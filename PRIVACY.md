# Rill Technical Privacy and Data Flow Notice

Last updated: 2026-07-18

This notice describes the data behavior of the current Rill build. It is a technical product disclosure, not a substitute for any formal legal privacy policy that may be required for a future distribution channel.

## Data processed by Rill

Rill processes microphone audio only while a voice capture is active. Depending on the workflow and privacy settings, it may also process selected text, stored clipboard items, scoped vocabulary terms, workflow configuration, delivery results, and content-free diagnostic or run-receipt metadata.

Clipboard monitoring can capture allowed text, images, and copied-file references. Rill skips capture when Secure Input, an unknown focus boundary, a configured sensitive application, a protected pasteboard type, or an explicit capture-exclusion tag requires it to fail closed.

Rill does not operate an analytics or advertising endpoint in this build. Sanitized runtime diagnostics are stored locally and are not uploaded by Rill itself.

## Network destinations

- **sherpa-onnx local speech:** the public build exposes and downloads exactly one local model, Qwen3-ASR 0.6B INT8. When a user prepares it, Rill downloads only the catalog-pinned HTTPS archive from `github.com`; redirects are restricted to `github.com`, `objects.githubusercontent.com`, and `release-assets.githubusercontent.com`. The ephemeral download session uses no cookies, credential storage, or cache, and removes `Authorization` and `Cookie` headers on redirects. Model download sends no microphone audio or recognized text. Rill verifies the exact archive byte count and SHA-256 digest before extraction, rejects unsafe archive entries, verifies the canonical inventory of every installed regular file, and atomically publishes a private model directory. Recognition from that directory then runs on this Mac without sending microphone audio or recognized text to the model hosts. The source tree retains a pinned SenseVoiceSmall INT8 identity only for internal compatibility and future evaluation; the public build does not expose, select, recommend, or download it pending product and legal review.
- **Deepgram cloud speech:** when the user selects Deepgram and the active privacy policy permits the run, Rill sends live or recorded microphone audio and matching recognition terms to Deepgram over encrypted transport. Deepgram returns transcription results. Rill rechecks the current privacy boundary before or during transfer and blocks or stops the run when the boundary becomes restricted.
- **Apple Shortcuts:** a workflow can hand final text to a user-selected Shortcut. The Shortcut, its actions, and any services it contacts are controlled by the user and are outside Rill's ability to inspect.
- **Markdown file output:** a workflow can append final text to a local Markdown path selected by the user. Rill does not upload that file. Appends use a same-directory atomic transaction and reject linked paths, multiply linked files, non-UTF-8 content, and files over 64 MiB.

Third-party services and user-created automations apply their own retention, account, and privacy terms after data reaches them. Rill's local history controls cannot delete data held by those destinations.

## Local storage and retention

Rill stores settings, clipboard state, run history, run receipts, and sanitized diagnostics in the user's Application Support area. Sensitive stored payloads are protected with AES-256-GCM using a root key held in macOS Keychain. Provider credentials are stored in Keychain rather than ordinary settings rows.

Clipboard history and run/diagnostic history default to 30 days. The user can independently select 1 day, 1 week, 30 days, 1 year, or no automatic pruning. Clearing clipboard history preserves items that are still active in a Stack, Queue, or List so pending delivery is not silently destroyed.

Failed-audio recovery is off by default. If explicitly enabled, eligible pre-delivery failures can be stored encrypted for at most 24 hours, with a maximum of 3 entries, 16 MiB per entry, and 32 MiB total. Recovery controls allow individual deletion or clearing all retained failed recordings.

Downloaded trusted speech models remain under `~/Library/Application Support/Rill/Models/sherpa-onnx`. The public build can prepare only the approximately 879 MB Qwen3-ASR 0.6B INT8 archive. It stores one verified extracted tree and removes the temporary download archive after installation; the extracted tree requires additional space. A SenseVoiceSmall tree prepared by an internal development build can remain in the same parent directory, but the public build does not select or download it. This build has no in-app control to reveal or delete those files. Removing the App does not automatically remove the model directories. Model files do not contain the user's recordings or transcripts.

## Your controls

The Settings screen provides controls for the speech provider, cloud confirmation, sensitive applications, Secure Input behavior, history preview exposure, history retention, history clearing, failed-audio recovery, provider credentials, and clipboard capture. Clipboard capture can also be paused or bypassed for the next external copy from the menu bar.

The history preview setting changes what text is exposed to the visual and accessibility UI: Full shows the complete result, Restricted exposes at most 96 summarized characters, and Hidden exposes no result text. It does not delete the underlying local record.

Rill does not yet provide a single "erase everything" command. Use the available history, failed-audio, credential, and clipboard controls for those data categories. Rill does not currently reveal or delete trusted model files in the App. Removing the App alone may not remove Keychain items or downloaded models.

## Product boundaries

Privacy checks are designed to fail closed when settings, focus identity, exact clipboard-item identity, or a processing destination cannot be verified. A preview or explanation is never an execution authorization; the runtime rechecks applicable policy before side effects.

This notice covers Rill's current behavior only. macOS, Deepgram, Apple Shortcuts, user-selected files, and any other software invoked by a Shortcut have their own data practices.

---

# Rill 技术隐私与数据流说明

更新日期：2026-07-18

