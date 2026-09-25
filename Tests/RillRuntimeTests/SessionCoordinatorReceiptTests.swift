@testable import RillKnowledge
@testable import RillRecords
@testable import RillWorkflows
@testable import RillCore
import RillDomainTestSupport
import Foundation
import XCTest

private struct ReceiptContextProvider: ContextProvider {
    func captureContext() async -> ContextSnapshot { .empty }
}

private struct ReceiptRecognizer: SpeechRecognizer {
    let id = "receipt.recognizer"

    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        RecognitionResult(rawText: "private input", bestText: "private input")
    }
}

private actor ReceiptActionProbe {
    private var actionIDs: [String] = []

    func record(_ actionID: String) {
        actionIDs.append(actionID)
    }

    func snapshot() -> [String] {
        actionIDs
    }
}

private struct ReceiptResultAction: OutputAction {
    let id: String
    let result: ActionResult
    let probe: ReceiptActionProbe

    func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
        _ = try record.requireText(for: id)
        await probe.record(id)
        return result
    }
}

private struct ReceiptActionError: Error, LocalizedError {
    var errorDescription: String? { "PRIVATE-THROWN-ACTION-ERROR" }
}

private struct ReceiptThrowingAction: OutputAction {
    let id: String
    let probe: ReceiptActionProbe

    func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
        _ = try record.requireText(for: id)
        await probe.record(id)
        throw ReceiptActionError()
    }
}

private struct ReceiptCancellingAction: OutputAction {
    let id: String
    let probe: ReceiptActionProbe

    func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
        _ = try record.requireText(for: id)
        await probe.record(id)
        throw CancellationError()
    }
}

private actor ReceiptBlockingGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStarted() -> Bool { started }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private struct ReceiptBlockingAction: OutputAction {
    let id: String
    let gate: ReceiptBlockingGate
    let probe: ReceiptActionProbe

    func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
        _ = try record.requireText(for: id)
        await probe.record(id)
        await gate.wait()
        return .injected
    }
}

private struct ReceiptRepositoryPrivateError: Error {}

private actor InsertFailingReceiptRepository: WorkflowRunReceiptRepository {
    func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration { .initial }
    func insertTerminal(_ value: WorkflowRunReceipt, generation: RunHistoryWriteGeneration) async throws {
        guard generation == .initial else { throw WorkflowRunReceiptRepositoryError.writeObsoletedByClearBarrier(runID: value.runID) }
        try await (self as any WorkflowRunReceiptRepository).insertTerminal(value)
    }

    func insertTerminal(_ receipt: WorkflowRunReceipt) async throws {
        throw ReceiptRepositoryPrivateError()
    }

    func receipts(matching query: WorkflowRunReceiptQuery) async throws -> [WorkflowRunReceipt] {
        []
    }

    func deleteReceipts(olderThan cutoff: Date) async throws -> Int { 0 }
    func deleteAllReceipts() async throws -> Int { 0 }
}

private actor ClearBarrierRejectingReceiptRepository: WorkflowRunReceiptRepository {
    func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration { .initial }
    func insertTerminal(_ value: WorkflowRunReceipt, generation: RunHistoryWriteGeneration) async throws {
        guard generation == .initial else { throw WorkflowRunReceiptRepositoryError.writeObsoletedByClearBarrier(runID: value.runID) }
        try await (self as any WorkflowRunReceiptRepository).insertTerminal(value)
    }

    private var insertAttempts = 0

    func insertTerminal(_ receipt: WorkflowRunReceipt) async throws {
        insertAttempts += 1
        throw WorkflowRunReceiptRepositoryError.writeObsoletedByClearBarrier(
            runID: receipt.runID
        )
    }

    func receipts(matching query: WorkflowRunReceiptQuery) async throws -> [WorkflowRunReceipt] {
        []
    }

    func deleteReceipts(olderThan cutoff: Date) async throws -> Int { 0 }
    func deleteAllReceipts() async throws -> Int { 0 }

    func attemptCount() -> Int { insertAttempts }
}

