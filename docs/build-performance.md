# 构建提速验证

2026-09-21 在 Apple Silicon Mac17,9（64 GiB）、macOS 27.0 26A428、
Xcode 27.0 27A5228h、Swift 6.4 上进行本地测量。源代码基线为 `cb5bff3`，
干净门禁在 `c900a1a` 运行；之后的 `94432e2` 收紧了清理判定和缓存输入复核，
并通过完整增量门禁。两次之间没有修改 Swift 源码、Package 或锁文件。

## 测量结果

| 场景 | 命令总耗时 | Release 构建耗时 | Release 编译任务 | 其中 worker/MLX |
| --- | ---: | ---: | ---: | ---: |
| `just ci-clean`，关闭 worker 缓存 | 402.8 s | 214.36 s | 686 | 204 |
| 随后的 `just ci`，源码无变化 | 104.4 s | 2.52 s | 0 | 0 |
| 全新 worktree，修改 UI 和 App 资源，命中 worker | 99.0 s | 72.69 s | 12 | 0 |
| 同一验证 worktree 再修改 UI，命中 worker | 50.6 s | 40.23 s | 2 | 0 |

完整门禁还包含 Debug 构建与全部测试、安全和发布策略检查、图标生成、许可证
核验及签名装配。Debug 构建从 69.01 s 降至 3.33 s；其余检查继续执行。
UI 修改仍会触发 UI/App 的编译和链接，这部分开销不会被 worker 缓存消除。

这里的冷构建指清空当前 worktree 的编译产物，仍保留依赖 checkouts 和机器上的
下载缓存。测量期间存在其他 worktree 的构建，样本只有一轮，不能据此承诺稳定
加速比例。此前另一轮资源竞争更重的 Release 构建为 753.20 s，不将它与本表
混用。首次完整测试依然会编译测试需要的 MLX 依赖。

任务数来自 Swift Build 数据库中本轮执行的 `CompileC`、`CompileMetalFile` 和
`SwiftDriver Compilation` 规则，排除 `Compilation Requirements`；它是构建
命令数，不是 Swift 文件数。worker/MLX 按目标名称统计，不把 App 同样需要的
Core/Providers 编译算成 worker 专属编译。还核对了对象文件时间与大小：无改动
门禁的 Release 对象文件更新为零。

## 缓存开销和正确性

一个真实 worker 条目为 109,597,296 bytes（约 104.5 MiB），包含 worker 及其
运行资源。一次独立测量中，输入身份计算为 0.7225 s、条目完整性校验为
0.0465 s、锁定依赖 checkout 核验为 0.7514 s。这些是分项开销，不是整个构建
命令的额外耗时。产品回执还会产生由调用者负责清理的独立快照。

缓存键相同的两个真实 worktree 同时构建均成功命中，回执中的 worker SHA-256
相同，各自 App 独立构建。当前实现对同一个条目持有独占锁直到产品快照完成；
同键并发消费者会等待，清理不会删除使用中的条目。

在新 worktree 中修改 UI 数值与工作流模板注释后，使用回执装配，逐字节核对
当前 App、worker 和修改后的资源，并检查版本、源码提交及 dirty 标记。随后
通过 arm64/macOS 14 Mach-O 检查、ad-hoc 签名验证和 worker 标准输入 EOF 启动
退出检查。单独清理 Debug 后，Release 可执行文件摘要保持不变。

实际执行 `SIGN_IDENTITY="Apple Development" scripts/release.sh --preflight`
完成本地 App/DMG 装配与签名，用时 133.6 s。预检和装配前的两次 Release 增量
检查各为 0.85 s，整轮 Release 编译任务为零，DMG 校验通过；没有安装或公证。

自动化覆盖了输入增删改、跨物理路径身份一致、工具链及参数失效、未知输入
绕过、资源冲突、损坏条目、发布中断状态、活动条目清理、进程锁互斥，以及构建
或复制期间输入漂移拒绝发布。新增可执行产品由 Package 声明自动纳入构建。
首次编译发生普通源码错误后，也会保留已经完成的依赖编译供修复后继续使用。

## 验证边界与复现

`just ci-clean` 和 `just ci` 均通过：1,760 项 XCTest 中 6 项按原有 opt-in 规则
跳过，另外 85 项 Swift Testing 通过。跳过项为原生截图导出和 10,000 条记录的
压力测试。Prek、依赖安全 baseline、秘密扫描、发布策略和许可证检查均通过。
这不代表公证、Gatekeeper 或物理 Fn/麦克风交互验收；本改动没有安装应用。

复现顺序：先在 owning worktree 运行 `just ci-clean`，再运行 `just ci`。新建
独立 worktree 后修改 `RillUI` 或 App 资源，并运行：

```bash
scripts/build_xcode_release.sh --result-file .artifacts/benchmark/result.json
just cache-status
```

确认回执 `workerCache.status` 为 `hit`，构建日志没有 MLX/worker 编译，且独立
装配结果包含当前工作区的 App 与资源。不要在本地 worktree 之间复制或共享
`.build` 或 Release 的 SwiftPM 数据库。

PR CI 在 GitHub runner 的同一路径恢复 SwiftPM 构建缓存，缓存键包含操作系统、
架构、Xcode/Swift/SDK 身份、Package 声明、锁文件和构建驱动。构建驱动仍核对
物理路径、工具链、参数和依赖指纹；不匹配时清理对应 arena，SwiftPM 再判断源码
需要重新编译的部分。正常结束的失败运行也会保存已生成的构建缓存，便于修复
测试后重用编译结果；取消的运行不保存。缓存只减少重复编译，测试、安全检查
及签名装配均照常执行，失败的预检仍会阻断 Required CI。
独立的 worker 产物缓存仍在所有 CI 中关闭；主分支 push、手动 CI 和正式公证
发布继续执行干净预检。上表是本地历史测量，不代表 GitHub 缓存的实际提速比例。

本次原始日志与分项 JSON 保存在 owning worktree 的
`.artifacts/build-performance/`；验证 App 位于相邻
`build-performance-validation/.artifacts/benchmark/Rill.app`，仅作为本地测试产物。
