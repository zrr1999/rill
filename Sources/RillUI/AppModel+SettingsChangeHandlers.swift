import Foundation
import RillCore

extension AppModel {
  func handleLanguageChange(from oldValue: AppLanguage) {
    guard oldValue != self.settings.language else { return }
    persistLanguagePreference()
    voice.syncLiveSubtitlePanel()
    refreshUnavailableStoredSettingsDomainErrors()
  }

  func handleClipboardCaptureEnabledChange(from oldValue: Bool) {
    guard oldValue != self.settings.systemClipboardCaptureEnabled else { return }
    clipboardCapturePreferenceRevision &+= 1
    persistClipboardCaptureEnabledPreference()
    publishClipboardCapturePreferenceToRuntime()
  }

  func applyResolvedClipboardCapturePreference(enabled: Bool) {
    guard self.settings.systemClipboardCaptureEnabled == enabled else {
      applySystemClipboardCaptureEnabled(enabled)
      return
    }
    clipboardCapturePreferenceRevision &+= 1
    publishClipboardCapturePreferenceToRuntime()
  }

  private func publishClipboardCapturePreferenceToRuntime() {
    recordInteractions.setCaptureEnabled(
      self.settings.systemClipboardCaptureEnabled,
      clipboardCapturePreferenceRevision
    )
  }

  func handleBufferOutputHotkeyChange(from oldValue: HotkeyBindingDescriptor) {
    guard oldValue != settings.bufferOutputHotkeyBinding else { return }
    persistStringSetting(settings.bufferOutputHotkeyBinding.storageString, for: .bufferOutputHotkey)
    recordInteractions.updateBufferHotkey(settings.bufferOutputHotkeyBinding)
  }

  func handleRecordPanelHotkeyChange(from oldValue: HotkeyBindingDescriptor) {
    guard oldValue != self.settings.recordPanelHotkeyBinding else { return }
    persistRecordPanelHotkeyPreference()
    recordInteractions.updateHotkey(self.settings.recordPanelHotkeyBinding)
  }

  func handlePreferredSpeechEngineChange(from oldValue: PreferredSpeechEngine) {
    guard oldValue != self.settings.preferredSpeechEngine else { return }
    workflowLibrary.cancelWorkflowExplanation()
    persistPreferredSpeechEnginePreference()
    guard !self.settings.isRestoringSettings else { return }
    setLocalSpeechRuntimeEnabledAction(self.settings.preferredSpeechEngine == .local)
    if self.settings.isLoading {
      self.voice.shouldPrepareLocalSpeechModelAfterInitialSettingsLoad =
        self.settings.preferredSpeechEngine == .local
      return
    }
    if self.settings.preferredSpeechEngine == .local {
      prepareLocalSpeechModel()
    } else {
      // A cloud selection owns no local-model readiness state. Retire
      // any in-flight local load so an old completion cannot publish
      // ready after the route has changed.
      voice.resetLocalSpeechPreparationStatus()
    }
  }

  func handleTTSModelIdentifierChange(from oldValue: String) {
    guard oldValue != self.settings.ttsModelIdentifier else { return }
    persistStringSetting(self.settings.ttsModelIdentifier, for: .ttsModel)
    voice.synchronizeTTSSelection()
  }

  func handleLongRecordingModeChange(from oldValue: Bool) {
    guard oldValue != self.settings.longRecordingModeEnabled else { return }
    persistLongRecordingModePreference()
  }

  func handleRecordingDurationLimitChange(from oldValue: RecordingDurationLimit) {
    guard oldValue != self.settings.recordingDurationLimit else { return }
    persistRecordingDurationLimitPreference()
  }

  func handleLocalSpeechModelChange(from oldValue: String) {
    if oldValue != self.settings.localSpeechModel, !self.settings.isRestoringSettings {
      self.settings.localSpeechModelMutationGeneration &+= 1
    }
    guard oldValue != self.settings.localSpeechModel else { return }
    publishCurrentLocalSpeechSettingsToRuntime()
    voice.resetLocalSpeechPreparationStatus()
    synchronizeWakeWordResourceWithLocalSpeechModel()
    persistStringSetting(self.settings.localSpeechModel, for: .localSpeechModel)
  }

  func handleLocalSpeechPrewarmChange(from oldValue: Bool) {
    guard oldValue != self.settings.localSpeechPrewarm else { return }
    publishCurrentLocalSpeechSettingsToRuntime()
    voice.resetLocalSpeechPreparationStatus()
    persistStringSetting(self.settings.localSpeechPrewarm ? "true" : "false", for: .localSpeechPrewarm)
  }

  func handleEnabledSpeechModelIDsChange(from oldValue: Set<String>) {
    guard oldValue != self.settings.enabledSpeechModelIDs else { return }
    markSettingModifiedDuringInitialLoad(.enabledSpeechModels)
    if !self.settings.residentSpeechModelIDs.isSubset(of: self.settings.enabledSpeechModelIDs) {
      applyResidentSpeechModelIDs(self.settings.residentSpeechModelIDs.intersection(self.settings.enabledSpeechModelIDs))
    }
    applyResidentSpeechBudgetConfirmation(nil)
    publishCurrentLocalSpeechSettingsToRuntime()
    persistSpeechModelIDSet(self.settings.enabledSpeechModelIDs, for: .enabledSpeechModels)
  }

  func handleResidentSpeechModelIDsChange(from oldValue: Set<String>) {
    guard oldValue != self.settings.residentSpeechModelIDs else { return }
    markSettingModifiedDuringInitialLoad(.residentSpeechModels)
    publishCurrentLocalSpeechSettingsToRuntime()
    persistSpeechModelIDSet(self.settings.residentSpeechModelIDs, for: .residentSpeechModels)
    synchronizeResidentSpeechModels(from: oldValue)
  }

  func handleResidentSpeechBudgetConfirmationChange(from oldValue: String?) {
    guard oldValue != self.settings.residentSpeechBudgetConfirmation else { return }
    markSettingModifiedDuringInitialLoad(.residentSpeechBudgetConfirmation)
    persistStringSetting(
      self.settings.residentSpeechBudgetConfirmation ?? "",
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

}
