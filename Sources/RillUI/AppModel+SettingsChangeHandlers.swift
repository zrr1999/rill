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
    guard oldValue != clipboardCaptureEnabled else { return }
    clipboardCapturePreferenceRevision &+= 1
    persistClipboardCaptureEnabledPreference()
    publishClipboardCapturePreferenceToRuntime()
  }

  func applyResolvedClipboardCapturePreference(enabled: Bool) {
    guard clipboardCaptureEnabled == enabled else {
      clipboardCaptureEnabled = enabled
      return
    }
    clipboardCapturePreferenceRevision &+= 1
    publishClipboardCapturePreferenceToRuntime()
  }

  private func publishClipboardCapturePreferenceToRuntime() {
    setClipboardCaptureEnabledAction(
      clipboardCaptureEnabled,
      clipboardCapturePreferenceRevision
    )
  }

  func handleClipboardPanelHotkeyChange(from oldValue: HotkeyBindingDescriptor) {
    guard oldValue != clipboardPanelHotkeyBinding else { return }
    persistClipboardPanelHotkeyPreference()
    updateClipboardPanelHotkeyAction(clipboardPanelHotkeyBinding)
  }

  func handlePreferredSpeechEngineChange(from oldValue: PreferredSpeechEngine) {
    guard oldValue != preferredSpeechEngine else { return }
    invalidateWorkflowExplanation()
    persistPreferredSpeechEnginePreference()
    applyPreferredSpeechEngineSelectionIfNeeded()
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

  func handleLegacyWhisperModelOptionChange(from oldValue: LegacyWhisperModelOption) {
    guard oldValue != localSpeechModelOption else { return }
    markSettingModifiedDuringInitialLoad(.localSpeechModel)
    if localSpeechModelOption == .custom {
      let customModel = legacyWhisperKitCustomModel.trimmingCharacters(in: .whitespacesAndNewlines)
      if localSpeechModel != customModel {
        localSpeechModel = customModel
      } else if !isRestoringSettings {
        persistStringSetting(customModel, for: .localSpeechModel)
      }
      guard !isRestoringSettings else { return }
      if isLoadingSettings {
        shouldPrepareLocalSpeechModelAfterInitialSettingsLoad = false
      }
      resetLocalSpeechPreparationStatus()
      return
    }

    let presetModel = localSpeechModelOption.modelIdentifier ?? ""
    if localSpeechModel != presetModel {
      localSpeechModel = presetModel
    } else if !isRestoringSettings {
      persistStringSetting(presetModel, for: .localSpeechModel)
    }
    guard !isRestoringSettings else { return }
    if isLoadingSettings {
      shouldPrepareLocalSpeechModelAfterInitialSettingsLoad = true
      resetLocalSpeechPreparationStatus()
      return
    }
    prepareLocalSpeechModel()
  }

  func handleLegacyWhisperCustomModelChange(from oldValue: String) {
    guard oldValue != legacyWhisperKitCustomModel else { return }
    markSettingModifiedDuringInitialLoad(.legacyWhisperKitCustomModel)
    publishCurrentLocalSpeechSettingsToRuntime()
    resetLocalSpeechPreparationStatus()
    guard localSpeechModelOption == .custom else { return }
    let customModel = legacyWhisperKitCustomModel.trimmingCharacters(in: .whitespacesAndNewlines)
    if localSpeechModel != customModel {
      localSpeechModel = customModel
    } else {
      resetLocalSpeechPreparationStatus()
    }
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

  func handleLegacyWhisperModelRepoChange(from oldValue: String) {
    markSettingModifiedDuringInitialLoad(.legacyWhisperKitModelRepo)
    handleLegacyWhisperRuntimeSettingChange(from: oldValue, value: legacyWhisperKitModelRepo)
  }

  func handleLegacyWhisperModelTokenChange(from oldValue: String) {
    markSettingModifiedDuringInitialLoad(.legacyWhisperKitModelToken)
    handleLegacyWhisperRuntimeSettingChange(from: oldValue, value: legacyWhisperKitModelToken)
  }

  func handleLegacyWhisperModelFolderChange(from oldValue: String) {
    markSettingModifiedDuringInitialLoad(.legacyWhisperKitModelFolder)
    handleLegacyWhisperRuntimeSettingChange(from: oldValue, value: legacyWhisperKitModelFolder)
  }

  func handleLegacyWhisperLanguageChange(from oldValue: String) {
    markSettingModifiedDuringInitialLoad(.legacyWhisperKitLanguage)
    handleLegacyWhisperRuntimeSettingChange(from: oldValue, value: legacyWhisperKitLanguage)
  }

  func handleLegacyWhisperDownloadIfNeededChange(from oldValue: Bool) {
    markSettingModifiedDuringInitialLoad(.legacyWhisperKitDownloadIfNeeded)
    handleLegacyWhisperRuntimeSettingChange(
      from: oldValue,
      value: legacyWhisperKitDownloadIfNeeded
    )
  }

  func handleLocalSpeechPrewarmChange(from oldValue: Bool) {
    guard oldValue != localSpeechPrewarm else { return }
    publishCurrentLocalSpeechSettingsToRuntime()
    resetLocalSpeechPreparationStatus()
    persistStringSetting(localSpeechPrewarm ? "true" : "false", for: .localSpeechPrewarm)
  }

  func handleOpenAIAPIKeyChange(from oldValue: String) {
    guard oldValue != openAIAPIKey else { return }
    openAIVerificationTask?.cancel()
    openAIVerificationTask = nil
    openAIVerificationGeneration &+= 1
    openAIVerificationFailure = nil
    openAIConfigurationVerificationState = .idle
    if !isRestoringSettings {
      openAICredentialLoadGeneration &+= 1
      openAICredentialAvailability = credentialStore == nil ? .inaccessible : .saving
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
    openAIVerificationTask?.cancel()
    openAIVerificationTask = nil
    openAIVerificationGeneration &+= 1
    openAIVerificationFailure = nil
    openAIConfigurationVerificationState = .idle
    persistStringSetting(value, for: key)
  }

  func handleLegacyWhisperRuntimeSettingChange<Value: Equatable>(
    from oldValue: Value,
    value: Value
  ) {
    guard oldValue != value else { return }
    publishCurrentLocalSpeechSettingsToRuntime()
    resetLocalSpeechPreparationStatus()
  }

}
