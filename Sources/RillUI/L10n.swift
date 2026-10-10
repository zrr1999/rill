import Foundation
import RillCore

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
    case menuClipboardOn
    case menuClipboardOff
    case menuClipboardStarting
    case menuClipboardIgnorePreparing
    case menuClipboardIgnoringNext
    case menuClipboardSettings
    case menuClipboardCaptureActive
    case menuClipboardCaptureOff
    case menuClipboardCaptureTurningOn
    case menuClipboardIgnoreNextArming
    case menuClipboardIgnoreNextPending
    case menuCopyLastResult
    case menuIgnoreNextExternalCopy
    case menuHoldToTalkHint
    case menuLocalEngine
    case menuLongRecording
    case menuLongRecordingToggle
    case menuLongRecordingToggleOff
    case menuManageEngineSettings
    case menuNoLongRecordingWorkflows
    case menuNoManualWorkflows
    case menuNoTextStyleWorkflows
    case menuOpenMainWindow
    case menuOpenDrafts
    case menuManualWorkflows
    case menuPasteIntoApp
    case menuDeliverNextRecord
    case menuTurnOffClipboardCapture
    case menuQuit
    case menuRecentResults
    case menuRecordingMode
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
    case menuToggleRecordingHint
    case menuVoiceInput
    case menuVoiceInputSettings
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
    case settingsCorpusRecordingArchive
    case settingsCorpusRecordingArchiveClear
    case settingsCorpusRecordingArchiveClearConfirmation
    case settingsCorpusRecordingArchiveClearConfirmationDetail
    case settingsCorpusRecordingArchiveDescription
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

  public static func string(_ key: Key, language: AppLanguage) -> String {
    catalogString("general.\(key.rawValue)", language: language)
  }

  public static func localSpeechPreparationFailure(
    _ stage: LocalSpeechPreparationFailure.Stage
  ) -> LocalizedStringResource {
    switch stage {
    case .architectureUnsupported:
      return L10n.resource("L10n.Local.speech.preparation.is.unavailable.because.this.build.does.not.include.a")
    case .trustMaterialUnavailable:
      return L10n.resource("L10n.This.build.does.not.include.reviewed.local.model.trust.material.so.local")
    case .trustRoot:
      return L10n.resource("L10n.Local.speech.preparation.stopped.because.the.model.identity.could.not.be.verified")
    case .resolution:
      return L10n.resource("L10n.Local.speech.preparation.could.not.obtain.the.selected.model")
    case .integrity:
      return L10n.resource("L10n.Local.speech.preparation.stopped.because.the.model.failed.integrity.verification")
    case .tokenizer:
      return L10n.resource("L10n.Local.speech.preparation.stopped.because.the.tokenizer.could.not.be.verified")
    case .runtime:
      return L10n.resource("L10n.Local.speech.preparation.could.not.load.the.selected.model")
    case .generic:
      return L10n.resource("L10n.Local.speech.preparation.failed.Try.again.from.Speech.settings")
    }
  }

  public static func itemCount(_ count: Int, language: AppLanguage) -> String {
    L10n.pluralString("count.items", language: language, count)
  }

  public static func voiceFailureSummary(message: String, language: AppLanguage) -> String {
    return string(.voiceFailureGenericSummary, language: language)
  }

  public static func menuClipboardReadyStatus(_ count: Int, language: AppLanguage) -> String {
    "\(string(.menuStatusClipboardReady, language: language)): \(itemCount(count, language: language))"
  }

  static func voiceTextStyleTitle(_ style: VoiceTextStyle, language: AppLanguage) -> String {
    switch style {
    case .rawInput: return catalogString("voiceTextStyleTitle.rawInput", language: language)
    case .cleanInput: return catalogString("voiceTextStyleTitle.cleanInput", language: language)
    case .smartCleanup: return catalogString("voiceTextStyleTitle.smartCleanup", language: language)
    case .formalWriting: return catalogString("voiceTextStyleTitle.formalWriting", language: language)
    case .translateInput: return catalogString("voiceTextStyleTitle.translateInput", language: language)
    case .commandMode: return catalogString("voiceTextStyleTitle.commandMode", language: language)
    case .custom: return catalogString("voiceTextStyleTitle.custom", language: language)
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
    switch style {
    case .rawInput: return catalogString("voiceTextStyleDescription.rawInput", language: language)
    case .cleanInput: return catalogString("voiceTextStyleDescription.cleanInput", language: language)
    case .smartCleanup: return catalogString("voiceTextStyleDescription.smartCleanup", language: language)
    case .formalWriting: return catalogString("voiceTextStyleDescription.formalWriting", language: language)
    case .translateInput: return catalogString("voiceTextStyleDescription.translateInput", language: language)
    case .commandMode: return catalogString("voiceTextStyleDescription.commandMode", language: language)
    case .custom: return catalogString("voiceTextStyleDescription.custom", language: language)
    }
  }

  public static func vocabularyRuleKind(_ kind: VocabularyRuleKind, language: AppLanguage) -> String {
    switch kind {
    case .hotword: return catalogString("vocabularyRuleKind.hotword", language: language)
    case .mapping: return catalogString("vocabularyRuleKind.mapping", language: language)
    }
  }

  public static func vocabularyMatchMode(_ mode: VocabularyMatchMode, language: AppLanguage)
    -> String
  {
    switch mode {
    case .exactPhrase: return catalogString("vocabularyMatchMode.exactPhrase", language: language)
    case .wordBoundary: return catalogString("vocabularyMatchMode.wordBoundary", language: language)
    case .regex: return catalogString("vocabularyMatchMode.regex", language: language)
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
    catalogString("privacy.\(key.rawValue)", language: language)
  }
  static func privacySettingsHistoryPreviewMode(
    _ mode: PrivacyHistoryPreviewMode, language: AppLanguage
  ) -> String {
    switch mode {
    case .full: return L10n.catalogString("L10n.Full.previews", language: language)
    case .restricted: return L10n.catalogString("L10n.Restricted.previews", language: language)
    case .disabled: return L10n.catalogString("L10n.Disabled", language: language)
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

  static func historySettingsText(
    _ key: HistorySettingsTextKey,
    language: AppLanguage
  ) -> String {
    catalogString("historySettings.\(key.rawValue)", language: language)
  }

  static func historyRetentionPeriod(
    _ period: HistoryRetentionPeriod,
    language: AppLanguage
  ) -> String {
    switch period {
    case .oneDay: return catalogString("historyRetentionPeriod.oneDay", language: language)
    case .oneWeek: return catalogString("historyRetentionPeriod.oneWeek", language: language)
    case .thirtyDays: return catalogString("historyRetentionPeriod.thirtyDays", language: language)
    case .oneYear: return catalogString("historyRetentionPeriod.oneYear", language: language)
    case .forever: return catalogString("historyRetentionPeriod.forever", language: language)
    }
  }

  static func historyMaintenanceResult(
    removedCount: Int,
    preservedActiveRecordCount: Int,
    language: AppLanguage
  ) -> String {
    L10n.resource(
      "history.maintenance.result",
      defaultValue: "Removed \(String(removedCount)) local record(s); preserved \(String(preservedActiveRecordCount)) active record(s)."
    ).string(for: language)
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
    if count == 0 { return catalogString("count.routeEmpty", language: language) }
    return resource("count.pending", defaultValue: "\(String(count)) item(s) pending").string(for: language)
  }

  public static func recordCountSummary(_ count: Int, language: AppLanguage) -> String {
    L10n.resource("count.recordSummary", defaultValue: "\(String(count)) item(s)").string(for: language)
  }

  public static func permissionState(_ state: PermissionState, language: AppLanguage) -> String {
    switch state {
    case .granted: return catalogString("permissionState.granted", language: language)
    case .denied: return catalogString("permissionState.denied", language: language)
    case .unknown: return catalogString("permissionState.unknown", language: language)
    }
  }

  public static func workflowName(_ workflow: WorkflowPresentation, language: AppLanguage) -> String {
    workflowNameResource(workflow).string(for: language)
  }

  static func workflowNameResource(_ workflow: WorkflowPresentation) -> LocalizedStringResource {
    guard let titleKey = workflow.titleKey else {
      return resource("workflowName.custom", defaultValue: "\(workflow.fallbackName)")
    }
    return resource("workflowName.\(titleKey.rawValue)")
  }

  public static func candidateModeSummary(
    mode: ResolutionMode,
    timeoutSeconds: Int,
    language: AppLanguage
  ) -> String {
    L10n.resource("candidate.modeSummary", defaultValue: "Mode: \(resolutionMode(mode, language: language)) · Timeout: \(String(timeoutSeconds))s").string(
      for: language)
  }

  public static func resolutionMode(_ mode: ResolutionMode, language: AppLanguage) -> String {
    switch mode {
    case .blocking: return catalogString("resolutionMode.blocking", language: language)
    case .nonBlocking: return catalogString("resolutionMode.nonBlocking", language: language)
    case .off: return catalogString("resolutionMode.off", language: language)
    }
  }

  public static func spanSummary(lowerBound: Int, upperBound: Int, language: AppLanguage) -> String {
    L10n.resource("candidate.span", defaultValue: "Span \(String(lowerBound))-\(String(upperBound))").string(for: language)
  }

  public static func candidateSource(_ source: CandidateSource, language: AppLanguage) -> String {
    return switch source {
    case .asr: "ASR"
    case .llm: "LLM"
    case .heuristic: L10n.resource("L10n.HEURISTIC").string(for: language)
    case .user: L10n.resource("L10n.USER").string(for: language)
    }
  }

  public static func subsystem(_ subsystem: SubsystemTag, language: AppLanguage) -> String {
    subsystemResource(subsystem).string(for: language)
  }

  static func subsystemResource(_ subsystem: SubsystemTag) -> LocalizedStringResource {
    switch subsystem {
    case .session: return resource("subsystem.session")
    case .records: return resource("subsystem.records")
    case .systemClipboard: return resource("subsystem.systemClipboard")
    case .resolver: return resource("subsystem.resolver")
    case .platform: return resource("subsystem.platform")
    case .providers: return resource("subsystem.providers")
    case .ui: return resource("subsystem.ui")
    }
  }

  public static func workflowDetail(_ workflow: WorkflowDefinition, language: AppLanguage) -> String {
    VoiceWorkflowPresentation(workflow: workflow).detail(language: language)
  }

  public static func workflowConflict(
    trigger: TriggerBinding,
    names: [String],
    language: AppLanguage
  ) -> String {
    resource(
      "workflowConflict", defaultValue: "Conflict: \(workflowTrigger(trigger, language: language)) is also enabled for \(names.joined(separator: ", "))."
    ).string(for: language)
  }

  public static func workflowEnableConflict(
    trigger: TriggerBinding,
    names: [String],
    language: AppLanguage
  ) -> String {
    resource(
      "workflowEnableConflict",
      defaultValue: "Cannot enable this workflow. \(workflowTrigger(trigger, language: language)) is already in use by \(names.joined(separator: ", "))."
    ).string(for: language)
  }

  public static func diagnosticLevel(_ level: DiagnosticLevel, language: AppLanguage) -> String {
    switch level {
    case .debug: return catalogString("diagnosticLevel.debug", language: language)
    case .info: return catalogString("diagnosticLevel.info", language: language)
    case .warning: return catalogString("diagnosticLevel.warning", language: language)
    case .error: return catalogString("diagnosticLevel.error", language: language)
    }
  }

  public static func workflowTrigger(
    _ trigger: TriggerBinding,
    metadata: [String: String] = [:],
    language: AppLanguage
  ) -> String {
    return switch trigger {
    case .manual: L10n.resource("L10n.Manual").string(for: language)
    case .menuBar: L10n.resource("L10n.Menu.Bar").string(for: language)
    case .hotkey: hotkeyGesture(metadata["trigger.gesture"], language: language)
    case .wakeWord: L10n.resource("L10n.Wake.Word").string(for: language)
    }
  }

  private static func hotkeyGesture(_ value: String?, language: AppLanguage) -> String {
    switch value.flatMap(PushToTalkGesture.init(rawValue:)) {
    case .fnHold: resource("hotkey.holdFn").string(for: language)
    case .controlOptionShiftSpace: "⌃⌥⇧Space"
    case nil: value ?? resource("hotkey.generic").string(for: language)
    }
  }

  public static func recognizerName(_ id: String, language: AppLanguage) -> String {
    return switch id {
    case "local-speech": L10n.resource("L10n.Local.Speech").string(for: language)
    case "sherpa-onnx.local": L10n.resource("L10n.Local.Speech").string(for: language)
    case "sherpa-onnx.streaming": L10n.resource("L10n.Local.Streaming.Speech").string(for: language)
    default: id
    }
  }

  public static func actionName(_ id: String, language: AppLanguage) -> String {
    switch id {
    case "focused-application.insert": return L10n.catalogString("L10n.Paste.into.App", language: language)
    case "system-clipboard.copy": return L10n.catalogString("L10n.Copy.to.Clipboard", language: language)
    case "record.store": return L10n.catalogString("L10n.Save.to.Queue", language: language)
    case ExternalOutputActionID.webhookPost: return "Webhook"
    case ExternalOutputActionID.shortcutsRun:
      return L10n.catalogString("L10n.Run.Shortcut", language: language)
    case ExternalOutputActionID.markdownAppend:
      return L10n.catalogString("L10n.Append.to.Markdown", language: language)
    default: return id
    }
  }

  public static func editorRecognizer(
    _ recognizer: WorkflowEditorDraft.RecognizerChoice,
    language: AppLanguage
  ) -> String {
    switch recognizer {
    case .automatic: return catalogString("editorRecognizer.automatic", language: language)
    case .localSpeech: return catalogString("editorRecognizer.localSpeech", language: language)
    }
  }

  public static func editorDestination(
    _ destination: WorkflowEditorDraft.DestinationChoice,
    language: AppLanguage
  ) -> String {
    switch destination {
    case .pasteIntoApp: return L10n.catalogString("L10n.Paste.into.Active.App", language: language)
    case .copyToClipboard: return L10n.catalogString("L10n.Copy.to.Clipboard", language: language)
    case .saveToQueue: return L10n.catalogString("L10n.Save.to.Clipboard.Queue", language: language)
    case .speakOnly: return L10n.catalogString("L10n.Speak.Only", language: language)
    case .sendToWebhook: return "Webhook"
    case .runShortcut: return L10n.catalogString("L10n.Run.macOS.Shortcut", language: language)
    case .appendToMarkdown:
      return L10n.catalogString("L10n.Append.to.Obsidian.Markdown", language: language)
    }
  }

  public static func speechEngine(_ engine: PreferredSpeechEngine, language: AppLanguage) -> String {
    switch engine {
    case .local: return catalogString("speechEngine.local", language: language)
    }
  }

  public static func localSpeechEngine(
    _ engine: LocalSpeechEngine,
    language: AppLanguage
  ) -> String {
    switch engine {
    case .sherpaOnnx: return catalogString("localSpeechEngine.sherpaOnnx", language: language)
    case .mlxAudioSwift: return catalogString("localSpeechEngine.mlxAudioSwift", language: language)
    }
  }

  public static func localSpeechModelOption(
    _ option: LegacyWhisperModelOption,
    language: AppLanguage
  ) -> String {
    switch option {
    case .automatic: L10n.resource("L10n.Automatic").string(for: language)
    case .tiny: L10n.resource("L10n.Fast.Tiny").string(for: language)
    case .distilLargeV3Compact: L10n.resource("L10n.English.Only.Distilled.Large.v3").string(for: language)
    case .largeV320240930Compact: L10n.resource("L10n.Best.Quality.Large.v3").string(for: language)
    case .custom: L10n.resource("L10n.Custom").string(for: language)
    }
  }

  public static func builtinPushToTalkOutputMode(
    _ mode: BuiltinPushToTalkOutputMode,
    language: AppLanguage
  ) -> String {
    switch mode {
    case .pasteIntoApp: return catalogString("builtinPushToTalkOutputMode.pasteIntoApp", language: language)
    case .saveToVoiceGroup: return catalogString("builtinPushToTalkOutputMode.saveToVoiceGroup", language: language)
    }
  }
}
