import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
final class AppModelLiveAudioStopTests: XCTestCase {
    func testHiddenCaptureMovesAutomaticEndpointFromRecordingToTranscribing() {
        let harness = makeHarness()
        let runID = UUID()
        let workflowID = UUID()
        beginManualCapture(harness.model, runID: runID, workflowID: workflowID)

        hideManualCapture(harness.model, runID: runID)

        XCTAssertEqual(
            harness.model.workflowAudioRunState,
            .transcribing(workflowID: workflowID)
        )
        XCTAssertNil(harness.model.currentCaptureLiveSubtitleSnapshot)
        XCTAssertEqual(harness.model.workflowAudioCaptureRunID, runID)
    }

    func testMatchingLiveAuthorizationFailureClearsManualRecordingState() {
        let harness = makeHarness()
        let runID = UUID()
        beginManualCapture(harness.model, runID: runID, providerID: "deepgram.live")

        harness.model.handle(
            .runFailed(
                runID: runID,
                workflow: nil,
                message: "The live recording stopped because its privacy authorization changed."
            )
        )

        XCTAssertFalse(harness.model.isRunning)
        XCTAssertEqual(harness.model.workflowAudioRunState, .idle)
        XCTAssertNil(harness.model.workflowAudioCaptureRunID)
    }

    func testCaptureStartFailureClearsIdentityBoundDuringPreparation() async {
        let startGate = WorkflowAudioStartGate()
        let workflow = makeCapturedAudioWorkflow()
        let harness = makeHarness(
            workflow: workflow,
            startWorkflowAudioRunAction: { _, _ in
                try await startGate.suspendStart()
            }
        )

        harness.model.runWorkflow(workflow)
        await startGate.waitUntilStarted()
        let runID = UUID()
        harness.model.handle(
            .liveSubtitleUpdated(
                LiveSubtitleSnapshot(runID: runID, phase: .preparing)
            )
        )
        XCTAssertEqual(harness.model.workflowAudioCaptureRunID, runID)

        await startGate.fail(message: "Microphone unavailable")
        await waitForEventProcessing()

        XCTAssertFalse(harness.model.isRunning)
        XCTAssertEqual(harness.model.workflowAudioRunState, .idle)
        XCTAssertNil(harness.model.workflowAudioCaptureRunID)
    }

    func testCaptureFinishFailureClearsBoundIdentity() async {
        let workflow = makeCapturedAudioWorkflow()
        let harness = makeHarness(
            workflow: workflow,
            finishWorkflowAudioRunAction: {
                throw TestError.captureFinishFailed
            }
        )
        let runID = UUID()
        beginManualCapture(
            harness.model,
            runID: runID,
            workflowID: workflow.id
        )

        harness.model.runWorkflow(workflow)
        await waitForEventProcessing()

        XCTAssertFalse(harness.model.isRunning)
        XCTAssertEqual(harness.model.workflowAudioRunState, .idle)
        XCTAssertNil(harness.model.workflowAudioCaptureRunID)
    }

    func testInteractiveShutdownClearsBoundCaptureIdentity() async {
        let harness = makeHarness()
        let runID = UUID()
        beginManualCapture(harness.model, runID: runID)

        await harness.model.stopInteractiveWorkflowRunsForApplicationShutdown()

        XCTAssertFalse(harness.model.isRunning)
        XCTAssertEqual(harness.model.workflowAudioRunState, .idle)
        XCTAssertNil(harness.model.workflowAudioCaptureRunID)
    }

    func testMatchingFailureAfterHiddenCaptureClearsManualRunState() {
        let harness = makeHarness()
        let runID = UUID()
        beginManualCapture(harness.model, runID: runID)
        hideManualCapture(harness.model, runID: runID)

        harness.model.handle(
            .runFailed(
                runID: runID,
                workflow: nil,
                message: "No speech was detected before recording timed out."
            )
        )

        XCTAssertFalse(harness.model.isRunning)
        XCTAssertEqual(harness.model.workflowAudioRunState, .idle)
        XCTAssertNil(harness.model.workflowAudioCaptureRunID)
    }

