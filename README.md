# Rill

Rill 是本地优先的 macOS 语音输入与记录应用。按住 Fn 说话，松开后输入文字；
也可以找回文本、图片和文件记录，在需要时复制或粘贴。

- 本地识别：Apple Silicon 上运行 Qwen3-ASR，模型准备后可离线听写。
- 可选智能整理：使用自己配置的 LLM 服务，保留转写内容和原意。
- 记录检索：关键词、拼音和近似匹配；可选本地语义检索和显式 Jev 比较。
- 可配置工作流：在外部编辑器维护 TOML，组织识别、处理和输出。

[在线使用指南](https://rill.zrr.dev/)与仓库中的指南来自同一份正文。文档描述当前开发版本；
安装包的能力与限制以对应版本说明为准。

## 安装

需要 Apple Silicon Mac 和 macOS 14.0 或更高版本。首次准备模型需要联网，
运行打包后的 App 无需安装 Python、uv 或开发工具。

从 [Releases](https://github.com/zrr1999/rill/releases) 检查可用版本；
没有适用安装包时，可按[贡献指南](https://github.com/zrr1999/rill/blob/main/CONTRIBUTING.md)
自行构建。详细步骤见[安装与首次使用](docs/usage.md)。

## 使用

首次使用：授予麦克风和输入监控权限，准备本地模型，将光标放入目标输入框，
按住 Fn 说话。直接向其他应用输入还需要辅助功能权限。未能投递时先到记录中找回文字。

| 要完成的任务 | 指南 |
| --- | --- |
| 听写、智能整理、语音助手 | [语音输入](docs/voice.md) |
| 找回内容、预览、复制与粘贴 | [记录与搜索](docs/records.md) |
| 调整触发方式、步骤与输出 | [工作流](docs/workflows.md) |
| 修正专有词，管理上下文和记忆 | [词汇与记忆](docs/vocabulary-memory.md) |
| 查快捷键、设置位置、TOML 字段 | [参考](docs/reference.md) |
| Fn、模型、输出或服务出错 | [排查问题](docs/troubleshooting.md) |

## 隐私与数据

剪贴板采集默认关闭，原生 ⌘C / ⌘V 保持不变。语音识别在本机完成。
云端润色、Jev 和上下文功能均有各自的配置与授权要求。

[隐私与数据管理](docs/privacy-data.md)说明如何暂停、撤销和删除；
[PRIVACY.md](PRIVACY.md)提供随 App 分发的数据流说明。

## 升级与卸载

升级前退出 App 并保留需要的数据。删除 App 不会自动清除用户数据、模型缓存和
Keychain 项；清理步骤见[安装指南](docs/usage.md#升级与卸载)。

## 参与开发与反馈

普通问题请到 [GitHub Issues](https://github.com/zrr1999/rill/issues)；
安全问题遵循 [SECURITY.md](SECURITY.md)。开发环境、架构契约和发布流程统一从
[贡献指南](https://github.com/zrr1999/rill/blob/main/CONTRIBUTING.md)进入。

## 许可证

Copyright (C) 2026 Zhan Rongrui and contributors.

原创代码和文档采用 **AGPL-3.0-only**，完整条款见 [LICENSE](LICENSE)。
本程序不提供任何担保，包括适销性或特定用途适用性的默示担保。

第三方代码和模型保留各自许可，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
和 [LOCAL_MODEL_NOTICES.md](LOCAL_MODEL_NOTICES.md)。