final class SessionCoordinatorReceiptTests: XCTestCase {
    func testNormalRunUsesActualTriggerAndDefaultsMissingEventToManual() async throws {
        let eventBus = EventBus()
        let repository = InMemoryWorkflowRunReceiptRepository()
        let probe = ReceiptActionProbe()
        let coordinator = makeCoordinator(
            actions: [
                ReceiptResultAction(
                    id: "receipt.copy",
                    result: .copiedToClipboard,
                    probe: probe
                ),
            ],
            eventBus: eventBus,
            repository: repository
        )
        let workflow = makeWorkflow(actionIDs: ["receipt.copy"])
        let menuBarRunID = UUID()
        let manualRunID = UUID()

        _ = await coordinator.runReportingOutcome(
            workflow: workflow,
            runID: menuBarRunID,
            triggerEvent: WorkflowTriggerEvent(
                binding: .menuBar,
                workflowID: workflow.id,
                sourceID: "PRIVATE-SOURCE-ID"
            ),
            contextSnapshot: .empty
        )
        _ = await coordinator.runReportingOutcome(
            workflow: workflow,
            runID: manualRunID,
            contextSnapshot: .empty
        )

        let menuBarReceipts = try await repository.receipts(
            matching: .init(runID: menuBarRunID)
        )
        let manualReceipts = try await repository.receipts(
            matching: .init(runID: manualRunID)
        )
        let menuBarReceipt = try XCTUnwrap(menuBarReceipts.first)
        let manualReceipt = try XCTUnwrap(manualReceipts.first)
        XCTAssertEqual(menuBarReceipt.trigger, .menuBar)
        XCTAssertEqual(menuBarReceipt.termination, .completed)
        XCTAssertEqual(menuBarReceipt.actionDetails.map(\.result), [.copiedToClipboard])
        XCTAssertEqual(manualReceipt.trigger, .manual)
        XCTAssertEqual(manualReceipt.termination, .completed)
    }

    func testActionResultsProduceFailedPartialAndSkippedTerminalReceipts() async throws {
        let eventBus = EventBus()
        let repository = InMemoryWorkflowRunReceiptRepository()
        let probe = ReceiptActionProbe()
        let coordinator = makeCoordinator(
            actions: [
                ReceiptResultAction(id: "success", result: .injected, probe: probe),
                ReceiptResultAction(id: "failure", result: .failed("PRIVATE-FAILURE"), probe: probe),
                ReceiptResultAction(id: "skip.one", result: .skipped("PRIVATE-SKIP"), probe: probe),
                ReceiptResultAction(id: "skip.two", result: .skipped("PRIVATE-SKIP"), probe: probe),
                ReceiptResultAction(id: "must.not.run", result: .injected, probe: probe),
            ],
            eventBus: eventBus,
            repository: repository
        )
        let partialRunID = UUID()
        let failedRunID = UUID()
        let skippedRunID = UUID()
        let mixedRunID = UUID()

        let partialResult = await coordinator.runReportingOutcome(
            workflow: makeWorkflow(actionIDs: ["success", "failure", "must.not.run"]),
            runID: partialRunID,
            contextSnapshot: .empty
        )
        let failedResult = await coordinator.runReportingOutcome(
            workflow: makeWorkflow(actionIDs: ["failure", "must.not.run"]),
            runID: failedRunID,
            contextSnapshot: .empty
        )
        _ = await coordinator.runReportingOutcome(
            workflow: makeWorkflow(actionIDs: ["skip.one", "skip.two"]),
            runID: skippedRunID,
            contextSnapshot: .empty
        )
        _ = await coordinator.runReportingOutcome(
            workflow: makeWorkflow(actionIDs: ["success", "skip.one"]),
            runID: mixedRunID,
            contextSnapshot: .empty
        )

        guard case .failed = partialResult, case .failed = failedResult else {
            return XCTFail("Returned action failures must fail the execution lifecycle.")
        }
        let partial = try await receipt(runID: partialRunID, repository: repository)
        let failed = try await receipt(runID: failedRunID, repository: repository)
        let skipped = try await receipt(runID: skippedRunID, repository: repository)
        let mixed = try await receipt(runID: mixedRunID, repository: repository)
        XCTAssertEqual(partial.termination, .partiallyCompleted(code: .processing))
        XCTAssertEqual(partial.actionDetails.map(\.result), [.injected, .failed])
        XCTAssertEqual(
            failed.termination,
            .failed(stage: .delivering, code: .processing)
        )
        XCTAssertEqual(failed.actionDetails.map(\.result), [.failed])
        XCTAssertEqual(skipped.termination, .skipped(reason: .allActionsSkipped))
        XCTAssertEqual(skipped.actionDetails.map(\.result), [.skipped, .skipped])
        XCTAssertEqual(mixed.termination, .partiallyCompleted(code: .processing))
        XCTAssertEqual(mixed.actionDetails.map(\.result), [.injected, .skipped])

        let executed = await probe.snapshot()
        XCTAssertEqual(
            executed,
            ["success", "failure", "failure", "skip.one", "skip.two", "success", "skip.one"]
        )
    }

