# 开发参考

## 工具链与依赖

使用 Xcode 提供的工具链，并确认 `xcrun metal -v` 可用。需要选择并存 Xcode 时，通过 `DEVELOPER_DIR` 指定当前命令的工具链；预检日志记录实际工具链和系统信息。

Swift 依赖由 `Package.swift` 和 `Package.resolved` 共同声明，构建包装脚本使用锁定解析结果。升级依赖时同时检查安全结果与第三方许可证据。

独立 Python 入口可通过 inline metadata 及配套 `.py.lock` 声明运行环境；修改声明后用 `uv lock --script <path>` 更新对应锁文件。内部评测与回放工具由 `tools/pyproject.toml` 和 `tools/uv.lock` 管理，通过 `uv run --locked --project tools` 调用。

## 构建与缓存

`just build` 默认只构建 Debug App，适合日常 App/UI 修改。`just build release` 构建全部 arm64 Release 产品。Debug 产物在当前 worktree 的 `.build`，Release 产物在 `.artifacts/build/release`。构建驱动负责加锁和缓存失效；不要在构建时手工删除目录，也不要跨 worktree 复制或软链接构建数据库。

完整依赖图通过 SwiftBuild 编译 String Catalog。`test-domain` 定向入口使用独立构建目录和缩小的依赖图；仅指定测试过滤器不保证缩小首次编译范围。定向领域测试可以使用：

```bash
scripts/preflight.sh swift test-domain --filter SessionCoordinatorTests
```

该入口保留锁文件校验，不能替代完整生产依赖图上的 CI 验证。工具链、SDK、依赖声明或构建参数变化时，相应缓存会失效；普通源码修改走增量构建。 `just ci clean` 使用干净构建，具体 CI 缓存策略见 [工作流配置](../.github/workflows/ci-tests.yml)。

本地 Release 可以复用跨 worktree 的语音 worker 产物。构建驱动校验输入与产物，无法确认或缓存损坏时回退源码构建；CI 和正式公证发布关闭该缓存。

```bash
just cache
just cache clean
just build release --worker-cache off
```

清理只针对非活动缓存。手动装配时使用构建驱动的 `--result-file` 回执和 `assemble_app_bundle.sh --build-result`，避免从多个构建目录混取产物。回执绑定源码和独立产物快照；App Intents 元数据与 Release 可执行文件一同保存和校验。手动创建的回执快照由调用者在装配结束后清理。

## 测试

| 入口 | 覆盖范围 |
| --- | --- |
| `just test stress` | 大记录目录压力用例 |
| `just test render` | 原生 UI 渲染证据 |

领域 XCTest 并行运行，原生和桌面 XCTest 串行运行；Swift Testing 保留框架默认并发。预检中的桌面测试复用 Debug 构建。压力用例独立执行，具体分组与启用条件见 [预检脚本](../scripts/preflight.sh)；与 CI 一致的记录压力检查使用 `RILL_RECORD_STRESS=1`。

依赖真实键盘焦点的 XCTest 使用 `testDesktop…` 前缀，并在操作应用窗口前调用 `requireInteractiveDesktop()`。它用独立 AppKit panel 探测焦点，失败即记录测试失败，不能跳过后当作通过；探测成功后还须验证被测窗口实际取得焦点。

性能对照使用同一机器和环境的基线与候选样本。质量评测、性能对照和 ASR 回放分别见 [Evals](../Evals/README.md)、[Benchmarks](../Benchmarks/README.md) 和 [ASR 评测](asr-evaluation.md)。原生交互验收见 [QA 清单](release-qa-checklist.md)。

## 质量检查与报告

`just check` 只读检查源文件；需要修复格式时显式运行 `just format`。Python 保留 Ruff 与 ty，deptry 检查运行时依赖，Import Linter 约束构建元数据不能依赖评测策略。ast-grep 约束领域模块的偏好存取边界，Semgrep 检查原始评测文件的权限；两者分别维护违规与合法样例。

