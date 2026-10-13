# 工作流可观测性改进计划

> 来源：`docs/competitive-research.md` 与 `docs/improvement-plan.md`。
> 目标：让 Rill 的语音工作流、剪贴板组事件和自动润色可解释、可调试、可回放。

## 1. 现状观察

当前代码已经有可观测性的基础：

- `EventBus` 发布 `runStarted`、`contextCaptured`、`recognitionCompleted`、`transformationApplied`、`actionExecuted`、`runCompleted`、`runFailed` 等事件。
- `SessionCoordinator.recordStage` 会写入 `DiagnosticEvent(event: "session.stage")`。
- `DiagnosticsRecorder` 支持内存快照和 repository 持久化。
- `ClipboardCaptureTag.polishGenerated` 与 `excludingTag(.polishGenerated)` 已用于防止自动润色循环。
- Workflows 页已有 dynamic content-free Explain：按当前 resolved route 展示 fixed-enum 输入、处理、全部输出效果、目的地、隐私原因与状态；预览只读取 privacy-safe 快照，不调用 provider、确认或完整上下文读取。
- 生产执行只接受 Runtime 创建、与 exact workflow 绑定的 opaque authorization；非音频工作流和剪贴板 replay 也不能绕过该边界。

本计划最初针对运行事件分散、用户或开发者难以回答的六个问题；后续章节保留这些设计输入，并记录 receipt-first 运行历史、固定跳过原因与只读 dry-run 的落地状态：

1. 这个工作流为什么触发？
2. 它读取了哪些上下文？
3. 哪一步改了文本？
4. 为什么某个组事件被跳过？
5. 防循环机制是否生效？
6. 失败后能否重放或 dry-run？

## 2. 设计原则

1. **不新增黑盒自动化**：任何自动触发都必须能解释触发来源和跳过原因。
2. **Runtime 是账本写入者**：终态收据由持有 pipeline 的 Runtime 直接生成并先持久化；`EventBus` 只负责 UI fan-out，diagnostics 只负责排障，二者都不能反向聚合成 durable truth。
3. **不生成正文指纹**：收据和默认 diagnostics 不保存正文、preview、精确字符数、行数、无盐 hash/digest、名称或自由 metadata，避免短文本字典恢复与跨库关联。
4. **闭合集合与有界详情**：触发、终态、失败、跳过、动作结果和耗时均使用稳定 enum；耗时只保存 bucket，动作详情有硬上限和 `detailsTruncated`。
5. **本地数据保护与统一留存**：完整 receipt payload 使用 Keychain 根密钥与 typed AAD 加密，跟随运行历史一起 prune、clear、checkpoint 和物理残留清理。
6. **可测试优先**：receipt 是带显式 schema 的普通 `Codable` model，能做严格解码、canary 和迁移测试。

## 3. 已实现模型：WorkflowRunReceipt

```swift
public enum WorkflowRunOutcome: String, Codable, Sendable, Equatable {
    case completed
    case partiallyCompleted
    case failed
    case cancelled
    case skipped
}

public enum WorkflowRunTriggerKind: String, Codable, Sendable, Equatable {
    case manual
    case menuBar
    case hotkey
    case wakeWord
    case clipboardGroupEvent
    case stackDelivery
    case clipboardUse
    case clipboardReplay
    case failedAudioRecovery
}

public enum WorkflowRunDurationBucket: String, Codable, Sendable, Equatable {
    case under250ms, ms250To999, s1To4, s5To14, s15To59, m1Plus, unavailable
}

public struct WorkflowActionReceipt: Codable, Sendable, Equatable {
    public var actionIndex: Int
    public var result: WorkflowActionResultCode
    public var duration: WorkflowRunDurationBucket
}

public struct WorkflowRunReceipt: Identifiable, Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var runID: UUID
    public var workflowID: UUID?
    public var trigger: WorkflowRunTriggerKind
    public var timestamp: Date
    public var duration: WorkflowRunDurationBucket
    public var termination: WorkflowRunTermination
    public var actionDetails: [WorkflowActionReceipt]
    public var detailsTruncated: Bool
}
```

