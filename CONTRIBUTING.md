# Contributing to Rill

## 开发环境

准备 macOS、Xcode 及其 Command Line Tools 和 Metal Toolchain，以及 [uv](https://docs.astral.sh/uv/)、[just](https://just.systems/) 和 Git。

平台与 Swift 要求见 [Package.swift](Package.swift)，工具链检查见 [scripts/preflight.sh](scripts/preflight.sh)。Swift、文档和 Python 工具使用仓库配置和锁文件声明的版本。`just install` 与 `just check` 的 prek 由本机 uv 环境解析；GitHub CI 固定 prek `v0.5.5`。

在仓库根目录安装 hooks，然后构建和测试：

```bash
just install
just build
just test
```

用 `just --list` 查看完整命令。构建模式、定向测试和故障定位见 [开发参考](docs/development.md)。SwiftPM 构建和测试统一通过 `scripts/preflight.sh swift` 运行；保留并使用仓库的 `Package.resolved`。

## 验证

| 命令 | 用途 |
| --- | --- |
| `just check` | 格式化与静态检查 |
| `just docs` / `just docs serve` | 严格构建文档与本地预览 |
| `just test` | 不依赖真实桌面焦点的领域和原生测试；不启用压力与渲染证据 |
| `just test desktop` | 在已解锁的交互式桌面验证焦点与键盘路由 |
| `just test scripts` / `just test tools` | 构建发布脚本与内部开发工具的离线测试 |
| `just ci` / `just ci clean` | 完整门禁。与 GitHub tests lane 一样启用一万条记录压力和 UI 渲染证据；`ci clean` 在清理构建产物后重跑 |

提交前运行 `just ci` 和 `git diff --check`。完整门禁需要可用的交互式桌面。

涉及 Fn、麦克风、IME、跨应用输出或 VoiceOver 的改动，按 [macOS 验收清单](docs/release-qa-checklist.md)进行人工验收。质量评测与性能测量分别见 [Evals](Evals/README.md) 和 [Benchmarks](Benchmarks/README.md)。

## 本地 App 与发布

构建可执行文件后，还需装配 App 才能验证权限声明和系统集成。完成验证后，使用本机可用的开发签名身份进行本地安装：

```bash
SIGN_IDENTITY="Apple Development" bash scripts/release.sh --install
```

省略 `--install` 可在 `.artifacts/release/` 生成本地产物。正式发布的版本标签、签名、公证和验收由维护者按 [发布步骤](docs/releasing.md)执行。

## 文档归属

| 入口 | 内容 |
| --- | --- |
| [README](README.md)、[用户指南](docs/usage.md) | 安装、首次使用和产品功能 |
| [开发参考](docs/development.md) | 构建、测试和生成物维护 |
| [架构](docs/architecture.md)、[Record](docs/record-architecture.md)、[工作流](docs/workflow-toml.md)、[UI](docs/ui-direction.md) | 模块、状态、执行和界面契约 |
| [输入法工程](docs/input-method-development.md)、[图标设计](docs/icon-design.md) | 对应功能的工程与资源维护 |
| [文档站维护](docs/documentation.md) | 文档收录、构建和站点交付 |
| [发布步骤](docs/releasing.md)、[验收清单](docs/release-qa-checklist.md) | 发布流程与候选包验收 |
| [EVOLUTION.md](EVOLUTION.md) | 项目起源和真实的方向变化 |
| [LICENSE](LICENSE)、[SECURITY](SECURITY.md)、[PRIVACY](PRIVACY.md) | 许可、安全报告与隐私说明 |

修改产品行为时同步相关说明。Agent 指令见 [AGENTS.md](AGENTS.md)。

## 改动边界与生成物

- 覆盖真实入口及失败、取消、隐私收紧和退出清理路径。竞态测试优先使用可控时钟或同步屏障。
- 新增正文、音频、路径、端点或凭据流向时，同步隐私、持久化与清理说明。
- 修改源文件后重新生成并提交对应产物；生成器变化时一并提交。依赖升级同步锁文件、许可清单和第三方许可证据，不要提交渲染后的 `THIRD_PARTY_NOTICES.md`；资源维护入口见开发参考。

## 提交与 Pull Request

提交信息和英文 PR 标题遵守 [ZenDev](https://github.com/zendev-lab/zendev) 的 `zendev` profile，例如 `🐛 fix(ui): preserve sidebar focus after route changes`。 `just install` 安装的 hooks 与 CI 使用官方校验入口；PR 正文可以使用中文。

独立改动分别提交到指向 `main` 的 PR。只有存在真实代码依赖时才使用线性 stack，依赖 PR 指向所需的前置分支。

按 [PR 模板](.github/pull_request_template.md)说明问题、最终行为、关键取舍和已知限制。涉及应用行为时提供实际操作与观察；涉及 UI 时，在正文内嵌对应提交、场景、语言及外观的截图。媒体使用 PR 附件，本地验收产物放在忽略的 `.artifacts/` 中。“后续工作”只记录超出本次范围的未来方向，当前未完成的验证放在“说明”中。

贡献遵循 [项目许可证](LICENSE)。引入第三方代码时保留其版权、许可与来源证据。合并遵循仓库保护规则，由维护者确认。
