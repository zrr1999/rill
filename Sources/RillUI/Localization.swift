import Foundation
import RillCore

public enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
  case english
  case simplifiedChinese

  public var id: String { rawValue }

  public static var preferred: AppLanguage {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .simplifiedChinese : .english
  }

  public var displayName: String {
    switch self {
    case .english:
      return "English"
    case .simplifiedChinese:
      return "中文"
    }
  }
}

extension L10n {
  public enum InterfaceKey: Sendable {
    case appTitle
    case menuBarLabel
    case appSubtitle
    case workflow
    case language
    case runSelectedWorkflow
    case running
    case workflowRecordAndRun
    case workflowPreparingAudio
    case workflowStopAndTranscribe
    case workflowTranscribing
    case streamActivityRecording
    case deliverNextRecord
    case deliveryStack
    case latestOutput
    case eventFeed
    case eventFeedEmpty
    case stackEmpty
    case noCompletedOutput
    case noRecentFailure
    case voiceSetupTitle
    case voiceSetupDescription
    case voiceSetupLoading
    case voiceSetupGlobalInputChecking
    case voiceSetupGlobalInputReady
    case voiceSetupGlobalInputVoiceOnlyReady
    case voiceSetupGlobalInputPermissionNeeded
    case voiceSetupGlobalInputInstallationFailed
    case voiceSetupMicrophoneReady
    case voiceSetupMicrophoneNeeded
    case voiceSetupAccessibilityReady
    case voiceSetupAccessibilityNeeded
    case voiceSetupAccessibilityOptional
    case voiceSetupLocalPreparing
    case voiceSetupLocalReady
    case voiceSetupLocalArchitectureUnsupported
    case voiceSetupLocalTrustMaterialUnavailable
    case voiceSetupLocalPreviouslyPrepared
    case voiceSetupLocalNeedsPreparation
    case voiceSetupLocalWillDownload
    case voiceSetupLocalFailed
    case voiceSetupPrivacyLoading
    case voiceSetupPrivacyUnavailable
    case permissions
    case permissionHint
    case refreshPermissions
    case accessibility
    case globalInput
    case microphone
    case requestAccess
    case retryGlobalInput
    case retryCredentialLoad
    case openSettings
    case appNotListedHint
    case commandVHint
    case candidateResolution
    case candidateResolutionHint
    case selectReplacement
    case ambiguousText
    case resolvedPreview
    case applySelection
    case useDefaults
    case dismiss
    case liveSubtitleClose
    case copy
    case searchCancelShortcutHint
    case sidebarStream
    case sidebarWorkflows
    case sidebarRecords
    case recordCollections
    case sidebarClipboard
    case sidebarDiagnostics
    case sidebarSettings
    case openWorkflowEditor
    case settingsTitle
    case settingsDescription
    case settingsSaveFailedTitle
    case settingsSaveRetry
    case settingsSaveRetrying
    case historyEmpty
    case historyPageEmpty
    case historyDescription
    case historyLoading
    case historyLoadFailedTitle
    case historyLoadFailedDescription
    case historyRetryLoad
    case historyLoadSessionOnlyTitle
    case historyLoadSessionOnlyDescription
    case historyLoadSessionOnlyViewStorage
    case historyNewRunsAvailable
    case historyRefreshNewest
    case historyNewerPage
    case historyOlderPage
    case historyPaginationFailed
    case historyEntryExpiredTitle
    case historyEntryExpiredDescription
    case historyStackBadge
    case historyScopeLabel
    case historyScopeAll
    case resultsEmpty
    case resultsTitle
    case resultsDescription
    case clipboardTitle
    case clipboardDescription
    case clipboardGroups
    case clipboardGroupsEmpty
    case clipboardGroupPreviewEmpty
    case clipboardAppAssignments
    case clipboardAppAssignmentsEmpty
    case clipboardAssignedGroup
    case clipboardCreateGroup
    case clipboardNewGroupName
    case clipboardCreate
    case clipboardCrossGroupFallback
    case clipboardCrossGroupFallbackHint
    case clipboardDefaultGroup
    case clipboardHistory
    case clipboardRouting
    case clipboardHistoryRemainingOnly
    case clipboardHistoryAllItems
    case clipboardMergeSimilar
    case clipboardMergeSimilarHint
    case clipboardMergedSimilarBadge
    case clipboardEmpty
    case clipboardNoResults
    case clipboardSelectItem
    case recordReplayWithWorkflow
    case clipboardReplaceWithWorkflow
    case recordUseItem
    case clipboardDeleteItem
    case clipboardPinItem
    case clipboardUnpinItem
    case clipboardPinnedBadge
    case clipboardPinnedOnly
    case clipboardSearch
    case clipboardClearSearch
    case clipboardNoPinnedItems
    case clipboardSection
    case clipboardAddTag
    case clipboardRemoveTag
    case clipboardPasteMode
    case clipboardAlternatives
    case clipboardTags
    case clipboardSystemSourceFallback
    case clipboardWorkflowSourceFallback
    case settingsLanguage
    case settingsLanguageDescription
    case settingsRecordPanel
    case settingsRecordPanelDescription
    case settingsClipboardCaptureEnabled
    case settingsClipboardCaptureEnabledDescription
    case clipboardCaptureDisabledTitle
    case clipboardCaptureDisabledDescription
    case clipboardCaptureEnable
    case recordPanelHotkeyRecord
    case recordPanelHotkeyRecording
    case recordPanelHotkeyReset
    case recordPanelHotkeyHint
    case recordPanelHotkeyDefault
    case recordPanelHotkeyRecorderLabel
    case settingsStackDelivery
    case settingsStackDescription
    case settingsStackStatus
    case settingsDiagnostics
    case settingsDiagnosticsDescription
    case refreshDiagnostics
    case diagnosticsLoading
    case diagnosticsLoadFailed
    case diagnosticsRetry
    case diagnosticsEmpty
    case settingsSpeechEngine
    case settingsSpeechEngineDescription
    case settingsBuiltinPushToTalk
    case settingsBuiltinPushToTalkDescription
    case settingsLocalSpeech
    case settingsLocalSpeechDescription
    case localSpeechArchitectureUnsupported
    case localSpeechTrustMaterialUnavailable
    case localSpeechModel
    case localSpeechDownloadedModels
    case localSpeechDownloaded
    case localSpeechNotDownloaded
    case legacyWhisperKitCustomModel
    case legacyWhisperKitCustomModelHint
    case legacyWhisperKitCustomModelRequired
    case legacyWhisperKitModelRepo
    case legacyWhisperKitModelToken
    case legacyWhisperKitModelFolder
    case legacyWhisperKitLanguage
    case localSpeechAutoDownload
    case localSpeechPrewarm
    case localSpeechPrepare
    case localSpeechPreparing
    case localSpeechValidating
    case localSpeechFinalizing
    case localSpeechCancelPreparation
    case localSpeechPreparationReady
    case localSpeechReleaseMemory
    case localSpeechReleaseMemoryHint
    case localSpeechLocalTestHint
    case localSpeechPreparationHint
    case localSpeechTrustedCatalogHint
    case settingsWorkflows
    case settingsWorkflowsDescription
    case stackPasteRequiresAccessibility
    case diagnosticsTitle
    case diagnosticsDescription
    case diagnosticsTimeline
    case workflowsTitle
    case workflowsDescription
    case workflowEditor
    case workflowLibrary
    case workflowNew
    case workflowSave
    case workflowReset
    case workflowNameField
    case workflowRecognizer
    case workflowDestination
    case workflowTrigger
    case workflowSourceCollection
    case workflowTargetGroup
    case workflowGroupAction
    case workflowMoveStepUp
    case workflowMoveStepDown
    case workflowRemoveStep
    case workflowLocalModel
    case workflowGlobalModelDefault
    case workflowNormalizeWhitespace
    case workflowExcludeFromCapture
    case workflowExcludeFromCaptureHint
    case workflowBuiltIn
    case workflowCustom
    case builtinPushToTalkOutputMode
    case workflowSelected
    case workflowEdit
    case workflowDelete
    case workflowDeleteConfirmationTitle
    case workflowDeleteConfirmationDetail
    case workflowUse
    case workflowEnabled
    case workflowCustomEmpty
    case vocabularyRule
    case vocabularyDeleteRule
  }

