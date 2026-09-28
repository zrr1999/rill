import Foundation
import RillCore

extension VoiceRunModel {
  func prepareWakeWordModel(didPrepare: @escaping @MainActor (String) -> Void) {
    guard !settings.hasBegunApplicationShutdown, !wakeWordResourceState.isPreparing else { return }
    let id = UUID()
    let owner = wakeWordPreparationTaskOwner
    wakeWordResourceState = .preparing(progress: nil)
    let task = Task { [weak self, owner, resources] in
      defer { owner.finish(id: id) }
      guard owner.isActive(id: id), !Task.isCancelled,
        self?.settings.hasBegunApplicationShutdown == false
      else { return }
      do {
        let model = try await resources.prepareWakeWordModel { [weak self] progress in
          Task { @MainActor [weak self] in
            guard let self, owner.isActive(id: id), !settings.hasBegunApplicationShutdown else {
              return
            }
            wakeWordResourceState = .preparing(progress: progress)
          }
        }
        guard let self, owner.isActive(id: id), !Task.isCancelled,
          !settings.hasBegunApplicationShutdown
        else { return }
        didPrepare(model)
        wakeWordResourceState = .ready
        resourceAvailabilityChanged()
      } catch {
        guard let self, owner.isActive(id: id), !settings.hasBegunApplicationShutdown else {
          return
        }
        switch error {
        case is CancellationError: wakeWordResourceState = .notInstalled
        case let reason as VoiceAssistantResourceUnavailableReason:
          wakeWordResourceState = .unavailable(reason)
        default: wakeWordResourceState = .failed(error.localizedDescription)
        }
        resourceAvailabilityChanged()
      }
    }
    _ = owner.replaceActive(id: id, with: task)
  }

  func cancelWakeWordPreparation() {
    wakeWordPreparationTaskOwner.cancelActive()
    if wakeWordResourceState.isPreparing { wakeWordResourceState = .notInstalled }
  }

  func synchronizeTTSSelection() {
    resources.selectTTSModel(settings.ttsModelIdentifier)
    ttsResourceState =
      downloadedTTSModelIdentifiers.contains(settings.ttsModelIdentifier) ? .ready : .notInstalled
  }

  func validateWakeWordConfiguration(_ configuration: WakeWordConfiguration) async throws {
    try await resources.validateWakeWordConfiguration(configuration)
  }

  @discardableResult public func stopSpeechPlaybackIfActive() -> Bool {
    resources.stopSpeechPlayback()
  }

  func stopResourcePreparationForApplicationShutdown() {
    cancelWakeWordPreparation()
    wakeWordPreparationTaskOwner.stopForApplicationShutdown()
  }

  func waitForResourcePreparations() async {
    await wakeWordPreparationTaskOwner.waitUntilIdle()
  }
}
