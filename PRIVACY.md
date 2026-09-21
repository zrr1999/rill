# Rill Technical Privacy and Data Flow Notice

Last updated: 2026-09-21

This notice describes the data behavior of the current Rill build. It is a technical product disclosure, not a substitute for any formal legal privacy policy that may be required for a future distribution channel.

## Data processed by Rill

Rill processes microphone audio during explicit voice capture. Wake-word listening is off by default; enabling it keeps a local microphone/VAD/ASR path active until listening is stopped. Model preloading alone does not acquire the microphone. Depending on the workflow and privacy settings, it may also process selected text, stored clipboard items, scoped vocabulary terms, workflow configuration, delivery results, and content-free diagnostic or run-receipt metadata.

Clipboard monitoring can capture allowed text, images, and copied-file references. Rill skips capture when Secure Input, an unknown focus boundary, a configured sensitive application, a protected pasteboard type, or an explicit capture-exclusion tag requires it to fail closed.

Rill does not operate an analytics or advertising endpoint in this build. Sanitized runtime diagnostics are stored locally and are not uploaded by Rill itself.

## Network destinations

- **Local MLX speech and synthesis:** Rill downloads catalog-pinned Qwen ASR, Qwen TTS, and Silero VAD model files from Hugging Face and its download storage when preparing an enabled model. The ASR catalog offers Qwen3-ASR 0.6B 8bit and 1.7B 8bit. Repository revisions, retained file sizes, and SHA-256 digests are checked before publishing a private local model directory. Model downloads send no microphone audio or recognized text. Recognition, wake-phrase matching, and local speech synthesis run on this Mac after preparation; system speech may be used as the documented synthesis fallback.
- **Smart Cleanup with DeepSeek:** uses the shared LLM Provider endpoint, model and Keychain credential. When configured for DeepSeek V4.1 Flash (`deepseek-flash`), rewrite requests disable thinking, have a 5-second budget and reject incomplete output. Audio remains in the local recognition path. Cloud authorization is scoped to the configured model, endpoint and credential.
- **Optional screen context and long-term memory:** both are off by default and require a separate grant for the current provider and workflows. Screen context captures the input display before recording, excludes Rill and enabled sensitive applications, and sends an in-memory JPEG plus optional summaries to an image-capable provider. Capture has a 250 ms budget; each independent summary has 10 seconds. Transcription remains the sole content source. Original images, base64 payloads, complete multimodal requests, and temporary memory summaries are not stored. Encrypted screen summaries may be retained with history. Idle organization sends batches of authorized voice history, explicit corrections, screen observations, and scope identifiers (workflow, application bundle ID, language) to the configured LLM, up to 10 sources / 12 KB per request and 8 background requests per day. Source kinds remain distinct. Long-term memories survive history cleanup; permanent memory deletion excludes their sources from relearning. Provider or privacy changes revoke active context work. Custom endpoints without confirmed image support receive no images.
- **LLM Provider (OpenAI-compatible Responses API):** when the user explicitly selects an enabled built-in or custom voice workflow containing an LLM rewrite step, has supplied a readable API key, confirms cloud text processing when required, and the active privacy policy permits the run, Rill sends the API key, final transcript text, and that workflow step's instruction to the configured Responses API endpoint. Without the optional context features described above, it does not send microphone audio, selected text, clipboard text, application names, or bundle identifiers. The request is non-streaming and sets `store: false`; that request setting is not a promise that the endpoint operator keeps no security, abuse-monitoring, billing, or operational records. The configured endpoint operator's terms and data controls govern data after it reaches the service. Rill cannot inspect or delete provider-side records.
- **Apple Shortcuts:** a workflow can hand final text to a user-selected Shortcut. The Shortcut, its actions, and any services it contacts are controlled by the user and are outside Rill's ability to inspect.
- **Markdown file output:** a workflow can append final text to a local Markdown path selected by the user. Rill does not upload that file. Appends use a same-directory atomic transaction and reject linked paths, multiply linked files, non-UTF-8 content, and files over 64 MiB.

Third-party services and user-created automations apply their own retention, account, and privacy terms after data reaches them. Rill's local history controls cannot delete data held by those destinations.

## Local storage and retention

