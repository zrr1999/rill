
@testable import RillCore
@testable import RillWorkflows
import XCTest

final class LocalHistoryMaintenanceTests: XCTestCase {
    func testFreshZeroDeletionClearsIntentWithoutPhysicalPurge() async throws {
        let clipboard = HistoryMaintenanceClipboardStore(
            clearResults: [RecordCleanupResult(removedCount: 0, preservedActiveCount: 2)]
        )
        let runHistory = HistoryMaintenanceRunRepository()
        let settings = HistoryMaintenanceSettingsStore()
        let purger = HistoryMaintenancePurger()
        let maintenance = makeMaintenance(
            clipboard: clipboard,
            runHistory: runHistory,
            settings: settings,
            purger: purger
        )

        let result = await maintenance.clearRecordHistory()

        XCTAssertEqual(
            result,
            .completed(
                LocalHistoryMaintenanceCounts(
                    preservedActiveRecordCount: 2
                )
            )
        )
        let purgeCount = await purger.callCount()
        XCTAssertEqual(purgeCount, 0)
        let pendingValue = try await settings.string(forKey: .localHistoryMaintenanceState)
        XCTAssertNil(pendingValue)
    }

    func testRecoveredLogicalIntentPurgesEvenWhenReplayDeletesNothing() async throws {
        let pendingState = LocalHistoryMaintenanceState(
            clipboardOperation: .clearAll,
            clearThrough: Date(timeIntervalSince1970: 100),
            phase: .logicalPending
        )
        let clipboard = HistoryMaintenanceClipboardStore(
            clearResults: [RecordCleanupResult(removedCount: 0, preservedActiveCount: 0)]
        )
        let runHistory = HistoryMaintenanceRunRepository()
        let settings = HistoryMaintenanceSettingsStore(
            storage: [.localHistoryMaintenanceState: try encode(pendingState)]
        )
        let purger = HistoryMaintenancePurger()
        let maintenance = makeMaintenance(
            clipboard: clipboard,
            runHistory: runHistory,
            settings: settings,
            purger: purger
        )

        let result = await maintenance.retryPendingMaintenance()

        XCTAssertEqual(result, .completed(LocalHistoryMaintenanceCounts()))
        let purgeCount = await purger.callCount()
        XCTAssertEqual(purgeCount, 1)
        let pendingValue = try await settings.string(forKey: .localHistoryMaintenanceState)
        XCTAssertNil(pendingValue)
    }

    func testPartialLogicalFailureRemainsReplayableAndRetryPurges() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let clipboard = HistoryMaintenanceClipboardStore(
            pruneResults: [
                RecordCleanupResult(removedCount: 3, preservedActiveCount: 1),
                RecordCleanupResult(removedCount: 0, preservedActiveCount: 1),
            ]
        )
        let runHistory = HistoryMaintenanceRunRepository(
            pruneResults: [.failure(.requested), .success(2)]
        )
        let settings = HistoryMaintenanceSettingsStore()
        let purger = HistoryMaintenancePurger()
        let maintenance = makeMaintenance(
            clipboard: clipboard,
            runHistory: runHistory,
            settings: settings,
            purger: purger
        )

        let firstResult = await maintenance.performRetention(
            recordRetention: .oneDay,
            runRetention: .oneWeek,
            now: now
        )

        XCTAssertEqual(
            firstResult,
            .pending(
                LocalHistoryMaintenanceCounts(
                    recordRemovedCount: 3,
                    preservedActiveRecordCount: 1
                ),
                .logicalDeletionFailed
            )
        )
        let storedAfterFailureValue = try await settings.string(
            forKey: .localHistoryMaintenanceState
        )
        let storedAfterFailure = try XCTUnwrap(storedAfterFailureValue)
        let stateAfterFailure = try JSONDecoder().decode(
            LocalHistoryMaintenanceState.self,
            from: Data(storedAfterFailure.utf8)
        )
        XCTAssertEqual(stateAfterFailure.phase, .logicalPending)

        let retryResult = await maintenance.retryPendingMaintenance()

