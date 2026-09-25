import Foundation
import RillCore

extension VoiceRunModel {
  func prepareLocalSpeechModel(
    settings request: LocalSpeechSettings, allowedModelIDs: Set<String>,
    didPrepare: @escaping @MainActor (String) -> Void
  ) {
    guard !settings.hasBegunApplicationShutdown, localSpeechPreparationState != .preparing else {
      return
    }
    localSpeechPreparationState = .preparing
    localSpeechPreparationProgress = 0
    localSpeechPreparationCompletedUnitCount = 0
    localSpeechPreparationTotalUnitCount = 0
    localSpeechPreparedModelIdentifier = nil
    localSpeechPreparationError = nil
    let id = UUID()
    let owner = localSpeechPreparationTaskOwner
    let task = Task { [weak self, prepareLocalSpeech, owner] in
      defer { owner.finish(id: id) }
      guard owner.isActive(id: id), !Task.isCancelled,
        self?.settings.hasBegunApplicationShutdown == false
      else { return }
      do {
        let model = try await prepareLocalSpeech(request) { [weak self] progress in
          Task { @MainActor [weak self] in
            self?.updateLocalSpeechPreparationProgress(progress, operationID: id)
          }
        }
        guard let self, owner.isActive(id: id), !Task.isCancelled,
          !settings.hasBegunApplicationShutdown
        else { return }
        guard model == request.model, allowedModelIDs.contains(model) else {
          resetPreparationPresentation()
          applyLocalSpeechPreparationFailure(LocalSpeechPreparationFailure(stage: .trustRoot))
          return
        }
        localSpeechPreparationState = .ready
        localSpeechPreparationProgress = 1
        localSpeechPreparedModelIdentifier = model
        didPrepare(model)
        appendEvent(
          EventFeedEntry(
            english: String(
              format: L10n.runText(.localSpeechModelReadyFormat, language: .english), model),
            simplifiedChinese: String(
              format: L10n.runText(.localSpeechModelReadyFormat, language: .simplifiedChinese),
              model)))
      } catch {
        guard let self, owner.isActive(id: id), !Task.isCancelled,
          !settings.hasBegunApplicationShutdown
        else { return }
        resetPreparationPresentation()
        if !(error is CancellationError) { applyLocalSpeechPreparationFailure(error) }
      }
    }
    _ = owner.replaceActive(id: id, with: task)
  }

  public func cancelLocalSpeechModelPreparation() {
    guard localSpeechPreparationState == .preparing else { return }
    localSpeechPreparationTaskOwner.cancelActive()
    resetPreparationPresentation()
    releaseLocalSpeech()
  }

  public func releaseLocalSpeechModelMemory() {
    guard !settings.hasBegunApplicationShutdown, localSpeechPreparationState != .preparing else {
      return
    }
    localSpeechPreparationTaskOwner.cancelActive()
    releaseLocalSpeech()
    localSpeechPreparationError = nil
    appendEvent(
      EventFeedEntry(
        english: L10n.runText(.localSpeechModelMemoryReleased, language: .english),
        simplifiedChinese: L10n.runText(
          .localSpeechModelMemoryReleased, language: .simplifiedChinese)))
  }

  private func applyLocalSpeechPreparationFailure(_ error: Error) {
    let stage = (error as? LocalSpeechPreparationFailure)?.stage ?? .generic
    let presentation = L10n.localSpeechPreparationFailure(stage)
    localSpeechPreparationError = presentation.string(for: settings.language)
    appendEvent(
      EventFeedEntry(
        english: presentation.english, simplifiedChinese: presentation.simplifiedChinese))
  }

  private func updateLocalSpeechPreparationProgress(_ progress: Progress, operationID: UUID) {
    guard !settings.hasBegunApplicationShutdown,
      localSpeechPreparationTaskOwner.isActive(id: operationID),
      localSpeechPreparationState == .preparing
    else { return }
    let fraction = progress.fractionCompleted
    if fraction.isFinite { localSpeechPreparationProgress = min(max(fraction, 0), 1) }
    localSpeechPreparationCompletedUnitCount = max(progress.completedUnitCount, 0)
    localSpeechPreparationTotalUnitCount = max(progress.totalUnitCount, 0)
  }

  public func waitForLocalSpeechPreparation() async {
    await localSpeechPreparationTaskOwner.waitUntilIdle()
  }

  func stopLocalSpeechPreparationForApplicationShutdown() async {
    resetPreparationPresentation()
    localSpeechPreparationTaskOwner.stopForApplicationShutdown()
    await stopLocalSpeech()
  }

  func resetLocalSpeechPreparationStatus() {
    cancelWakeWordPreparation()
    localSpeechPreparationTaskOwner.cancelActive()
    resetPreparationPresentation()
    if !settings.isRestoringSettings { releaseLocalSpeech() }
  }

  private func resetPreparationPresentation() {
    localSpeechPreparationState = .idle
    localSpeechPreparationProgress = 0
    localSpeechPreparationCompletedUnitCount = 0
    localSpeechPreparationTotalUnitCount = 0
    localSpeechPreparedModelIdentifier = nil
    localSpeechPreparationError = nil
  }
}