Rill stores settings, clipboard state, run history, run receipts, and sanitized diagnostics in the user's Application Support area. Sensitive stored payloads are protected with AES-256-GCM using a root key held in macOS Keychain. The shared LLM Provider credential is stored in Keychain rather than ordinary settings rows. Diagnostics record only allowlisted provider, stage, result category, duration, and coarse status-code metadata; they do not record the API key, request text, response text, prompt, or OpenAI error body.

Voice activity history also retains the recognized text and each executed text-processing result, including vocabulary replacement and LLM cleanup. Completed steps remain available when a later step fails. These snapshots use the same encrypted history storage and retention controls; they are not added to diagnostic exports. LLM steps also retain API-reported input, output, and total token counts when available; missing counts are not estimated. Selected recognition and text-processing steps retain measured milliseconds in encrypted history and content-free run receipts, including failures, cancellations, and transcript fallbacks. The workflow step option `record_duration` defaults to enabled for recognition and LLM calls and disabled for other steps. Receipts separately retain captured audio length and output-action elapsed milliseconds; this does not retain audio samples or recording start times. Timing covers the recognition executor or transformer call, including request preparation and response parsing, but excludes recording, queueing, candidate selection, and delivery. Candidate selection can record its own wait when explicitly enabled. Older entries cannot reconstruct intermediate results, token counts, or exact durations that were not recorded; text-only input has no recognition duration.

Clipboard history and run/diagnostic history default to 30 days. The user can independently select 1 day, 1 week, 30 days, 1 year, or no automatic pruning. Automatic clipboard pruning preserves pinned items. Explicitly clearing clipboard history removes pinned history but preserves items that are still active in a Stack, Queue, or List so pending delivery is not silently destroyed.

Failed-audio recovery is off by default. If explicitly enabled, eligible pre-delivery failures can be stored encrypted for at most 24 hours, with a maximum of 3 entries, 16 MiB per entry, and 32 MiB total. Recovery controls allow individual deletion or clearing all retained failed recordings.

Downloaded ASR models remain under `~/Library/Application Support/Rill/Models/mlx-audio-swift`; synthesis models and Hugging Face download caches use their own Rill-managed model/cache directories. The ASR catalog currently requires approximately 1.01 GB for the 0.6B model or 2.46 GB for the 1.7B model, plus temporary download/cache space. Old sherpa-onnx directories can remain after an upgrade but are not the current recognition runtime. Removing the App does not automatically remove downloaded models or caches. Model weights do not contain the user's recordings or transcripts.

## Your controls

When cloud confirmation is enabled, the default action is **Allow and Remember**. Rill saves that authorization across restarts and skips later prompts for the same workflow and provider configuration. **Allow Once** applies only to the current run. You can revoke saved authorizations in Settings > Privacy; changing the workflow or provider configuration requires confirmation again.

The Settings screen provides controls for the speech provider, OpenAI API key, Responses API Base URL and model ID, explicit configuration verification, cloud confirmation, sensitive applications, Secure Input behavior, history preview exposure, history retention, history clearing, failed-audio recovery, provider credentials, and clipboard capture. Verification sends the API key and fixed non-user content to the configured endpoint and does not record the response text. Clipboard capture can also be paused or bypassed for the next external copy from the menu bar.

The history preview setting changes what text is exposed to the visual and accessibility UI: Full shows the complete result, Restricted exposes at most 96 summarized characters per result or processing step, and Hidden exposes no result text. It does not delete the underlying local record.

Rill does not yet provide a single "erase everything" command. Use the available history, failed-audio, credential, and clipboard controls for those data categories. Rill does not currently reveal or delete trusted model files in the App. Removing the App alone may not remove Keychain items or downloaded models.

## Product boundaries

Privacy checks are designed to fail closed when settings, focus identity, exact clipboard-item identity, or a processing destination cannot be verified. A preview or explanation is never an execution authorization; the runtime rechecks applicable policy before side effects.

For captured speech or explicitly supplied text, recoverable rewrite failures (network errors, rate limiting, timeout, incomplete or invalid results) may deliver the complete text from before the rewrite, under the same output and privacy policy. Activity reports skipped cleanup. Partial cloud output is rejected. Cancellation, privacy restrictions, credential/configuration failures, authentication failures and refusal stop delivery; assistant runs never fall back to echoing the request.

This notice covers Rill's current behavior only. macOS, DeepSeek, OpenAI, Apple Shortcuts, user-selected files, and any other software invoked by a Shortcut have their own data practices.

---

# Rill 技术隐私与数据流说明

更新日期：2026-09-19

