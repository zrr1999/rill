import Foundation
import Testing

@testable import RillPlatform

@Suite(.timeLimit(.minutes(1)))
struct CaptureReadinessGateTests {
  private enum Failure: Error, Equatable {
    case stopped
    case timedOut
  }

  @Test func readinessReleasesAllWaitersAndKeepsTheFirstResolution() async throws {
    let gate = CaptureReadinessGate<Failure>()
    let timers = ReadinessTimerProbe()
    let first = Task { try await gate.wait(timeout: .seconds(3_600), timeoutFailure: .timedOut, sleep: timers.sleep) }
    let second = Task { try await gate.wait(timeout: .seconds(3_600), timeoutFailure: .timedOut, sleep: timers.sleep) }
    await timers.waitForStarts(2)
    await gate.signalReady()
    await gate.signalFailure(.stopped)
    await gate.cancel()
    try await first.value
    try await second.value
    #expect(await timers.cancellations == 2)

    try await gate.wait(timeout: .seconds(3_600), timeoutFailure: .timedOut, sleep: timers.sleep)
    #expect(await timers.cancellations == 3)
  }

  @Test func anEarlyFailureRetainsItsTypedReason() async {
    let gate = CaptureReadinessGate<Failure>()
    let timers = ReadinessTimerProbe()
    await gate.signalFailure(.stopped)
    await gate.signalReady()
    await #expect(throws: Failure.stopped) {
      try await gate.wait(timeout: .seconds(3_600), timeoutFailure: .timedOut, sleep: timers.sleep)
    }
    #expect(await timers.cancellations == 1)
  }

  @Test func timeoutUsesTheCallersFailureAndDuration() async {
    let gate = CaptureReadinessGate<Failure>()
    await #expect(throws: Failure.timedOut) {
      try await gate.wait(timeout: .seconds(7), timeoutFailure: .timedOut) { duration in
        #expect(duration == .seconds(7))
      }
    }
  }

  @Test func cancellingAWaiterCancelsTheGateAndJoinsBothTimers() async {
    let gate = CaptureReadinessGate<Failure>()
    let timers = ReadinessTimerProbe()
    let first = Task { try await gate.wait(timeout: .seconds(3_600), timeoutFailure: .timedOut, sleep: timers.sleep) }
    let second = Task { try await gate.wait(timeout: .seconds(3_600), timeoutFailure: .timedOut, sleep: timers.sleep) }
    await timers.waitForStarts(2)
    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    await #expect(throws: CancellationError.self) { try await second.value }
    #expect(await timers.cancellations == 2)
  }

  @Test func cancellationBeforeWaitingDoesNotLeaveAContinuationSuspended() async {
    let gate = CaptureReadinessGate<Failure>()
    let timers = ReadinessTimerProbe()
    let waiter = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await gate.wait(timeout: .seconds(3_600), timeoutFailure: .timedOut, sleep: timers.sleep)
    }
    await #expect(throws: CancellationError.self) { try await waiter.value }
    #expect(await timers.cancellations == 1)
  }
}

private actor ReadinessTimerProbe {
  private var starts = 0
  private(set) var cancellations = 0
  private var observers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  func sleep(_ duration: Duration) async throws {
    starts += 1
    let ready = observers.filter { $0.count <= starts }
    observers.removeAll { $0.count <= starts }
    for observer in ready { observer.continuation.resume() }
    do {
      try await Task.sleep(for: duration)
    } catch {
      cancellations += 1
      throw error
    }
  }

  func waitForStarts(_ count: Int) async {
    guard starts < count else { return }
    await withCheckedContinuation { observers.append((count, $0)) }
  }
}