本文说明当前 Rill 构建的数据行为，是面向产品的技术披露；它不替代未来分发渠道可能要求的正式法律隐私政策。

## Rill 处理的数据

Rill 只在语音采集处于活动状态时处理麦克风音频。根据工作流和隐私设置，它还可能处理选中文本、已保存的剪贴板条目、作用域词汇、工作流配置、投递结果，以及不含正文的诊断与运行收据元数据。

剪贴板监听可捕获策略允许的文本、图片和复制文件引用。遇到 Secure Input、未知焦点边界、已配置的敏感 App、受保护的粘贴板类型或明确的捕获排除标签时，Rill 会采用 fail-closed 策略跳过捕获。

当前构建没有 Rill 自营的分析或广告上报端点。经过净化的运行诊断仅保存在本机，Rill 不会主动上传这些诊断。

## 网络目的地

- **sherpa-onnx 本地语音：**公开构建只暴露和下载一款本地模型：Qwen3-ASR 0.6B INT8。用户准备该模型时，Rill 只会从 `github.com` 下载目录中固定的 HTTPS 归档；重定向仅允许前往 `github.com`、`objects.githubusercontent.com` 和 `release-assets.githubusercontent.com`。临时下载会话不使用 Cookie、凭据存储或缓存，并会在重定向时移除 `Authorization` 与 `Cookie` 请求头。模型下载不会发送麦克风音频或识别文本。Rill 会在解压前校验归档的精确字节数和 SHA-256，拒绝不安全的归档条目，校验每个已安装普通文件的规范清单，并把私有模型目录原子发布；之后从该目录进行的识别完全在本机运行，不会把麦克风音频或识别文本发送给模型 host。源码仍保留固定的 SenseVoiceSmall INT8 身份，仅用于内部兼容和未来评估；在产品与法律审核完成前，公开构建不会暴露、选择、推荐或下载该模型。
- **Deepgram 云端语音：**用户选择 Deepgram 且当前隐私策略允许运行时，Rill 会通过加密传输发送实时或录后麦克风音频及匹配的识别词，并接收转写结果。Rill 会在传输前或传输期间复核隐私边界；边界变为受限时会阻止或停止运行。
- **Apple 快捷指令：**工作流可把最终文本交给用户选择的快捷指令。快捷指令的动作及其访问的服务由用户控制，Rill 无法检查其后续行为。
- **Markdown 文件输出：**工作流可把最终文本追加到用户选择的本地 Markdown 路径；Rill 不会上传该文件。追加使用同目录原子事务，并拒绝链接路径、多重硬链接、非 UTF-8 内容和超过 64 MiB 的文件。

数据到达第三方服务或用户自动化后，适用其自身的留存、账户与隐私条款。Rill 的本地历史控制无法删除这些目的地持有的数据。

## 本地存储与留存

Rill 在用户的 Application Support 区域保存设置、剪贴板状态、运行历史、运行收据和净化后的诊断。敏感持久化正文使用 macOS Keychain 中的根密钥和 AES-256-GCM 保护；provider 凭据保存在 Keychain，而不是普通设置行中。

剪贴板历史和运行/诊断历史默认保留 30 天。用户可以分别选择 1 天、1 周、30 天、1 年或不自动清理。清除剪贴板历史时，仍在 Stack、Queue 或 List 中等待投递的条目会被保留，避免静默破坏待投递内容。

失败录音恢复默认关闭。明确开启后，符合条件的投递前失败录音可加密保留最多 24 小时，最多 3 条、单条 16 MiB、总计 32 MiB；用户可逐条删除或清空全部恢复录音。

已下载的可信语音模型会留在 `~/Library/Application Support/Rill/Models/sherpa-onnx`。公开构建只能准备大小约 879 MB 的 Qwen3-ASR 0.6B INT8 归档；安装后会保存一棵经过校验的解压目录、删除临时下载归档，解压目录还需要更多空间。内部开发构建曾准备的 SenseVoiceSmall 目录可能仍留在同一父目录，但公开构建不会选择或下载它。当前构建没有在 App 内显示位置或删除模型文件的控制；移除 App 也不会自动删除这些模型目录。模型文件不包含用户录音或转写正文。

## 用户控制

设置页提供语音 provider、云端确认、敏感 App、Secure Input 行为、历史预览暴露、历史留存与清除、失败录音恢复、provider 凭据和剪贴板捕获控制。菜单栏还可以暂停剪贴板捕获，或跳过下一次外部复制。

历史预览设置控制视觉界面和辅助功能界面实际接收的文本：完整预览显示全部结果；受限预览最多暴露 96 个摘要字符；隐藏预览不暴露结果正文。该设置不会删除底层本地记录。

Rill 目前没有单一的“清除全部数据”命令。历史、失败录音、凭据和剪贴板数据可使用当前提供的分类控制；Rill 当前不会在 App 内显示或删除可信模型文件。仅移除 App 不一定会删除 Keychain 条目或已下载模型。

## 产品边界

当设置、焦点身份、精确剪贴板条目身份或处理目的地无法验证时，隐私检查会采用 fail-closed 策略。预览或解释不是执行授权；运行时会在副作用发生前重新检查适用策略。

本文只覆盖当前 Rill 行为。macOS、Deepgram、Apple 快捷指令、用户选择的文件，以及快捷指令调用的其他软件均有各自的数据实践。
