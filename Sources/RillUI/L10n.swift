import Foundation
import RillCore

public struct LocalizedText: Equatable, Sendable {
  public let english: String
  public let simplifiedChinese: String

  public init(english: String, simplifiedChinese: String) {
    self.english = english
    self.simplifiedChinese = simplifiedChinese
  }

  public func string(for language: AppLanguage) -> String {
    switch language {
    case .english:
      return english
    case .simplifiedChinese:
      return simplifiedChinese
    }
  }
}

public enum L10n {
  public enum Key: String, CaseIterable, Sendable {
    case applicationShutdownDetail
    case applicationShutdownTitle
    case clipboardCurrentDescription
    case clipboardCurrentTitle
    case clipboardHistoryDescription
    case clipboardHistoryTitle
    case clipboardRoutingDescription
    case clipboardRoutingTitle
    case close
    case menuAbout
    case menuClipboardCaptureActive
    case menuClipboardCaptureOff
    case menuClipboardCaptureTurningOn
    case menuClipboardIgnoreNextArming
    case menuClipboardIgnoreNextPending
    case menuCopyLastResult
    case menuIgnoreNextExternalCopy
    case menuInterfaceLanguage
    case menuLocalEngine
    case menuLongRecording
    case menuLongRecordingToggle
    case menuLongRecordingToggleOff
    case menuManageEngineSettings
    case menuNoLongRecordingWorkflows
    case menuNoManualWorkflows
    case menuNoTextStyleWorkflows
    case menuOpenMainWindow
    case menuPasteIntoApp
    case menuDeliverNextRecord
    case menuTurnOffClipboardCapture
    case menuQuit
    case menuRecentResults
    case menuTurnOnClipboardCapture
    case menuSaveToVoiceGroup
    case menuSpeechEngine
    case menuStatusClipboardReady
    case menuStatusFinishSetup
    case menuStatusFinishSetupDetail
    case menuStatusIdleDetail
    case menuStatusLastResult
    case menuStatusNeedsAttention
    case menuStatusReady
    case menuStatusRunning
    case menuStatusRunningDetail
    case menuStatusSetupLoading
    case menuStatusSetupLoadingDetail
    case menuTextOutput
    case menuTextStyles
    case menuWorkflows
    case vocabularyAddRule
    case vocabularyAnyApp
    case vocabularyAnyGroup
    case vocabularyAnyLocale
    case vocabularyCaseSensitive
    case vocabularyCorrectionAction
    case vocabularyCorrectionCancel
    case vocabularyCorrectionConflict
    case vocabularyCorrectionCorrectedText
    case vocabularyCorrectionCreated
    case vocabularyCorrectionDescription
    case vocabularyCorrectionHotwordOption
    case vocabularyCorrectionMappingOption
    case vocabularyCorrectionNoChange
    case vocabularyCorrectionOpenSettings
    case vocabularyCorrectionOriginalText
    case vocabularyCorrectionReused
    case vocabularyCorrectionSave
    case vocabularyCorrectionSaveText
    case vocabularyCorrectionSaveFailed
    case vocabularyCorrectionScopeDescription
    case vocabularyCorrectionScopeTitle
    case vocabularyCorrectionSuggestions
    case vocabularyCorrectionTitle
    case vocabularyCorrectionUnknownApp
    case vocabularyCorrectionUnknownGroup
    case vocabularyCorrectionUnknownLanguage
    case vocabularyCorrectionUnsupported
    case vocabularyDescription
    case vocabularyEmpty
    case vocabularyHotwordBehavior
    case vocabularyKind
    case vocabularyLocale
    case vocabularyMatchMode
    case vocabularyPattern
    case vocabularyPriority
    case vocabularyReplacement
    case vocabularyScope
    case vocabularySourceApp
    case vocabularyTitle
    case settingsOpenAIAPIKey
    case settingsOpenAIAvailable
    case settingsOpenAIBaseURL
    case settingsOpenAICustomModel
    case settingsOpenAIDescription
    case settingsOpenAIEndpointHint
    case settingsOpenAIInaccessible
    case settingsOpenAIMissing
    case settingsOpenAIModel
    case settingsOpenAISaving
    case settingsOpenAITitle
    case settingsOpenAITranscriptOnlyHint
    case settingsOpenAIVerificationFailed
    case settingsOpenAIVerificationSucceeded
    case settingsOpenAIVerify
    case settingsOpenAIVerifying
    case settingsLongRecordingMode
    case settingsLongRecordingModeDescription
    case settingsRecordingDurationLimit
    case settingsRecordingDurationLimitDescription
    case settingsFailedAudioRecovery
    case settingsFailedAudioRecoveryClear
    case settingsFailedAudioRecoveryClearConfirmation
    case settingsFailedAudioRecoveryClearConfirmationDetail
    case settingsFailedAudioRecoveryDescription
    case settingsBenchmarkRecordingArchive
    case settingsBenchmarkRecordingArchiveClear
    case settingsBenchmarkRecordingArchiveClearConfirmation
    case settingsBenchmarkRecordingArchiveClearConfirmationDetail
    case settingsBenchmarkRecordingArchiveDescription
    case historyFailedAudioDelete
    case historyFailedAudioDeleteConfirmation
    case historyFailedAudioDeleteConfirmationDetail
    case historyFailedAudioExpires
    case historyFailedAudioOutcomeUnknown
    case historyFailedAudioRetry
    case historyFailedAudioRetrying
    case voiceModeOutputNone
    case workflowAdvancedTextSteps
    case workflowLanguageAuto
    case workflowLanguageOverride
    case workflowRouteAutomaticHint
    case workflowRouteLocalHint
    case workflowSpeechRoute
    case workflowTextStyle
    case workflowTextStyleHint
    case workflowLocalSpeechModelOverride
    case voiceFailureDetailsLabel
    case voiceFailureDismiss
    case voiceFailureGenericSummary
    case voiceFailureOpenRecognitionSettings
    case voiceFailureTitle
  }

