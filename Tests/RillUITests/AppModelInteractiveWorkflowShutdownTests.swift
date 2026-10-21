import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
final class AppModelInteractiveWorkflowShutdownTests: XCTestCase {
  func testShutdownCancelsScheduledInteractiveRunBeforeItStarts() async {
    let harness = makeHarness()

    XCTAssertTrue(harness.model.canTriggerWorkflow(harness.workflow))
    harness.model.runWorkflowText("hello", workflow: harness.workflow)
    await harness.model.stopInteractiveWorkflowRunsForApplicationShutdown()

    let actionCount = await harness.actionLog.snapshot()
    XCTAssertEqual(actionCount, 0)
    XCTAssertTrue(harness.model.isApplicationShuttingDown)
    XCTAssertFalse(harness.model.canTriggerWorkflow(harness.workflow))
    XCTAssertFalse(harness.model.voice.isRunning)
    XCTAssertNil(harness.model.voice.pendingInteractiveWorkflowTask)
  }

  func testShutdownDrainsCancellationIgnoringCaptureStartBeforeItCanAct() async {
    let gate = WorkflowAudioStartGate()
    let log = ProbeActionLog()
    let harness = makeHarness(startWorkflowAudioRunAction: { _, _, _ in
      try await gate.suspendStart()
      try Task.checkCancellation()
      await log.increment()
    })
    await harness.model.waitForInitialVoiceConfiguration()
    guard harness.model.canTriggerWorkflow(harness.workflow) else { return XCTFail("The capture fixture must be runnable.") }
    XCTAssertTrue(harness.model.runWorkflow(harness.workflow))
    await gate.waitUntilStarted()
    let shutdown = Task { await harness.model.stopInteractiveWorkflowRunsForApplicationShutdown() }
    while !harness.model.isApplicationShuttingDown { await Task.yield() }
    await gate.succeed()
    await shutdown.value
    let actionCount = await log.snapshot()
    XCTAssertEqual(actionCount, 0)
    XCTAssertFalse(harness.model.voice.isRunning)
    XCTAssertTrue(harness.model.voice.workflowAudioActionTasks.isEmpty)
    XCTAssertFalse(harness.model.runWorkflow(harness.workflow))
    await harness.model.waitForWorkflowAudioActions()
    XCTAssertFalse(harness.model.voice.isRunning)
  }
}
