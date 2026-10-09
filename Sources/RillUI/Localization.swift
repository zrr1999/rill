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
  public enum InterfaceKey: String, CaseIterable, Sendable {
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
    case settingsBack
    case settingsMenuCommand
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
    catalogString("interface.\(key.rawValue)", language: language)
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
    switch category {
    case .privacy: return catalogString("settingsSaveCategory.privacy", language: language)
    case .interface: return catalogString("settingsSaveCategory.interface", language: language)
    case .systemClipboard: return catalogString("settingsSaveCategory.systemClipboard", language: language)
    case .speech: return catalogString("settingsSaveCategory.speech", language: language)
    case .input: return catalogString("settingsSaveCategory.input", language: language)
    case .vocabulary: return catalogString("settingsSaveCategory.vocabulary", language: language)
    case .workflows: return catalogString("settingsSaveCategory.workflows", language: language)
    }
  }

  public static func recordingDurationLimit(
    _ limit: RecordingDurationLimit,
    language: AppLanguage
  ) -> String {
    switch limit {
    case .twoMinutes: return catalogString("recordingDurationLimit.twoMinutes", language: language)
    case .fiveMinutes: return catalogString("recordingDurationLimit.fiveMinutes", language: language)
    case .unlimited: return catalogString("recordingDurationLimit.unlimited", language: language)
    }
  }

  public static func settingsSaveFailureDescription(
    _ summary: UnsavedSettingsSummary,
    language: AppLanguage
  ) -> String {
    let categories = summary.categories.map { settingsSaveCategory($0, language: language) }
      .joined(separator: catalogString("Localization.listSeparator", language: language))
    return pluralString("settings.saveFailure", language: language, summary.affectedChangeCount, categories)
  }

  public static func loadedRunCount(_ count: Int, language: AppLanguage) -> String {
    L10n.pluralString("count.loadedRuns", language: language, count)
  }

  public static func clipboardDeleteConfirmationTitle(
    itemCount: Int,
    language: AppLanguage
  ) -> String {
    if itemCount == 1 { return catalogString("clipboard.delete.title.one", language: language) }
    return resource("clipboard.delete.title.many", defaultValue: "Delete these \(String(itemCount)) merged records?").string(for: language)
  }

  public static func clipboardDeleteConfirmationDescription(
    itemCount: Int,
    language: AppLanguage
  ) -> String {
    if itemCount == 1 { return catalogString("clipboard.delete.description.one", language: language) }
    return resource(
      "clipboard.delete.description.many",
      defaultValue: "This permanently removes all \(String(itemCount)) saved records represented by this row. This action can't be undone."
    ).string(for: language)
  }

  public static func clipboardEntryAccessibilityValue(
    copyCount: Int,
    groupName: String,
    language: AppLanguage
  ) -> String {
    pluralString("clipboard.accessibilityValue", language: language, copyCount, groupName)
  }

  public static func clipboardEntryAccessibilityHint(
    supportsDirectPaste: Bool,
    language: AppLanguage
  ) -> String {
    switch supportsDirectPaste {
    case true: L10n.resource("Localization.Selects.this.item.Press.Return.to.paste.it").string(for: language)
    case false: L10n.resource("Localization.Selects.this.item.and.opens.its.details").string(for: language)
    }
  }

  public static func targetedAccessibilityLabel(
    _ key: InterfaceKey,
    target: String,
    language: AppLanguage
  ) -> String {
    let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTarget.isEmpty else { return text(key, language: language) }
    let separator = L10n.catalogString("Localization.labelSeparator", language: language)
    return "\(text(key, language: language))\(separator)\(trimmedTarget)"
  }
}
