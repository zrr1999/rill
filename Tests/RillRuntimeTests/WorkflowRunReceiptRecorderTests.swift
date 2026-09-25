
@testable import RillCore
@testable import RillWorkflows
import Foundation
import XCTest
import RillPersistence
@testable import RillCore
@testable import RillWorkflows
@testable import RillRecords
@testable import RillKnowledge

private final class ReceiptTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: UInt64
    private var date: Date

    init(nanoseconds: UInt64 = 0, date: Date = Date(timeIntervalSince1970: 100)) {
        self.nanoseconds = nanoseconds
        self.date = date
    }

    func monotonicNow() -> UInt64 {
        lock.withLock { nanoseconds }
    }

    func wallNow() -> Date {
        lock.withLock { date }
    }

    func setNanoseconds(_ value: UInt64) {
        lock.withLock { nanoseconds = value }
    }

    func advanceNanoseconds(_ value: UInt64) {
        lock.withLock { nanoseconds += value }
    }

    func setDate(_ value: Date) {
        lock.withLock { date = value }
    }
}

private struct ReceiptRepositoryProbeError: Error {
    let privateDescription: String
}

private actor FailOnceWorkflowRunReceiptRepository: WorkflowRunReceiptRepository {
    private var shouldFail = true
    private var stored: [UUID: WorkflowRunReceipt] = [:]
    private let privateErrorCanary: String
    private var generation: RunHistoryWriteGeneration = .initial
    private var lastClearIntentID: UUID?

    init(privateErrorCanary: String) {
        self.privateErrorCanary = privateErrorCanary
    }

    func insertTerminal(_ receipt: WorkflowRunReceipt) async throws {
        try await insertTerminal(receipt, generation: generation)
    }

    func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration {
        generation
    }

    func insertTerminal(
        _ receipt: WorkflowRunReceipt,
        generation writeGeneration: RunHistoryWriteGeneration
    ) async throws {
        if shouldFail {
            shouldFail = false
            throw ReceiptRepositoryProbeError(privateDescription: privateErrorCanary)
        }
        guard writeGeneration == generation else {
            throw WorkflowRunReceiptRepositoryError.writeObsoletedByClearBarrier(
                runID: receipt.runID
            )
        }
        if let existing = stored[receipt.runID], existing != receipt {
            throw WorkflowRunReceiptRepositoryError.conflictingTerminalReceipt(
                runID: receipt.runID
            )
        }
        stored[receipt.runID] = receipt
    }

    func receipts(
        matching query: WorkflowRunReceiptQuery
    ) async throws -> [WorkflowRunReceipt] {
        var values = Array(stored.values)
        if let runID = query.runID {
            values = values.filter { $0.runID == runID }
        }
        return values.sorted { $0.timestamp > $1.timestamp }
    }

    func deleteReceipts(olderThan cutoff: Date) async throws -> Int {
        let originalCount = stored.count
        stored = stored.filter { $0.value.timestamp >= cutoff }
        return originalCount - stored.count
    }

    func deleteAllReceipts() async throws -> Int {
        let count = stored.count
        stored.removeAll()
        return count
    }

    func deleteReceipts(
        obsoletedBy transition: RunHistoryClearTransition,
        preservingLegacyRowsAfter legacyUpperBound: Date?
    ) async throws -> Int {
        if generation == transition.nextGeneration,
           lastClearIntentID == transition.intentID {
            return 0
        }
        guard generation == transition.previousGeneration else {
            throw RunHistoryGenerationError.clearTransitionConflict
        }
        generation = transition.nextGeneration
        lastClearIntentID = transition.intentID
        let count = stored.count
        stored.removeAll()
        return count
    }
}