`runID` / `workflowID` 仅作为本机加密存储的关联坐标；默认导出不得携带原始 UUID、精确时间或稳定关联 token。`timestamp` 只用于本地排序和留存。未来若为短时调试引入正文查看，必须放在独立、显式授权且不持久化的工具中，不能复用默认 receipt 或 diagnostics。

## 4. 组事件与防循环记录

`ClipboardGroupTriggerRule` 现在只接收无正文 `ClipboardGroupEventDescriptor`，并返回可解释结果而不是只返回 Bool：

```swift
public enum ClipboardGroupTriggerMatchOutcome: Codable, Sendable, Equatable {
    case matched
    case skipped(reason: ClipboardGroupTriggerSkipReason)
}

public enum ClipboardGroupTriggerSkipReason: String, Codable, Sendable, Equatable {
    case eventKindMismatch
    case sourceGroupMismatch
    case excludedByCaptureTag
    case conditionFailed
    case itemMissing
    case loopPrevented
}
```

Runtime scheduler 把匹配原因映射到 `WorkflowRunSkipCode`；disabled 与 unsupported 属于 scheduler 状态，而不是 trigger rule 条件。durable receipt 成功后才记录：

- `clipboard.trigger.matched`
- `clipboard.trigger.skipped`
- `clipboard.trigger.loop-prevented`

diagnostics 只能保存固定 `eventKind`、固定 `reason`、布尔状态和计数；不得保存 trigger/group/item 名称、UUID、tag 原值或可由用户控制的 code 字符串。需要关联时只使用 `DiagnosticEvent.runID`，并遵守运行历史留存。

这样用户能知道「自动润色没有发生」到底是因为 workflow disabled、tag 排除、防循环，还是条件不匹配。

## 5. 运行前解释设计

运行前解释的目标不是模拟正文处理，而是用内容无关的收据回答：

> 这个工作流依赖哪些输入类别、处理类型和输出效果，数据会去哪里，当前是否可以安全运行？

第一阶段由 Runtime 先把自动 recognizer 选择和内建 output mode 解析成
`WorkflowResolvedExecutionPlan`，再基于真实 component registries 和集中维护的内建 component
profile 生成 `WorkflowExplanationReceipt`。生产执行与解释必须复用同一个 resolver 和内建
push-to-talk 判定；未解析的自动选择只能生成 typed blocked 收据，不能用
manifest 中的占位 recognizer 或 action 推断实际执行路径。收据只允许 UUID、Bool、Int 和固定 enum，不包含工作流名称、
组件 ID、输入或输出正文、prompt、URL、文件路径、header、凭据、上下文快照或自由 metadata。
opaque resolved plan 还必须保存本次 `initiatedBy` binding；收据的 trigger 来自实际 invocation，
不能回退到 workflow 声明的 trigger。

Workflows UI 只允许预览已保存且当前 `WorkflowEditorDraft` 与保存版本完全一致的工作流；任何未保存的 recognizer、output 或其他可见改动都会禁用入口，避免用旧定义解释新草稿。切换工作流、删除工作流、关闭 sheet、应用离开 active、修改隐私设置或实际路由时必须取消或失效旧异步结果；返回前台或用户刷新时重新采集 privacy-only 快照。

最小解释能力：

1. 按固定类别和 usage 说明 trigger 与输入来源：麦克风是 required；本地 recognition hints 是 conditional，表示运行时可能传给所选本地模型，并不声称当前 options 一定包含热词。不要把同一 hints payload 再重复记为 vocabulary terms。
2. 在声明的 post-process steps 前列出 on-device `vocabularyMapping`，并标为 conditional；它表示本地规则可能生效，不声称当前一定存在匹配规则。其他 transform 列出类别及可用状态，不渲染 prompt 或变量。
3. 列出每个 action 的全部 output effects、来源 action index、配置状态和处理目的地，不回显配置值；例如复制 action 同时包含系统剪贴板写入和本地 history/storage 写入。
4. 查询 recognizer、transformer 和 action registry，但绝不调用 `recognize`、`transform` 或 `execute`。
5. 未知或缺失组件必须 fail-closed，且不能把未知组件的原始 ID 写进收据。
6. 隐私策略尚未基于当前上下文完成评估时，返回 typed issue 并保持 blocked；不能仅凭组件和配置齐全声称 ready。
7. 动态解释只读取 privacy-safe focus identity、clipboard descriptor/policy snapshot 和当前隐私设置，并复用真实运行闸门的 closed destination classifier 与 `PrivacyPolicy.evaluate`。它只蒸馏 fixed-enum status、reason 和 redacted input category，绝不调用云端确认、组件、完整 context provider 或网络。Shortcut 与文件输出在 Rill 内部分类为本机交接，但 UI 必须提示下游自动化可能联网、目标文件也可能同步，预览不能证明数据最终留在本机。
8. 动态评估后，完整本地计划可成为 `ready`，云端计划可成为 `requiresConfirmation`，策略阻断、设置不可用、未知目的地以及任何缺失/未知组件仍为 `blocked`。隐私允许不能覆盖静态计划问题。