        XCTAssertEqual(
            retryResult,
            .completed(
                LocalHistoryMaintenanceCounts(
                    runRemovedCount: 2,
                    preservedActiveRecordCount: 1
                )
            )
        )
        let purgeCount = await purger.callCount()
        XCTAssertEqual(purgeCount, 1)
        let pendingValue = try await settings.string(forKey: .localHistoryMaintenanceState)
        XCTAssertNil(pendingValue)
    }

    func testInvalidNestedOperationBlocksWithoutOverwritingState() async throws {
        let invalidState =
            #"{"schemaVersion":1,"clipboardOperation":{"kind":"clear-all","extra":true},"phase":"logical-pending"}"#
        let clipboard = HistoryMaintenanceClipboardStore()
        let runHistory = HistoryMaintenanceRunRepository()
        let settings = HistoryMaintenanceSettingsStore(
            storage: [.localHistoryMaintenanceState: invalidState]
        )
        let purger = HistoryMaintenancePurger()
        let maintenance = makeMaintenance(
            clipboard: clipboard,
            runHistory: runHistory,
            settings: settings,
            purger: purger
        )

        let result = await maintenance.retryPendingMaintenance()

        XCTAssertEqual(result, .blocked(.invalidPendingState))
        let clipboardCallCount = await clipboard.totalCallCount()
        let runCallCount = await runHistory.deletionCallCount()
        let purgeCount = await purger.callCount()
        XCTAssertEqual(clipboardCallCount, 0)
        XCTAssertEqual(runCallCount, 0)
        XCTAssertEqual(purgeCount, 0)
        let storedValue = try await settings.string(forKey: .localHistoryMaintenanceState)
        XCTAssertEqual(storedValue, invalidState)
    }

    func testGenerationTransitionWithUnknownFieldBlocksBeforeDeletion() async throws {
        let invalidState =
            #"{"schemaVersion":5,"runOperation":{"kind":"clear-all"},"runClearTransition":{"intentID":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","previousGeneration":0,"nextGeneration":1,"extra":true},"phase":"logical-pending"}"#
        let runHistory = HistoryMaintenanceRunRepository(clearResults: [.success(1)])
        let settings = HistoryMaintenanceSettingsStore(
            storage: [.localHistoryMaintenanceState: invalidState]
        )
        let maintenance = makeMaintenance(
            clipboard: HistoryMaintenanceClipboardStore(),
            runHistory: runHistory,
            settings: settings,
            purger: HistoryMaintenancePurger()
        )

        let result = await maintenance.retryPendingMaintenance()
        let deletionCallCount = await runHistory.deletionCallCount()
        let storedValue = try await settings.string(forKey: .localHistoryMaintenanceState)

        XCTAssertEqual(result, .blocked(.invalidPendingState))
        XCTAssertEqual(deletionCallCount, 0)
        XCTAssertEqual(storedValue, invalidState)
    }

    func testPhysicalPurgeFailureLeavesResiduePhaseAndRetryDoesNotRepeatDeletion() async throws {
        let clipboard = HistoryMaintenanceClipboardStore(
            clearResults: [RecordCleanupResult(removedCount: 1, preservedActiveCount: 0)]
        )
        let runHistory = HistoryMaintenanceRunRepository()
        let settings = HistoryMaintenanceSettingsStore()
        let purger = HistoryMaintenancePurger(failuresRemaining: 1)
        let maintenance = makeMaintenance(
            clipboard: clipboard,
            runHistory: runHistory,
            settings: settings,
            purger: purger
        )

        let firstResult = await maintenance.clearRecordHistory()

        XCTAssertEqual(
            firstResult,
            .pending(
                LocalHistoryMaintenanceCounts(recordRemovedCount: 1),
                .physicalPurgeFailed
            )
        )
        let storedPendingValue = try await settings.string(
            forKey: .localHistoryMaintenanceState
        )
        let storedPending = try XCTUnwrap(storedPendingValue)
        let pendingState = try JSONDecoder().decode(
            LocalHistoryMaintenanceState.self,
            from: Data(storedPending.utf8)
        )
        XCTAssertEqual(pendingState.phase, .residuePending)

        let retryResult = await maintenance.retryPendingMaintenance()

        XCTAssertEqual(retryResult, .completed(LocalHistoryMaintenanceCounts()))
        let clipboardCallCount = await clipboard.totalCallCount()
        let purgeCount = await purger.callCount()
        XCTAssertEqual(clipboardCallCount, 1)
        XCTAssertEqual(purgeCount, 2)
        let finalPendingValue = try await settings.string(forKey: .localHistoryMaintenanceState)
        XCTAssertNil(finalPendingValue)
    }

    func testConcurrentRequestsAreFIFOAndDoNotInterleaveIntents() async throws {
        let clipboard = HistoryMaintenanceClipboardStore(
            clearResults: [RecordCleanupResult(removedCount: 1, preservedActiveCount: 0)],
            blockFirstClear: true
        )
        let runHistory = HistoryMaintenanceRunRepository(clearResults: [.success(1)])
        let settings = HistoryMaintenanceSettingsStore()
        let purger = HistoryMaintenancePurger()
        let maintenance = makeMaintenance(
            clipboard: clipboard,
            runHistory: runHistory,
            settings: settings,
            purger: purger
        )

        let clipboardTask = Task { await maintenance.clearRecordHistory() }
        await clipboard.waitUntilClearStarted()
        let runTask = Task { await maintenance.clearRunHistory() }
        try await Task.sleep(for: .milliseconds(25))

        let runCallsWhileClipboardBlocked = await runHistory.deletionCallCount()
        XCTAssertEqual(runCallsWhileClipboardBlocked, 0)

        await clipboard.releaseFirstClear()
        let clipboardResult = await clipboardTask.value
        let runResult = await runTask.value

        XCTAssertEqual(
            clipboardResult,
            .completed(LocalHistoryMaintenanceCounts(recordRemovedCount: 1))
        )
        XCTAssertEqual(
            runResult,
            .completed(LocalHistoryMaintenanceCounts(runRemovedCount: 1))
        )
        let purgeCount = await purger.callCount()
        XCTAssertEqual(purgeCount, 2)
        let pendingValue = try await settings.string(forKey: .localHistoryMaintenanceState)
        XCTAssertNil(pendingValue)
    }

    func testNewRunClearCapturesGenerationAfterPendingRecovery() async throws {
        let pendingTransition = try RunHistoryClearTransition(
            intentID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            advancing: .initial
        )
        let pendingState = LocalHistoryMaintenanceState(
            runOperation: .clearAll,
            runClearTransition: pendingTransition
        )
        let runHistory = HistoryMaintenanceRunRepository(
            clearResults: [.success(0), .success(0)]
        )
        let settings = HistoryMaintenanceSettingsStore(
            storage: [.localHistoryMaintenanceState: try encode(pendingState)]
        )
        let maintenance = makeMaintenance(
            clipboard: HistoryMaintenanceClipboardStore(),
            runHistory: runHistory,
            settings: settings,
            purger: HistoryMaintenancePurger()
        )

        let result = await maintenance.clearRunHistory()
        let deletionCallCount = await runHistory.deletionCallCount()
        let currentGeneration = await runHistory.currentWriteGeneration()
        let pendingValue = try await settings.string(forKey: .localHistoryMaintenanceState)

        XCTAssertEqual(result, .completed(LocalHistoryMaintenanceCounts()))
        XCTAssertEqual(deletionCallCount, 2)
        XCTAssertEqual(currentGeneration, try RunHistoryWriteGeneration(2))
        XCTAssertNil(pendingValue)
    }

    func testRunClearAlsoClearsDiagnosticsAndIncludesBothCounts() async {
        let runHistory = HistoryMaintenanceRunRepository(clearResults: [.success(2)])
        let diagnostics = HistoryMaintenanceDiagnosticRepository(clearResults: [.success(3)])
        let maintenance = makeMaintenance(
            clipboard: HistoryMaintenanceClipboardStore(),
            runHistory: runHistory,
            diagnostics: diagnostics,
            settings: HistoryMaintenanceSettingsStore(),
            purger: HistoryMaintenancePurger()
        )

        let result = await maintenance.clearRunHistory()

        XCTAssertEqual(
            result,
            .completed(
                LocalHistoryMaintenanceCounts(
                    runRemovedCount: 2,
                    diagnosticRemovedCount: 3
                )
            )
        )
    }

    func testRunClearAlsoClearsDurableRunReceipts() async throws {
        let receipts = try InMemoryWorkflowRunReceiptRepository(receipts: [
            try WorkflowRunReceipt(
                runID: UUID(),
                workflowID: UUID(),
                trigger: .manual,
                timestamp: Date(timeIntervalSince1970: 1),
                duration: .under250ms,
                termination: .completed
            ),
            try WorkflowRunReceipt(
                runID: UUID(),
                workflowID: nil,
                trigger: .recordUse,
                timestamp: Date(timeIntervalSince1970: 2),
                duration: .under250ms,
                termination: .skipped(reason: .allActionsSkipped)
            ),
        ])
        let maintenance = makeMaintenance(
            clipboard: HistoryMaintenanceClipboardStore(),
            runHistory: HistoryMaintenanceRunRepository(clearResults: [.success(1)]),
            runReceipts: receipts,
            diagnostics: HistoryMaintenanceDiagnosticRepository(clearResults: [.success(3)]),
            settings: HistoryMaintenanceSettingsStore(),
            purger: HistoryMaintenancePurger()
        )

        let result = await maintenance.clearRunHistory()
        let remainingReceipts = try await receipts.receipts(matching: .all)

        XCTAssertEqual(
            result,
            .completed(
                LocalHistoryMaintenanceCounts(
                    runRemovedCount: 1,
                    runReceiptRemovedCount: 2,
                    diagnosticRemovedCount: 3
                )
            )
        )
        XCTAssertTrue(remainingReceipts.isEmpty)
    }

    func testRecoveredBoundedClearPreservesRecordsWrittenAfterIntentAcrossAllRunStores() async throws {
        let upperBound = Date(timeIntervalSince1970: 100)
        let oldTimestamp = Date(timeIntervalSince1970: 90)
        let newTimestamp = Date(timeIntervalSince1970: 110)
        let oldHistory = WorkflowResultRecord(
            workflow: WorkflowPresentation(fallbackName: "Old history"),
            finalText: "old",
            timestamp: oldTimestamp,
            outcome: .completed
        )
        let newHistory = WorkflowResultRecord(
            workflow: WorkflowPresentation(fallbackName: "New history"),
            finalText: "new",
            timestamp: newTimestamp,
            outcome: .completed
        )
        let history = InMemoryHistoryRepository(records: [oldHistory, newHistory])
        let oldReceipt = try WorkflowRunReceipt(
            runID: UUID(),
            workflowID: nil,
            trigger: .manual,
            timestamp: oldTimestamp,
            duration: .under250ms,
            termination: .completed
        )
        let newReceipt = try WorkflowRunReceipt(
            runID: UUID(),
            workflowID: nil,
            trigger: .manual,
            timestamp: newTimestamp,
            duration: .under250ms,
            termination: .completed
        )
        let receipts = try InMemoryWorkflowRunReceiptRepository(
            receipts: [oldReceipt, newReceipt]
        )
        let oldDiagnostic = DiagnosticEvent(
            timestamp: oldTimestamp,
            subsystem: .session,
            level: .info,
            event: "history.maintenance.old",
            message: "old"
        )
        let newDiagnostic = DiagnosticEvent(
            timestamp: newTimestamp,
            subsystem: .session,
            level: .info,
            event: "history.maintenance.new",
            message: "new"
        )
        let diagnostics = InMemoryDiagnosticRepository(
            events: [oldDiagnostic, newDiagnostic]
        )
        let pendingState = LocalHistoryMaintenanceState(
            schemaVersion: 4,
            runOperation: .clearAll,
            clearThrough: upperBound
        )
        let settings = HistoryMaintenanceSettingsStore(
            storage: [.localHistoryMaintenanceState: try encode(pendingState)]
        )
        let maintenance = LocalHistoryMaintenance(
            recordHistory: HistoryMaintenanceClipboardStore(),
            runHistory: history,
            runReceipts: receipts,
            diagnosticHistory: diagnostics,
            settingsStore: settings,
            physicalPurger: HistoryMaintenancePurger()
        )

        let result = await maintenance.retryPendingMaintenance()
        let remainingHistory = try await history.records(matching: .all)
        let remainingReceipts = try await receipts.receipts(matching: .all)
        let remainingDiagnostics = try await diagnostics.events(matching: DiagnosticQuery())

        XCTAssertEqual(
            result,
            .completed(
                LocalHistoryMaintenanceCounts(
                    runRemovedCount: 1,
                    runReceiptRemovedCount: 1,
                    diagnosticRemovedCount: 1
                )
            )
        )
        XCTAssertEqual(remainingHistory, [newHistory])
        XCTAssertEqual(remainingReceipts, [newReceipt])
        XCTAssertEqual(remainingDiagnostics.map(\.timestamp), [newTimestamp])
    }

    func testTerminalReceiptWriteStartedBeforeGenerationAdvanceIsCleared() async throws {
        let upperBound = Date(timeIntervalSince1970: 100)
        let receiptTimestamp = Date(timeIntervalSince1970: 101)
        let history = BlockingBoundedHistoryRepository()
        let receipts = InMemoryWorkflowRunReceiptRepository()
        let recorder = WorkflowRunReceiptRecorder(
            repository: receipts,
            wallClock: { receiptTimestamp }
        )
        let runID = UUID()
        try await recorder.begin(runID: runID, workflowID: UUID(), trigger: .hotkey)
        let maintenance = LocalHistoryMaintenance(
            recordHistory: HistoryMaintenanceClipboardStore(),
            runHistory: history,
            runReceipts: receipts,
            diagnosticHistory: HistoryMaintenanceDiagnosticRepository(),
            settingsStore: HistoryMaintenanceSettingsStore(),
            physicalPurger: HistoryMaintenancePurger(),
            wallClock: { upperBound }
        )

        let clearTask = Task { await maintenance.clearRunHistory() }
        await history.waitUntilBoundedDeletionStarts()
        let insertedReceipt = try await recorder.finish(
            runID: runID,
            termination: .completed
        )
        await history.releaseBoundedDeletion()
        let result = await clearTask.value
        let storedReceipts = try await receipts.receipts(
            matching: WorkflowRunReceiptQuery(runID: runID)
        )

        XCTAssertEqual(
            result,
            .completed(LocalHistoryMaintenanceCounts(runReceiptRemovedCount: 1))
        )
        XCTAssertTrue(storedReceipts.isEmpty)
        XCTAssertEqual(insertedReceipt.timestamp, receiptTimestamp)
    }

    func testRecoveredUnboundedLegacyClearIntentIsBlockedWithoutDeletingNewData() async throws {
        let pendingState = LocalHistoryMaintenanceState(
            schemaVersion: 1,
            runOperation: .clearAll
        )
        let runHistory = HistoryMaintenanceRunRepository(clearResults: [.success(2)])
        let diagnostics = HistoryMaintenanceDiagnosticRepository(clearResults: [.success(3)])
        let settings = HistoryMaintenanceSettingsStore(
            storage: [.localHistoryMaintenanceState: try encode(pendingState)]
        )
        let purger = HistoryMaintenancePurger()
        let maintenance = makeMaintenance(
            clipboard: HistoryMaintenanceClipboardStore(),
            runHistory: runHistory,
            diagnostics: diagnostics,
            settings: settings,
            purger: purger
        )

        let result = await maintenance.retryPendingMaintenance()

        XCTAssertEqual(result, .blocked(.invalidPendingState))
        let runCalls = await runHistory.deletionCallCount()
        let diagnosticCalls = await diagnostics.deletionCallCount()
        let purgeCount = await purger.callCount()
        XCTAssertEqual(runCalls, 0)
        XCTAssertEqual(diagnosticCalls, 0)
        XCTAssertEqual(purgeCount, 0)
        let pendingValue = try await settings.string(forKey: .localHistoryMaintenanceState)
        XCTAssertNotNil(pendingValue)
    }

    func testSchemaFourClearWithoutBoundaryIsRejectedBeforeRepositoryDeletion() async throws {
        let pendingState = LocalHistoryMaintenanceState(runOperation: .clearAll)
        let runHistory = HistoryMaintenanceRunRepository(clearResults: [.success(2)])
        let settings = HistoryMaintenanceSettingsStore(
            storage: [.localHistoryMaintenanceState: try encode(pendingState)]
        )
        let maintenance = makeMaintenance(
            clipboard: HistoryMaintenanceClipboardStore(),
            runHistory: runHistory,
            settings: settings,
            purger: HistoryMaintenancePurger()
        )

        let result = await maintenance.retryPendingMaintenance()
        let deletionCalls = await runHistory.deletionCallCount()

        XCTAssertEqual(result, .blocked(.invalidPendingState))
        XCTAssertEqual(deletionCalls, 0)
    }

    func testPruneOnlyStateRejectsExtraneousClearBoundary() async throws {
        let pendingState = LocalHistoryMaintenanceState(
            runOperation: .prune(olderThan: Date(timeIntervalSince1970: 50)),
            clearThrough: Date(timeIntervalSince1970: 100)
        )
        let runHistory = HistoryMaintenanceRunRepository(pruneResults: [.success(2)])
        let settings = HistoryMaintenanceSettingsStore(
            storage: [.localHistoryMaintenanceState: try encode(pendingState)]
        )
        let maintenance = makeMaintenance(
            clipboard: HistoryMaintenanceClipboardStore(),
            runHistory: runHistory,
            settings: settings,
            purger: HistoryMaintenancePurger()
        )

        let result = await maintenance.retryPendingMaintenance()
        let deletionCalls = await runHistory.deletionCallCount()

        XCTAssertEqual(result, .blocked(.invalidPendingState))
        XCTAssertEqual(deletionCalls, 0)
    }

    func testLegacyPruneIntentRemainsReplayableWithoutClearBoundary() async throws {
        let pendingState = LocalHistoryMaintenanceState(
            schemaVersion: 3,
            runOperation: .prune(olderThan: Date(timeIntervalSince1970: 50))
        )
        let runHistory = HistoryMaintenanceRunRepository(pruneResults: [.success(2)])
        let diagnostics = HistoryMaintenanceDiagnosticRepository(pruneResults: [.success(3)])
        let settings = HistoryMaintenanceSettingsStore(
            storage: [.localHistoryMaintenanceState: try encode(pendingState)]
        )
        let maintenance = makeMaintenance(
            clipboard: HistoryMaintenanceClipboardStore(),
            runHistory: runHistory,
            diagnostics: diagnostics,
            settings: settings,
            purger: HistoryMaintenancePurger()
        )

        let result = await maintenance.retryPendingMaintenance()

        XCTAssertEqual(
            result,
            .completed(
                LocalHistoryMaintenanceCounts(
                    runRemovedCount: 2,
                    diagnosticRemovedCount: 3
                )
            )
        )
    }

    func testLegacyResiduePendingClearCompletesWithoutRepeatingUnboundedDeletion() async throws {
        let pendingState = LocalHistoryMaintenanceState(
            schemaVersion: 3,
            runOperation: .clearAll,
            phase: .residuePending
        )
        let runHistory = HistoryMaintenanceRunRepository(clearResults: [.success(2)])
        let settings = HistoryMaintenanceSettingsStore(
            storage: [.localHistoryMaintenanceState: try encode(pendingState)]
        )
        let purger = HistoryMaintenancePurger()
        let maintenance = makeMaintenance(
            clipboard: HistoryMaintenanceClipboardStore(),
            runHistory: runHistory,
            settings: settings,
            purger: purger
        )

        let result = await maintenance.retryPendingMaintenance()
        let deletionCalls = await runHistory.deletionCallCount()
        let purgeCalls = await purger.callCount()

        XCTAssertEqual(result, .completed(LocalHistoryMaintenanceCounts()))
        XCTAssertEqual(deletionCalls, 0)
        XCTAssertEqual(purgeCalls, 1)
    }

    func testDiagnosticFailureKeepsRunIntentReplayable() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let runHistory = HistoryMaintenanceRunRepository(
            pruneResults: [.success(2), .success(0)]
        )
        let diagnostics = HistoryMaintenanceDiagnosticRepository(
            pruneResults: [.failure(.requested), .success(4)]
        )
        let settings = HistoryMaintenanceSettingsStore()
        let purger = HistoryMaintenancePurger()
        let maintenance = makeMaintenance(
            clipboard: HistoryMaintenanceClipboardStore(),
            runHistory: runHistory,
            diagnostics: diagnostics,
            settings: settings,
            purger: purger
        )

        let firstResult = await maintenance.performRetention(
            recordRetention: .forever,
            runRetention: .oneWeek,
            now: now
        )

        XCTAssertEqual(
            firstResult,
            .pending(
                LocalHistoryMaintenanceCounts(runRemovedCount: 2),
                .logicalDeletionFailed
            )
        )
        let pendingValue = try await settings.string(forKey: .localHistoryMaintenanceState)
        let pendingJSON = try XCTUnwrap(pendingValue)
        let pendingState = try JSONDecoder().decode(
            LocalHistoryMaintenanceState.self,
            from: Data(pendingJSON.utf8)
        )
        XCTAssertEqual(pendingState.schemaVersion, LocalHistoryMaintenanceState.currentSchemaVersion)
        XCTAssertEqual(pendingState.phase, .logicalPending)

        let retryResult = await maintenance.retryPendingMaintenance()

        XCTAssertEqual(
            retryResult,
            .completed(LocalHistoryMaintenanceCounts(diagnosticRemovedCount: 4))
        )
        let runCalls = await runHistory.deletionCallCount()
        let diagnosticCalls = await diagnostics.deletionCallCount()
        let purgeCount = await purger.callCount()
        XCTAssertEqual(runCalls, 2)
        XCTAssertEqual(diagnosticCalls, 2)
        XCTAssertEqual(purgeCount, 1)
    }

    private func makeMaintenance(
        clipboard: HistoryMaintenanceClipboardStore,
        runHistory: HistoryMaintenanceRunRepository,
        runReceipts: any WorkflowRunReceiptMaintaining = InMemoryWorkflowRunReceiptRepository(),
        diagnostics: HistoryMaintenanceDiagnosticRepository = HistoryMaintenanceDiagnosticRepository(),
        settings: HistoryMaintenanceSettingsStore,
        purger: HistoryMaintenancePurger
    ) -> LocalHistoryMaintenance {
        LocalHistoryMaintenance(
            recordHistory: clipboard,
            runHistory: runHistory,
            runReceipts: runReceipts,
            diagnosticHistory: diagnostics,
            settingsStore: settings,
            physicalPurger: purger
        )
    }

    private func encode(_ state: LocalHistoryMaintenanceState) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(state), as: UTF8.self)
    }
}