本文说明当前 Rill 构建的数据行为，是面向产品的技术披露；它不替代未来分发渠道可能要求的正式法律隐私政策。

## Rill 处理的数据

Rill 在用户发起语音采集时处理麦克风音频。唤醒词监听默认关闭；开启后，本地麦克风、VAD 和 ASR 路径会持续工作，直到用户停止监听。仅预加载模型不会占用麦克风。根据工作流和隐私设置，它还可能处理选中文本、已保存的剪贴板条目、作用域词汇、工作流配置、投递结果，以及不含正文的诊断与运行收据元数据。

剪贴板监听可捕获策略允许的文本、图片和复制文件引用。遇到 Secure Input、未知焦点边界、已配置的敏感 App、受保护的粘贴板类型或明确的捕获排除标签时，Rill 会采用 fail-closed 策略跳过捕获。

当前构建没有 Rill 自营的分析或广告上报端点。经过净化的运行诊断仅保存在本机，Rill 不会主动上传这些诊断。

## 网络目的地

- **MLX 本地语音识别与合成：**准备已启用的模型时，Rill 从 Hugging Face 及其下载存储获取目录中固定版本的 Qwen ASR、Qwen TTS 和 Silero VAD 文件。ASR 目录提供 Qwen3-ASR 0.6B 8bit 和 1.7B 8bit。程序在发布私有本地模型目录前核对仓库 revision、保留文件大小及 SHA-256。模型下载不发送麦克风音频或识别文本。准备完成后，识别、唤醒词匹配和本地语音合成在本机运行；合成路径可按产品说明回退到系统语音。
- **使用 DeepSeek 的智能整理：**复用统一 LLM Provider 的地址、模型和 Keychain 凭据。配置 DeepSeek V4.1 Flash（`deepseek-flash`）后，润色请求关闭思考，预算为 5 秒，不接受截断结果。音频继续在本地识别，云端授权绑定所配置的模型、地址和凭据。
- **可选屏幕上下文与长期记忆：**两者默认关闭，需为当前服务与工作流单独授权。屏幕上下文在录音前采集输入所在显示器，排除 Rill 和已启用的敏感应用，将内存中的 JPEG 与可选摘要发给具备图片能力的服务。截图预算 250 毫秒，两个独立摘要各限 10 秒；转写始终是唯一内容主体。原图、base64、完整图文请求和临时记忆摘要不保存；屏幕摘要可加密保存在历史中。空闲整理会将已授权语音历史、明确纠正、屏幕观察，以及工作流、应用 bundle ID 和语言等范围信息分批发送给已配置 LLM，每次最多 10 条来源、12 KB，每天最多 8 次后台请求。来源类型分别标记；长期记忆独立于历史清理留存，永久删除记忆后其来源不再参与学习。服务或隐私配置变化会撤销当前上下文任务；未确认图片能力的自定义地址不会收到图片。
- **LLM Provider（OpenAI-compatible Responses API）：**只有用户主动选择已启用、包含大模型改写步骤的内置或自定义语音工作流，提供的 API Key 可读取，在需要时确认云端文本处理且当前隐私策略允许运行，Rill 才会把 API Key、最终转写正文和对应工作流步骤指令发送到已配置的 Responses API 地址。未开启上述可选上下文功能时，请求不包含麦克风音频、选中文本、剪贴板正文、App 名或 bundle ID。请求采用非流式并设置 `store: false`；该请求参数不等于地址运营方不保留任何安全、滥用监测、计费或运行记录。数据到达服务后适用地址运营方的服务条款和数据控制，Rill 无法检查或删除 provider 侧记录。
- **Apple 快捷指令：**工作流可把最终文本交给用户选择的快捷指令。快捷指令的动作及其访问的服务由用户控制，Rill 无法检查其后续行为。
- **Markdown 文件输出：**工作流可把最终文本追加到用户选择的本地 Markdown 路径；Rill 不会上传该文件。追加使用同目录原子事务，并拒绝链接路径、多重硬链接、非 UTF-8 内容和超过 64 MiB 的文件。

数据到达第三方服务或用户自动化后，适用其自身的留存、账户与隐私条款。Rill 的本地历史控制无法删除这些目的地持有的数据。

## 本地存储与留存