    func testThrownActionIsRecordedAsFixedFailedResult() async throws {
        let eventBus = EventBus()
        let repository = InMemoryWorkflowRunReceiptRepository()
        let probe = ReceiptActionProbe()
        let coordinator = makeCoordinator(
            actions: [ReceiptThrowingAction(id: "throwing", probe: probe)],
            eventBus: eventBus,
            repository: repository
        )
        let runID = UUID()

        let result = await coordinator.runReportingOutcome(
            workflow: makeWorkflow(actionIDs: ["throwing"]),
            runID: runID,
            contextSnapshot: .empty
        )
        guard case .failed = result else { return XCTFail("Expected action throw to fail.") }

        let receipt = try await receipt(runID: runID, repository: repository)
        XCTAssertEqual(receipt.actionDetails.map(\.result), [.failed])
        XCTAssertEqual(
            receipt.termination,
            .failed(stage: .delivering, code: .processing)
        )
        XCTAssertFalse(String(describing: receipt).contains("PRIVATE-THROWN-ACTION-ERROR"))
    }

    func testFirstActionCancellationProducesCancelledOutcomeWithoutFailureSignals() async throws {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let repository = InMemoryWorkflowRunReceiptRepository()
        let probe = ReceiptActionProbe()
        let coordinator = makeCoordinator(
            actions: [
                ReceiptCancellingAction(id: "cancel", probe: probe),
                ReceiptResultAction(id: "must.not.run", result: .injected, probe: probe),
            ],
            eventBus: eventBus,
            repository: repository,
            diagnostics: diagnostics
        )
        let runID = UUID()
        let stream = await eventBus.stream()
        let lifecycle = Task { () -> [RillEvent] in
            var events: [RillEvent] = []
            for await event in stream {
                events.append(event)
                if case .runCancelled(let summary) = event, summary.runID == runID {
                    return events
                }
            }
            return events
        }
        await Task.yield()

        let result = await coordinator.runReportingOutcome(
            workflow: makeWorkflow(actionIDs: ["cancel", "must.not.run"]),
            runID: runID,
            contextSnapshot: .empty
        )
        let published = await lifecycle.value
        let expectedCancellation = WorkflowRunCancelledSummary(
            runID: runID,
            stage: .delivering,
            wasPartiallyCompleted: false
        )

        XCTAssertEqual(result, .cancelled(expectedCancellation))
        let storedReceipt = try await receipt(runID: runID, repository: repository)
        let executedActionIDs = await probe.snapshot()
        let finalState = await coordinator.currentState()
        XCTAssertEqual(storedReceipt.termination, .cancelled(stage: .delivering))
        XCTAssertEqual(storedReceipt.actionDetails.map(\.result), [.cancelled])
        XCTAssertEqual(executedActionIDs, ["cancel"])
        XCTAssertEqual(finalState, .idle)
        XCTAssertTrue(published.contains { $0 == .runCancelled(expectedCancellation) })
        XCTAssertFalse(published.contains { event in
            if case .runFailed = event { return true }
            return false
        })
        let recordedDiagnostics = await diagnostics.snapshot()
        XCTAssertTrue(recordedDiagnostics.contains { event in
            event.event == "session.cancelled"
                && event.level == .info
                && event.metadata["stage"] == "delivering"
                && event.metadata["outcome"] == "cancelled"
        })
        XCTAssertFalse(recordedDiagnostics.contains { $0.event == "session.failure" })
        XCTAssertFalse(recordedDiagnostics.contains { event in
            event.event == "session.action" && event.metadata["resultCode"] == "failed"
        })
        XCTAssertFalse(recordedDiagnostics.contains { event in
            event.event == "session.stage" && event.metadata["stage"] == "failed"
        })
    }

