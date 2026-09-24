# Rill 同类工具研究与改进方向

> 历史材料，保留原始研究、计划或验收范围；不代表当前功能或发布结论。
> 归档基线：main `9e786a6`。当前使用说明见 [用户指南](../../usage.md)。

> 初次调研：2026-06-17
> 最近刷新：2026-07-16
> 目标：寻找同类工具，学习可复用经验，明确 Rill 下一步改善重点。

## 1. 定位结论

Rill 不应只被定义成「又一个语音输入工具」。更准确的定位是：

> **本地优先的 macOS 语音输入 + 剪贴板路由 + 可观察工作流工作站。**

同类产品大多只覆盖其中一部分：

- Wispr Flow / Superwhisper / Type4Me：强在语音输入、AI 润色、词汇/模式配置。
- MacWhisper / VoiceInk / open-wispr：强在本地转写、隐私、模型控制或文件转写。
- Raycast / Maccy / PastePal / Paste：强在剪贴板历史、搜索、收藏、跨设备。
- Keyboard Maestro / Alfred / Raycast：强在桌面自动化、快捷触发和扩展生态。

Rill 的差异化机会在于把这些能力用一个可解释的数据流串起来：**声音 → 可纠正文本 → 剪贴板组路由 → 可观察工作流 → 输出动作**。组事件动作自动化仍是未开放的路线图能力；当前只交付 content-free 调度决策、typed run receipt 与固定 trigger/skip 原因，不把它描述成可执行功能。

## 2. 主要竞品/参考工具

| 工具 | 类型 | 可学习点 | Rill 启示 |
|---|---|---|---|
| Wispr Flow | 云端 AI dictation | 任意输入框、上下文感知、个人词典/替换规则、AI command | 需要尽快补「词典/映射词」和「基于上下文的润色变量」 |
| Superwhisper | AI dictation | 离线可用、模式系统、自定义 AI instructions、主动使用 selected text / clipboard / app context | 把工作流模板做成用户可理解的「模式」而非只暴露底层节点 |
| Type4Me | macOS 语音输入 | SenseVoice + Qwen3-ASR 二次校准、多云端 ASR、热词/映射词、Ollama、本地/云端双版本 | 当前 README 已列出的 roadmap 优先级是对的；尤其热词、映射词、Prompt 变量应前置 |
| MacWhisper | 文件转写 + dictation | 本地 Whisper/Parakeet/云端模型选择，AI action，一键发到 Zapier/Make/n8n/webhook/Obsidian | Rill 工作流可增加 webhook/本地文件/Obsidian 类输出动作，但不要先做重型文件编辑器 |
| VoiceInk / open-wispr / Whispur / Fisper | 开源/本地 dictation | 极简 hold-to-talk、隐私叙事、whisper.cpp/Metal、BYOK、多引擎 | Rill 需要更清楚地讲「本地优先」和失败时的 fallback 行为 |
| Raycast Clipboard | 启动器内置剪贴板 | 本地加密、忽略密码管理器/敏感内容、搜索/置顶、多类型支持 | Rill 的剪贴板历史要补敏感 App 排除、置顶/收藏、清晰隐私设置 |
| PastePal / Paste / Maccy | 剪贴板管理 | collections、跨设备、轻量搜索、快速键盘流 | Rill 的「组」概念要用更日常的 collections/routes 语言解释 |
| Keyboard Maestro | 桌面自动化 | 剪贴板历史、Clipboard Filter、宏触发器、多步骤动作、调试心智 | Rill 工作流编辑器需要可观测性：运行历史、dry-run、事件日志、失败原因 |

## 3. 关键经验

### 3.1 用户看到的是「模式」，不是引擎

竞品普遍把复杂能力包装成 Mode / Command / Preset：

- Superwhisper 用 built-in modes 和 custom mode 表达「转写后如何处理」。
- Type4Me 把润色、翻译、Prompt 优化做成可选模板。
- Wispr Flow 强调自然说话后自动变成可发送文本。

Rill 底层已有 workflow 抽象，但 UI/文档不应只讲「事件、条件、动作」。建议提供上层模式：

1. 原样输入：只转写不润色。
2. 干净输入：去口头禅、修标点。
3. 正式写作：结构化、语气更正式。
4. 翻译输入：语音 → 目标语言。
5. 命令模式：使用 `{text}` / `{selected}` / `{clipboard}` / `{app}` 变量。

### 3.2 词汇管理是语音输入产品的核心，不是锦上添花

Wispr Flow 的 dictionary、Superwhisper 的 custom vocabulary、Type4Me 的热词/映射词都说明：用户对专业术语、人名、项目名的失败容忍度很低。

建议 Rill 把 roadmap 中的「热词/映射词」提升为 P0，并分成两层：

- **热词**：传给支持该能力的 ASR provider，影响识别。
- **映射词**：识别后规则替换，provider 无关，可解释、可测试、可导入导出。

### 3.3 上下文变量比「接一个 LLM」更重要

竞品强调 app context、selected text、clipboard context。Rill 已经有剪贴板和焦点追踪，适合把上下文做成稳定变量，而不是把所有信息隐式塞给 LLM。

建议先支持这些变量：

- `{text}`：本次识别结果。
- `{selected}`：当前选中文本；拿不到时为空并记录原因。
- `{clipboard}`：当前组候选或系统剪贴板。
- `{app}`：前台 App 名称/bundle id。
- `{group}`：当前剪贴板组。

### 3.4 自动化能力要可观测，否则用户不敢开

Keyboard Maestro 的长期价值不只是动作多，而是用户能理解「哪个 trigger 触发了什么」。Rill 的组事件工作流如果默认自动润色，必须避免黑盒感。

截至 2026-07-13，生产版本仍禁用组事件动作。可观察的调度前置层已经交付：DeliveryStack 只向 Runtime scheduler 和 EventBus 提交无正文、绑定 exact item version 的 descriptor；有界 FIFO 以背压等待而不是丢事件，event ID 去重和稳定 workflow 顺序负责调度；严格 Core parser 拒绝缺失或非法的 source group、布尔值与 action。transient lineage 以 root、唯一有序 workflow path 与 8-hop cap 阻断重入，且不进入持久收据或诊断。路由候选会先写入 durable `skipped` receipt，再发布固定 `matched` / `skipped` / `loop-prevented` diagnostics；收据不可用时只报告固定 storage-unavailable，不提前声称判定成功。执行能力与用户启用状态分离，当前生产能力明确为 unsupported，不伪装成用户停用。退出时先停生产者，再等待 DeliveryStack 摘除写屏障，最后排空已接纳判定。`polishGenerated` 与一般 capture exclusion 分别显示为 `loopPrevented` 和 `excludedByCaptureTag`，History 及辅助功能标签提供具体双语原因。

仍需在开放动作前补齐：

- workflow-revision-bound 持久 grant、one-shot group action lease 与副作用前最终复核；
- 本地组动作的幂等与持久化提交语义；外部副作用还需要 durable outbox；
- 浮动 NSPanel 的全局双击 Command、attached-sheet 和 VoiceOver 实机验收；最新打包 App 已通过 Dashboard 打开、失焦 auto-hide、Esc 关闭/焦点恢复与搜索键盘零穿透检查，dry-run 产品 UI 已交付但入口在完整验收前保持关闭；
- 一键暂停某个工作流/某个组事件。

### 3.5 不要把 Rill 做成所有竞品的合集

从 Unix-style 设计看，Rill 的核心机制应保持小而清晰：

```text
recognizer -> text candidate -> group store -> event bus -> workflow action
```

文件转写、跨设备同步、复杂宏系统、完整 launcher 能力都可以后置。优先把上面这条链路做可靠、可解释、可扩展。

## 4. 初始产品优先级（2026-06-17 历史快照）

本节保留初次调研时的决策输入，不代表当前缺口；最新实现事实、当轮决策与下一步分别以第 7 节和第 9 节为准。

### P0：直接提升日常语音输入成功率

1. **热词/映射词系统**
   - 先实现 provider-independent 映射词；再给支持热词的 ASR provider 加 adapter。
   - 支持 app/group scoped rules，避免全局误替换。
2. **Prompt 变量与模式模板**
   - 至少支持 `{text}` / `{selected}` / `{clipboard}` / `{app}` / `{group}`。
   - 把内置工作流包装成「原样输入 / 干净输入 / 正式写作 / 翻译」。
3. **自动化可观测性**
   - 工作流运行日志、失败原因、防循环原因、手动重放。
4. **隐私与安全设置**
   - 敏感 App 排除（密码管理器、银行、2FA）。
   - 明确本地/云端路径提示：本次音频/文本是否离开本机。

### P1：扩展 provider 和输出生态，但保持可替换

1. **本地 ASR benchmark**
   - 比较 WhisperKit、whisper.cpp、SenseVoice/Qwen3-ASR、Parakeet/FluidAudio 的延迟、准确率、包体和 Swift 集成成本。
2. **更多云端 ASR adapter**
   - 优先 Soniox/火山豆包，原因是 Type4Me 用户反馈和中文实时能力值得验证。
3. **输出动作**
   - webhook、append-to-file/Obsidian、Shortcuts、n8n/Make/Zapier 兼容。

### P2：谨慎考虑的扩展

- 文件转写编辑器：MacWhisper 已经很强，除非 Rill 要服务「语音历史再加工」，否则不应先做。
- 跨设备同步：Paste/PastePal/Raycast 已有成熟心智，Rill 需要先证明组路由的本地价值。
- 完整宏系统：Keyboard Maestro 已经是强势工具，Rill 只需做好语音和剪贴板事件相关的窄自动化。

## 5. 初始近期任务（2026-06-17 历史快照）

以下任务保留为演进记录；已完成、改写或暂缓的状态以第 7 节和第 9 节为准。

1. 写一页 `docs/user-modes.md`，用用户语言定义内置模式和变量，而不是只描述底层 workflow 节点。
2. 设计 `VocabularyRule` / `PromptVariableContext` 两个 core model，并先用纯函数测试覆盖替换规则。
3. 给 workflow runtime 增加 `WorkflowRunRecord`，记录事件、输入、动作结果、错误和耗时。
4. 给设置页加「敏感 App 排除」和「云端 provider 使用提示」。
5. 做一个 30 分钟 dogfood benchmark：同一批中英混合短句，用 Rill 的 sherpa/MLX 本地路径及 Type4Me、Superwhisper 或 Wispr Flow 记录延迟与编辑次数。

## 6. 2026-07-10 竞品雷达刷新

本轮把观察对象收敛为三组。只把仍有活跃产品更新、官方文档或可核验源码的项目作为决策依据；功能相似但停更、来源不清或尚未成熟的项目只进入观察名单。

### 6.1 语音输入产品标杆

| 产品 | 当前最值得跟踪的能力 | 不应直接复制的部分 |
|---|---|---|
| Wispr Flow | Command Mode、纠正后自动学习、失败重试、按 App 风格 | 云端订阅与跨设备同步不是 Rill 当前优势 |
| Superwhisper | 显式上下文变量、可配置 Mode、本地/云端模型选择、历史重处理 | 不追逐大量模型和复杂 Mode 选项 |
| Willow | 选中文本语音改写、Scribe、风格记忆、个人词典 | 不先做不可解释的自动风格学习 |
| Aqua Voice | 屏幕/文件上下文、Dictionary + Replacement + Instructions、低延迟交互 | 不先引入屏幕 OCR 权限面 |
| MacWhisper | 本地文件/会议转写、App-specific prompt、replacement 导入导出 | 不把 Rill 扩成重型文件转写编辑器 |
| Monologue / Typeless | 语音动作、按 App 风格、纠正学习、跨设备产品体验 | 不以云端“代写助手”取代可观察工作流 |

