import Foundation
import RillCore

extension AppModel {
  func handleLanguageChange(from oldValue: AppLanguage) {
    guard oldValue != language else { return }
    persistLanguagePreference()
    syncLiveSubtitlePanel()
    refreshUnavailableStoredSettingsDomainErrors()
  }

  func handleClipboardCaptureEnabledChange(from oldValue: Bool) {
    guard oldValue != systemClipboardCaptureEnabled else { return }
    clipboardCapturePreferenceRevision &+= 1
    persistClipboardCaptureEnabledPreference()
    publishClipboardCapturePreferenceToRuntime()
  }

  func applyResolvedClipboardCapturePreference(enabled: Bool) {
    guard systemClipboardCaptureEnabled == enabled else {
      systemClipboardCaptureEnabled = enabled
      return
    }
    clipboardCapturePreferenceRevision &+= 1
    publishClipboardCapturePreferenceToRuntime()
  }

  private func publishClipboardCapturePreferenceToRuntime() {
    setSystemClipboardCaptureEnabledAction(
      systemClipboardCaptureEnabled,
      clipboardCapturePreferenceRevision
    )
  }

  func handleRecordPanelHotkeyChange(from oldValue: HotkeyBindingDescriptor) {
    guard oldValue != recordPanelHotkeyBinding else { return }
    persistRecordPanelHotkeyPreference()
    updateRecordPanelHotkeyAction(recordPanelHotkeyBinding)
  }

  func handlePreferredSpeechEngineChange(from oldValue: PreferredSpeechEngine) {
    guard oldValue != preferredSpeechEngine else { return }
    invalidateWorkflowExplanation()
    persistPreferredSpeechEnginePreference()
    guard !isRestoringSettings else { return }
    setLocalSpeechRuntimeEnabledAction(preferredSpeechEngine == .local)
    if isLoadingSettings {
      shouldPrepareLocalSpeechModelAfterInitialSettingsLoad = preferredSpeechEngine == .local
      return
    }
    if preferredSpeechEngine == .local {
      prepareLocalSpeechModel()
    } else {
      // A cloud selection owns no local-model readiness state. Retire
      // any in-flight local load so an old completion cannot publish
      // ready after the route has changed.
      resetLocalSpeechPreparationStatus()
    }
  }

  func handleTTSModelIdentifierChange(from oldValue: String) {
    guard oldValue != ttsModelIdentifier else { return }
    persistStringSetting(ttsModelIdentifier, for: .ttsModel)
    selectTTSModelAction(ttsModelIdentifier)
    ttsResourceState =
      downloadedTTSModelIdentifiers.contains(ttsModelIdentifier)
      ? .ready
      : .notInstalled
  }

  func handleBuiltinPushToTalkOutputModeChange(from oldValue: BuiltinPushToTalkOutputMode) {
    guard oldValue != builtinPushToTalkOutputMode else { return }
    invalidateWorkflowExplanation()
    persistBuiltinPushToTalkOutputModePreference()
  }

  func handleLongRecordingModeChange(from oldValue: Bool) {
    guard oldValue != longRecordingModeEnabled else { return }
    persistLongRecordingModePreference()
  }

  func handleRecordingDurationLimitChange(from oldValue: RecordingDurationLimit) {
    guard oldValue != recordingDurationLimit else { return }
    persistRecordingDurationLimitPreference()
  }





  func handleLocalSpeechModelChange(from oldValue: String) {
    if oldValue != localSpeechModel, !isRestoringSettings {
      localSpeechModelMutationGeneration &+= 1
    }
    guard oldValue != localSpeechModel else { return }
    publishCurrentLocalSpeechSettingsToRuntime()
    resetLocalSpeechPreparationStatus()
    synchronizeWakeWordResourceWithLocalSpeechModel()
    persistStringSetting(localSpeechModel, for: .localSpeechModel)
  }











  func handleLocalSpeechPrewarmChange(from oldValue: Bool) {
    guard oldValue != localSpeechPrewarm else { return }
    publishCurrentLocalSpeechSettingsToRuntime()
    resetLocalSpeechPreparationStatus()
    persistStringSetting(localSpeechPrewarm ? "true" : "false", for: .localSpeechPrewarm)
  }

