import Foundation
import RillCore
import RillWorkflows
import RillRecords
import RillKnowledge
import RillSpeech

extension AppModel {
  public func prepareLocalSpeechModel() {
    guard !hasBegunApplicationShutdown,
      !self.settings.isLoading,
      self.voice.localSpeechPreparationState != .preparing
    else {
      return
    }
    guard !settings.hasUnavailableScalarSettings(in: .localSpeech) else {
      self.voice.localSpeechPreparationFailure = ProviderSettingsPersistenceError.unavailableStoredSettings.presentation
      return
    }
    guard localSpeechTrustMaterialAvailable else {
      self.voice.localSpeechPreparationState = .idle
      self.voice.localSpeechPreparationProgress = 0
      self.voice.localSpeechPreparedModelIdentifier = nil
      self.voice.localSpeechPreparationFailure = L10n.localSpeechAvailabilityResource(localSpeechAvailability)
      return
    }
    if !trustedLocalSpeechModels.isEmpty {
      let selectedModel = selectedTrustedLocalSpeechModelIdentifier
      guard !selectedModel.isEmpty else {
        self.voice.localSpeechPreparationState = .idle
        self.voice.localSpeechPreparationProgress = 0
        self.voice.localSpeechPreparedModelIdentifier = nil
        self.voice.localSpeechPreparationFailure = L10n.resource("interface.localSpeechTrustMaterialUnavailable")
        return
      }
      if self.settings.localSpeechModel != selectedModel {
        applyLocalSpeechModel(selectedModel)
      }
    }
    voice.prepareLocalSpeechModel(
      settings: currentLocalSpeechSettings(),
      allowedModelIDs: Set(trustedLocalSpeechModels.map(\.id))
    ) { [weak self] model in
      self?.recordDownloadedLocalSpeechModel(model)
    }
  }

  public func stopLocalSpeechPreparationForApplicationShutdown() async {
    beginApplicationShutdown()
    await voice.stopLocalSpeechPreparationForApplicationShutdown()
  }
}