`privacyReasons` 只保存固定枚举。收据不保存 `PrivacyPolicyDecision`、bundle ID、App 名、PID、
clipboard change count、正文或底层错误字符串；它只是运行前快照，不是授权凭证。真实运行仍须重新读取
context 和设置、重新执行策略，并在确认后再次校验策略未变化。

生产执行只接受 Runtime 创建且绑定 exact `WorkflowDefinition` 的 opaque
`AuthorizedWorkflowRunContext`。UI 只能转交 capability，不能读取、构造或序列化其中的 context；
接收 raw `ContextSnapshot` 的 Coordinator 入口保持 Runtime-internal。缺少 capability/raw authorized context
时，在 options、recognizer、transformer 与 action 前 fail-closed。剪贴板显式投递只采集 privacy-safe
focus identity，不把 selection 或当前 clipboard payload 放入 `ActionContext`。

同一授权动作同时覆盖需要录音和不需要录音的手动工作流，以及剪贴板历史 replay。授权先执行 execution policy 与 provider preflight，再通过 shared classifier 评估真实 workflow destinations，采集经策略遮蔽的完整 context 和 recognition options，最后封装为 workflow-bound capability。`PrivacyRunGate` 在本地无确认路径和云端确认后都会重新读取设置与目的地分类；策略结果或目的地变化时拒绝本次授权。完整 context 采集后还要复核 bundle/PID、Secure Input 与 clipboard change count，避免把早先的判断提交给已变化的来源。Replay/Replace 额外由 `DeliveryStack` 原子解析 exact item subject 与 transient source App identity：来源策略在任何云确认前先评估，并在目标授权后再次评估；来源的 cloud/workflow block 不会被当前前台 App 身份替代，identity 也不会进入 dry-run 收据或 scheduler descriptor。

延迟音频不直接保存可执行 context/options。Runtime 发行与 exact run/workflow 绑定的一次性 lease；queue 先 claim 并验证当前设置/目的地，再解析 deferred capture，然后 final revalidate 才取得 `AuthorizedWorkflowRunContext`。确认状态在 issuance、claim 和 finalization 间以 run 级 fixed state 传递；只有先前从未确认且当前新增云端确认要求时才弹出一次。失败录音 retry 使用同一两阶段语义，但绑定已移除 outputs 的 recovery workflow；最终拒绝时先删除解密明文并恢复 attempt，绝不进入 recognizer 或恢复保留分支。

redaction 规则属于执行合同而非 UI 提示：Secure Input 和未知焦点遮蔽 selection/clipboard，并停止 clipboard/workflow capture；未知焦点的云端路径额外阻断。`excludeFromWorkflowCapture` 条目仍可按历史策略保存，但其 clipboard payload 不进入 workflow context。动态收据只展示这些 fixed reasons 与 redacted input categories，不携带 bundle ID、App 名、PID、change count 或底层错误。

相邻的系统副作用也使用相同的“最终使用前复核”原则：

- StackPaste mirror/capture 在 payload read 前后与 mirror write 后比较 pasteboard descriptor/change count、焦点身份、Secure Input、策略决定和 capture-control revision；焦点/设置竞态、暂停/ignore-next 或 ownership 变化会丢弃 payload、恢复仍由 Rill 持有的原剪贴板并关闭 paste interception。
- 本地语音准备会校验受信模型身份和安装状态；内部 `finishing` 状态拒绝重复 start/finish，取消后不继续识别并清理托管临时音频。
- TextInjection 把 `inject.text` 绑定到运行开始时的 bundle/PID 最小身份，必要时尝试恢复目标 App，并在 Command-V 或每个键盘分块前复核。浮动剪贴板面板在任何 await 前锁定 content-free PID/bundle，恢复后 AppBootstrap 只采集一次当前 privacy context 并与锁定目标比较；A 被 B 抢焦点时 text/rich 均不调用 action。无法验证、激活失败或焦点漂移时 fail-closed；临时 clipboard 仍按 change count 条件恢复。诊断只记录固定事件、布尔状态、outcome 和长度/计数，不记录目标身份或正文。

