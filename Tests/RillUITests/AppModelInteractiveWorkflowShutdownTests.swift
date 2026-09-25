import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
final class AppModelInteractiveWorkflowShutdownTests: XCTestCase {
    func testShutdownCancelsScheduledInteractiveRunBeforeItStarts() async {
        let harness = makeHarness()

        XCTAssertTrue(harness.model.canTriggerWorkflow(harness.workflow))
        harness.model.runWorkflow(harness.workflow)
        await harness.model.stopInteractiveWorkflowRunsForApplicationShutdown()

        let actionCount = await harness.actionLog.snapshot()
        XCTAssertEqual(actionCount, 0)
        XCTAssertTrue(harness.model.isApplicationShuttingDown)
        XCTAssertFalse(harness.model.canTriggerWorkflow(harness.workflow))
        XCTAssertFalse(harness.model.voice.isRunning)
        XCTAssertNil(harness.model.voice.pendingInteractiveWorkflowTask)
    }

    func testShutdownCancelsInteractiveRunBeforeCancellationIgnoringRecognizerCanAct() async {
        let harness = makeHarness(delay: .seconds(30))
        let eventStream = await harness.eventBus.stream()
        let runStarted = Task {
            for await event in eventStream {
                if case .runStarted = event {
                    return
                }
            }
        }

        harness.model.runWorkflow(harness.workflow)
        await runStarted.value

        await harness.model.stopInteractiveWorkflowRunsForApplicationShutdown()

        let actionCount = await harness.actionLog.snapshot()
        XCTAssertEqual(actionCount, 0)
        XCTAssertFalse(harness.model.voice.isRunning)
        XCTAssertNil(harness.model.voice.pendingInteractiveWorkflowTask)

        harness.model.runWorkflow(harness.workflow)
        await Task.yield()
        let actionCountAfterRejectedRun = await harness.actionLog.snapshot()
        XCTAssertEqual(actionCountAfterRejectedRun, 0)
        XCTAssertFalse(harness.model.voice.isRunning)
    }
}