  public static func text(_ key: InterfaceKey, language: AppLanguage) -> String {
    interfaceTextTable[key]?.string(for: language) ?? String(describing: key)
  }

  public static func localSpeechAvailabilityDescription(
    _ availability: LocalSpeechAvailability,
    language: AppLanguage
  ) -> String {
    let key: InterfaceKey =
      switch availability {
      case .available:
        .settingsLocalSpeechDescription
      case .architectureUnsupported:
        .localSpeechArchitectureUnsupported
      case .trustMaterialUnavailable:
        .localSpeechTrustMaterialUnavailable
      }
    return text(key, language: language)
  }

  public static func settingsSaveCategory(
    _ category: SettingsSaveCategory,
    language: AppLanguage
  ) -> String {
    switch (language, category) {
    case (.english, .privacy): "Privacy"
    case (.simplifiedChinese, .privacy): "隐私"
    case (.english, .interface): "Interface"
    case (.simplifiedChinese, .interface): "界面"
    case (.english, .systemClipboard): "System Clipboard"
    case (.simplifiedChinese, .systemClipboard): "系统剪贴板"
    case (.english, .speech): "Speech"
    case (.simplifiedChinese, .speech): "语音"
    case (.english, .input): "Input"
    case (.simplifiedChinese, .input): "输入"
    case (.english, .vocabulary): "Vocabulary"
    case (.simplifiedChinese, .vocabulary): "词汇"
    case (.english, .workflows): "Workflows"
    case (.simplifiedChinese, .workflows): "工作流"
    }
  }

  public static func recordingDurationLimit(
    _ limit: RecordingDurationLimit,
    language: AppLanguage
  ) -> String {
    switch (language, limit) {
    case (.english, .twoMinutes):
      "2 minutes"
    case (.simplifiedChinese, .twoMinutes):
      "2 分钟"
    case (.english, .fiveMinutes):
      "5 minutes"
    case (.simplifiedChinese, .fiveMinutes):
      "5 分钟"
    case (.english, .unlimited):
      "Unlimited"
    case (.simplifiedChinese, .unlimited):
      "无限制"
    }
  }

  public static func settingsSaveFailureDescription(
    _ summary: UnsavedSettingsSummary,
    language: AppLanguage
  ) -> String {
    let categories = summary.categories
      .map { settingsSaveCategory($0, language: language) }
      .joined(separator: language == .english ? ", " : "、")
    switch language {
    case .english:
      let change = summary.affectedChangeCount == 1 ? "change" : "changes"
      let verb = summary.affectedChangeCount == 1 ? "is" : "are"
      return "\(summary.affectedChangeCount) \(change) in \(categories) "
        + "\(verb) active only for this session. Retry before quitting Rill."
    case .simplifiedChinese:
      return "\(categories)中的 \(summary.affectedChangeCount) 项更改仅在本次会话中有效。请在退出 Rill 前重试。"
    }
  }

  public static func loadedRunCount(_ count: Int, language: AppLanguage) -> String {
    switch language {
    case .english:
      return count == 1 ? "1 run loaded" : "\(count) runs loaded"
    case .simplifiedChinese:
      return "已加载 \(count) 条运行"
    }
  }

  public static func clipboardDeleteConfirmationTitle(
    itemCount: Int,
    language: AppLanguage
  ) -> String {
    switch language {
    case .english:
      return itemCount == 1
        ? "Delete this record?"
        : "Delete these \(itemCount) merged records?"
    case .simplifiedChinese:
      return itemCount == 1
        ? "删除这条记录？"
        : "删除这 \(itemCount) 条已合并的记录？"
    }
  }

  public static func clipboardDeleteConfirmationDescription(
    itemCount: Int,
    language: AppLanguage
  ) -> String {
    switch language {
    case .english:
      return itemCount == 1
        ? "This permanently removes the saved record. This action can't be undone."
        : "This permanently removes all \(itemCount) saved records represented by this row. This action can't be undone."
    case .simplifiedChinese:
      return itemCount == 1
        ? "这会永久移除已保存的记录，且无法撤销。"
        : "这会永久移除该行所代表的全部 \(itemCount) 条已保存记录，且无法撤销。"
    }
  }

  public static func clipboardEntryAccessibilityValue(
    copyCount: Int,
    groupName: String,
    language: AppLanguage
  ) -> String {
    switch language {
    case .english:
      let count = copyCount == 1 ? "1 saved item" : "\(copyCount) saved items"
      return "\(groupName), \(count)"
    case .simplifiedChinese:
      return "\(groupName)，\(copyCount) 个已保存条目"
    }
  }

  public static func clipboardEntryAccessibilityHint(
    supportsDirectPaste: Bool,
    language: AppLanguage
  ) -> String {
    switch (language, supportsDirectPaste) {
    case (.english, true):
      "Selects this item. Press Return to paste it."
    case (.english, false):
      "Selects this item and opens its details."
    case (.simplifiedChinese, true):
      "选择这个条目；按 Return 键可粘贴。"
    case (.simplifiedChinese, false):
      "选择这个条目并打开其详情。"
    }
  }