正文级 prompt 预览不属于运行前解释。若未来确有调试需要，应放在用户明确授权的独立工具中，
遵守隐私策略并禁止持久化到解释收据或默认 diagnostics。

## 6. 重放设计

当前公开入口为 `replayClipboardItem(itemID:authorizedContext:replacingSourceItem:)`；UI 会先为 exact workflow 获取授权，raw workflow/context overload 仅供 Runtime 内部使用。建议在 UI/record 层把重放继续做成显式动作：

- 从 `WorkflowRunRecord` 找到仍受本地保留策略管理的 source clipboard item。
- 若原文仍在历史中，允许 replay。
- 若原文因隐私设置未保存，只允许展示「无法重放：输入未保存」。

重放必须生成新的 `runID`。默认 receipt 与 diagnostics 不保存 `replayOfRunID`：原运行与重放运行的稳定关联会扩大正文历史、剪贴板历史和诊断之间的可连接面。若 UI 需要在一次显式交互里展示来源关系，只能使用不持久化的会话内状态。

## 7. 最小实现顺序

### Phase 1：模型与记录聚合

1. **已完成**：在 `RillCore` 增加 versioned、content-free `WorkflowRunReceipt`、duration bucket 和有界 action detail。
2. **已完成**：增加独立 `WorkflowRunReceiptRepository` 与 Runtime recorder；durable insert 成功后只广播 content-free `runReceiptRepositoryChanged` 失效坐标。订阅者必须回读 repository，不能把通知当作收据仍存在的证明；insert 返回与 clear 之间的竞态因此 fail-closed。
3. **已完成**：SQLite v8 延续 typed AAD 加密 receipt payload 与 nullable closed trigger，并为 History、receipt、diagnostic 增加共享的 durable write generation。clear intent 在破坏性工作前持久化 CAS transition；旧 token 晚写拒绝，公共查询只承认当前 generation，新 token 不依赖 wall clock。v7 旧行迁到 generation 0，schema 4 pending clear 通过一次性 timestamp promotion 安全桥接。运行历史 retention、clear 和物理残留清理覆盖 receipt。
4. **已完成**：所有 Coordinator 入口、运行快照、完成与失败历史记录真实 trigger、动作终态、skip 与部分成功；只有 record trigger 与同 run receipt 不冲突的 voice-capture 记录可展示正文。两者均缺失或冲突时 fail-closed，不读取当前 workflow metadata/titleKey。History UI 以 durable receipt 为主时间线，并以 content-free 行显示 Stack、剪贴板与失败尝试。

### Phase 2：组事件跳过原因

1. **已完成**：DeliveryStack 直接向 Runtime scheduler 提交无正文 descriptor；EventBus 不承担调度正确性。
2. **已完成**：有界 FIFO 以背压等待而不是丢弃，event ID 去重和稳定 workflow 顺序只为路由候选生成 durable skipped receipt；receipt query/insert 不可用时 fail-closed，不声称 matched/skipped 已完成，也不记录底层错误正文。
3. **已完成**：`polishGenerated` 明确记录 `loop-prevented`，一般 exclusion、缺失 item、disabled 与 unsupported 使用各自固定原因；执行能力与用户启用状态是独立输入，当前生产能力明确归为 unsupported。
4. **已完成**：diagnostics 只保留 runID、固定 event kind/reason/outcome；History 与 accessibility 显示具体双语 skip reason。
5. **已完成**：退出先停事件生产者，再等待 DeliveryStack sink 摘除写屏障，最后 drain scheduler 已接纳事件；并发 mutation 的 scheduler/EventBus batch 保持相同 revision 顺序。
6. **已完成**：descriptor 绑定 per-item generation + revision，并携带只在内存中流转的 root lineage 与有序 workflow path；重复 workflow 或达到 8-hop 上限在 capability/disabled 判断前固定记录 `loopPrevented`。lineage ID/path 不进入 durable receipt 或 diagnostics。
7. **已完成的预检边界**：execution policy 现在区分 interactive capture、clipboard replay 与 clipboard group surface。DeliveryStack 只在 exact item incarnation 仍存在时向 Runtime 提供 transient source identity；non-interactive group preflight 只允许单一 `stack.push` replacement plan，按来源 App 评估 privacy，并把 requires-confirmation 固定拒绝，确认 callback 调用数为 0。
8. **保持关闭**：preflight 的 `ready` 不是授权 capability。scheduler 仍不读取正文、不调用 transformer/action；缺少 workflow-revision-bound 持久 grant、one-shot group action lease、effect 前最终复核和面板实机验收时，生产 `isExecutionSupported` 保持 false。