  private static let table: [Key: LocalizedText] = [
    .applicationShutdownDetail: .init(
      english: "Restoring the clipboard and saving local data before Rill closes.",
      simplifiedChinese: "正在恢复剪贴板并保存本地数据，完成后 Rill 会自动退出。"
    ),
    .applicationShutdownTitle: .init(
      english: "Safely quitting Rill…",
      simplifiedChinese: "正在安全退出 Rill…"
    ),
    .clipboardCurrentDescription: .init(
      english: "Active memberships available for delivery from record collections.",
      simplifiedChinese: "记录集中可用于投递的活跃成员关系。"
    ),
    .clipboardCurrentTitle: .init(
      english: "Collection Records",
      simplifiedChinese: "记录集内容"
    ),
    .clipboardHistoryDescription: .init(
      english: "All captured and generated records, including records with no collection membership.",
      simplifiedChinese: "所有采集和生成的记录，包括不属于任何记录集的记录。"
    ),
    .clipboardHistoryTitle: .init(
      english: "All Records",
      simplifiedChinese: "所有记录"
    ),
    .clipboardRoutingDescription: .init(
      english: "Collections, independent policies, and app routing rules.",
      simplifiedChinese: "记录集、独立策略和 App 路由规则。"
    ),
    .clipboardRoutingTitle: .init(
      english: "Collections",
      simplifiedChinese: "记录集"
    ),
    .close: .init(
      english: "Close",
      simplifiedChinese: "关闭"
    ),
    .menuAbout: .init(
      english: "About Rill",
      simplifiedChinese: "关于 Rill"
    ),
    .menuClipboardCaptureActive: .init(
      english: "Clipboard capture active",
      simplifiedChinese: "剪贴板捕获已开启"
    ),
    .menuClipboardCaptureOff: .init(
      english: "Clipboard capture off",
      simplifiedChinese: "剪贴板捕获已关闭"
    ),
    .menuClipboardCaptureTurningOn: .init(
      english: "Turning on clipboard capture…",
      simplifiedChinese: "正在开启剪贴板捕获…"
    ),
    .menuClipboardIgnoreNextArming: .init(
      english: "Preparing one-time clipboard ignore…",
      simplifiedChinese: "正在准备忽略下一次复制…"
    ),
    .menuClipboardIgnoreNextPending: .init(
      english: "Next external copy will be ignored",
      simplifiedChinese: "将忽略下一次外部复制"
    ),
    .menuCopyLastResult: .init(
      english: "Copy Last Transcription Result",
      simplifiedChinese: "复制上次转写结果"
    ),
    .menuIgnoreNextExternalCopy: .init(
      english: "Ignore Next External Copy",
      simplifiedChinese: "忽略下一次外部复制"
    ),
    .menuInterfaceLanguage: .init(
      english: "Interface Language",
      simplifiedChinese: "界面语言"
    ),
    .menuLocalEngine: .init(
      english: "Local Speech",
      simplifiedChinese: "本地语音"
    ),
    .menuLongRecording: .init(
      english: "Toggle Recording",
      simplifiedChinese: "切换式录音"
    ),
    .menuLongRecordingToggle: .init(
      english: "Press Once to Start/Stop",
      simplifiedChinese: "按一下开始 / 结束"
    ),
    .menuLongRecordingToggleOff: .init(
      english: "Hold to Talk",
      simplifiedChinese: "按住说话"
    ),
    .menuManageEngineSettings: .init(
      english: "Manage Recognition Settings…",
      simplifiedChinese: "管理识别设置…"
    ),
    .menuNoLongRecordingWorkflows: .init(
      english: "No Toggle Recording Workflows",
      simplifiedChinese: "暂无切换式录音工作流"
    ),
    .menuNoManualWorkflows: .init(
      english: "No Manual Workflows",
      simplifiedChinese: "暂无手动工作流"
    ),
    .menuNoTextStyleWorkflows: .init(
      english: "No Text Style Workflows",
      simplifiedChinese: "暂无文字风格工作流"
    ),
    .menuOpenMainWindow: .init(
      english: "Open Rill Main Window",
      simplifiedChinese: "打开 Rill 主窗口"
    ),
    .menuPasteIntoApp: .init(
      english: "Type into Current App and Save Record",
      simplifiedChinese: "输入到当前 App 并记录"
    ),
    .menuDeliverNextRecord: .init(
      english: "Paste Top Clipboard Queue Item",
      simplifiedChinese: "粘贴队列顶部条目"
    ),
    .menuTurnOffClipboardCapture: .init(
      english: "Turn Off Clipboard Capture",
      simplifiedChinese: "关闭剪贴板捕获"
    ),
    .menuQuit: .init(
      english: "Quit Rill",
      simplifiedChinese: "退出 Rill"
    ),
    .menuRecentResults: .init(
      english: "Recent Results",
      simplifiedChinese: "最近结果"
    ),
    .menuTurnOnClipboardCapture: .init(
      english: "Turn On Clipboard Capture",
      simplifiedChinese: "开启剪贴板捕获"
    ),
    .menuSaveToVoiceGroup: .init(
      english: "Save Voice Record Only",
      simplifiedChinese: "仅保存语音记录"
    ),
    .menuSpeechEngine: .init(
      english: "Recognition Engine",
      simplifiedChinese: "识别引擎"
    ),
    .menuStatusClipboardReady: .init(
      english: "Ready to paste",
      simplifiedChinese: "可粘贴"
    ),
    .menuStatusFinishSetup: .init(
      english: "Finish Voice Setup",
      simplifiedChinese: "完成语音设置"
    ),
    .menuStatusFinishSetupDetail: .init(
      english: "Open Rill to complete the required permission and speech setup steps.",
      simplifiedChinese: "打开 Rill，完成所需权限和语音设置步骤。"
    ),
    .menuStatusIdleDetail: .init(
      english: "Use a hotkey, workflow, or clipboard action to begin.",
      simplifiedChinese: "使用快捷键、工作流或剪贴板动作开始。"
    ),
    .menuStatusLastResult: .init(
      english: "Last result",
      simplifiedChinese: "上次结果"
    ),
    .menuStatusNeedsAttention: .init(
      english: "Needs attention",
      simplifiedChinese: "需要处理"
    ),
    .menuStatusReady: .init(
      english: "Rill Idle",
      simplifiedChinese: "Rill 空闲"
    ),
    .menuStatusRunning: .init(
      english: "Voice run active",
      simplifiedChinese: "语音运行中"
    ),
    .menuStatusRunningDetail: .init(
      english: "Recording, transcribing, or delivering text.",
      simplifiedChinese: "正在录音、转写或输出文本。"
    ),
    .menuStatusSetupLoading: .init(
      english: "Loading Voice Setup",
      simplifiedChinese: "正在加载语音设置"
    ),
    .menuStatusSetupLoadingDetail: .init(
      english: "Checking saved settings, credentials, and privacy safeguards.",
      simplifiedChinese: "正在检查已保存设置、凭据和隐私保护。"
    ),
    .menuTextOutput: .init(
      english: "Text Output",
      simplifiedChinese: "文字输出"
    ),
    .menuTextStyles: .init(
      english: "Text Style",
      simplifiedChinese: "文字风格"
    ),
    .menuWorkflows: .init(
      english: "Workflows",
      simplifiedChinese: "工作流"
    ),
    .vocabularyAddRule: .init(
      english: "Add Rule",
      simplifiedChinese: "添加规则"
    ),
    .vocabularyAnyApp: .init(
      english: "Any app",
      simplifiedChinese: "任意 App"
    ),
    .vocabularyAnyGroup: .init(
      english: "Any group",
      simplifiedChinese: "任意分组"
    ),
    .vocabularyAnyLocale: .init(
      english: "Any language",
      simplifiedChinese: "任意语言"
    ),
    .vocabularyCaseSensitive: .init(
      english: "Case sensitive",
      simplifiedChinese: "区分大小写"
    ),
    .vocabularyCorrectionAction: .init(
      english: "Correct terminology",
      simplifiedChinese: "纠正术语"
    ),
    .vocabularyCorrectionCancel: .init(
      english: "Cancel",
      simplifiedChinese: "取消"
    ),
    .vocabularyCorrectionConflict: .init(
      english:
        "A rule with the same match and scope already has a different output. Review it in Settings before changing anything.",
      simplifiedChinese: "相同匹配条件和作用范围已有不同输出的规则。请先在设置中检查，Rill 未保存本次建议。"
    ),
    .vocabularyCorrectionCorrectedText: .init(
      english: "Corrected recognition",
      simplifiedChinese: "纠正后的识别文本"
    ),
    .vocabularyCorrectionCreated: .init(
      english: "Correction rule saved for future runs.",
      simplifiedChinese: "纠正规则已保存，将用于后续运行。"
    ),
    .vocabularyCorrectionDescription: .init(
      english:
        "Save an edited copy for this recording, or explicitly remember a vocabulary rule for future runs. The original remains available; saving a copy does not send it to another app.",
      simplifiedChinese: "可以只保存本次录音的修正版，也可以明确记住词汇供以后使用。原始内容会保留，保存修正版不会再次发送到其他应用。"
    ),
    .vocabularyCorrectionHotwordOption: .init(
      english: "Prefer as a recognition hotword",
      simplifiedChinese: "作为识别热词优先识别"
    ),
    .vocabularyCorrectionMappingOption: .init(
      english: "Replace recognized text",
      simplifiedChinese: "替换识别文本"
    ),
    .vocabularyCorrectionNoChange: .init(
      english: "Edit the recognition above to create a suggestion.",
      simplifiedChinese: "请先编辑上方识别文本以生成建议。"
    ),
    .vocabularyCorrectionOpenSettings: .init(
      english: "Open Vocabulary Settings",
      simplifiedChinese: "打开词汇设置"
    ),
    .vocabularyCorrectionOriginalText: .init(
      english: "Original recognition",
      simplifiedChinese: "原始识别文本"
    ),
    .vocabularyCorrectionReused: .init(
      english: "The matching correction rule is enabled for future runs.",
      simplifiedChinese: "已有的匹配纠正规则已启用，将用于后续运行。"
    ),
    .vocabularyCorrectionSave: .init(
      english: "Remember Vocabulary",
      simplifiedChinese: "记住词汇"
    ),
    .vocabularyCorrectionSaveText: .init(
      english: "Save Edited Copy", simplifiedChinese: "修正本次文本"
    ),
    .vocabularyCorrectionSaveFailed: .init(
      english: "Could not save the edited copy. The original may be unavailable, or storage needs attention. Try again.",
      simplifiedChinese: "无法保存修正版。原始记录可能已移除，或本地存储不可用，请重试。"
    ),
    .vocabularyCorrectionScopeDescription: .init(
      english:
        "Known recognition context stays constrained. Confirm each unavailable field before treating it as Any.",
      simplifiedChinese: "已知的识别上下文会保持受限；只有逐项确认后，缺失字段才会按“任意”处理。"
    ),
    .vocabularyCorrectionScopeTitle: .init(
      english: "Rule scope",
      simplifiedChinese: "规则作用范围"
    ),
    .vocabularyCorrectionSuggestions: .init(
      english: "Suggested rule",
      simplifiedChinese: "建议规则"
    ),
    .vocabularyCorrectionTitle: .init(
      english: "Correct Recognition",
      simplifiedChinese: "纠正识别结果"
    ),
    .vocabularyCorrectionUnknownApp: .init(
      english: "The source app is unavailable — apply in any app",
      simplifiedChinese: "来源 App 不可用——确认应用于任意 App"
    ),
    .vocabularyCorrectionUnknownGroup: .init(
      english: "The clipboard group is unavailable — apply in any group",
      simplifiedChinese: "剪贴板分组不可用——确认应用于任意分组"
    ),
    .vocabularyCorrectionUnknownLanguage: .init(
      english: "The recognition language is unavailable — apply to any language",
      simplifiedChinese: "识别语言不可用——确认应用于任意语言"
    ),
    .vocabularyCorrectionUnsupported: .init(
      english:
        "These edits cannot be reduced to one safe rule. Add a precise rule manually in Vocabulary Settings.",
      simplifiedChinese: "这些修改无法安全归纳为一条规则。请在词汇设置中手动添加精确规则。"
    ),
    .vocabularyDescription: .init(
      english: "Teach Rill names, project terms, and replacements for voice output.",
      simplifiedChinese: "为 Rill 配置人名、项目术语和语音输出替换规则。"
    ),
    .vocabularyEmpty: .init(
      english: "No vocabulary rules yet.",
      simplifiedChinese: "还没有词汇规则。"
    ),
    .vocabularyHotwordBehavior: .init(
      english:
        "Matching local Qwen runs use a bounded hotword context. Hotwords improve recognition probability but do not guarantee a match.",
      simplifiedChinese: "范围匹配时，本地 Qwen 使用有界热词上下文。热词只提高识别概率，不保证命中。"
    ),
    .vocabularyKind: .init(
      english: "Rule type",
      simplifiedChinese: "规则类型"
    ),
    .vocabularyLocale: .init(
      english: "Language scope",
      simplifiedChinese: "语言范围"
    ),
    .vocabularyMatchMode: .init(
      english: "Match mode",
      simplifiedChinese: "匹配方式"
    ),
    .vocabularyPattern: .init(
      english: "Spoken or recognized phrase",
      simplifiedChinese: "口述或识别到的词"
    ),
    .vocabularyPriority: .init(
      english: "Priority",
      simplifiedChinese: "优先级"
    ),
    .vocabularyReplacement: .init(
      english: "Preferred output",
      simplifiedChinese: "期望输出"
    ),
    .vocabularyScope: .init(
      english: "Scope",
      simplifiedChinese: "作用范围"
    ),
    .vocabularySourceApp: .init(
      english: "App bundle ID",
      simplifiedChinese: "App Bundle ID"
    ),
    .vocabularyTitle: .init(
      english: "Vocabulary & Mappings",
      simplifiedChinese: "词汇与映射词"
    ),
    .settingsOpenAIAPIKey: .init(
      english: "API Key",
      simplifiedChinese: "API Key"
    ),
    .settingsOpenAIAvailable: .init(
      english: "API key saved in Keychain",
      simplifiedChinese: "API Key 已保存到钥匙串"
    ),
    .settingsOpenAIBaseURL: .init(
      english: "Base URL",
      simplifiedChinese: "Base URL"
    ),
    .settingsOpenAICustomModel: .init(
      english: "Custom model ID",
      simplifiedChinese: "自定义模型 ID"
    ),
    .settingsOpenAIDescription: .init(
      english:
        "One OpenAI-compatible Responses API configuration for Smart Cleanup, voice assistant answers, and custom text workflows.",
      simplifiedChinese: "智能整理、语音助手回答和自定义文本工作流共用一套 OpenAI-compatible Responses API 配置。"
    ),
    .settingsOpenAIEndpointHint: .init(
      english:
        "The API key and transcript are sent to this endpoint. Use HTTPS; plain HTTP is allowed only for loopback addresses.",
      simplifiedChinese: "API Key 与转写正文会发送到该地址。请使用 HTTPS；仅回环地址允许明文 HTTP。"
    ),
    .settingsOpenAIInaccessible: .init(
      english: "LLM Provider credential storage is unavailable.",
      simplifiedChinese: "LLM Provider 凭据存储不可用。"
    ),
    .settingsOpenAIMissing: .init(
      english: "Add an API key to enable text polishing.",
      simplifiedChinese: "添加 API Key 后才能启用文本润色。"
    ),
    .settingsOpenAIModel: .init(
      english: "Model preset",
      simplifiedChinese: "模型预设"
    ),
    .settingsOpenAISaving: .init(
      english: "Saving API key securely…",
      simplifiedChinese: "正在安全保存 API Key…"
    ),
    .settingsOpenAITitle: .init(
      english: "LLM Provider",
      simplifiedChinese: "LLM Provider"
    ),
    .settingsOpenAITranscriptOnlyHint: .init(
      english:
        "Only the final transcript is sent. Requests use the configured Responses API endpoint, non-streaming mode, and store=false.",
      simplifiedChinese: "仅发送最终转写正文。请求使用已配置的 Responses API 地址、非流式模式，并设置 store=false。"
    ),
    .settingsOpenAIVerificationFailed: .init(
      english:
        "Verification failed. Check the endpoint, model ID, key, network, and account limits.",
      simplifiedChinese: "验证失败。请检查地址、模型 ID、API Key、网络和账号额度。"
    ),
    .settingsOpenAIVerificationSucceeded: .init(
      english: "LLM Provider configuration verified.",
      simplifiedChinese: "LLM Provider 配置验证成功。"
    ),
    .settingsOpenAIVerify: .init(
      english: "Verify Configuration",
      simplifiedChinese: "验证配置"
    ),
    .settingsOpenAIVerifying: .init(
      english: "Verifying LLM Provider configuration…",
      simplifiedChinese: "正在验证 LLM Provider 配置…"
    ),
    .settingsLongRecordingMode: .init(
      english: "Toggle recording hotkey mode",
      simplifiedChinese: "切换式录音快捷键模式"
    ),
    .settingsLongRecordingModeDescription: .init(
      english:
        "Press once to start and again to stop. The selected recording limit applies to built-in and manual voice runs.",
      simplifiedChinese: "按一次开始，再按一次停止。所选录音上限同时用于内置听写和手动语音运行。"
    ),
    .settingsRecordingDurationLimit: .init(
      english: "Recording time limit",
      simplifiedChinese: "录音时间上限"
    ),
    .settingsRecordingDurationLimitDescription: .init(
      english:
        "Unlimited disables Rill's automatic stop; available disk space and provider or model limits still apply.",
      simplifiedChinese: "“无限制”会关闭 Rill 的自动停止；可用磁盘空间以及所选模型或服务自身的硬限制仍然有效。"
    ),
    .settingsFailedAudioRecovery: .init(
      english: "Keep failed recordings for manual retry",
      simplifiedChinese: "保留失败录音以供手动重试"
    ),
    .settingsFailedAudioRecoveryClear: .init(
      english: "Clear Failed Recordings",
      simplifiedChinese: "清除失败录音"
    ),
    .settingsFailedAudioRecoveryClearConfirmation: .init(
      english: "Delete all retained failed recordings?",
      simplifiedChinese: "删除全部保留的失败录音吗？"
    ),
    .settingsFailedAudioRecoveryClearConfirmationDetail: .init(
      english:
        "This permanently removes every encrypted recovery recording. Run history and completed transcripts are not changed.",
      simplifiedChinese: "这会永久删除全部加密恢复录音；运行历史和已完成的转写不会改变。"
    ),
    .settingsFailedAudioRecoveryDescription: .init(
      english:
        "Off by default. Eligible recordings are encrypted with the local Keychain key for up to 24 hours (3 items, 16 MB each, 32 MB total). Retry rechecks current privacy and provider settings, writes only to History, and never repeats output actions.",
      simplifiedChinese:
        "默认关闭。符合条件的录音会使用本机 Keychain 密钥加密保存，最长 24 小时（最多 3 条、单条 16 MB、总计 32 MB）。重试会重新检查当前隐私与服务配置，只写入历史，不会重复执行输出动作。"
    ),
    .settingsBenchmarkRecordingArchive: .init(
      english: "Save recordings for ASR benchmark",
      simplifiedChinese: "保存录音用于 ASR Benchmark"
    ),
    .settingsBenchmarkRecordingArchiveClear: .init(
      english: "Clear Benchmark Recordings",
      simplifiedChinese: "清除 Benchmark 录音"
    ),
    .settingsBenchmarkRecordingArchiveClearConfirmation: .init(
      english: "Delete all benchmark recordings?",
      simplifiedChinese: "删除全部 Benchmark 录音吗？"
    ),
    .settingsBenchmarkRecordingArchiveClearConfirmationDetail: .init(
      english:
        "This permanently removes every encrypted benchmark recording. Run history and transcripts are not changed.",
      simplifiedChinese: "这会永久删除全部加密的 Benchmark 录音；运行历史和转写不会改变。"
    ),
    .settingsBenchmarkRecordingArchiveDescription: .init(
      english:
        "Off by default. When enabled, every recording that reaches workflow processing is encrypted with the local Keychain key and kept until cleared. Nothing is uploaded automatically. Turning this off stops new saves but keeps the existing archive.",
      simplifiedChinese:
        "默认关闭。开启后，每条进入工作流处理的录音都会使用本机 Keychain 密钥加密保存，直到手动清除；不会自动上传。关闭只会停止新增，不会删除已有归档。"
    ),
    .historyFailedAudioDelete: .init(
      english: "Delete recording",
      simplifiedChinese: "删除录音"
    ),
    .historyFailedAudioDeleteConfirmation: .init(
      english: "Delete this retained recording?",
      simplifiedChinese: "删除这条保留的录音吗？"
    ),
    .historyFailedAudioDeleteConfirmationDetail: .init(
      english:
        "This permanently removes the encrypted recovery recording. The run history entry is kept.",
      simplifiedChinese: "这会永久删除加密恢复录音，但保留对应的运行历史条目。"
    ),
    .historyFailedAudioExpires: .init(
      english: "Encrypted recording expires",
      simplifiedChinese: "加密录音到期"
    ),
    .historyFailedAudioOutcomeUnknown: .init(
      english:
        "A previous retry was interrupted. Its provider outcome is unknown, so Rill will not repeat it automatically.",
      simplifiedChinese: "上一次重试被中断，服务端结果未知，因此 Rill 不会自动重复请求。"
    ),
    .historyFailedAudioRetry: .init(
      english: "Retry transcription",
      simplifiedChinese: "重试转写"
    ),
    .historyFailedAudioRetrying: .init(
      english: "Retrying…",
      simplifiedChinese: "正在重试…"
    ),
    .voiceModeOutputNone: .init(
      english: "No output",
      simplifiedChinese: "无输出"
    ),
    .workflowAdvancedTextSteps: .init(
      english: "Advanced Text Steps",
      simplifiedChinese: "高级文本步骤"
    ),
    .workflowLanguageAuto: .init(
      english: "Auto language",
      simplifiedChinese: "自动语言"
    ),
    .workflowLanguageOverride: .init(
      english: "Language override",
      simplifiedChinese: "语言覆盖"
    ),
    .workflowRouteAutomaticHint: .init(
      english:
        "Uses the current global engine, with this workflow's language/model overrides when set.",
      simplifiedChinese: "使用当前全局引擎；如已设置，则应用此工作流自己的语言/模型覆盖。"
    ),
    .workflowRouteLocalHint: .init(
      english: "Local speech worker; the workflow's model and language stay on this Mac.",
      simplifiedChinese: "使用本地语音 worker；workflow 的模型和语言处理留在本机。"
    ),
    .workflowSpeechRoute: .init(
      english: "Speech Route",
      simplifiedChinese: "语音路径"
    ),
    .workflowTextStyle: .init(
      english: "Text Style",
      simplifiedChinese: "文字风格"
    ),
    .workflowTextStyleHint: .init(
      english: "Choose what Rill should do with your words before output.",
      simplifiedChinese: "选择 Rill 在输出前如何处理你的语音文本。"
    ),
    .workflowLocalSpeechModelOverride: .init(
      english: "Local model override",
      simplifiedChinese: "本地模型覆盖"
    ),
    .voiceFailureDetailsLabel: .init(
      english: "Details",
      simplifiedChinese: "详细原因"
    ),
    .voiceFailureDismiss: .init(
      english: "Dismiss",
      simplifiedChinese: "忽略"
    ),
    .voiceFailureGenericSummary: .init(
      english: "The last voice run failed. Review the details below.",
      simplifiedChinese: "上次语音运行失败。请查看下方详细原因。"
    ),
    .voiceFailureOpenRecognitionSettings: .init(
      english: "Open Recognition Settings",
      simplifiedChinese: "打开识别设置"
    ),
    .voiceFailureTitle: .init(
      english: "Voice Run Needs Attention",
      simplifiedChinese: "语音运行需要处理"
    ),
  ]

