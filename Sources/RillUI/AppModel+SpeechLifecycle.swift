import Foundation
import RillCore
import RillRuntime

extension AppModel {
  public func prepareLocalSpeechModel() {
    guard !hasBegunApplicationShutdown,
      !self.settings.isLoading,
      self.voice.localSpeechPreparationState != .preparing
    else {
      return
    }
    guard !hasUnavailableScalarSettings(in: .localSpeech) else {
      self.voice.localSpeechPreparationError = ProviderSettingsPersistenceError.unavailableStoredSettings
        .message(language: language)
      return
    }
    guard localSpeechTrustMaterialAvailable else {
      self.voice.localSpeechPreparationState = .idle
      self.voice.localSpeechPreparationProgress = 0
      self.voice.localSpeechPreparedModelIdentifier = nil
      self.voice.localSpeechPreparationError = L10n.localSpeechAvailabilityDescription(
        localSpeechAvailability,
        language: language
      )
      return
    }
    self.voice.localSpeechPreparationTaskOwner.cancelActive()
    self.voice.localSpeechPreparationGeneration += 1
    let generation = self.voice.localSpeechPreparationGeneration
    if !trustedLocalSpeechModels.isEmpty {
      let selectedModel = selectedTrustedLocalSpeechModelIdentifier
      guard !selectedModel.isEmpty else {
        self.voice.localSpeechPreparationState = .idle
        self.voice.localSpeechPreparationProgress = 0
        self.voice.localSpeechPreparedModelIdentifier = nil
        self.voice.localSpeechPreparationError = L10n.text(
          L10n.InterfaceKey.localSpeechTrustMaterialUnavailable,
          language: language
        )
        return
      }
      if localSpeechModel != selectedModel {
        applyLocalSpeechModel(selectedModel)
      }
    }
    self.voice.localSpeechPreparationState = .preparing
    self.voice.localSpeechPreparationProgress = 0
    self.voice.localSpeechPreparationCompletedUnitCount = 0
    self.voice.localSpeechPreparationTotalUnitCount = 0
    self.voice.localSpeechPreparedModelIdentifier = nil
    self.voice.localSpeechPreparationError = nil
    let settings = currentLocalSpeechSettings()
    let operationID = UUID()
    let progressRelay = LocalSpeechPreparationProgressRelay(
      model: self,
      operationID: operationID
    )
    let taskOwner = self.voice.localSpeechPreparationTaskOwner

    let task = Task { [weak self, prepareLocalSpeechAction, taskOwner] in
      let shouldStartProvider = await MainActor.run {
        guard let self,
          !self.hasBegunApplicationShutdown,
          taskOwner.isActive(id: operationID),
          self.voice.localSpeechPreparationGeneration == generation
        else {
          return false
        }
        return true
      }
      guard shouldStartProvider, !Task.isCancelled else {
        await MainActor.run {
          taskOwner.finish(id: operationID)
        }
        return
      }
      let result: Result<String, Error>
      do {
        result = .success(
          try await prepareLocalSpeechAction(
            settings,
            { progress in
              Task {
                await progressRelay.update(progress: progress)
              }
            }))
      } catch {
        result = .failure(error)
      }
      let wasCancelled = Task.isCancelled
      await MainActor.run {
        let shouldPublish =
          !wasCancelled
          && taskOwner.isActive(id: operationID)
          && self?.hasBegunApplicationShutdown == false
          && self?.voice.localSpeechPreparationGeneration == generation
        taskOwner.finish(id: operationID)
        guard shouldPublish, let self else { return }

        switch result {
        case .success(let preparedModel):
          guard
            self.acceptsPreparedLocalSpeechModel(
              preparedModel,
              requestedModel: settings.model
            )
          else {
            self.voice.localSpeechPreparationState = .idle
            self.voice.localSpeechPreparationProgress = 0
            self.voice.localSpeechPreparedModelIdentifier = nil
            self.applyLocalSpeechPreparationFailure(
              LocalSpeechPreparationFailure(stage: .trustRoot)
            )
            return
          }
          self.voice.localSpeechPreparationState = .ready
          self.voice.localSpeechPreparationProgress = 1
          self.voice.localSpeechPreparedModelIdentifier = preparedModel
          self.recordDownloadedLocalSpeechModel(preparedModel)
          self.append(
            english: String(
              format: L10n.runText(.localSpeechModelReadyFormat, language: .english),
              preparedModel
            ),
            simplifiedChinese: String(
              format: L10n.runText(.localSpeechModelReadyFormat, language: .simplifiedChinese),
              preparedModel
            )
          )
        case .failure(is CancellationError):
          self.voice.localSpeechPreparationState = .idle
          self.voice.localSpeechPreparationProgress = 0
          self.voice.localSpeechPreparedModelIdentifier = nil
        case .failure(let error):
          self.voice.localSpeechPreparationState = .idle
          self.voice.localSpeechPreparationProgress = 0
          self.voice.localSpeechPreparedModelIdentifier = nil
          self.applyLocalSpeechPreparationFailure(error)
        }
      }
    }
    _ = taskOwner.replaceActive(id: operationID, with: task)
  }

