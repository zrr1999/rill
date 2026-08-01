import XCTest

@testable import RillCore
@testable import RillUI

@MainActor
final class AppModelLiveSubtitleMeterRefreshTests: XCTestCase {
  func testTrailingRefreshPublishesLatestSuppressedMeter() async throws {
    let harness = makeHarness()
    let gate = installMeterRefreshGate(on: harness.model)
    let runID = UUID()
    beginThrottledCapture(harness.model, runID: runID)

    updateMeter(harness.model, runID: runID, levels: [0.2])
    let refreshTask = try XCTUnwrap(harness.model.pendingLiveSubtitleMeterRefreshTask)
    updateMeter(harness.model, runID: runID, levels: [0.8])
    await gate.waitUntilScheduled()

    XCTAssertEqual(harness.model.currentCaptureLiveSubtitleSnapshot?.levelMeter, [])

    await gate.releaseAll()
    await refreshTask.value

    XCTAssertEqual(harness.model.currentCaptureLiveSubtitleSnapshot?.levelMeter, [0.8])
    XCTAssertEqual(harness.model.liveSubtitleSnapshot?.levelMeter, [0.8])
    XCTAssertNil(harness.model.pendingLiveSubtitleMeterSnapshot)
    XCTAssertNil(harness.model.pendingLiveSubtitleMeterRefreshTask)
  }

  func testStaleMeterCannotOverwriteNewRun() async throws {
    let harness = makeHarness()
    let gate = installMeterRefreshGate(on: harness.model)
    let previousRunID = UUID()
    beginThrottledCapture(harness.model, runID: previousRunID)
    updateMeter(harness.model, runID: previousRunID, levels: [0.4])
    let staleTask = try XCTUnwrap(harness.model.pendingLiveSubtitleMeterRefreshTask)
    await gate.waitUntilScheduled()

    let currentRunID = UUID()
    harness.model.handle(
      .liveSubtitleUpdated(
        LiveSubtitleSnapshot(
          runID: currentRunID,
          phase: .recording,
          levelMeter: [0.9],
          providerID: "sherpa-onnx.local"
        )
      )
    )

    XCTAssertTrue(staleTask.isCancelled)
    await gate.releaseAll()
    await staleTask.value

    XCTAssertEqual(harness.model.currentCaptureLiveSubtitleSnapshot?.runID, currentRunID)
    XCTAssertEqual(harness.model.currentCaptureLiveSubtitleSnapshot?.levelMeter, [0.9])
  }

  func testStaleMeterCannotOverwriteSameRunSemanticTransition() async throws {
    let harness = makeHarness()
    let gate = installMeterRefreshGate(on: harness.model)
    let runID = UUID()
    beginThrottledCapture(harness.model, runID: runID)
    updateMeter(harness.model, runID: runID, levels: [0.4])
    let staleTask = try XCTUnwrap(harness.model.pendingLiveSubtitleMeterRefreshTask)
    await gate.waitUntilScheduled()

    harness.model.handle(
      .liveSubtitleUpdated(
        LiveSubtitleSnapshot(
          runID: runID,
          phase: .transcribing,
          confirmedText: "current",
          levelMeter: [0.9],
          providerID: "sherpa-onnx.local"
        )
      )
    )

    XCTAssertTrue(staleTask.isCancelled)
    await gate.releaseAll()
    await staleTask.value

    XCTAssertEqual(harness.model.currentCaptureLiveSubtitleSnapshot?.phase, .transcribing)
    XCTAssertEqual(harness.model.currentCaptureLiveSubtitleSnapshot?.confirmedText, "current")
    XCTAssertEqual(harness.model.currentCaptureLiveSubtitleSnapshot?.levelMeter, [0.9])
  }

  func testHiddenSnapshotCancelsPendingMeterRefresh() async throws {
    let harness = makeHarness()
    let gate = installMeterRefreshGate(on: harness.model)
    let runID = UUID()
    beginThrottledCapture(harness.model, runID: runID)
    updateMeter(harness.model, runID: runID, levels: [0.6])
    let staleTask = try XCTUnwrap(harness.model.pendingLiveSubtitleMeterRefreshTask)
    await gate.waitUntilScheduled()

    harness.model.handle(
      .liveSubtitleUpdated(LiveSubtitleSnapshot(runID: runID, phase: .hidden))
    )

    XCTAssertTrue(staleTask.isCancelled)
    await gate.releaseAll()
    await staleTask.value

    XCTAssertNil(harness.model.currentCaptureLiveSubtitleSnapshot)
    XCTAssertNil(harness.model.liveSubtitleSnapshot)
  }

