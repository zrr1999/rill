import Foundation
import RillCore
import Testing

private actor UncooperativeOperation {
  private var continuation: CheckedContinuation<String, Never>?
  private var startedWaiters: [CheckedContinuation<Void, Never>] = []

  func run() async -> String {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      startedWaiters.forEach { $0.resume() }
      startedWaiters.removeAll()
    }
  }

  func waitUntilStarted() async {
    if continuation != nil { return }
    await withCheckedContinuation { startedWaiters.append($0) }
  }

  func release() {
    continuation?.resume(returning: "Late result")
    continuation = nil
  }
}

struct BoundedOperationTests {
  @Test func cancelledDependencyRetainsItsSlotUntilItReallyFinishes() async throws {
    let owner = BoundedOperation()
    let dependency = UncooperativeOperation()
    let first = Task { try await owner.run(timeout: .seconds(60)) { await dependency.run() } }
    await dependency.waitUntilStarted()
    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    #expect(await owner.pendingOperationCount == 1)
    await #expect(throws: OperationDeadlineError.capacityExceeded) {
      try await owner.run(timeout: .seconds(1)) { "Must not start" }
    }
    let shutdown = Task { await owner.shutdown() }
    await dependency.release()
    await shutdown.value
    #expect(await owner.pendingOperationCount == 0)
    await #expect(throws: OperationDeadlineError.stopped) {
      try await owner.run(timeout: .seconds(1)) { "Must not restart" }
    }
  }
}