2026-07-12 再核对后的边界更清楚：Wispr Flow 的 Context Awareness 默认开启，会读取光标附近文字、App 元数据和部分代码上下文，并把相关上下文随云端听写发送；Privacy Mode 与 Private Cloud Sync 只分别控制训练和服务端存储，转写本身仍在云端。Superwhisper 则允许语音模型和后处理模型分别选择本地或云端，Custom / Super Mode 可显式启用 App、选区和近期剪贴板上下文，并支持从历史重新处理录音。Rill 不应复制默认隐式取上下文，而应继续让输入类别、目的地和离机判定在运行前解释与运行时授权中保持一致。

### 6.2 开源工程基线

| 项目 | 为什么跟踪 | 对 Rill 的直接启示 |
|---|---|---|
| Handy | 本地优先、低门槛、流式模型；Issues 暴露“先转写、后持久化”可能丢失长录音，并讨论失败恢复 | 把它作为可靠性问题与设计证据，不把尚未核实发布的 Issue 方案写成已上线能力 |
| VoiceInk | 多本地/云端 provider、OpenAI-compatible、上下文与 Mode | 明确区分 LLM vocabulary 与确定性 replacement |
| FluidVoice | 原生 Swift、Parakeet/Nemotron、纠错采集流程 | 先 benchmark，再决定是否引入新本地模型依赖 |
| Type4Me | ASR 热词、片段替换、Prompt 变量、多触发模式 | provider 能力限制必须成为显式合同 |
| open-wispr | 极简本地 whisper.cpp + Metal、PTT/Toggle | 保持“原样听写”主路径极简 |
| OpenWhispr | 会议、Notes、MCP、同步等完整产品面 | 作为范围上界，而不是近期功能清单 |

### 6.3 剪贴板与自动化基线

- Raycast、Maccy、Paste、PastePal 已把敏感内容过滤、App 排除、暂停捕获和搜索做成基础能力。
- CleanClip 的“跟随前台 App”最接近 Rill 的组路由心智，但没有把语音来源、Stack/Queue/List 语义、可观察工作流和运行解释串成同一条链。
- Alfred 把 trigger 明确建模为工作流激活源，Debugger 会显示对象输出并高亮执行节点；Keyboard Maestro 同样把 macro/group activation 与 action 分开，并提供可暂停、单步、取消和查看日志的 Macro Debugger。共同启示是：自动化一旦变强，运行历史、固定原因和 debugger 就会从高级功能变成可信使用的前提。
- Keyboard Maestro 的 Clipboard Changed 文档说明每次剪贴板变化都会触发；本轮核对的官方页面没有给出通用防循环保证。因此 Rill 没有把“排除某个 tag”当成完整 lineage，而是已用 transient workflow path 与 8-hop cap 阻断重入；未来 group action 必须显式推进该 lineage，不能静默重建 root。
- Raycast 当前 Clipboard History 文档把保留期、禁用 App、手动动作和 paste sequence 放在同一产品面，Troubleshooting 另提供日志路径；Rill 应继续把数据控制和运行解释做成用户功能，而不是只留开发日志。
- Raycast v2 还把保留原始 pasteboard 格式、`Paste as…`、多内容单条目、条目重命名和 Ask Clipboard 放进同一入口。它提高了通用剪贴板工具的交互基线，但不改变 Rill 的近期排序：先验证 App / 组路由与 Stack / Queue / List 的真实复用价值，再用搜索复用率和格式错误率决定是否加入置顶、重命名或格式选择，不能只按竞品功能数量扩张。
- Apple Shortcuts 以顺序 action、权限提示、取消和显式 If/Repeat 控制流为基本心智；Rill 当前只做窄剪贴板调度，不应在缺少这些执行控制与恢复语义时扩成通用宏系统。
- Paste MCP 值得长期关注；Rill 若开放 AI context，必须先受 group、privacy decision 和 workflow scope 约束，并留下访问记录。

### 6.4 App Icon 视觉领地

2026-07-14 复核了五个相邻产品的官方图标资产：