### Phase 3：运行前解释与 UI

1. **已完成**：增加 content-free workflow explain service、single resolved-plan 语义与 dynamic fixed-classification privacy evaluation。
2. **已完成**：在 Workflows UI 增加运行前解释入口、saved-draft guard、loading/stale-result cancellation、双语状态与隐私原因展示。
3. **已完成**：clipboard dry-run 使用纯模型、Runtime-owned exact prepare 和零副作用 planning service；当前/历史详情与右键菜单提供 `Paste / Replay / Replace` 只读影响预演，sheet-local 状态拒绝条目、工作流、隐私设置或请求 identity 漂移，并用一个 in-flight + 一个 latest-pending 限制非合作 provider。live replay/replace 绑定 generation + revision、group、kind、tags、content availability 与 operation，并与 Explain 共用 invocation-aware classifier。预演内没有执行按钮。
4. **已调整产品边界**：不再在 Diagnostics 重复建设 workflow runs timeline；“运行历史”已合并全部运行与最近结果，并承载 receipt-first 时间线和固定跳过原因，Diagnostics 保留面向排障的 content-free 事件。

## 8. 测试建议

- `SessionCoordinator` 正常 run 会记录 preparing/recognizing/transforming/delivering/completed。
- 缺失 recognizer/action 会记录 failed outcome 和错误信息。
- action 返回 `.failed` 时不能发布成功终态或继续执行后续 action；已有副作用时必须记录 `partiallyCompleted`。
- receipt JSON 不含正文、名称、component ID、错误字符串、路径、endpoint、精确长度、精确耗时或无盐 hash。
- SQLite v4–v7 → v8、错误 key、坏 payload、retention cutoff、generation CAS/replay/conflict、clock rollback、跨连接旧 token、单表提交后旧代不可见、崩溃重开与 WAL/SHM canary 均有回归。
- receipt 查询会逐行隔离损坏 payload，坏行不占用 `limit`；可见历史 run 按 `runID` 精确补载，不会被高频非语音收据挤出。
- terminal 写入先复用冻结收据做有界重试；持续失败进入有界 dead-letter，未 durable 时不得广播 finalized。
- clear-all intent 在持久化前捕获 `previous → next + intentID`；同 intent 崩溃重放幂等，不同 intent 或旧 generation fail-closed，不能删除 next-generation 的历史、诊断或收据。
- `polishGenerated` tag 会导致 voice group auto-polish 被跳过，并记录 loop-prevented。
- scheduler 的 query/insert 故障只记录 receipt-unavailable；不得发布 matched/skipped/loop claim，也不得泄漏底层错误 canary。
- scheduler 跨 event kind 与 workflow 保持 FIFO；去重跨 idle 生效，最旧 event ID 只在有界窗口满后淘汰。
- `historyOnly` 会保存条目但不提交 scheduler 或发布 group event；sink 摘除必须等待已捕获旧 sink 的 publication，随后 mutation 不再送往旧 sink。
- 运行前解释不会调用 `OutputAction.execute`。
- 解释收据的 JSON 不包含名称、正文、prompt、endpoint、path、header 或凭据 canary。
- 解释服务不会调用 recognizer、transformer、action、上下文正文读取或确认回调。
- Workflows 入口在草稿和保存版本不一致时禁用；切换、删除、关闭、失活或设置变化后，旧异步收据不能写回当前 UI。
- 自动 recognizer/output mode 未解析时返回 typed blocked，不回退到 manifest 占位路径。
- 本地语音收据把 audio 标为 required、recognition hints 标为 conditional，且两者均指向本机；不重复报告同一 hints payload。
- 收据在声明步骤前包含 conditional on-device vocabulary mapping；多效果 action 不遗漏次级存储写入，并保留来源 action index。
- Explain 和 live authorization 对 LLM rewrite、Webhook、本地 ASR 与本地输出使用同一个 closed destination classifier；未知 ID 两侧均 fail-closed。
- 非音频工作流与 replay 授权失败时，Coordinator、recognizer、transformer 和 action 调用数均为 0；公共 Runtime API 不能从 raw context 构造一次运行。
- Secure Input、未知焦点和 `excludeFromWorkflowCapture` 的 preview/authorization redaction 保持一致；授权期间设置或 focus/clipboard 身份漂移会拒绝提交。
- Stack mirror/capture 的 payload-read/mirror-write 竞态测试覆盖敏感 App、Secure Input、设置收紧、焦点 activation、暂停和 ignore-next；失效写入只在仍持有 change count 时恢复。
- 本地语音准备与运行测试覆盖受信模型校验、`finishing` 重入、取消和托管临时音频清理；TextInjection 测试覆盖目标激活、分块间漂移、粘贴前漂移、条件恢复和诊断 canary。
- replay 生成新的 runID，默认持久化边界不保存与原运行的稳定关联。
- legacy clipboard state 解码会生成新的 item generation，并在 schema 6 回写；同 item mutation 单调递增 revision，删除后同 ID 重建必须改变 generation，无关 item mutation 不使 subject 失效。
- clipboard dry-run preparer 对 `.use` 不取 privacy context；replay/replace 使用 clipboard invocation 的 privacy-only evaluate，绝不确认、授权或调用 recognizer/transformer/action。准备期间 item 漂移返回固定错误且不提交收据。
- UI correlation 同时校验 item/version/group/kind/tags/content availability、operation、workflowID 与 receipt version；dismiss、scene inactive、item/workflow/privacy 变化和乱序返回都不能把旧结果写入当前 sheet。
- 所有 dry-run status/reason/read/effect/replacement/issue 均有固定中英文；presentation 与 accessibility 文案不包含正文、prompt、路径、endpoint、credential 或任意 provider error。

