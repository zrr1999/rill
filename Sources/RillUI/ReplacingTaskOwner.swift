import Foundation

/// Replaced work remains owned until completion, including non-cooperative cancellation.
@MainActor
final class ReplacingTaskOwner {
  private var currentTaskID: UUID?
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []

  func replace(id: UUID, with task: Task<Void, Never>) {
    if let currentTaskID {
      tasks[currentTaskID]?.cancel()
    }
    tasks[id] = task
    currentTaskID = id
  }

  func finish(id: UUID) {
    tasks.removeValue(forKey: id)
    if currentTaskID == id {
      currentTaskID = nil
    }
    guard tasks.isEmpty else { return }
    let waiters = idleWaiters
    idleWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  func cancel() {
    guard let currentTaskID else { return }
    tasks[currentTaskID]?.cancel()
    self.currentTaskID = nil
  }

  func waitUntilIdle() async {
    guard !tasks.isEmpty else { return }
    await withCheckedContinuation { continuation in
      idleWaiters.append(continuation)
    }
  }

  deinit {
    for task in tasks.values {
      task.cancel()
    }
    for waiter in idleWaiters {
      waiter.resume()
    }
  }
}
