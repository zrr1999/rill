import RillCore

public enum SurfaceText: CaseIterable, Sendable {
  case panelContent
  case collections
  case drafts
  case keepOpen
  case keepThePanelExpandedWhen
  case collapseToPendingStrip
  case closePanel
  case closePendingStrip
  case editsNeedAttention
  case outputNeedsConfirmation
  case nothingPending
  case processing
  case deliveredStateNotSaved
  case checkTheTargetBeforeConfirming
  case retrySave
  case inserted
  case retryItem
  case drafts2
  case newItem
  case finishRecording
  case recordNewItem
  case removeThisPendingItem
  case remove
  case cancel
  case draftEditsWillBeDiscarded
  case collectVoiceInDrafts
  case whenOffFnDictationTypes
  case collectClipboardInDrafts
  case collectsNewCopiesAfterEnabling
  case opensAutomaticallyIncludingAfterRestart
  case recognizing
  case resultToReview
  case edited
  case inProgress
  case disabled
  case createADraftOrCollect
  case editText
  case saving
  case unsaved
  case saved
  case dictateHere
  case pendingText
  case selectAnItem
  case editSelectAndUndoText
  case speechResultsAreReadyTo
  case insertAtSelection
  case dismiss
  case reviewChanges
  case compareWith
  case recognition
  case initialDraft
  case deletionsAreStruckThroughAdditions
  case saveAsNewDraft
  case sendTo
  case focusTheTargetAndUse
  case hide
  case sendSelected
  case returnSendsWhileEditingReturn
  case speech
  case clipboard
  case emptyDraft
  case stack
  case queue
  case reusable
  case theDraftExceedsTheLocal
  case enterSomeTextBeforeSending
  case couldNotLoadItemsReopen
  case editsAreNotSavedRetry
  case theItemChangedYourEdits
  case couldNotStartRecordingCheck
  case outputNext
  case remainingCount
  case processing2
  case nothingPending2
  case confirmTheResult
  case advanceOnlyAfterConfirmingInsertion
  case deliveredSettlementPending
  case retrySaving
  case openDrafts
  case focusTheTargetAndPress
  case close
  case empty
  case addTo
  case newSet
  case reusableItems
  case manageOutputBuffers
  case empty2
  case contextCorrectionMemory
  case speechRemainsTheOnlyContent
  case useVocabularyForSmartCleanup
  case applicableHotwordsAreSharedWith
  case screenContext
  case longTermMemoryIdleOrganization
  case screenRecordingPermissionIsUnavailable
  case authorizeCurrentProvider
  case manageMemories
  case organizeWhenIdle
  case backgroundRequestsToday
  case foregroundSummaryRequestsTodayMain
  case authorizeContextProcessing
  case enableForTheseVoiceWorkflows
  case smartCleanupSendsItsApplicable
  case theCurrentLlmReceivesThe
  case theCurrentLlmReceivesAuthorized
  case providerChangesRequireAuthorizatioAgain
  case userStatement
  case explicitCorrection
  case screenObservation
  case needsConfirmation
  case active
  case archived
  case longTermMemories
  case refresh
  case done
  case sources
  case historyDeleted
  case proposedReplacement
  case edit
  case confirmed
  case confirm
  case unlock
  case lock
  case restore
  case archive
  case delete
  case permanentlyDeleteThisMemoryAnd
  case deletePermanently
  case correctionReferences
  case preRecordingImage
  case imageSummary
  case memorySummary
  case vocabulary
  case applicable
  case included
  case omittedByBudget
  case sentReferencesAreEvidenceOffered
  case screenObservationNotAPersonal
  case thisSummaryArrivedAfterInputs
  case relatedMemories
  case off
  case unavailableSkipped
  case timedOutSkipped
  case failedSkipped
  case notReadyAtFreezeOmitted
  case prepared
  case sentAsReference
  case requestFailedDeliveryUnconfirmed
  case cancelled
  case outputNextShortcut
  case shortcutConflictChangeOneBinding
  case clipboardPanel
  case theLegacyWorkflowLibraryHas
  case copy
  case newWorkflow
  case theWorkflowCouldNotFinish
  case termsCommaSeparated
  case setExpiry
  case archiveAfter
  case saveConfirm
  case speechTextSentReferencesListed
  case currentSpeechModel
  case modelDetailsAndResidency
  case modelId
  case collection
  case allRecords
  case addToDrafts
  case shortcutConflictsWithOutputNext
  case shortcutConflictsWithTheClipboard
  case setUpLater
  case finishSetup
  case forDeepseekUseHttpsApi
  case rillOutputNext
}

