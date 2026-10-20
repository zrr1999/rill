# 开发参考

开始开发和提交贡献见 [CONTRIBUTING.md](../CONTRIBUTING.md)。本文说明构建、测试和
生成物维护的操作细节；具体版本、参数和支持范围以当前配置及命令帮助为准。

## 工具链与依赖

使用 Xcode 提供的工具链，并确认 `xcrun metal -v` 可用。需要选择并存 Xcode 时，
通过 `DEVELOPER_DIR` 指定当前命令的工具链；预检日志记录实际工具链和系统信息。

Swift 依赖由 `Package.swift` 和 `Package.resolved` 共同声明，构建包装脚本使用锁定解析结果。
升级依赖时同时检查安全结果与第三方许可证据，避免在文档中复制一份版本约束。

独立 Python 入口可通过 inline metadata 及配套 `.py.lock` 声明运行环境；修改声明后用
`uv lock --script <path>` 更新对应锁文件。内部评测与回放工具由
`tools/pyproject.toml` 和 `tools/uv.lock` 管理，通过 `uv run --locked --project tools` 调用。
具体调用方式以 `justfile` 和各脚本入口为准。

## 构建与缓存

`just build` 默认只构建 Debug App，适合日常 App/UI 修改。Debug 产物在当前 worktree
的 `.build`，Release 产物在 `.artifacts/build/release`。构建驱动负责加锁和缓存失效；
不要在构建时手工删除目录，也不要跨 worktree 复制或软链接构建数据库。

完整依赖图通过 SwiftBuild 编译 String Catalog。`test-domain` 定向入口使用独立构建目录
和缩小的依赖图；仅指定测试过滤器不保证缩小首次编译范围。定向领域测试可以使用：

```bash
scripts/preflight.sh swift test-domain --filter SessionCoordinatorTests
```

该入口保留锁文件校验，不能替代完整生产依赖图上的 CI 验证。
工具链、SDK、依赖声明或构建参数变化时，相应缓存会失效；普通源码修改走增量构建。
`just ci-clean` 使用干净构建，具体 CI 缓存策略见 [工作流配置](../.github/workflows/ci-tests.yml)。

本地 Release 可以复用跨 worktree 的语音 worker 产物。构建驱动校验输入与产物，
无法确认或缓存损坏时回退源码构建；CI 和正式公证发布关闭该缓存。

```bash
just cache-status
just cache-clean
scripts/preflight.sh swift release --worker-cache off
```

清理只针对非活动缓存。手动装配时使用构建驱动的 `--result-file` 回执和
`assemble_app_bundle.sh --build-result`，避免从多个构建目录混取产物。
回执绑定源码和独立产物快照；App Intents 元数据与 Release 可执行文件一同保存和校验。
手动创建的回执快照由调用者在装配结束后清理。

## 测试

| 入口 | 覆盖范围 |
| --- | --- |
| `just test` | 领域测试，以及不要求真实桌面焦点的原生平台、UI 和 App 测试 |
| `just test-desktop` | 真实窗口焦点和键盘路由 |
| `just test-stress` | 大记录目录压力用例 |
| `just test-render` | 原生 UI 渲染证据 |
| `just test-scripts` | 构建、发布、安全和资源脚本的行为 |
| `just test-tools` | 内部评测和回放工具的离线行为 |

领域 XCTest 并行运行，原生和桌面 XCTest 串行运行；Swift Testing 保留框架默认并发。
预检中的桌面测试复用 Debug 构建。压力用例独立执行，具体分组与启用条件见
[预检脚本](../scripts/preflight.sh)；与 CI 一致的记录压力检查使用 `RILL_RECORD_STRESS=1`。

依赖真实键盘焦点的 XCTest 使用 `testDesktop…` 前缀，并在操作应用窗口前调用
`requireInteractiveDesktop()`。它用独立 AppKit panel 探测焦点，失败即记录测试失败，
不能跳过后当作通过；探测成功后还须验证被测窗口实际取得焦点。
AppKit 窗口、布局和响应者测试不等于应用外部的真实键盘或辅助功能操作。

竞态和生命周期回归使用可控时钟、fake 或同步屏障，观察用户可见结果与资源清理。
共享 runner 的耗时日志不能证明性能变化；质量评测、性能对照和 ASR 回放分别见
[Evals](../Evals/README.md)、[Benchmarks](../Benchmarks/README.md) 和
[ASR 评测](asr-evaluation.md)。原生交互验收见 [QA 清单](release-qa-checklist.md)。

## 预检报告与故障定位

完整预检在 `.artifacts/preflight/run.*/` 保存 `summary.md`、`source.json` 和阶段日志。
从摘要中的首个失败阶段开始定位；没有执行的阶段不能报告为通过。
CI 同时上传报告，初始化失败时应直接检查对应 Actions 步骤。

源码基线记录提交、Git 状态和文件指纹，每个阶段前后校验输入一致性。
预检期间不要修改源码；发生漂移后从稳定输入重新运行。PR CI 可能检出合并快照，
核对报告中的 source revision 与 PR head/base，不能只凭一个提交号判断证据归属。

先读 `toolchain.log` 确认环境，再查对应阶段日志。构建驱动只针对识别出的缓存损坏
清理重试，不自动重跑测试断言失败。完整预检与发布候选包的物理验收范围分别记录。

## 生成物与脚本维护

- 内建工作流位于 `Sources/RillPlatform/Resources/BuiltinWorkflows/`，与用户工作流
  共用解析和验证路径；格式与执行契约见 [工作流文档](workflow-toml.md)。
- 依赖变化后，用 `scripts/generate_third_party_notices.py` 更新许可清单，
  再运行其 `--check` 模式。安全检查使用受审 baseline；联网核对使用
  `scripts/check_dependency_security.py --live-osv`。按各入口声明的 uv 环境执行。
- 图标从受审矢量事实源生成，资源、校验值与生成方法见 [图标设计](icon-design.md)。
- 文档站的依赖与构建入口见 [文档站维护](documentation.md)。

生成物验证由完整预检执行。保留既有锁文件和校验边界，修改声明时同步事实源、
生成结果及受影响的行为测试。
