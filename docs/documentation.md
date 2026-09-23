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
`project.extra.docs_assets` 列出页面图片，以及可下载的许可证、工作流示例与 JSON Schema。
构建入口把这些文件按仓库相对路径复制到 `.artifacts/docs/source/`，README 自动成为首页。
唯一的链接转换是将 `LICENSE` 导出为 `LICENSE.txt` 并调整生成页面中的下载链接，
避免预览服务器把无扩展名 URL 当作目录；许可证内容不变。不要手工编辑生成目录。

增加页面时，先在仓库维护正文，再加入 `nav`。页面引用的新图片和下载资源加入
`docs_assets`。代码和工作流配置的链接指向 GitHub 源码，不把源码当站点页面复制。
研究、计划和历史 QA 记录默认不收录；它们不能证明当前功能已实现或发布验收已通过。

界面采用中文导航、系统字体和随系统切换的深浅主题。搜索由浏览器本地执行；
Zensical 当前的搜索对话框仍使用英文，文档内容可用中文搜索。没有配置分析服务。

## 验证与交付

提交前运行 `just docs` 和仓库要求的 `just ci`。更新主题或 Zensical 时还应在
本地预览检查窄窗口、键盘搜索、深浅主题、架构 Mermaid 图，以及 TOML 与 Schema 下载。
搜索至少覆盖「语音识别」「剪贴板」「润色」和 `record_duration`。

CI 通过 `Documentation and change scope` 在 Linux 构建文档、验证 Cloudflare
静态资产配置并运行 prek，
通过 `Release preflight` 在 macOS 执行预检。纯文档修改仍扫描完整 Git 历史和
当前源码中的密钥，但跳过 Swift/MLX 构建与应用测试。
随 App 分发的根目录文档、工作流 Schema、代码、脚本和 CI 配置变化仍运行完整预检。

## Cloudflare 托管

文档站使用 [Cloudflare Workers Static Assets](https://developers.cloudflare.com/workers/static-assets/)，
与 zendev、zrr.dev 使用同一托管方式。Worker 名称为 `rill-docs`，正式域名为
`https://rill.zrr.dev/`。`zensical.toml` 的 `site_url` 决定 canonical URL 与 sitemap；
`wrangler.toml` 管理静态产物目录、域名、目录索引和 404 行为。
无需 Worker 脚本，也不包含 App 运行时或用户数据。

仅在验证或部署 Cloudflare 时需要 Node.js 22+ 和 npm。与 zendev 一样，
仓库不维护 Node.js 文档包；通过 npx 调用固定版本的 Wrangler，
Zensical 继续由 `scripts/docs.py.lock` 锁定。普通 `just docs` 仍只需要 uv 和 just。
从仓库根目录验证：

```sh
just docs
npx --yes --ignore-scripts wrangler@4.136.3 deploy --dry-run
```

npx 将工具缓存到 npm 缓存目录，不在仓库生成 `package.json`、锁文件或
`node_modules/`。上述 dry-run 不需要 Cloudflare 登录，也不会上传资源；
它不能证明线上域名、TLS 或 Git 集成已经生效。

### 自动构建

在 Cloudflare 的 Workers & Pages 中连接 GitHub 仓库 `zrr1999/rill`，
使用 [Workers Builds](https://developers.cloudflare.com/workers/ci-cd/builds/configuration/)
配置以下项目。已有 Worker 时从 **Settings > Build** 连接仓库。

| 设置 | 值 |
| --- | --- |
| Worker 名称 | `rill-docs`，必须与 `wrangler.toml` 一致 |
| 根目录 | `/` |
| 生产分支 | `main` |
| 构建命令 | `python -m pip install uv==0.12.17 && uv run --no-build --locked --script scripts/docs.py build` |
| 部署命令 | `npx --yes --ignore-scripts wrangler@4.136.3 deploy` |
| 非生产分支命令 | `npx --yes --ignore-scripts wrangler@4.136.3 versions upload` |
| 非生产分支构建 | 需要预览的分支均包含托管配置后启用 |
| 构建变量 | `NODE_VERSION=22`、`PYTHON_VERSION=3.13.3`、`SKIP_DEPENDENCY_INSTALL=true` |

上述命令在仓库根目录执行。先构建再上传：Wrangler 的 `assets.directory`
指向 `.artifacts/docs/site/`，
只安装依赖不会生成该目录。生产部署更新正式域名和默认 `workers.dev` 地址；
非生产分支只上传版本并生成预览 URL，不替换正式站点。
Cloudflare Git 集成提供构建状态；GitHub Actions 只做验证，不重复部署。
构建命令显式安装与 GitHub CI 相同版本的 uv，不依赖构建镜像预装它。
跳过平台的自动依赖安装；构建命令使用 Python 脚本锁文件，npx 禁用安装脚本。
Python 固定为构建镜像的默认版本，避免每次安装最新补丁版本。

### 手动部署与验收

在拥有 `zrr.dev` 域名的 Cloudflare 账户中运行 `npx --yes --ignore-scripts wrangler@4.136.3 login`，
用 `npx --yes --ignore-scripts wrangler@4.136.3 whoami` 核对账户。无人值守部署使用
`CLOUDFLARE_API_TOKEN` 和 `CLOUDFLARE_ACCOUNT_ID`；凭据只配置在受保护的
环境中，不写入仓库。Workers Builds 使用 Cloudflare 管理的构建凭据。

```sh
# 在仓库根目录执行
just docs
npx --yes --ignore-scripts wrangler@4.136.3 versions upload  # 上传预览版本
npx --yes --ignore-scripts wrangler@4.136.3 deploy           # 部署到正式域名
```

首次部署会按 `routes` 创建自定义域名；若目标已有 DNS 记录，先核对记录用途，
不要覆盖其他服务。部署后确认 Cloudflare 中的源码分支与 commit，检查 HTTPS 首页、
`/docs/architecture/`、搜索、`/docs/examples/conditional-workflow.toml`、
`/docs/schemas/workflow-v2.schema.json` 和不存在路径的 404。
PR 预览还应确认正式站点的部署版本未改变。