  public static func string(_ key: Key, language: AppLanguage) -> String {
    table[key]?.string(for: language) ?? key.rawValue
  }

  public static func localSpeechPreparationFailure(
    _ stage: LocalSpeechPreparationFailure.Stage
  ) -> LocalizedText {
    switch stage {
    case .architectureUnsupported:
      return LocalizedText(
        english:
          "Local speech preparation is unavailable because this build does not include a compatible MLX worker.",
        simplifiedChinese: "此构建未包含兼容的 MLX worker，无法准备本地语音。"
      )
    case .trustMaterialUnavailable:
      return LocalizedText(
        english:
          "This build does not include reviewed local model trust material, so local speech is unavailable.",
        simplifiedChinese: "此构建未包含受审的本地模型信任材料，因此本地语音不可用。"
      )
    case .trustRoot:
      return LocalizedText(
        english:
          "Local speech preparation stopped because the model identity could not be verified.",
        simplifiedChinese: "本地语音准备已停止，因为无法验证模型身份。"
      )
    case .resolution:
      return LocalizedText(
        english: "Local speech preparation could not obtain the selected model.",
        simplifiedChinese: "本地语音准备无法取得所选模型。"
      )
    case .integrity:
      return LocalizedText(
        english:
          "Local speech preparation stopped because the model failed integrity verification.",
        simplifiedChinese: "本地语音准备已停止，因为模型未通过完整性验证。"
      )
    case .tokenizer:
      return LocalizedText(
        english: "Local speech preparation stopped because the tokenizer could not be verified.",
        simplifiedChinese: "本地语音准备已停止，因为无法验证分词器。"
      )
    case .runtime:
      return LocalizedText(
        english: "Local speech preparation could not load the selected model.",
        simplifiedChinese: "本地语音准备无法加载所选模型。"
      )
    case .generic:
      return LocalizedText(
        english: "Local speech preparation failed. Try again from Speech settings.",
        simplifiedChinese: "本地语音准备失败。请在语音设置中重试。"
      )
    }
  }