    func testCancellationAfterSuccessfulActionProducesPartialCancelledOutcome() async throws {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let repository = InMemoryWorkflowRunReceiptRepository()
        let probe = ReceiptActionProbe()
        let coordinator = makeCoordinator(
            actions: [
                ReceiptResultAction(id: "success", result: .injected, probe: probe),
                ReceiptCancellingAction(id: "cancel", probe: probe),
                ReceiptResultAction(id: "must.not.run", result: .injected, probe: probe),
            ],
            eventBus: eventBus,
            repository: repository,
            diagnostics: diagnostics
        )
        let runID = UUID()
        let stream = await eventBus.stream()
        let lifecycle = Task { () -> [RillEvent] in
            var events: [RillEvent] = []
            for await event in stream {
                events.append(event)
                if case .runCancelled(let summary) = event, summary.runID == runID {
                    return events
                }
            }
            return events
        }
        await Task.yield()

        let result = await coordinator.runReportingOutcome(
            workflow: makeWorkflow(actionIDs: ["success", "cancel", "must.not.run"]),
            runID: runID,
            contextSnapshot: .empty
        )
        let published = await lifecycle.value
        let expectedCancellation = WorkflowRunCancelledSummary(
            runID: runID,
            stage: .delivering,
            wasPartiallyCompleted: true
        )

        XCTAssertEqual(result, .cancelled(expectedCancellation))
        let storedReceipt = try await receipt(runID: runID, repository: repository)
        let executedActionIDs = await probe.snapshot()
        let finalState = await coordinator.currentState()
        XCTAssertEqual(storedReceipt.termination, .partiallyCompleted(code: .cancelled))
        XCTAssertEqual(storedReceipt.actionDetails.map(\.result), [.injected, .cancelled])
        XCTAssertEqual(executedActionIDs, ["success", "cancel"])
        XCTAssertEqual(finalState, .idle)
        XCTAssertFalse(published.contains { event in
            if case .runFailed = event { return true }
            return false
        })
        let recordedDiagnostics = await diagnostics.snapshot()
        XCTAssertTrue(recordedDiagnostics.contains { event in
            event.event == "session.cancelled" && event.metadata["outcome"] == "partial"
        })
        XCTAssertFalse(recordedDiagnostics.contains { $0.event == "session.failure" })
        XCTAssertFalse(recordedDiagnostics.contains { event in
            event.event == "session.stage" && event.metadata["stage"] == "failed"
        })
    }


    func testDirectStackCancellationReturnsLeaseWithoutFailureSignals() async throws {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let repository = InMemoryWorkflowRunReceiptRepository()
        let recordStore = RecordStore()
        let probe = ReceiptActionProbe()
        let coordinator = makeCoordinator(
            actions: [ReceiptCancellingAction(id: "cancel", probe: probe)],
            eventBus: eventBus,
            repository: repository,
            diagnostics: diagnostics,
            recordStore: recordStore
        )
        let inserted = try await recordStore.ingest(
            RecordDraft(
                payload: .text("stack cancellation"),
                provenance: .init(source: .init(kind: .workflow))
            ),
            into: [RecordCollection.inboxID]
        )
        let stream = await eventBus.stream()
        let lifecycle = Task { () -> (WorkflowRunCancelledSummary?, [RillEvent]) in
            var events: [RillEvent] = []
            for await event in stream {
                events.append(event)
                if case .runCancelled(let summary) = event {
                    return (summary, events)
                }
            }
            return (nil, events)
        }
        await Task.yield()

        await coordinator.deliverNextRecord(actionID: "cancel")
        let (cancellation, published) = await lifecycle.value

        XCTAssertEqual(cancellation?.stage, .delivering)
        XCTAssertEqual(cancellation?.wasPartiallyCompleted, false)
        let storedItem = try await recordStore.record(id: inserted.id)
        let finalState = await coordinator.currentState()
        XCTAssertEqual(storedItem?.activity.useCount, 0)
        XCTAssertNil(storedItem?.activity.lastDeliveredAt)
        XCTAssertNil(storedItem?.activity.latestFailure)
        XCTAssertEqual(storedItem?.memberships.first?.state, .active)
        XCTAssertEqual(finalState, .idle)
        let receipts = try await repository.receipts(matching: .all)
        let storedReceipt = try XCTUnwrap(receipts.first { $0.trigger == .recordDelivery })
        XCTAssertEqual(storedReceipt.termination, .cancelled(stage: .delivering))
        XCTAssertEqual(storedReceipt.actionDetails.map(\.result), [.cancelled])
        XCTAssertFalse(published.contains { event in
            if case .runFailed = event { return true }
            return false
        })
        let recordedDiagnostics = await diagnostics.snapshot()
        XCTAssertTrue(recordedDiagnostics.contains { $0.event == "session.cancelled" })
        XCTAssertFalse(recordedDiagnostics.contains { $0.event == "session.failure" })
        XCTAssertFalse(recordedDiagnostics.contains { event in
            event.event == "session.stage" && event.metadata["stage"] == "failed"
        })
    }


