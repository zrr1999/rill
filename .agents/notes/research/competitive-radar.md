# Rill 竞品雷达与持续改进队列

> 状态：当前决策输入
> 最近核验：2026-08-12
> 适用范围：macOS 语音输入、Record 复用/路由与可观察工作流
> 事实优先级：当前源码与测试 > 竞品官方文档/发布说明 > 产品营销页；官方来源冲突时标记未知

## 产品判断

Rill 不应扩成另一个启动器、会议记录器或通用 AI 聊天框。相邻产品已经把
剪贴板历史、选中文本改写、App 风格和通用命令入口商品化；Rill 更有价值的
链路是：

```text
local voice -> explicit context -> immutable Record -> observable workflow
            -> routed sink -> durable receipt
```

因此，每轮竞品学习都必须改善这条链路的成功率、可恢复性、可解释性或复用
效率。只增加模型、入口或设置数量不算进步。

## 直接竞品

| 产品 | 当前优势 | 值得学习 | 不直接复制 |
|---|---|---|---|
| [Wispr Flow](https://wisprflow.ai/features) | 主听写循环完成度高；词典、Style、[失败恢复](https://docs.wisprflow.ai/articles/2503460374-retry-failed-transcriptions)与设备本地历史形成一体化体验；词典和 Style 可跨端同步，但[听写历史当前不跨端同步](https://docs.wisprflow.ai/articles/5284722493-sync-flow-across-your-devices) | 让失败后恢复和按任务切换成为主路径，而不是藏在设置中；给用户可见的学习反馈 | 默认云端转写、隐式抓取上下文、跨端同步与会议记录器。其 [Privacy Mode 与 Cloud Sync](https://docs.wisprflow.ai/articles/4709791908-understanding-privacy-mode-and-cloud-sync) 是不同控制项，不能把“隐私模式”误写成本地处理 |
| [Superwhisper](https://superwhisper.com/docs/security/sensitive-data) | 把语音识别与文本后处理拆成两阶段；Mode、上下文开关与[历史重处理](https://superwhisper.com/docs/get-started/interface-history)都可配置 | 在产品上清楚区分“识别了什么”和“之后如何变换”；允许基于同一来源重试不同处理 | 模型目录竞赛、会议套件和宽泛 agent 能力。首页、Pro 文档与 [模型页](https://superwhisper.com/models) 的免费/付费能力描述并不完全一致，套餐事实暂不用于决策 |
| [VoiceInk](https://tryvoiceink.com/) | 原生、开源、本地优先；按 App/网站/触发方式选择 Mode，确定性替换与上下文开关相互独立 | 保持 Mode、词汇提示、确定性替换和上下文授权为不同机制；上下文默认显式选择 | shell 命令、屏幕 OCR、通用聊天和 provider 数量扩张；这些会扩大权限面并稀释 Record 路由 |
| [MacWhisper](https://www.macwhisper.com/) | 文件/录音转写、来源音频、历史编辑、搜索和导出形成成熟的“转写资产”工作站 | 让来源与编辑结果成为可管理资产；历史应支持恢复而不只是浏览 | 重型文件转写、会议管理和长文编辑器；Rill 只吸收来源保留与恢复心智 |
| [Typeless](https://www.typeless.com/help/release-notes/macos) | 用 Dictate / Translate / Ask 这样的任务名降低模式理解成本；[云端处理](https://www.typeless.com/data-controls)与[设备本地历史](https://www.typeless.com/help/troubleshooting/missing-transcript)分别说明 | 用任务结果命名用户入口；为纠错、翻译和保真建立可重复 fixture | 必需云端、网页产品面和模糊的自动语义；Rill 的来源、上下文和目的地必须运行前可解释 |
| [TypeOff](https://typeoff.ai/changelog) | Fn 按住/切换、实时预览、本地 fallback、结果窗口策略、失败重试、麦克风 fallback、中英混排间距和润色强度都围绕主循环 | 优先学习结果显示/恢复策略、中英混排确定性格式化、设备失败回退和少量可理解的润色强度 | 登录依赖、默认云端、游戏化与 Voice Notes。其 [FAQ](https://www.typeoff.ai/docs/faq) 与 [隐私政策](https://typeoff.ai/privacy) 对云端音频是否保留相互冲突；转写文本和活动应用的账号关联保存则由当前隐私政策明确确认，因此不能宣称云端零留存 |

共同信号：用户感知到的完成度主要来自“开始可靠、状态明确、结果可恢复、
术语命中、输出正确”，而不是模型数量。Rill 的本地优先是基础优势，但只有
在主循环同样闭环时才会转化成产品优势。

## 相邻竞品

| 产品/系统 | 已商品化的能力 | 对 Rill 的边界启示 |
|---|---|---|
| [macOS Clipboard History](https://support.apple.com/en-mide/guide/mac-help/mchl40d5b86b/mac) 与 [Writing Tools](https://support.apple.com/guide/mac-help/find-the-right-words-with-writing-tools-mchldcd6c260/26/mac/26) | 系统级历史、改写、查看原文、替换和撤销 | 通用历史/改写不是差异化；Rill 要解释来源、派生关系、路由和回执 |
| [Raycast Clipboard](https://manual.raycast.com/clipboard-history)、[Dictation](https://manual.raycast.com/ai/dictation) 与 [AI Commands](https://manual.raycast.com/ai/ai-commands) | 在一个搜索入口中复用历史、听写和处理选中文本 | 不追 launcher 宽度；学习快捷的“选中对象 -> 明确动作”交互和工具调用确认 |
| [Alfred Universal Actions](https://www.alfredapp.com/help/features/universal-actions/) | 任何选中对象可进入动作链；[模板](https://www.alfredapp.com/help/workflows/templates/)和 [debugger](https://www.alfredapp.com/help/workflows/advanced/debugger/) 降低工作流调试成本 | Rill 可提供少量任务模板和固定原因调试，不开放任意脚本执行面 |
| [Paste](https://pasteapp.io/help/organize-with-pinboards) | [搜索/筛选](https://pasteapp.io/help/search-and-filters)、Pinboards、[Stack](https://pasteapp.io/help/using-paste-stack) 和直接复用形成成熟内容工作台 | Record Workspace 应先让现有 Stack/Queue/List 真正可用，再扩展筛选和外部 API |
| [CleanClip](https://cleanclip.cc/) | 光标附近面板、前五项数字直贴、队列与前台 App 配合，交互路径短 | 学习“打开面板 -> 选择 -> 回到原 App”的低摩擦闭环，不复制完整剪贴板产品面 |
| [PopClip](https://www.popclip.app/guide/extensions) | 选中文本直接进入窄动作 | 后续可做显式 selected-text voice instruction；上下文必须冻结、授权且有派生 Record |

## 借鉴优先级

评分为 1–5：价值越高越好，成本越高越难，Rill 适配度越高越符合产品主链。

| 优先级 | 改进切片 | 竞品证据 | 价值 | 成本 | 适配度 | 决策 |
|---|---|---|---:|---:|---:|---|
| P0 | **List 选中 Record -> 送回上一 App** | Paste/CleanClip 的直接复用路径 | 5 | 2 | 5 | 本轮实现。先闭合已经存在但 UI 不可用的 manual selection 语义 |
| P0 | 结果显示与失败恢复策略 | Wispr Flow、TypeOff | 5 | 2 | 5 | 下一轮先盘点现有错误/恢复入口，再选择一个固定失败类闭环 |
| P0 | 中英/中日与拉丁字符确定性间距 transformer | TypeOff | 5 | 1 | 5 | 小而可测；必须是可关闭、保真、非 LLM 的纯变换 |
| P1 | 显式选中文本语音指令 | Wispr Flow Command、Raycast、PopClip | 5 | 3 | 5 | 使用冻结上下文、派生 Record、授权目的地和回执；不读取整屏 |
| P1 | 少量任务模板与润色强度 | Typeless、Superwhisper、TypeOff | 4 | 2 | 4 | 只包装已有工作流机制，不复制竞品的模式目录 |
| P1 | 历史来源重处理 | Superwhisper、VoiceInk | 4 | 3 | 4 | 先定义来源保留和隐私合同，再开放重试 |
| P1 | Record 分面搜索与快速面板 | Paste、Raycast | 4 | 3 | 4 | 用真实复用数据决定字段，不先做通用 launcher |
| P2 | 受记录集、隐私策略和回执约束的本地 Record API | [Paste MCP](https://pasteapp.io/help/paste-mcp) | 3 | 4 | 3 | 证明本地 UI 路由价值之后再评估 |

以下项目不进入近期队列：会议/Notetaker、跨设备同步、网页搜索、应用/文件
启动器、通用聊天、长期 agent memory、隐式屏幕 OCR、任意 shell/插件执行和更多
云端 ASR provider。

## 本轮切片：让 List 的 manual 语义真正可用

当前 Store 已定义 `selectionPolicy.manual`，且在没有明确 membership 时拒绝投递；
但所有现有入口只请求“下一条”，Record Workspace 选中记录后也没有“使用”
动作。结果是产品声称支持 List 手动选择，用户却无法完成一次投递。

本轮验收合同：

1. 只有浮动面板中、手动 List 内、仍然 active 的已选 membership 显示动作。
2. 点击后冻结 exact `RecordID + MembershipID + revision`，隐藏面板并恢复打开
   面板前的目标 App。
3. 通过既有 Runtime lease、focused-application action 和 receipt 路径投递；UI
   不直接写系统剪贴板。
4. 目标 App、Record revision 或 membership 漂移时 fail closed；不得悄悄改投
   另一条记录。
5. List 的 retain 策略保持不变，图片/文件继续使用既有有界临时
   pasteboard 事务。
6. 主窗口没有可信的“上一 App”目标时不显示同名动作。

这项改进比先做中英间距更优先：间距能改善文本外观，但 manual List 当前是一个
已经公开的核心领域语义却没有产品闭环；修复它同时验证 Rill 相对通用听写工具
更独特的 Record 复用与路由价值。

本轮自动验证已覆盖 exact membership、List retain、目标 App 漂移、嵌套临时
pasteboard 恢复、持久化失败回滚、并发图写串行化和面板 shutdown；已提交输出的
剪贴板恢复失败会按成功投递结算并给出不可重试提示，settlement 重试也保持原
action 只执行一次。打包 App 中的
Spaces/全屏焦点恢复、真实图片/文件投递、运行中撤销辅助功能权限和退出时恢复仍需
dogfood，未用单元测试结论替代。

## 持续改进协议

每轮只推进一个可验证切片：

1. **刷新**：查看上述直接竞品的官方发布说明，并记录核验日期；营销页与隐私
   政策分开取证。
2. **对照**：用当前源码、测试和打包 App 对照，不复用历史计划里的“已实现”
   结论。
3. **排序**：用用户价值、成本、Rill 适配度、隐私/权限增量和现有边界复用率
   重新排序。
4. **实现**：只选一个端到端切片；机制放在 Core/Runtime，策略留在显式边界，
   UI 只发用户意图。
5. **验证**：至少覆盖成功、漂移/失败、无副作用三条路径；硬件、焦点、权限与
   安装包行为必须另列人工验收，不能由单元测试代替。
6. **复盘**：记录结果、未验证项和下一候选；没有真实收益证据的功能不继续扩张。

触发下一轮的条件：当前切片通过自动检查并完成一次打包 App dogfood，或上述
重点竞品出现改变 Rill 主链判断的正式版本。持续改进不等于持续扩大范围。