  public static func itemCount(_ count: Int, language: AppLanguage) -> String {
    switch language {
    case .english:
      return count == 1 ? "1 item" : "\(count) items"
    case .simplifiedChinese:
      return "\(count) 个条目"
    }
  }

  public static func voiceFailureSummary(message: String, language: AppLanguage) -> String {
    return string(.voiceFailureGenericSummary, language: language)
  }

  public static func menuClipboardReadyStatus(_ count: Int, language: AppLanguage) -> String {
    "\(string(.menuStatusClipboardReady, language: language)): \(itemCount(count, language: language))"
  }

  static func voiceTextStyleTitle(_ style: VoiceTextStyle, language: AppLanguage) -> String {
    switch (style, language) {
    case (.rawInput, .english):
      return "Raw Input"
    case (.rawInput, .simplifiedChinese):
      return "原样输入"
    case (.cleanInput, .english):
      return "Clean Input"
    case (.cleanInput, .simplifiedChinese):
      return "干净输入"
    case (.smartCleanup, .english):
      return "Smart Cleanup"
    case (.smartCleanup, .simplifiedChinese):
      return "智能整理"
    case (.formalWriting, .english):
      return "Formal Writing"
    case (.formalWriting, .simplifiedChinese):
      return "正式写作"
    case (.translateInput, .english):
      return "Translate Input"
    case (.translateInput, .simplifiedChinese):
      return "翻译输入"
    case (.commandMode, .english):
      return "Command Mode"
    case (.commandMode, .simplifiedChinese):
      return "命令模式"
    case (.custom, .english):
      return "Custom Style"
    case (.custom, .simplifiedChinese):
      return "自定义风格"
    }
  }