`just coverage` 在 `.artifacts/quality/` 生成 Python XML 和 Swift LCOV、文本摘要。覆盖率测试明确使用与完整预检一致的 SwiftBuild，避免随 Xcode 默认值改变测试包组织方式。Swift 报告合并领域测试的所有测试二进制，仅覆盖该入口编译的模块；不代表 App、UI、输入法和语音 worker 已完成覆盖率采集。Codecov 接收两种实测报告，Sonar 分析应用与辅助源码；上传失败或缺少账号凭据会使对应 CI 步骤失败。

`just mutation` 验证编辑距离评分函数的测试有效性。变异工具使用独立 Python 环境，不改变开发工具的默认解释器。`just reports` 输出 jscpd、Lizard 和 Radon 的结构指标，尚未建立预算的指标与变异结果用于审查，不设统一分数线。报告、外部链接和性能检查沿用每周周期，也支持手动运行。模型评测依赖明确配置的服务和固定合成用例；真实音频与设备验收仍按对应评测文档执行。

## GitHub Actions

Workflow 文件名和 job ID 使用小写 kebab-case。文件按职责使用 `ci-`、`ce-`、`cd-`、 `policy-` 或 `automation-` 前缀，显示名称对应 `CI - <Purpose>`、`CE - <Purpose>`、 `CD - <Purpose>`、`Policy - <Purpose>` 或 `Automation - <Purpose>`。

[Policy - PR](../.github/workflows/policy-pr.yml) 只读校验 PR 元数据，检出 base commit 的模板。有写操作的 PR 自动化放在独立的 [Automation - PR Title](../.github/workflows/automation-pr-title.yml) 中，仅授予所需的 `pull-requests: write` 和 `actions: write`；不检出 PR 代码，也不读取上游运行产物。

jactionlint 本地离线检查 Git 可见的 workflow 和 action 文件，并实际运行 ShellCheck 与 Pyflakes；下载依赖中的第三方 action 不属于扫描输入。zizmor 继续检查安全规则。受信任的主分支 CI 执行严格在线审计，查询失败不能算作通过。CodeQL 分析 Swift、C、Python 与 Actions。Swift 源码分析使用独立的 native 构建目录，避开 tracer 与 SwiftBuild Metal 资源编译的冲突；这份分析产物不用于 App 装配，生产构建仍使用 SwiftBuild；依赖审计分别查询 Swift 锁定提交和全部 Python 锁文件。

仓库规则使用实际检查名称：[Policy - PR](../.github/workflows/policy-pr.yml) 的检查是 `PR message`，[CI - Tests](../.github/workflows/ci-tests.yml) 的汇总检查是 `Release preflight`。后者要求文档检查、所需的 tests / release lane 和 Record workload 检查成功，仅接受范围判定明确不需要运行的跳过项；失败、取消或缺少范围输出均阻断。修改检查名称时同步核对仓库规则，合并步骤见[发布文档](releasing.md#合并门禁)。

## 预检报告与故障定位

完整预检在 `.artifacts/preflight/run.*/` 保存 `summary.md`、`source.json` 和阶段日志。从摘要中的首个失败阶段开始定位。 CI 同时上传报告，初始化失败时应直接检查对应 Actions 步骤。

源码基线记录提交、Git 状态和文件指纹，每个阶段前后校验输入一致性。预检期间不要修改源码；发生漂移后从稳定输入重新运行。PR CI 可能检出合并快照，核对报告中的 source revision 与 PR head/base。

先读 `toolchain.log` 确认环境，再查对应阶段日志。构建驱动只针对识别出的缓存损坏清理重试，不自动重跑测试断言失败。

## 生成物与脚本维护

- 内建工作流位于 `Sources/RillPlatform/Resources/BuiltinWorkflows/`，与用户工作流
  共用解析和验证路径；格式与执行契约见 [工作流文档](workflow-toml.md)。
- 依赖变化后，用 `scripts/generate_third_party_notices.py` 更新许可清单，
  再运行其 `--check` 模式。安全检查使用受审 baseline；联网核对使用
  `scripts/check_dependency_security.py --live-osv`。按各入口声明的 uv 环境执行。
- 图标从受审矢量事实源生成，资源、校验值与生成方法见 [图标设计](icon-design.md)。
- 文档站的依赖与构建入口见 [文档站维护](documentation.md)。
