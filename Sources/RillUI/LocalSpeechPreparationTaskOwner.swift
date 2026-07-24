import Foundation

/// Retains every local-model preparation task while the application is live.
///
/// Replacing or cancelling the active task only retires it: providers are
/// allowed to ignore cooperative cancellation, so retired tasks remain owned
/// until they finish or terminal application shutdown releases their handles.
@MainActor
final class LocalSpeechPreparationTaskOwner {
  enum State: Sendable, Equatable {
    case accepting
    case stopped
  }

  private(set) var state: State = .accepting
  private(set) var activeID: UUID?
  private var tasks: [UUID: Task<Void, Never>] = [:]

  var trackedTaskCount: Int {
    tasks.count
  }

  func replaceActive(
    id: UUID,
    with task: Task<Void, Never>
  ) -> Bool {
    guard state == .accepting else {
      task.cancel()
      return false
    }

    if let activeID {
      tasks[activeID]?.cancel()
    }
    tasks[id] = task
    activeID = id
    return true
  }

  func isActive(id: UUID) -> Bool {
    state == .accepting && activeID == id
  }

  /// Cancels the current operation without releasing ownership of it.
  func cancelActive() {
    guard let activeID else { return }
    tasks[activeID]?.cancel()
    self.activeID = nil
  }

  func finish(id: UUID) {
    tasks.removeValue(forKey: id)
    if activeID == id {
      activeID = nil
    }
  }

  /// Rejects future tasks and cancels all active and retired preparations.
  ///
  /// A provider may be queued behind a non-cooperative native decode and never
  /// return. Application shutdown is terminal, and every task already guards
  /// publication with this owner's state plus the model shutdown generation,
  /// so waiting for those provider calls would only deadlock safe termination.
  func stopForApplicationShutdown() {
    guard state == .accepting else { return }
    state = .stopped
    activeID = nil
    let tasks = Array(self.tasks.values)
    self.tasks.removeAll()
    for task in tasks {
      task.cancel()
    }
  }
}
