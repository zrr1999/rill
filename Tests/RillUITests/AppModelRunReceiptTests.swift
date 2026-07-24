import XCTest
@testable import RillCore
@testable import RillRuntime
@testable import RillUI

private actor SuspendedFirstRunReceiptRepository: WorkflowRunReceiptRepository {
    private var stored: [UUID: WorkflowRunReceipt] = [:]
    private var queryCount = 0
    private var firstSnapshotWasCaptured = false
    private var firstQueryContinuation: CheckedContinuation<Void, Never>?

    func insertTerminal(_ receipt: WorkflowRunReceipt) throws {
        stored[receipt.runID] = receipt
    }

    func receipts(
        matching query: WorkflowRunReceiptQuery
    ) async throws -> [WorkflowRunReceipt] {
        queryCount += 1
        let snapshot = Array(stored.values)
        if queryCount == 1 {
            firstSnapshotWasCaptured = true
            await withCheckedContinuation { continuation in
                firstQueryContinuation = continuation
            }
        }
        return snapshot.sorted { $0.timestamp > $1.timestamp }
    }

    func deleteReceipts(olderThan cutoff: Date) throws -> Int { 0 }

    func deleteAllReceipts() throws -> Int {
        let count = stored.count
        stored.removeAll()
        return count
    }

    func didCaptureFirstSnapshot() -> Bool {
        firstSnapshotWasCaptured
    }

    func observedQueryCount() -> Int {
        queryCount
    }

    func releaseFirstQuery() {
        firstQueryContinuation?.resume()
        firstQueryContinuation = nil
    }
}

