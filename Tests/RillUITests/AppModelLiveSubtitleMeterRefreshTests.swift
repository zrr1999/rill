import XCTest
import Testing

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
    let refreshTask = try XCTUnwrap(harness.model.voice.pendingLiveSubtitleMeterRefreshTask)
    updateMeter(harness.model, runID: runID, levels: [0.8])
    await gate.waitUntilScheduled()

    XCTAssertEqual(harness.model.voice.currentCaptureLiveSubtitleSnapshot?.levelMeter, [])

    await gate.releaseAll()
    await refreshTask.value

    XCTAssertEqual(harness.model.voice.currentCaptureLiveSubtitleSnapshot?.levelMeter, [0.8])
    XCTAssertEqual(harness.model.voice.liveSubtitleSnapshot?.levelMeter, [0.8])
    XCTAssertNil(harness.model.voice.pendingLiveSubtitleMeterSnapshot)
    XCTAssertNil(harness.model.voice.pendingLiveSubtitleMeterRefreshTask)
  }

  func testStaleMeterCannotOverwriteNewRun() async throws {
    let harness = makeHarness()
    let gate = installMeterRefreshGate(on: harness.model)
    let previousRunID = UUID()
    beginThrottledCapture(harness.model, runID: previousRunID)
    updateMeter(harness.model, runID: previousRunID, levels: [0.4])
    let staleTask = try XCTUnwrap(harness.model.voice.pendingLiveSubtitleMeterRefreshTask)
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

    XCTAssertEqual(harness.model.voice.currentCaptureLiveSubtitleSnapshot?.runID, currentRunID)
    XCTAssertEqual(harness.model.voice.currentCaptureLiveSubtitleSnapshot?.levelMeter, [0.9])
  }

  func testStaleMeterCannotOverwriteSameRunSemanticTransition() async throws {
    let harness = makeHarness()
    let gate = installMeterRefreshGate(on: harness.model)
    let runID = UUID()
    beginThrottledCapture(harness.model, runID: runID)
    updateMeter(harness.model, runID: runID, levels: [0.4])
    let staleTask = try XCTUnwrap(harness.model.voice.pendingLiveSubtitleMeterRefreshTask)
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

    XCTAssertEqual(harness.model.voice.currentCaptureLiveSubtitleSnapshot?.phase, .transcribing)
    XCTAssertEqual(harness.model.voice.currentCaptureLiveSubtitleSnapshot?.confirmedText, "current")
    XCTAssertEqual(harness.model.voice.currentCaptureLiveSubtitleSnapshot?.levelMeter, [0.9])
  }

  func testHiddenSnapshotCancelsPendingMeterRefresh() async throws {
    let harness = makeHarness()
    let gate = installMeterRefreshGate(on: harness.model)
    let runID = UUID()
    beginThrottledCapture(harness.model, runID: runID)
    updateMeter(harness.model, runID: runID, levels: [0.6])
    let staleTask = try XCTUnwrap(harness.model.voice.pendingLiveSubtitleMeterRefreshTask)
    await gate.waitUntilScheduled()

    harness.model.handle(
      .liveSubtitleUpdated(LiveSubtitleSnapshot(runID: runID, phase: .hidden))
    )

    XCTAssertTrue(staleTask.isCancelled)
    await gate.releaseAll()
    await staleTask.value

    XCTAssertNil(harness.model.voice.currentCaptureLiveSubtitleSnapshot)
    XCTAssertNil(harness.model.voice.liveSubtitleSnapshot)
  }

  func testExplicitStopAndShutdownCancelPendingMeterRefreshes() async throws {
    let stopHarness = makeHarness()
    let stopGate = installMeterRefreshGate(on: stopHarness.model)
    let stoppedRunID = UUID()
    beginThrottledCapture(stopHarness.model, runID: stoppedRunID)
    updateMeter(stopHarness.model, runID: stoppedRunID, levels: [0.3])
    let stoppedTask = try XCTUnwrap(stopHarness.model.voice.pendingLiveSubtitleMeterRefreshTask)
    await stopGate.waitUntilScheduled()

    stopHarness.model.markLiveAudioRunStoppedByUser(runID: stoppedRunID)
    XCTAssertTrue(stoppedTask.isCancelled)
    await stopGate.releaseAll()
    await stoppedTask.value
    XCTAssertNil(stopHarness.model.voice.currentCaptureLiveSubtitleSnapshot)

    let shutdownHarness = makeHarness()
    let shutdownGate = installMeterRefreshGate(on: shutdownHarness.model)
    let shutdownRunID = UUID()
    beginThrottledCapture(shutdownHarness.model, runID: shutdownRunID)
    updateMeter(shutdownHarness.model, runID: shutdownRunID, levels: [0.7])
    let shutdownTask = try XCTUnwrap(
      shutdownHarness.model.voice.pendingLiveSubtitleMeterRefreshTask
    )
    await shutdownGate.waitUntilScheduled()

    await shutdownHarness.model.drainAndStopEventListenerForApplicationShutdown()
    XCTAssertTrue(shutdownTask.isCancelled)
    await shutdownGate.releaseAll()
    await shutdownTask.value

    XCTAssertNil(shutdownHarness.model.voice.currentCaptureLiveSubtitleSnapshot)
    XCTAssertNil(shutdownHarness.model.voice.liveSubtitleSnapshot)
    XCTAssertNil(shutdownHarness.model.voice.pendingLiveSubtitleMeterSnapshot)
  }

  private func installMeterRefreshGate(on model: AppModel) -> LiveSubtitleMeterRefreshGate {
    let gate = LiveSubtitleMeterRefreshGate()
    model.voice.waitForLiveSubtitleMeterRefresh = { _ in
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

@MainActor
struct LiveSubtitleHideTests {
  @Test func preparationHidesOnlyAfterItsTimerCompletes() async throws {
    let app = makeHarness().model
    let gate = LiveSubtitleMeterRefreshGate()
    app.voice.waitForLiveSubtitleHide = { _ in await gate.wait() }
    app.handle(.liveSubtitleUpdated(.init(runID: UUID(), phase: .preparing)))
    let task = try #require(app.voice.pendingLiveSubtitleHideTask)
    await gate.waitUntilScheduled()
    #expect(app.voice.liveSubtitleSnapshot?.phase == .preparing)
    await gate.releaseAll()
    await task.value
    #expect(app.voice.liveSubtitleSnapshot == nil)
  }

  @Test func cancelledHideCannotEraseSameRunRecording() async throws {
    let app = makeHarness().model
    let gate = LiveSubtitleMeterRefreshGate()
    app.voice.waitForLiveSubtitleHide = { _ in await gate.wait() }
    let runID = UUID()
    app.handle(.liveSubtitleUpdated(.init(runID: runID, phase: .preparing)))
    let task = try #require(app.voice.pendingLiveSubtitleHideTask)
    await gate.waitUntilScheduled()
    app.handle(.liveSubtitleUpdated(.init(runID: runID, phase: .recording)))
    #expect(task.isCancelled)
    await gate.releaseAll()
    await task.value
    #expect(app.voice.liveSubtitleSnapshot?.phase == .recording)
    #expect(app.voice.liveSubtitleSnapshot?.runID == runID)
  }

  @Test func shutdownClosesPanelBeforeCancellingHideAndRejectsLateUpdates() async throws {
    let app = makeHarness().model
    let gate = LiveSubtitleMeterRefreshGate()
    app.voice.waitForLiveSubtitleHide = { _ in await gate.wait() }
    app.handle(.liveSubtitleUpdated(.init(runID: UUID(), phase: .preparing)))
    let task = try #require(app.voice.pendingLiveSubtitleHideTask)
    await gate.waitUntilScheduled()
    var panelUpdates: [LiveSubtitleSnapshot?] = []
    app.voice.installLiveSubtitlePanelAction { snapshot, _ in panelUpdates.append(snapshot) }
    #expect(panelUpdates.count == 1)
    #expect(panelUpdates[0]?.phase == .preparing)
    app.beginApplicationShutdown()
    #expect(task.isCancelled)
    #expect(app.voice.currentCaptureLiveSubtitleSnapshot == nil)
    #expect(app.voice.liveSubtitleSnapshot == nil)
    #expect(panelUpdates.count == 2)
    #expect(panelUpdates[1] == nil)
    app.voice.applyLiveSubtitleUpdate(.init(runID: UUID(), phase: .recording))
    app.voice.refreshLiveSubtitlePresentation()
    await gate.releaseAll()
    await task.value
    #expect(app.voice.liveSubtitleSnapshot == nil)
    #expect(panelUpdates.dropFirst().allSatisfy { $0 == nil })
  }
}
