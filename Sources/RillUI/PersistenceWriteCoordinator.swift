import Foundation
import RillCore

/// Serializes replacement writes per key and retains every accepted write until
/// completion, including cancelled writes whose stores ignore cancellation.
@MainActor
final class PersistenceWriteCoordinator {
  private struct PendingWrite {
    let id: UUID
    let keys: Set<AppSettingKey>
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
    replace(for: [key], debounce: debounce, operation: operation) { result, _ in
      completion(result)
    }
  }

  func replace(
    for keys: Set<AppSettingKey>,
    debounce: Duration = .zero,
    operation: @escaping @Sendable () async throws -> Void,
    completion: @escaping @MainActor (Result<Void, Error>, Set<AppSettingKey>) -> Void
  ) {
    guard !keys.isEmpty else { return }
    let predecessors = Dictionary(
      keys.compactMap { latestWrites[$0] }.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    ).values
    // A replacement of one key must not cancel the other keys in a transaction.
    for previous in predecessors where previous.keys.isSubset(of: keys) {
      previous.task.cancel()
    }
    let previousTasks = predecessors.map(\.task)
    let id = UUID()
    let task = Task { [weak self, previousTasks] in
      for previous in previousTasks { await previous.value }
      let result: Result<Void, Error>
      do {
        try await Task.sleep(for: debounce)
        try Task.checkCancellation()
        try await operation()
        result = .success(())
      } catch {
        result = .failure(error)
      }
      guard let self else { return }
      let currentKeys = keys.filter { self.latestWrites[$0]?.id == id }
      for key in currentKeys { self.latestWrites[key] = nil }
      if !currentKeys.isEmpty { completion(result, currentKeys) }
    }
    for key in keys { latestWrites[key] = PendingWrite(id: id, keys: keys, task: task) }
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
