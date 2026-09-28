import Foundation

actor HistoryMaintenanceClock {
  private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
  private var cancelled: Set<UUID> = []
  private var observers: [CheckedContinuation<Void, Never>] = []
  var pendingCount: Int { pending.count }

  func sleep(for _: Duration) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled || cancelled.remove(id) != nil {
          continuation.resume(throwing: CancellationError())
        } else {
          pending[id] = continuation
          let waiting = observers
          observers = []
          for observer in waiting { observer.resume() }
        }
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }

  func waitUntilSleeping() async {
    if !pending.isEmpty { return }
    await withCheckedContinuation { observers.append($0) }
  }

  func advance() {
    let waiting = pending
    pending = [:]
    for continuation in waiting.values { continuation.resume() }
  }

  private func cancel(_ id: UUID) {
    if let continuation = pending.removeValue(forKey: id) {
      continuation.resume(throwing: CancellationError())
    } else { cancelled.insert(id) }
  }
}