private actor SuspendedDeadLetterRetryRepository: WorkflowRunReceiptRepository {
    func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration { .initial }
    func insertTerminal(_ value: WorkflowRunReceipt, generation: RunHistoryWriteGeneration) async throws {
        guard generation == .initial else { throw WorkflowRunReceiptRepositoryError.writeObsoletedByClearBarrier(runID: value.runID) }
        try await (self as any WorkflowRunReceiptRepository).insertTerminal(value)
    }

    private var insertCallCount = 0
    private var stored: [UUID: WorkflowRunReceipt] = [:]
    private var retryIsSuspended = false
    private var retryContinuation: CheckedContinuation<Void, Never>?
    private var retrySuspensionWaiters: [CheckedContinuation<Void, Never>] = []

    func insertTerminal(_ receipt: WorkflowRunReceipt) async throws {
        insertCallCount += 1
        if insertCallCount == 1 {
            throw ReceiptRepositoryProbeError(privateDescription: "first-write-fails")
        }
        if insertCallCount == 2 {
            retryIsSuspended = true
            let waiters = retrySuspensionWaiters
            retrySuspensionWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                retryContinuation = continuation
            }
        }
        stored[receipt.runID] = receipt
    }

    func receipts(
        matching query: WorkflowRunReceiptQuery
    ) async throws -> [WorkflowRunReceipt] {
        Array(stored.values)
    }

    func deleteReceipts(olderThan cutoff: Date) async throws -> Int { 0 }
    func deleteAllReceipts() async throws -> Int { 0 }

    func isRetrySuspended() -> Bool { retryIsSuspended }

    func waitUntilRetryIsSuspended() async {
        if retryIsSuspended { return }
        await withCheckedContinuation { continuation in
            retrySuspensionWaiters.append(continuation)
        }
    }

    func releaseRetry() {
        retryContinuation?.resume()
        retryContinuation = nil
    }
}

