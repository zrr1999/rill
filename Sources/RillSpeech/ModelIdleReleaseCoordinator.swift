import Foundation

actor ModelIdleReleaseCoordinator {
  private let delay: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  private var pending: [String: (id: UUID, task: Task<Void, Never>)] = [:]

  init(
    delay: Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    precondition(delay > .zero)
    self.delay = delay
    self.sleep = sleep
  }

  func markActive(modelID: String) {
    pending.removeValue(forKey: modelID)?.task.cancel()
  }

  @discardableResult
  func scheduleRelease(
    modelID: String,
    resident: Bool,
    release: @escaping @Sendable () async -> Void
  ) -> Task<Void, Never>? {
    markActive(modelID: modelID)
    guard !resident else { return nil }
    let id = UUID()
    let task = Task { [weak self, delay, sleep] in
      do {
        try await sleep(delay)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await release()
      await self?.releaseFinished(modelID: modelID, id: id)
    }
    pending[modelID] = (id, task)
    return task
  }

  func cancelAll() {
    for entry in pending.values { entry.task.cancel() }
    pending.removeAll()
  }

  private func releaseFinished(modelID: String, id: UUID) {
    guard pending[modelID]?.id == id else { return }
    pending.removeValue(forKey: modelID)
  }
}