extension L10n {
  public static func surface(_ key: SurfaceText, language: AppLanguage) -> String {
    surfaceTable[key]?.string(for: language) ?? String(describing: key)
  }
}

private let surfaceTable: [SurfaceText: LocalizedText] = [
  .panelContent: .init(english: "Panel content", simplifiedChinese: "面板内容"),
  .collections: .init(english: "Collections", simplifiedChinese: "记录集"),
  .drafts: .init(english: "Drafts", simplifiedChinese: "待发"),
  .keepOpen: .init(english: "Keep open", simplifiedChinese: "保持显示"),
  .keepThePanelExpandedWhen: .init(english: "Keep the panel expanded when switching apps", simplifiedChinese: "切换应用时保持面板展开"),
  .collapseToPendingStrip: .init(english: "Collapse to pending strip", simplifiedChinese: "折叠为待发条"),
  .closePanel: .init(english: "Close panel", simplifiedChinese: "关闭面板"),
  .closePendingStrip: .init(english: "Close pending strip", simplifiedChinese: "关闭待发条"),
  .editsNeedAttention: .init(english: "Edits need attention", simplifiedChinese: "修改尚未保存，展开处理"),
  .outputNeedsConfirmation: .init(english: "Output needs confirmation", simplifiedChinese: "输出结果待确认"),
  .nothingPending: .init(english: "Nothing pending", simplifiedChinese: "没有待发内容"),
  .processing: .init(english: "Processing…", simplifiedChinese: "处理中…"),
  .deliveredStateNotSaved: .init(english: "Delivered; state not saved", simplifiedChinese: "已输出，状态尚未保存"),
  .checkTheTargetBeforeConfirming: .init(english: "Check the target before confirming insertion.", simplifiedChinese: "检查目标中的内容，再确认输出结果。"),
  .retrySave: .init(english: "Retry save", simplifiedChinese: "重试保存"),
  .inserted: .init(english: "Inserted", simplifiedChinese: "已插入"),
  .retryItem: .init(english: "Retry item", simplifiedChinese: "重试此项"),
  .drafts2: .init(english: "Drafts", simplifiedChinese: "待发区"),
  .newItem: .init(english: "New item", simplifiedChinese: "新建"),
  .finishRecording: .init(english: "Finish recording", simplifiedChinese: "结束录音"),
  .recordNewItem: .init(english: "Record new item", simplifiedChinese: "录音新建"),
  .removeThisPendingItem: .init(english: "Remove this pending item?", simplifiedChinese: "移除此待发项？"),
  .remove: .init(english: "Remove", simplifiedChinese: "移除"),
  .cancel: .init(english: "Cancel", simplifiedChinese: "取消"),
  .draftEditsWillBeDiscarded: .init(english: "Draft edits will be discarded. The original record is retained.", simplifiedChinese: "草稿修改将被丢弃，原始记录仍保留。"),
  .collectVoiceInDrafts: .init(english: "Collect voice in Drafts", simplifiedChinese: "语音进入待发区"),
  .whenOffFnDictationTypes: .init(english: "When off, Fn dictation types into the current app. Record new item still collects here.", simplifiedChinese: "关闭后，Fn 听写直接输入当前应用；“录音新建”仍会收进待发区。"),
  .collectClipboardInDrafts: .init(english: "Collect clipboard in Drafts", simplifiedChinese: "剪贴板进入待发区"),
  .collectsNewCopiesAfterEnabling: .init(english: "Collects new copies after enabling, subject to your privacy exclusions.", simplifiedChinese: "收集开启后的新复制内容，并遵守隐私排除设置。"),
  .opensAutomaticallyIncludingAfterRestart: .init(english: "Opens automatically, including after restart. New items keep your editing selection.", simplifiedChinese: "开启后自动显示，重启后保持；新内容不会打断当前编辑。"),
  .recognizing: .init(english: "Recognizing…", simplifiedChinese: "正在识别…"),
  .resultToReview: .init(english: "Result to review", simplifiedChinese: "有待应用结果"),
  .edited: .init(english: "Edited", simplifiedChinese: "已编辑"),
  .inProgress: .init(english: "In progress", simplifiedChinese: "处理中"),
  .disabled: .init(english: " · Disabled", simplifiedChinese: " · 已停用"),
  .createADraftOrCollect: .init(english: "Create a draft or collect\\nvoice results here first.", simplifiedChinese: "新建草稿，或将语音结果\\n先收进待发区。"),
  .editText: .init(english: "Edit text", simplifiedChinese: "编辑内容"),
  .saving: .init(english: "Saving…", simplifiedChinese: "保存中…"),
  .unsaved: .init(english: "Unsaved", simplifiedChinese: "尚未保存"),
  .saved: .init(english: "Saved", simplifiedChinese: "已保存"),
  .dictateHere: .init(english: "Dictate here", simplifiedChinese: "在此听写"),
  .pendingText: .init(english: "Pending text", simplifiedChinese: "待发内容"),
  .selectAnItem: .init(english: "Select an item", simplifiedChinese: "选择待发项"),
  .editSelectAndUndoText: .init(english: "Edit, select and undo text here. Pending recognition becomes editable when it finishes.", simplifiedChinese: "文字可直接修改、选中和撤销。识别中的条目完成后即可编辑。"),
  .speechResultsAreReadyTo: .init(english: "Speech results are ready to insert at your selected position.", simplifiedChinese: "语音结果尚未应用，可在当前选区插入。"),
  .insertAtSelection: .init(english: "Insert at selection", simplifiedChinese: "插入选区"),
  .dismiss: .init(english: "Dismiss", simplifiedChinese: "忽略"),
  .reviewChanges: .init(english: "Review changes", simplifiedChinese: "查看修改差异"),
  .compareWith: .init(english: "Compare with", simplifiedChinese: "对比原文"),
  .recognition: .init(english: "Recognition", simplifiedChinese: "识别原文"),
  .initialDraft: .init(english: "Initial draft", simplifiedChinese: "进入草稿时"),
  .deletionsAreStruckThroughAdditions: .init(english: "Deletions are struck through; additions are underlined. Rewrites are not necessarily recognition errors. No vocabulary is learned automatically.", simplifiedChinese: "删除带删除线，新增带下划线。改写不一定是识别错误，差异不会自动写入词库。"),
  .saveAsNewDraft: .init(english: "Save as new draft", simplifiedChinese: "另存新草稿"),
  .sendTo: .init(english: "Send to ", simplifiedChinese: "发送到 "),
  .focusTheTargetAndUse: .init(english: "Focus the target and use the output shortcut after preparing the item.", simplifiedChinese: "发送后可回到目标输入框，按输出快捷键取用。"),
  .hide: .init(english: "Hide", simplifiedChinese: "隐藏"),
  .sendSelected: .init(english: "Send selected", simplifiedChinese: "发送所选项"),
  .returnSendsWhileEditingReturn: .init(english: "⌘Return sends while editing; Return inserts a newline.", simplifiedChinese: "编辑时按 ⌘Return 发送；Return 换行。"),
  .speech: .init(english: "Speech", simplifiedChinese: "语音"),
  .clipboard: .init(english: "Clipboard", simplifiedChinese: "剪贴板"),
  .emptyDraft: .init(english: "Empty draft", simplifiedChinese: "空白草稿"),
  .stack: .init(english: "Stack", simplifiedChinese: "后进先出"),
  .queue: .init(english: "Queue", simplifiedChinese: "先进先出"),
  .reusable: .init(english: "Reusable", simplifiedChinese: "手动取用"),
  .theDraftExceedsTheLocal: .init(english: "The draft exceeds the local content limit. Shorten it and retry.", simplifiedChinese: "草稿超出本地内容上限，请缩短后重试。"),
  .enterSomeTextBeforeSending: .init(english: "Enter some text before sending.", simplifiedChinese: "先输入内容，再发送。"),
  .couldNotLoadItemsReopen: .init(english: "Could not load items. Reopen the panel to retry.", simplifiedChinese: "无法读取待发项，请重新打开面板。"),
  .editsAreNotSavedRetry: .init(english: "Edits are not saved. Retry; your text is still in the editor.", simplifiedChinese: "修改尚未保存，请重试。当前编辑仍保留在面板中。"),
  .theItemChangedYourEdits: .init(english: "The item changed. Your edits are retained; nothing was sent.", simplifiedChinese: "条目已变化，当前修改已保留，尚未发送。"),
  .couldNotStartRecordingCheck: .init(english: "Could not start recording. Check voice settings.", simplifiedChinese: "无法开始录音，请检查语音设置。"),
  .outputNext: .init(english: "Output Next", simplifiedChinese: "输出下一项"),
  .remainingCount: .init(english: "Remaining count", simplifiedChinese: "剩余数量"),
  .processing2: .init(english: "Processing", simplifiedChinese: "处理中"),
  .nothingPending2: .init(english: "Nothing pending", simplifiedChinese: "没有待输出内容"),
  .confirmTheResult: .init(english: "Confirm the result", simplifiedChinese: "结果待确认"),
  .advanceOnlyAfterConfirmingInsertion: .init(english: "Advance only after confirming insertion. Check the target after a partial output.", simplifiedChinese: "只有确认内容已插入，才会推进。部分输出时请先检查目标。"),
  .deliveredSettlementPending: .init(english: "Delivered; settlement pending", simplifiedChinese: "已输出，等待保存状态"),
  .retrySaving: .init(english: "Retry saving", simplifiedChinese: "重试保存"),
  .openDrafts: .init(english: "Open drafts", simplifiedChinese: "打开待发区"),
  .focusTheTargetAndPress: .init(english: "Focus the target and press the output shortcut", simplifiedChinese: "聚焦目标后按输出快捷键"),
  .close: .init(english: "Close", simplifiedChinese: "关闭"),
  .empty: .init(english: "Empty", simplifiedChinese: "空"),
  .addTo: .init(english: "Add to ", simplifiedChinese: "加入 "),
  .newSet: .init(english: "New Set", simplifiedChinese: "新建 Set"),
  .reusableItems: .init(english: "Reusable items", simplifiedChinese: "手动取用"),
  .manageOutputBuffers: .init(english: "Manage output buffers", simplifiedChinese: "管理待发容器"),
  .empty2: .init(english: "Empty", simplifiedChinese: "暂无内容"),
  .contextCorrectionMemory: .init(english: "Context correction & memory", simplifiedChinese: "上下文纠错与记忆"),
  .speechRemainsTheOnlyContent: .init(english: "Speech remains the only content source. References help correct recognition errors.", simplifiedChinese: "语音识别正文是唯一内容主体；参考仅用于纠正识别错误。"),
  .useVocabularyForSmartCleanup: .init(english: "Use vocabulary for Smart Cleanup", simplifiedChinese: "润色使用词库"),
  .applicableHotwordsAreSharedWith: .init(english: "Applicable hotwords are shared with the current LLM for new Smart Cleanup recordings, including words that do not fit the ASR budget.", simplifiedChinese: "新录音的 Smart Cleanup 会向当前 LLM 提供适用热词，包括 ASR 预算装不下的词。"),
  .screenContext: .init(english: "Screen context", simplifiedChinese: "屏幕上下文"),
  .longTermMemoryIdleOrganization: .init(english: "Long-term memory & idle organization", simplifiedChinese: "长期记忆与空闲整理"),
  .screenRecordingPermissionIsUnavailable: .init(english: "Screen Recording permission is unavailable; recordings continue without a screenshot.", simplifiedChinese: "屏幕录制权限不可用，录音会跳过截图。"),
  .authorizeCurrentProvider: .init(english: "Authorize current provider", simplifiedChinese: "授权当前服务"),
  .manageMemories: .init(english: "Manage memories", simplifiedChinese: "管理记忆"),
  .organizeWhenIdle: .init(english: "Organize when idle", simplifiedChinese: "下次空闲时整理"),
  .backgroundRequestsToday: .init(english: "background requests today", simplifiedChinese: "今日后台请求"),
  .foregroundSummaryRequestsTodayMain: .init(english: "foreground summary requests today (main corrections appear in history)", simplifiedChinese: "今日前台摘要请求（主纠错请求见历史）"),
  .authorizeContextProcessing: .init(english: "Authorize context processing", simplifiedChinese: "授权上下文处理"),
  .enableForTheseVoiceWorkflows: .init(english: "Enable for these voice workflows", simplifiedChinese: "为这些语音工作流开启"),
  .smartCleanupSendsItsApplicable: .init(english: "Smart Cleanup sends its applicable hotwords to the current LLM as correction references. No screen or history access is needed. Reference terms are not copied into history.", simplifiedChinese: "Smart Cleanup 将适用热词发送给当前 LLM 作为纠错参考，无需访问屏幕或历史，也不会将参考词表复制到历史中。"),
  .theCurrentLlmReceivesThe: .init(english: "The current LLM receives the pre-recording image and its optional summary. Screen summaries are encrypted locally.", simplifiedChinese: "当前 LLM 将收到录音前图片及可选摘要，屏幕摘要在本地加密保存。"),
  .theCurrentLlmReceivesAuthorized: .init(english: "The current LLM receives authorized voice history, explicit corrections and saved screen observations for idle organization, plus relevant terms and confirmed corrections during recordings. Memories survive history cleanup; deletion excludes their sources from relearning.", simplifiedChinese: "当前 LLM 将收到已授权的语音历史、明确纠正和已存屏幕观察，用于空闲整理；录音时还会接收相关术语和已确认纠正。记忆独立于历史留存，删除记忆会排除其来源，防止再次生成。"),
  .providerChangesRequireAuthorizatioAgain: .init(english: "Provider changes require authorization again. Workflows: ", simplifiedChinese: "服务变更需重新授权。工作流："),
  .userStatement: .init(english: "User statement", simplifiedChinese: "用户陈述"),
  .explicitCorrection: .init(english: "Explicit correction", simplifiedChinese: "明确纠正"),
  .screenObservation: .init(english: "Screen observation", simplifiedChinese: "屏幕观察"),
  .needsConfirmation: .init(english: "Needs confirmation", simplifiedChinese: "待确认"),
  .active: .init(english: "Active", simplifiedChinese: "使用中"),
  .archived: .init(english: "Archived", simplifiedChinese: "已归档"),
  .longTermMemories: .init(english: "Long-term memories", simplifiedChinese: "长期记忆"),
  .refresh: .init(english: "Refresh", simplifiedChinese: "刷新"),
  .done: .init(english: "Done", simplifiedChinese: "完成"),
  .sources: .init(english: "sources", simplifiedChinese: "条来源"),
  .historyDeleted: .init(english: " · history deleted", simplifiedChinese: " · 原始历史已清理"),
  .proposedReplacement: .init(english: "Proposed replacement: ", simplifiedChinese: "拟替代："),
  .edit: .init(english: "Edit", simplifiedChinese: "编辑"),
  .confirmed: .init(english: "Confirmed", simplifiedChinese: "已确认"),
  .confirm: .init(english: "Confirm", simplifiedChinese: "确认"),
  .unlock: .init(english: "Unlock", simplifiedChinese: "解锁"),
  .lock: .init(english: "Lock", simplifiedChinese: "锁定"),
  .restore: .init(english: "Restore", simplifiedChinese: "恢复"),
  .archive: .init(english: "Archive", simplifiedChinese: "归档"),
  .delete: .init(english: "Delete", simplifiedChinese: "删除"),
  .permanentlyDeleteThisMemoryAnd: .init(english: "Permanently delete this memory and exclude its sources?", simplifiedChinese: "永久删除记忆并排除其来源？"),
  .deletePermanently: .init(english: "Delete permanently", simplifiedChinese: "永久删除"),
  .correctionReferences: .init(english: "Correction references", simplifiedChinese: "纠错参考"),
  .preRecordingImage: .init(english: "Pre-recording image", simplifiedChinese: "录音前参考图"),
  .imageSummary: .init(english: "Image summary", simplifiedChinese: "图片摘要"),
  .memorySummary: .init(english: "Memory summary", simplifiedChinese: "记忆摘要"),
  .vocabulary: .init(english: "Vocabulary", simplifiedChinese: "词库"),
  .applicable: .init(english: "Applicable: ", simplifiedChinese: "适用："),
  .included: .init(english: "Included: ", simplifiedChinese: "装入："),
  .omittedByBudget: .init(english: "Omitted by budget: ", simplifiedChinese: "预算省略："),
  .sentReferencesAreEvidenceOffered: .init(english: "Sent references are evidence offered to the model, not verified corrections. Images and temporary memory summaries are not saved.", simplifiedChinese: "已发送参考表示向模型提供了依据，不代表已确认纠正成功。原图和临时记忆摘要不保存。"),
  .screenObservationNotAPersonal: .init(english: "Screen observation (not a personal fact)", simplifiedChinese: "屏幕观察（不代表用户事实）"),
  .thisSummaryArrivedAfterInputs: .init(english: "This summary arrived after inputs were frozen and was saved to history only.", simplifiedChinese: "此摘要在主请求冻结后到达，仅补入历史，没有修改输出。"),
  .relatedMemories: .init(english: "Related memories: ", simplifiedChinese: "相关记忆："),
  .off: .init(english: "Off", simplifiedChinese: "未开启"),
  .unavailableSkipped: .init(english: "Unavailable / skipped", simplifiedChinese: "不可用，已跳过"),
  .timedOutSkipped: .init(english: "Timed out / skipped", simplifiedChinese: "超时，已跳过"),
  .failedSkipped: .init(english: "Failed / skipped", simplifiedChinese: "失败，已跳过"),
  .notReadyAtFreezeOmitted: .init(english: "Not ready at freeze / omitted", simplifiedChinese: "冻结时未就绪，未携带"),
  .prepared: .init(english: "Prepared", simplifiedChinese: "已准备"),
  .sentAsReference: .init(english: "Sent as reference", simplifiedChinese: "已作为参考发送"),
  .requestFailedDeliveryUnconfirmed: .init(english: "Request failed; delivery unconfirmed", simplifiedChinese: "请求未完成，是否送达不可确认"),
  .cancelled: .init(english: "Cancelled", simplifiedChinese: "已取消"),
  .outputNextShortcut: .init(english: "Output Next shortcut", simplifiedChinese: "输出下一项快捷键"),
  .shortcutConflictChangeOneBinding: .init(english: "Shortcut conflict: change one binding.", simplifiedChinese: "快捷键冲突：请修改其中一个绑定。"),
  .clipboardPanel: .init(english: "Clipboard panel", simplifiedChinese: "剪贴板面板"),
  .theLegacyWorkflowLibraryHas: .init(english: "The legacy workflow library has not migrated to TOML. Repair the workflow directory and restart before creating or opening a file; existing workflows are preserved.", simplifiedChinese: "旧工作流尚未完成 TOML 迁移。请修复工作流目录并重新启动，再创建或打开文件；现有工作流已保留。"),
  .copy: .init(english: " Copy", simplifiedChinese: " 副本"),
  .newWorkflow: .init(english: "New workflow", simplifiedChinese: "新工作流"),
  .theWorkflowCouldNotFinish: .init(english: "The workflow could not finish. Review Privacy and provider settings.", simplifiedChinese: "工作流未能完成，请检查隐私和服务商设置。"),
  .termsCommaSeparated: .init(english: "Terms (comma separated)", simplifiedChinese: "术语（用逗号分隔）"),
  .setExpiry: .init(english: "Set expiry", simplifiedChinese: "设置到期时间"),
  .archiveAfter: .init(english: "Archive after", simplifiedChinese: "到期后归档"),
  .saveConfirm: .init(english: "Save & confirm", simplifiedChinese: "保存并确认"),
  .speechTextSentReferencesListed: .init(english: "Speech text sent (references listed separately; image not retained)", simplifiedChinese: "发送的语音正文（参考另列，原图不保存）"),
  .currentSpeechModel: .init(english: "Current speech model", simplifiedChinese: "当前语音模型"),
  .modelDetailsAndResidency: .init(english: "Model details and residency", simplifiedChinese: "模型详情与常驻"),
  .modelId: .init(english: "Model ID", simplifiedChinese: "模型标识"),
  .collection: .init(english: "Collection", simplifiedChinese: "记录集"),
  .allRecords: .init(english: "All Records", simplifiedChinese: "全部记录"),
  .addToDrafts: .init(english: "Add to Drafts", simplifiedChinese: "加入待发"),
  .shortcutConflictsWithOutputNext: .init(english: "Shortcut conflicts with Output Next.", simplifiedChinese: "快捷键与输出下一项冲突。"),
  .shortcutConflictsWithTheClipboard: .init(english: "Shortcut conflicts with the clipboard panel.", simplifiedChinese: "快捷键与剪贴板面板冲突。"),
  .setUpLater: .init(english: "Set up later", simplifiedChinese: "稍后设置"),
  .finishSetup: .init(english: "Finish Setup", simplifiedChinese: "完成准备"),
  .forDeepseekUseHttpsApi: .init(english: "For DeepSeek, use https://api.deepseek.com and choose DeepSeek V4.1 Flash. Thinking is disabled for polishing.", simplifiedChinese: "使用 DeepSeek：Base URL 填写 https://api.deepseek.com，模型选择 DeepSeek V4.1 Flash。润色时自动关闭思考。"),
  .rillOutputNext: .init(english: "Rill · Output Next", simplifiedChinese: "Rill · 输出下一项"),
]