final class WorkflowRunReceiptRecorderTests: XCTestCase {
    func testRuntimePersistsBodyAndReceiptWithoutPresentationConsumer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLitePersistenceStore(databaseURL: directory.appendingPathComponent("history.sqlite"),
            localDataProtector: AESGCMDataProtector(key: Data(repeating: 7, count: AESGCMDataProtector.keyByteCount)))
        let recorder = WorkflowRunReceiptRecorder(repository: store, eventBus: EventBus())
        let workflow = WorkflowDefinition(name: "Headless voice", pipeline: .init(recognizerID: "test", outputActions: []),
            ui: .init(symbolName: "waveform", accentColorName: "blue"))
        let runID = UUID()
        try await recorder.begin(runID: runID, workflowID: workflow.id, trigger: .hotkey, historyWorkflow: workflow)
        await recorder.recordResult(runID: runID, finalText: "Final text", correctionSource: nil, historyUpdate: nil)
        let receipt = try await recorder.finish(runID: runID, termination: .completed)
        let records = try await store.records(matching: .init(runID: runID))
        let receipts = try await store.receipts(matching: .init(runID: runID))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.finalText, "Final text")
        XCTAssertEqual(records.first?.timestamp.timeIntervalSince1970, receipt.timestamp.timeIntervalSince1970)
        XCTAssertEqual(receipts, [receipt])
    }

    func testRecorderPersistsBeforePublishingAndBoundsOrderedActionDetails() async throws {
        let repository = InMemoryWorkflowRunReceiptRepository()
        let eventBus = EventBus()
        let clock = ReceiptTestClock()
        let recorder = WorkflowRunReceiptRecorder(
            repository: repository,
            eventBus: eventBus,
            wallClock: { clock.wallNow() },
            monotonicClock: { clock.monotonicNow() }
        )
        let runID = UUID()
        let workflowID = UUID()
        try await recorder.begin(runID: runID, workflowID: workflowID, trigger: .hotkey)

        clock.setNanoseconds(100_000_000)
        try await recorder.beginAction(runID: runID, actionIndex: 0)
        clock.setNanoseconds(350_000_000)
        try await recorder.finishAction(
            runID: runID,
            actionIndex: 0,
            result: WorkflowActionResultCode.copiedToClipboard
        )

        for index in 1 ... WorkflowRunReceipt.maximumActionDetails {
            clock.advanceNanoseconds(1)
            try await recorder.beginAction(runID: runID, actionIndex: index)
            clock.advanceNanoseconds(1)
            try await recorder.finishAction(
                runID: runID,
                actionIndex: index,
                result: index == WorkflowRunReceipt.maximumActionDetails
                    ? WorkflowActionResultCode.failed
                    : WorkflowActionResultCode.skipped
            )
        }
        clock.setNanoseconds(1_500_000_000)

        let stream = await eventBus.stream()
        let eventTask = Task { () -> WorkflowRunReceiptRepositoryChange? in
            for await event in stream {
                if case .runReceiptRepositoryChanged(let change) = event {
                    return change
                }
            }
            return nil
        }
        await Task.yield()

        let receipt = try await recorder.finish(
            runID: runID,
            termination: .partiallyCompleted(code: .processing)
        )
        let published = await eventTask.value
        let persisted = try await repository.receipts(matching: .init(runID: runID))

        XCTAssertEqual(persisted, [receipt])
        XCTAssertEqual(
            published,
            WorkflowRunReceiptRepositoryChange(
                runID: receipt.runID,
                terminalTimestamp: receipt.timestamp,
                writeGeneration: .initial
            )
        )
        XCTAssertEqual(receipt.workflowID, workflowID)
        XCTAssertEqual(receipt.trigger, .hotkey)
        XCTAssertEqual(receipt.duration, .s1To4)
        XCTAssertEqual(
            receipt.actionDetails.count,
            WorkflowRunReceipt.maximumActionDetails
        )
        XCTAssertTrue(receipt.detailsTruncated)
        XCTAssertEqual(receipt.actionDetails.first?.actionIndex, 0)
        XCTAssertEqual(receipt.actionDetails.first?.duration, .ms250To999)
        XCTAssertEqual(receipt.actionDetails.last?.actionIndex, 31)
    }

    func testEmptyInputDiscardRetiresIdentityAndCannotEraseOutputReceipts() async throws {
        let repository = InMemoryWorkflowRunReceiptRepository()
        let recorder = WorkflowRunReceiptRecorder(repository: repository)
        let emptyRunID = UUID()
        try await recorder.begin(runID: emptyRunID, workflowID: nil, trigger: .hotkey)
        try await recorder.beginStep(runID: emptyRunID, stepIndex: 0, kind: .recognizeSpeech)
        try await recorder.discardEmptyInput(runID: emptyRunID)
        do {
            try await recorder.begin(runID: emptyRunID, workflowID: nil, trigger: .hotkey)
            XCTFail("Discarded input must remain terminal")
        } catch {
            XCTAssertEqual(error as? WorkflowRunReceiptRecorderError, .terminalAlreadyFinalized(runID: emptyRunID))
        }
        let outputRunID = UUID()
        try await recorder.begin(runID: outputRunID, workflowID: nil, trigger: .hotkey)
        try await recorder.beginAction(runID: outputRunID, actionIndex: 0)
        try await recorder.finishAction(runID: outputRunID, actionIndex: 0, result: WorkflowActionResultCode.injected)
        do {
            try await recorder.discardEmptyInput(runID: outputRunID)
            XCTFail("Committed effects must retain their receipt")
        } catch {
            XCTAssertEqual(error as? WorkflowRunReceiptRecorderError, .cannotDiscardProcessedRun(runID: outputRunID))
        }
        _ = try await recorder.finish(runID: outputRunID, termination: .completed)
        let receipts = try await repository.receipts(matching: .all)
        XCTAssertEqual(receipts.map(\.runID), [outputRunID])
        XCTAssertEqual(receipts.first?.actionDetails.map(\.result), [.injected])
    }

    func testRecorderRejectsOutOfOrderActionsAndASecondTerminal() async throws {
        let repository = InMemoryWorkflowRunReceiptRepository()
        let recorder = WorkflowRunReceiptRecorder(repository: repository)
        let runID = UUID()
        try await recorder.begin(runID: runID, workflowID: nil, trigger: .manual)

        do {
            try await recorder.beginAction(runID: runID, actionIndex: 1)
            XCTFail("Expected out-of-order action start to fail.")
        } catch {
            XCTAssertEqual(
                error as? WorkflowRunReceiptRecorderError,
                .unexpectedActionIndex(expected: 0, actual: 1)
            )
        }

        try await recorder.beginAction(runID: runID, actionIndex: 0)
        do {
            _ = try await recorder.finish(runID: runID, termination: .completed)
            XCTFail("Expected an active action to block terminal finalization.")
        } catch {
            XCTAssertEqual(
                error as? WorkflowRunReceiptRecorderError,
                .terminalWhileActionInProgress(runID: runID)
            )
        }
        do {
            try await recorder.finishAction(
                runID: runID,
                actionIndex: 1,
                result: WorkflowActionResultCode.injected
            )
            XCTFail("Expected a mismatched action completion to fail.")
        } catch {
            XCTAssertEqual(
                error as? WorkflowRunReceiptRecorderError,
                .actionIndexMismatch(expected: 0, actual: 1)
            )
        }
        try await recorder.finishAction(
            runID: runID,
            actionIndex: 0,
            result: WorkflowActionResultCode.injected
        )
        _ = try await recorder.finish(runID: runID, termination: .completed)

        do {
            _ = try await recorder.finish(runID: runID, termination: .completed)
            XCTFail("Expected a second terminal to fail.")
        } catch {
            XCTAssertEqual(
                error as? WorkflowRunReceiptRecorderError,
                .terminalAlreadyFinalized(runID: runID)
            )
        }
        do {
            try await recorder.begin(runID: runID, workflowID: nil, trigger: .manual)
            XCTFail("Expected a finalized run ID to remain unavailable.")
        } catch {
            XCTAssertEqual(
                error as? WorkflowRunReceiptRecorderError,
                .terminalAlreadyFinalized(runID: runID)
            )
        }
    }

    func testClockRegressionProducesUnavailableDurationBuckets() async throws {
        let clock = ReceiptTestClock(nanoseconds: 1_000)
        let repository = InMemoryWorkflowRunReceiptRepository()
        let recorder = WorkflowRunReceiptRecorder(
            repository: repository,
            wallClock: { clock.wallNow() },
            monotonicClock: { clock.monotonicNow() }
        )
        let runID = UUID()
        try await recorder.begin(runID: runID, workflowID: nil, trigger: .manual)
        try await recorder.beginAction(runID: runID, actionIndex: 0)
        clock.setNanoseconds(900)
        try await recorder.finishAction(
            runID: runID,
            actionIndex: 0,
            result: WorkflowActionResultCode.skipped
        )

        let receipt = try await recorder.finish(
            runID: runID,
            termination: .skipped(reason: .allActionsSkipped)
        )

        XCTAssertEqual(receipt.duration, .unavailable)
        XCTAssertEqual(receipt.actionDetails.first?.duration, .unavailable)
    }

    func testFinalizedRunMemoryIsBoundedToRecentRunIDs() async throws {
        let repository = InMemoryWorkflowRunReceiptRepository()
        let recorder = WorkflowRunReceiptRecorder(repository: repository)
        let runIDs = (0 ... WorkflowRunReceiptRecorder.finalizedRunIDCapacity).map { _ in
            UUID()
        }

        for runID in runIDs {
            try await recorder.begin(runID: runID, workflowID: nil, trigger: .manual)
            _ = try await recorder.finish(runID: runID, termination: .completed)
        }

        let rememberedCount = await recorder.rememberedFinalizedRunIDCount()
        XCTAssertEqual(rememberedCount, WorkflowRunReceiptRecorder.finalizedRunIDCapacity)

        // The durable repository remains the final conflict authority after a
        // run ID leaves the recorder's bounded recent set.
        do {
            try await recorder.begin(runID: runIDs[0], workflowID: nil, trigger: .manual)
            XCTFail("Expected the repository to guard an evicted finalized run ID.")
        } catch {
            XCTAssertEqual(
                error as? WorkflowRunReceiptRecorderError,
                .terminalAlreadyFinalized(runID: runIDs[0])
            )
        }
        do {
            try await recorder.begin(
                runID: runIDs[runIDs.count - 1],
                workflowID: nil,
                trigger: .manual
            )
            XCTFail("Expected the most recent finalized run ID to remain guarded.")
        } catch {
            XCTAssertEqual(
                error as? WorkflowRunReceiptRecorderError,
                .terminalAlreadyFinalized(runID: runIDs[runIDs.count - 1])
            )
        }

        let stored = try await repository.receipts(matching: .all)
        XCTAssertEqual(stored.count, runIDs.count)
    }

    func testRecorderRetriesTransientTerminalWriteBeforePublishingRepositoryChange() async throws {
        let repository = FailOnceWorkflowRunReceiptRepository(privateErrorCanary: "private")
        let diagnostics = DiagnosticsRecorder()
        let eventBus = EventBus()
        let recorder = WorkflowRunReceiptRecorder(
            repository: repository,
            eventBus: eventBus,
            diagnostics: diagnostics,
            maximumPersistenceAttempts: 3,
            persistenceRetryDelay: { _ in }
        )
        let runID = UUID()
        try await recorder.begin(runID: runID, workflowID: nil, trigger: .manual)
        let stream = await eventBus.stream()
        let eventTask = Task { () -> WorkflowRunReceiptRepositoryChange? in
            for await event in stream {
                if case .runReceiptRepositoryChanged(let change) = event {
                    return change
                }
            }
            return nil
        }
        await Task.yield()

        let receipt = try await recorder.finish(runID: runID, termination: .completed)
        let published = await eventTask.value
        let persisted = try await repository.receipts(matching: .init(runID: runID))
        let pendingCount = await recorder.pendingRunCount()
        let failedCount = await recorder.rememberedFailedTerminalCount()
        let recordedDiagnostics = await diagnostics.snapshot()

        XCTAssertEqual(
            published,
            WorkflowRunReceiptRepositoryChange(
                runID: receipt.runID,
                terminalTimestamp: receipt.timestamp,
                writeGeneration: .initial
            )
        )
        XCTAssertEqual(persisted, [receipt])
        XCTAssertEqual(pendingCount, 0)
        XCTAssertEqual(failedCount, 0)
        XCTAssertTrue(recordedDiagnostics.isEmpty)
    }

    func testConcurrentDeadLetterRetryHasOnePersistenceOwnerAndOneRepositoryChange() async throws {
        let repository = SuspendedDeadLetterRetryRepository()
        let eventBus = EventBus()
        let recorder = WorkflowRunReceiptRecorder(
            repository: repository,
            eventBus: eventBus,
            maximumPersistenceAttempts: 1,
            persistenceRetryDelay: { _ in }
        )
        let runID = UUID()
        try await recorder.begin(runID: runID, workflowID: nil, trigger: .manual)
        do {
            _ = try await recorder.finish(runID: runID, termination: .completed)
            XCTFail("Expected the initial terminal write to fail.")
        } catch {
            XCTAssertEqual(
                error as? WorkflowRunReceiptRecorderError,
                .persistenceFailed(runID: runID)
            )
        }

        let stream = await eventBus.stream()
        let eventTask = Task { () -> Int in
            var changeCount = 0
            for await event in stream {
                switch event {
                case .runReceiptRepositoryChanged:
                    changeCount += 1
                case .diagnostic(let diagnostic)
                    where diagnostic.event == "diagnostic.boundary":
                    return changeCount
                default:
                    break
                }
            }
            return changeCount
        }
        let owningRetry = Task {
            try await recorder.retryFailedTerminal(runID: runID)
        }
        await repository.waitUntilRetryIsSuspended()
        let retryIsSuspended = await repository.isRetrySuspended()
        XCTAssertTrue(retryIsSuspended)

        do {
            _ = try await recorder.retryFailedTerminal(runID: runID)
            XCTFail("Expected a concurrent retry to be rejected.")
        } catch {
            XCTAssertEqual(
                error as? WorkflowRunReceiptRecorderError,
                .terminalWriteInProgress(runID: runID)
            )
        }

        await repository.releaseRetry()
        _ = try await owningRetry.value
        await eventBus.publish(
            .diagnostic(
                DiagnosticEvent(
                    subsystem: .session,
                    level: .debug,
                    event: "diagnostic.boundary",
                    message: "Receipt retry boundary."
                )
            )
        )

        let eventCount = await eventTask.value
        let failedTerminalCount = await recorder.rememberedFailedTerminalCount()
        XCTAssertEqual(eventCount, 1)
        XCTAssertEqual(failedTerminalCount, 0)
    }

    func testPersistenceFailureRecordsSafeDiagnosticAndRetryUsesFrozenTerminal() async throws {
        let privateErrorCanary = "PRIVATE-REPOSITORY-ERROR-5E31"
        let repository = FailOnceWorkflowRunReceiptRepository(
            privateErrorCanary: privateErrorCanary
        )
        let diagnostics = DiagnosticsRecorder()
        let eventBus = EventBus()
        let clock = ReceiptTestClock(
            nanoseconds: 0,
            date: Date(timeIntervalSince1970: 100)
        )
        let recorder = WorkflowRunReceiptRecorder(
            repository: repository,
            eventBus: eventBus,
            diagnostics: diagnostics,
            wallClock: { clock.wallNow() },
            monotonicClock: { clock.monotonicNow() },
            maximumPersistenceAttempts: 1,
            persistenceRetryDelay: { _ in }
        )
        let runID = UUID()
        try await recorder.begin(runID: runID, workflowID: UUID(), trigger: .manual)
        clock.setNanoseconds(2_000_000_000)

        do {
            _ = try await recorder.finish(
                runID: runID,
                termination: .failed(stage: .recognizing, code: .processing)
            )
            XCTFail("Expected the first persistence attempt to fail.")
        } catch {
            XCTAssertEqual(
                error as? WorkflowRunReceiptRecorderError,
                .persistenceFailed(runID: runID)
            )
        }

        let recordedDiagnostics = await diagnostics.snapshot()
        XCTAssertTrue(recordedDiagnostics.contains { event in
            event.runID == runID
                && event.event == "run-receipt.persistence.failed"
                && event.message == DiagnosticEventSanitizer.sanitizedMessage
        })
        XCTAssertFalse(String(describing: recordedDiagnostics).contains(privateErrorCanary))

        do {
            _ = try await recorder.finish(
                runID: runID,
                termination: .cancelled(stage: .recognizing)
            )
            XCTFail("Expected a changed terminal classification to fail.")
        } catch {
            XCTAssertEqual(
                error as? WorkflowRunReceiptRecorderError,
                .conflictingPreparedTerminal(runID: runID)
            )
        }

        clock.setDate(Date(timeIntervalSince1970: 999))
        clock.setNanoseconds(90_000_000_000)
        let stream = await eventBus.stream()
        let eventTask = Task { () -> WorkflowRunReceiptRepositoryChange? in
            for await event in stream {
                if case .runReceiptRepositoryChanged(let change) = event {
                    return change
                }
            }
            return nil
        }
        await Task.yield()

        let receipt = try await recorder.finish(
            runID: runID,
            termination: .failed(stage: .recognizing, code: .processing)
        )
        let published = await eventTask.value

        XCTAssertEqual(receipt.timestamp, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(receipt.duration, .s1To4)
        XCTAssertEqual(
            published,
            WorkflowRunReceiptRepositoryChange(
                runID: receipt.runID,
                terminalTimestamp: receipt.timestamp,
                writeGeneration: .initial
            )
        )
        let persisted = try await repository.receipts(matching: .init(runID: runID))
        XCTAssertEqual(persisted, [receipt])
    }

    func testDeadLetterRetryReusesGenerationCapturedByOriginalWriteIntent() async throws {
        let repository = FailOnceWorkflowRunReceiptRepository(privateErrorCanary: "private")
        let clock = ReceiptTestClock(date: Date(timeIntervalSince1970: 100))
        let recorder = WorkflowRunReceiptRecorder(
            repository: repository,
            wallClock: { clock.wallNow() },
            maximumPersistenceAttempts: 1,
            persistenceRetryDelay: { _ in }
        )
        let runID = UUID()
        try await recorder.begin(runID: runID, workflowID: UUID(), trigger: .manual)
        let originalGeneration = try await repository.captureRunHistoryWriteGeneration()
        do {
            _ = try await recorder.finish(runID: runID, termination: .completed)
            XCTFail("Expected the first persistence attempt to create a dead letter.")
        } catch {
            XCTAssertEqual(
                error as? WorkflowRunReceiptRecorderError,
                .persistenceFailed(runID: runID)
            )
        }
        let transition = try RunHistoryClearTransition(advancing: originalGeneration)
        _ = try await repository.deleteReceipts(
            obsoletedBy: transition,
            preservingLegacyRowsAfter: nil
        )
        clock.setDate(Date(timeIntervalSince1970: 10_000))

        do {
            _ = try await recorder.finish(runID: runID, termination: .completed)
            XCTFail("The dead letter must not capture the new generation during retry.")
        } catch {
            XCTAssertEqual(
                error as? WorkflowRunReceiptRecorderError,
                .writeObsoletedByClearBarrier(runID: runID)
            )
        }
        let persisted = try await repository.receipts(matching: .init(runID: runID))
        let failedTerminalCount = await recorder.rememberedFailedTerminalCount()
        XCTAssertTrue(persisted.isEmpty)
        XCTAssertEqual(failedTerminalCount, 0)
    }
}