| 产品 | 已占据的核心符号 | Rill 主动避开的重合 |
|---|---|---|
| [Wispr Flow](https://wisprflow.ai/media-kit) | 黑底暖白竖向波形 | 均衡器和对称波形 |
| [Superwhisper](https://ai.superwhisper.com/assets) | 黑底抽象 Möbius 环 | 泛 AI 环形符号 |
| [MacWhisper](https://apps.apple.com/us/app/whisper-transcription/id1668083311?platform=mac) | 蓝底白色麦克风 | 麦克风与蓝白语音工具套路 |
| [Paste](https://apps.apple.com/us/app/paste-limitless-clipboard/id967805235) | 橙底回转箭头 `P` | 剪贴板回转箭头 |
| [Raycast](https://www.raycast.com/blog/launch-week-summary) | 黑红键帽与射线 | 键帽、图标内文字和黑红发光边框 |

因此生产图标采用原创的 **Routed Voice Cursor**：暖象牙语音脉冲和工作流
lane 汇入珊瑚路由节点，再解析成文字插入光标；深墨绿底表达本地、私密和
可靠。它直接表现 Rill 的“声音 → 路由 → 输入”差异，而不是再叠加波形、
麦克风或剪贴板卡片。受审 master、prompt、SHA-256、16/32 px 光学调整和传统
ICNS 兼容策略记录在 `Resources/AppIcon/README.md`。

### 6.5 语音主循环刷新（2026-07-16）

本轮只采用官方产品资料，并把对比重点从“模型数量”改为用户每次听写都能
感知的主循环。Wispr Flow 的 [快捷键](https://docs.wisprflow.ai/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts)、
[上下文](https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness)、
[词典](https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary)
和 [失败重试](https://docs.wisprflow.ai/articles/2503460374-retry-failed-transcriptions)，
Superwhisper 的 [模式快捷键](https://superwhisper.com/docs/get-started/settings-shortcuts)、
[本地/云模型](https://superwhisper.com/models) 与
[历史重处理](https://superwhisper.com/docs/get-started/transcribe-history)，以及 VoiceInk 的
[模式](https://tryvoiceink.com/docs/mode-settings)、
[模型](https://tryvoiceink.com/docs/ai-models) 和
[同音频重试](https://tryvoiceink.com/docs/shortcuts) 共同说明：模型目录不是产品
完成度，可靠启停、即时状态、术语命中和不重说恢复才是。

因此近期语音改进按以下顺序收敛：

1. 持久化为本地引擎时始终准备当前固定目录模型；`prewarm` 只控制额外 native
   recognizer 预热，不允许第一次热键只触发后台加载并丢掉本次输入。
2. 空白或纯噪声识别是 typed `noSpeech` 失败：不进入转换、输出动作或失败
   录音恢复，并给出可立即重试的双语提示。
3. 将现有作用域 hotword 通过 Qwen3-ASR 的有界 hotword 输入接入本地录后
   解码；术语不进入诊断或 metadata，仍保留确定性 mapping 作为后处理。
4. 在继续增加模型前记录冷/热启动、最终延迟、字词错误率和专业词通过率；
   本地 batch 路径不虚构首个 partial，并按普通话、粤语、英语分别给出推荐。
5. 后续再评估 Hybrid Fn 与按 App 自动选择语音配置；自然语义清稿只有在
   保留名字、数字、代码和原意的可测合同成立后才接入生产 transformer。

本轮不引入默认剪贴板上下文、屏幕 OCR、会议编辑器或更多常驻服务。用户关闭
剪贴板捕获后，语音优化不得读取剪贴板或把该开关隐式打开。

## 7. 能力命名与当前产品事实

竞品中的“词典”至少包含四种不同机制，Rill 不应继续混称：

1. **ASR hints / keyterms**：在识别阶段影响候选，能力和限制由 provider 决定。
2. **本地模型 hotword 输入**：当前只在 Qwen3-ASR 路径提供，不保证命中。
3. **LLM vocabulary context**：只影响识别后的生成或润色。
4. **确定性 mapping**：识别后执行可解释、可测试的文本替换。

截至本次刷新，Rill 的真实状态是：

- `VocabularyRule`、作用域和设置 UI 已存在；本轮已把 **mapping** 接入 `SessionCoordinator`，在后处理之前按 App、目标剪贴板组和语言执行。
- **hotword** 已通过显式 provider 能力合同接入生产路径：retired cloud ASR retired cloud model 的实时与录后识别会收到按 App、目标剪贴板组和语言筛选的 keyterms；本地 Qwen3-ASR 路径会去空白、去重、拒绝控制字符/逗号并执行数量、单项长度和总字节上限后传给 sherpa-onnx。两者都是非确定性识别提示，不保证命中；内部 SenseVoice 身份与其他不支持路径明确忽略，而不是伪装生效。
- 一步纠错闭环已进入真实历史路径：运行时只保留候选消歧后、mapping/transform 前的识别文本和最小 App/组/语言上下文；用户必须编辑文本、显式选择 mapping 或 hotword，并逐项确认缺失作用域是否可按“任意”处理后才能保存。冲突规则不会被覆盖，剪贴板重放不会伪装成学习样本，关闭历史预览时不提供纠错入口。
- `PromptVariableRenderer` 已有纯模型和渲染逻辑，但尚未进入生产变换链；未配置真实 provider 的 LLM / Snippet / 组事件动作已从生产注册与新建入口移除。
- 内建目录只保留 `Speech Recognition` 与 `Voice Assistant`；前者是 Fn → STT → 个人词库热词/替换 → 文字输出，后者是默认停用的 Wake Word → STT → LLM → TTS。TOML 是唯一事实源，JSON 与 Swift fallback 由同一生成器产生并受 `--check` 保护。
- `PrivacyPolicy` 已进入剪贴板、录音、非音频工作流和剪贴板重放的真实运行路径；密码管理器 pasteboard 标记、敏感 App、Secure Input、未知焦点、排除工作流捕获的条目标签与云端目的地都会在载荷读取、组件调用或外发前判定。Secure Input 与未知焦点会遮蔽选区和剪贴板，排除标签会遮蔽工作流可见的剪贴板正文；未知焦点下的云端路径额外阻断。
- Replay/Replace 不再只用授权时的前台 App 判断隐私：DeliveryStack 将 exact item generation/revision 与 transient source App identity 一起原子解析，Runtime 在任何云确认前先评估来源、目标授权后再复核来源；来源规则禁止 cloud/workflow processing 时不能通过切换前台 App 绕过。source identity 不进入 dry-run 收据、scheduler descriptor 或 durable diagnostics。
- 隐私预览与真实执行共用 closed destination classifier，不由 UI 猜测本地/云端路径。Runtime 只公开接受 opaque `AuthorizedWorkflowRunContext` 的执行入口；capability 与 exact `WorkflowDefinition` 绑定，raw `ContextSnapshot` 执行入口保持 Runtime-internal，因此非音频与 replay 不能绕过 preflight、隐私授权或识别 options 快照。
- 剪贴板捕获已有 Settings、菜单栏与主剪贴板页共用的持久总开关，并保留“忽略下一次外部复制”。关闭冷启动不会读取 pasteboard descriptor、payload、焦点或隐私状态，不运行外部复制监控，也不会拦截 Command-V；历史与显式复制/粘贴仍可用。重新开启先以当前 change count 建立 baseline，不回填关闭期间的复制；单调 preference revision 会拒绝旧启动快照覆盖较新的用户选择。敏感 App 规则支持增改删、启停、bundle ID 校验/去重和推荐默认恢复。UI 与运行时共享同一会话策略源，修改立即生效；四项设置以严格顺序在单次 SQLite 事务中提交，加载失败 fail-closed，保存失败可见且可重试。外部剪贴板采集只异步读取和记录，在 payload 读取前后复核 change count、焦点身份、Secure Input、策略结果和控制 revision；焦点或设置竞态会丢弃 payload。原生复制和粘贴不被拦截，队列预览不再写入系统剪贴板；只有用户明确触发输出时才进行条件写入与恢复。
- Webhook 动作实现已有最小文本载荷、隐私授权与 HTTPS 策略；发布版本不在 destination picker 或生产 registry 注册 Webhook，manifest 导入和旧执行均 fail-closed。启动迁移会先将旧端点/请求头写入 Keychain 并精确回读，再原子写回不含凭据的稳定引用，强制工作流禁用并物理清除 SQLite DB/WAL 残留；任一步失败都隔离工作流库而不影响其他设置。
- retired cloud ASR API Key 使用 Keychain，旧 SQLite 值只在安全写入成功后删除。本地 sherpa-onnx 模型来自固定公开 archive，不需要 repository token，也不会把旧 Whisper credential 传给下载器或 runtime。
- 保留期内的本地内容也不再以应用级明文落盘：32-byte 根密钥保存在本机 Keychain，运行正文、工作流名、纠错来源、全部设置（含剪贴板活动状态）和导出路径/元数据使用带表/行/字段 AAD 的 AES-256-GCM 版本化 envelope。SQLite v4 在同一事务写入 key marker、密文和 `user_version`；错误密钥、损坏 tag 或 marker/schema 不一致均 fail-closed。旧诊断正文在迁移时清空为安全摘要，durable `cleanup_pending` 会在 WAL busy、崩溃或清理失败后继续重试，只有可验证 checkpoint + `VACUUM` 完成后才清除。
- 失败录音恢复默认关闭；此时成功、失败和取消路径仍会清理 Rill 管理的临时音频。处理成功或失败后的瞬时 unlink 失败会转交队列退避任务，run cancel 与 App shutdown 都会等待托管 WAV 清理。只有用户显式开启后，投递前发生且非取消的合格失败录音才会在删除明文前进入加密恢复缓存。
- 恢复缓存的音频与无正文 receipt 使用 Keychain 根密钥和 typed-AAD AES-256-GCM 保护，最长 24 小时，最多 3 条、单条 16 MiB、总计 32 MiB。运行时在最早到期点主动清理，失败会退避重试；损坏索引按不可延长 TTL 的保守时间清理，不阻塞其他到期条目，崩溃后超配额也会自动收敛。重试在隐私确认后重新检查 TTL，并在解密前持久化一次性 attempt 状态；同一时间只允许一个明文恢复重试，中断或成功后清理失败都不会静默重复 provider 请求。重试只写入新的运行历史，不重复粘贴、剪贴板、Shortcut、文件或 Webhook 等输出动作。恢复明文正常路径立即删除，崩溃遗留在下次启动立即清理；清理失败会持续退避重试，并在完成前阻止新的恢复请求。AppModel 以 receipt ID 持有活动重试；退出开始后拒绝新请求，取消并等待所有重试恢复 durable receipt、删除解密明文，即使 provider 忽略 cancellation 也不会发布晚到成功。开启、关闭、清空和 preserve 使用同一代际状态机，较早的启动刷新不能覆盖新的 opt-out。
- 剪贴板历史与运行历史默认各保留 30 天，可独立选择 1 天、1 周、30 天、1 年或永久，并可分别一键清理；诊断跟随运行历史策略。初始设置批量读取未完成时，UI 与 AppModel 都拒绝留存期改动，避免旧快照覆盖新选择并启动不可逆清理。启动、缩短策略和每日维护都会执行同一套可重放清理协议；Stack / Queue / List 中仍活动或已租约的剪贴板项不会被误删，实际删除后会清理 SQLite 与 WAL 残留。
- 诊断事件在写入边界按 allowlist 清洗，只保留固定事件码、状态和计数；provider 响应正文、热词、转写原文和任意错误描述不进入持久化诊断。
- Dashboard 已用默认听写路径 readiness 清单替代泛化的“已就绪”声明：历史模型记录不等于当前缓存可加载，retired cloud ASR 非空 Key 不等于已验证，只有当前会话真实模型加载或非空 Speech Check 才进入 ready 状态。应用返回前台会刷新权限，权限请求只由用户操作触发。
- 应用内复制统一走共享 pasteboard 写入端口并登记 owned change，避免诊断/历史复制被外部捕获监听器再次收录。
- 临时覆盖剪贴板的文字注入采用单事务条件回滚：Command-V 成功、失败或任务取消都会尝试恢复原快照；如果用户期间主动复制，change count 不匹配会跳过恢复，避免覆盖新内容；重叠注入会在写入前拒绝。`inject.text` 还绑定开始运行时的 bundle/PID 最小身份，必要时尝试恢复目标 App，并在粘贴或每个键盘分块前复核；目标不可验证、激活失败或中途漂移时 fail-closed。相关诊断只保留布尔状态、固定 outcome 和长度/计数，不记录目标 App 标识或注入正文。
- retired cloud ASR 缺失/空白 Key 或非法端点会在麦克风权限、临时音频和 fallback 之前失败；真正的流式运行错误仍可退回录后识别。手动工作流则以独立 preparing 状态覆盖持久化、隐私确认和 capture 启动，只有真实启动成功后才显示 recording。
- 实时 capture 启动现在从首个 `await` 前就持有唯一 reservation；配置等待、权限等待、fallback late-start 和复用 runID 的旧任务都不能覆盖新会话。retired cloud ASR 音频通道固定容量，overflow 同步撤销外发 lifetime、关 WebSocket，并由 runtime 停采集、丢缓冲、删除临时 WAV，不会以无界内存换取网络背压。
- 通用 recognition preflight 还把同一检查放到云端隐私确认和任何上下文读取之前；手动与热键路径都只依赖 Core 端口，retired cloud ASR 的具体校验留在 Providers，避免 Runtime 反向读取设置或复制 provider 规则。Diagnostics 的 retired cloud ASR Speech Check 也先精确持久化/回读配置并执行无确认的隐私 preflight，录音结束后、调用 recognizer 前再按当前焦点与设置完成最终 egress authorization；capture finish、最终授权、recognizer 与托管临时音频清理由一个精确 operation 持有，取消/shutdown 会等待整条链退出。
- Workflows 页已提供动态、content-free 的运行前解释：只允许预览已保存且当前草稿无未保存改动的工作流；AppModel 先用真实手动 invocation、当前 recognizer 和内建 output route 解析 opaque plan，再由组合根只采集 privacy-safe identity/descriptor 快照。收据只含 fixed enum、UUID、Bool 与 Int，展示输入类别、transform、全部 action effects、目的地、隐私原因及 `ready` / `requiresConfirmation` / `blocked`，不包含名称、正文、prompt、URL、路径、header、凭据或底层错误。预览不会调用确认、provider 或完整上下文读取；路由/隐私设置变化会使结果失效，真实运行会重新采集上下文和设置并在确认后再次校验。
- 录后处理采用显式 controller/queue 所有权状态机：只有 sealed lease 能原子进入 `queueOwned`；转移前 Stop 由控制器清理，转移后 Stop/shutdown 由队列取消 exact run。控制器以 `runID + operationID` 持有 deferred finalize，退出会等待已转移 WAV 清理；队列终态拒绝新任务，取消会传播到底层 Task，并收束 pending、active、drain 与清理 waiter。retired cloud ASR Speech Check 的完整 finishing operation 也可由 UI 或 App 退出精确取消并等待。
- 本地发布链路默认输出到 `.artifacts/release/`，拒绝仓库根目录和仓库内 `.artifacts/` 之外的位置；preflight/prek 会在构建前拒绝根目录遗留的 App、DMG 或 checksum sidecar，宽泛的 App/DMG ignore 也已移除。最终分发顺序固定为“创建 DMG → 签名外层 DMG → 提交该 DMG 公证 → staple/validate → Gatekeeper 复验”。App 装配同时包含原创 ICNS 与中英文系统麦克风权限文案。仓库仍没有许可证、Developer ID Application 身份与真实公证结果，因此不能把假工具顺序测试或本地签名表述为公开可分发。
- 桌面生命周期不再把最后一次用户状态留给运气：组合根持有启动清理、恢复刷新与 producer 启动任务；退出先取消并排空它们，再把录音/恢复入口置为不可逆终止态，然后停全部运行时生产者和 group scheduler，取消并等待手动/重放工作流及其外部 Shortcuts 子进程，收束本地模型准备/预热，最后 flush AppModel 设置、Keychain 凭据、隐私原子写和 DeliveryStack 的 debounce 状态。忽略 cancellation 的 recognizer 也会在输出动作前被 SessionCoordinator 拒绝，不能在 flush 后补写元数据或继续外发。全局快捷键统一拒绝系统、单修饰键和 Rill 保留组合，并以 key-down/key-up latch 阻止 autorepeat 或修饰键漂移泄漏到前台 App。
- 组自动化的执行前边界已从单一 `polishGenerated` tag 扩展为 content-free exact item version、root lineage、有序 workflow path 与 8-hop cap；执行 policy 还区分 interactive/replay/group surface。来源感知的 non-interactive preflight 绝不调用确认 provider，且目前只接受单一 `stack.push` replacement plan；它不发 capability，生产 action 继续因缺少 revision-bound grant 和 one-shot group lease 而关闭。浮动面板取消后的延迟 auto-hide 不再继续执行，最新打包 App 已通过失焦 auto-hide、Esc/焦点恢复与键盘零穿透检查；全部 sheet 入口在全局双击 Command、attached sheet 与 VoiceOver 人工验收前仍关闭。
- 合并后的运行历史不再用当前 workflow 配置猜测正文来源：SQLite v8 延续 nullable closed trigger 并与同 run receipt 交叉验证；旧行、来源冲突和旧 group metadata 均 fail-closed。Dashboard、历史页与活动流共用 `full / restricted / disabled` presentation，受限正文进入视觉与 AX 前截断，禁用时活动项只显示无正文状态。浮动 NSPanel 的 modal gate 也已扩大到全部 SwiftUI sheet，不再只隐藏 dry-run。
- 主窗口全局搜索由 shell 统一持有：`Cmd-F`、菜单命令和工具栏按钮索引页面、工作流、receipt-first 运行历史与设置分区；历史正文只按当前 `full / restricted / disabled` presentation 加入索引，受限模式最多使用 96 字符预览，禁用时不索引正文。结果使用 typed destination 打开工作流、精确历史条目或设置分区；Dashboard/Diagnostics 的设置入口也复用 typed section request，由 Settings 滚动并聚焦语言、剪贴板面板、权限、隐私、存储、语音、词汇或输入标题。
- 主窗口普通路由的焦点恢复跨过 AppKit mouse tracking：MainShell 先清除 stale `FocusState`，在主 RunLoop default mode 再提交最终侧栏焦点；Dashboard → Clipboard 的方向键、List selection、`NSEventTrackingRunLoopMode`、快速路由与 typed-detail 所有权已有 hosted 回归，真实鼠标与完整 VoiceOver 按发布 QA 验收。

这份“产品事实”优先于路线图宣传。任何能力只有贯穿真实运行路径并有验收测试后，才标记为已完成。

## 8. 差异化与边界

Rill 的核心不是把所有听写、剪贴板和自动化功能放进一个 App，而是提供一条可解释的数据路线：

```text
voice → correctable text → clipboard group route → observable workflow → output action
```

其中：

- 初次用户只需要看到“原样听写”的低摩擦入口。
- 进阶用户可以逐层启用映射、组路由、模式和输出动作。
- 每次运行都应能回答：使用了什么上下文、是否离开本机、为什么触发或跳过、文本去了哪里。

近期不复制会议套件、跨设备同步、屏幕 OCR、任意脚本插件或完整宏控制流。这些能力只有在核心链路的 dogfood 数据证明存在明确瓶颈后再评估。

## 9. 持续改进机制

### 9.1 固定循环

每月一次，并在重点竞品发布重大版本时额外执行：

1. **发现**：只读官方更新日志、产品文档、价格/隐私页和源码仓库。
2. **核实**：把竞品能力与 Rill 当前运行路径逐项对照，区分模型、UI、生产接线和可验证结果。
3. **选择**：每轮只选一个能改善真实指标的最小切片。
4. **实现**：优先扩展既有模块边界，不为追平竞品引入平行架构。
5. **验证**：自动化测试 + dogfood；记录成功率、编辑成本、失败恢复和隐私路径。
6. **复盘**：更新本页的事实、决策、未做事项和下一触发条件。

能力进入实现队列前必须同时满足：

- 对应可复现的用户痛点，而不是竞品功能数量；
- 能加强 Rill 的核心数据流和差异化；
- 有可度量的成功条件，且权限/隐私成本可接受。

### 9.2 本轮记录

| 日期 | 证据 | 选择 | 实现与验收 | 下一步 |
|---|---|---|---|---|
| 2026-07-10 | 多个成熟竞品同时提供 replacement；代码审计发现 Rill 只有模型/UI，没有生产接线 | 先完成 provider-independent mapping，不同时扩展 ASR 或 LLM | 在识别后、post-process 前应用；支持 App/组/语言作用域；加载失败时 fail-open；记录不含原文的诊断；新增 runtime 测试 | P0：Capture Privacy Gate；随后建立 provider capability contract 与一步纠错闭环 |
| 2026-07-11 | Raycast/Paste 类产品把敏感内容过滤、暂停捕获和凭据保护视为基础能力；仓库审计同时发现伪 LLM、明文凭据、HTTP 外发和临时音频泄漏 | 先完成隐私/产品真实性切面，不扩展新 provider | 两阶段剪贴板读取、录音前云端确认、Keychain 凭据与 Webhook 迁移、SQLite/WAL 物理清理、显式音频所有权、捕获暂停/忽略下一次、自定义敏感 App、共享会话策略源与原子设置事务；Webhook 仍从发布入口与 registry 隔离，导入和旧执行 fail-closed；新增 CI/preflight 和回归测试 | P0：实现默认 30 天历史留存/安全清理并完成真实 ASR dogfood；随后建立 provider capability contract |
| 2026-07-11 | Paste 提供可选保留期，Raycast 提供禁用 App 与批量删除；Rill 还必须保护其独有的 Stack / Queue / List 活动语义 | 实现两类历史独立留存，不为剪贴板历史另建平行数据库 | 默认 30 天；支持 1 天 / 1 周 / 30 天 / 1 年 / 永久、分域清理、活动项保护、崩溃重放、每日维护和 SQLite/WAL 物理清理；组合回归 153 项通过 | P0：provider capability contract 与真实 ASR dogfood；并继续审计诊断数据边界 |
| 2026-07-11 | Type4Me 等产品把“热词”作为高频卖点；retired cloud ASR 官方把 keyterm 限定为 retired cloud model 系列，而 Rill 的实时连接会早于原有 `SessionCoordinator` 后处理 | 采用“隐私授权后生成、录音时冻结、双路径传递”的 typed options snapshot，不让 provider 反向读取设置 | `SpeechRecognizerCapabilities` 显式声明能力；App / 组 / 语言作用域规则经统一 resolver 进入实时和录后请求；retired cloud ASR 只对 retired cloud model 系列追加重复 `keyterm` 参数并执行数量/长度预算；不支持路径丢弃提示且只记录无内容计数诊断；Core/Runtime/Provider/App 组合测试通过 | P0：真实 retired cloud ASR/WhisperKit dogfood、首次启动 readiness 与签名安装包验收 |
| 2026-07-11 | 成熟听写产品把权限、模型准备和云端配置放在首次成功路径；仓库审计发现后台预热吞错、历史下载记录被当作可用、菜单无条件显示 Ready | 采用 Dashboard 内嵌、持续更新的默认听写 readiness，而不是一次性向导或持久化 ready 标志 | 麦克风/辅助功能按当前输出模式判定；本地模型以当前会话真实加载为准，retired cloud ASR 以当前会话非空 Speech Check 为准；配置变化立即失效；返回前台刷新权限；UI 组合测试通过 | P0：云端缺配置在麦克风前 fail-fast；干净账户与签名安装包验收 |
| 2026-07-11 | 运行时审计发现缺失 retired cloud ASR Key 会先请求麦克风并退回本地录音；手动工作流在异步准备完成前就显示 recording | 把配置验证前移到任何本地副作用之前，并把 UI 准备态与 runtime capture 状态对齐 | 缺失/空白 Key、非法 URL 的测试证明权限请求、legacy capture 和临时 WAV 均为 0；其他流式错误仍可 fallback。手动录音在 start 成功前保持 preparing，二击不触发 finish，失败回 idle | P0：干净账户与 Developer ID 公证包验收 |
| 2026-07-11 | 麦克风前 fail-fast 后继续审计发现，手动与热键路径仍可能先读上下文或显示一次无意义的云端确认 | 增加 provider-independent `RecognitionRunPreflight`，具体 retired cloud ASR 校验集中在 Providers | 两个控制器都在 preparing 后、privacy/context/options/capture 前调用；失败回 idle，热键发布既有 failure 事件；录后、实时、启动诊断和组合根共用单一 validator；调用次数测试证明后续阶段均为 0 | P0：签名/公证身份与真实设备 dogfood |
| 2026-07-11 | 真实签名验收发现 App 已包含麦克风 entitlement，但发布校验把点号当作 plist key path 分隔符并误报缺失；仓库根目录已有产物也不应在验证时被覆盖 | 让发布输出可隔离，并按字面 entitlement 键校验最终签名，不降低签名要求 | 隔离目录中完成 454 项测试、universal App 装配、Apple Development 签名、strict/hardened runtime/Team ID/时间戳/entitlement 校验与 DMG checksum；配置测试 11/11 通过 | P0：许可证、Developer ID 公证与干净账户验收；真实 retired cloud ASR/WhisperKit dogfood |
| 2026-07-11 | Wispr Flow、Willow、Typeless 等把纠正学习作为高频成功率机制；Rill 已有 scoped mapping/hotword，但缺少从一次真实运行安全生成规则的闭环 | 采用最小 provenance + 纯规划器 + 人工确认，不做静默自动学习 | Core 只接受单个连续修改并拒绝控制字符、超长、分散修改和危险的纯空白映射；SQLite v3 可恢复迁移保存可选 provenance；History UI 要求显式 option 和所有未知 scope 确认；全量 502 项测试通过 | P0：修复文字注入回滚；随后保护保留期内的本地明文内容 |
| 2026-07-11 | 纠错闭环后的 maintenance audit 发现，临时写入 pasteboard 后若 Command-V 创建失败，原恢复语句会被抛错绕过 | 把临时剪贴板写入收敛为单一条件回滚事务 | 纯文本/富内容在成功、失败和取消时恢复；并发事务在写入前拒绝；用户期间复制时跳过恢复；8 项注入回归覆盖所有边界且诊断不含文本 | P0：Keychain 根密钥 + AES-GCM 本地静态数据保护 |
| 2026-07-11 | `secure_delete` 与 retention 只保护删除后的残留，保留期内的历史正文、纠错来源和完整剪贴板状态仍可在 SQLite 中直接读取 | 不引入平行数据库；在现有 persistence 边界增加 Keychain 根密钥、typed AAD 与版本化 AES-GCM envelope | SQLite v4 原子迁移 history/settings/export 并重写旧 diagnostics；key marker 阻止错误密钥写入，`cleanup_pending` 跨崩溃重试物理清理；WAL busy、事务中断、wrong key/AAD/tag、DB/WAL 明文扫描均有测试；全量 533 项通过 | P1：在加密存储基础上设计显式 opt-in 的失败音频恢复队列 |
| 2026-07-11 | Wispr Flow 已提供失败录音 Retry/Recover，Superwhisper 支持历史重处理；Handy Issues 暴露“先转写、后持久化”的数据损失窗口 | 复用既有数据保护与运行边界，采用默认关闭、显式 opt-in、手动且一次性的短期恢复队列 | 写入前加密、硬 TTL/容量、错误密钥和篡改 fail-closed、当前策略重试、无重复输出、逐条删除/全部清除；并发 opt-out、过期维护重试、启动明文清理、损坏索引隔离、崩溃后配额收敛与驱逐回滚均有故障注入；全量 589 项、1 项 expected skip、0 失败 | P0：发布/真实 ASR 验收；P1：自动化解释与 dry-run |
| 2026-07-11 | 发布复审发现依赖许可、来源 revision、公证构建来源与 ASR 证据仍可能在最后一步漂移；有限网络 probe、路径前后哈希和自报 consent 也不足以证明离线真人 dogfood | 把发布来源、第三方归因和 ASR 输入都收敛成 fail-closed capability / trust-anchor 边界 | `Package.resolved`、detached worktree、commit/tree/lock 重验和 8 个依赖 NOTICE 进入发布门禁；ASR XCTest 自行应用 `no-network`，wrapper 使用空环境，受信 Ed25519 attestation 绑定 consent evidence，输入以 fd-bound 私有快照运行，公开结果删除正文及无盐正文 hash；26 项发布策略、9 项许可测试与 17 项 ASR helper 通过 | P0：取得 Developer ID 并用受信签名真人语料完成干净账户正式 dogfood |
| 2026-07-11 | Keyboard Maestro / Alfred 一类自动化产品说明强能力必须配可解释性；代码红队同时发现旧剪贴板事件入口会在不同资源边界触碰上下文、录音或解密，静态说明也可能和 UI 实际路由分叉 | 在开放自动化前先建立单一 resolved plan、content-free receipt 和不可绕过的执行 policy | AppModel 与 Explain 共用 resolver，按实际 invocation 披露 required/conditional input、transform、全部 action effects 与目的地；隐私未动态评估时固定 blocked。legacy workflow 在所有资源入口先拒绝，失败明文清理持续退避重试但绝不识别/恢复；完整 preflight 为 630 项、1 项 expected skip、0 失败 | P1：接入 fixed-classification 动态隐私评估与 Explain UI（已由下一行完成），再做 dry-run/跳过原因；继续禁用组事件自动化 |
| 2026-07-11 | 静态 Explain 后的边界复审发现：UI 草稿可能与保存版本分叉，preview 可能被误当授权，非音频/replay 与 provider 诊断也需要同一隐私闸门；Stack 镜像、焦点切换和设置变更存在 TOCTOU 窗口 | 完成动态 Explain 与 workflow-bound authorization，同时收紧剪贴板、retired cloud ASR egress 和文字注入的最终使用边界 | Workflows UI 只解释无未保存改动的已保存工作流；privacy-only preview 与 live authorization 共用 destination classifier，但运行时重新取 context/settings。opaque capability 关闭 raw Runtime API，覆盖非音频与 replay；Stack mirror/capture、Speech Check finishing/final egress、TextInjection focus binding 均有针对性竞态与 canary 回归，最终全量 preflight 仍待本切片后重跑 | P0：Developer ID、公证与受信真人语料/干净账户验收；P1：typed run receipt、trigger/skip 原因和 clipboard dry-run |
| 2026-07-11 | 继续红队发现授权与真实副作用之间还有耗时边界：队列 WAV finalize、失败录音解密、剪贴板条件写入和浮动面板恢复焦点 | 使用两阶段 audio lease、同步 pasteboard transaction 和 panel-locked target identity 把授权推近最终使用点 | Deferred/recovery 在音频解析/解密前 claim，之后、recognizer 前 final revalidate；拒绝后清理明文且不进 recovery/provider。剪贴板写入在同一 MainActor 非 suspension 区间比较 change count；panel 锁定 PID/bundle 并在 Bootstrap 及 TextInjection 再复核。永久失败 deferred Task 不再无界重试 | P0：Developer ID/公证、受信真人语料与干净账户验收；P1：为 retired cloud ASR live 增加运行中撤销/关流语义，再做 typed run receipt 与 dry-run |
| 2026-07-11 | retired cloud ASR live 边界审计发现 capture-start 授权无法约束录音中途切入敏感 App，普通 cancel 还会排空缓冲；后置 lease 只能阻止 fallback，无法撤回已发送音频 | 把授权改为“录音会话内持续有效、可撤销”，并用 Core permit、Runtime monitor/seal、Provider teardown 三层分离策略与机制 | 手动、按住说话和长录音共用 run/workflow-bound lifetime；敏感/未知焦点、Secure Input、设置不可用或收紧会按 runID 关流。Provider 撤销时不发 Finalize/CloseStream、不排空尾部，旧 receive/cancel 不能污染新 run；停止后只有 sealed lease 可进入队列。浮窗显示 Cloud/本机并提供真实停止，App 退出 await 清理 | P0：Developer ID/公证、受信真人语料与干净账户验收；P1：typed run receipt、trigger/skip 原因与 clipboard dry-run |
| 2026-07-11 | live 会话复审继续发现配置 `await` 前无占位、音频流无界、seal/enqueue 接管空窗、退出未收束队列和诊断 HTTP Task | 用唯一 reservation、有界 fail-closed buffer、原子 queue ownership 与 terminal shutdown 统一生命周期 | 并发/取消后的旧 start 不能覆盖新 run；16-chunk overflow 撤销外发并删临时音频；`sealed → queueOwned` 精确分工，Stop/shutdown 取消底层 deferred；Speech Check 转写可见取消。完整 preflight 已通过 Universal Release 构建、资源访问器、App 装配、临时严格签名、第三方许可归因与全量 768 项测试，结果为 1 项 expected skip、0 失败 | P0：Developer ID/公证、受信真人语料、解锁桌面后的干净账户验收；P1：typed run receipt 与 clipboard dry-run |
| 2026-07-11 | 最终红队发现退出只等待 capture/HTTP 的局部阶段，仍可能在 provider 已交出 WAV、最终授权或 seal 挂起时提前结束；发布复审同时发现 CI 门禁、Universal 断言、本地版本来源与竞品宣传存在可修空窗 | 将整个 finishing 栈纳入 run/operation 所有权，并把发布与竞品事实收敛为可验证、fail-closed 输入 | 手动/热键录音与 Speech Check 的 cancel/shutdown 都等待旧 Task 完成 managed WAV 清理，旧 completion 不影响新 run；CI 固定带哈希验证的 prek action/tool，preflight 与 assembler 共用 Universal verifier，非精确干净 tag 使用 dev metadata；竞品表固定到日期和源码快照。最终 clean preflight 通过 26 项发布策略、9 项归因测试和 `--parallel` 全量 771 项，1 项 expected skip、0 失败 | P0：Developer ID/公证、许可证决策、受信真人语料和解锁桌面后的干净账户验收；P1：typed run receipt 与 clipboard dry-run |
| 2026-07-11 | Keyboard Maestro / Alfred 的可追踪自动化边界与本地隐私产品的可清除历史表明，强工作流不能只靠临时日志；代码审计还发现 EventBus 聚合、坏行放大、授权与 replay 语义漂移、clear 重放和晚到写入风险 | 让 Runtime 成为 content-free terminal ledger 的唯一写入者，并让 dry-run 与 live replay 共用 exact invocation capability | versioned receipt 记录真实 trigger、分桶耗时、动作固定结果与 completed/partial/failed/cancelled/skipped；SQLite v6 加密独立 payload、坏行隔离、精确 runID 补载和 bounded-clear write barrier，落库后才 fan-out。History 以 receipt 为主时间线并显示 receipt-only 操作；clipboard dry-run 保持纯函数，live authorization 绑定 exact item kind/tags/operation，未知目的地 fail-closed | P0：Developer ID/公证、许可证与受信真人 dogfood；P1：补 group scheduler 的 fixed skip/loop reasons，并在真实桌面/辅助功能验收后开放 dry-run UI |
| 2026-07-11 | 最终线性化与隐私复审发现：receipt insert 返回后可被 clear 删除，迟到的完整 receipt 事件仍会制造假 durable 投影；clipboard replay 复用语音工作流时也可能把剪贴板正文二次写入语音历史 | 把 fan-out 降为 content-free repository invalidation，并让实际 closed trigger 成为正文留存与展示的唯一判据 | AppModel 收到通知先删除旧投影再 exact-ID 回读，reload 失败保持缺失；确定性 suspend-insert → clear → notify 测试证明不复活。完成摘要携带真实 trigger，Stack/clipboard group/use/replay 不保存、左连接或展示正文，即使工作流声明 WhisperKit/retired cloud ASR。clean preflight 通过 Universal Release、App 装配、临时严格签名、26 项发布策略、9 项归因测试和 `--parallel` 全量 868 项，1 项 expected skip、0 失败 | P0：Developer ID/公证、许可证、受信真人 dogfood 与解锁桌面验收；P1：补 group scheduler 的 fixed skip/loop reasons，并在真实桌面/辅助功能验收后开放 dry-run UI |
| 2026-07-11 | Alfred、Keyboard Maestro、Raycast 与 Apple Shortcuts 都把 trigger activation、执行可见性、数据控制或权限边界做成显式产品概念；仓库审计同时发现完整 clipboard item 会穿过 EventBus、`polishGenerated` 只会被归为普通排除、非法 legacy metadata 会扩大 source/action 默认值 | 先交付 content-free、decision-only group scheduler，不借机开放 action | DeliveryStack 直连无正文 descriptor，EventBus 同步移除完整 item payload；Runtime 使用有界背压 FIFO、去重和稳定顺序，只为路由候选写 durable skipped receipt。持久化失败不发布 matched/skipped；生产能力与用户启用状态分离。revision batch、生产者停止、sink 摘除屏障和 scheduler drain 共同封闭退出竞态。严格 Core parser fail-closed；`loopPrevented` 与其他固定原因进入 allowlisted diagnostics、History 双语详情和 accessibility。排除项可产生无正文 skip receipt；`historyOnly` 不进入调度或 group event fan-out。未知 event type 在所有旧执行入口 fail-closed；组 action、授权和 dry-run UI 继续关闭。clean preflight 通过 26 项发布策略、9 项归因、Universal Release/App 装配与 `--parallel` 全量 905 项，1 项 expected skip、0 失败 | P0：Developer ID/公证、许可证、受信真人 dogfood 与解锁桌面验收；P1：exact revision/lineage 与 dry-run 桌面验收，之后再评估本地幂等 replace action |
| 2026-07-12 | Hazel 的 rule preview 绑定单个样本、只检查条件且绝不执行 action，甚至允许预览已停用规则；Keyboard Maestro 与 Alfred 更接近会执行或观察真实运行的 debugger，Apple Shortcuts 的普通 Run 也是顺序执行而非 dry-run。代码红队同时发现 Rill 只按 item ID/kind/tags 授权，存在同类型正文漂移、删除重建 ABA、晚到 UI 结果和受保护 Webhook 误报 | 首版只开放 exact-item、read-only impact preview；不把 `ready` 变成权限，不提供 Run / Apply / Replace 按钮。用 per-item generation + revision 代替 store-wide revision，并让 Runtime 而非 UI 解析 subject | schema 6 兼容升级；subject 绑定 version/group/kind/tags/content availability；authorization 后与 transform 后复核；Runtime privacy-only prepare 零确认、零 provider/action；sheet-local 状态和有界 latest-pending 拒绝乱序结果；`Paste / Replay / Replace` 双语展示固定 reads/effects/destination/replacement/privacy/issues。主窗口真实桌面与 AX 树验收通过；完整 preflight 通过 26 项发布策略、9 项归因、Universal Release/App 装配与 `--parallel` 全量 920 项，1 项 expected skip、0 失败 | P0：Developer ID/公证、许可证、受信真人 dogfood；P1：浮动 NSPanel 干净账户验收、lineage/hop、one-shot lease、replacement CAS 与 non-interactive authorization，之后才评估本地幂等 replace action |
| 2026-07-12 | dry-run 后续红队发现复制授权可被重复消费、直接 Paste/Use 可能使用过期 UI payload、Stack 富内容镜像可能“预览 A、消费 B”，发布复审还发现最终 DMG 未被签名/公证/装订 | 先封闭真实条目所有权和分发容器，不开放新的自动化动作；同时收口退出落盘、全局快捷键和基础桌面产品面 | capability 复制共享一次性消耗状态；exact use lease、mirror subject 与 replacement CAS 阻止 stale/ABA；live/dry-run 共用替换基数。最终 DMG 成为唯一标准分发公证对象；退出 flush 覆盖设置/凭据/隐私及 WhisperKit 尾写。主窗口单实例，破坏性录音删除有准确确认，App 包含 ICNS 和双语系统权限文案。完整 preflight 通过 27 项发布策略、9 项归因、Universal Release/App 装配、临时严格签名与全量 948 项测试，1 项 expected skip、0 失败；AX 验证合并历史、快捷键文案与单窗口 | P0：许可证、Developer ID 最终 DMG 真实公证、受信真人 dogfood 与干净账户验收；P1：浮动 NSPanel、lineage/hop cap 与 non-interactive authorization |
| 2026-07-12 | Keyboard Maestro 的 Clipboard Changed 没有提供可替代因果链的通用防循环保证；继续代码红队又发现 queued group event 缺 item generation/revision，后台复用 replay gate 会用当前前台 App 覆盖条目来源 App 的 cloud block，浮动 panel 取消 auto-hide 后仍会继续隐藏 | 把因果、exact source 与授权策略写进小型数据合同；先交付 source-aware、zero-confirmation preflight，仍不发 group execution capability | descriptor 增加 exact item version；transient lineage 以 root + 唯一有序 workflow path 推导 hop，重复进入和 8-hop 上限在 capability 判断前阻断。execution policy 分离 interactive/replay/group surface。DeliveryStack 原子解析 source identity，当前 Replay/Replace 与 group preflight 均按来源规则评估；requires-confirmation 的后台路径固定拒绝且 callback 为 0。panel delay 正确传播 cancellation，dry-run feature gate 仍关闭。完整 preflight 通过 27 项发布策略、9 项归因、Universal Release/App 装配、临时严格签名与全量 959 项测试，1 项 expected skip、0 失败；最新打包 App 已通过 Dashboard 打开、失焦 auto-hide、Esc 关闭/焦点恢复和 TextEdit 键盘零穿透 AX 检查 | P0：许可证、Developer ID 最终 DMG 真实公证、受信真人 dogfood；P1：人工完成全局双击 Command、attached-sheet 与 VoiceOver 验收，再设计 revision-bound automation grant 与 one-shot group action lease |
| 2026-07-12 | 最终隐私复审发现 Dashboard 绕过历史正文预览设置、旧记录按当前 workflow metadata 猜测语音来源、浮动 panel 仍可从“新建分组”绕过 dry-run 专用 modal gate | 让正文资格与显示策略都只有一个事实源；不可信 legacy provenance 宁可隐藏，不做启发式迁移 | SQLite v7 持久化 closed trigger；record/receipt 冲突、两者均缺失或旧 group metadata 都不能展示正文，删除 custom workflow 不影响已有权威语音结果。Dashboard 与 History 共用三态 preview presentation；浮动 panel 关闭全部 SwiftUI sheet，最新 packaged-App AX 树确认“分组”页已无新建分组或其他 sheet 入口。完整 preflight 通过 27 项发布策略、9 项归因、Universal Release/App 装配、临时严格签名与全量 967 项测试，1 项 expected skip、0 失败 | P0：许可证、Developer ID 最终 DMG 真实公证、受信真人 dogfood；P1：人工完成全局双击 Command、attached-sheet 与 VoiceOver 验收，再设计 revision-bound automation grant 与 one-shot group action lease |
| 2026-07-12 | Wispr Flow 把上下文感知、训练选择和云同步拆成独立控制但转写仍依赖云端；Superwhisper 已提供本地/云端两阶段模型、显式上下文和历史重处理；Raycast v2 新增原格式保留、多内容单条目、重命名与 `Paste as…`。同轮代码审计发现 Rill 的 Shortcuts 子进程、退出持久化和镜像剪贴板恢复仍有可复现生命周期缺口 | 不追逐默认隐式上下文或通用剪贴板功能数量；先修复当前独特数据链的退出、并发和外部进程所有权 | Shortcuts 运行改为有界、可取消并限制 stderr；DeliveryStack 退出绕过 debounce flush 最新状态；Stack paste 与 SessionCoordinator 在首个跨 actor `await` 前占用运行态；交互工作流进入 shutdown 所有权，退出等待捕获/镜像落定后条件恢复原剪贴板。完整 preflight 通过 27 项发布策略、Universal Release/App 装配、签名结构、第三方归因和全量 982 项测试；全文件 `prek` 与 diff whitespace 检查通过 | P0：许可证、默认 WhisperKit 模型 revision/hash/许可证明、Developer ID 公证与真人 dogfood；P1：只在 dogfood 证明复用或格式摩擦后评估置顶、重命名和 `Paste as…` |
| 2026-07-12 | 用户反馈“运行历史”和“最近结果”页面语义重复；同轮维护/发布审计发现受限预览仍把全文交给 AX、退出时终态历史是未追踪写入、EventBus 存在注册空窗、PTT tap 中断会漏 release，WhisperKit 跨配置加载与默认模型来源也缺少明确所有权 | 用单一页面与小型生命周期/信任边界收敛现有能力，不借机扩大自动化或模型声明 | 页面改为“最近运行 / 最近结果”，显示已加载数量、受限预览真实截断并提供空态入口；本地技术隐私说明与包内资源逐字节一致。EventBus 同步保留 lifecycle stream，退出排空后 flush 历史；CandidateResolver、tap 中断和 WhisperKit generation ownership 均有确定性测试。模型 verifier 拒绝非 exact revision、无证据许可、路径/链接和 tree/hash 漂移；trusted local-artifact loader 在每次使用前重验并只以 verified folder、`download: false` 初始化，legacy 路径不声称可信，但仍没有 production manifest、实际 downloader 或 tokenizer provenance。完整 preflight 通过 Universal Release、27 项发布策略、9 项归因/装配和全量 1017 项测试；打包 App AX/视觉与 Cmd-Q 回归通过 | P0：取得默认模型真实许可/revision，补 production resolver、私有物化与 tokenizer 闭环；决定自身许可证/公开渠道，完成 Developer ID 公证与真人 dogfood；P1：人工 VoiceOver、纯修饰键双击与 attached-sheet 验收 |
| 2026-07-12 | 合并页面后的继续红队发现：retired cloud ASR 可能把未确认结束的实时片段当完整结果，跨连接 clear/write 与损坏历史行影响时间线完整性，程序化 Stack paste 和模型预热缺少 terminal shutdown；默认模型还来自彼此独立的 Core ML 与 tokenizer 来源 | 不扩张页面和功能；先把数据完整性、退出所有权与多来源模型信任合同做成可测试边界 | 未收到当前 `from_finalize` 或实时流失败时保留完整 WAV 并走录后识别；SQLite clear 复核与 insert 同事务，坏行不占查询 limit；Stack paste 与 WhisperKit loader/preload 在退出时排空并拒绝新入口。模型 manifest 升级为 schema v2，独立绑定每个 source 的 endpoint/repository/exact revision/license evidence，并规范化 resolver plan；仍不伪造 production manifest 或掩盖 tokenizer Hub fallback。完整 preflight 通过 Universal Release、28 项发布策略、9 项归因/装配和全量 1031 项测试，1 项 expected skip、0 失败 | P0：实现 production resolver、私有无链接物化、严格本地 tokenizer、真实许可/revision 证据、Developer ID 公证与真人 dogfood；P1：用 logical generation 替代 wall-clock clear marker |
| 2026-07-12 | trusted loader 红队证明 `download: false` 不能阻止 tokenizer Hub fallback，验证后的普通路径仍有 TOCTOU；进一步复审发现 FIFO/path escape、retired task 漏排空、缓存替换未卸载、活动转写缺少租约、损坏快照不自愈，以及只验证词表“自洽”不能证明 Core ML token 语义对齐 | 把候选目录、verified bytes、runtime 与活动使用者拆成显式 capability；只在受审完整字节身份和 canonical Whisper 合同同时成立时加载 | WhisperKit 0.17.0 与 swift-transformers 1.1.9 顶层 exact 固定；manifest-closed 候选经 `O_NOFOLLOW/O_NONBLOCK` 复制成私有、内容寻址、只读并原子发布的独立快照，程序化 manifest 重新校验，损坏缓存隔离后只重建一次。verifier 同次哈希保留 tokenizer 字节；strict adapter 禁止 path/pretrained/Hub API，并绑定 OpenAI 两个 exact revision 的完整 tokenizer/config SHA-256、canonical special/language/byte ID 与 Core ML logits。共享等待者可独立取消；retired/current/cached runtime 经 drain barrier 和 lease 在活动离线/实时转写结束后单次卸载。完整 preflight 通过 Universal Release、29 项发布策略、9 项归因/装配和全量 1050 项测试，1 项 expected skip、0 失败 | P0：取得真实许可/revision 证据并提交 production manifest，完成 revision-aware resolver/downloader 与 AppBootstrap trusted-path 接线；决定自身许可证，完成 Developer ID 最终 DMG 公证、干净账户安装与真人 dogfood。P1：稳定阶段错误映射与 History logical generation |
| 2026-07-12 | 产品级复审发现活动流绕过三态正文预览、diagnostic 单个坏行拖垮整页、wall-clock clear 误判时钟回拨、跨表部分清理会短暂重显旧代、trusted loader 透传底层路径/令牌，退出超时还会取消关键清理 | 不扩张功能；把 presentation、持久代数、错误出口和退出阶段都改成显式边界 | 活动流与 History/Dashboard 共用三态 presentation；SQLite v8 用持久 CAS generation 绑定 History/receipt/diagnostic 写意图并安全桥接 schema 4，所有公共读路径只承认当前 generation，坏 diagnostic 行按批跳过且不占 limit；trusted path 只暴露五类无 payload 阶段错误；退出先排空事件和持久化，最后卸载模型，超时取消本次退出而不取消清理。针对性 Core/Runtime/Persistence/Providers/App/UI 测试均已通过，完整 preflight 结果见改进计划 | P0：production model provenance/resolver/App 接线、Developer ID 公证、许可证与真人 dogfood；P1：最低系统 CI 迁移、组 action 授权/租约及人工 VoiceOver/attached-sheet 验收 |
| 2026-07-12 | [Argmax Core ML 当前模型卡](https://huggingface.co/argmaxinc/whisperkit-coreml/blob/main/README.md)没有可核验的许可证声明，不能从 OpenAI 原始模型条款推断衍生产物授权；[Distil large-v3 模型卡](https://huggingface.co/distil-whisper/distil-large-v3)明确其为 English-only。同轮红队还发现下载后才判超限、候选副本累积、任意公网 host/redirect、祖先 symlink/ACL、跨 revision retention 与双 Command 的 Fn/指针/长按误触边界 | 只交付可复核的下载与信任机制，不伪造默认模型 provenance；把网络策略、临时下载、候选安装、可信快照和 runtime lease 分成独立边界 | production resolver 使用 exact host 白名单、默认拒绝跨源 redirect、流式硬上限、从 `/` 开始的 dirfd/no-follow traversal、ACL 拒绝、原子内容寻址发布和有锁的三候选/24 小时宽限 retention；有效快照先离线验证，授权策略变化退休旧 resolution。Distil UI 明示“仅英语”。双 Command 改为左右对称的纯状态识别器，Fn、其他输入、鼠标/滚轮、长按和第三次重叠均 fail-closed。发布门禁逐 slice 固定 macOS 14.0 minos，只有真实公证后的最终 DMG 生成标准 checksum；完整 preflight 通过 29 项发布策略、Universal Release/App 装配、9 项许可归因与全量 1106 项测试，1 项 expected skip、0 失败 | P0：取得真实逐来源许可/revision 并固化 production manifest、CDN host 与编译期信任锚，完成 App factory/禁网真实模型集成；Developer ID 公证、许可证决策与真人 dogfood。P1：Sonoma runner 迁移及人工双 Command/VoiceOver/attached-sheet 验收 |
| 2026-07-12 | 主窗口从 Dashboard 进入 Clipboard 时，详情页搜索框会成为默认 key view，侧栏焦点反馈像是消失；group 子路由还会让顶层 Clipboard 选择弹回旧 group | 把跨页导航焦点归 MainShell，Clipboard 只管理页内显式焦点；原生 Tab 顺序不由页面重写 | 侧栏 List 使用 shell-owned FocusState，并只在真实侧栏路由变化时恢复；Clipboard 移除 onAppear 搜索抢焦与 Tab 拦截，搜索焦点增加可见强调色，search → Routing 时落到分段控件。顶层 Clipboard 清除 group 子路由；AppKit hosted test 以真实 Down 键覆盖 Dashboard → Clipboard 并验证 responder 仍在侧栏。当前 debug App 的 AX 回归确认进入 Clipboard 后继续 Down 可到 History，搜索框仅在明确点击后获焦；完整 preflight 通过全量 1111 项测试，1 项 expected skip、0 失败 | P0 仍为模型 provenance、Developer ID 公证、许可证与真人 dogfood；P1 保留完整 VoiceOver/两种输入法焦点顺序及 detail 按钮跨页落点人工验收 |
| 2026-07-12 | 用户进一步明确问题是主窗口侧栏“仪表盘”下方的“剪贴板”；跨页复审同时发现 detail 按钮依赖隐式 AppKit fallback，输出 action 的 `CancellationError` 会被包装成 processing failure，发布门禁只有私钥规则而没有通用凭据扫描 | 把 route 焦点、运行取消和 secret hygiene 各自收敛为单一 typed owner；不在 AppModel 持有瞬态焦点，也不把取消修补成分散的错误字符串 catch | MainShell 用 route-keyed task 同步键盘与 VoiceOver 侧栏焦点，相同 route 不抢控件，快速 route 只提交最终目的地；4 项 hosted test 与实际 App AX 操作覆盖 Dashboard → Clipboard → History、History → Dashboard → Clipboard 和 Dashboard → Settings → Diagnostics。Runtime 新增 typed cancellation summary/action result，首动作取消与已有副作用后取消分别形成 cancelled/partial cancelled，Stack/Clipboard lease 无错误归还，AppModel 不生成失败历史。Gitleaks 8.30.1 安装资产按架构固定 SHA-256；Git 全历史与 tracked+untracked(nonignored) 快照均脱敏扫描，6 个公开模型 hash/revision 假阳性只在 exact value + rule + path + full-line 全部匹配时放行，扫描失败必清理临时快照，文件枚举失败或 shallow clone 均 fail-closed。完整 preflight 通过双域扫描、29 项发布策略、Universal Release/App 装配、9 项归因与全量 1123 项测试，1 项 expected skip、0 失败 | P0 仍为 production 模型 provenance/App 接线、Developer ID 最终 DMG 公证、Rill 自身许可证/安全渠道与真人 dogfood；P1 保留 macOS 14 实机、完整 VoiceOver、双输入法与 external Shortcuts/Markdown 人工验收 |
| 2026-07-13 | 产品复审发现 README 已承诺 `Cmd-F`，真实主窗口却没有全局搜索；Dashboard/Diagnostics 只到设置页顶；根目录旧 App/DMG 被宽泛 ignore 隐藏；失败录音重试缺退出所有权；secret 源快照还能在 Gitleaks 运行期间漂移 | 用 shell-local overlay + AppKit search-field bridge 和 typed destination 收敛导航；用物理路径/capability 与同文件系统 staging 收敛发布；把恢复明文和扫描输入都变成可证明的终止条件 | MainShell 浮层与 `NSSearchField` bridge 确定性处理首次/重复 `Cmd-F`、方向键、`Return` 与 `Esc`，历史索引复用三态预览；workflow/history/settings 由 typed 目标页持有 exact 焦点。hosted AppKit 回归覆盖 Dashboard → Clipboard 的键盘、List selection 和 mouse-event-tracking 恢复时序；修复后的真实鼠标路径仍按发布 QA 验收。发布默认 `.artifacts/release/`，先失效旧产物，再用同文件系统私有 staging 原子发布；逻辑/物理路径和公证 snapshot capability 均 fail-closed。终止会等待最终全局恢复明文 sweep，不能证明清理完成时拒绝本次退出。secret scan 在结束后复核源文件集和逐字节内容稳定性。最终完整 preflight 通过 35 项发布策略、Universal Release、App 装配、临时严格签名、9 项归因及全量 1154 项测试，1 项 expected skip、0 失败 | P0 仍为 production 模型 provenance/App 接线、Developer ID 最终 DMG 公证、Rill 自身许可证/安全渠道与真人 dogfood；P1 保留 Intel/macOS 14、完整 VoiceOver、双输入法与 external Shortcuts/Markdown 人工验收 |
| 2026-07-13 | 依赖复审确认锁定的 `swift-crypto` 4.3.0 落在 CVE-2026-28815 的受影响区间；仅有 exact lock 与自动依赖更新（当时为 Dependabot）不能在无网本地门禁中保留已复核漏洞边界，也不能证明 CI 查询了每个 transitive commit | 把人工复核的版本边界写成小型离线 deny baseline，再以 OSV exact-commit 查询补充会持续变化的在线情报；两层都 fail-closed，但不让网络可用性污染本地可复现 preflight | 锁文件与第三方 NOTICE 升级到 `swift-crypto` 4.3.1；Python 标准库 checker 严格拒绝受影响边界、baseline/lock 重复或畸形输入。preflight 与 prek 运行离线 policy，CI 对全部 lock commit 调 OSV `querybatch`，按输入顺序映射、逐结果分页并拒绝网络、重定向、响应数量、重复 advisory/token 等异常；任何 live advisory 都阻断。README 同时补齐受审 Gitleaks 安装路径，内部 `SPARK.md` 明确保持本地忽略 | P0 仍为许可证、安全渠道、production 模型 provenance/App 接线、Developer ID 公证和真人 dogfood；依赖变更必须同时通过离线 baseline、live OSV 与 NOTICE provenance |
| 2026-07-13 | 焦点路径收尾后的产品复审发现两个隐蔽边界：Prompt 瞬态正文模型可被误用为持久 DTO，regex/sentinel 渲染缺少统一资源上限；初始设置快照挂起时，工作流、词汇或模型准备会从空内存集合整表覆盖磁盘旧库。另行评估确认 group action 若直接开启仍缺 revision-bound grant、专用 one-shot lease、lineage 传播、durable outbox 与执行收据 | Prompt 只持久化 canonical content-free evidence；设置按“标量逐 key 合并、集合加载前拒绝 mutation”划界；group action 继续 feature-off，不用一个 capability Bool 掩盖跨层执行合同缺失 | Prompt renderer 改为有界单遍状态机，瞬态 context/result 不再 Codable；summary 强制 `redacted ⊆ missing ⊆ used`、used-order、唯一性和计数边界。AppModel/UI 同时阻止加载期工作流/词汇/下载模型整表写入，运行与 Speech Check 也不能用默认值覆盖 provider 设置或删除 Keychain 凭据；WhisperKit 派生 option 在 backing 未变化时覆盖旧持久值，加载期 preset 只在恢复后准备最终选择。125 项 AppModel 与 29 项 Prompt/Privacy 定向测试通过；最终完整 preflight 为 1166 项、1 项 expected skip、0 失败。组 action 保持关闭 | P0 仍为许可证、安全渠道、production 模型 provenance/App 接线、Developer ID 公证和真人 dogfood；P1 先做 typed plan + revision digest/grant，再独立实现 lease/outbox/receipt/VoiceOver 验收，最后才允许启用 |

| 2026-07-13 | 最后一轮产品复审发现非文本控件的辅助功能标签不完整、历史维护完成后的投影读取未显式归入 shutdown、SwiftPM 暴露了内部产品、WhisperKit 修复竞态可能误隔离新对象，Markdown 追加也缺少可证明的原子发布/元数据/并发边界 | 不增加新功能；把 UI 可理解性、生命周期、公共产品面、模型修复和本地文件输出各自交给单一 typed owner，并明确自动化证明与真人验收的分界 | 双语非空 AX 标签由 L10n 测试固定；历史投影与周期维护纳入终止屏障；包只公开 `RillApp`；WhisperKit 仅对原身份执行一次受权修复。Markdown 以同目录描述符事务保留既有元数据，排斥 linked/special/oversize/non-UTF-8 目标，并在 SWAP 后身份无法证明时保留双方现场、返回 indeterminate 而不回滚。最终 `release.sh` 通过 36 项发布策略、Universal App、9 项归因、Apple Development 签名 DMG 与全量 1198 项测试，1 项 expected skip、0 失败；Dashboard → Clipboard → History 的连续侧栏方向键由 hosted AppKit 覆盖，但不替代真人 VoiceOver、双输入法或 macOS 14 实机验收 | P0 仍为 Rill 许可证/私密安全渠道、production 模型 provenance/App 接线、Developer ID 公证和真人 dogfood；P1 保留完整 VoiceOver、双输入法、Intel/macOS 14 与 external Shortcuts/Markdown 实际目标验收；group action 继续关闭 |
| 2026-07-13 | 产品级复审确认全局事件 tap 安装失败仍可能显示语音设置完成，临时文字注入会丢失未投影到 ClipboardSnapshot 的 RTF/自定义类型，History 与 Diagnostics 的 repository 错误又会显示成空数据 | 用真实安装结果而非权限推断驱动 readiness；把临时系统剪贴板事务与历史投影模型分离；为读取页面建立 typed loading/failed/loaded 状态 | Fn、全局面板快捷键与 Command-V 共用的 active tap 现在只有安装成功才标记就绪，授权变化可重试；临时粘贴逐 item 无损保存全部 type/data/order，失败前不可读类型 fail-closed，用户新复制优先；History/Diagnostics 故障提供双语重试且不显示普通空态。全量 1209 项测试，1 项 expected skip、0 失败 | 后续复审已继续补齐通用设置失败可见性和剪贴板 mutation 退出所有权；下一项是超过 50 条历史的统一分页/搜索。外部 P0 仍为 production 模型 provenance、Developer ID 公证、公开发布决策与真人 dogfood |
| 2026-07-13 | 最低系统与供应链复审确认 WhisperKit 0.17 在 Apple Silicon 会弱依赖 macOS 14 不具备的 `Float16` witness；Argmax OSS 1.0 修复该风险，但两份 SwiftPM manifest 的重复 CLI alias 会阻断 Xcode Universal build。生产 App 同时仍从 legacy loader 自动下载未受审模型，SDK 已链接和历史下载 ID 会误报可用 | 升级到官方 v1.0 并把最低系统 witness 变成二进制门禁；用可逆、exact-hash 的 manifest-only 构建兼容层保留标准资源/签名模型；生产默认改为 release-owned capability，真实证据缺失时明确 fail-closed | Argmax OSS 1.0.0 与完整 NOTICE exact 固定；Universal verifier 要求 arm64 witness 定义来自 `ArgmaxCore`。构建 wrapper 核对 commit 与两份 manifest 前后摘要，临时移除重复 alias 后必定恢复。manifest SHA-256 在解析前锚定；factory 立即校验 source/license/host，App、Settings、Dashboard、预热、离线与实时链路均共享同一 trusted/unavailable capability。当前无受审模型资源，因此不会下载或用旧 ID 宣告 Ready。完整 preflight 通过 38 项发布策略、Universal Release/App 装配、ad-hoc 严格签名、9 项归因和全量 1271 项测试，1 项 expected skip、0 失败；Dashboard → Clipboard 的 11 项 hosted focus 回归单独通过 | P0：选择真实默认 variant，取得逐来源许可证据/revision/host 并完成联网物化、禁网识别与篡改拒绝；决定 Rill 许可证/安全渠道并完成 Developer ID 公证和真人 dogfood。P1：向上游提交重复 CLI alias 修复，官方版本发布后删除兼容层；保留 Intel/macOS 14、完整 VoiceOver 与双输入法人工验收 |
| 2026-07-13 | 本轮架构/产品收口发现：主窗口 Dashboard → Clipboard、全局历史 Retry 与剪贴板持久化 Retry 都有瞬态焦点所有权；DeliveryStack 的不可读/保存失败不能继续静默降级；Settings 的 collection/scalar 读取、保存与退出也需要分域生命周期 | 不新增平行页面或第二套存储；由 MainShell 持有跨页焦点，瞬态 Retry 在移除前迁往稳定控件；DeliveryStack 和 Settings 以 typed availability、单一 task owner 与 shutdown drain 明确 fail-closed/恢复边界 | Dashboard → Clipboard hosted focus 合同保持不抢 Search；剪贴板状态不可读或坐标冲突不覆盖旧数据，保存失败自动退避且主窗口提供单飞立即重试，退出完成最终 drain；设置集合/标量独立隔离损坏值，settings-read owner 与 save barrier 拒绝并排空终止期工作；global history Retry 以完整 request identity 拒绝 stale publication，并在按钮消失时把焦点交回搜索框。完整 preflight 通过 Gitleaks 8.30.1 双域扫描、38 项发布策略、Universal Release/App 装配、ad-hoc 临时严格签名、9 项许可归因与全量 1339 项测试，结果为 1 项 expected skip、0 失败 | 外部 P0 仍为真实默认模型 provenance/App 接线、Rill 许可证/安全渠道、Developer ID 公证与真人 dogfood；本轮还需用候选包完成人工持久化故障、完整 VoiceOver、双输入法和 Intel/macOS 14 验收 |
| 2026-07-13 | 后续跨表面审计发现菜单栏可绕过 scalar-domain fail-closed，collection/privacy Retry 缺少退出所有权，History Retry 与全局搜索 toolbar 存在焦点边界；Runtime 同时忽略已保存的 `fallbackPriority`，持久化只验证重复 ID 而未验证完整引用图 | 标量写入统一经过 AppModel commands，设置读取统一进入 task owner；Runtime 与 UI 共享 Core fallback 排序合同；持久状态在 actor 赋值前验证完整图；瞬态控件消失前按键盘/VoiceOver 通道迁往稳定控件 | 损坏设置域与 shutdown 后写入不再产生假成功；退出取消并排空 collection/privacy 恢复。History Retry 回到 scope picker，全局搜索独占 sidebar/detail/toolbar 且重复 `Cmd-F` 只重新聚焦。跨组回退以较小正优先级先行，悬空/重复/组不一致图全部保留原始字节并 fail-closed；debounce 取消改为确定性 gate。最终完整 preflight 通过 38 项发布策略、Universal Release/App 装配、ad-hoc 临时严格签名、9 项许可归因与全量 1362 项测试，1 项 expected skip、0 失败 | 下一项本地优先级是为活动剪贴板条目与图片字节建立明确存储预算；外部 P0 仍为真实默认模型 provenance、Rill 许可证/安全渠道、Developer ID 公证与真人 dogfood |
| 2026-07-13 | 官方资料显示：[Raycast](https://manual.raycast.com/clipboard-history) 提供 1 天 / 1 周 / 1 月 / 3 月，Pro 增加 6 月 / 1 年 / 无限；[Paste](https://pasteapp.io/help/control-history-retention) 默认 30 天，可选 1 天 / 1 周 / 1 月 / 1 年 / 永久，且只让未置顶历史老化，并会[默认跳过 confidential / transient 内容且允许排除 App](https://pasteapp.io/help/exclude-apps)；Maccy 当前源码把历史默认设为 [200](https://github.com/p0deje/Maccy/blob/3fe63ec3a0eabf6605d40c48b3c85b7bf555c86a/Maccy/Extensions/Defaults.Keys%2BNames.swift)，设置界面限制为 [1...999](https://github.com/p0deje/Maccy/blob/3fe63ec3a0eabf6605d40c48b3c85b7bf555c86a/Maccy/Settings/StorageSettingsPane.swift)，并按[未置顶条目](https://github.com/p0deje/Maccy/blob/3fe63ec3a0eabf6605d40c48b3c85b7bf555c86a/Maccy/Observables/History.swift)执行上限；[Alfred](https://www.alfredapp.com/help/features/clipboard/) 按类型提供 24 小时 / 7 天 / 1 月 / 3 月留存，并允许限制最大文本 clip、排除 App 和 Concealed 数据 | 时间/条数留存解决“多久、多少条”，但不足以约束图片、富格式和 JSON/Base64 放大，也不能表达 Stack / Queue 活动项与 in-flight paste lease 的不可逐出语义；Rill 采用时间策略 + typed shape/byte budget + semantic capacity，不复制 pinned 作为另一套活动模型 | schema 7 限制 1000 个活动项、每组 500 个活动项、500 个仅历史项、256 个自定义组、1024 条 App 路由、文本 1 MiB、图片 32 MiB、编码总量 64 MiB；所有正文和元数据先做原始校验，只逐出最旧的仅历史项，旧版未知大小不会进入普通整数记账或后台重编码。assignment / group 以 lease-aware plan 原子提交，`loadUnavailable` 提供显式 destructive reset；临时富剪贴板有 128 item / 256 representation / 64 MiB 预算，ImageIO single-flight 移出 MainActor，恢复失败保留 archive 且退出排空；完整 preflight 通过 38/38 发布策略、Universal Release、App bundle smoke 与全量 1439/1439 | 下一本地优先级是把当前单体 JSON/Base64 持久化拆成受保护 metadata + image blobs 的原子迁移；外部 P0 仍为真实默认模型 provenance、许可证/安全渠道、Developer ID 公证与真人 dogfood |

mapping / hotword 的 dogfood 指标：专业词一次通过率、手动编辑次数、误替换率、规则命中/省略诊断。必须分别统计确定性替换与非确定性识别提示，避免把二者效果混为一谈。

### 9.3 下一轮候选

1. **默认模型供应链与晋级（P0）**：公开构建只把 Qwen3-ASR 0.6B INT8 放入 sherpa-onnx 产品目录，并以精确 URL、字节数、SHA-256、required layout、canonical installed-file inventory、私有原子安装和 native runtime 接线约束其供应链。SenseVoiceSmall 只保留固定来源的内部兼容/未来评估身份，不出现在公开设置、下载或推荐路径；任何公开提案都必须先通过产品与法律审核。Qwen 剩余门禁是真人多语 dogfood、完整支持机型与离线/取消/退出验收。
2. **真实设备与 ASR dogfood（P0）**：验证 sherpa Qwen3-ASR 0.6B 与 MLX Qwen3-ASR 1.7B 的本地热词、延迟、权限和编辑成本；同时故意触发一次可恢复识别失败，验证加密保留、当前策略重试、成功后删除和不重复输出，避免只凭 fixture 判断产品效果。
3. **公开发布就绪（P0）**：本地 readiness、Apple Development、最终 DMG 顺序门禁、图标、系统本地化与技术隐私说明已通过；下一步决定 Rill 自身许可证、公开渠道与私密安全报告路径，并用 Developer ID/notary profile 执行真实最终 DMG 公证与干净账户安装验收。
4. **组执行前置（P1）**：content-free scheduler、严格配置解析、durable fixed receipt、History 原因、exact item revision、lineage/8-hop cap、surface policy、source-aware zero-confirmation preflight、one-shot item lease 与 replacement CAS 已完成。下一步在任何 action 前增加 workflow-revision-bound persistent grant、one-shot group action lease 与 effect-adjacent final revalidation；在完整人工验收前继续关闭执行入口。默认不记录正文、精确长度或可字典恢复的无盐正文 hash。
5. **Command Mode（P1）**：只在接入真实本地或 BYOK transformer 后开放，并显示使用的上下文、privacy decision 与离机收据。
6. **剪贴板交互增强（条件式 P2）**：置顶、只看置顶与多关键词联合搜索已经完成，并保持与 Stack / Queue / List 活动语义分离。下一步先用本地、content-free 的 dogfood 记录复用率与格式失败计数；只有数据证明痛点后，才评估条目重命名和显式 `Paste as…`，并继续受敏感 App、来源身份和条目版本约束。

## 10. 参考来源

- Wispr Flow features / docs: <https://wisprflow.ai/features>, <https://docs.wisprflow.ai/articles/2772472373-what-is-flow>, <https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary>, <https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness>, <https://docs.wisprflow.ai/articles/4709791908-understanding-privacy-mode-and-cloud-sync>
- Superwhisper docs: <https://superwhisper.com/>, <https://superwhisper.com/docs/get-started/introduction>, <https://superwhisper.com/docs/get-started/transcribe-history>, <https://superwhisper.com/docs/modes/custom>, <https://superwhisper.com/docs/modes/super>, <https://superwhisper.com/docs/security/sensitive-data>
- Type4Me: <https://github.com/joewongjc/type4me>, <https://github.com/joewongjc/type4me/releases>; 2026-07-11 能力快照固定到 commit `5a899d9`: <https://github.com/joewongjc/type4me/tree/5a899d9cdad89a9ee47c53f01edaa701d385b17b>
- MacWhisper: <https://macwhisper.org/>, <https://macwhisper.helpscoutdocs.com/article/14-how-to-use-the-dictation-feature>, <https://macwhisper.helpscoutdocs.com/article/53-integrating-macwhisper-with-other-services>
- VoiceInk / open-wispr / Whispur / Fisper: <https://github.com/Beingpax/VoiceInk>, <https://github.com/human37/open-wispr>, <https://whispur.app/>, <https://fisper.app/>
- Raycast Clipboard: <https://www.raycast.com/core-features/clipboard-history>
- Raycast current Clipboard History retention / disabled applications / v2 / troubleshooting: <https://manual.raycast.com/clipboard-history>, <https://manual.raycast.com/new-in-v2>, <https://manual.raycast.com/troubleshooting>
- Alfred triggers / debugger / hotkey conflicts: <https://www.alfredapp.com/help/workflows/triggers/>, <https://www.alfredapp.com/help/workflows/advanced/debugger/>, <https://www.alfredapp.com/help/workflows/triggers/hotkey/>
- Keyboard Maestro activation / clipboard trigger / debugger: <https://wiki.keyboardmaestro.com/manual/Macro_Triggers>, <https://wiki.keyboardmaestro.com/Macro_Activation>, <https://wiki.keyboardmaestro.com/trigger/Clipboard_Changed>, <https://wiki.keyboardmaestro.com/manual/Macro_Debugger>
- Hazel rule preview: <https://www.noodlesoft.com/manual/hazel/work-with-folders-rules/create-edit-rules/preview-a-rule/>
- Apple Shortcuts execution / flow control / CLI: <https://support.apple.com/guide/shortcuts-mac/run-a-shortcut-from-the-app-apd5ba077760/mac>, <https://support.apple.com/guide/shortcuts-mac/control-the-flow-of-actions-apd25a01237e/mac>, <https://support.apple.com/en-nz/guide/shortcuts-mac/-apd455c82f02/mac>
- Wispr Flow Command / privacy / changelog: <https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode>, <https://docs.wisprflow.ai/articles/4709791908-understanding-privacy-mode-and-cloud-sync>, <https://wisprflow.ai/whats-new>
- Willow Scribe / dictionary / privacy: <https://help.willowvoice.com/en/articles/15043797-introduction-to-scribe-in-willow>, <https://help.willowvoice.com/en/articles/13183918-using-personal-dictionary-and-shortcuts>, <https://help.willowvoice.com/en/articles/12854269-how-willow-protects-your-data-and-privacy>
- Aqua Voice guide / changelog: <https://aquavoice.com/guide/index>, <https://aquavoice.com/changelog>
- Monologue / Typeless: <https://www.monologue.to/>, <https://www.typeless.com/help/release-notes/macos>
- Handy / VoiceInk / FluidVoice / open-wispr / OpenWhispr: <https://github.com/cjpais/Handy>, <https://github.com/cjpais/Handy/issues/1104>, <https://github.com/cjpais/Handy/issues/1483>, <https://github.com/Beingpax/VoiceInk>, <https://github.com/altic-dev/FluidVoice>, <https://github.com/human37/open-wispr>, <https://github.com/OpenWhispr/openwhispr>
- Wispr Flow failed recording recovery: <https://docs.wisprflow.ai/articles/4984532368-fix-taking-longer-than-usual-and-transcription-errors>
- Paste retention / capture exclusions: <https://pasteapp.io/help/control-history-retention>, <https://pasteapp.io/help/what-paste-captures>, <https://pasteapp.io/help/exclude-apps>
- Maccy capacity policy at commit `3fe63ec`: <https://github.com/p0deje/Maccy/blob/3fe63ec3a0eabf6605d40c48b3c85b7bf555c86a/Maccy/Extensions/Defaults.Keys%2BNames.swift>, <https://github.com/p0deje/Maccy/blob/3fe63ec3a0eabf6605d40c48b3c85b7bf555c86a/Maccy/Settings/StorageSettingsPane.swift>, <https://github.com/p0deje/Maccy/blob/3fe63ec3a0eabf6605d40c48b3c85b7bf555c86a/Maccy/Observables/History.swift>
- Alfred Clipboard History retention / maximum clip size / exclusions: <https://www.alfredapp.com/help/features/clipboard/>
- PastePal / CleanClip / PasteBar: <https://indiegoodies.com/pastepal>, <https://cleanclip.cc/>, <https://github.com/PasteBar/PasteBarApp>
- Apple notarization guidance: <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>

## 11. Structured workflow editor references (2026-09-15)

The workflow editor adopts file-based configuration and a native, independent
window with vertical steps. The following official references informed the
specific interactions; these are reference patterns, not feature-parity claims.

| Reference | Pattern adopted in Rill | Scope |
| --- | --- | --- |
| [n8n execution modes](https://raw.githubusercontent.com/n8n-io/n8n-docs/main/docs/build/understand-workflows/understand-executions/types-of-executions.md) | Test a workflow or stop at a selected step; pin generated sample outputs. | Samples stay in the editor. Rill has structured sequences rather than an arbitrary graph canvas. |
| [Apple Shortcuts If actions](https://support.apple.com/guide/shortcuts-mac/use-if-actions-apd83dcd1b51/mac) | Vertically nested Then/Else blocks with explicit data flow. | Native form controls and bounded nesting. |
| [Kestra flow UI](https://kestra.io/docs/ui/flows) | Source and visual editing share the same configuration. | TOML is authoritative; invalid source cannot be overwritten by a reduced form model. |
| [Home Assistant troubleshooting](https://www.home-assistant.io/docs/automation/troubleshooting/) | Show which path ran and where execution stopped. | Persist fixed result codes and coarse timing; full test text is transient. |
| [Alfred editor and palette](https://www.alfredapp.com/help/workflows/getting-started/editor-and-palette/) | Add explicit actions and inspect their configuration locally. | A compact native step menu rather than a general integration marketplace. |
| [Node-RED projects](https://nodered.org/docs/user-guide/projects/) | Treat workflows as versionable author-owned files. | One XDG TOML per workflow, external edit detection, bounded local history. |
| [Dify workflow quick start](https://docs.dify.ai/en/quick-start) | Inspect processing output before committing to production effects. | A process test suppresses all outputs; real output is a separate explicit action. |

Implementation and schema contracts are documented in
[workflow-toml.md](../../workflow-toml.md). Native visual QA and physical microphone/Fn
acceptance remain separate from parser and runtime test results.