  func testExplicitStopAndShutdownCancelPendingMeterRefreshes() async throws {
    let stopHarness = makeHarness()
    let stopGate = installMeterRefreshGate(on: stopHarness.model)
    let stoppedRunID = UUID()
    beginThrottledCapture(stopHarness.model, runID: stoppedRunID)
    updateMeter(stopHarness.model, runID: stoppedRunID, levels: [0.3])
    let stoppedTask = try XCTUnwrap(stopHarness.model.pendingLiveSubtitleMeterRefreshTask)
    await stopGate.waitUntilScheduled()

    stopHarness.model.markLiveAudioRunStoppedByUser(runID: stoppedRunID)
    XCTAssertTrue(stoppedTask.isCancelled)
    await stopGate.releaseAll()
    await stoppedTask.value
    XCTAssertNil(stopHarness.model.currentCaptureLiveSubtitleSnapshot)

    let shutdownHarness = makeHarness()
    let shutdownGate = installMeterRefreshGate(on: shutdownHarness.model)
    let shutdownRunID = UUID()
    beginThrottledCapture(shutdownHarness.model, runID: shutdownRunID)
    updateMeter(shutdownHarness.model, runID: shutdownRunID, levels: [0.7])
    let shutdownTask = try XCTUnwrap(
      shutdownHarness.model.pendingLiveSubtitleMeterRefreshTask
    )
    await shutdownGate.waitUntilScheduled()

    await shutdownHarness.model.drainAndStopEventListenerForApplicationShutdown()
    XCTAssertTrue(shutdownTask.isCancelled)
    await shutdownGate.releaseAll()
    await shutdownTask.value

    XCTAssertEqual(shutdownHarness.model.currentCaptureLiveSubtitleSnapshot?.runID, shutdownRunID)
    XCTAssertEqual(shutdownHarness.model.currentCaptureLiveSubtitleSnapshot?.levelMeter, [])
    XCTAssertNil(shutdownHarness.model.pendingLiveSubtitleMeterSnapshot)
  }

  private func installMeterRefreshGate(on model: AppModel) -> LiveSubtitleMeterRefreshGate {
    let gate = LiveSubtitleMeterRefreshGate()
    model.waitForLiveSubtitleMeterRefresh = { _ in
      await gate.wait()
    }
    return gate
  }

  private func beginThrottledCapture(_ model: AppModel, runID: UUID) {
    model.handle(
      .liveSubtitleUpdated(
        LiveSubtitleSnapshot(
          runID: runID,
          phase: .listening,
          providerID: "sherpa-onnx.local"
        )
      )
    )
    model.handle(
      .liveSubtitleUpdated(
        LiveSubtitleSnapshot(
          runID: runID,
          phase: .recording,
          providerID: "sherpa-onnx.local"
        )
      )
    )
  }

  private func updateMeter(_ model: AppModel, runID: UUID, levels: [Float]) {
    model.handle(
      .liveSubtitleUpdated(
        LiveSubtitleSnapshot(
          runID: runID,
          phase: .recording,
          levelMeter: levels,
          providerID: "sherpa-onnx.local"
        )
      )
    )
  }
}

private actor LiveSubtitleMeterRefreshGate {
  private var scheduledCount = 0
  private var scheduledWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    scheduledCount += 1
    let readyWaiters = scheduledWaiters.filter { $0.count <= scheduledCount }
    scheduledWaiters.removeAll { $0.count <= scheduledCount }
    for waiter in readyWaiters {
      waiter.continuation.resume()
    }
    await withCheckedContinuation { continuation in
      releaseWaiters.append(continuation)
    }
  }

  func waitUntilScheduled(count: Int = 1) async {
    guard scheduledCount < count else { return }
    await withCheckedContinuation { continuation in
      scheduledWaiters.append((count, continuation))
    }
  }

  func releaseAll() {
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}