private enum HistoryMaintenanceTestError: Error, Sendable {
    case requested
}

private actor HistoryMaintenanceClipboardStore: RecordHistoryMaintaining {
    private var pruneResults: [RecordCleanupResult]
    private var clearResults: [RecordCleanupResult]
    private let blockFirstClear: Bool
    private var didBlockFirstClear = false
    private var clearStarted = false
    private var clearStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var clearReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var callCount = 0

    init(
        pruneResults: [RecordCleanupResult] = [],
        clearResults: [RecordCleanupResult] = [],
        blockFirstClear: Bool = false
    ) {
        self.pruneResults = pruneResults
        self.clearResults = clearResults
        self.blockFirstClear = blockFirstClear
    }

    func pruneHistory(olderThan cutoff: Date) async throws -> RecordCleanupResult {
        callCount += 1
        return pruneResults.isEmpty
            ? RecordCleanupResult(removedCount: 0, preservedActiveCount: 0)
            : pruneResults.removeFirst()
    }

    func clearHistory() async throws -> RecordCleanupResult {
        callCount += 1
        if blockFirstClear, !didBlockFirstClear {
            didBlockFirstClear = true
            clearStarted = true
            let waiters = clearStartedWaiters
            clearStartedWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                clearReleaseWaiters.append(continuation)
            }
        }
        return clearResults.isEmpty
            ? RecordCleanupResult(removedCount: 0, preservedActiveCount: 0)
            : clearResults.removeFirst()
    }

    func clearHistory(through upperBound: Date) async throws -> RecordCleanupResult {
        try await clearHistory()
    }

    func waitUntilClearStarted() async {
        guard !clearStarted else { return }
        await withCheckedContinuation { continuation in
            clearStartedWaiters.append(continuation)
        }
    }

    func releaseFirstClear() {
        let waiters = clearReleaseWaiters
        clearReleaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func totalCallCount() -> Int {
        callCount
    }
}