  public func cancelLocalSpeechModelPreparation() {
    guard self.voice.localSpeechPreparationState == .preparing else { return }
    self.voice.localSpeechPreparationGeneration += 1
    self.voice.localSpeechPreparationTaskOwner.cancelActive()
    self.voice.localSpeechPreparationState = .idle
    self.voice.localSpeechPreparationProgress = 0
    self.voice.localSpeechPreparationCompletedUnitCount = 0
    self.voice.localSpeechPreparationTotalUnitCount = 0
    self.voice.localSpeechPreparedModelIdentifier = nil
    self.voice.localSpeechPreparationError = nil
    releaseLocalSpeechRuntimeAction()
  }

  public func releaseLocalSpeechModelMemory() {
    guard !hasBegunApplicationShutdown,
      self.voice.localSpeechPreparationState != .preparing
    else {
      return
    }
    self.voice.localSpeechPreparationGeneration += 1
    self.voice.localSpeechPreparationTaskOwner.cancelActive()
    releaseLocalSpeechRuntimeAction()
    self.voice.localSpeechPreparationError = nil
    append(
      english: L10n.runText(.localSpeechModelMemoryReleased, language: .english),
      simplifiedChinese: L10n.runText(
        .localSpeechModelMemoryReleased,
        language: .simplifiedChinese
      )
    )
  }

  /// Projects provider failures into fixed, payload-free UI state.
  ///
  /// App composition may preserve one of the trusted loader's allowlisted
  /// stages by wrapping it in `LocalSpeechPreparationFailure`. Any other error
  /// is deliberately collapsed to the generic presentation before it reaches
  /// Settings or the activity feed.
  func applyLocalSpeechPreparationFailure(_ error: Error) {
    let stage = (error as? LocalSpeechPreparationFailure)?.stage ?? .generic
    let presentation = L10n.localSpeechPreparationFailure(stage)
    self.voice.localSpeechPreparationError = presentation.string(for: language)
    append(
      english: presentation.english,
      simplifiedChinese: presentation.simplifiedChinese
    )
  }

  func acceptsPreparedLocalSpeechModel(
    _ preparedModel: String,
    requestedModel: String
  ) -> Bool {
    return preparedModel == requestedModel
      && trustedLocalSpeechModels.contains(where: { $0.id == preparedModel })
  }
  func updateLocalSpeechPreparationProgress(
    _ progress: Progress,
    operationID: UUID
  ) {
    guard !hasBegunApplicationShutdown,
      self.voice.localSpeechPreparationTaskOwner.isActive(id: operationID),
      self.voice.localSpeechPreparationState == .preparing
    else {
      return
    }
    let fraction = progress.fractionCompleted
    if fraction.isFinite {
      self.voice.localSpeechPreparationProgress = min(max(fraction, 0), 1)
    }
    self.voice.localSpeechPreparationCompletedUnitCount = max(progress.completedUnitCount, 0)
    self.voice.localSpeechPreparationTotalUnitCount = max(progress.totalUnitCount, 0)
  }

  /// Waits for local speech preparation, including cancelled provider work
  /// that is still unwinding, without changing the selected model or state.
  public func waitForLocalSpeechPreparation() async {
    await self.voice.localSpeechPreparationTaskOwner.waitUntilIdle()
  }

  public func stopLocalSpeechPreparationForApplicationShutdown() async {
    beginApplicationShutdown()
    self.voice.localSpeechPreparationGeneration += 1

    self.voice.localSpeechPreparationState = .idle
    self.voice.localSpeechPreparationProgress = 0
    self.voice.localSpeechPreparedModelIdentifier = nil
    self.voice.localSpeechPreparationError = nil

    self.voice.localSpeechPreparationTaskOwner.stopForApplicationShutdown()
    await stopLocalSpeechRuntimeAction()
  }

  func resetLocalSpeechPreparationStatus() {
    self.voice.localSpeechPreparationGeneration += 1
    self.voice.localSpeechPreparationTaskOwner.cancelActive()
    self.voice.localSpeechPreparationState = .idle
    self.voice.localSpeechPreparationProgress = 0
    self.voice.localSpeechPreparedModelIdentifier = nil
    self.voice.localSpeechPreparationError = nil
    if !self.settings.isRestoringSettings {
      releaseLocalSpeechRuntimeAction()
    }
  }

}


actor LocalSpeechPreparationProgressRelay {
  weak var model: AppModel?
  let operationID: UUID

  init(model: AppModel, operationID: UUID) {
    self.model = model
    self.operationID = operationID
  }

  func update(progress: Progress) async {
    await MainActor.run { [weak model, operationID] in
      model?.updateLocalSpeechPreparationProgress(
        progress,
        operationID: operationID
      )
    }
  }
}