## 9. 非目标

- 不做全量事件溯源系统。
- 不把所有音频和全文默认持久化。
- 不实现 Keyboard Maestro 级别的宏调试器。
- 不要求第一版 UI 有复杂图形 timeline；列表 + 详情足够。

## 10. 近期推荐落点

和 `docs/vocabulary-prompt-design.md` 组合起来，最有价值的实现切片是：

1. **已完成**：内容无关的运行前解释收据、静态 planning service、动态 fixed-classification 隐私评估和 Workflows UI。
2. **已完成**：shared destination classifier、workflow-bound authorization 与真实运行重新检查，正文和配置值不进入收据。
3. **已完成**：typed run receipt、独立加密仓库、clipboard item dry-run 核心、invocation-aware live authorization 与 durable-first 最小 timeline。
4. **已完成**：group descriptor 绑定 exact item version，transient lineage 以 root、唯一有序 workflow path 和 8-hop cap 阻断重入；Replay/Replace 已使用 one-shot item lease、source replacement CAS 与来源 App 感知授权，group non-interactive preflight 固定零确认且不发执行 capability。
5. **下一步**：最新打包 App 已通过浮动 NSPanel 的 Dashboard 打开、失焦 auto-hide、Esc/焦点恢复与搜索键盘零穿透检查；继续在干净账户人工完成纯修饰键全局热键、attached sheet 和 VoiceOver 验收。在开放任何 group action 前补 workflow-revision-bound 持久 grant、one-shot group action lease 与副作用前最终复核。

后续工作应继续沿用现有 content-free 与 capability 边界；固定跳过原因、exact revision、lineage/hop、one-shot item lease/CAS、来源感知的零确认 preflight 和只读条目预演已经可追踪。workflow grant、group action lease、副作用前最终复核与浮动面板干净账户验收完成前，仍不开放组事件动作或预演内执行按钮。