  func handleEnabledSpeechModelIDsChange(from oldValue: Set<String>) {
    guard oldValue != enabledSpeechModelIDs else { return }
    markSettingModifiedDuringInitialLoad(.enabledSpeechModels)
    if !residentSpeechModelIDs.isSubset(of: enabledSpeechModelIDs) {
      residentSpeechModelIDs.formIntersection(enabledSpeechModelIDs)
    }
    residentSpeechBudgetConfirmation = nil
    publishCurrentLocalSpeechSettingsToRuntime()
    persistSpeechModelIDSet(enabledSpeechModelIDs, for: .enabledSpeechModels)
  }

  func handleResidentSpeechModelIDsChange(from oldValue: Set<String>) {
    guard oldValue != residentSpeechModelIDs else { return }
    markSettingModifiedDuringInitialLoad(.residentSpeechModels)
    publishCurrentLocalSpeechSettingsToRuntime()
    persistSpeechModelIDSet(residentSpeechModelIDs, for: .residentSpeechModels)
    synchronizeResidentSpeechModels(from: oldValue)
  }

  func handleResidentSpeechBudgetConfirmationChange(from oldValue: String?) {
    guard oldValue != residentSpeechBudgetConfirmation else { return }
    markSettingModifiedDuringInitialLoad(.residentSpeechBudgetConfirmation)
    persistStringSetting(
      residentSpeechBudgetConfirmation ?? "",
      for: .residentSpeechBudgetConfirmation
    )
  }

  private func persistSpeechModelIDSet(
    _ modelIDs: Set<String>,
    for key: AppSettingKey
  ) {
    guard let data = try? JSONEncoder().encode(modelIDs.sorted()),
      let value = String(data: data, encoding: .utf8)
    else { return }
    persistStringSetting(value, for: key)
  }

  func handleOpenAIAPIKeyChange(from oldValue: String) {
    guard oldValue != openAIAPIKey else { return }
    openAIVerificationTask?.cancel()
    openAIVerificationTask = nil
    openAIVerificationGeneration &+= 1
    openAIVerificationFailure = nil
    openAIConfigurationVerificationState = .idle
    let previousAvailability = openAICredentialAvailability
    if !isRestoringSettings {
      openAICredentialLoadGeneration &+= 1
      openAICredentialAvailability = credentialStore == nil ? .inaccessible : .saving
    }
    if previousAvailability != openAICredentialAvailability {
      workflowLibraryChangedAction()
    }
    persistSecureCredential(
      openAIAPIKey,
      for: .openAIAPIKey,
      taskKey: .openAIAPIKey
    )
  }

  func handleOpenAIBaseURLChange(from oldValue: String) {
    handleOpenAIConfigurationStringChange(
      from: oldValue,
      value: openAIBaseURL,
      key: .openAIBaseURL
    )
  }

  func handleOpenAIModelChange(from oldValue: String) {
    handleOpenAIConfigurationStringChange(
      from: oldValue,
      value: openAIModel,
      key: .openAIModel
    )
  }

  private func handleOpenAIConfigurationStringChange(
    from oldValue: String,
    value: String,
    key: AppSettingKey
  ) {
    guard oldValue != value else { return }
    let verificationWasFailed = openAIConfigurationVerificationState == .failed
    let validityChanged: Bool
    switch key {
    case .openAIBaseURL:
      validityChanged = OpenAISettings.isValidBaseURL(oldValue)
        != OpenAISettings.isValidBaseURL(value)
    case .openAIModel:
      validityChanged = OpenAISettings.isValidModelIdentifier(oldValue)
        != OpenAISettings.isValidModelIdentifier(value)
    default:
      validityChanged = false
    }
    openAIVerificationTask?.cancel()
    openAIVerificationTask = nil
    openAIVerificationGeneration &+= 1
    openAIVerificationFailure = nil
    openAIConfigurationVerificationState = .idle
    if validityChanged || verificationWasFailed {
      workflowLibraryChangedAction()
    }
    persistStringSetting(value, for: key)
  }



}