private actor HistoryMaintenanceRunRepository: HistoryRepository, HistoryMaintaining {
    func save(_ value: WorkflowResultRecord, generation: RunHistoryWriteGeneration) async throws {
        guard generation == .initial else { throw RunHistoryGenerationError.unsupported }
        try await (self as any HistoryRepository).save(value)
    }

    private var pruneResults: [Result<Int, HistoryMaintenanceTestError>]
    private var clearResults: [Result<Int, HistoryMaintenanceTestError>]
    private var deletionCalls = 0
    private var generation: RunHistoryWriteGeneration = .initial
    private var lastClearIntentID: UUID?

    init(
        pruneResults: [Result<Int, HistoryMaintenanceTestError>] = [],
        clearResults: [Result<Int, HistoryMaintenanceTestError>] = []
    ) {
        self.pruneResults = pruneResults
        self.clearResults = clearResults
    }

    func save(_ record: WorkflowResultRecord) async throws {}

    func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration {
        generation
    }

    func records(matching query: HistoryQuery) async throws -> [WorkflowResultRecord] {
        []
    }

    func deleteRecords(olderThan cutoff: Date) async throws -> Int {
        deletionCalls += 1
        guard !pruneResults.isEmpty else { return 0 }
        return try pruneResults.removeFirst().get()
    }

    func deleteAllRecords() async throws -> Int {
        deletionCalls += 1
        guard !clearResults.isEmpty else { return 0 }
        return try clearResults.removeFirst().get()
    }

    func deleteRecords(through upperBound: Date) async throws -> Int {
        deletionCalls += 1
        guard !clearResults.isEmpty else { return 0 }
        return try clearResults.removeFirst().get()
    }

    func deleteRecords(
        obsoletedBy transition: RunHistoryClearTransition,
        preservingLegacyRowsAfter legacyUpperBound: Date?
    ) async throws -> Int {
        try advance(transition)
        deletionCalls += 1
        guard !clearResults.isEmpty else { return 0 }
        return try clearResults.removeFirst().get()
    }

    private func advance(_ transition: RunHistoryClearTransition) throws {
        if generation == transition.nextGeneration,
           lastClearIntentID == transition.intentID { return }
        guard generation == transition.previousGeneration else {
            throw RunHistoryGenerationError.clearTransitionConflict
        }
        generation = transition.nextGeneration
        lastClearIntentID = transition.intentID
    }

    func deletionCallCount() -> Int {
        deletionCalls
    }

    func currentWriteGeneration() -> RunHistoryWriteGeneration {
        generation
    }
}