  public static func targetedAccessibilityLabel(
    _ key: InterfaceKey,
    target: String,
    language: AppLanguage
  ) -> String {
    let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTarget.isEmpty else { return text(key, language: language) }
    let separator = language == .english ? ": " : "："
    return "\(text(key, language: language))\(separator)\(trimmedTarget)"
  }
}

private let interfaceTextTable: [L10n.InterfaceKey: LocalizedText] = [
  .appTitle: .init(
    english: "Rill",
    simplifiedChinese: "Rill"
  ),
  .menuBarLabel: .init(
    english: "Rill",
    simplifiedChinese: "Rill"
  ),
  .appSubtitle: .init(
    english: "Hands-free writing with voice workflows, clipboard history, and fast replay.",
    simplifiedChinese: "用语音工作流、剪贴板历史和快速重放来更高效地输入内容。"
  ),
  .workflow: .init(
    english: "Workflows",
    simplifiedChinese: "工作流"
  ),
  .language: .init(
    english: "Language",
    simplifiedChinese: "界面语言"
  ),
  .runSelectedWorkflow: .init(
    english: "Run Workflow",
    simplifiedChinese: "运行工作流"
  ),
  .running: .init(
    english: "Running...",
    simplifiedChinese: "运行中..."
  ),
  .workflowRecordAndRun: .init(
    english: "Record and Run",
    simplifiedChinese: "录音并运行"
  ),
  .workflowPreparingAudio: .init(
    english: "Preparing Recording...",
    simplifiedChinese: "正在准备录音..."
  ),
  .workflowStopAndTranscribe: .init(
    english: "Stop and Transcribe",
    simplifiedChinese: "停止并转写"
  ),
  .workflowTranscribing: .init(
    english: "Transcribing...",
    simplifiedChinese: "转写中..."
  ),
  .streamActivityRecording: .init(
    english: "Recording...",
    simplifiedChinese: "录音中..."
  ),
  .deliverNextRecord: .init(
    english: "Deliver Next Record",
    simplifiedChinese: "投递下一条记录"
  ),
  .deliveryStack: .init(
    english: "Record Queue",
    simplifiedChinese: "记录队列"
  ),
  .latestOutput: .init(
    english: "Recent Results",
    simplifiedChinese: "最近结果"
  ),
  .eventFeed: .init(
    english: "Activity",
    simplifiedChinese: "活动"
  ),
  .eventFeedEmpty: .init(
    english: "No events yet. Run a workflow to see activity here.",
    simplifiedChinese: "暂无事件。运行工作流后，活动将显示在此处。"
  ),
  .stackEmpty: .init(
    english: "Record queue is empty",
    simplifiedChinese: "记录队列为空"
  ),
  .noCompletedOutput: .init(
    english: "No results yet",
    simplifiedChinese: "还没有结果"
  ),
  .noRecentFailure: .init(
    english: "No recent issues",
    simplifiedChinese: "最近没有问题"
  ),
  .voiceSetupTitle: .init(
    english: "Finish Voice Setup",
    simplifiedChinese: "完成语音设置"
  ),
  .voiceSetupDescription: .init(
    english:
      "Complete the steps required by your selected speech route. Permissions are requested only "
      + "when you choose an action below.",
    simplifiedChinese: "完成当前语音路线所需的步骤。只有点击下面的操作时，Rill 才会请求系统权限。"
  ),
  .voiceSetupLoading: .init(
    english: "Loading saved speech settings and credentials…",
    simplifiedChinese: "正在加载已保存的语音设置和凭据…"
  ),
  .voiceSetupGlobalInputChecking: .init(
    english: "Checking whether global keyboard input is active…",
    simplifiedChinese: "正在检查全局键盘输入是否可用…"
  ),
  .voiceSetupGlobalInputReady: .init(
    english: "Ready for Fn push-to-talk and global clipboard shortcuts.",
    simplifiedChinese: "已可使用 Fn 按住说话和全局剪贴板快捷键。"
  ),
  .voiceSetupGlobalInputVoiceOnlyReady: .init(
    english: "Ready for Fn push-to-talk.",
    simplifiedChinese: "已可使用 Fn 按住说话。"
  ),
  .voiceSetupGlobalInputPermissionNeeded: .init(
    english: "Input Monitoring access is required for Fn push-to-talk and global shortcuts.",
    simplifiedChinese: "Fn 按住说话和全局快捷键需要“输入监控”权限。"
  ),
  .voiceSetupGlobalInputInstallationFailed: .init(
    english: "Global input could not start. Check Input Monitoring and Accessibility, then retry.",
    simplifiedChinese: "全局输入未能启动。请检查“输入监控”和“辅助功能”权限后重试。"
  ),
  .voiceSetupMicrophoneReady: .init(
    english: "Ready for voice capture.",
    simplifiedChinese: "已可录制语音。"
  ),
  .voiceSetupMicrophoneNeeded: .init(
    english: "Required for voice capture and speech checks.",
    simplifiedChinese: "录音和语音检查需要此权限。"
  ),
  .voiceSetupAccessibilityReady: .init(
    english: "Ready for direct text insertion.",
    simplifiedChinese: "已可直接输入文本。"
  ),
  .voiceSetupAccessibilityNeeded: .init(
    english: "Required because built-in Fn workflows are set to type into the active app.",
    simplifiedChinese: "内置 Fn 工作流当前会输入到活动 App，因此需要此权限。"
  ),
  .voiceSetupAccessibilityOptional: .init(
    english: "Optional while built-in Fn workflows save results to the Speech Recognition group.",
    simplifiedChinese: "内置 Fn 工作流保存到“语音识别”分组时，此权限可选。"
  ),
  .voiceSetupLocalPreparing: .init(
    english: "Downloading or loading the selected local model…",
    simplifiedChinese: "正在下载或加载所选本地模型…"
  ),
  .voiceSetupLocalReady: .init(
    english: "The selected local model is loaded for this app session.",
    simplifiedChinese: "所选本地模型已在本次 App 会话中加载。"
  ),
  .voiceSetupLocalArchitectureUnsupported: .init(
    english:
      "This build does not include a compatible local speech runtime. Use a supported Rill build.",
    simplifiedChinese: "此构建未包含兼容的本地语音运行时。请使用受支持的 Rill 构建。"
  ),
  .voiceSetupLocalTrustMaterialUnavailable: .init(
    english:
      "This build does not include reviewed local model trust material. Local speech and model downloads are disabled.",
    simplifiedChinese: "此构建未包含受审的本地模型信任材料。本地语音与模型下载已禁用。"
  ),
  .voiceSetupLocalPreviouslyPrepared: .init(
    english:
      "A prior preparation is recorded, but the current model cache has not been verified. Prepare it again to confirm.",
    simplifiedChinese: "存在过去的准备记录，但尚未验证当前模型缓存。请再次准备以确认。"
  ),
  .voiceSetupLocalNeedsPreparation: .init(
    english: "No successful preparation is recorded, and automatic download is off.",
    simplifiedChinese: "尚无成功准备记录，且自动下载已关闭。"
  ),
  .voiceSetupLocalWillDownload: .init(
    english: "Not prepared yet. It can download on first use; prepare now to avoid that delay.",
    simplifiedChinese: "尚未准备。首次使用时可以自动下载；现在准备可避免首次运行等待。"
  ),
  .voiceSetupLocalFailed: .init(
    english: "Local model preparation failed. Open Settings for the reported error and retry.",
    simplifiedChinese: "本地模型准备失败。请在设置中查看已报告的错误并重试。"
  ),
  .voiceSetupPrivacyLoading: .init(
    english: "Loading privacy safeguards…",
    simplifiedChinese: "正在加载隐私保护设置…"
  ),
  .voiceSetupPrivacyUnavailable: .init(
    english: "Privacy settings are unavailable, so voice runs remain blocked.",
    simplifiedChinese: "隐私设置不可用，因此语音运行保持阻断。"
  ),
  .permissions: .init(
    english: "Permissions",
    simplifiedChinese: "权限"
  ),
  .permissionHint: .init(
    english:
      "Input Monitoring is used for Fn push-to-talk and global shortcuts. Accessibility is used "
      + "when an output types directly into the active app. Microphone access is used for recording.",
    simplifiedChinese: "输入监控权限用于 Fn 按住说话和全局快捷键；输出需要直接输入活动 App 时才使用辅助功能权限；" + "麦克风权限用于录音。"
  ),
  .refreshPermissions: .init(
    english: "Refresh",
    simplifiedChinese: "刷新状态"
  ),
  .accessibility: .init(
    english: "Accessibility",
    simplifiedChinese: "辅助功能"
  ),
  .globalInput: .init(
    english: "Global Input",
    simplifiedChinese: "全局输入"
  ),
  .microphone: .init(
    english: "Microphone",
    simplifiedChinese: "麦克风"
  ),
  .requestAccess: .init(
    english: "Request Access",
    simplifiedChinese: "请求授权"
  ),
  .retryGlobalInput: .init(
    english: "Retry",
    simplifiedChinese: "重试"
  ),
  .retryCredentialLoad: .init(
    english: "Retry Keychain",
    simplifiedChinese: "重试钥匙串"
  ),
  .openSettings: .init(
    english: "Open Settings",
    simplifiedChinese: "打开设置"
  ),
  .appNotListedHint: .init(
    english:
      "If the app is not listed in Privacy settings yet, click Request Access once first. The "
      + "system only adds it after an authorization prompt has been requested.",
    simplifiedChinese: "如果你还没在隐私权限列表里看到这个应用，请先点一次“请求授权”。系统通常会在触发授权提示后才把它加入列表。"
  ),
  .commandVHint: .init(
    english:
      "Copy and paste work normally. Rill records clipboard history in the background; "
      + "open the clipboard panel to explicitly copy or paste a saved item.",
    simplifiedChinese: "复制和粘贴保持系统原有行为。Rill 在后台记录剪贴板历史；打开面板后，可手动复制或粘贴历史条目。"
  ),
  .candidateResolution: .init(
    english: "Candidate Resolution",
    simplifiedChinese: "候选词消歧"
  ),
  .candidateResolutionHint: .init(
    english: "Review ambiguous spans before the workflow continues.",
    simplifiedChinese: "在工作流继续之前，请先确认这些存在歧义的词。"
  ),
  .selectReplacement: .init(
    english: "Select the most likely replacement for this span.",
    simplifiedChinese: "为这个歧义片段选择最可能的替换结果。"
  ),
  .ambiguousText: .init(
    english: "Ambiguous text",
    simplifiedChinese: "歧义文本"
  ),
  .resolvedPreview: .init(
    english: "Resolved Preview",
    simplifiedChinese: "解析预览"
  ),
  .applySelection: .init(
    english: "Apply Selection",
    simplifiedChinese: "应用当前选择"
  ),
  .useDefaults: .init(
    english: "Use Defaults",
    simplifiedChinese: "使用默认候选"
  ),
  .dismiss: .init(
    english: "Dismiss",
    simplifiedChinese: "取消"
  ),
  .liveSubtitleClose: .init(
    english: "Close live subtitle",
    simplifiedChinese: "关闭实时字幕"
  ),
  .copy: .init(
    english: "Copy",
    simplifiedChinese: "复制"
  ),
  .searchCancelShortcutHint: .init(
    english: "Close search (Esc)",
    simplifiedChinese: "关闭搜索（Esc）"
  ),
  .sidebarStream: .init(
    english: "Activity",
    simplifiedChinese: "活动"
  ),
  .sidebarWorkflows: .init(
    english: "Workflows",
    simplifiedChinese: "工作流"
  ),
  .sidebarRecords: .init(
    english: "Records",
    simplifiedChinese: "记录"
  ),
  .recordCollections: .init(
    english: "Collections",
    simplifiedChinese: "记录集"
  ),
  .sidebarClipboard: .init(
    english: "Clipboard",
    simplifiedChinese: "剪贴板"
  ),
  .sidebarDiagnostics: .init(
    english: "Diagnostics",
    simplifiedChinese: "诊断"
  ),
  .sidebarSettings: .init(
    english: "Settings",
    simplifiedChinese: "设置"
  ),
  .openWorkflowEditor: .init(
    english: "Manage Workflows",
    simplifiedChinese: "管理工作流"
  ),
  .settingsTitle: .init(
    english: "Settings",
    simplifiedChinese: "设置"
  ),
  .settingsDescription: .init(
    english: "Manage interface preferences, permissions, and cloud speech configuration.",
    simplifiedChinese: "管理界面偏好、权限和云端语音配置。"
  ),
  .settingsSaveFailedTitle: .init(
    english: "Some settings aren't saved",
    simplifiedChinese: "部分设置尚未保存"
  ),
  .settingsSaveRetry: .init(
    english: "Retry Saving",
    simplifiedChinese: "重试保存"
  ),
  .settingsSaveRetrying: .init(
    english: "Retrying…",
    simplifiedChinese: "正在重试…"
  ),
  .historyEmpty: .init(
    english: "No runs yet. Run a workflow to see results here.",
    simplifiedChinese: "还没有运行记录。运行一个工作流后结果会显示在这里。"
  ),
  .historyPageEmpty: .init(
    english: "No runs remain on this page. Go to a newer page or refresh the latest history.",
    simplifiedChinese: "此页已没有保留的运行记录。请前往较新页面或刷新最新历史。"
  ),
  .historyDescription: .init(
    english:
      "Review recently loaded workflow attempts, including results, failures, cancellations, skips, clipboard runs, and execution details.",
    simplifiedChinese: "查看最近加载的工作流尝试，包括结果、失败、取消、跳过、剪贴板运行与执行详情。"
  ),
  .historyLoading: .init(
    english: "Loading run history…",
    simplifiedChinese: "正在加载运行历史…"
  ),
  .historyLoadFailedTitle: .init(
    english: "Run history is unavailable",
    simplifiedChinese: "运行历史暂不可用"
  ),
  .historyLoadFailedDescription: .init(
    english:
      "Rill couldn't read your saved run history. Your data was not replaced; try loading it again.",
    simplifiedChinese: "Rill 无法读取已保存的运行历史。现有数据未被替换，请重试加载。"
  ),
  .historyRetryLoad: .init(
    english: "Try Again",
    simplifiedChinese: "重试"
  ),
  .historyLoadSessionOnlyTitle: .init(
    english: "Saved history is unavailable",
    simplifiedChinese: "已保存的历史记录不可用"
  ),
  .historyLoadSessionOnlyDescription: .init(
    english:
      "Rill is running session-only, so reopening saved history cannot "
      + "succeed until persistent storage is available.",
    simplifiedChinese: "Rill 当前仅在本次会话中运行；在持久化存储恢复前，重新加载已保存历史不会成功。"
  ),
  .historyLoadSessionOnlyViewStorage: .init(
    english: "View Storage Settings",
    simplifiedChinese: "查看存储设置"
  ),
  .historyNewRunsAvailable: .init(
    english: "New runs are available",
    simplifiedChinese: "有新的运行记录"
  ),
  .historyRefreshNewest: .init(
    english: "Show Newest",
    simplifiedChinese: "查看最新记录"
  ),
  .historyNewerPage: .init(
    english: "Newer",
    simplifiedChinese: "较新"
  ),
  .historyOlderPage: .init(
    english: "Older",
    simplifiedChinese: "较早"
  ),
  .historyPaginationFailed: .init(
    english: "This page couldn't be loaded. The current page is unchanged.",
    simplifiedChinese: "无法加载该页，当前页面保持不变。"
  ),
  .historyEntryExpiredTitle: .init(
    english: "Run no longer available",
    simplifiedChinese: "运行记录已不可用"
  ),
  .historyEntryExpiredDescription: .init(
    english: "This run was removed by retention or cleanup and can no longer be opened.",
    simplifiedChinese: "该运行记录已被保留策略或清理操作移除，无法再打开。"
  ),
  .historyStackBadge: .init(
    english: "Clipboard",
    simplifiedChinese: "剪贴板"
  ),
  .historyScopeLabel: .init(
    english: "Run history view",
    simplifiedChinese: "运行历史视图"
  ),
  .historyScopeAll: .init(
    english: "Recent Runs",
    simplifiedChinese: "最近运行"
  ),
  .resultsEmpty: .init(
    english: "No voice results yet. Finish a recording to see text here.",
    simplifiedChinese: "还没有语音结果。完成一次录音后，文本会显示在这里。"
  ),
  .resultsTitle: .init(
    english: "Recent Results",
    simplifiedChinese: "最近结果"
  ),
  .resultsDescription: .init(
    english:
      "Review the latest successful voice outputs without failed runs or clipboard-only noise.",
    simplifiedChinese: "查看最近成功的语音输出，不混入失败记录和非语音剪贴板内容。"
  ),
  .clipboardTitle: .init(
    english: "Clipboard History",
    simplifiedChinese: "剪贴板历史"
  ),
  .clipboardDescription: .init(
    english:
      "Review clipboard groups, assign apps into a single group, and replay any item through a "
      + "workflow.",
    simplifiedChinese: "查看剪贴板分组，把应用归入唯一分组，并把任意条目重新交给工作流处理。"
  ),
  .clipboardGroups: .init(
    english: "Groups",
    simplifiedChinese: "分组"
  ),
  .clipboardGroupsEmpty: .init(
    english: "No groups yet.",
    simplifiedChinese: "还没有分组。"
  ),
  .clipboardGroupPreviewEmpty: .init(
    english: "No pending item in this group.",
    simplifiedChinese: "这个分组里还没有待粘贴的条目。"
  ),
  .clipboardAppAssignments: .init(
    english: "App Assignments",
    simplifiedChinese: "应用归组"
  ),
  .clipboardAppAssignmentsEmpty: .init(
    english: "No app assignments yet.",
    simplifiedChinese: "还没有应用归组。"
  ),
  .clipboardAssignedGroup: .init(
    english: "Assigned Group",
    simplifiedChinese: "所属分组"
  ),
  .clipboardCreateGroup: .init(
    english: "New Group",
    simplifiedChinese: "新建分组"
  ),
  .clipboardNewGroupName: .init(
    english: "Group name",
    simplifiedChinese: "分组名称"
  ),
  .clipboardCreate: .init(
    english: "Create",
    simplifiedChinese: "创建"
  ),
  .clipboardCrossGroupFallback: .init(
    english: "Allow as cross-group fallback",
    simplifiedChinese: "允许跨组回退粘贴"
  ),
  .clipboardCrossGroupFallbackHint: .init(
    english:
      "When enabled, this group is used only after the focused app's own group has no pending item.",
    simplifiedChinese: "启用后，只有当前应用所属分组没有待粘贴条目时，才会回退使用这个分组。"
  ),
  .clipboardDefaultGroup: .init(
    english: "Unassigned / Default Fallback",
    simplifiedChinese: "未分组 / 默认回退"
  ),
  .clipboardHistory: .init(
    english: "Items",
    simplifiedChinese: "条目"
  ),
  .clipboardRouting: .init(
    english: "Groups",
    simplifiedChinese: "分组"
  ),
  .clipboardHistoryRemainingOnly: .init(
    english: "Remaining",
    simplifiedChinese: "剩余"
  ),
  .clipboardHistoryAllItems: .init(
    english: "All",
    simplifiedChinese: "全部"
  ),
  .clipboardMergeSimilar: .init(
    english: "Merge similar text",
    simplifiedChinese: "合并相似文本"
  ),
  .clipboardMergeSimilarHint: .init(
    english:
      "When enabled, nearby text variants with small spacing, case, or punctuation differences are "
      + "shown as one history entry.",
    simplifiedChinese: "开启后，只有大小写、空格或标点差异的文本会合并显示为一条历史记录。"
  ),
  .clipboardMergedSimilarBadge: .init(
    english: "Similar",
    simplifiedChinese: "相似合并"
  ),
  .clipboardEmpty: .init(
    english: "No records yet.",
    simplifiedChinese: "暂无记录。"
  ),
  .clipboardNoResults: .init(
    english: "No records match this search.",
    simplifiedChinese: "没有匹配当前搜索的记录。"
  ),
  .clipboardSelectItem: .init(
    english: "Select an item to preview it, run a workflow, or paste it.",
    simplifiedChinese: "选择一个条目即可预览、运行工作流或直接粘贴。"
  ),
  .recordReplayWithWorkflow: .init(
    english: "Replay with Workflow",
    simplifiedChinese: "用工作流重放"
  ),
  .clipboardReplaceWithWorkflow: .init(
    english: "Replace with Workflow",
    simplifiedChinese: "用工作流覆盖"
  ),
  .recordUseItem: .init(
    english: "Paste",
    simplifiedChinese: "粘贴"
  ),
  .clipboardDeleteItem: .init(
    english: "Delete",
    simplifiedChinese: "删除"
  ),
  .clipboardPinItem: .init(
    english: "Pin",
    simplifiedChinese: "置顶"
  ),
  .clipboardUnpinItem: .init(
    english: "Unpin",
    simplifiedChinese: "取消置顶"
  ),
  .clipboardPinnedBadge: .init(
    english: "Pinned",
    simplifiedChinese: "已置顶"
  ),
  .clipboardPinnedOnly: .init(
    english: "Show pinned items only",
    simplifiedChinese: "仅显示置顶条目"
  ),
  .clipboardSearch: .init(
    english: "Search records",
    simplifiedChinese: "搜索记录"
  ),
  .clipboardClearSearch: .init(
    english: "Clear record search",
    simplifiedChinese: "清除记录搜索"
  ),
  .clipboardNoPinnedItems: .init(
    english: "No pinned records match the current filters.",
    simplifiedChinese: "没有匹配当前筛选条件的置顶记录。"
  ),
  .clipboardSection: .init(
    english: "Records section",
    simplifiedChinese: "记录页面区域"
  ),
  .clipboardAddTag: .init(
    english: "Add tag",
    simplifiedChinese: "添加标签"
  ),
  .clipboardRemoveTag: .init(
    english: "Remove tag",
    simplifiedChinese: "移除标签"
  ),
  .clipboardPasteMode: .init(
    english: "Paste mode",
    simplifiedChinese: "粘贴模式"
  ),
  .clipboardAlternatives: .init(
    english: "Related Variants",
    simplifiedChinese: "相关变体"
  ),
  .clipboardTags: .init(
    english: "Tags",
    simplifiedChinese: "标签"
  ),
  .clipboardSystemSourceFallback: .init(
    english: "System clipboard",
    simplifiedChinese: "系统剪贴板"
  ),
  .clipboardWorkflowSourceFallback: .init(
    english: "Rill workflow",
    simplifiedChinese: "Rill 工作流"
  ),
  .settingsLanguage: .init(
    english: "Language",
    simplifiedChinese: "界面语言"
  ),
  .settingsLanguageDescription: .init(
    english: "Switch the app interface between English and Simplified Chinese.",
    simplifiedChinese: "在英文和简体中文之间切换应用界面。"
  ),
  .settingsRecordPanel: .init(
    english: "Clipboard Capture & History",
    simplifiedChinese: "剪贴板捕获与历史"
  ),
  .settingsRecordPanelDescription: .init(
    english:
      "Turning capture off stops new automatic captures and the global panel shortcut. Existing "
      + "history remains available from the main window.",
    simplifiedChinese: "关闭捕获后不会再自动收集新内容，全局面板快捷键也会停用；现有历史仍可从主窗口访问。"
  ),
  .settingsClipboardCaptureEnabled: .init(
    english: "Automatically Capture Clipboard",
    simplifiedChinese: "自动捕获剪贴板"
  ),
  .settingsClipboardCaptureEnabledDescription: .init(
    english:
      "When enabled, external clipboard changes are added to Rill history and the global panel "
      + "shortcut is active.",
    simplifiedChinese: "开启后，外部剪贴板变化会自动加入 Rill 历史，全局面板快捷键也会生效。"
  ),
  .clipboardCaptureDisabledTitle: .init(
    english: "Automatic clipboard capture is off",
    simplifiedChinese: "剪贴板自动捕获已关闭"
  ),
  .clipboardCaptureDisabledDescription: .init(
    english:
      "Existing history remains available in the main window. New external copies are not captured, "
      + "and the global panel shortcut is off.",
    simplifiedChinese: "现有历史仍可从主窗口访问；新的外部复制内容不会被捕获，全局面板快捷键也已停用。"
  ),
  .clipboardCaptureEnable: .init(
    english: "Turn On Capture",
    simplifiedChinese: "开启捕获"
  ),
  .recordPanelHotkeyRecord: .init(
    english: "Record Shortcut",
    simplifiedChinese: "录制快捷键"
  ),
  .recordPanelHotkeyRecording: .init(
    english: "Press shortcut...",
    simplifiedChinese: "请按下快捷键…"
  ),
  .recordPanelHotkeyReset: .init(
    english: "Use Double Command",
    simplifiedChinese: "改回双击 Command"
  ),
  .recordPanelHotkeyHint: .init(
    english: "Use a non-system shortcut with at least two modifiers. Press Esc to cancel.",
    simplifiedChinese: "请使用至少包含两个修饰键且不与系统冲突的快捷键。按 Esc 取消。"
  ),
  .recordPanelHotkeyDefault: .init(
    english: "Double Command",
    simplifiedChinese: "双击 Command"
  ),
  .recordPanelHotkeyRecorderLabel: .init(
    english: "Hotkey recorder",
    simplifiedChinese: "快捷键录制器"
  ),
  .settingsStackDelivery: .init(
    english: "Record Delivery",
    simplifiedChinese: "记录投递"
  ),
  .settingsStackDescription: .init(
    english:
      "Workflow output and external system clipboard copies flow into record collections. Capture "
      + "and delivery routes can target multiple collections, while each collection controls "
      + "selection and consumption independently.",
    simplifiedChinese:
      "工作流输出和外部系统剪切板内容都会进入记录集。采集与投递路由可关联多个记录集，每个记录集独立控制选取与消费策略。"
  ),
  .settingsStackStatus: .init(
    english: "Current routed item count:",
    simplifiedChinese: "当前路由条目数："
  ),
  .settingsDiagnostics: .init(
    english: "Diagnostics",
    simplifiedChinese: "诊断信息"
  ),
  .settingsDiagnosticsDescription: .init(
    english: "Recent persisted runtime diagnostics from the local repository.",
    simplifiedChinese: "这里显示最近持久化到本地仓库的运行诊断事件。"
  ),
  .refreshDiagnostics: .init(
    english: "Refresh Diagnostics",
    simplifiedChinese: "刷新诊断"
  ),
  .diagnosticsLoading: .init(
    english: "Loading diagnostics…",
    simplifiedChinese: "正在加载诊断信息…"
  ),
  .diagnosticsLoadFailed: .init(
    english: "Diagnostics could not be loaded from local storage.",
    simplifiedChinese: "无法从本地存储加载诊断信息。"
  ),
  .diagnosticsRetry: .init(
    english: "Retry",
    simplifiedChinese: "重试"
  ),
  .diagnosticsEmpty: .init(
    english: "No persisted diagnostics yet.",
    simplifiedChinese: "还没有持久化诊断信息。"
  ),
  .settingsSpeechEngine: .init(
    english: "Providers & Models",
    simplifiedChinese: "提供商与模型"
  ),
  .settingsSpeechEngineDescription: .init(
    english: "Configure shared recognition, language-model, and speech-synthesis providers. Workflow-specific behavior and voices stay in each workflow.",
    simplifiedChinese: "配置共享的语音识别、大模型与语音合成提供商；工作流行为和音色仍由各工作流单独保存。"
  ),
  .settingsBuiltinPushToTalk: .init(
    english: "Built-in Fn Workflows",
    simplifiedChinese: "内置 Fn 工作流"
  ),
  .settingsBuiltinPushToTalkDescription: .init(
    english:
      "Choose whether the built-in Fn hold workflows type directly into the current app or save "
      + "into the reserved Speech Recognition clipboard group.",
    simplifiedChinese: "选择内置 Fn 按住工作流是直接输入到当前应用，还是保存到保留的语音识别剪贴板组。"
  ),
  .settingsLocalSpeech: .init(
    english: "Local Speech",
    simplifiedChinese: "本地语音识别"
  ),
  .settingsLocalSpeechDescription: .init(
    english: "Runs on device and keeps audio local. Pick a model below and Rill downloads it "
      + "automatically.",
    simplifiedChinese: "在本机上运行，音频不会离开设备。你只需要在下面选择模型，Rill 会自动下载。"
  ),
  .localSpeechArchitectureUnsupported: .init(
    english:
      "This build does not include a compatible MLX speech worker. Use a supported Rill build.",
    simplifiedChinese: "此构建未包含兼容的 MLX 语音 worker，请使用受支持的 Rill 构建。"
  ),
  .localSpeechTrustMaterialUnavailable: .init(
    english:
      "This build does not include reviewed local model trust material. Local speech cannot prepare or download a model.",
    simplifiedChinese: "此构建未包含受审的本地模型信任材料，无法准备或下载本地语音模型。"
  ),
  .localSpeechModel: .init(
    english: "Final Transcription Model",
    simplifiedChinese: "最终转写模型"
  ),
  .localSpeechDownloadedModels: .init(
    english: "Downloaded Models",
    simplifiedChinese: "已下载模型"
  ),
  .localSpeechDownloaded: .init(
    english: "Downloaded",
    simplifiedChinese: "已下载"
  ),
  .localSpeechNotDownloaded: .init(
    english: "Not downloaded",
    simplifiedChinese: "未下载"
  ),
  .legacyWhisperKitCustomModel: .init(
    english: "Custom Model ID",
    simplifiedChinese: "自定义模型 ID"
  ),
  .legacyWhisperKitCustomModelHint: .init(
    english: "Only release-pinned MLX models are accepted.",
    simplifiedChinese: "仅接受由当前版本固定并校验的 MLX 模型。"
  ),
  .legacyWhisperKitCustomModelRequired: .init(
    english: "Choose a supported local model first.",
    simplifiedChinese: "请先选择受支持的本地模型。"
  ),
  .legacyWhisperKitModelRepo: .init(
    english: "Model Repository",
    simplifiedChinese: "模型仓库"
  ),
  .legacyWhisperKitModelToken: .init(
    english: "Access Token",
    simplifiedChinese: "访问令牌"
  ),
  .legacyWhisperKitModelFolder: .init(
    english: "Model Folder",
    simplifiedChinese: "模型目录"
  ),
  .legacyWhisperKitLanguage: .init(
    english: "Default Language",
    simplifiedChinese: "默认语言"
  ),
  .localSpeechAutoDownload: .init(
    english: "Download model automatically when needed",
    simplifiedChinese: "在需要时自动下载模型"
  ),
  .localSpeechPrewarm: .init(
    english: "Load model before the first recording",
    simplifiedChinese: "首次录音前加载模型"
  ),
  .localSpeechPrepare: .init(
    english: "Prepare Local Model",
    simplifiedChinese: "准备本地模型"
  ),
  .localSpeechPreparing: .init(
    english: "Downloading local model...",
    simplifiedChinese: "正在下载本地模型..."
  ),
  .localSpeechValidating: .init(
    english: "Download complete. Verifying model files...",
    simplifiedChinese: "下载完成，正在校验模型文件..."
  ),
  .localSpeechFinalizing: .init(
    english: "Loading the model and compiling first-run Metal resources...",
    simplifiedChinese: "正在加载模型并编译首次运行所需的 Metal 资源..."
  ),
  .localSpeechCancelPreparation: .init(
    english: "Cancel",
    simplifiedChinese: "取消"
  ),
  .localSpeechPreparationReady: .init(
    english: "Selected model is ready",
    simplifiedChinese: "所选模型已就绪"
  ),
  .localSpeechReleaseMemory: .init(
    english: "Release Model Memory",
    simplifiedChinese: "释放本地模型内存"
  ),
  .localSpeechReleaseMemoryHint: .init(
    english:
      "Clears the native local-speech cache. The model stays installed and reloads on the next local recognition.",
    simplifiedChinese: "清除本地语音原生缓存；模型文件仍保留，并会在下次本地识别时重新加载。"
  ),
  .localSpeechLocalTestHint: .init(
    english:
      "Record through the selected local model and save the transcript to the Speech Recognition group.",
    simplifiedChinese: "使用所选本地模型录音，并将转写结果保存到“语音识别”分组。"
  ),
  .localSpeechPreparationHint: .init(
    english:
      "Qwen3-ASR is the approved local model for high-quality Simplified Chinese and English mixed dictation.",
    simplifiedChinese: "Qwen3-ASR 是当前已批准的本地模型，适合高质量简体中文与英文混合听写。"
  ),
  .localSpeechTrustedCatalogHint: .init(
    english:
      "Choose a release-pinned local model. Rill verifies downloaded artifacts before on-device use; custom model IDs are not accepted.",
    simplifiedChinese: "请选择由当前版本固定的本地模型；Rill 会在本机使用前校验下载产物，当前不接受自定义模型 ID。"
  ),
  .settingsWorkflows: .init(
    english: "Workflows",
    simplifiedChinese: "工作流"
  ),
  .settingsWorkflowsDescription: .init(
    english: "Available workflows and their production pipeline configuration.",
    simplifiedChinese: "可用工作流及其生产管线配置。"
  ),
  .stackPasteRequiresAccessibility: .init(
    english: "Grant Accessibility access before delivering records.",
    simplifiedChinese: "请先授予辅助功能权限，再投递记录。"
  ),
  .diagnosticsTitle: .init(
    english: "Diagnostics",
    simplifiedChinese: "诊断"
  ),
  .diagnosticsDescription: .init(
    english: "Validate your speech setup and inspect recent runtime events.",
    simplifiedChinese: "检查语音配置是否正常，并查看最近的运行事件。"
  ),
  .diagnosticsTimeline: .init(
    english: "Runtime Timeline",
    simplifiedChinese: "运行时间线"
  ),
  .workflowsTitle: .init(
    english: "Workflows",
    simplifiedChinese: "工作流"
  ),
  .workflowsDescription: .init(
    english:
      "Create reusable voice workflows, choose how they trigger, and decide where the final text "
      + "should go.",
    simplifiedChinese: "创建可复用的语音工作流，配置触发方式，并决定最终文本的去向。"
  ),
  .workflowEditor: .init(
    english: "Create or Edit Workflow",
    simplifiedChinese: "创建或编辑工作流"
  ),
  .workflowLibrary: .init(
    english: "Workflow Library",
    simplifiedChinese: "工作流库"
  ),
  .workflowNew: .init(
    english: "New Workflow",
    simplifiedChinese: "新建工作流"
  ),
  .workflowSave: .init(
    english: "Save Workflow",
    simplifiedChinese: "保存工作流"
  ),
  .workflowReset: .init(
    english: "Reset",
    simplifiedChinese: "重置"
  ),
  .workflowNameField: .init(
    english: "Workflow Name",
    simplifiedChinese: "工作流名称"
  ),
  .workflowRecognizer: .init(
    english: "Speech Engine",
    simplifiedChinese: "语音引擎"
  ),
  .workflowDestination: .init(
    english: "Output Destination",
    simplifiedChinese: "输出位置"
  ),
  .workflowTrigger: .init(
    english: "Trigger",
    simplifiedChinese: "触发方式"
  ),
  .workflowSourceCollection: .init(
    english: "Source Collection",
    simplifiedChinese: "来源记录集"
  ),
  .workflowTargetGroup: .init(
    english: "Target Group",
    simplifiedChinese: "目标分组"
  ),
  .workflowGroupAction: .init(
    english: "Group Action",
    simplifiedChinese: "组动作"
  ),
  .workflowMoveStepUp: .init(
    english: "Move step up",
    simplifiedChinese: "上移步骤"
  ),
  .workflowMoveStepDown: .init(
    english: "Move step down",
    simplifiedChinese: "下移步骤"
  ),
  .workflowRemoveStep: .init(
    english: "Remove step",
    simplifiedChinese: "移除步骤"
  ),
  .workflowLocalModel: .init(
    english: "Local Model Override",
    simplifiedChinese: "本地模型覆盖"
  ),
  .workflowGlobalModelDefault: .init(
    english: "Use default enabled model",
    simplifiedChinese: "使用默认已启用模型"
  ),
  .workflowNormalizeWhitespace: .init(
    english: "Clean up spacing before delivery",
    simplifiedChinese: "输出前整理空格与换行"
  ),
  .workflowExcludeFromCapture: .init(
    english: "Exclude clipboard output from workflow capture",
    simplifiedChinese: "让剪贴板输出不被工作流再次捕获"
  ),
  .workflowExcludeFromCaptureHint: .init(
    english: "Turn this off if you want clipboard-based workflow chaining.",
    simplifiedChinese: "关闭后，基于剪贴板的工作流链式触发会继续生效。"
  ),
  .workflowBuiltIn: .init(
    english: "Built-in",
    simplifiedChinese: "内置"
  ),
  .workflowCustom: .init(
    english: "Custom",
    simplifiedChinese: "自定义"
  ),
  .builtinPushToTalkOutputMode: .init(
    english: "Output",
    simplifiedChinese: "输出方式"
  ),
  .workflowSelected: .init(
    english: "Current",
    simplifiedChinese: "当前"
  ),
  .workflowEdit: .init(
    english: "Edit",
    simplifiedChinese: "编辑"
  ),
  .workflowDelete: .init(
    english: "Delete",
    simplifiedChinese: "删除"
  ),
  .workflowDeleteConfirmationTitle: .init(
    english: "Delete this workflow?",
    simplifiedChinese: "删除这个工作流？"
  ),
  .workflowDeleteConfirmationDetail: .init(
    english: "This permanently removes the workflow's TOML file. This action can't be undone.",
    simplifiedChinese: "这会永久删除该工作流的 TOML 文件，且无法撤销。"
  ),
  .workflowUse: .init(
    english: "Use",
    simplifiedChinese: "使用"
  ),
  .workflowEnabled: .init(
    english: "Enabled",
    simplifiedChinese: "启用"
  ),
  .workflowCustomEmpty: .init(
    english: "No custom workflows yet. Create one above to get started.",
    simplifiedChinese: "还没有自定义工作流。先在上方创建一个。"
  ),
  .vocabularyRule: .init(
    english: "Vocabulary rule",
    simplifiedChinese: "词汇规则"
  ),
  .vocabularyDeleteRule: .init(
    english: "Delete vocabulary rule",
    simplifiedChinese: "删除词汇规则"
  ),
]