  static func speechRouteHint(_ route: WorkflowEditorDraft.RecognizerChoice, language: AppLanguage)
    -> String
  {
    switch route {
    case .automatic:
      return string(.workflowRouteAutomaticHint, language: language)
    case .localSpeech:
      return string(.workflowRouteLocalHint, language: language)
    }
  }

  static func voiceTextStyleDescription(_ style: VoiceTextStyle, language: AppLanguage) -> String {
    switch (style, language) {
    case (.rawInput, .english):
      return "Keep the transcript as close to the recognizer result as possible."
    case (.rawInput, .simplifiedChinese):
      return "尽量保留识别结果原文。"
    case (.cleanInput, .english):
      return "Clean spacing and line breaks without rewriting meaning."
    case (.cleanInput, .simplifiedChinese):
      return "整理空格和换行，不改写含义。"
    case (.smartCleanup, .english):
      return "Correct transcription errors and organize paragraphs and lists without losing information."
    case (.smartCleanup, .simplifiedChinese):
      return "纠正识别错误，整理段落和列表，保留所有实质信息。"
    case (.formalWriting, .english):
      return "Rewrite into a concise polished draft while preserving meaning."
    case (.formalWriting, .simplifiedChinese):
      return "在保留含义的前提下润色成简洁成稿。"
    case (.translateInput, .english):
      return "Translate the transcript when you ask for a target language."
    case (.translateInput, .simplifiedChinese):
      return "按你说出的目标语言翻译转写内容。"
    case (.commandMode, .english):
      return "Shape the transcript into a concise command or instruction."
    case (.commandMode, .simplifiedChinese):
      return "把转写内容整理成简洁命令或指令。"
    case (.custom, .english):
      return "Use the custom advanced text steps below."
    case (.custom, .simplifiedChinese):
      return "使用下方自定义高级文本步骤。"
    }
  }

  public static func vocabularyRuleKind(_ kind: VocabularyRuleKind, language: AppLanguage) -> String
  {
    switch (kind, language) {
    case (.hotword, .english):
      return "Hotword"
    case (.hotword, .simplifiedChinese):
      return "热词"
    case (.mapping, .english):
      return "Mapping"
    case (.mapping, .simplifiedChinese):
      return "映射词"
    }
  }

  public static func vocabularyMatchMode(_ mode: VocabularyMatchMode, language: AppLanguage)
    -> String
  {
    switch (mode, language) {
    case (.exactPhrase, .english):
      return "Exact phrase"
    case (.exactPhrase, .simplifiedChinese):
      return "完整短语"
    case (.wordBoundary, .english):
      return "Word boundary"
    case (.wordBoundary, .simplifiedChinese):
      return "单词边界"
    case (.regex, .english):
      return "Regular expression"
    case (.regex, .simplifiedChinese):
      return "正则表达式"
    }
  }

  public static func vocabularyScopeSummary(
    _ scope: VocabularyRuleScope,
    groupName: String?,
    language: AppLanguage
  ) -> String {
    let bundleIdentifier = scope.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
    let locale = scope.locale?.trimmingCharacters(in: .whitespacesAndNewlines)
    var parts: [String] = []
    parts.append(
      bundleIdentifier?.isEmpty == false
        ? bundleIdentifier! : string(.vocabularyAnyApp, language: language))
    parts.append(groupName ?? string(.vocabularyAnyGroup, language: language))
    parts.append(
      locale?.isEmpty == false ? locale! : string(.vocabularyAnyLocale, language: language))
    return parts.joined(separator: " · ")
  }