private actor SwitchableRunReceiptRepository: WorkflowRunReceiptRepository {
    enum QueryError: Error { case unavailable }

    private var receiptsByRunID: [UUID: WorkflowRunReceipt]
    private var clearThrough: Date?
    private var queryShouldFail = false
    private var queryCount = 0

    init(receipts: [WorkflowRunReceipt]) {
        receiptsByRunID = Dictionary(
            receipts.map { ($0.runID, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
    }

    func insertTerminal(_ receipt: WorkflowRunReceipt) throws {
        guard clearThrough.map({ receipt.timestamp > $0 }) ?? true else {
            throw WorkflowRunReceiptRepositoryError.writeObsoletedByClearBarrier(
                runID: receipt.runID
            )
        }
        receiptsByRunID[receipt.runID] = receipt
    }

    func receipts(
        matching query: WorkflowRunReceiptQuery
    ) throws -> [WorkflowRunReceipt] {
        queryCount += 1
        guard !queryShouldFail else { throw QueryError.unavailable }
        var receipts = Array(receiptsByRunID.values)
        if let runID = query.runID {
            receipts = receipts.filter { $0.runID == runID }
        }
        if let runIDs = query.runIDs {
            receipts = receipts.filter { runIDs.contains($0.runID) }
        }
        if let since = query.since {
            receipts = receipts.filter { $0.timestamp >= since }
        }
        receipts.sort { $0.timestamp > $1.timestamp }
        if let limit = query.limit, limit >= 0 {
            receipts = Array(receipts.prefix(limit))
        }
        return receipts
    }

    func deleteReceipts(olderThan cutoff: Date) throws -> Int { 0 }

    func deleteReceipts(through upperBound: Date) async throws -> Int {
        let originalCount = receiptsByRunID.count
        receiptsByRunID = receiptsByRunID.filter { $0.value.timestamp > upperBound }
        if clearThrough.map({ upperBound > $0 }) ?? true {
            clearThrough = upperBound
        }
        return originalCount - receiptsByRunID.count
    }

    func deleteAllReceipts() throws -> Int { 0 }

    func failFutureQueries() {
        queryShouldFail = true
    }

    func observedQueryCount() -> Int {
        queryCount
    }
}

private actor SuspendedAcceptedInsertRunReceiptRepository: WorkflowRunReceiptRepository {
    enum QueryError: Error { case unavailable }

    private var receiptsByRunID: [UUID: WorkflowRunReceipt] = [:]
    private var clearThrough: Date?
    private var queryCount = 0
    private var queryShouldFail = false
    private var insertWasAccepted = false
    private var insertContinuation: CheckedContinuation<Void, Never>?

    func insertTerminal(_ receipt: WorkflowRunReceipt) async throws {
        guard clearThrough.map({ receipt.timestamp > $0 }) ?? true else {
            throw WorkflowRunReceiptRepositoryError.writeObsoletedByClearBarrier(
                runID: receipt.runID
            )
        }
        receiptsByRunID[receipt.runID] = receipt
        insertWasAccepted = true
        await withCheckedContinuation { continuation in
            insertContinuation = continuation
        }
    }

    func receipts(
        matching query: WorkflowRunReceiptQuery
    ) throws -> [WorkflowRunReceipt] {
        queryCount += 1
        guard !queryShouldFail else { throw QueryError.unavailable }
        var receipts = Array(receiptsByRunID.values)
        if let runID = query.runID {
            receipts = receipts.filter { $0.runID == runID }
        }
        if let runIDs = query.runIDs {
            receipts = receipts.filter { runIDs.contains($0.runID) }
        }
        if let since = query.since {
            receipts = receipts.filter { $0.timestamp >= since }
        }
        receipts.sort { $0.timestamp > $1.timestamp }
        if let limit = query.limit, limit >= 0 {
            receipts = Array(receipts.prefix(limit))
        }
        return receipts
    }

    func deleteReceipts(olderThan cutoff: Date) throws -> Int { 0 }

    func deleteReceipts(through upperBound: Date) async throws -> Int {
        let originalCount = receiptsByRunID.count
        receiptsByRunID = receiptsByRunID.filter { $0.value.timestamp > upperBound }
        if clearThrough.map({ upperBound > $0 }) ?? true {
            clearThrough = upperBound
        }
        return originalCount - receiptsByRunID.count
    }

    func deleteAllReceipts() throws -> Int { 0 }

    func didAcceptInsert() -> Bool { insertWasAccepted }
    func observedQueryCount() -> Int { queryCount }
    func storedCount() -> Int { receiptsByRunID.count }

    func failFutureQueries() {
        queryShouldFail = true
    }

    func releaseInsert() {
        insertContinuation?.resume()
        insertContinuation = nil
    }
}

private actor ClearInterleavingHistoryRepository: HistoryRepository {
    private let rejectsObsoleteWrites: Bool
    private var stored: [HistoryRecord] = []
    private var clearThrough: Date?
    private var saveStarted = false
    private var saveFinished = false
    private var saveContinuation: CheckedContinuation<Void, Never>?

    init(rejectsObsoleteWrites: Bool = true) {
        self.rejectsObsoleteWrites = rejectsObsoleteWrites
    }

    func save(_ record: HistoryRecord) async throws {
        saveStarted = true
        await withCheckedContinuation { continuation in
            saveContinuation = continuation
        }
        defer { saveFinished = true }
        guard !rejectsObsoleteWrites || clearThrough.map({ record.timestamp > $0 }) ?? true else {
            throw HistoryRepositoryError.writeObsoletedByClearBarrier
        }
        stored.append(record)
    }

    func records(matching query: HistoryQuery) async throws -> [HistoryRecord] {
        stored.sorted { $0.timestamp > $1.timestamp }
    }

    func deleteRecords(olderThan cutoff: Date) async throws -> Int {
        let count = stored.count
        stored.removeAll { $0.timestamp < cutoff }
        return count - stored.count
    }

    func deleteRecords(through upperBound: Date) async throws -> Int {
        let count = stored.count
        stored.removeAll { $0.timestamp <= upperBound }
        if clearThrough.map({ upperBound > $0 }) ?? true {
            clearThrough = upperBound
        }
        return count - stored.count
    }

    func deleteAllRecords() async throws -> Int {
        let count = stored.count
        stored.removeAll()
        return count
    }

    func didStartSave() -> Bool { saveStarted }
    func didFinishSave() -> Bool { saveFinished }

    func releaseSave() {
        saveContinuation?.resume()
        saveContinuation = nil
    }
}

@MainActor
final class AppModelRunReceiptTests: XCTestCase {
    func testAppModelLoadsDurableRunReceiptsWithoutEventReplay() async throws {
        let receipt = try makeReceipt(trigger: .clipboardReplay)
        let repository = try InMemoryWorkflowRunReceiptRepository(receipts: [receipt])
        let harness = makeHarness(runReceiptRepository: repository)

        let loaded = await waitUntil {
            harness.model.workflowRunReceipt(for: receipt.runID) == receipt
        }

        XCTAssertTrue(loaded)
    }

    func testRepositoryChangeRefreshesCacheWithoutWritingRepository() async throws {
        let repository = InMemoryWorkflowRunReceiptRepository()
        let harness = makeHarness(runReceiptRepository: repository)
        let receipt = try makeReceipt(trigger: .hotkey)
        try await repository.insertTerminal(receipt)

        await harness.eventBus.publish(repositoryChangeEvent(for: receipt))

        let loaded = await waitUntil {
            harness.model.workflowRunReceipt(for: receipt.runID) == receipt
        }
        let stored = try await repository.receipts(matching: .all)
        XCTAssertTrue(loaded)
        XCTAssertEqual(stored, [receipt])
    }

    func testRepositoryChangeInvalidatesOlderInFlightRepositorySnapshot() async throws {
        let repository = SuspendedFirstRunReceiptRepository()
        let harness = makeHarness(runReceiptRepository: repository)
        let receipt = try makeReceipt(trigger: .clipboardReplay)

        let firstQueryStarted = await waitUntilAsync {
            await repository.didCaptureFirstSnapshot()
        }
        XCTAssertTrue(firstQueryStarted)

        try await repository.insertTerminal(receipt)
        await harness.eventBus.publish(repositoryChangeEvent(for: receipt))

        let postPersistReloadStarted = await waitUntilAsync {
            await repository.observedQueryCount() >= 2
        }
        XCTAssertTrue(postPersistReloadStarted)
        await repository.releaseFirstQuery()

        let retained = await waitUntil {
            harness.model.workflowRunReceipt(for: receipt.runID) == receipt
        }
        XCTAssertTrue(retained)
    }

    func testVisibleHistoryRunLoadsExactReceiptBeyondGlobalRecentLimit() async throws {
        let now = Date()
        let requiredRunID = UUID()
        let requiredReceipt = try makeReceipt(
            runID: requiredRunID,
            trigger: .hotkey,
            timestamp: now.addingTimeInterval(-1_000)
        )
        let highTrafficReceipts = try (0..<101).map { offset in
            try makeReceipt(
                runID: UUID(),
                trigger: .clipboardUse,
                timestamp: now.addingTimeInterval(-Double(offset))
            )
        }
        let receiptRepository = try InMemoryWorkflowRunReceiptRepository(
            receipts: highTrafficReceipts + [requiredReceipt]
        )
        let historyRepository = InMemoryHistoryRepository(records: [
            HistoryRecord(
                runID: requiredRunID,
                workflow: WorkflowPresentation(fallbackName: "Visible run"),
                finalText: "result",
                timestamp: now,
                outcome: .completed
            ),
        ])
        let harness = makeHarness(
            historyRepository: historyRepository,
            runReceiptRepository: receiptRepository
        )

        let loaded = await waitUntil {
            harness.model.workflowRunReceipt(for: requiredRunID) == requiredReceipt
        }

        XCTAssertTrue(loaded)
    }

    func testPersistedVoiceTriggerKeepsCustomResultVisibleAfterWorkflowRemoval() async {
        let runID = UUID()
        let record = HistoryRecord(
            runID: runID,
            workflowID: UUID(),
            workflow: WorkflowPresentation(fallbackName: "Removed Custom Dictation"),
            finalText: "retained voice result",
            timestamp: Date(),
            outcome: .completed,
            trigger: .hotkey
        )
        let historyRepository = InMemoryHistoryRepository(records: [record])
        let harness = makeHarness(
            workflows: [],
            historyRepository: historyRepository
        )

        let loaded = await waitUntil {
            harness.model.historyRecords.contains { $0.runID == runID }
        }

        XCTAssertTrue(loaded)
        XCTAssertEqual(harness.model.recentVoiceResultRecords.map(\.runID), [runID])
    }

    func testLegacyGroupMetadataCannotClassifyClipboardBodyAsVoiceWithoutReceipt() async {
        let workflow = WorkflowDefinition(
            name: "Legacy Group Rewrite",
            pipeline: PipelineDeclaration(
                recognizerID: "context.selection",
                outputActions: [OutputActionReference(id: "stack.push")]
            ),
            ui: WorkflowUIConfig(symbolName: "bolt", accentColorName: "orange"),
            metadata: [
                WorkflowMetadataKey.legacyEventType: "groupItemCreated",
                WorkflowMetadataKey.legacySourceGroupID: ClipboardGroup.voiceGroupID.uuidString,
                WorkflowMetadataKey.legacyExcludePolishTag: "true",
                WorkflowMetadataKey.legacyGroupActionKind: ClipboardGroupActionKind.editItem.rawValue,
            ]
        )
        let runID = UUID()
        let record = HistoryRecord(
            runID: runID,
            workflowID: workflow.id,
            workflow: workflow.presentation,
            finalText: "legacy clipboard payload",
            timestamp: Date(),
            outcome: .completed
        )
        let harness = makeHarness(
            workflows: [workflow],
            historyRepository: InMemoryHistoryRepository(records: [record])
        )

        let loaded = await waitUntil {
            harness.model.historyRecords.contains { $0.runID == runID }
        }

        XCTAssertTrue(loaded)
        XCTAssertTrue(harness.model.recentVoiceHistoryRecords.isEmpty)
        XCTAssertTrue(harness.model.recentVoiceResultRecords.isEmpty)
    }

    func testLegacyReceiptFallbackIsVoiceButTriggerConflictFailsClosed() async throws {
        let legacyVoiceRunID = UUID()
        let conflictingRunID = UUID()
        let legacyVoice = HistoryRecord(
            runID: legacyVoiceRunID,
            workflow: WorkflowPresentation(fallbackName: "Legacy Voice"),
            finalText: "voice body",
            timestamp: Date(),
            outcome: .completed
        )
        let conflicting = HistoryRecord(
            runID: conflictingRunID,
            workflow: WorkflowPresentation(fallbackName: "Conflicting Body"),
            finalText: "must stay hidden",
            timestamp: Date().addingTimeInterval(-1),
            outcome: .completed,
            trigger: .manual
        )
        let voiceReceipt = try makeReceipt(
            runID: legacyVoiceRunID,
            trigger: .failedAudioRecovery
        )
        let conflictingReceipt = try makeReceipt(
            runID: conflictingRunID,
            trigger: .clipboardReplay
        )
        let receiptRepository = try InMemoryWorkflowRunReceiptRepository(
            receipts: [voiceReceipt, conflictingReceipt]
        )
        let harness = makeHarness(
            historyRepository: InMemoryHistoryRepository(
                records: [legacyVoice, conflicting]
            ),
            runReceiptRepository: receiptRepository
        )

        let loaded = await waitUntil {
            harness.model.historyRecords.count == 2
                && harness.model.workflowRunReceipt(for: legacyVoiceRunID) == voiceReceipt
                && harness.model.workflowRunReceipt(for: conflictingRunID) == conflictingReceipt
        }

        XCTAssertTrue(loaded)
        XCTAssertEqual(
            harness.model.recentVoiceResultRecords.map(\.runID),
            [legacyVoiceRunID]
        )
    }

    func testCompletedExplicitClearRemovesCachedReceiptWhenReloadFails() async throws {
        let receipt = try makeReceipt(trigger: .clipboardUse)
        let repository = SwitchableRunReceiptRepository(receipts: [receipt])
        let maintenance = UITestLocalHistoryMaintenance(
            fallbackResult: .completed(
                LocalHistoryMaintenanceCounts(runReceiptRemovedCount: 1)
            )
        )
        let harness = makeHarness(
            runReceiptRepository: repository,
            localHistoryMaintenance: maintenance
        )
        let initiallyLoaded = await waitUntil {
            harness.model.workflowRunReceipt(for: receipt.runID) == receipt
        }
        XCTAssertTrue(initiallyLoaded)
        await repository.failFutureQueries()

        harness.model.clearRunHistory()
        let maintenanceFinished = await waitUntil {
            !harness.model.isLocalHistoryMaintenanceRunning
        }

        XCTAssertTrue(maintenanceFinished)
        XCTAssertNil(harness.model.workflowRunReceipt(for: receipt.runID))
    }

    func testLateRepositoryChangeCannotResurrectClearedReceiptWhenReloadFails() async throws {
        let receipt = try makeReceipt(trigger: .clipboardUse)
        let repository = SwitchableRunReceiptRepository(receipts: [receipt])
        let maintenance = UITestLocalHistoryMaintenance(
            fallbackResult: .completed(
                LocalHistoryMaintenanceCounts(runReceiptRemovedCount: 1)
            )
        )
        let harness = makeHarness(
            runReceiptRepository: repository,
            localHistoryMaintenance: maintenance
        )
        let initiallyLoaded = await waitUntil {
            harness.model.workflowRunReceipt(for: receipt.runID) == receipt
        }
        XCTAssertTrue(initiallyLoaded)
        await repository.failFutureQueries()

        harness.model.clearRunHistory()
        let maintenanceFinished = await waitUntil {
            !harness.model.isLocalHistoryMaintenanceRunning
        }
        XCTAssertTrue(maintenanceFinished)
        let queryCountBeforeLateEvent = await repository.observedQueryCount()

        await harness.eventBus.publish(repositoryChangeEvent(for: receipt))
        let reloadAttempted = await waitUntilAsync {
            await repository.observedQueryCount() > queryCountBeforeLateEvent
        }
        XCTAssertTrue(reloadAttempted)
        XCTAssertNil(harness.model.workflowRunReceipt(for: receipt.runID))
    }

    func testRepositoryChangeDeliveredAfterDurableClearFailsClosedWhenReloadFails() async throws {
        let receipt = try makeReceipt(trigger: .hotkey)
        let repository = SwitchableRunReceiptRepository(receipts: [receipt])
        let harness = makeHarness(runReceiptRepository: repository)
        let initiallyLoaded = await waitUntil {
            harness.model.workflowRunReceipt(for: receipt.runID) == receipt
        }
        XCTAssertTrue(initiallyLoaded)

        // This ordering is the recorder's insert-return -> clear -> event-delivery
        // window. The notification is deliberately delivered only after the
        // durable row and its inclusive timestamp have been cleared.
        let removedCount = try await repository.deleteReceipts(
            through: receipt.timestamp
        )
        XCTAssertEqual(removedCount, 1)
        await repository.failFutureQueries()
        let queryCountBeforeChange = await repository.observedQueryCount()

        await harness.eventBus.publish(repositoryChangeEvent(for: receipt))

        let reloadAttempted = await waitUntilAsync {
            await repository.observedQueryCount() > queryCountBeforeChange
        }
        XCTAssertTrue(reloadAttempted)
        XCTAssertNil(harness.model.workflowRunReceipt(for: receipt.runID))
    }

    func testRecorderInsertReturnAfterConcurrentClearPublishesOnlyFailClosedInvalidation() async throws {
        let repository = SuspendedAcceptedInsertRunReceiptRepository()
        let harness = makeHarness(runReceiptRepository: repository)
        let terminalTimestamp = Date()
        let runID = UUID()
        let recorder = WorkflowRunReceiptRecorder(
            repository: repository,
            eventBus: harness.eventBus,
            wallClock: { terminalTimestamp }
        )
        try await recorder.begin(runID: runID, workflowID: UUID(), trigger: .hotkey)

        let finishTask = Task {
            try await recorder.finish(runID: runID, termination: .completed)
        }
        let insertAccepted = await waitUntilAsync {
            await repository.didAcceptInsert()
        }
        XCTAssertTrue(insertAccepted)

        // The insert is already accepted, but its actor call is suspended before
        // returning to the recorder. The clear therefore linearizes between the
        // durable insert and the later repository-change publication.
        let removedCount = try await repository.deleteReceipts(
            through: terminalTimestamp
        )
        XCTAssertEqual(removedCount, 1)
        await repository.failFutureQueries()
        let queryCountBeforeRelease = await repository.observedQueryCount()
        await repository.releaseInsert()
        let receipt = try await finishTask.value
        XCTAssertEqual(receipt.runID, runID)

        let reloadAttempted = await waitUntilAsync {
            await repository.observedQueryCount() > queryCountBeforeRelease
        }
        let storedCount = await repository.storedCount()
        XCTAssertTrue(reloadAttempted)
        XCTAssertEqual(storedCount, 0)
        XCTAssertNil(harness.model.workflowRunReceipt(for: runID))
    }

    func testClearBetweenReceiptChangeAndHistorySaveDoesNotLeaveHistoryOnlyRow() async throws {
        let receiptRepository = InMemoryWorkflowRunReceiptRepository()
        let historyRepository = ClearInterleavingHistoryRepository()
        let harness = makeHarness(
            historyRepository: historyRepository,
            runReceiptRepository: receiptRepository
        )
        let receipt = try makeReceipt(
            trigger: .hotkey,
            timestamp: Date(timeIntervalSince1970: 10)
        )
        let receiptGeneration = try await receiptRepository.captureRunHistoryWriteGeneration()
        try await receiptRepository.insertTerminal(receipt)
        await harness.eventBus.publish(
            repositoryChangeEvent(
                for: receipt,
                writeGeneration: receiptGeneration
            )
        )
        let receiptLoaded = await waitUntil {
            harness.model.workflowRunReceipt(for: receipt.runID) == receipt
        }
        XCTAssertTrue(receiptLoaded)

        await harness.eventBus.publish(
            .runCompleted(
                WorkflowRunSummary(
                    runID: receipt.runID,
                    workflowID: receipt.workflowID ?? UUID(),
                    workflow: WorkflowPresentation(fallbackName: "Late history"),
                    trigger: receipt.trigger,
                    finalText: "result",
                    finishedAt: Date(timeIntervalSince1970: 30)
                )
            )
        )
        let saveStarted = await waitUntilAsync { await historyRepository.didStartSave() }
        XCTAssertTrue(saveStarted)
        let removedCount = try await historyRepository.deleteRecords(
            through: Date(timeIntervalSince1970: 20)
        )
        XCTAssertEqual(removedCount, 0)
        await historyRepository.releaseSave()
        let saveFinished = await waitUntilAsync { await historyRepository.didFinishSave() }
        XCTAssertTrue(saveFinished)

        let storedHistory = try await historyRepository.records(matching: .all)
        XCTAssertTrue(storedHistory.isEmpty)
        XCTAssertFalse(harness.model.historyRecords.contains { $0.runID == receipt.runID })
    }

    func testClearAfterRepositoryChangeStillUsesTerminalTimestampForLateCompletion() async throws {
        let historyRepository = InMemoryHistoryRepository()
        let receiptRepository = InMemoryWorkflowRunReceiptRepository()
        let maintenance = UITestLocalHistoryMaintenance(
            fallbackResult: .completed(
                LocalHistoryMaintenanceCounts(runReceiptRemovedCount: 1)
            )
        )
        let harness = makeHarness(
            historyRepository: historyRepository,
            runReceiptRepository: receiptRepository,
            localHistoryMaintenance: maintenance
        )
        let receipt = try makeReceipt(
            trigger: .hotkey,
            timestamp: Date(timeIntervalSince1970: 10)
        )
        let receiptGeneration = try await receiptRepository.captureRunHistoryWriteGeneration()
        try await receiptRepository.insertTerminal(receipt)
        await harness.eventBus.publish(
            repositoryChangeEvent(
                for: receipt,
                writeGeneration: receiptGeneration
            )
        )
        let receiptLoaded = await waitUntil {
            harness.model.workflowRunReceipt(for: receipt.runID) == receipt
        }
        XCTAssertTrue(receiptLoaded)

        let clearGeneration = try await historyRepository.captureRunHistoryWriteGeneration()
        let clearTransition = try RunHistoryClearTransition(advancing: clearGeneration)
        _ = try await historyRepository.deleteRecords(
            obsoletedBy: clearTransition,
            preservingLegacyRowsAfter: nil
        )
        _ = try await receiptRepository.deleteReceipts(
            obsoletedBy: clearTransition,
            preservingLegacyRowsAfter: nil
        )
        harness.model.clearRunHistory()
        let maintenanceFinished = await waitUntil {
            !harness.model.isLocalHistoryMaintenanceRunning
                && harness.model.workflowRunReceipt(for: receipt.runID) == nil
        }
        XCTAssertTrue(maintenanceFinished)
        XCTAssertEqual(
            harness.model.terminalReceiptWriteGenerationByRunID[receipt.runID],
            receiptGeneration
        )

        await harness.eventBus.publish(
            .runCompleted(
                WorkflowRunSummary(
                    runID: receipt.runID,
                    workflowID: receipt.workflowID ?? UUID(),
                    workflow: WorkflowPresentation(fallbackName: "Late completion"),
                    trigger: receipt.trigger,
                    finalText: "result",
                    finishedAt: Date(timeIntervalSince1970: 30)
                )
            )
        )
        for _ in 0..<20 { await Task.yield() }

        let storedHistory = try await historyRepository.records(matching: .all)
        XCTAssertTrue(storedHistory.isEmpty)
        XCTAssertFalse(harness.model.historyRecords.contains { $0.runID == receipt.runID })
    }

    func testClearWaitsForTrackedHistoryWriteBeforeStartingMaintenance() async throws {
        let historyRepository = ClearInterleavingHistoryRepository(
            rejectsObsoleteWrites: false
        )
        let maintenance = UITestLocalHistoryMaintenance()
        let harness = makeHarness(
            historyRepository: historyRepository,
            localHistoryMaintenance: maintenance
        )
        let runID = UUID()
        for _ in 0..<20 { await Task.yield() }

        await harness.eventBus.publish(
            .runCompleted(
                WorkflowRunSummary(
                    runID: runID,
                    workflowID: UUID(),
                    workflow: WorkflowPresentation(fallbackName: "Delayed cache append"),
                    trigger: .manual,
                    finalText: "result"
                )
            )
        )
        let saveStarted = await waitUntilAsync { await historyRepository.didStartSave() }
        XCTAssertTrue(saveStarted)

        harness.model.clearRunHistory()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(harness.model.isLocalHistoryMaintenanceRunning)
        await historyRepository.releaseSave()
        let saveFinished = await waitUntilAsync { await historyRepository.didFinishSave() }
        XCTAssertTrue(saveFinished)
        let maintenanceFinished = await waitUntil {
            !harness.model.isLocalHistoryMaintenanceRunning
        }
        XCTAssertTrue(maintenanceFinished)

        XCTAssertTrue(harness.model.historyRecords.contains { $0.runID == runID })
    }

    func testGroupSchedulerReceiptReachesHistoryProjectionWithoutClipboardBody() async throws {
        let privateBody = "private-group-scheduler-body-canary"
        let workflow = makeBuiltinPushToTalkPolishWorkflow()
        let configuration = try XCTUnwrap(
            workflow.parseClipboardGroupAutomationConfiguration()
        )
        let repository = InMemoryWorkflowRunReceiptRepository()
        let harness = makeHarness(
            workflows: [workflow],
            runReceiptRepository: repository
        )
        await waitForListenerSetup()
        let registration = ClipboardGroupWorkflowRegistration(
            workflowID: workflow.id,
            triggerRule: configuration.rule,
            isEnabled: false,
            isExecutionSupported: false
        )
        let scheduler = ClipboardGroupEventScheduler(
            receiptRecorder: WorkflowRunReceiptRecorder(
                repository: repository,
                eventBus: harness.eventBus
            ),
            registrationProvider: { [registration] }
        )
        let deliveryStack = DeliveryStack(
            eventBus: harness.eventBus,
            clipboardGroupEventSink: scheduler
        )

        await deliveryStack.push(
            DeliveryItem(
                workflowID: UUID(),
                text: privateBody,
                targetGroupID: ClipboardGroup.voiceGroupID
            )
        )
        await scheduler.waitUntilIdle()
        let didLoadReceipt = await waitUntil {
            harness.model.workflowRunReceiptsByRunID.count == 1
        }

        XCTAssertTrue(didLoadReceipt)
        let receipt = try XCTUnwrap(
            harness.model.workflowRunReceiptsByRunID.values.first
        )
        XCTAssertEqual(receipt.workflowID, workflow.id)
        XCTAssertEqual(receipt.trigger, .clipboardGroupEvent)
        XCTAssertEqual(receipt.termination, .skipped(reason: .unsupported))
        XCTAssertTrue(harness.model.historyRecords.isEmpty)
        let entries = HistoryTimelineBuilder.allRuns(
            records: harness.model.historyRecords,
            receipts: [receipt]
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].record)
        XCTAssertFalse(String(describing: entries).contains(privateBody))
    }

    private func makeReceipt(
        runID: UUID = UUID(),
        trigger: WorkflowRunTriggerKind,
        timestamp: Date = Date()
    ) throws -> WorkflowRunReceipt {
        try WorkflowRunReceipt(
            runID: runID,
            workflowID: UUID(),
            trigger: trigger,
            timestamp: timestamp,
            duration: .under250ms,
            termination: .completed,
            actionDetails: [
                WorkflowActionReceipt(
                    actionIndex: 0,
                    result: .injected,
                    duration: .under250ms
                ),
            ]
        )
    }

    private func repositoryChangeEvent(
        for receipt: WorkflowRunReceipt,
        writeGeneration: RunHistoryWriteGeneration? = nil
    ) -> RillEvent {
        .runReceiptRepositoryChanged(
            WorkflowRunReceiptRepositoryChange(
                runID: receipt.runID,
                terminalTimestamp: receipt.timestamp,
                writeGeneration: writeGeneration
            )
        )
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    private func waitUntilAsync(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if await predicate() { return true }
            await Task.yield()
        }
        return await predicate()
    }
}
