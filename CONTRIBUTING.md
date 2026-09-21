# Contributing to Rill

感谢你改进 Rill。这个仓库包含语音采集、剪贴板路由、外部输出和本地持久化等高影响边界；提交应保持改动可解释、依赖可复现，并为失败、取消、隐私收紧和 App 退出路径补充验证。

## 开发环境

- macOS 14.0 或更高版本
- Xcode 26 或更高版本，并选择包含 Swift 6.2+ 的 Command Line Tools；本地
  默认开发工具链为 Xcode 27
- 与所选 Xcode build version 匹配的 Metal Toolchain；运行 `xcodebuild -downloadComponent MetalToolchain` 安装，`xcrun metal -v` 必须成功。若组件已安装但验证仍失败，请通过 `DEVELOPER_DIR` 临时选择一个组件可用的并存稳定版 Xcode
- [uv](https://docs.astral.sh/uv/guides/scripts/)；发布脚本通过 PEP 723 单文件脚本模式运行 Python 3.11 或更高版本
- Git；运行完整发布预检还需要 macOS 自带的 `codesign`、`lipo`、`otool` 和磁盘映像工具
- Gitleaks 8.30.1；仓库安装脚本会按当前 Mac 架构下载并校验固定 SHA-256
- [just](https://just.systems/) 与 [prek](https://prek.j178.dev/)，用于运行与 CI 相同的仓库门禁

先确认工具链，再使用锁定依赖的包装脚本：

```bash
swift --version
xcrun metal -v
uv run --script scripts/report_python_version.py
scripts/swift_locked.sh build
bash scripts/test.sh
```

安装 Git hooks，并通过统一入口运行开发门禁：

```bash
just install
just check
just build          # 默认只构建 Debug RillApp
just test
just ci             # 保留增量产物的完整门禁
just ci-clean       # 与每个 PR 一样的干净构建门禁
```

`just check` 只运行 prek 内建检查以及上游提供的 TOML、Actionlint 和 Typos
检查；不在 Git hook 中运行整仓构建、完整历史扫描或项目策略测试。
这些项目专用检查集中在 `just ci` / `scripts/preflight.sh`，生成物和安全门禁
仍然是提交前必须完成的检查。新增通用检查时优先复用维护中的上游工具。

不要删除、绕过或手工改写 `Package.resolved`。所有 SwiftPM 构建和测试都应通过 `scripts/swift_locked.sh` 运行，以保证使用仓库锁定的依赖图。

原生 MLX 路径固定使用 `mlx-audio-swift` 0.1.3 与 `mlx-swift` 0.31.4。
`mlx-swift` 0.31.5/0.31.6 的 `CudaBuild` package plugin 会破坏当前 Xcode
package graph，且 SwiftPM 消费方不能关闭传递插件；只有上游发布修复或仓库引入
受审 fork 后才升级这个底层 pin。

`scripts/check_dependency_security.py` 及其他发布辅助脚本使用 [uv 的单文件脚本模式](https://docs.astral.sh/uv/guides/scripts/)和 PEP 723 inline script metadata，只使用 Python 3.11+ 标准库。脚本顶部的 `requires-python = ">=3.11"` 会让 uv 自动选择或下载兼容的 Python；因此本机不需要单独安装或配置 `python3`。本地默认模式对照 `scripts/dependency_security_baseline.json` 做确定性离线检查；baseline 只记录已经复核来源和受影响版本边界的 advisory，删除或放宽已固定的 required policy 会失败。首次运行时，如果 uv 缓存中没有兼容的 Python，uv 可能需要联网下载解释器。需要联网复核全部 exact lock commit 时运行：

```bash
uv run --script scripts/check_dependency_security.py
uv run --script scripts/check_dependency_security.py --live-osv
```

live 模式固定调用 OSV 官方 `https://api.osv.dev/v1/querybatch`；响应按 lock 顺序映射，只有返回独立 `next_page_token` 的条目会继续分页。网络、重定向、JSON/字段、结果数量、重复 advisory 或分页异常都必须 fail-closed，任何 advisory 都会阻断。依赖变化必须同步锁文件测试与第三方 NOTICE 证据；baseline 变化必须保留受审来源并更新 policy tests，不能用 baseline 忽略 live 结果。

CI 直接调用的 Python 脚本随附 `.py.lock`，并使用 `--no-build --locked`。
修改这些脚本的依赖或 Python 要求后，运行 `uv lock --script <path>` 更新对应锁文件。

可以把仓库固定的 Gitleaks 安装到个人工具目录：

```bash
tool_dir="$HOME/.local/share/rill/bin"
bash scripts/install_gitleaks.sh --destination "$tool_dir"
export PATH="$tool_dir:$PATH"
gitleaks version
```

## 构建目录与增量验证

Debug 使用当前 worktree 的 `.build`，Release 使用 `.artifacts/build/release`。
构建、清理和产物快照由统一入口按配置加锁；不要在另一进程构建时手工删除目录，
也不要在 worktree 之间复制或软链接 SwiftPM 的构建数据库。工具链、SDK、Metal、
锁文件、Package 声明或构建参数变化会使相应配置失效；普通源文件变化由 SwiftPM
增量处理。清理不删除 SwiftPM 的共享依赖下载缓存。

`just build RillApp` 适合 App/UI 日常修改，不编译语音 worker 和 MLX。
`swift test --filter` 只限定测试执行范围，不保证缩小首次编译范围。
完整预检和打包使用绑定源码摘要的构建回执及独立产物快照；装配过程中源码或
产物不匹配会失败。许可证验证读取该次构建实际使用的依赖 checkouts。

### 跨 worktree 的 worker 产物缓存

本地 Release 默认复用完整的 `RillSpeechWorker` 和依赖资源，缓存位于
`~/Library/Caches/Rill/BuildArtifacts/worker-v1/`，只允许当前用户访问。
缓存键包含求值后的包声明、worker 传递依赖的实际文件内容、锁文件、工具链、
SDK、Metal 及构建参数；增加、删除或修改未提交文件也参与判断。仅修改 App/UI
可继续命中。无法完整确定输入、依赖 checkout 有改动或条目损坏时，回退源码构建。

- `just cache-status` 显示容量，`just cache-clean` 删除非活动条目。
- 默认限制 10 GiB，成功使用后按最近使用情况淘汰；活动条目持有锁。
- `scripts/build_xcode_release.sh --worker-cache off` 强制使用源码。
- `--result-file PATH` 写入带校验值的 JSON 回执及产品快照；PATH 应放在被 Git
  忽略的目录或工作区之外。`assemble_app_bundle.sh --build-result PATH` 消费该回执。
- `--show-bin-path` 仍返回当前 SwiftPM 产品目录。缓存命中的 worker 可以来自
  独立目录，装配时应使用回执；不要假定该目录含有缓存命中的 worker。
- `RILL_BUILD_CACHE_DIR` 可将缓存定向到独立测试目录。正式公证发布及 CI 始终关闭
  worker 缓存；缓存不替代完整测试，新 worktree 首次测试仍需编译测试依赖。

构建回执将产品复制到其父目录中的独立快照，预检和发布脚本会自动清理自己的
临时快照。手动指定回执目录时，由调用者在装配完成后清理该目录。共享缓存中的
文件不参与签名；所有签名都在当前装配目录中完成。

实测数据、计数口径和复现步骤见 [构建提速验证](docs/build-performance.md)。

## 本地 App 与发布

`swift build` 只生成可执行文件，不会装配带权限声明的 macOS App。
使用本机可用的 Apple Development 签名身份进行开发安装：

```bash
SIGN_IDENTITY="Apple Development" bash scripts/release.sh --install
```

该命令使用独立的 Release scratch path，增量构建、装配、签名、验证并原子安装；
不会隐式运行完整测试。先运行 `just ci`，或用 `--preflight --install` 一并执行。
省略 `--install` 会在 `.artifacts/release/` 生成本地 App 和 DMG。
本地开发签名不证明 Developer ID 公证或 Gatekeeper 分发验收通过。
正式版本、签名、公证与对应源码交付见 [发布步骤](docs/releasing.md)。

## 文档归属

参照 ZenDev，文档按用途维护，具体行为以当前源码和配置为准：

| 文档 | 内容 |
| --- | --- |
| [README.md](README.md) | 用户安装、首次使用、工作流配置、隐私设置、排查与升级卸载 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 开发环境、验证、生成物维护、文档归属与 Git 约定 |
| [LICENSE](LICENSE) | Rill 原创代码和文档的 AGPL-3.0-only 许可条款 |
| [SECURITY.md](SECURITY.md) | 支持版本、漏洞报告渠道及披露规则 |
| [PRIVACY.md](PRIVACY.md) | 随 App 分发的技术隐私与数据流说明 |
| [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)、[LOCAL_MODEL_NOTICES.md](LOCAL_MODEL_NOTICES.md) | 第三方依赖与模型的许可及来源证据 |
| [架构](docs/architecture.md)、[Record](docs/record-architecture.md)、[工作流](docs/workflow-toml.md)、[上下文纠错](docs/contextual-correction.md)、[UI](docs/ui-direction.md) | 开发者维护的模块、状态、执行与界面契约 |
| [发布步骤](docs/releasing.md)、[验收清单](docs/release-qa-checklist.md) | 维护者发布流程和特定候选包的验收要求 |

用户说明集中在 README；技术契约保留在所属文档，通过链接引用。
`docs/` 中的研究、计划和历史 QA 记录提供背景，不作为当前产品能力或发布通过的依据。

文档站使用 Zensical；`just docs` 严格构建并检查链接，`just docs-serve` 提供自动刷新的
本地预览。页面清单、依赖锁定与站点交付边界见 [文档站维护](docs/documentation.md)。
站点直接使用上述正文，不维护另一份文档副本。`scripts/docs.py` 是 Python 辅助脚本中
唯一使用第三方依赖的入口；Zensical 与传递依赖由随脚本提交的锁文件固定，不随 App 分发。

修改产品行为时同步对应使用说明和契约，避免在多个计划文件中重复维护使用手册。

## 改动边界

模块依赖应保持单向；完整依赖图与状态归属见 [架构说明](docs/architecture.md)：

```text
RillCore          领域模型与协议
RillPlatform      macOS 系统边界
RillSpeechContracts Worker 协议、流式合同与本地模型清单
RillProviders     识别客户端、变换与外部输出实现
RillRuntime       会话协调与运行生命周期
RillPersistence   加密持久化
RillUI            SwiftUI、功能状态所有者与 AppModel 编排
RillApp           组合根
```

- 让 `RillCore` 保持平台无关；系统 API 和第三方 SDK 不应反向进入领域层。
- 将一次运行的成功、失败、取消、部分完成和退出清理建模为显式状态，不用错误字符串替代跨层合同。
- 新增任何正文、音频、路径、端点或凭据流向时，同步说明隐私判定、持久化、诊断清洗、取消与清理行为。
- 修复应覆盖用户可见入口和真实组合根；仅有孤立模型或未注册实现不算产品能力。
- 保持改动聚焦。不要顺带重写无关文件，也不要覆盖工作树中不属于当前改动的内容。

## 测试

开发时可以先运行定向测试：

```bash
scripts/swift_locked.sh test --filter MainShellFocusIntegrationTests
scripts/swift_locked.sh test --filter SessionCoordinatorTests
```

提交前必须运行完整测试与仓库门禁；`just ci` 是本地与 CI 的统一入口：

```bash
just ci
git diff --check
git diff --cached --check
```

`scripts/preflight.sh` 会先运行依赖安全 policy tests 和 reviewed baseline 离线检查，再用固定版本的 Gitleaks 扫描完整 Git 历史与 tracked + untracked(nonignored) 当前源码快照；之后检查脚本语法、生成物和仓库根发布产物卫生，保留现有增量产物，执行 arm64-only Release 构建、验证最低 macOS 版本、装配并临时签名 App、运行完整测试。CI 在此基础上单独运行 live OSV exact-commit 查询，避免把可用网络伪装成本地确定性门禁。当前源码扫描拒绝 symlink 与非普通文件，并保留扫描清单；Gitleaks 返回后会重新枚举源文件集并逐字节比对原文件与快照，扫描期间发生任何增删改都必须失败后重试。扫描日志始终脱敏；`.gitleaks.toml` 只允许经过审查的公开模型 hash/revision 精确值，并同时约束 rule、路径和完整行，不允许关闭通用凭据规则。`just ci-clean` / `scripts/preflight.sh --clean` 在开始时分别清理 Debug 和 Release；GitHub PR CI 与正式公证发布强制使用此模式。预检不能替代在 macOS 14 的 Apple Silicon 真机上验证最终公证包，也不能替代 `docs/release-qa-checklist.md` 中的人工交互和辅助功能检查。

修复竞态或生命周期问题时，应优先使用可控的 fake、barrier 或 lease 写确定性测试；不要依赖固定 `sleep` 猜测时序。涉及 SwiftUI/AppKit 焦点、系统权限、全局快捷键、VoiceOver、签名或公证时，除自动化测试外还需记录真实环境验收结果。

主窗口搜索由 MainShell 的浮层与 AppKit `NSSearchField` bridge 共同拥有，以便在 macOS 14 上确定性处理首次/重复 `Cmd-F`、方向键、`Return` 与 `Esc`；不要未经同等真实 App 回归就替换为 `.searchable`。普通页面路由由 shell 恢复侧栏焦点，typed Record / History 目的地则由详情页持有目标焦点，Settings 深链由独立设置窗口持有目标焦点。鼠标选择后的恢复必须跨到主 RunLoop 的 default mode，不能只靠 `Task.yield()` 猜测 AppKit mouse tracking / first-responder 时序；修改任一侧时都应覆盖 全部记录 → 记录集 → 活动的方向键、List selection、快速路由与 exact 详情 AX 焦点。

## GitHub Actions 命名

参考 ZenDev 和 Volvox，workflow 文件使用小写 kebab-case，按职责使用 `ci-`、
`cd-`、`policy-` 或 `automation-` 前缀；显示名称对应 `CI - <Purpose>`、
`CD - <Purpose>`、`Policy - <Purpose>` 或 `Automation - <Purpose>`。
PR 和提交规范采用 ZenDev 当前的 `Policy - PR` 分类。

| Workflow | 显示名称 | 职责 |
| --- | --- | --- |
| [policy-pr.yml](https://github.com/zrr1999/rill/blob/main/.github/workflows/policy-pr.yml) | Policy - PR | PR 标题和正文 |
| [automation-pr-title.yml](https://github.com/zrr1999/rill/blob/main/.github/workflows/automation-pr-title.yml) | Automation - PR Title | 规范化 ImgBot 默认标题 |
| [ci-tests.yml](https://github.com/zrr1999/rill/blob/main/.github/workflows/ci-tests.yml) | CI - Tests | Linux 文档构建，以及按修改范围运行的 macOS 测试、依赖和发布预检 |

job ID 使用小写 kebab-case，检查名称描述具体职责。`Required CI` 和 `PR message`
是主分支保护要引用的检查名称；改名时必须同步服务端配置及发布文档。

`Automation - PR Title` 在 `pull_request_target` 上只通过 GitHub API 改名，永不检出 PR head
或任何仓库代码。
它只把 `imgbot[bot]` 的 `[ImgBot] Optimize images` 改为 `⚡ perf(assets): optimize images`，
保留其他作者和人工设置的标题；写权限只授予该 job。
`Policy - PR` 使用普通 `pull_request` 校验标题和正文，不调用自动化工作流。
自动化改名会触发 `edited`，policy 随后按新标题重新运行。提交信息由本地 prek
`commit-msg` hook（`zendev-message-check`）校验，CI 不逐条扫描提交。

## 生成文件

不要直接编辑生成产物。

- 内建工作流以 `Sources/RillApp/Resources/BuiltinWorkflows.toml` 为事实源。修改后运行：

  ```bash
  uv run --script scripts/generate_builtin_workflows.py
  uv run --script scripts/generate_builtin_workflows.py --check
  ```

- `THIRD_PARTY_NOTICES.md` 由锁文件和脚本内受审证据生成。依赖变化后运行：

  ```bash
  uv run --script scripts/generate_third_party_notices.py
  uv run --script scripts/generate_third_party_notices.py --check
  ```

- App 图标的受审源文件是 `Resources/AppIcon/AppIcon-1024-routed-voice-cursor.png`；`scripts/render_app_icon_renditions.swift` 生成包含透明圆角和小尺寸光学调整的传统 macOS renditions，`scripts/generate_app_icon.sh` 再装配 ICNS。图标来源与受审 SHA-256 记录在同目录 `README.md` 中。`scripts/release.sh` 默认把本地产物写入被忽略的 `.artifacts/release/`；仓库根目录禁止出现 `Rill.app`、`Rill.dmg` 或 `Rill.dmg.sha256`，也不应提交临时装配目录、本地发布产物或 `.rill-release.*` 私有 staging。

生成器、事实源和生成结果应放在同一个提交中。

## 提交与 Pull Request

提交信息和英文 PR 标题遵守 [ZenDev](https://github.com/zendev-lab/zendev)
的 `zendev` profile，例如 `🐛 fix(ui): preserve sidebar focus after route changes`。
使用官方校验器检查 emoji 与 type 的对应关系、scope、正文和 footer，不维护另一套正则。
当前统一版本是 0.4.0；prek 的上游 revision 和 CI Actions 均固定到 commit，
ZenDev CLI 及其 commit/review 组件在本地和 CI 中固定为相同版本。

- `just install` 安装标准 `pre-commit` 和 `commit-msg` hooks，后者运行
  `zendev-message-check --profile zendev`。提交信息在本地 hook 中校验；CI 不扫描
  PR 或主分支的完整提交历史。
- CI 的 `PR message` 检查英文标题的 ZenDev 格式，并按
  [.github/pull_request_template.md](https://github.com/zrr1999/rill/blob/main/.github/pull_request_template.md) 验证描述章节。
  PR 标题必须使用英文；描述可使用中文。
- 一个提交表达一个可审阅的意图，说明最终行为和实际测试结果。
  人工验收未完成时明确记录，不能用单元测试或本地开发签名代替。
- 原创贡献使用项目的 AGPL-3.0-only 许可；引入第三方代码时保留其原始
  版权和许可声明，并同步对应的来源证据。

需要核对一段历史时，可在本地运行同一校验器；无参数时检查当前 HEAD 的全部历史，
提供 base 时只检查它之后引入的提交：

```bash
bash scripts/check_commit_messages.sh
bash scripts/check_commit_messages.sh origin/main HEAD
```

主分支应要求 `Required CI` 和 `PR message` 通过，并限制直接推送和绕过规则。
仓库仅启用 rebase 合并来保留已通过 hook 校验的 message；若维护者重新启用
squash，最终生成的 message 必须重新经过同一校验器。GitHub 的计划、权限和
仓库设置决定这些规则是否实际生效；提交 CI 配置不等于已经启用服务端保护。

## 发布权限

普通贡献不应创建版本标签、安装到其他用户的 `/Applications`，或提交公证请求。发布脚本默认输出到 `.artifacts/release/`，并在构建前使旧 App/DMG/sidecar 失效；新产物只在同文件系统私有 staging 中完成验证后原子发布。仓库内 `RELEASE_OUTPUT_DIR` 的逻辑路径与解析后的物理祖先都必须位于 `.artifacts/`，公证快照 capability 也绑定物理输出位置；仓库外隔离目录不受此限制。完整发布策略测试（包括 App-only SwiftPM 产品面）必须保持通过。正式发布需要维护者明确授权，并要求：

- 工作树（含未跟踪文件）干净；
- `HEAD` 精确且唯一地标记为 `vMAJOR.MINOR.PATCH`；
- `Package.resolved` 已跟踪且与该提交一致；
- 使用 Developer ID Application 身份和维护者管理的 `notarytool` 凭据；
- 最终 DMG 完成签名、公证、staple、Gatekeeper 复验和人工 QA。

发布步骤见 [docs/releasing.md](docs/releasing.md)，实际打包以 `scripts/release.sh` 和 `docs/release-qa-checklist.md` 为准。项目许可见 [LICENSE](LICENSE)，安全报告渠道状态与披露规则见 [SECURITY.md](SECURITY.md)。
