import Foundation
import RillCore

/// Serializes replacement writes per key and retains every accepted write until
/// completion, including cancelled writes whose stores ignore cancellation.
@MainActor
final class PersistenceWriteCoordinator {
  private struct PendingWrite {
    let id: UUID
    let task: Task<Void, Never>
  }

  private var latestWrites: [AppSettingKey: PendingWrite] = [:]
  private var tasks: [UUID: Task<Void, Never>] = [:]

  func replace(
    for key: AppSettingKey,
    debounce: Duration,
    operation: @escaping @Sendable () async throws -> Void,
    completion: @escaping @MainActor (Result<Void, Error>) -> Void
  ) {
    let previousTask = latestWrites[key]?.task
    previousTask?.cancel()
    let id = UUID()
    let task = Task { [weak self, previousTask] in
      await previousTask?.value
      let result: Result<Void, Error>
      do {
        try await Task.sleep(for: debounce)
        try Task.checkCancellation()
        try await operation()
        result = .success(())
      } catch {
        result = .failure(error)
      }
      guard let self, self.latestWrites[key]?.id == id else { return }
      self.latestWrites[key] = nil
      completion(result)
    }
    latestWrites[key] = PendingWrite(id: id, task: task)
    track(task)
  }

  func track(_ task: Task<Void, Never>) {
    let id = UUID()
    tasks[id] = Task { [weak self] in
      await task.value
      self?.tasks[id] = nil
    }
  }

  func flush() async {
    while let task = tasks.values.first {
      await task.value
    }
  }
}