  static func privacyText(_ key: PrivacySettingsTextKey, language: AppLanguage) -> String {
    privacyTextTable[key]?.string(for: language) ?? key.rawValue
  }
  static func privacySettingsHistoryPreviewMode(
    _ mode: PrivacyHistoryPreviewMode, language: AppLanguage
  ) -> String {
    switch mode {
    case .full: return language == .english ? "Full previews" : "完整预览"
    case .restricted: return language == .english ? "Restricted previews" : "受限预览"
    case .disabled: return language == .english ? "Disabled" : "禁用"
    }
  }
  static func privacySettingsSpeechRouteHint(
    _ route: WorkflowEditorDraft.RecognizerChoice, language: AppLanguage
  ) -> String {
    switch route {
    case .automatic:
      return privacyText(PrivacySettingsTextKey.automaticRouteHint, language: language)
    case .localSpeech: return privacyText(PrivacySettingsTextKey.localRouteHint, language: language)
    }
  }
  private static var privacyTextTable: [PrivacySettingsTextKey: LocalizedText] {
    [
      PrivacySettingsTextKey.addRule: .init(english: "Add App", simplifiedChinese: "添加 App"),
      PrivacySettingsTextKey.applicationNameOptional: .init(
        english: "App name (optional)", simplifiedChinese: "App 名称（可选）"),
      PrivacySettingsTextKey.automaticRouteHint: .init(
        english: "Global engine; cloud may confirm.", simplifiedChinese: "全局引擎；云端可能确认。"),
      PrivacySettingsTextKey.cloudConfirmation: .init(
        english: "Ask before cloud processing", simplifiedChinese: "云端处理前询问"),
      PrivacySettingsTextKey.bundleIdentifier: .init(
        english: "Bundle identifier (for example, com.example.Vault)",
        simplifiedChinese: "Bundle ID（例如 com.example.Vault）"),
      PrivacySettingsTextKey.cancelEdit: .init(english: "Cancel", simplifiedChinese: "取消"),
      PrivacySettingsTextKey.cloudConfirmationDescription: .init(
        english:
          "Choose Allow and Remember at the first prompt to skip future prompts for the same workflow and service configuration. Restricted apps and stricter privacy settings still block those runs.",
        simplifiedChinese: "首次询问时选择“允许并记住”，同一工作流和服务配置下不再重复弹窗。受限 App 与更严格的隐私设置仍会阻止运行。"),
      PrivacySettingsTextKey.cloudAlwaysAllowed: .init(
        english: "Always-allowed workflows", simplifiedChinese: "永久允许的工作流"),
      PrivacySettingsTextKey.cloudAlwaysAllowedDescription: .init(
        english:
          "These grants only match the saved workflow and provider configuration. Rill asks again after either changes.",
        simplifiedChinese: "授权仅匹配保存时的工作流与服务配置；任一配置变化后，Rill 都会重新询问。"),
      PrivacySettingsTextKey.revokeAuthorization: .init(
        english: "Revoke", simplifiedChinese: "撤销"),
      PrivacySettingsTextKey.revokeAllAuthorizations: .init(
        english: "Revoke All", simplifiedChinese: "全部撤销"),
      PrivacySettingsTextKey.description: .init(
        english: "Control privacy settings.", simplifiedChinese: "控制隐私设置。"),
      PrivacySettingsTextKey.deleteRule: .init(english: "Delete", simplifiedChinese: "删除"),
      PrivacySettingsTextKey.duplicateBundleIdentifier: .init(
        english: "This bundle identifier already has a rule.",
        simplifiedChinese: "这个 Bundle ID 已有规则。"),
      PrivacySettingsTextKey.editRule: .init(english: "Edit", simplifiedChinese: "编辑"),
      PrivacySettingsTextKey.historyPreviewDescription: .init(
        english:
          "Full previews show the complete result; restricted previews expose at most 96 summarized characters; hidden previews expose no result text. This does not delete local records.",
        simplifiedChinese: "完整预览显示全部结果；受限预览最多暴露 96 个摘要字符；隐藏预览不暴露结果正文。此设置不会删除本地记录。"),
      PrivacySettingsTextKey.historyPreviewHidden: .init(
        english: "Preview hidden by privacy setting", simplifiedChinese: "已按隐私设置隐藏预览"),
      PrivacySettingsTextKey.historyPreviewMode: .init(
        english: "History preview mode", simplifiedChinese: "历史预览模式"),
      PrivacySettingsTextKey.localRouteHint: .init(
        english: "Local route: recognition stays on this Mac.", simplifiedChinese: "本地路径：识别留在本机。"),
      PrivacySettingsTextKey.invalidBundleIdentifier: .init(
        english: "Enter a valid reverse-DNS bundle identifier.",
        simplifiedChinese: "请输入有效的反向域名格式 Bundle ID。"),
      PrivacySettingsTextKey.loading: .init(
        english: "Loading privacy settings…", simplifiedChinese: "正在加载隐私设置…"),
      PrivacySettingsTextKey.missingBundleIdentifier: .init(
        english: "A bundle identifier is required.", simplifiedChinese: "必须填写 Bundle ID。"),
      PrivacySettingsTextKey.recommendedRule: .init(
        english: "Recommended", simplifiedChinese: "推荐"),
      PrivacySettingsTextKey.recommendedRuleCannotBeEdited: .init(
        english: "Recommended rule identities cannot be edited or deleted.",
        simplifiedChinese: "推荐规则不能编辑标识或删除。"),
      PrivacySettingsTextKey.resetSafeDefaults: .init(
        english: "Reset to Safe Defaults", simplifiedChinese: "恢复安全默认值"),
      PrivacySettingsTextKey.restoreRecommended: .init(
        english: "Restore Recommended", simplifiedChinese: "恢复推荐规则"),
      PrivacySettingsTextKey.retryLoad: .init(english: "Retry Load", simplifiedChinese: "重试加载"),
      PrivacySettingsTextKey.retrySave: .init(english: "Retry Save", simplifiedChinese: "重试保存"),
      PrivacySettingsTextKey.routeDetailLabel: .init(english: "Privacy", simplifiedChinese: "隐私"),
      PrivacySettingsTextKey.ruleBlocksClipboard: .init(
        english: "Do not save clipboard history", simplifiedChinese: "不保存剪贴板历史"),
      PrivacySettingsTextKey.ruleBlocksCloud: .init(
        english: "Block cloud processing", simplifiedChinese: "阻止云端处理"),
      PrivacySettingsTextKey.ruleBlocksSelectedText: .init(
        english: "Redact selected text", simplifiedChinese: "隐藏选中文本"),
      PrivacySettingsTextKey.ruleBlocksWorkflow: .init(
        english: "Do not trigger workflows from clipboard", simplifiedChinese: "不从剪贴板触发工作流"),
      PrivacySettingsTextKey.ruleEnabled: .init(english: "Enabled", simplifiedChinese: "已启用"),
      PrivacySettingsTextKey.ruleNotFound: .init(
        english: "This rule no longer exists. Reload Settings and try again.",
        simplifiedChinese: "该规则已不存在，请重新打开设置后重试。"),
      PrivacySettingsTextKey.saveRule: .init(english: "Save Changes", simplifiedChinese: "保存更改"),
      PrivacySettingsTextKey.saving: .init(
        english: "Saving privacy settings…", simplifiedChinese: "正在保存隐私设置…"),
      PrivacySettingsTextKey.secureInputConservativeDescription: .init(
        english: "Redact selected text when secure input is detected.",
        simplifiedChinese: "检测到安全输入时隐藏选中文本。"),
      PrivacySettingsTextKey.secureInputConservativeMode: .init(
        english: "Conservative secure input", simplifiedChinese: "安全输入保守处理"),
      PrivacySettingsTextKey.sensitiveApps: .init(
        english: "Sensitive app exclusions", simplifiedChinese: "敏感 App 排除"),
      PrivacySettingsTextKey.sensitiveAppsDescription: .init(
        english: "Recommended rules cover password and keychain apps.",
        simplifiedChinese: "推荐规则覆盖密码和钥匙串工具。"),
      PrivacySettingsTextKey.technicalNotice: .init(
        english: "Technical Privacy Notice", simplifiedChinese: "技术隐私说明"),
      PrivacySettingsTextKey.technicalNoticeDescription: .init(
        english:
          "Read the bundled, offline description of local storage, network destinations, retention, and product boundaries.",
        simplifiedChinese: "查看随 App 离线提供的本地存储、网络目的地、留存和产品边界说明。"),
      PrivacySettingsTextKey.technicalNoticeUnavailable: .init(
        english:
          "The packaged privacy notice is unavailable. Reinstall Rill from a verified build.",
        simplifiedChinese: "安装包中的隐私说明不可用，请从已验证的构建重新安装 Rill。"),
      PrivacySettingsTextKey.title: .init(
        english: "Privacy & Sensitive Apps", simplifiedChinese: "隐私与敏感 App"),
    ]
  }

  static func historySettingsText(
    _ key: HistorySettingsTextKey,
    language: AppLanguage
  ) -> String {
    historySettingsTextTable[key]?.string(for: language) ?? key.rawValue
  }

  static func historyRetentionPeriod(
    _ period: HistoryRetentionPeriod,
    language: AppLanguage
  ) -> String {
    switch (period, language) {
    case (.oneDay, .english): return "1 day"
    case (.oneDay, .simplifiedChinese): return "1 天"
    case (.oneWeek, .english): return "1 week"
    case (.oneWeek, .simplifiedChinese): return "1 周"
    case (.thirtyDays, .english): return "30 days"
    case (.thirtyDays, .simplifiedChinese): return "30 天"
    case (.oneYear, .english): return "1 year"
    case (.oneYear, .simplifiedChinese): return "1 年"
    case (.forever, .english): return "Forever"
    case (.forever, .simplifiedChinese): return "永久保留"
    }
  }

  static func historyMaintenanceResult(
    removedCount: Int,
    preservedActiveRecordCount: Int,
    language: AppLanguage
  ) -> String {
    switch language {
    case .english:
      return
        "Removed \(removedCount) local record(s); preserved \(preservedActiveRecordCount) active record(s)."
    case .simplifiedChinese:
      return "已移除 \(removedCount) 条本地记录；保留 \(preservedActiveRecordCount) 条活跃记录。"
    }
  }

