# 文档站维护

文档站使用 [Zensical](https://zensical.org/)，直接取用仓库中的 Markdown。
用户指南以根目录 `README.md` 为准；开发、隐私和发布文档的归属见
[贡献指南](../CONTRIBUTING.md#文档归属)。现有文件路径也是仓库技能和 App
离线文档的契约，不应为调整站点导航而迁移正文。

## 构建与预览

安装 `uv` 和 `just` 后运行：

```sh
just docs
just docs-serve
```

`just docs` 使用锁定依赖运行 Zensical 严格构建，检查站内链接和标题锚点。
产物位于 `.artifacts/docs/site/`。它不需要 Xcode、Swift 或 MLX。
`just docs-serve` 在 `http://127.0.0.1:8000` 提供本地预览；修改原始 Markdown
后会自动同步并刷新。可用 `just docs-serve 8001` 更换端口；预览仅监听本机地址，
端口只接受 1–65535 的整数。构建与预览都通过 uv 锁定环境的 Python 启动 Zensical。

`scripts/docs.py` 使用 PEP 723 声明 Zensical 的固定版本，完整依赖由
`scripts/docs.py.lock` 锁定。升级时同时更新版本与锁文件：

```sh
uv lock --script scripts/docs.py
just docs
```

## 收录范围

`zensical.toml` 的 `project.nav` 是页面清单，也是导航的唯一配置。
`project.extra.docs_assets` 列出可下载的许可证、工作流示例与 JSON Schema。
构建入口把这些文件按仓库相对路径复制到 `.artifacts/docs/source/`，README 自动成为首页。
唯一的链接转换是将 `LICENSE` 导出为 `LICENSE.txt` 并调整生成页面中的下载链接，
避免预览服务器把无扩展名 URL 当作目录；许可证内容不变。不要手工编辑生成目录。

增加页面时，先在仓库维护正文，再加入 `nav`。页面引用的新下载资源加入
`docs_assets`。代码和工作流配置的链接指向 GitHub 源码，不把源码当站点页面复制。
研究、计划和历史 QA 记录默认不收录；它们不能证明当前功能已实现或发布验收已通过。

界面采用中文导航、系统字体和随系统切换的深浅主题。搜索由浏览器本地执行；
Zensical 当前的搜索对话框仍使用英文，文档内容可用中文搜索。没有配置分析服务。

## 验证与交付

提交前运行 `just docs` 和仓库要求的 `just ci`。更新主题或 Zensical 时还应在
本地预览检查窄窗口、键盘搜索、深浅主题、架构 Mermaid 图，以及 TOML 与 Schema 下载。
搜索至少覆盖「语音识别」「剪贴板」「润色」和 `record_duration`。

CI 始终在 Linux 构建文档、运行 prek，并保留 `Required CI` 汇总检查。纯文档修改
仍在 macOS 扫描完整 Git 历史和当前源码中的密钥，但跳过 Swift/MLX 构建与应用测试。
随 App 分发的根目录文档、工作流 Schema、代码、脚本和 CI 配置变化仍运行完整预检。

当前提供可部署的静态产物和本地预览，尚未配置线上站点。选定托管位置后再设置
`site_url`、对应源码版本和部署流程。
