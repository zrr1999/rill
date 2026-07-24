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

  func handleBuiltinPushToTalkOutputModeChange(from oldValue: BuiltinPushToTalkOutputMode) {
    guard oldValue != builtinPushToTalkOutputMode else { return }
    invalidateWorkflowExplanation()
    persistBuiltinPushToTalkOutputModePreference()
  }

  func handleLongRecordingModeChange(from oldValue: Bool) {
    guard oldValue != longRecordingModeEnabled else { return }
    persistLongRecordingModePreference()
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

  func handleDeepgramAPIKeyChange(from oldValue: String) {
    guard oldValue != deepgramAPIKey else { return }
    if !isRestoringSettings {
      deepgramCredentialLoadGeneration += 1
      deepgramCredentialAvailability = credentialStore == nil ? .inaccessible : .saving
    }
    handleDeepgramStringChange(
      from: oldValue,
      value: deepgramAPIKey,
      key: .deepgramAPIKey
    )
  }

  func handleDeepgramBaseURLChange(from oldValue: String) {
    handleDeepgramStringChange(
      from: oldValue,
      value: deepgramBaseURL,
      key: .deepgramBaseURL
    )
  }

  func handleDeepgramModelChange(from oldValue: String) {
    handleDeepgramStringChange(
      from: oldValue,
      value: deepgramModel,
      key: .deepgramModel
    )
  }

  func handleDeepgramLanguageChange(from oldValue: String) {
    handleDeepgramStringChange(
      from: oldValue,
      value: deepgramLanguage,
      key: .deepgramLanguage
    )
  }

  func handleLegacyWhisperRuntimeSettingChange<Value: Equatable>(
    from oldValue: Value,
    value: Value
  ) {
    guard oldValue != value else { return }
    publishCurrentLocalSpeechSettingsToRuntime()
    resetLocalSpeechPreparationStatus()
  }

  func handleDeepgramStringChange(
    from oldValue: String,
    value: String,
    key: AppSettingKey
  ) {
    guard oldValue != value else { return }
    if !isRestoringSettings,
      let lastFailure,
      L10n.hasDeepgramAPIKeyRecovery(for: lastFailure)
    {
      self.lastFailure = nil
    }
    let cancelledActiveSpeechCheck = !isRestoringSettings && deepgramAudioTestState != .idle
    if cancelledActiveSpeechCheck {
      cancelDeepgramAudioTest()
    }
    deepgramTestTranscript = nil
    deepgramTestError =
      cancelledActiveSpeechCheck
      ? UIStrings.text(.deepgramConfigurationChanged, language: language)
      : nil
    persistDeepgramSetting(value, for: key)
  }
}
