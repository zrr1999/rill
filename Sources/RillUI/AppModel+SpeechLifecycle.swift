import Foundation
import RillCore
import RillRuntime

extension AppModel {
  public func prepareLocalSpeechModel() {
    guard !hasBegunApplicationShutdown,
      !self.settings.isLoading,
      localSpeechPreparationState != .preparing
    else {
      return
    }
    guard !hasUnavailableScalarSettings(in: .localSpeech) else {
      localSpeechPreparationError = ProviderSettingsPersistenceError.unavailableStoredSettings
        .message(language: language)
      return
    }
    guard localSpeechTrustMaterialAvailable else {
      localSpeechPreparationState = .idle
      localSpeechPreparationProgress = 0
      localSpeechPreparedModelIdentifier = nil
      localSpeechPreparationError = UIStrings.localSpeechAvailabilityDescription(
        localSpeechAvailability,
        language: language
      )
      return
    }
    localSpeechPreparationTaskOwner.cancelActive()
    localSpeechPreparationGeneration += 1
    let generation = localSpeechPreparationGeneration
    if !trustedLocalSpeechModels.isEmpty {
      let selectedModel = selectedTrustedLocalSpeechModelIdentifier
      guard !selectedModel.isEmpty else {
        localSpeechPreparationState = .idle
        localSpeechPreparationProgress = 0
        localSpeechPreparedModelIdentifier = nil
        localSpeechPreparationError = UIStrings.text(
          UIStrings.Key.localSpeechTrustMaterialUnavailable,
          language: language
        )
        return
      }
      if localSpeechModel != selectedModel {
        localSpeechModel = selectedModel
      }
    }
    localSpeechPreparationState = .preparing
    localSpeechPreparationProgress = 0
    localSpeechPreparationCompletedUnitCount = 0
    localSpeechPreparationTotalUnitCount = 0
    localSpeechPreparedModelIdentifier = nil
    localSpeechPreparationError = nil
    let settings = currentLocalSpeechSettings()
    let operationID = UUID()
    let progressRelay = LocalSpeechPreparationProgressRelay(
      model: self,
      operationID: operationID
    )
    let taskOwner = localSpeechPreparationTaskOwner

    let task = Task { [weak self, prepareLocalSpeechAction, taskOwner] in
      let shouldStartProvider = await MainActor.run {
        guard let self,
          !self.hasBegunApplicationShutdown,
          taskOwner.isActive(id: operationID),
          self.localSpeechPreparationGeneration == generation
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
          && self?.localSpeechPreparationGeneration == generation
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
            self.localSpeechPreparationState = .idle
            self.localSpeechPreparationProgress = 0
            self.localSpeechPreparedModelIdentifier = nil
            self.applyLocalSpeechPreparationFailure(
              LocalSpeechPreparationFailure(stage: .trustRoot)
            )
            return
          }
          self.localSpeechPreparationState = .ready
          self.localSpeechPreparationProgress = 1
          self.localSpeechPreparedModelIdentifier = preparedModel
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
          self.localSpeechPreparationState = .idle
          self.localSpeechPreparationProgress = 0
          self.localSpeechPreparedModelIdentifier = nil
        case .failure(let error):
          self.localSpeechPreparationState = .idle
          self.localSpeechPreparationProgress = 0
          self.localSpeechPreparedModelIdentifier = nil
          self.applyLocalSpeechPreparationFailure(error)
        }
      }
    }
    _ = taskOwner.replaceActive(id: operationID, with: task)
  }

  public func cancelLocalSpeechModelPreparation() {
    guard localSpeechPreparationState == .preparing else { return }
    localSpeechPreparationGeneration += 1
    localSpeechPreparationTaskOwner.cancelActive()
    localSpeechPreparationState = .idle
    localSpeechPreparationProgress = 0
    localSpeechPreparationCompletedUnitCount = 0
    localSpeechPreparationTotalUnitCount = 0
    localSpeechPreparedModelIdentifier = nil
    localSpeechPreparationError = nil
    releaseLocalSpeechRuntimeAction()
  }

  public func releaseLocalSpeechModelMemory() {
    guard !hasBegunApplicationShutdown,
      localSpeechPreparationState != .preparing
    else {
      return
    }
    localSpeechPreparationGeneration += 1
    localSpeechPreparationTaskOwner.cancelActive()
    releaseLocalSpeechRuntimeAction()
    localSpeechPreparationError = nil
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
    localSpeechPreparationError = presentation.string(for: language)
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
      localSpeechPreparationTaskOwner.isActive(id: operationID),
      localSpeechPreparationState == .preparing
    else {
      return
    }
    let fraction = progress.fractionCompleted
    if fraction.isFinite {
      localSpeechPreparationProgress = min(max(fraction, 0), 1)
    }
    localSpeechPreparationCompletedUnitCount = max(progress.completedUnitCount, 0)
    localSpeechPreparationTotalUnitCount = max(progress.totalUnitCount, 0)
  }

  /// Waits for local speech preparation, including cancelled provider work
  /// that is still unwinding, without changing the selected model or state.
  public func waitForLocalSpeechPreparation() async {
    await localSpeechPreparationTaskOwner.waitUntilIdle()
  }

  public func stopLocalSpeechPreparationForApplicationShutdown() async {
    hasBegunApplicationShutdown = true
    localSpeechPreparationGeneration += 1

    localSpeechPreparationState = .idle
    localSpeechPreparationProgress = 0
    localSpeechPreparedModelIdentifier = nil
    localSpeechPreparationError = nil

    localSpeechPreparationTaskOwner.stopForApplicationShutdown()
    await stopLocalSpeechRuntimeAction()
  }

  func resetLocalSpeechPreparationStatus() {
    localSpeechPreparationGeneration += 1
    localSpeechPreparationTaskOwner.cancelActive()
    localSpeechPreparationState = .idle
    localSpeechPreparationProgress = 0
    localSpeechPreparedModelIdentifier = nil
    localSpeechPreparationError = nil
    if !isRestoringSettings {
      releaseLocalSpeechRuntimeAction()
    }
  }

}