private actor BlockingBoundedHistoryRepository: HistoryRepository, HistoryMaintaining {
    func save(_ value: WorkflowResultRecord, generation: RunHistoryWriteGeneration) async throws {
        guard generation == .initial else { throw RunHistoryGenerationError.unsupported }
        try await save(value)
    }

    private var deletionStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var generation: RunHistoryWriteGeneration = .initial
    private var lastClearIntentID: UUID?

    func save(_ record: WorkflowResultRecord) async throws {}

    func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration {
        generation
    }

    func records(matching query: HistoryQuery) async throws -> [WorkflowResultRecord] { [] }

    func deleteRecords(olderThan cutoff: Date) async throws -> Int { 0 }

    func deleteRecords(through upperBound: Date) async throws -> Int {
        deletionStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        return 0
    }

    func deleteRecords(
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
        deletionStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        return 0
    }

    func deleteAllRecords() async throws -> Int { 0 }

    func waitUntilBoundedDeletionStarts() async {
        guard !deletionStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseBoundedDeletion() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor HistoryMaintenanceDiagnosticRepository: DiagnosticRepository, DiagnosticHistoryMaintaining {
    func save(_ value: DiagnosticEvent, generation: RunHistoryWriteGeneration) async throws {
        guard generation == .initial else { throw RunHistoryGenerationError.unsupported }
        try await (self as any DiagnosticRepository).save(value)
    }

    private var pruneResults: [Result<Int, HistoryMaintenanceTestError>]
    private var clearResults: [Result<Int, HistoryMaintenanceTestError>]
    private var deletionCalls = 0
    private var generation: RunHistoryWriteGeneration = .initial
    private var lastClearIntentID: UUID?

    init(
        pruneResults: [Result<Int, HistoryMaintenanceTestError>] = [],
        clearResults: [Result<Int, HistoryMaintenanceTestError>] = []
    ) {
        self.pruneResults = pruneResults
        self.clearResults = clearResults
    }

    func save(_ event: DiagnosticEvent) async throws {}

    func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration {
        generation
    }

    func events(matching query: DiagnosticQuery) async throws -> [DiagnosticEvent] {
        []
    }

    func deleteEvents(olderThan cutoff: Date) async throws -> Int {
        deletionCalls += 1
        guard !pruneResults.isEmpty else { return 0 }
        return try pruneResults.removeFirst().get()
    }

    func deleteAllEvents() async throws -> Int {
        deletionCalls += 1
        guard !clearResults.isEmpty else { return 0 }
        return try clearResults.removeFirst().get()
    }

    func deleteEvents(through upperBound: Date) async throws -> Int {
        deletionCalls += 1
        guard !clearResults.isEmpty else { return 0 }
        return try clearResults.removeFirst().get()
    }

    func deleteEvents(
        obsoletedBy transition: RunHistoryClearTransition,
        preservingLegacyRowsAfter legacyUpperBound: Date?
    ) async throws -> Int {
        if generation == transition.nextGeneration,
           lastClearIntentID == transition.intentID {
            deletionCalls += 1
            guard !clearResults.isEmpty else { return 0 }
            return try clearResults.removeFirst().get()
        }
        guard generation == transition.previousGeneration else {
            throw RunHistoryGenerationError.clearTransitionConflict
        }
        generation = transition.nextGeneration
        lastClearIntentID = transition.intentID
        deletionCalls += 1
        guard !clearResults.isEmpty else { return 0 }
        return try clearResults.removeFirst().get()
    }

    func deletionCallCount() -> Int {
        deletionCalls
    }
}

private actor HistoryMaintenanceSettingsStore: SettingsStore {
    private var storage: [AppSettingKey: String]

    init(storage: [AppSettingKey: String] = [:]) {
        self.storage = storage
    }

    func string(forKey key: AppSettingKey) async throws -> String? {
        storage[key]
    }

    func setString(_ value: String, forKey key: AppSettingKey) async throws {
        storage[key] = value
    }

    func setStringsAtomically(_ values: [AppSettingKey: String]) async throws {
        storage.merge(values) { _, replacement in replacement }
    }

    func removeValue(forKey key: AppSettingKey) async throws {
        storage.removeValue(forKey: key)
    }
}

private actor HistoryMaintenancePurger: StorageResiduePurging {
    private var failuresRemaining: Int
    private var calls = 0

    init(failuresRemaining: Int = 0) {
        self.failuresRemaining = failuresRemaining
    }

    func purgeSensitiveStorageResidue() async throws {
        calls += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw HistoryMaintenanceTestError.requested
        }
    }

    func callCount() -> Int {
        calls
    }
}