    func testUnrelatedAndUnidentifiedFailuresDoNotClearHiddenManualCapture() {
        let harness = makeHarness()
        let runID = UUID()
        let workflowID = UUID()
        beginManualCapture(harness.model, runID: runID, workflowID: workflowID)
        hideManualCapture(harness.model, runID: runID)

        harness.model.handle(
            .runFailed(runID: UUID(), workflow: nil, message: "Unrelated failure.")
        )
        harness.model.handle(
            .runFailed(runID: nil, workflow: nil, message: "Unidentified failure.")
        )

        XCTAssertTrue(harness.model.isRunning)
        XCTAssertEqual(
            harness.model.workflowAudioRunState,
            .transcribing(workflowID: workflowID)
        )
        XCTAssertEqual(harness.model.workflowAudioCaptureRunID, runID)
    }

    func testMatchingCancellationAfterHiddenCaptureClearsManualRunState() {
        let harness = makeHarness()
        let runID = UUID()
        beginManualCapture(harness.model, runID: runID)
        hideManualCapture(harness.model, runID: runID)

        harness.model.handle(
            .runCancelled(
                WorkflowRunCancelledSummary(
                    runID: runID,
                    stage: .capturingInput,
                    wasPartiallyCompleted: false
                )
            )
        )

        XCTAssertFalse(harness.model.isRunning)
        XCTAssertEqual(harness.model.workflowAudioRunState, .idle)
        XCTAssertNil(harness.model.workflowAudioCaptureRunID)
    }

    func testMatchingCompletionAfterHiddenCaptureClearsManualRunState() {
        let harness = makeHarness()
        let runID = UUID()
        beginManualCapture(
            harness.model,
            runID: runID,
            workflowID: harness.workflow.id
        )
        hideManualCapture(harness.model, runID: runID)

        harness.model.handle(
            .runCompleted(
                WorkflowRunSummary(
                    runID: runID,
                    workflowID: harness.workflow.id,
                    workflow: harness.workflow.presentation,
                    trigger: .manual,
                    finalText: "hello"
                )
            )
        )

        XCTAssertFalse(harness.model.isRunning)
        XCTAssertEqual(harness.model.workflowAudioRunState, .idle)
        XCTAssertNil(harness.model.workflowAudioCaptureRunID)
    }

    func testExplicitStopClearsOnlyMatchingVisibleCapture() {
        let harness = makeHarness()
        let runID = UUID()
        beginManualCapture(harness.model, runID: runID, providerID: "deepgram.live")

        harness.model.markLiveAudioRunStoppedByUser(runID: UUID())

        XCTAssertTrue(harness.model.isRunning)
        XCTAssertEqual(harness.model.liveSubtitleSnapshot?.runID, runID)
        XCTAssertEqual(harness.model.workflowAudioCaptureRunID, runID)

        harness.model.markLiveAudioRunStoppedByUser(runID: runID)

        XCTAssertFalse(harness.model.isRunning)
        XCTAssertNil(harness.model.liveSubtitleSnapshot)
        XCTAssertEqual(harness.model.workflowAudioRunState, .idle)
        XCTAssertNil(harness.model.workflowAudioCaptureRunID)
    }

    private func beginManualCapture(
        _ model: AppModel,
        runID: UUID,
        workflowID: UUID = UUID(),
        providerID: String = "whisperkit.stream"
    ) {
        model.isRunning = true
        model.workflowAudioRunState = .recording(workflowID: workflowID)
        model.handle(
            .liveSubtitleUpdated(
                LiveSubtitleSnapshot(
                    runID: runID,
                    phase: .recording,
                    providerID: providerID
                )
            )
        )
    }

    private func hideManualCapture(_ model: AppModel, runID: UUID) {
        model.handle(
            .liveSubtitleUpdated(
                LiveSubtitleSnapshot(runID: runID, phase: .hidden)
            )
        )
    }

    private func makeCapturedAudioWorkflow() -> WorkflowDefinition {
        WorkflowDefinition(
            name: "Local Dictation",
            pipeline: PipelineDeclaration(
                recognizerID: "sherpa-onnx.local",
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "purple")
        )
    }

    private enum TestError: Error {
        case captureFinishFailed
    }
}