    func testDuplicateRunIDBlocksBeforeASecondAction() async throws {
        let eventBus = EventBus()
        let repository = InMemoryWorkflowRunReceiptRepository()
        let probe = ReceiptActionProbe()
        let coordinator = makeCoordinator(
            actions: [ReceiptResultAction(id: "success", result: .injected, probe: probe)],
            eventBus: eventBus,
            repository: repository
        )
        let workflow = makeWorkflow(actionIDs: ["success"])
        let runID = UUID()

        _ = await coordinator.runReportingOutcome(
            workflow: workflow,
            runID: runID,
            contextSnapshot: .empty
        )
        let duplicate = await coordinator.runReportingOutcome(
            workflow: workflow,
            runID: runID,
            contextSnapshot: .empty
        )

        guard case .failed(let failure) = duplicate else {
            return XCTFail("Expected duplicate run ID to be rejected.")
        }
        XCTAssertEqual(failure.code, .busy)
        let actions = await probe.snapshot()
        let receipts = try await repository.receipts(matching: .init(runID: runID))
        XCTAssertEqual(actions, ["success"])
        XCTAssertEqual(receipts.count, 1)
    }

    func testBusyUnsupportedAndMissingContextProduceTerminalReceipts() async throws {
        let eventBus = EventBus()
        let repository = InMemoryWorkflowRunReceiptRepository()
        let probe = ReceiptActionProbe()
        let gate = ReceiptBlockingGate()
        let coordinator = makeCoordinator(
            actions: [ReceiptBlockingAction(id: "blocking", gate: gate, probe: probe)],
            eventBus: eventBus,
            repository: repository
        )
        let workflow = makeWorkflow(actionIDs: ["blocking"])
        let activeRunID = UUID()
        let busyRunID = UUID()
        let activeTask = Task {
            await coordinator.runReportingOutcome(
                workflow: workflow,
                runID: activeRunID,
                contextSnapshot: .empty
            )
        }
        for _ in 0..<200 {
            if await gate.hasStarted() { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let actionStarted = await gate.hasStarted()
        XCTAssertTrue(actionStarted)

        _ = await coordinator.runReportingOutcome(
            workflow: workflow,
            runID: busyRunID,
            contextSnapshot: .empty
        )
        await gate.resume()
        _ = await activeTask.value

        let unsupportedRunID = UUID()
        var unsupportedWorkflow = makeWorkflow(actionIDs: ["blocking"])
        unsupportedWorkflow.metadata["eventType"] = "groupItemCreated"
        _ = await coordinator.runReportingOutcome(
            workflow: unsupportedWorkflow,
            runID: unsupportedRunID,
            contextSnapshot: .empty
        )
        let missingContextResult = await coordinator.runReportingOutcome(
            workflow: makeWorkflow(actionIDs: ["blocking"])
        )
        guard case .failed(let missingContextFailure) = missingContextResult,
              let missingContextRunID = missingContextFailure.runID else {
            return XCTFail("Missing context must allocate an attempt run ID.")
        }

        let busyReceipt = try await receipt(runID: busyRunID, repository: repository)
        let unsupportedReceipt = try await receipt(
            runID: unsupportedRunID,
            repository: repository
        )
        let missingContextReceipt = try await receipt(
            runID: missingContextRunID,
            repository: repository
        )
        XCTAssertEqual(busyReceipt.termination, .skipped(reason: .busy))
        XCTAssertEqual(unsupportedReceipt.termination, .skipped(reason: .unsupported))
        XCTAssertEqual(
            missingContextReceipt.termination,
            .failed(stage: .preparing, code: .configuration)
        )
    }


    func testReceiptPersistenceFailureDoesNotReverseSuccessfulLifecycle() async throws {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let repository = InsertFailingReceiptRepository()
        let recorder = WorkflowRunReceiptRecorder(
            repository: repository,
            eventBus: eventBus,
            diagnostics: diagnostics
        )
        let probe = ReceiptActionProbe()
        let coordinator = makeCoordinator(
            actions: [ReceiptResultAction(id: "success", result: .injected, probe: probe)],
            eventBus: eventBus,
            repository: repository,
            diagnostics: diagnostics,
            recorder: recorder
        )

        let result = await coordinator.runReportingOutcome(
            workflow: makeWorkflow(actionIDs: ["success"]),
            contextSnapshot: .empty
        )

        guard case .completed = result else {
            return XCTFail("Receipt persistence must not reverse a successful action.")
        }
        let actions = await probe.snapshot()
        XCTAssertEqual(actions, ["success"])
        let events = await diagnostics.snapshot()
        XCTAssertTrue(events.contains { $0.event == "run-receipt.persistence.failed" })
        XCTAssertFalse(events.contains { event in
            event.event == "session.failure"
        })
    }

    func testClearBarrierReceiptRejectionIsSilentAndDoesNotCreateDeadLetter() async throws {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let repository = ClearBarrierRejectingReceiptRepository()
        let recorder = WorkflowRunReceiptRecorder(
            repository: repository,
            eventBus: eventBus,
            diagnostics: diagnostics
        )
        let probe = ReceiptActionProbe()
        let coordinator = makeCoordinator(
            actions: [ReceiptResultAction(id: "success", result: .injected, probe: probe)],
            eventBus: eventBus,
            repository: repository,
            diagnostics: diagnostics,
            recorder: recorder
        )
        let stream = await eventBus.stream()
        let lifecycle = Task { () -> [RillEvent] in
            var events: [RillEvent] = []
            for await event in stream {
                events.append(event)
                if case .runCompleted = event { return events }
            }
            return events
        }
        await Task.yield()

        let result = await coordinator.runReportingOutcome(
            workflow: makeWorkflow(actionIDs: ["success"]),
            contextSnapshot: .empty
        )
        let published = await lifecycle.value

        guard case .completed = result else {
            return XCTFail("A clear barrier must not redefine successful execution.")
        }
        let insertAttemptCount = await repository.attemptCount()
        let failedTerminalCount = await recorder.rememberedFailedTerminalCount()
        let pendingRunCount = await recorder.pendingRunCount()
        XCTAssertEqual(insertAttemptCount, 1)
        XCTAssertEqual(failedTerminalCount, 0)
        XCTAssertEqual(pendingRunCount, 0)
        XCTAssertFalse(published.contains { event in
            if case .runReceiptRepositoryChanged = event { return true }
            return false
        })
        let recordedDiagnostics = await diagnostics.snapshot()
        XCTAssertFalse(recordedDiagnostics.contains { event in
            event.event == "run-receipt.coordination.failed"
                || event.event == "run-receipt.persistence.failed"
        })
    }

    private func makeCoordinator(
        actions: [any OutputAction],
        eventBus: EventBus,
        repository: any WorkflowRunReceiptRepository,
        diagnostics: DiagnosticsRecorder? = nil,
        recordStore: RecordStore? = nil,
        recorder providedRecorder: WorkflowRunReceiptRecorder? = nil
    ) -> SessionCoordinator {
        let recorder = providedRecorder ?? WorkflowRunReceiptRecorder(
            repository: repository,
            eventBus: eventBus,
            diagnostics: diagnostics
        )
        return makeTestSessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: [ReceiptRecognizer()]),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: actions),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            recordStore: recordStore ?? RecordStore(),
            eventBus: eventBus,
            diagnostics: diagnostics,
            runReceiptRecorder: recorder
        )
    }

    private func makeWorkflow(actionIDs: [String]) -> WorkflowDefinition {
        WorkflowDefinition(
            name: "Private workflow name",
            pipeline: PipelineDeclaration(
                recognizerID: "receipt.recognizer",
                outputActions: actionIDs.map { OutputActionReference(id: $0) },
                uncertaintyPolicy: .init(mode: .off),
                deliveryPolicy: .init(strategy: .immediate)
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
    }

    private func receipt(
        runID: UUID,
        repository: InMemoryWorkflowRunReceiptRepository
    ) async throws -> WorkflowRunReceipt {
        let receipts = try await repository.receipts(matching: .init(runID: runID))
        return try XCTUnwrap(receipts.first)
    }

}