  private static var historySettingsTextTable: [HistorySettingsTextKey: LocalizedText] {
    [
      .cancel: .init(english: "Cancel", simplifiedChinese: "取消"),
      .clearClipboard: .init(english: "Clear Record History…", simplifiedChinese: "清除记录历史…"),
      .clearClipboardConfirmation: .init(
        english: "Remove eligible records now?",
        simplifiedChinese: "现在移除可清理的记录吗？"
      ),
      .clearClipboardConfirmationDetail: .init(
        english:
          "Unprotected records are removed. Pinned records and records with an active membership or delivery lease remain available.",
        simplifiedChinese: "将移除未受保护的记录；置顶记录及拥有活跃成员关系或投递租约的记录会继续保留。"
      ),
      .clearRun: .init(
        english: "Clear Run & Diagnostic History…",
        simplifiedChinese: "清除运行与诊断历史…"
      ),
      .clearRunConfirmation: .init(
        english: "Remove all run and diagnostic history now?",
        simplifiedChinese: "现在移除全部运行与诊断历史吗？"
      ),
      .clearRunConfirmationDetail: .init(
        english:
          "Run records and diagnostics are removed. Records and collections are not changed.",
        simplifiedChinese: "将移除运行记录与诊断；记录和记录集不会改变。"
      ),
      .recordRetention: .init(english: "Records", simplifiedChinese: "记录"),
      .description: .init(
        english:
          "Choose how long local records, run history, and diagnostics are kept. Cleanup can be retried if storage is temporarily unavailable.",
        simplifiedChinese: "分别设置本地记录、运行历史与诊断的保留时长；存储暂时不可用时可以重试清理。"
      ),
      .maintenancePending: .init(
        english: "Local history cleanup is pending.",
        simplifiedChinese: "本地历史清理尚待完成。"
      ),
      .maintenanceRunning: .init(
        english: "Updating local history…",
        simplifiedChinese: "正在更新本地历史…"
      ),
      .preservedClipboardDetail: .init(
        english:
          "Clearing does not remove pinned records or records with an active membership or delivery lease.",
        simplifiedChinese: "清除操作不会移除置顶记录，以及拥有活跃成员关系或投递租约的记录。"
      ),
      .preservedRunDetail: .init(
        english: "Run and diagnostic history is independent from Records and Collections.",
        simplifiedChinese: "运行与诊断历史和记录、记录集相互独立。"
      ),
      .retry: .init(english: "Retry Cleanup", simplifiedChinese: "重试清理"),
      .runActiveHint: .init(
        english:
          "Finish the active or queued voice run before clearing run and diagnostic history.",
        simplifiedChinese: "请先完成当前或排队中的语音运行，再清除运行与诊断历史。"
      ),
      .runRetention: .init(
        english: "Run & diagnostic history",
        simplifiedChinese: "运行与诊断历史"
      ),
      .title: .init(english: "Local Data & Retention", simplifiedChinese: "本地数据与留存"),
    ]
  }
}
enum PrivacySettingsTextKey: String, CaseIterable, Sendable {
  case addRule, applicationNameOptional, automaticRouteHint, bundleIdentifier, cancelEdit
  case cloudAlwaysAllowed, cloudAlwaysAllowedDescription, cloudConfirmation
  case cloudConfirmationDescription, deleteRule, description
  case duplicateBundleIdentifier, editRule, historyPreviewDescription, historyPreviewHidden
  case historyPreviewMode, invalidBundleIdentifier, loading, localRouteHint, missingBundleIdentifier
  case recommendedRule, recommendedRuleCannotBeEdited, resetSafeDefaults, restoreRecommended
  case retryLoad, retrySave, revokeAllAuthorizations, revokeAuthorization, routeDetailLabel
  case ruleBlocksClipboard, ruleBlocksCloud, ruleBlocksSelectedText, ruleBlocksWorkflow, ruleEnabled
  case ruleNotFound, saveRule, saving, secureInputConservativeDescription,
    secureInputConservativeMode
  case sensitiveApps, sensitiveAppsDescription, technicalNotice, technicalNoticeDescription
  case technicalNoticeUnavailable, title
}

enum HistorySettingsTextKey: String, CaseIterable, Sendable {
  case cancel
  case clearClipboard
  case clearClipboardConfirmation
  case clearClipboardConfirmationDetail
  case clearRun
  case clearRunConfirmation
  case clearRunConfirmationDetail
  case recordRetention
  case description
  case maintenancePending
  case maintenanceRunning
  case preservedClipboardDetail
  case preservedRunDetail
  case retry
  case runActiveHint
  case runRetention
  case title
}
extension L10n {
  public static func stackPending(_ count: Int, language: AppLanguage) -> String {
    switch language {
    case .english:
      return count == 0 ? "Route empty" : "\(count) item(s) pending"
    case .simplifiedChinese:
      return count == 0 ? "路由为空" : "待投递 \(count) 项"
    }
  }

  public static func recordCountSummary(_ count: Int, language: AppLanguage) -> String {
    switch language {
    case .english:
      return "\(count) item(s)"
    case .simplifiedChinese:
      return "\(count) 项"
    }
  }

  public static func permissionState(_ state: PermissionState, language: AppLanguage) -> String {
    switch (language, state) {
    case (.english, .granted):
      return "Granted"
    case (.simplifiedChinese, .granted):
      return "已授权"
    case (.english, .denied):
      return "Denied"
    case (.simplifiedChinese, .denied):
      return "未授权"
    case (.english, .unknown):
      return "Unknown"
    case (.simplifiedChinese, .unknown):
      return "未知"
    }
  }

  public static func workflowName(_ workflow: WorkflowPresentation, language: AppLanguage) -> String
  {
    guard let titleKey = workflow.titleKey else {
      return workflow.fallbackName
    }
    return workflowNameTable[titleKey]?.string(for: language) ?? workflow.fallbackName
  }

  private static var workflowNameTable: [WorkflowTitleKey: LocalizedText] {
    [
      .ambiguousDemoStack: .init(english: "Guided Capture", simplifiedChinese: "确认后保存"),
      .directDemoClipboard: .init(english: "Capture Selection", simplifiedChinese: "收进剪贴板组"),
      .rewriteDemoStack: .init(english: "Polish Draft", simplifiedChinese: "润色成稿"),
      .pushToTalkCapture: .init(english: "Accurate Transcription", simplifiedChinese: "精准转写"),
      .speechRecognition: .init(english: "Speech Recognition", simplifiedChinese: "语音识别"),
      .pushToTalkPolish: .init(
        english: "Transcription + LLM Rewrite (Planned)",
        simplifiedChinese: "转写 + 大模型润色（待办）"
      ),
      .rawInput: .init(english: "Raw Input", simplifiedChinese: "原样输入"),
      .cleanInput: .init(english: "Clean Input", simplifiedChinese: "干净输入"),
      .smartCleanup: .init(english: "Smart Cleanup", simplifiedChinese: "智能整理"),
      .formalWriting: .init(english: "Formal Writing", simplifiedChinese: "正式写作"),
      .translateInput: .init(english: "Translate Input", simplifiedChinese: "翻译输入"),
      .commandMode: .init(english: "Command Mode", simplifiedChinese: "命令模式"),
      .localDictation: .init(english: "Local Dictation", simplifiedChinese: "本地听写"),
      .cloudDictation: .init(english: "Cloud Dictation", simplifiedChinese: "云端听写"),
      .recordDelivery: .init(english: "Record Delivery", simplifiedChinese: "记录投递"),
      .streamingInput: .init(english: "Streaming Direct", simplifiedChinese: "流式直出"),
      .voiceAssistant: .init(english: "Voice Assistant", simplifiedChinese: "语音助手"),
    ]
  }

  public static func candidateModeSummary(
    mode: ResolutionMode,
    timeoutSeconds: Int,
    language: AppLanguage
  ) -> String {
    switch language {
    case .english:
      return "Mode: \(resolutionMode(mode, language: language)) · Timeout: \(timeoutSeconds)s"
    case .simplifiedChinese:
      return "模式：\(resolutionMode(mode, language: language)) · 超时：\(timeoutSeconds) 秒"
    }
  }

  public static func resolutionMode(_ mode: ResolutionMode, language: AppLanguage) -> String {
    switch (language, mode) {
    case (.english, .blocking):
      return "Blocking"
    case (.simplifiedChinese, .blocking):
      return "阻塞"
    case (.english, .nonBlocking):
      return "Non-blocking"
    case (.simplifiedChinese, .nonBlocking):
      return "非阻塞"
    case (.english, .off):
      return "Off"
    case (.simplifiedChinese, .off):
      return "关闭"
    }
  }

  public static func spanSummary(lowerBound: Int, upperBound: Int, language: AppLanguage) -> String
  {
    switch language {
    case .english:
      return "Span \(lowerBound)-\(upperBound)"
    case .simplifiedChinese:
      return "范围 \(lowerBound)-\(upperBound)"
    }
  }

  public static func candidateSource(_ source: CandidateSource, language: AppLanguage) -> String {
    switch (language, source) {
    case (_, .asr):
      return "ASR"
    case (_, .llm):
      return "LLM"
    case (.english, .heuristic):
      return "HEURISTIC"
    case (.simplifiedChinese, .heuristic):
      return "规则"
    case (.english, .user):
      return "USER"
    case (.simplifiedChinese, .user):
      return "用户"
    }
  }

  public static func subsystem(_ subsystem: SubsystemTag, language: AppLanguage) -> String {
    switch (language, subsystem) {
    case (.english, .session):
      return "Session"
    case (.simplifiedChinese, .session):
      return "会话"
    case (.english, .records):
      return "Records"
    case (.simplifiedChinese, .records):
      return "记录"
    case (.english, .systemClipboard):
      return "System Clipboard"
    case (.simplifiedChinese, .systemClipboard):
      return "系统剪贴板"
    case (.english, .resolver):
      return "Resolution"
    case (.simplifiedChinese, .resolver):
      return "消歧"
    case (.english, .platform):
      return "Platform"
    case (.simplifiedChinese, .platform):
      return "平台"
    case (.english, .providers):
      return "Speech"
    case (.simplifiedChinese, .providers):
      return "语音服务"
    case (.english, .ui):
      return "Interface"
    case (.simplifiedChinese, .ui):
      return "界面"
    }
  }