Rill 在用户的 Application Support 区域保存设置、剪贴板状态、运行历史、运行收据和净化后的诊断。敏感持久化正文使用 macOS Keychain 中的根密钥和 AES-256-GCM 保护；统一 LLM Provider 的 API Key 保存在 Keychain，而不是普通设置行中。诊断只记录白名单内的 provider、阶段、结果分类、耗时和粗粒度状态码信息，不记录 API Key、请求正文、响应正文、prompt 或服务端错误正文。

语音活动历史还会保留识别文本及各个实际执行步骤的结果，包括词替换和大模型润色；后续步骤失败时，已完成步骤的文本仍可查看。这些快照沿用加密历史存储和留存控制，不进入诊断导出。大模型步骤同时保留接口实际返回的输入、输出和总 token 用量，不估算缺失的计数。选中的识别及文本处理步骤还会在加密历史和不含正文的运行收据中保存毫秒级耗时，包括失败、取消和转写回退。步骤选项 `record_duration` 对识别和大模型调用默认开启，其他步骤默认关闭；运行收据另行记录音频长度和输出动作耗时，不保存音频样本或录音开始时间。计时覆盖识别执行器或文本处理器调用中的请求准备、处理和响应解析，不包含录音、排队、候选选择和投递；候选选择可单独开启等待耗时记录。旧记录未保存的中间结果、token 用量或精确耗时无法补回；直接处理文本时不生成识别耗时。

剪贴板历史和运行/诊断历史默认保留 30 天。用户可以分别选择 1 天、1 周、30 天、1 年或不自动清理。自动清理会保留已置顶条目；用户显式清除剪贴板历史时会删除已置顶历史，但仍保留 Stack、Queue 或 List 中等待投递的条目，避免静默破坏待投递内容。

失败录音恢复默认关闭。明确开启后，符合条件的投递前失败录音可加密保留最多 24 小时，最多 3 条、单条 16 MiB、总计 32 MiB；用户可逐条删除或清空全部恢复录音。

ASR 模型保存在 `~/Library/Application Support/Rill/Models/mlx-audio-swift`；语音合成模型和 Hugging Face 下载缓存使用各自的 Rill 模型／缓存目录。当前 ASR 目录中的 0.6B 模型约需 1.01 GB，1.7B 模型约需 2.46 GB，下载时还需要临时文件和缓存空间。升级后旧 sherpa-onnx 目录可能仍然存在，但当前识别不使用它。移除 App 不会自动删除模型和缓存；模型权重不包含用户录音或转写正文。

## 用户控制

开启云端确认时，弹窗默认操作为**允许并记住**。Rill 会在重启后保留授权，同一工作流和服务配置下不再重复询问；**仅这一次**只授权当前运行。可在“设置 > 隐私”中撤销已保存的授权；更改工作流或服务配置后需要重新确认。

设置页提供语音 provider、OpenAI API Key、Responses API Base URL 与模型 ID、显式配置验证、云端确认、敏感 App、Secure Input 行为、历史预览暴露、历史留存与清除、失败录音恢复、provider 凭据和剪贴板捕获控制。验证会把 API Key 与固定的非用户内容发送到已配置地址，且不记录响应正文。菜单栏还可以暂停剪贴板捕获，或跳过下一次外部复制。

历史预览设置控制视觉界面和辅助功能界面实际接收的文本：完整预览显示全部结果；受限预览对每个结果或处理步骤最多显示 96 个摘要字符；隐藏预览不暴露结果正文。该设置不会删除底层本地记录。

Rill 目前没有单一的“清除全部数据”命令。历史、失败录音、凭据和剪贴板数据可使用当前提供的分类控制；Rill 当前不会在 App 内显示或删除可信模型文件。仅移除 App 不一定会删除 Keychain 条目或已下载模型。

## 产品边界

当设置、焦点身份、精确剪贴板条目身份或处理目的地无法验证时，隐私检查会采用 fail-closed 策略。预览或解释不是执行授权；运行时会在副作用发生前重新检查适用策略。

对于已录制语音或主动提供的文本，网络错误、限流、超时、不完整或无效结果等可恢复的改写失败，可以在相同输出与隐私策略下投递改写前的完整文本，并在活动中提示未完成整理。云端部分结果不会被投递。取消、隐私阻止、凭据或配置错误、认证失败及拒绝会停止投递；语音助手不会回退为复述请求。

本文只覆盖当前 Rill 行为。macOS、DeepSeek、OpenAI、Apple 快捷指令、用户选择的文件，以及快捷指令调用的其他软件均有各自的数据实践。