  public static func workflowDetail(_ workflow: WorkflowDefinition, language: AppLanguage) -> String
  {
    VoiceWorkflowPresentation(workflow: workflow).detail(language: language)
  }

  public static func workflowConflict(
    trigger: TriggerBinding,
    names: [String],
    language: AppLanguage
  ) -> String {
    let triggerName = workflowTrigger(trigger, language: language)
    let joinedNames = names.joined(separator: ", ")
    switch language {
    case .english:
      return "Conflict: \(triggerName) is also enabled for \(joinedNames)."
    case .simplifiedChinese:
      return "冲突：\(triggerName) 也被以下工作流启用了：\(joinedNames)。"
    }
  }

  public static func workflowEnableConflict(
    trigger: TriggerBinding,
    names: [String],
    language: AppLanguage
  ) -> String {
    let triggerName = workflowTrigger(trigger, language: language)
    let joinedNames = names.joined(separator: ", ")
    switch language {
    case .english:
      return "Cannot enable this workflow. \(triggerName) is already in use by \(joinedNames)."
    case .simplifiedChinese:
      return "无法启用这个工作流。\(triggerName) 已被以下工作流占用：\(joinedNames)。"
    }
  }

  public static func diagnosticLevel(_ level: DiagnosticLevel, language: AppLanguage) -> String {
    switch (language, level) {
    case (.english, .debug):
      return "DEBUG"
    case (.simplifiedChinese, .debug):
      return "调试"
    case (.english, .info):
      return "INFO"
    case (.simplifiedChinese, .info):
      return "信息"
    case (.english, .warning):
      return "WARNING"
    case (.simplifiedChinese, .warning):
      return "警告"
    case (.english, .error):
      return "ERROR"
    case (.simplifiedChinese, .error):
      return "错误"
    }
  }

  public static func workflowTrigger(
    _ trigger: TriggerBinding,
    metadata: [String: String] = [:],
    language: AppLanguage
  ) -> String {
    switch (language, trigger) {
    case (.english, .manual):
      return "Manual"
    case (.simplifiedChinese, .manual):
      return "手动"
    case (.english, .menuBar):
      return "Menu Bar"
    case (.simplifiedChinese, .menuBar):
      return "菜单栏"
    case (.english, .hotkey):
      return hotkeyGesture(metadata["trigger.gesture"], language: language)
    case (.simplifiedChinese, .hotkey):
      return hotkeyGesture(metadata["trigger.gesture"], language: language)
    case (.english, .wakeWord):
      return "Wake Word"
    case (.simplifiedChinese, .wakeWord):
      return "唤醒词"
    }
  }

  private static func hotkeyGesture(_ value: String?, language: AppLanguage) -> String {
    switch (language, value.flatMap(PushToTalkGesture.init(rawValue:))) {
    case (.english, .fnHold): "Hold Fn"
    case (.simplifiedChinese, .fnHold): "按住 Fn"
    case (_, .controlOptionShiftSpace): "⌃⌥⇧Space"
    case (.english, nil): value ?? "Hotkey"
    case (.simplifiedChinese, nil): value ?? "快捷键"
    }
  }

  public static func recognizerName(_ id: String, language: AppLanguage) -> String {
    switch (language, id) {
    case (.english, "local-speech"):
      return "Local Speech"
    case (.simplifiedChinese, "local-speech"):
      return "本地识别"
    case (.english, "sherpa-onnx.local"):
      return "Local Speech"
    case (.simplifiedChinese, "sherpa-onnx.local"):
      return "本地识别"
    case (.english, "sherpa-onnx.streaming"):
      return "Local Streaming Speech"
    case (.simplifiedChinese, "sherpa-onnx.streaming"):
      return "本地流式识别"
    default:
      return id
    }
  }

  public static func actionName(_ id: String, language: AppLanguage) -> String {
    switch id {
    case "focused-application.insert": return language == .english ? "Paste into App" : "输入到当前应用"
    case "system-clipboard.copy": return language == .english ? "Copy to Clipboard" : "复制到剪贴板"
    case "record.store": return language == .english ? "Save to Queue" : "保存到队列"
    case ExternalOutputActionID.webhookPost: return "Webhook"
    case ExternalOutputActionID.shortcutsRun:
      return language == .english ? "Run Shortcut" : "运行快捷指令"
    case ExternalOutputActionID.markdownAppend:
      return language == .english ? "Append to Markdown" : "追加到 Markdown"
    default: return id
    }
  }

  public static func editorRecognizer(
    _ recognizer: WorkflowEditorDraft.RecognizerChoice,
    language: AppLanguage
  ) -> String {
    switch (language, recognizer) {
    case (.english, .automatic):
      return "Automatic"
    case (.simplifiedChinese, .automatic):
      return "自动"
    case (.english, .localSpeech):
      return "Local Speech"
    case (.simplifiedChinese, .localSpeech):
      return "本地识别"
    }
  }

  public static func editorDestination(
    _ destination: WorkflowEditorDraft.DestinationChoice,
    language: AppLanguage
  ) -> String {
    switch destination {
    case .pasteIntoApp: return language == .english ? "Paste into Active App" : "输入到当前应用"
    case .copyToClipboard: return language == .english ? "Copy to Clipboard" : "复制到剪贴板"
    case .saveToQueue: return language == .english ? "Save to Clipboard Queue" : "保存到剪贴板队列"
    case .speakOnly: return language == .english ? "Speak Only" : "仅朗读"
    case .sendToWebhook: return "Webhook"
    case .runShortcut: return language == .english ? "Run macOS Shortcut" : "运行 macOS 快捷指令"
    case .appendToMarkdown:
      return language == .english ? "Append to Obsidian/Markdown" : "追加到 Obsidian/Markdown"
    }
  }

  public static func speechEngine(_ engine: PreferredSpeechEngine, language: AppLanguage) -> String
  {
    switch (language, engine) {
    case (.english, .local):
      return "Local"
    case (.simplifiedChinese, .local):
      return "本地"
    }
  }

  public static func localSpeechEngine(
    _ engine: LocalSpeechEngine,
    language: AppLanguage
  ) -> String {
    switch (language, engine) {
    case (.english, .sherpaOnnx):
      return "Legacy Local"
    case (.simplifiedChinese, .sherpaOnnx):
      return "旧版本地"
    case (.english, .mlxAudioSwift):
      return "MLX Local"
    case (.simplifiedChinese, .mlxAudioSwift):
      return "MLX 本地"
    }
  }

  public static func localSpeechModelOption(
    _ option: LegacyWhisperModelOption,
    language: AppLanguage
  ) -> String {
    switch language {
    case .english:
      switch option {
      case .automatic:
        return "Automatic"
      case .tiny:
        return "Fast — Tiny"
      case .distilLargeV3Compact:
        return "English Only — Distilled Large v3"
      case .largeV320240930Compact:
        return "Best Quality — Large v3"
      case .custom:
        return "Custom"
      }
    case .simplifiedChinese:
      switch option {
      case .automatic:
        return "自动"
      case .tiny:
        return "快速 — Tiny"
      case .distilLargeV3Compact:
        return "仅英语 — Distilled Large v3"
      case .largeV320240930Compact:
        return "最佳质量 — Large v3"
      case .custom:
        return "自定义"
      }
    }
  }

  public static func builtinPushToTalkOutputMode(
    _ mode: BuiltinPushToTalkOutputMode,
    language: AppLanguage
  ) -> String {
    switch (language, mode) {
    case (.english, .pasteIntoApp):
      return "Type into App and Save Record"
    case (.simplifiedChinese, .pasteIntoApp):
      return "输入并记录"
    case (.english, .saveToVoiceGroup):
      return "Save Voice Record Only"
    case (.simplifiedChinese, .saveToVoiceGroup):
      return "仅保存语音记录"
    }
  }
}
