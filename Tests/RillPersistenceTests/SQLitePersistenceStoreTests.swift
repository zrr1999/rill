import Foundation
import SQLite3
import XCTest

@testable import RillCore
@testable import RillPersistence

private final class RecordingLocalDataProtector: LocalDataProtector, @unchecked Sendable {
  private let wrapped: AESGCMDataProtector
  private let lock = NSLock()
  private var contexts: [LocalDataProtectionContext] = []

  init(byte: UInt8) throws {
    wrapped = try AESGCMDataProtector(
      key: Data(repeating: byte, count: AESGCMDataProtector.keyByteCount)
    )
  }

  func seal(_ plaintext: Data, context: LocalDataProtectionContext) throws -> String {
    try wrapped.seal(plaintext, context: context)
  }

  func open(_ envelope: String, context: LocalDataProtectionContext) throws -> Data {
    lock.lock()
    contexts.append(context)
    lock.unlock()
    return try wrapped.open(envelope, context: context)
  }

  func resetOpenedContexts() {
    lock.lock()
    contexts.removeAll(keepingCapacity: true)
    lock.unlock()
  }

  func openedContexts() -> [LocalDataProtectionContext] {
    lock.lock()
    defer { lock.unlock() }
    return contexts
  }
}

private struct DowngradedExactV4Fixture {
  let markerEnvelope: String
  let firstHistoryID: UUID
  let firstFallbackEnvelope: String
  let firstFinalTextPlaintext: String
  let firstCorrectionEnvelope: String
  let secondHistoryID: UUID
  let secondFallbackPlaintext: String
  let secondFinalTextEnvelope: String
  let protectedSettingEnvelope: String
  let plainSettingValue: String
  let exportID: UUID
  let protectedExportPathEnvelope: String
  let exportMetadataPlaintext: String
  let diagnosticEventPlaintext: String
  let plaintextResidueSentinels: [String]
}

private struct DowngradedV4LogicalSnapshot: Equatable {
  let version: Int
  let cleanupPending: Int?
  let markerEnvelope: String?
  let values: [String?]
  let rowCounts: [Int]
}

final class SQLitePersistenceStoreTests: XCTestCase {
  func testTerminalBodyAndReceiptCommitTogetherAndRetryIdempotently() async throws {
    let store = try makeStore()
    let runID = UUID()
    let workflowID = UUID()
    let receipt = try WorkflowRunReceipt(runID: runID, workflowID: workflowID, trigger: .hotkey,
      timestamp: Date(), duration: .unavailable, termination: .completed)
    let record = WorkflowResultRecord(id: runID, runID: runID, workflowID: workflowID,
      workflow: .init(fallbackName: "Atomic run"), finalText: "Preserved text",
      timestamp: receipt.timestamp, outcome: .completed, trigger: .hotkey)
    let generation = try await store.captureRunHistoryWriteGeneration()
    try await store.commitTerminal(receipt, history: record, generation: generation)
    try await store.commitTerminal(receipt, history: record, generation: generation)
    let rows = try await store.records(matching: .init(runID: runID))
    let receipts = try await store.receipts(matching: .init(runID: runID))
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows.first?.finalText, record.finalText)
    XCTAssertEqual(rows.first?.timestamp.timeIntervalSince1970, record.timestamp.timeIntervalSince1970)
    XCTAssertEqual(receipts, [receipt])
  }

  func testRejectedTerminalBodyRollsBackReceipt() async throws {
    let store = try makeStore()
    let recordID = UUID()
    try await store.save(WorkflowResultRecord(id: recordID, workflow: .init(fallbackName: "Existing"), outcome: .failed))
    let receipt = try WorkflowRunReceipt(runID: UUID(), workflowID: UUID(), trigger: .hotkey,
      timestamp: Date(), duration: .unavailable, termination: .completed)
    let conflicting = WorkflowResultRecord(id: recordID, runID: receipt.runID, workflowID: receipt.workflowID,
      workflow: .init(fallbackName: "Atomic run"), finalText: "Preserved text",
      timestamp: receipt.timestamp, outcome: .completed, trigger: .hotkey)
    do {
      try await store.commitTerminal(receipt, history: conflicting,
        generation: try await store.captureRunHistoryWriteGeneration())
      XCTFail("A conflicting body must reject the entire terminal transaction")
    } catch let error as HistoryRepositoryError {
      XCTAssertEqual(error, .conflictingHistoryRecord(recordID: recordID))
    }
    let receipts = try await store.receipts(matching: .init(runID: receipt.runID))
    XCTAssertTrue(receipts.isEmpty)
    let rows = try await store.records(matching: .all)
    XCTAssertEqual(rows.count, 1)
    XCTAssertNil(rows.first?.runID)
  }

  func testHistoryRoundTrip() async throws {
    let store = try makeStore()
    let workflowID = UUID()
    let record = WorkflowResultRecord(
      runID: UUID(),
      workflowID: workflowID,
      workflow: WorkflowPresentation(
        fallbackName: "Persisted Workflow", titleKey: .directDemoClipboard),
      finalText: "hello persistence",
      timestamp: Date(timeIntervalSince1970: 42),
      isRecordRelated: true,
      outcome: .completed,
      trigger: .hotkey
    )

    try await store.save(record)
    let records = try await store.records(matching: HistoryQuery(workflowID: workflowID, limit: 10))

    XCTAssertEqual(records, [record])

    let updated = WorkflowResultRecord(
      id: record.id,
      runID: record.runID,
      workflowID: workflowID,
      workflow: record.workflow,
      finalText: "updated persistence",
      timestamp: record.timestamp,
      isRecordRelated: record.isRecordRelated,
      outcome: .completed,
      trigger: .hotkey
    )
    try await store.save(updated)
    let updatedRecords = try await store.records(
      matching: HistoryQuery(workflowID: workflowID, limit: 10)
    )

    XCTAssertEqual(updatedRecords, [updated])
  }

  func testWorkflowRunReceiptRoundTripsFiltersAndRejectsConflictingTerminal() async throws {
    let store = try makeStore()
    let runID = UUID()
    let workflowID = UUID()
    let receipt = try WorkflowRunReceipt(
      runID: runID,
      workflowID: workflowID,
      trigger: .hotkey,
      timestamp: Date(timeIntervalSince1970: 42),
      duration: .ms250To999,
      termination: .completed,
      stepDetails: [
        WorkflowStepReceipt(
          stepIndex: 0, kind: .recognizeSpeech, result: .completed,
          duration: .under250ms, durationMilliseconds: 123
        ),
        WorkflowStepReceipt(
          stepIndex: 1, kind: .llmRewrite, result: .completed,
          duration: .ms250To999, durationMilliseconds: 456
        )
      ],
      actionDetails: [
        WorkflowActionReceipt(
          actionIndex: 0,
          result: .copiedToClipboard,
          duration: .under250ms
        )
      ]
    )

    try await store.insertTerminal(receipt)
    try await store.insertTerminal(receipt)

    let allReceipts = try await store.receipts(matching: .all)
    let runReceipts = try await store.receipts(
      matching: WorkflowRunReceiptQuery(runID: runID)
    )
    let workflowReceipts = try await store.receipts(
      matching: WorkflowRunReceiptQuery(workflowID: workflowID)
    )
    let triggerReceipts = try await store.receipts(
      matching: WorkflowRunReceiptQuery(trigger: .hotkey)
    )
    let completedReceipts = try await store.receipts(
      matching: WorkflowRunReceiptQuery(outcome: .completed)
    )
    let newerReceipts = try await store.receipts(
      matching: WorkflowRunReceiptQuery(since: Date(timeIntervalSince1970: 43))
    )
    let zeroLimitedReceipts = try await store.receipts(
      matching: WorkflowRunReceiptQuery(workflowID: workflowID, limit: 0)
    )
    XCTAssertEqual(allReceipts, [receipt])
    XCTAssertEqual(runReceipts, [receipt])
    XCTAssertEqual(workflowReceipts, [receipt])
    XCTAssertEqual(triggerReceipts, [receipt])
    XCTAssertEqual(completedReceipts, [receipt])
    XCTAssertTrue(newerReceipts.isEmpty)
    XCTAssertTrue(zeroLimitedReceipts.isEmpty)

    let conflicting = try WorkflowRunReceipt(
      runID: runID,
      workflowID: workflowID,
      trigger: .hotkey,
      timestamp: receipt.timestamp,
      duration: .ms250To999,
      termination: .failed(stage: .delivering, code: .processing)
    )
    do {
      try await store.insertTerminal(conflicting)
      XCTFail("Expected a conflicting terminal receipt to be rejected.")
    } catch let error as WorkflowRunReceiptRepositoryError {
      XCTAssertEqual(error, .conflictingTerminalReceipt(runID: runID))
    }
  }

  func testWorkflowRunReceiptQuerySkipsCorruptNewestRowWithoutConsumingLimit() async throws {
    let store = try makeStore()
    let databaseURL = await store.databaseURL
    let corruptNewest = try workflowRunReceipt(timestamp: 30)
    let validOlder = try workflowRunReceipt(timestamp: 20)
    try await store.insertTerminal(corruptNewest)
    try await store.insertTerminal(validOlder)
    try replaceRunReceiptPayload(
      "invalid-protected-receipt",
      runID: corruptNewest.runID,
      at: databaseURL
    )

    let receipts = try await store.receipts(
      matching: WorkflowRunReceiptQuery(limit: 1)
    )

    XCTAssertEqual(receipts, [validOlder])
  }

  func testWorkflowRunReceiptQuerySkipsCorruptMiddleRowAndPreservesPayloadFilters() async throws {
    let store = try makeStore()
    let databaseURL = await store.databaseURL
    let workflowID = UUID()
    let matchingNewest = try workflowRunReceipt(
      workflowID: workflowID,
      trigger: .hotkey,
      timestamp: 40
    )
    let nonmatching = try workflowRunReceipt(
      workflowID: UUID(),
      trigger: .manual,
      timestamp: 30
    )
    let corruptMiddle = try workflowRunReceipt(
      workflowID: workflowID,
      trigger: .hotkey,
      timestamp: 20
    )
    let matchingOldest = try workflowRunReceipt(
      workflowID: workflowID,
      trigger: .hotkey,
      timestamp: 10
    )
    for receipt in [matchingNewest, nonmatching, corruptMiddle, matchingOldest] {
      try await store.insertTerminal(receipt)
    }
    try replaceRunReceiptPayload(
      "invalid-protected-receipt",
      runID: corruptMiddle.runID,
      at: databaseURL
    )

    let receipts = try await store.receipts(
      matching: WorkflowRunReceiptQuery(
        workflowID: workflowID,
        trigger: .hotkey,
        outcome: .completed,
        limit: 2
      )
    )

    XCTAssertEqual(receipts, [matchingNewest, matchingOldest])
  }

  func testWorkflowRunReceiptQueryFiltersExactRunIDBatchBeforeApplyingLimit() async throws {
    let store = try makeStore()
    let selectedOlder = try workflowRunReceipt(timestamp: 10)
    let selectedNewer = try workflowRunReceipt(timestamp: 20)
    let unrelatedNewest = try workflowRunReceipt(timestamp: 30)
    for receipt in [selectedOlder, selectedNewer, unrelatedNewest] {
      try await store.insertTerminal(receipt)
    }

    let receipts = try await store.receipts(
      matching: WorkflowRunReceiptQuery(
        runIDs: [selectedOlder.runID, selectedNewer.runID],
        limit: 2
      )
    )

    XCTAssertEqual(receipts, [selectedNewer, selectedOlder])
  }

  func testWorkflowRunReceiptDeletionUsesStrictCutoff() async throws {
    let store = try makeStore()
    let older = try WorkflowRunReceipt(
      runID: UUID(),
      workflowID: nil,
      trigger: .manual,
      timestamp: Date(timeIntervalSince1970: 10),
      duration: .under250ms,
      termination: .completed
    )
    let boundary = try WorkflowRunReceipt(
      runID: UUID(),
      workflowID: nil,
      trigger: .recordDelivery,
      timestamp: Date(timeIntervalSince1970: 20),
      duration: .under250ms,
      termination: .skipped(reason: .allActionsSkipped)
    )
    let newer = try WorkflowRunReceipt(
      runID: UUID(),
      workflowID: nil,
      trigger: .hotkey,
      timestamp: Date(timeIntervalSince1970: 30),
      duration: .under250ms,
      termination: .completed
    )
    try await store.insertTerminal(older)
    try await store.insertTerminal(boundary)
    try await store.insertTerminal(newer)

    let prunedCount = try await store.deleteReceipts(
      olderThan: Date(timeIntervalSince1970: 20)
    )
    let remaining = try await store.receipts(matching: .all)
    let boundedClearCount = try await store.deleteReceipts(
      through: Date(timeIntervalSince1970: 20)
    )
    let afterBoundedClear = try await store.receipts(matching: .all)
    let clearedCount = try await store.deleteAllReceipts()
    let repeatedClearCount = try await store.deleteAllReceipts()
    XCTAssertEqual(prunedCount, 1)
    XCTAssertEqual(remaining, [newer, boundary])
    XCTAssertEqual(boundedClearCount, 1)
    XCTAssertEqual(afterBoundedClear, [newer])
    XCTAssertEqual(clearedCount, 1)
    XCTAssertEqual(repeatedClearCount, 0)
  }

  func testLogicalRunHistoryGenerationSurvivesReopenRejectsOldIntentAndAcceptsClockRollback() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-clear-barrier.sqlite")
    let protector = try testProtector(byte: 0x4C)
    let oldGeneration: RunHistoryWriteGeneration

    do {
      let initialStore = try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: protector
      )
      try await initialStore.save(historyRecord(text: "initial", timestamp: 20))
      try await initialStore.insertTerminal(workflowRunReceipt(timestamp: 20))
      try await initialStore.save(diagnosticEvent(name: "initial", timestamp: 20))
      oldGeneration = try await initialStore.captureRunHistoryWriteGeneration()
      let transition = try RunHistoryClearTransition(
        intentID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
        advancing: oldGeneration
      )
      let historyRemovedCount = try await initialStore.deleteRecords(
        obsoletedBy: transition,
        preservingLegacyRowsAfter: nil
      )
      let receiptRemovedCount = try await initialStore.deleteReceipts(
        obsoletedBy: transition,
        preservingLegacyRowsAfter: nil
      )
      let diagnosticRemovedCount = try await initialStore.deleteEvents(
        obsoletedBy: transition,
        preservingLegacyRowsAfter: nil
      )
      XCTAssertEqual(historyRemovedCount, 1)
      XCTAssertEqual(receiptRemovedCount, 1)
      XCTAssertEqual(diagnosticRemovedCount, 1)
    }
    XCTAssertEqual(try runHistoryGeneration(at: databaseURL), 1)

    let reopened = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: protector
    )
    do {
      try await reopened.save(
        historyRecord(text: "late", timestamp: 10_000),
        generation: oldGeneration
      )
      XCTFail("Expected old-generation history to be rejected after reopening.")
    } catch {
      XCTAssertEqual(error as? HistoryRepositoryError, .writeObsoletedByClearBarrier)
    }
    let oldReceipt = try workflowRunReceipt(timestamp: 10_000)
    do {
      try await reopened.insertTerminal(oldReceipt, generation: oldGeneration)
      XCTFail("Expected an old-generation receipt to be rejected after reopening.")
    } catch {
      XCTAssertEqual(
        error as? WorkflowRunReceiptRepositoryError,
        .writeObsoletedByClearBarrier(runID: oldReceipt.runID)
      )
    }
    do {
      try await reopened.save(
        diagnosticEvent(name: "old-intent", timestamp: 10_000),
        generation: oldGeneration
      )
      XCTFail("Expected an old-generation diagnostic to be rejected after reopening.")
    } catch {
      XCTAssertEqual(error as? DiagnosticRepositoryError, .writeObsoletedByClearBarrier)
    }

    let newGeneration = try await reopened.captureRunHistoryWriteGeneration()
    let rollbackHistory = historyRecord(text: "new intent", timestamp: 19)
    let rollbackReceipt = try workflowRunReceipt(timestamp: 19)
    let rollbackDiagnostic = diagnosticEvent(name: "new-intent", timestamp: 19)
    try await reopened.save(rollbackHistory, generation: newGeneration)
    try await reopened.insertTerminal(rollbackReceipt, generation: newGeneration)
    try await reopened.save(rollbackDiagnostic, generation: newGeneration)

    let reopenedHistory = try await reopened.records(matching: .all)
    let reopenedReceipts = try await reopened.receipts(matching: .all)
    let reopenedDiagnostics = try await reopened.events(matching: .init())
    XCTAssertEqual(reopenedHistory, [rollbackHistory])
    XCTAssertEqual(reopenedReceipts, [rollbackReceipt])
    XCTAssertEqual(
      reopenedDiagnostics,
      [DiagnosticEventSanitizer.sanitize(rollbackDiagnostic)]
    )
  }

  func testPartialLogicalClearHidesOldGenerationsAcrossReopenAndExactReceiptReads() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-partial-clear.sqlite")
    let protector = try testProtector(byte: 0x6D)
    let oldHistory = historyRecord(text: "old generation", timestamp: 30)
    let oldReceipt = try workflowRunReceipt(timestamp: 30)
    let oldDiagnostic = diagnosticEvent(name: "old-generation", timestamp: 30)
    let transition: RunHistoryClearTransition

    do {
      let initialStore = try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: protector
      )
      try await initialStore.save(oldHistory)
      try await initialStore.insertTerminal(oldReceipt)
      try await initialStore.save(oldDiagnostic)
      let generation = try await initialStore.captureRunHistoryWriteGeneration()
      transition = try RunHistoryClearTransition(
        advancing: generation
      )

      let removedCount = try await initialStore.deleteRecords(
        obsoletedBy: transition,
        preservingLegacyRowsAfter: nil
      )
      let visibleHistory = try await initialStore.records(matching: .all)
      let visibleReceipts = try await initialStore.receipts(matching: .all)
      let visibleDiagnostics = try await initialStore.events(matching: .init())
      XCTAssertEqual(removedCount, 1)
      XCTAssertTrue(visibleHistory.isEmpty)
      XCTAssertTrue(visibleReceipts.isEmpty)
      XCTAssertTrue(visibleDiagnostics.isEmpty)
    }

    XCTAssertNotNil(try rawRunReceiptPayload(runID: oldReceipt.runID, at: databaseURL))
    let reopened = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: protector
    )
    let reopenedGeneration = try await reopened.captureRunHistoryWriteGeneration()
    let reopenedHistory = try await reopened.records(matching: .all)
    let reopenedReceipts = try await reopened.receipts(matching: .all)
    let reopenedSingleReceipt = try await reopened.receipts(
      matching: WorkflowRunReceiptQuery(runID: oldReceipt.runID)
    )
    let reopenedExactReceipts = try await reopened.receipts(
      matching: WorkflowRunReceiptQuery(runIDs: [oldReceipt.runID])
    )
    let reopenedDiagnostics = try await reopened.events(matching: .init())
    XCTAssertEqual(reopenedGeneration, transition.nextGeneration)
    XCTAssertTrue(reopenedHistory.isEmpty)
    XCTAssertTrue(reopenedReceipts.isEmpty)
    XCTAssertTrue(reopenedSingleReceipt.isEmpty)
    XCTAssertTrue(reopenedExactReceipts.isEmpty)
    XCTAssertTrue(reopenedDiagnostics.isEmpty)

    let replacementReceipt = try WorkflowRunReceipt(
      runID: oldReceipt.runID,
      workflowID: nil,
      trigger: .hotkey,
      timestamp: Date(timeIntervalSince1970: 10),
      duration: .under250ms,
      termination: .completed
    )
    let currentHistory = historyRecord(text: "current generation", timestamp: 10)
    let currentDiagnostic = diagnosticEvent(name: "current-generation", timestamp: 10)
    try await reopened.save(currentHistory, generation: transition.nextGeneration)
    try await reopened.insertTerminal(
      replacementReceipt,
      generation: transition.nextGeneration
    )
    try await reopened.save(currentDiagnostic, generation: transition.nextGeneration)

    let currentHistoryRecords = try await reopened.records(matching: .all)
    let currentReceipts = try await reopened.receipts(matching: .all)
    let currentExactReceipts = try await reopened.receipts(
      matching: WorkflowRunReceiptQuery(runIDs: [oldReceipt.runID])
    )
    let currentDiagnostics = try await reopened.events(matching: .init())
    XCTAssertEqual(currentHistoryRecords, [currentHistory])
    XCTAssertEqual(currentReceipts, [replacementReceipt])
    XCTAssertEqual(
      currentExactReceipts,
      [replacementReceipt]
    )
    XCTAssertEqual(
      currentDiagnostics,
      [DiagnosticEventSanitizer.sanitize(currentDiagnostic)]
    )
  }

  func testConcurrentLogicalClearRejectsWriteIntentCapturedBeforeGenerationAdvance() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-clear-race.sqlite")
    let baseProtector = try testProtector(byte: 0x5A)
    let blockingProtector = BlockingHistorySealProtector(base: baseProtector)
    defer { blockingProtector.unblock() }
    let writingStore = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: blockingProtector
    )
    let clearingStore = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: baseProtector
    )
    let lateRecord = historyRecord(text: "must-not-return", timestamp: 10_000)

    let writeTask = Task {
      try await writingStore.save(lateRecord)
    }
    await blockingProtector.waitUntilBlocked()

    let clearGeneration = try await clearingStore.captureRunHistoryWriteGeneration()
    let clearTransition = try RunHistoryClearTransition(advancing: clearGeneration)
    let removedCount = try await clearingStore.deleteRecords(
      obsoletedBy: clearTransition,
      preservingLegacyRowsAfter: nil
    )
    XCTAssertEqual(
      removedCount,
      0
    )
    blockingProtector.unblock()

    do {
      try await writeTask.value
      XCTFail("The write that began before clear must not recreate cleared history.")
    } catch {
      XCTAssertEqual(
        error as? HistoryRepositoryError,
        .writeObsoletedByClearBarrier
      )
    }
    let remainingRecords = try await clearingStore.records(matching: .all)
    XCTAssertTrue(remainingRecords.isEmpty)
  }

  func testConcurrentClearRejectsWholeTerminalWhileBodyEncryptionIsPending() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-clear-race.sqlite")
    let baseProtector = try testProtector(byte: 0x5A)
    let blockingProtector = BlockingHistorySealProtector(base: baseProtector)
    defer { blockingProtector.unblock() }
    let writingStore = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: blockingProtector
    )
    let clearingStore = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: baseProtector
    )
    let receipt = try WorkflowRunReceipt(runID: UUID(), workflowID: UUID(), trigger: .hotkey,
      timestamp: Date(timeIntervalSince1970: 10_000), duration: .unavailable, termination: .completed)
    let lateRecord = WorkflowResultRecord(id: receipt.runID, runID: receipt.runID, workflowID: receipt.workflowID,
      workflow: .init(fallbackName: "Atomic"), finalText: "must-not-return", timestamp: receipt.timestamp,
      outcome: .completed, trigger: .hotkey)
    let generation = try await writingStore.captureRunHistoryWriteGeneration()
    let writeTask = Task {
      try await writingStore.commitTerminal(receipt, history: lateRecord, generation: generation)
    }
    await blockingProtector.waitUntilBlocked()

    let clearGeneration = try await clearingStore.captureRunHistoryWriteGeneration()
    let clearTransition = try RunHistoryClearTransition(advancing: clearGeneration)
    let removedCount = try await clearingStore.deleteRecords(
      obsoletedBy: clearTransition,
      preservingLegacyRowsAfter: nil
    )
    XCTAssertEqual(
      removedCount,
      0
    )
    blockingProtector.unblock()

    do {
      try await writeTask.value
      XCTFail("The write that began before clear must not recreate cleared history.")
    } catch {
      XCTAssertEqual(
        error as? WorkflowRunReceiptRepositoryError,
        .writeObsoletedByClearBarrier(runID: receipt.runID)
      )
    }
    let remainingRecords = try await clearingStore.records(matching: .all)
    XCTAssertTrue(remainingRecords.isEmpty)
    let receipts = try await clearingStore.receipts(matching: .all)
    XCTAssertTrue(receipts.isEmpty)
  }

  func testLogicalClearTransitionReplaysIdempotentlyAndRejectsConflicts() async throws {
    let store = try makeStore()
    let generationZero = try await store.captureRunHistoryWriteGeneration()
    let first = try RunHistoryClearTransition(
      intentID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
      advancing: generationZero
    )
    _ = try await store.deleteRecords(
      obsoletedBy: first,
      preservingLegacyRowsAfter: nil
    )
    let generationOne = try await store.captureRunHistoryWriteGeneration()
    let nextGenerationRecord = historyRecord(text: "must survive replay", timestamp: 1)
    try await store.save(nextGenerationRecord, generation: generationOne)

    let replayRemovedCount = try await store.deleteRecords(
      obsoletedBy: first,
      preservingLegacyRowsAfter: nil
    )
    let recordsAfterReplay = try await store.records(matching: .all)
    let generationAfterReplay = try await store.captureRunHistoryWriteGeneration()
    XCTAssertEqual(replayRemovedCount, 0)
    XCTAssertEqual(recordsAfterReplay, [nextGenerationRecord])
    XCTAssertEqual(generationAfterReplay, generationOne)

    let competing = try RunHistoryClearTransition(
      intentID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
      previousGeneration: first.previousGeneration,
      nextGeneration: first.nextGeneration
    )
    do {
      _ = try await store.deleteRecords(
        obsoletedBy: competing,
        preservingLegacyRowsAfter: nil
      )
      XCTFail("A different clear intent must not be mistaken for a replay.")
    } catch {
      XCTAssertEqual(error as? RunHistoryGenerationError, .clearTransitionConflict)
    }

    let second = try RunHistoryClearTransition(
      intentID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
      advancing: generationOne
    )
    _ = try await store.deleteRecords(
      obsoletedBy: second,
      preservingLegacyRowsAfter: nil
    )
    do {
      _ = try await store.deleteRecords(
        obsoletedBy: first,
        preservingLegacyRowsAfter: nil
      )
      XCTFail("An old clear intent must not replay across a future generation.")
    } catch {
      XCTAssertEqual(error as? RunHistoryGenerationError, .clearTransitionConflict)
    }
  }

  func testLegacyTimestampBridgePromotesPostIntentRowsAcrossAllRunHistoryTables() async throws {
    let store = try makeStore()
    let oldHistory = historyRecord(text: "old", timestamp: 90)
    let retainedHistory = historyRecord(text: "retained", timestamp: 110)
    let oldReceipt = try workflowRunReceipt(timestamp: 90)
    let retainedReceipt = try workflowRunReceipt(timestamp: 110)
    let oldDiagnostic = diagnosticEvent(name: "old", timestamp: 90)
    let retainedDiagnostic = diagnosticEvent(name: "retained", timestamp: 110)
    try await store.save(oldHistory)
    try await store.save(retainedHistory)
    try await store.insertTerminal(oldReceipt)
    try await store.insertTerminal(retainedReceipt)
    try await store.save(oldDiagnostic)
    try await store.save(retainedDiagnostic)
    let generation = try await store.captureRunHistoryWriteGeneration()
    let transition = try RunHistoryClearTransition(advancing: generation)
    let legacyBoundary = Date(timeIntervalSince1970: 100)

    let historyCount = try await store.deleteRecords(
      obsoletedBy: transition,
      preservingLegacyRowsAfter: legacyBoundary
    )
    let receiptCount = try await store.deleteReceipts(
      obsoletedBy: transition,
      preservingLegacyRowsAfter: legacyBoundary
    )
    let diagnosticCount = try await store.deleteEvents(
      obsoletedBy: transition,
      preservingLegacyRowsAfter: legacyBoundary
    )
    let history = try await store.records(matching: .all)
    let receipts = try await store.receipts(matching: .all)
    let diagnostics = try await store.events(matching: .init())

    XCTAssertEqual(historyCount, 1)
    XCTAssertEqual(receiptCount, 1)
    XCTAssertEqual(diagnosticCount, 1)
    XCTAssertEqual(history, [retainedHistory])
    XCTAssertEqual(receipts, [retainedReceipt])
    XCTAssertEqual(diagnostics, [DiagnosticEventSanitizer.sanitize(retainedDiagnostic)])
  }

  func testHistoryQuerySkipsCorruptNewestRowWithoutConsumingLimit() async throws {
    let store = try makeStore()
    let databaseURL = await store.databaseURL
    let corruptNewest = historyRecord(text: "corrupt", timestamp: 30)
    let validOlder = historyRecord(text: "valid", timestamp: 20)
    try await store.save(corruptNewest)
    try await store.save(validOlder)
    try replaceHistoryValue(
      "invalid-protected-history",
      column: "final_text",
      recordID: corruptNewest.id,
      at: databaseURL
    )

    let records = try await store.records(matching: HistoryQuery(limit: 1))

    XCTAssertEqual(records, [validOlder])
  }

  func testWorkflowRunReceiptPayloadIsProtectedInSQLiteAndWAL() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-receipt.sqlite")
    let store = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: testProtector(byte: 0x4A)
    )
    let receipt = try WorkflowRunReceipt(
      runID: UUID(),
      workflowID: UUID(),
      trigger: .recordReplay,
      timestamp: Date(timeIntervalSince1970: 73),
      duration: .s1To4,
      termination: .failed(stage: .delivering, code: .processing),
      actionDetails: [
        WorkflowActionReceipt(
          actionIndex: 0,
          result: .failed,
          duration: .ms250To999
        )
      ]
    )

    try await store.insertTerminal(receipt)
    try await store.purgeSensitiveStorageResidue()

    let envelope = try XCTUnwrap(
      rawRunReceiptPayload(runID: receipt.runID, at: databaseURL)
    )
    XCTAssertTrue(envelope.hasPrefix("rill:v1:"))
    for sentinel in ["recordReplay", "delivering", "processing", "ms250To999"] {
      let data = Data(sentinel.utf8)
      for file in try persistedDatabaseBytes(at: databaseURL) {
        XCTAssertNil(
          file.data.range(of: data),
          "Run receipt payload reached \(file.name) as plaintext."
        )
      }
    }
  }

  func testV4DatabaseMigratesToV11WithoutFabricatingReceipts() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-v4-to-v11.sqlite")
    let protector = try testProtector(byte: 0x4B)
    _ = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: protector
    )
    try simulateV4DatabaseByRemovingReceiptStorage(at: databaseURL)

    let migrated = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: protector
    )
    let receipts = try await migrated.receipts(matching: .all)

    XCTAssertEqual(try schemaVersion(at: databaseURL), 14)
    XCTAssertTrue(try runReceiptTableExists(at: databaseURL))
    XCTAssertTrue(try runHistoryGenerationTableExists(at: databaseURL))
    XCTAssertTrue(receipts.isEmpty)
  }

  func testV5DatabaseMigratesToV11WithInitialGeneration() throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-v5-to-v11.sqlite")
    let protector = try testProtector(byte: 0x4D)
    _ = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: protector
    )
    try simulateV5DatabaseByRemovingGenerationStorage(at: databaseURL)

    _ = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: protector
    )

    XCTAssertEqual(try schemaVersion(at: databaseURL), 14)
    XCTAssertTrue(try runHistoryGenerationTableExists(at: databaseURL))
    XCTAssertEqual(try runHistoryGeneration(at: databaseURL), 0)
  }

  func testV6MigrationAddsNullableAuthoritativeTriggerWithoutClassifyingLegacyRows() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-v6-to-v11.sqlite")
    let protector = try testProtector(byte: 0x4F)
    let legacyRecord = WorkflowResultRecord(
      runID: UUID(),
      workflowID: UUID(),
      workflow: WorkflowPresentation(fallbackName: "Legacy unclassified run"),
      finalText: "legacy body",
      timestamp: Date(timeIntervalSince1970: 42),
      outcome: .completed
    )
    do {
      let store = try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: protector
      )
      try await store.save(legacyRecord)
      try await store.purgeSensitiveStorageResidue()
    }
    try simulateV6DatabaseByRemovingHistoryTrigger(at: databaseURL)

    XCTAssertEqual(try schemaVersion(at: databaseURL), 6)
    XCTAssertFalse(try historyColumnNames(at: databaseURL).contains("trigger_kind"))

    let migrated = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: protector
    )
    let records = try await migrated.records(matching: .all)

    XCTAssertEqual(try schemaVersion(at: databaseURL), 14)
    XCTAssertTrue(try historyColumnNames(at: databaseURL).contains("trigger_kind"))
    XCTAssertEqual(records, [legacyRecord])
    XCTAssertNil(records.first?.trigger)
  }

  func testV7DatabaseMigratesAllRunHistoryTablesToInitialGenerationWithoutDataLoss() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-v7-to-v11.sqlite")
    let protector = try testProtector(byte: 0x50)
    let history = browsingRecord(
      id: UUID(),
      runID: nil,
      trigger: .manual,
      text: "legacy history",
      timestamp: 42
    )
    let receipt = try workflowRunReceipt(timestamp: 43)
    let diagnostic = diagnosticEvent(name: "legacy", timestamp: 44)
    do {
      let store = try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: protector
      )
      try await store.save(history)
      try await store.insertTerminal(receipt)
      try await store.save(diagnostic)
    }
    try simulateV7DatabaseWithoutLogicalGeneration(at: databaseURL)

    XCTAssertEqual(try schemaVersion(at: databaseURL), 7)
    XCTAssertFalse(try runHistoryGenerationTableExists(at: databaseURL))
    for tableName in ["history_records", "workflow_run_receipts", "diagnostic_events"] {
      XCTAssertFalse(try columnNames(in: tableName, at: databaseURL).contains("write_generation"))
    }

    let migrated = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: protector
    )

    XCTAssertEqual(try schemaVersion(at: databaseURL), 14)
    XCTAssertEqual(try runHistoryGeneration(at: databaseURL), 0)
    for tableName in ["history_records", "workflow_run_receipts", "diagnostic_events"] {
      XCTAssertTrue(try columnNames(in: tableName, at: databaseURL).contains("write_generation"))
    }
    XCTAssertTrue(
      try columnNames(in: "history_records", at: databaseURL).contains("write_ordinal")
    )
    XCTAssertTrue(
      try columnNames(in: "workflow_run_receipts", at: databaseURL).contains("write_ordinal")
    )
    XCTAssertTrue(
      try columnNames(in: "history_records", at: databaseURL).contains(
        "has_nonempty_final_text"
      )
    )
    let migratedHistory = try await migrated.records(matching: .all)
    let migratedReceipts = try await migrated.receipts(matching: .all)
    let migratedDiagnostics = try await migrated.events(matching: .init())
    XCTAssertEqual(migratedHistory, [history])
    XCTAssertEqual(migratedReceipts, [receipt])
    XCTAssertEqual(
      migratedDiagnostics,
      [DiagnosticEventSanitizer.sanitize(diagnostic)]
    )
    let browsePage = try await migrated.page(
      .first(
        scope: .allRuns,
        retentionCutoff: nil,
        contentAccess: .metadataOnly,
        limit: 10
      )
    )
    XCTAssertEqual(browsePage.session.snapshotWriteOrdinal, 2)
    XCTAssertEqual(
      browsePage.entries.first { $0.recordMetadata?.recordID == history.id }?
        .recordMetadata?.hasNonemptyFinalText,
      true
    )
  }

  func testHistoryCorrectionProvenanceRoundTripsAndCanBeClearedByUpsert() async throws {
    let store = try makeStore()
    let id = UUID()
    let source = RecognitionCorrectionSource(
      preMappingText: "Vox Type keeps provenance",
      context: VocabularyRuleContext(
        bundleIdentifier: "com.example.editor",
        recordCollectionID: UUID(),
        locale: "en-US"
      ),
      languageModelInputTexts: ["normalized question", "second LLM input"]
    )
    let correctedRecord = WorkflowResultRecord(
      id: id,
      runID: UUID(),
      workflowID: UUID(),
      workflow: WorkflowPresentation(fallbackName: "Corrected Workflow"),
      finalText: "Rill keeps provenance",
      timestamp: Date(timeIntervalSince1970: 43),
      outcome: .completed,
      correctionSource: source
    )

    try await store.save(correctedRecord)
    let persistedCorrectedRecords = try await store.records(matching: .all)

    XCTAssertEqual(persistedCorrectedRecords, [correctedRecord])

    let uncorrectedRecord = WorkflowResultRecord(
      id: id,
      runID: correctedRecord.runID,
      workflowID: correctedRecord.workflowID,
      workflow: correctedRecord.workflow,
      finalText: correctedRecord.finalText,
      timestamp: correctedRecord.timestamp,
      outcome: correctedRecord.outcome
    )
    try await store.save(uncorrectedRecord)
    let persistedUncorrectedRecords = try await store.records(matching: .all)

    XCTAssertEqual(persistedUncorrectedRecords, [uncorrectedRecord])
  }

  func testHistoryPersistenceBoundaryNeverStoresRawFailureDetails() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-test.sqlite")
    let store = try SQLitePersistenceStore(databaseURL: databaseURL)
    let sentinel = "provider-private-response-" + UUID().uuidString

    try await store.save(
      WorkflowResultRecord(
        workflow: WorkflowPresentation(fallbackName: "Failure"),
        failureMessage: sentinel,
        outcome: .failed
      )
    )
    try await store.purgeSensitiveStorageResidue()

    let records = try await store.records(matching: .all)
    XCTAssertEqual(records.first?.failureMessage, HistoryFailureSanitizer.genericMessage)
    let sentinelData = Data(sentinel.utf8)
    for file in try persistedDatabaseBytes(at: databaseURL) {
      XCTAssertNil(
        file.data.range(of: sentinelData),
        "Raw history failure content reached \(file.name)."
      )
    }
  }

  func testV1MigrationSanitizesAndPhysicallyRemovesLegacyFailureDetails() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-v1.sqlite")
    let sentinel = "legacy-provider-body-" + UUID().uuidString
    try createV1HistoryDatabase(at: databaseURL, failureMessage: sentinel)

    let store = try SQLitePersistenceStore(databaseURL: databaseURL)
    let records = try await store.records(matching: .all)

    XCTAssertEqual(records.first?.failureMessage, HistoryFailureSanitizer.genericMessage)
    let sentinelData = Data(sentinel.utf8)
    for file in try persistedDatabaseBytes(at: databaseURL) {
      XCTAssertNil(
        file.data.range(of: sentinelData),
        "The v1 migration retained raw failure content in \(file.name)."
      )
    }
  }

  func testV2MigrationAddsNullableCorrectionProvenanceWithoutChangingLegacyRows() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-v2.sqlite")
    let legacyID = UUID()
    try createV2HistoryDatabase(at: databaseURL, recordID: legacyID)

    let store = try SQLitePersistenceStore(databaseURL: databaseURL)
    let records = try await store.records(matching: .all)

    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records.first?.id, legacyID)
    XCTAssertEqual(records.first?.finalText, "legacy v2 history")
    XCTAssertNil(records.first?.correctionSource)
    XCTAssertEqual(try schemaVersion(at: databaseURL), 14)
    XCTAssertTrue(try historyColumnNames(at: databaseURL).contains("correction_source_json"))
  }

  func testV3MigrationRecoversWhenColumnWasAddedBeforeSchemaVersionAdvanced() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-interrupted-v3.sqlite")
    let legacyID = UUID()
    try createV2HistoryDatabase(at: databaseURL, recordID: legacyID)
    try simulateInterruptedV3Migration(at: databaseURL)

    XCTAssertEqual(try schemaVersion(at: databaseURL), 2)
    XCTAssertTrue(try historyColumnNames(at: databaseURL).contains("correction_source_json"))

    let store = try SQLitePersistenceStore(databaseURL: databaseURL)
    let migratedRecords = try await store.records(matching: .all)

    XCTAssertEqual(migratedRecords.count, 1)
    XCTAssertEqual(migratedRecords.first?.id, legacyID)
    XCTAssertNil(migratedRecords.first?.correctionSource)
    XCTAssertEqual(try schemaVersion(at: databaseURL), 14)

    let correctedRecord = WorkflowResultRecord(
      workflow: WorkflowPresentation(fallbackName: "Recovered migration"),
      finalText: "corrected text",
      timestamp: Date(timeIntervalSince1970: 3),
      outcome: .completed,
      correctionSource: RecognitionCorrectionSource(
        preMappingText: "pre-mapping text",
        context: VocabularyRuleContext(locale: "en-US")
      )
    )
    try await store.save(correctedRecord)
    let recordsAfterSave = try await store.records(matching: .all)

    XCTAssertEqual(recordsAfterSave.first, correctedRecord)
  }

  func testV4ProtectsHistoryAndSettingsBeforeTheyReachSQLiteFiles() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-v4.sqlite")
    let protector = try testProtector(byte: 0x31)
    let store = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: protector
    )
    let finalText = "protected-final-" + UUID().uuidString
    let provenanceText = "protected-provenance-" + UUID().uuidString
    let fallbackName = "protected-workflow-" + UUID().uuidString
    let clipboardState = "protected-clipboard-" + UUID().uuidString
    let record = WorkflowResultRecord(
      workflow: WorkflowPresentation(fallbackName: fallbackName),
      finalText: finalText,
      timestamp: Date(timeIntervalSince1970: 8),
      outcome: .completed,
      correctionSource: RecognitionCorrectionSource(
        preMappingText: provenanceText,
        context: VocabularyRuleContext(locale: "en-US")
      )
    )

    try await store.save(record)
    try await store.setString(clipboardState, forKey: .legacyClipboardPersistedState)
    try await store.purgeSensitiveStorageResidue()

    let persistedRecords = try await store.records(matching: .all)
    let persistedClipboardState = try await store.string(forKey: .legacyClipboardPersistedState)
    XCTAssertEqual(persistedRecords, [record])
    XCTAssertEqual(persistedClipboardState, clipboardState)
    for column in ["workflow_fallback_name", "final_text", "correction_source_json"] {
      let envelope = try XCTUnwrap(
        rawHistoryValue(column: column, recordID: record.id, at: databaseURL)
      )
      XCTAssertTrue(envelope.hasPrefix("rill:v1:"))
    }
    XCTAssertTrue(
      try XCTUnwrap(
        rawSettingValue(forKey: .legacyClipboardPersistedState, at: databaseURL)
      ).hasPrefix("rill:v1:")
    )
    for sentinel in [finalText, provenanceText, fallbackName, clipboardState] {
      let sentinelData = Data(sentinel.utf8)
      for file in try persistedDatabaseBytes(at: databaseURL) {
        XCTAssertNil(
          file.data.range(of: sentinelData),
          "Protected local content reached \(file.name) as plaintext."
        )
      }
    }
    XCTAssertEqual(try schemaVersion(at: databaseURL), 14)
    XCTAssertTrue(
      try SQLitePersistenceStore.requiresExistingDataProtectionKey(
        databaseURL: databaseURL
      )
    )
  }

  func testV3MigrationProtectsExistingPlaintextAndPhysicallyRemovesIt() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-v3-plaintext.sqlite")
    let finalText = "legacy-final-" + UUID().uuidString
    let provenanceText = "legacy-provenance-" + UUID().uuidString
    let settingValue = "legacy-setting-" + UUID().uuidString
    let diagnosticSentinel = "legacy-diagnostic-" + UUID().uuidString
    let exportDestination = "/tmp/legacy-export-\(UUID().uuidString).json"
    let exportMetadataSentinel = "legacy-export-metadata-" + UUID().uuidString
    let record = WorkflowResultRecord(
      workflow: WorkflowPresentation(fallbackName: "Legacy protected migration"),
      finalText: finalText,
      timestamp: Date(timeIntervalSince1970: 7),
      outcome: .completed,
      correctionSource: RecognitionCorrectionSource(
        preMappingText: provenanceText,
        context: VocabularyRuleContext(bundleIdentifier: "com.example.editor")
      )
    )
    try createV3Database(
      at: databaseURL,
      records: [record],
      settingKey: .legacyClipboardPersistedState,
      settingValue: settingValue
    )
    try insertLegacyDiagnostic(
      message: diagnosticSentinel,
      metadataJSON: "{\"providerBody\":\"\(diagnosticSentinel)\"}",
      at: databaseURL
    )
    let legacyExport = ExportMetadata(
      kind: .diagnostics,
      destinationPath: exportDestination,
      itemCount: 1,
      createdAt: Date(timeIntervalSince1970: 9),
      metadata: ["format": exportMetadataSentinel]
    )
    try insertLegacyExport(legacyExport, at: databaseURL)
    XCTAssertFalse(
      try SQLitePersistenceStore.requiresExistingDataProtectionKey(
        databaseURL: databaseURL
      )
    )

    let store = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: testProtector(byte: 0x32)
    )

    let migratedRecords = try await store.records(matching: .all)
    let migratedSetting = try await store.string(forKey: .legacyClipboardPersistedState)
    let migratedDiagnostics = try await store.events(matching: .init())
    let migratedExports = try await store.exports(limit: nil)
    XCTAssertEqual(migratedRecords, [record])
    XCTAssertEqual(migratedSetting, settingValue)
    XCTAssertEqual(migratedDiagnostics.first?.message, DiagnosticEventSanitizer.sanitizedMessage)
    XCTAssertEqual(migratedDiagnostics.first?.metadata, [:])
    XCTAssertEqual(migratedExports, [legacyExport])
    XCTAssertEqual(try schemaVersion(at: databaseURL), 14)
    for sentinel in [
      finalText,
      provenanceText,
      settingValue,
      diagnosticSentinel,
      exportDestination,
      exportMetadataSentinel,
    ] {
      let sentinelData = Data(sentinel.utf8)
      for file in try persistedDatabaseBytes(at: databaseURL) {
        XCTAssertNil(
          file.data.range(of: sentinelData),
          "The v3 migration retained plaintext in \(file.name)."
        )
      }
    }
  }

  func testV3MigrationSanitizesUnsafeLegacyDiagnosticEventCodesAndRemovesTheirBytes() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-v3-diagnostic-events.sqlite")
    try createV3Database(
      at: databaseURL,
      records: [],
      settingKey: .interfaceLanguage,
      settingValue: "system"
    )
    let sentinel = UUID().uuidString
    let unsafeEventCodes = [
      "diagnostic private \(sentinel)",
      "/Users/private/\(sentinel)/event.txt",
      "token=\(sentinel)",
    ]
    for eventCode in unsafeEventCodes {
      try insertLegacyDiagnostic(
        eventCode: eventCode,
        message: "legacy diagnostic message",
        metadataJSON: "{}",
        at: databaseURL
      )
    }

    let store = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: testProtector(byte: 0x3C)
    )
    let migratedEvents = try await store.events(matching: .init())

    XCTAssertEqual(migratedEvents.count, unsafeEventCodes.count)
    XCTAssertTrue(
      migratedEvents.allSatisfy {
        $0.event == DiagnosticEventSanitizer.invalidEventCode
      }
    )
    for eventCode in unsafeEventCodes {
      let eventBytes = Data(eventCode.utf8)
      for file in try persistedDatabaseBytes(at: databaseURL) {
        XCTAssertNil(
          file.data.range(of: eventBytes),
          "The v3 migration retained an unsafe diagnostic event in \(file.name)."
        )
      }
    }
  }

  func testExistingNonemptyVersionZeroDatabasePurgesDeletedPlaintextResidue() throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-v0-residue.sqlite")
    let sentinel = "deleted-v0-plaintext-" + UUID().uuidString
    try createVersionZeroDatabaseWithDeletedHistoryResidue(
      at: databaseURL,
      sentinel: sentinel
    )
    let sentinelBytes = Data(sentinel.utf8)

    XCTAssertEqual(try schemaVersion(at: databaseURL), 0)
    XCTAssertTrue(
      try persistedDatabaseBytes(at: databaseURL).contains {
        $0.data.range(of: sentinelBytes) != nil
      },
      "The version-zero fixture did not retain the deleted plaintext sentinel."
    )

    _ = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: testProtector(byte: 0x3E)
    )

    XCTAssertEqual(try schemaVersion(at: databaseURL), 14)
    XCTAssertEqual(try cleanupPendingValue(at: databaseURL), 0)
    for file in try persistedDatabaseBytes(at: databaseURL) {
      XCTAssertNil(
        file.data.range(of: sentinelBytes),
        "The v4 migration retained version-zero plaintext residue in \(file.name)."
      )
    }
  }

  func testV11DatabaseRejectsWrongKeyBeforeAnyReadOrWrite() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-wrong-key.sqlite")
    let originalStore = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: testProtector(byte: 0x33)
    )
    let record = historyRecord(text: "wrong-key-control", timestamp: 1)
    try await originalStore.save(record)
    let markerBefore = try XCTUnwrap(rawKeyVerificationEnvelope(at: databaseURL))

    do {
      _ = try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: testProtector(byte: 0x34)
      )
      XCTFail("Expected an unrelated root key to be rejected during initialization.")
    } catch let error as SQLitePersistenceError {
      guard case .migrationFailed(let message) = error else {
        return XCTFail("Unexpected SQLite error: \(error)")
      }
      XCTAssertEqual(message, "Authenticated schema metadata could not be validated.")
    }

    XCTAssertEqual(try rawKeyVerificationEnvelope(at: databaseURL), markerBefore)
    let originalRecords = try await originalStore.records(matching: .all)
    XCTAssertEqual(originalRecords, [record])
  }

  func testV4DatabaseRejectsTamperedKeyVerificationMarker() throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-tampered-marker.sqlite")
    let protector = try testProtector(byte: 0x35)
    _ = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: protector
    )
    try replaceKeyVerificationEnvelope(
      "rill:v1:\(Data(repeating: 0, count: 32).base64EncodedString())",
      at: databaseURL
    )

    do {
      _ = try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: protector
      )
      XCTFail("Expected tampered key verification metadata to be rejected.")
    } catch let error as SQLitePersistenceError {
      guard case .migrationFailed(let message) = error else {
        return XCTFail("Unexpected SQLite error: \(error)")
      }
      XCTAssertEqual(message, "Local data protection key verification failed.")
    }
  }

  func testInterruptedV4MigrationRollsBackAndCanRetry() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-interrupted-v4.sqlite")
    let records = [
      WorkflowResultRecord(
        workflow: WorkflowPresentation(fallbackName: "First legacy workflow"),
        finalText: "first-legacy-final",
        timestamp: Date(timeIntervalSince1970: 1),
        outcome: .completed
      ),
      WorkflowResultRecord(
        workflow: WorkflowPresentation(fallbackName: "Second legacy workflow"),
        finalText: "second-legacy-final",
        timestamp: Date(timeIntervalSince1970: 2),
        outcome: .completed
      ),
    ]
    try createV3Database(
      at: databaseURL,
      records: records,
      settingKey: .legacyClipboardPersistedState,
      settingValue: "legacy-clipboard-state"
    )
    let baseProtector = try testProtector(byte: 0x36)
    let interruptedProtector = FailingLocalDataProtector(
      base: baseProtector,
      successfulSealLimit: 2
    )

    XCTAssertThrowsError(
      try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: interruptedProtector
      )
    )
    XCTAssertEqual(try schemaVersion(at: databaseURL), 3)
    XCTAssertEqual(
      try rawHistoryValue(
        column: "final_text",
        recordID: records[0].id,
        at: databaseURL
      ),
      records[0].finalText
    )
    XCTAssertFalse(try localDataProtectionTableExists(at: databaseURL))

    let recoveredStore = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: baseProtector
    )
    let recovered = try await recoveredStore.records(matching: .all)
    let recoveredClipboardState = try await recoveredStore.string(
      forKey: .legacyClipboardPersistedState
    )
    XCTAssertEqual(recovered, records.sorted { $0.timestamp > $1.timestamp })
    XCTAssertEqual(recoveredClipboardState, "legacy-clipboard-state")
    XCTAssertEqual(try schemaVersion(at: databaseURL), 14)
  }

  func testPendingV4ResidueCleanupSurvivesBusyCheckpointAndRetriesOnNextOpen() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-pending-cleanup.sqlite")
    let sentinel = "pending-cleanup-plaintext-" + UUID().uuidString
    let record = WorkflowResultRecord(
      workflow: WorkflowPresentation(fallbackName: "Pending cleanup"),
      finalText: sentinel,
      timestamp: Date(timeIntervalSince1970: 11),
      outcome: .completed
    )
    try createV3Database(
      at: databaseURL,
      records: [record],
      settingKey: .legacyClipboardPersistedState,
      settingValue: "pending-cleanup-setting"
    )
    try enableWALMode(at: databaseURL)

    var reader: OpaquePointer?
    XCTAssertEqual(
      sqlite3_open_v2(databaseURL.path, &reader, SQLITE_OPEN_READWRITE, nil),
      SQLITE_OK
    )
    guard let reader else { return }
    XCTAssertEqual(
      sqlite3_exec(reader, "BEGIN; SELECT final_text FROM history_records;", nil, nil, nil),
      SQLITE_OK
    )
    let protector = try testProtector(byte: 0x37)

    do {
      _ = try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: protector
      )
      XCTFail("Expected the held reader to block the mandatory WAL truncation.")
    } catch let error as SQLitePersistenceError {
      guard case .executingSQL(let message) = error else {
        sqlite3_close(reader)
        return XCTFail("Unexpected SQLite error: \(error)")
      }
      XCTAssertTrue(message.contains("busy"))
    }

    XCTAssertEqual(try schemaVersion(at: databaseURL), 14)
    XCTAssertEqual(try cleanupPendingValue(at: databaseURL), 1)
    XCTAssertEqual(sqlite3_exec(reader, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
    sqlite3_close(reader)

    let recoveredStore = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: protector
    )
    let recoveredRecords = try await recoveredStore.records(matching: .all)
    XCTAssertEqual(recoveredRecords, [record])
    XCTAssertEqual(try cleanupPendingValue(at: databaseURL), 0)
    let sentinelData = Data(sentinel.utf8)
    for file in try persistedDatabaseBytes(at: databaseURL) {
      XCTAssertNil(
        file.data.range(of: sentinelData),
        "Retried v4 cleanup left plaintext in \(file.name)."
      )
    }
  }

  func testKeyCreationPreflightRequiresExistingKeyForAnyDowngradedProtectionMarker() throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-downgraded.sqlite")
    _ = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: testProtector(byte: 0x38)
    )
    try setSchemaVersion(3, at: databaseURL)

    XCTAssertTrue(
      try SQLitePersistenceStore.requiresExistingDataProtectionKey(
        databaseURL: databaseURL
      )
    )
  }

  func testKeyCreationPreflightAllowsFreshPathWithoutDatabaseOrSidecars() throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-fresh.sqlite")

    XCTAssertFalse(
      try SQLitePersistenceStore.requiresExistingDataProtectionKey(
        databaseURL: databaseURL
      )
    )
  }

  func testKeyCreationPreflightFailsClosedForEveryOrphanedSQLiteSidecar() throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    for suffix in ["-wal", "-shm", "-journal"] {
      let databaseURL = directoryURL.appendingPathComponent(
        "rill-orphan\(suffix).sqlite"
      )
      let sidecarURL = URL(fileURLWithPath: databaseURL.path + suffix)
      XCTAssertTrue(
        FileManager.default.createFile(atPath: sidecarURL.path, contents: Data()),
        "Failed to create the \(suffix) fixture."
      )

      XCTAssertTrue(
        try SQLitePersistenceStore.requiresExistingDataProtectionKey(
          databaseURL: databaseURL
        ),
        "An orphaned \(suffix) must prevent replacement-key generation."
      )
    }
  }

  func testKeyCreationPreflightFailsClosedForDanglingSidecarSymlink() throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-dangling.sqlite")
    let sidecarURL = URL(fileURLWithPath: databaseURL.path + "-wal")
    let missingTargetURL = directoryURL.appendingPathComponent("missing-wal-target")
    try FileManager.default.createSymbolicLink(
      at: sidecarURL,
      withDestinationURL: missingTargetURL
    )

    XCTAssertTrue(
      try SQLitePersistenceStore.requiresExistingDataProtectionKey(
        databaseURL: databaseURL
      )
    )
  }

  func testKeyCreationPreflightDoesNotFollowMainDatabaseSymlink() throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let targetURL = directoryURL.appendingPathComponent("unbound-target.sqlite")
    try executeFixtureSQL("PRAGMA user_version = 3;", at: targetURL)
    XCTAssertFalse(
      try SQLitePersistenceStore.requiresExistingDataProtectionKey(
        databaseURL: targetURL
      )
    )

    let databaseURL = directoryURL.appendingPathComponent("rill-linked.sqlite")
    try FileManager.default.createSymbolicLink(
      at: databaseURL,
      withDestinationURL: targetURL
    )

    XCTAssertTrue(
      try SQLitePersistenceStore.requiresExistingDataProtectionKey(
        databaseURL: databaseURL
      )
    )
  }

  func testKeyCreationPreflightFailsClosedForInvalidPathComponent() throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let nonDirectoryURL = directoryURL.appendingPathComponent("not-a-directory")
    XCTAssertTrue(FileManager.default.createFile(atPath: nonDirectoryURL.path, contents: Data()))
    let databaseURL = nonDirectoryURL.appendingPathComponent("rill.sqlite")

    XCTAssertTrue(
      try SQLitePersistenceStore.requiresExistingDataProtectionKey(
        databaseURL: databaseURL
      )
    )
  }

  func testAuthenticatedSchemaFloorRejectsWrongKeyWithoutMutationThenRecoversOriginalKey()
    async throws
  {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-direct-downgrade.sqlite")
    let originalProtector = try testProtector(byte: 0x3A)
    let record = historyRecord(text: "downgrade-protected-control", timestamp: 12)
    do {
      let store = try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: originalProtector
      )
      try await store.save(record)
      try await store.purgeSensitiveStorageResidue()
    }
    let markerBefore = try XCTUnwrap(rawKeyVerificationEnvelope(at: databaseURL))
    let protectedTextBefore = try XCTUnwrap(
      rawHistoryValue(column: "final_text", recordID: record.id, at: databaseURL)
    )
    try setSchemaVersion(3, at: databaseURL)

    XCTAssertThrowsError(
      try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: testProtector(byte: 0x3B)
      )
    )

    XCTAssertEqual(try schemaVersion(at: databaseURL), 3)
    XCTAssertEqual(try rawKeyVerificationEnvelope(at: databaseURL), markerBefore)
    XCTAssertEqual(
      try rawHistoryValue(column: "final_text", recordID: record.id, at: databaseURL),
      protectedTextBefore
    )

    let recovered = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: originalProtector
    )
    let recoveredRecords = try await recovered.records(matching: .all)
    XCTAssertEqual(try schemaVersion(at: databaseURL), 14)
    XCTAssertEqual(recoveredRecords, [record])
    XCTAssertEqual(try rawKeyVerificationEnvelope(at: databaseURL), markerBefore)
    XCTAssertEqual(
      try rawHistoryValue(column: "final_text", recordID: record.id, at: databaseURL),
      protectedTextBefore
    )
  }

  func testBoundarylessV10PlusSchemaDowngradeStillFailsClosedWithoutMutation() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-boundaryless-downgrade.sqlite")
    let protector = try testProtector(byte: 0x93)
    let record = historyRecord(text: "boundaryless-downgrade-control", timestamp: 13)
    do {
      let store = try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: protector
      )
      try await store.save(record)
    }
    let markerBefore = try XCTUnwrap(rawKeyVerificationEnvelope(at: databaseURL))
    let protectedTextBefore = try XCTUnwrap(
      rawHistoryValue(column: "final_text", recordID: record.id, at: databaseURL)
    )
    try removeV11StorageBoundary(at: databaseURL)
    try setSchemaVersion(3, at: databaseURL)

    XCTAssertThrowsError(
      try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: protector
      )
    )

    XCTAssertEqual(try schemaVersion(at: databaseURL), 3)
    XCTAssertEqual(try rawKeyVerificationEnvelope(at: databaseURL), markerBefore)
    XCTAssertEqual(
      try rawHistoryValue(column: "final_text", recordID: record.id, at: databaseURL),
      protectedTextBefore
    )
    XCTAssertEqual(try rowCount(in: "history_records", at: databaseURL), 1)
  }

  func testAuthenticatedSchemaRecoveryRejectsMissingWriterBarrierWithoutMutation()
    async throws
  {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-missing-writer-barrier.sqlite")
    let protector = try testProtector(byte: 0x94)
    let record = historyRecord(text: "missing-barrier-control", timestamp: 14)
    do {
      let store = try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: protector
      )
      try await store.save(record)
    }
    let markerBefore = try XCTUnwrap(rawKeyVerificationEnvelope(at: databaseURL))
    let protectedTextBefore = try XCTUnwrap(
      rawHistoryValue(column: "final_text", recordID: record.id, at: databaseURL)
    )
    try executeFixtureSQL(
      "DROP TRIGGER rill_writer_barrier_v11_history_records_update;",
      at: databaseURL
    )
    try setSchemaVersion(3, at: databaseURL)

    XCTAssertThrowsError(
      try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: protector
      )
    )

    XCTAssertEqual(try schemaVersion(at: databaseURL), 3)
    XCTAssertEqual(try rawKeyVerificationEnvelope(at: databaseURL), markerBefore)
    XCTAssertEqual(
      try rawHistoryValue(column: "final_text", recordID: record.id, at: databaseURL),
      protectedTextBefore
    )
    XCTAssertEqual(try rowCount(in: "history_records", at: databaseURL), 1)
  }

  func testV11LegacyConnectionCannotMutateProtectedTablesAndOriginalKeyRecoversVersion()
    async throws
  {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-v11-legacy-writer.sqlite")
    let protector = try testProtector(byte: 0x95)
    let history = historyRecord(text: "legacy-writer-history", timestamp: 15)
    let diagnostic = diagnosticEvent(name: "legacy-writer", timestamp: 16)
    let setting = "legacy-writer-setting"
    let export = ExportMetadata(
      kind: .history,
      destinationPath: "/tmp/legacy-writer-export.json",
      itemCount: 1,
      createdAt: Date(timeIntervalSince1970: 17),
      metadata: ["source": "writer-barrier"]
    )
    do {
      let store = try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: protector
      )
      try await store.save(history)
      try await store.save(diagnostic)
      try await store.setString(setting, forKey: .interfaceLanguage)
      try await store.save(export)
    }

    do {
      var legacy: OpaquePointer?
      guard
        sqlite3_open_v2(databaseURL.path, &legacy, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
        let legacy
      else {
        return XCTFail("Failed to open the legacy writer fixture.")
      }
      defer { sqlite3_close(legacy) }

      XCTAssertEqual(
        sqlite3_exec(legacy, "PRAGMA user_version = 1;", nil, nil, nil),
        SQLITE_OK
      )
      let blockedWrites: [(label: String, sql: String)] = [
        (
          "history insert",
          "INSERT INTO history_records SELECT * FROM history_records LIMIT 1;"
        ),
        (
          "history update",
          "UPDATE history_records SET timestamp = timestamp WHERE id = '\(history.id.uuidString)';"
        ),
        (
          "history delete",
          "DELETE FROM history_records WHERE id = '\(history.id.uuidString)';"
        ),
        (
          "diagnostic insert",
          "INSERT INTO diagnostic_events SELECT * FROM diagnostic_events LIMIT 1;"
        ),
        (
          "diagnostic update",
          "UPDATE diagnostic_events SET timestamp = timestamp;"
        ),
        (
          "diagnostic delete",
          "DELETE FROM diagnostic_events;"
        ),
        (
          "settings insert",
          "INSERT INTO app_settings SELECT * FROM app_settings LIMIT 1;"
        ),
        (
          "settings update",
          "UPDATE app_settings SET updated_at = updated_at WHERE key = '\(AppSettingKey.interfaceLanguage.rawValue)';"
        ),
        (
          "settings delete",
          "DELETE FROM app_settings WHERE key = '\(AppSettingKey.interfaceLanguage.rawValue)';"
        ),
        (
          "export insert",
          "INSERT INTO export_metadata SELECT * FROM export_metadata LIMIT 1;"
        ),
        (
          "export update",
          "UPDATE export_metadata SET item_count = item_count WHERE id = '\(export.id.uuidString)';"
        ),
        (
          "export delete",
          "DELETE FROM export_metadata WHERE id = '\(export.id.uuidString)';"
        ),
      ]
      for blockedWrite in blockedWrites {
        let result = sqlite3_exec(legacy, blockedWrite.sql, nil, nil, nil)
        let message = String(cString: sqlite3_errmsg(legacy))
        XCTAssertNotEqual(result, SQLITE_OK, "Unexpectedly allowed \(blockedWrite.label).")
        XCTAssertTrue(
          message.contains(SQLiteWriterBarrier.capabilityFunctionName) || message.contains("rill_catalog_writer_v13") || message.contains("rill_memory_writer_v14"),
          "\(blockedWrite.label) failed for an unrelated reason: \(message)"
        )
      }
    }

    XCTAssertEqual(try schemaVersion(at: databaseURL), 1)
    for table in [
      "history_records",
      "diagnostic_events",
      "app_settings",
      "export_metadata",
    ] {
      XCTAssertEqual(try rowCount(in: table, at: databaseURL), 1)
    }

    let recovered = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: protector
    )
    let recoveredHistory = try await recovered.records(matching: .all)
    let recoveredDiagnostics = try await recovered.events(matching: .init())
    let recoveredSetting = try await recovered.string(forKey: .interfaceLanguage)
    let recoveredExports = try await recovered.exports(limit: nil)
    XCTAssertEqual(try schemaVersion(at: databaseURL), 14)
    XCTAssertEqual(recoveredHistory, [history])
    XCTAssertEqual(
      recoveredDiagnostics,
      [DiagnosticEventSanitizer.sanitize(diagnostic)]
    )
    XCTAssertEqual(recoveredSetting, setting)
    XCTAssertEqual(recoveredExports, [export])
  }

  func testDowngradedExactV4RecoveryAuthenticatesMixedDataAndPurgesPlaintextResidue()
    async throws
  {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-exact-v4-recovery.sqlite")
    let protector = try testProtector(byte: 0x8A)
    let fixture = try createDowngradedExactV4Fixture(
      at: databaseURL,
      protector: protector
    )

    XCTAssertTrue(
      try SQLitePersistenceStore.requiresExistingDataProtectionKey(
        databaseURL: databaseURL
      )
    )
    _ = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: protector
    )

    XCTAssertEqual(try schemaVersion(at: databaseURL), 14)
    XCTAssertEqual(try cleanupPendingValue(at: databaseURL), 0)
    XCTAssertEqual(try rawKeyVerificationEnvelope(at: databaseURL), fixture.markerEnvelope)
    XCTAssertEqual(
      try rawHistoryValue(
        column: "workflow_fallback_name",
        recordID: fixture.firstHistoryID,
        at: databaseURL
      ),
      fixture.firstFallbackEnvelope
    )
    XCTAssertEqual(
      try rawHistoryValue(
        column: "correction_source_json",
        recordID: fixture.firstHistoryID,
        at: databaseURL
      ),
      fixture.firstCorrectionEnvelope
    )
    XCTAssertEqual(
      try rawHistoryValue(
        column: "final_text",
        recordID: fixture.secondHistoryID,
        at: databaseURL
      ),
      fixture.secondFinalTextEnvelope
    )
    XCTAssertEqual(
      try rawSettingValue(forKey: .interfaceLanguage, at: databaseURL),
      fixture.protectedSettingEnvelope
    )
    XCTAssertEqual(
      try rawExportValue(
        column: "destination_path",
        recordID: fixture.exportID,
        at: databaseURL
      ),
      fixture.protectedExportPathEnvelope
    )

    let recoveredFirstFinalText = try XCTUnwrap(
      rawHistoryValue(
        column: "final_text",
        recordID: fixture.firstHistoryID,
        at: databaseURL
      )
    )
    XCTAssertEqual(
      try protector.open(
        recoveredFirstFinalText,
        context: LocalDataProtectionContext(
          namespace: "history_records",
          recordID: fixture.firstHistoryID.uuidString,
          field: "final_text"
        )
      ),
      Data(fixture.firstFinalTextPlaintext.utf8)
    )
    let recoveredSecondFallback = try XCTUnwrap(
      rawHistoryValue(
        column: "workflow_fallback_name",
        recordID: fixture.secondHistoryID,
        at: databaseURL
      )
    )
    XCTAssertEqual(
      try protector.open(
        recoveredSecondFallback,
        context: LocalDataProtectionContext(
          namespace: "history_records",
          recordID: fixture.secondHistoryID.uuidString,
          field: "workflow_fallback_name"
        )
      ),
      Data(fixture.secondFallbackPlaintext.utf8)
    )
    let recoveredPlainSetting = try XCTUnwrap(
      rawSettingValue(forKey: .selectedWorkflowID, at: databaseURL)
    )
    XCTAssertEqual(
      try protector.open(
        recoveredPlainSetting,
        context: LocalDataProtectionContext(
          namespace: "app_settings",
          recordID: AppSettingKey.selectedWorkflowID.rawValue,
          field: "value"
        )
      ),
      Data(fixture.plainSettingValue.utf8)
    )
    let recoveredExportMetadata = try XCTUnwrap(
      rawExportValue(
        column: "metadata_json",
        recordID: fixture.exportID,
        at: databaseURL
      )
    )
    XCTAssertEqual(
      try protector.open(
        recoveredExportMetadata,
        context: LocalDataProtectionContext(
          namespace: "export_metadata",
          recordID: fixture.exportID.uuidString,
          field: "metadata_json"
        )
      ),
      Data(fixture.exportMetadataPlaintext.utf8)
    )
    XCTAssertEqual(
      try rawTextValue(
        "failure_message",
        table: "history_records",
        identifierColumn: "id",
        identifier: fixture.firstHistoryID.uuidString,
        at: databaseURL
      ),
      HistoryFailureSanitizer.genericMessage
    )
    XCTAssertEqual(
      try rawTextValue(
        "event",
        table: "diagnostic_events",
        identifierColumn: "id",
        identifier: "1",
        at: databaseURL
      ),
      DiagnosticEventSanitizer.sanitizeEventCode(fixture.diagnosticEventPlaintext)
    )
    XCTAssertEqual(
      try rawTextValue(
        "message",
        table: "diagnostic_events",
        identifierColumn: "id",
        identifier: "1",
        at: databaseURL
      ),
      DiagnosticEventSanitizer.sanitizedMessage
    )
    XCTAssertEqual(
      try rawTextValue(
        "metadata_json",
        table: "diagnostic_events",
        identifierColumn: "id",
        identifier: "1",
        at: databaseURL
      ),
      "{}"
    )
    XCTAssertEqual(try rowCount(in: "history_records", at: databaseURL), 2)
    XCTAssertEqual(try rowCount(in: "app_settings", at: databaseURL), 2)
    XCTAssertEqual(try rowCount(in: "export_metadata", at: databaseURL), 1)
    XCTAssertEqual(try rowCount(in: "diagnostic_events", at: databaseURL), 1)

    for plaintext in fixture.plaintextResidueSentinels {
      let bytes = Data(plaintext.utf8)
      for file in try persistedDatabaseBytes(at: databaseURL) {
        XCTAssertNil(
          file.data.range(of: bytes),
          "Recovered v4 data retained plaintext in \(file.name)."
        )
      }
    }
  }

  func testDowngradedExactV4RecoveryWrongKeyFailsWithoutMutation() throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-exact-v4-wrong-key.sqlite")
    let fixture = try createDowngradedExactV4Fixture(
      at: databaseURL,
      protector: testProtector(byte: 0x8B)
    )
    let snapshot = try downgradedV4LogicalSnapshot(
      fixture: fixture,
      at: databaseURL
    )

    XCTAssertThrowsError(
      try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: testProtector(byte: 0x8C)
      )
    )

    XCTAssertEqual(
      try downgradedV4LogicalSnapshot(fixture: fixture, at: databaseURL),
      snapshot
    )
  }

  func testDowngradedExactV4RecoveryRejectsTamperedEnvelopeWithoutMutation() throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-exact-v4-tampered.sqlite")
    let protector = try testProtector(byte: 0x8D)
    let fixture = try createDowngradedExactV4Fixture(
      at: databaseURL,
      protector: protector
    )
    try replaceHistoryValue(
      "rill:v1:\(Data(repeating: 0, count: 32).base64EncodedString())",
      column: "correction_source_json",
      recordID: fixture.firstHistoryID,
      at: databaseURL
    )
    let snapshot = try downgradedV4LogicalSnapshot(fixture: fixture, at: databaseURL)

    XCTAssertThrowsError(
      try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: protector
      )
    )

    XCTAssertEqual(
      try downgradedV4LogicalSnapshot(fixture: fixture, at: databaseURL),
      snapshot
    )
  }

  func testDowngradedExactV4RecoveryRejectsUnsupportedEnvelopeWithoutMutation() throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-exact-v4-future-envelope.sqlite")
    let protector = try testProtector(byte: 0x91)
    let fixture = try createDowngradedExactV4Fixture(
      at: databaseURL,
      protector: protector
    )
    try replaceRawSettingValue(
      "rill:v2:unsupported",
      forKey: .selectedWorkflowID,
      at: databaseURL
    )
    let snapshot = try downgradedV4LogicalSnapshot(fixture: fixture, at: databaseURL)

    XCTAssertThrowsError(
      try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: protector
      )
    )

    XCTAssertEqual(
      try downgradedV4LogicalSnapshot(fixture: fixture, at: databaseURL),
      snapshot
    )
  }

  func testDowngradedExactV4RecoveryRejectsExtraSchemaWithoutMutation() throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-exact-v4-extra-schema.sqlite")
    let protector = try testProtector(byte: 0x8E)
    let fixture = try createDowngradedExactV4Fixture(
      at: databaseURL,
      protector: protector
    )
    try executeFixtureSQL("CREATE TABLE unexpected_table (id INTEGER);", at: databaseURL)
    let snapshot = try downgradedV4LogicalSnapshot(fixture: fixture, at: databaseURL)

    XCTAssertThrowsError(
      try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: protector
      )
    )

    XCTAssertEqual(
      try downgradedV4LogicalSnapshot(fixture: fixture, at: databaseURL),
      snapshot
    )
  }

  func testDowngradedExactV4RecoverySealFailureRollsBackEveryField() throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-exact-v4-rollback.sqlite")
    let baseProtector = try testProtector(byte: 0x8F)
    let fixture = try createDowngradedExactV4Fixture(
      at: databaseURL,
      protector: baseProtector
    )
    let snapshot = try downgradedV4LogicalSnapshot(fixture: fixture, at: databaseURL)

    XCTAssertThrowsError(
      try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: FailingLocalDataProtector(
          base: baseProtector,
          successfulSealLimit: 1
        )
      )
    )

    XCTAssertEqual(
      try downgradedV4LogicalSnapshot(fixture: fixture, at: databaseURL),
      snapshot
    )
  }

  func testV9MigrationRejectsDamagedProtectedHistoryInsteadOfMarkingItEmpty() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-v9-damaged-history.sqlite")
    let protector = try testProtector(byte: 0x92)
    let record = historyRecord(text: "authenticated-body", timestamp: 9)
    var store: SQLitePersistenceStore? = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: protector
    )
    try await store?.save(record)
    store = nil

    let damagedEnvelope =
      "rill:v1:\(Data(repeating: 0, count: 32).base64EncodedString())"
    try replaceHistoryValue(
      damagedEnvelope,
      column: "final_text",
      recordID: record.id,
      at: databaseURL
    )
    try simulateV8DatabaseByRemovingV11StorageBoundary(at: databaseURL)

    XCTAssertThrowsError(
      try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: protector
      )
    )
    XCTAssertEqual(try schemaVersion(at: databaseURL), 8)
    XCTAssertEqual(
      try rawHistoryValue(
        column: "final_text",
        recordID: record.id,
        at: databaseURL
      ),
      damagedEnvelope
    )
  }

  func testHistoryDeletionUsesStrictCutoffReportsChangesAndPreservesDiagnostics() async throws {
    let store = try makeStore()
    let cutoff = Date(timeIntervalSince1970: 20)
    for record in [
      historyRecord(text: "older", timestamp: 10),
      historyRecord(text: "boundary", timestamp: 20),
      historyRecord(text: "newer", timestamp: 30),
    ] {
      try await store.save(record)
    }
    let diagnostic = DiagnosticEvent(
      timestamp: Date(timeIntervalSince1970: 15),
      subsystem: .records,
      level: .info,
      event: "persistence.must-remain",
      message: "History cleanup must not remove diagnostics."
    )
    try await store.save(diagnostic)

    let prunedCount = try await store.deleteRecords(olderThan: cutoff)
    let afterPrune = try await store.records(matching: .all)
    let repeatedPruneCount = try await store.deleteRecords(olderThan: cutoff)
    let boundedClearCount = try await store.deleteRecords(through: cutoff)
    let afterBoundedClear = try await store.records(matching: .all)
    let clearedCount = try await store.deleteAllRecords()
    let repeatedClearCount = try await store.deleteAllRecords()
    let diagnostics = try await store.events(matching: DiagnosticQuery())

    XCTAssertEqual(prunedCount, 1)
    XCTAssertEqual(afterPrune.map(\.finalText), ["newer", "boundary"])
    XCTAssertEqual(repeatedPruneCount, 0)
    XCTAssertEqual(boundedClearCount, 1)
    XCTAssertEqual(afterBoundedClear.map(\.finalText), ["newer"])
    XCTAssertEqual(clearedCount, 1)
    XCTAssertEqual(repeatedClearCount, 0)
    XCTAssertEqual(diagnostics, [DiagnosticEventSanitizer.sanitize(diagnostic)])
  }

  func testHistoryRetentionDeletionPhysicallyRemovesCorrectionProvenance() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-test.sqlite")
    let store = try SQLitePersistenceStore(databaseURL: databaseURL)
    let provenanceSentinel = "expired-pre-mapping-" + UUID().uuidString
    let expiredRecord = WorkflowResultRecord(
      workflow: WorkflowPresentation(fallbackName: "Expired correction"),
      finalText: "expired corrected text",
      timestamp: Date(timeIntervalSince1970: 10),
      outcome: .completed,
      correctionSource: RecognitionCorrectionSource(
        preMappingText: provenanceSentinel,
        context: VocabularyRuleContext(locale: "en-US")
      )
    )
    let retainedRecord = WorkflowResultRecord(
      workflow: WorkflowPresentation(fallbackName: "Boundary correction"),
      finalText: "retained corrected text",
      timestamp: Date(timeIntervalSince1970: 20),
      outcome: .completed,
      correctionSource: RecognitionCorrectionSource(
        preMappingText: "retained pre-mapping text",
        context: VocabularyRuleContext(locale: "en-US")
      )
    )
    try await store.save(expiredRecord)
    try await store.save(retainedRecord)
    try await store.purgeSensitiveStorageResidue()

    let sentinelData = Data(provenanceSentinel.utf8)
    for file in try persistedDatabaseBytes(at: databaseURL) {
      XCTAssertNil(
        file.data.range(of: sentinelData),
        "Unexpired correction provenance was stored as plaintext in \(file.name)."
      )
    }
    let expiredEnvelope = try XCTUnwrap(
      rawHistoryValue(
        column: "correction_source_json",
        recordID: expiredRecord.id,
        at: databaseURL
      )
    )
    XCTAssertTrue(expiredEnvelope.hasPrefix("rill:v1:"))

    let deletedCount = try await store.deleteRecords(
      olderThan: Date(timeIntervalSince1970: 20)
    )
    XCTAssertEqual(deletedCount, 1)
    try await store.purgeSensitiveStorageResidue()

    let remainingRecords = try await store.records(matching: .all)
    XCTAssertEqual(remainingRecords, [retainedRecord])
    let expiredEnvelopeData = Data(expiredEnvelope.utf8)
    for file in try persistedDatabaseBytes(at: databaseURL) {
      XCTAssertNil(
        file.data.range(of: expiredEnvelopeData),
        "Expired protected correction provenance remained in \(file.name)."
      )
    }
  }

  func testDiagnosticDeletionUsesStrictCutoffReportsChangesAndPreservesRunHistory() async throws {
    let store = try makeStore()
    let cutoff = Date(timeIntervalSince1970: 20)
    let history = historyRecord(text: "run-history-must-remain", timestamp: 5)
    try await store.save(history)
    for event in [
      diagnosticEvent(name: "older", timestamp: 10),
      diagnosticEvent(name: "boundary", timestamp: 20),
      diagnosticEvent(name: "newer", timestamp: 30),
    ] {
      try await store.save(event)
    }

    let prunedCount = try await store.deleteEvents(olderThan: cutoff)
    let afterPrune = try await store.events(matching: DiagnosticQuery())
    let repeatedPruneCount = try await store.deleteEvents(olderThan: cutoff)
    let boundedClearCount = try await store.deleteEvents(through: cutoff)
    let afterBoundedClear = try await store.events(matching: DiagnosticQuery())
    let clearedCount = try await store.deleteAllEvents()
    let repeatedClearCount = try await store.deleteAllEvents()
    let remainingHistory = try await store.records(matching: .all)

    XCTAssertEqual(prunedCount, 1)
    XCTAssertEqual(afterPrune.map(\.event), ["diagnostic.newer", "diagnostic.boundary"])
    XCTAssertEqual(repeatedPruneCount, 0)
    XCTAssertEqual(boundedClearCount, 1)
    XCTAssertEqual(afterBoundedClear.map(\.event), ["diagnostic.newer"])
    XCTAssertEqual(clearedCount, 1)
    XCTAssertEqual(repeatedClearCount, 0)
    XCTAssertEqual(remainingHistory, [history])
  }

  func testDiagnosticsAndSettingsRoundTrip() async throws {
    let store = try makeStore()
    let runID = UUID()
    let event = DiagnosticEvent(
      timestamp: Date(timeIntervalSince1970: 64),
      runID: runID,
      subsystem: .providers,
      level: .warning,
      event: "providers.warning",
      message: "provider warning",
      metadata: ["source": "tests"]
    )

    try await store.save(event)
    try await store.setString("simplifiedChinese", forKey: .interfaceLanguage)
    try await store.setString(UUID().uuidString, forKey: .selectedWorkflowID)

    let diagnostics = try await store.events(
      matching: DiagnosticQuery(runID: runID, minimumLevel: .info)
    )
    let language = try await store.string(forKey: .interfaceLanguage)

    XCTAssertEqual(diagnostics, [DiagnosticEventSanitizer.sanitize(event)])
    XCTAssertEqual(language, "simplifiedChinese")
  }

  func testDiagnosticQuerySkipsCorruptNewestRowWithoutConsumingLimit() async throws {
    let store = try makeStore()
    let databaseURL = await store.databaseURL
    let corruptNewest = diagnosticEvent(name: "corrupt", timestamp: 30)
    let validBoundary = diagnosticEvent(name: "boundary", timestamp: 20)
    let validOlder = diagnosticEvent(name: "older", timestamp: 10)
    try await store.save(corruptNewest)
    try await store.save(validBoundary)
    try await store.save(validOlder)
    try replaceDiagnosticMetadata(
      "not-json",
      eventCode: DiagnosticEventSanitizer.sanitize(corruptNewest).event,
      timestamp: corruptNewest.timestamp,
      at: databaseURL
    )

    let limited = try await store.events(matching: DiagnosticQuery(limit: 2))
    let allValid = try await store.events(matching: DiagnosticQuery())

    XCTAssertEqual(limited.map(\.event), [
      DiagnosticEventSanitizer.sanitize(validBoundary).event,
      DiagnosticEventSanitizer.sanitize(validOlder).event,
    ])
    XCTAssertEqual(allValid, [
      DiagnosticEventSanitizer.sanitize(validBoundary),
      DiagnosticEventSanitizer.sanitize(validOlder),
    ])
  }

  func testDiagnosticPersistenceSanitizesUnsafeEventCodesBeforeWritingSQLiteFiles() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-diagnostic-event-privacy.sqlite")
    let store = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: testProtector(byte: 0x3D)
    )
    let sentinel = UUID().uuidString
    let unsafeEventCodes = [
      "diagnostic private \(sentinel)",
      "/Users/private/\(sentinel)/event.txt",
      "token=\(sentinel)",
    ]

    for eventCode in unsafeEventCodes {
      try await store.save(
        DiagnosticEvent(
          subsystem: .session,
          level: .warning,
          event: eventCode,
          message: "unsafe diagnostic event"
        )
      )
    }
    try await store.purgeSensitiveStorageResidue()
    let persistedEvents = try await store.events(matching: .init())

    XCTAssertEqual(persistedEvents.count, unsafeEventCodes.count)
    XCTAssertTrue(
      persistedEvents.allSatisfy {
        $0.event == DiagnosticEventSanitizer.invalidEventCode
      }
    )
    for eventCode in unsafeEventCodes {
      let eventBytes = Data(eventCode.utf8)
      for file in try persistedDatabaseBytes(at: databaseURL) {
        XCTAssertNil(
          file.data.range(of: eventBytes),
          "An unsafe diagnostic event reached \(file.name)."
        )
      }
    }
  }

  func testDiagnosticPersistenceRejectsAlphanumericBase64AndHexCodeCanaries() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-diagnostic-code-privacy.sqlite")
    let store = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: testProtector(byte: 0x4D)
    )
    let uniqueToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let alphanumericCanary = "CANARYSECRET\(uniqueToken)"
    let base64Canary = "Q0FOQVJZU0VDUkVUMTIzNDU2Nzg5"
    let hexadecimalCanary = "43414e415259534543524554313233343536373839"
    let unknownEventCode = "diagnostic.\(uniqueToken.lowercased())"
    let canaries = [
      unknownEventCode,
      alphanumericCanary,
      base64Canary,
      hexadecimalCanary,
    ]

    try await store.save(
      DiagnosticEvent(
        subsystem: .providers,
        level: .warning,
        event: unknownEventCode,
        message: "unsafe",
        metadata: [
          "actionID": alphanumericCanary,
          "count": "1",
          "provider.model": base64Canary,
          "recognizerID": hexadecimalCanary,
        ]
      )
    )
    for canary in canaries {
      let bytes = Data(canary.utf8)
      for file in try persistedDatabaseBytes(at: databaseURL) {
        XCTAssertNil(
          file.data.range(of: bytes),
          "A code-shaped diagnostic canary reached \(file.name) before residue cleanup."
        )
      }
    }
    try await store.purgeSensitiveStorageResidue()

    let persistedEvents = try await store.events(matching: .init())
    let persisted = try XCTUnwrap(persistedEvents.first)
    XCTAssertEqual(persisted.event, DiagnosticEventSanitizer.invalidEventCode)
    XCTAssertEqual(persisted.metadata, ["count": "1"])

    for canary in canaries {
      let bytes = Data(canary.utf8)
      for file in try persistedDatabaseBytes(at: databaseURL) {
        XCTAssertNil(
          file.data.range(of: bytes),
          "A code-shaped diagnostic canary reached \(file.name)."
        )
      }
    }
  }

  func testBatchSettingsFetchReturnsRequestedValues() async throws {
    let store = try makeStore()
    let selectedWorkflowID = UUID().uuidString

    try await store.setString("simplifiedChinese", forKey: .interfaceLanguage)
    try await store.setString(selectedWorkflowID, forKey: .selectedWorkflowID)

    let values = try await store.strings(forKeys: [
      .interfaceLanguage,
      .selectedWorkflowID,
      .openAIModel,
    ])

    XCTAssertEqual(values[.interfaceLanguage], "simplifiedChinese")
    XCTAssertEqual(values[.selectedWorkflowID], selectedWorkflowID)
    XCTAssertNil(values[.openAIModel])
    XCTAssertEqual(values.count, 2)
  }

  func testSettingsSnapshotIsolatesDamagedMigratedRowWithoutReplacingIt() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-migrated-setting-damage.sqlite")
    let protector = try testProtector(byte: 0x4A)
    try createV3Database(
      at: databaseURL,
      records: [],
      settingKey: .privacyCloudConfirmationRequired,
      settingValue: "false"
    )
    let store = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: protector
    )
    try await store.setString("english", forKey: .interfaceLanguage)
    let damagedEnvelope = "rill:v1:\(Data(repeating: 0, count: 32).base64EncodedString())"
    try replaceRawSettingValue(
      damagedEnvelope,
      forKey: .privacyCloudConfirmationRequired,
      at: databaseURL
    )

    let snapshot = try await store.settingsSnapshot(forKeys: [
      .privacyCloudConfirmationRequired,
      .interfaceLanguage,
    ])

    XCTAssertEqual(snapshot.values[.interfaceLanguage], "english")
    XCTAssertNil(snapshot.values[.privacyCloudConfirmationRequired])
    XCTAssertEqual(snapshot.unavailableKeys, [.privacyCloudConfirmationRequired])
    XCTAssertEqual(
      try rawSettingValue(forKey: .privacyCloudConfirmationRequired, at: databaseURL),
      damagedEnvelope
    )
    do {
      _ = try await store.string(forKey: .privacyCloudConfirmationRequired)
      XCTFail("Expected the strict single-setting read to reject the damaged row.")
    } catch {
      // The isolated snapshot is the recovery path; strict reads remain strict.
    }
  }

  func testAtomicSettingsSnapshotWritesEveryPrivacyValueTogether() async throws {
    let store = try makeStore()
    let values: [AppSettingKey: String] = [
      .privacySensitiveAppRules: "[]",
      .privacyCloudConfirmationRequired: "true",
      .privacyHistoryPreviewMode: PrivacyHistoryPreviewMode.restricted.rawValue,
      .privacySecureInputConservativeMode: "true",
    ]

    try await store.setStringsAtomically(values)

    let stored = try await store.strings(forKeys: Array(values.keys))
    XCTAssertEqual(stored, values)
  }

  func testRemovingLegacyCredentialPurgesItsBytesFromDatabaseAndWAL() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-test.sqlite")
    let store = try SQLitePersistenceStore(databaseURL: databaseURL)
    let secret = "legacy-credential-" + UUID().uuidString

    try await store.setString(secret, forKey: .openAIAPIKey)
    try await store.removeValue(forKey: .openAIAPIKey)

    let storedCredential = try await store.string(forKey: .openAIAPIKey)
    XCTAssertNil(storedCredential)
    let secretData = Data(secret.utf8)
    for url in [
      databaseURL,
      URL(fileURLWithPath: databaseURL.path + "-wal"),
      URL(fileURLWithPath: databaseURL.path + "-shm"),
    ] where FileManager.default.fileExists(atPath: url.path) {
      let data = try Data(contentsOf: url)
      XCTAssertNil(
        data.range(of: secretData), "Legacy credential remained in \(url.lastPathComponent)")
    }
  }

  func testSensitiveResiduePurgeRemovesReplacedWebhookSecretsFromDatabaseFiles() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-test.sqlite")
    let store = try SQLitePersistenceStore(databaseURL: databaseURL)
    let webhookURL = "https://hooks.example.test/" + UUID().uuidString
    let headerName = "X-Rill-Secret-" + UUID().uuidString
    let token = "Bearer webhook-token-" + UUID().uuidString
    let plaintextWorkflow =
      """
      [{"configuration":{"webhook.url":"\(webhookURL)","webhook.headersJSON":"{\\"\(headerName)\\":\\"\(token)\\"}"}}]
      """

    try await store.setString(plaintextWorkflow, forKey: .customWorkflows)
    try await store.purgeSensitiveStorageResidue()

    let sensitiveBytes = [webhookURL, headerName, token].map { Data($0.utf8) }
    for file in try persistedDatabaseBytes(at: databaseURL) {
      for secret in sensitiveBytes {
        XCTAssertNil(
          file.data.range(of: secret),
          "A protected setting was stored as plaintext in \(file.name)."
        )
      }
    }
    let originalEnvelope = try XCTUnwrap(
      rawSettingValue(forKey: .customWorkflows, at: databaseURL)
    )
    XCTAssertTrue(originalEnvelope.hasPrefix("rill:v1:"))

    try await store.setString(
      "[{\"configuration\":{\"webhook.secureReference\":\"workflow.webhook.v1:test:0\"}}]",
      forKey: .customWorkflows
    )
    try await store.purgeSensitiveStorageResidue()

    let originalEnvelopeData = Data(originalEnvelope.utf8)
    for file in try persistedDatabaseBytes(at: databaseURL) {
      XCTAssertNil(
        file.data.range(of: originalEnvelopeData),
        "Replaced protected setting remained in \(file.name)."
      )
      for secret in sensitiveBytes {
        XCTAssertNil(
          file.data.range(of: secret),
          "Replaced Webhook secret remained in \(file.name)."
        )
      }
    }
  }

  func testSensitiveResiduePurgeThrowsWhenWALTruncationIsBusy() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-test.sqlite")
    let store = try SQLitePersistenceStore(databaseURL: databaseURL)

    try await store.setString("first", forKey: .customWorkflows)
    try await store.purgeSensitiveStorageResidue()

    var reader: OpaquePointer?
    let openResult = sqlite3_open_v2(databaseURL.path, &reader, SQLITE_OPEN_READONLY, nil)
    XCTAssertEqual(openResult, SQLITE_OK)
    guard openResult == SQLITE_OK, let reader else { return }
    defer { sqlite3_close(reader) }
    XCTAssertEqual(
      sqlite3_exec(reader, "BEGIN; SELECT value FROM app_settings;", nil, nil, nil),
      SQLITE_OK
    )

    try await store.setString("replacement", forKey: .customWorkflows)
    do {
      try await store.purgeSensitiveStorageResidue()
      XCTFail("Expected a busy truncating checkpoint to fail the purge.")
    } catch let error as SQLitePersistenceError {
      guard case .executingSQL(let message) = error else {
        return XCTFail("Unexpected SQLite error: \(error)")
      }
      XCTAssertTrue(message.contains("busy"), "Unexpected purge failure: \(message)")
    }

    XCTAssertEqual(sqlite3_exec(reader, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
    try await store.purgeSensitiveStorageResidue()
  }

  func testHistoryDeletionAndResiduePurgeRemovePhysicalSentinelWithoutDeletingDiagnostics()
    async throws
  {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-test.sqlite")
    let store = try SQLitePersistenceStore(databaseURL: databaseURL)
    let historySentinel = "history-sensitive-sentinel-" + UUID().uuidString
    let diagnostic = DiagnosticEvent(
      timestamp: Date(timeIntervalSince1970: 200),
      subsystem: .records,
      level: .warning,
      event: "persistence.sentinel-control",
      message: "Diagnostic control remains after history cleanup."
    )

    let history = historyRecord(text: historySentinel, timestamp: 100)
    try await store.save(history)
    try await store.save(diagnostic)
    try await store.purgeSensitiveStorageResidue()

    let sentinelBytes = Data(historySentinel.utf8)
    for file in try persistedDatabaseBytes(at: databaseURL) {
      XCTAssertNil(
        file.data.range(of: sentinelBytes),
        "Run history was stored as plaintext in \(file.name)."
      )
    }
    let historyEnvelope = try XCTUnwrap(
      rawHistoryValue(column: "final_text", recordID: history.id, at: databaseURL)
    )
    XCTAssertTrue(historyEnvelope.hasPrefix("rill:v1:"))

    let removedCount = try await store.deleteAllRecords()
    XCTAssertEqual(removedCount, 1)
    try await store.purgeSensitiveStorageResidue()

    let historyEnvelopeData = Data(historyEnvelope.utf8)
    for file in try persistedDatabaseBytes(at: databaseURL) {
      XCTAssertNil(
        file.data.range(of: historyEnvelopeData),
        "Deleted protected history content remained in \(file.name)."
      )
    }
    let diagnostics = try await store.events(matching: DiagnosticQuery())
    XCTAssertEqual(diagnostics, [DiagnosticEventSanitizer.sanitize(diagnostic)])
  }

  func testDiagnosticDeletionAndResiduePurgeRemovePhysicalSentinelWithoutDeletingRunHistory()
    async throws
  {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-test.sqlite")
    let store = try SQLitePersistenceStore(databaseURL: databaseURL)
    let diagnosticSentinel = "diagnostic-sensitive-sentinel-" + UUID().uuidString
    let persistedEventSentinel = "persistence.sentinel-control"
    let history = historyRecord(text: "run-history-control", timestamp: 100)
    let diagnostic = DiagnosticEvent(
      timestamp: Date(timeIntervalSince1970: 200),
      subsystem: .session,
      level: .warning,
      event: persistedEventSentinel,
      message: diagnosticSentinel
    )

    try await store.save(history)
    try await store.save(diagnostic)
    try await store.purgeSensitiveStorageResidue()

    let rejectedMessageBytes = Data(diagnosticSentinel.utf8)
    let persistedEventBytes = Data(persistedEventSentinel.utf8)
    XCTAssertFalse(
      try persistedDatabaseBytes(at: databaseURL).contains {
        $0.data.range(of: rejectedMessageBytes) != nil
      },
      "The persistence boundary retained an unsanitized diagnostic message."
    )
    XCTAssertTrue(
      try persistedDatabaseBytes(at: databaseURL).contains {
        $0.data.range(of: persistedEventBytes) != nil
      },
      "The fixture did not persist the safe diagnostic event code before deletion."
    )

    let removedCount = try await store.deleteAllEvents()
    XCTAssertEqual(removedCount, 1)
    try await store.purgeSensitiveStorageResidue()

    for file in try persistedDatabaseBytes(at: databaseURL) {
      XCTAssertNil(
        file.data.range(of: persistedEventBytes),
        "Deleted diagnostic content remained in \(file.name)."
      )
    }
    let remainingHistory = try await store.records(matching: .all)
    XCTAssertEqual(remainingHistory, [history])
  }

  func testExportMetadataRoundTrip() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appendingPathComponent("rill-export.sqlite")
    let store = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: testProtector(byte: 0x39)
    )
    let destinationPath = "/tmp/private-export-\(UUID().uuidString).json"
    let metadataSentinel = "private-export-metadata-" + UUID().uuidString
    let export = ExportMetadata(
      kind: .diagnostics,
      destinationPath: destinationPath,
      itemCount: 7,
      createdAt: Date(timeIntervalSince1970: 128),
      metadata: ["format": metadataSentinel]
    )

    try await store.save(export)
    try await store.purgeSensitiveStorageResidue()
    let exports = try await store.exports(limit: 10)

    XCTAssertEqual(exports, [export])
    for column in ["destination_path", "metadata_json"] {
      XCTAssertTrue(
        try XCTUnwrap(
          rawExportValue(column: column, recordID: export.id, at: databaseURL)
        ).hasPrefix("rill:v1:")
      )
    }
    for sentinel in [destinationPath, metadataSentinel] {
      let sentinelData = Data(sentinel.utf8)
      for file in try persistedDatabaseBytes(at: databaseURL) {
        XCTAssertNil(
          file.data.range(of: sentinelData),
          "Export metadata reached \(file.name) as plaintext."
        )
      }
    }
  }

  func testRunHistoryBrowsePaginates121SameTimestampEntriesWithoutDuplicatesAndFreezesWrites()
    async throws
  {
    let store = try makeStore()
    let timestamp = Date(timeIntervalSince1970: 1_000)
    let expectedIDs = (1 ... 121).map(deterministicUUID)
    for runID in expectedIDs.reversed() {
      try await store.insertTerminal(
        try browsingReceipt(runID: runID, trigger: .hotkey, timestamp: timestamp)
      )
    }

    let first = try await store.page(
      .first(
        scope: .allRuns,
        retentionCutoff: nil,
        contentAccess: .metadataOnly,
        limit: 50
      )
    )
    XCTAssertEqual(first.entries.map(\.id), Array(expectedIDs.prefix(50)))
    let firstCursor = try XCTUnwrap(first.nextCursor)

    let lateNewerID = deterministicUUID(900)
    let lateOlderID = deterministicUUID(901)
    try await store.insertTerminal(
      try browsingReceipt(
        runID: lateNewerID,
        trigger: .hotkey,
        timestamp: timestamp.addingTimeInterval(100)
      )
    )
    try await store.insertTerminal(
      try browsingReceipt(
        runID: lateOlderID,
        trigger: .hotkey,
        timestamp: timestamp.addingTimeInterval(-100)
      )
    )

    let second = try await store.page(.next(cursor: firstCursor, limit: 50))
    XCTAssertEqual(second.entries.map(\.id), Array(expectedIDs[50 ..< 100]))
    let secondCursor = try XCTUnwrap(second.nextCursor)
    let third = try await store.page(.next(cursor: secondCursor, limit: 50))
    XCTAssertEqual(third.entries.map(\.id), Array(expectedIDs[100 ..< 121]))
    XCTAssertNil(third.nextCursor)

    let snapshotIDs = first.entries.map(\.id) + second.entries.map(\.id)
      + third.entries.map(\.id)
    XCTAssertEqual(snapshotIDs.count, 121)
    XCTAssertEqual(Set(snapshotIDs).count, 121)
    XCTAssertFalse(snapshotIDs.contains(lateNewerID))
    XCTAssertFalse(snapshotIDs.contains(lateOlderID))

    let fresh = try await store.page(
      .first(
        scope: .allRuns,
        retentionCutoff: nil,
        contentAccess: .metadataOnly,
        limit: 50
      )
    )
    XCTAssertEqual(fresh.entries.first?.id, lateNewerID)
    XCTAssertEqual(fresh.session.snapshotWriteOrdinal, 123)
  }

  func testRunHistoryBrowseMergesOnlyVoiceBodiesAndFiltersVoiceResults() async throws {
    let store = try makeStore()
    let voiceRunID = deterministicUUID(201)
    let clipboardRunID = deterministicUUID(202)
    let orphanRunID = deterministicUUID(203)
    let mismatchedVoiceRunID = deterministicUUID(205)
    let longBody = String(repeating: "voice ", count: 30)
    let voiceReceipt = try browsingReceipt(
      runID: voiceRunID,
      trigger: .hotkey,
      timestamp: Date(timeIntervalSince1970: 300)
    )
    let clipboardReceipt = try browsingReceipt(
      runID: clipboardRunID,
      trigger: .recordReplay,
      timestamp: Date(timeIntervalSince1970: 200)
    )
    let mismatchedVoiceReceipt = try browsingReceipt(
      runID: mismatchedVoiceRunID,
      trigger: .hotkey,
      timestamp: Date(timeIntervalSince1970: 250)
    )
    let voiceRecord = browsingRecord(
      id: deterministicUUID(211),
      runID: voiceRunID,
      trigger: .hotkey,
      text: longBody,
      timestamp: 299
    )
    let clipboardRecord = browsingRecord(
      id: deterministicUUID(212),
      runID: clipboardRunID,
      trigger: .recordReplay,
      text: "clipboard secret",
      timestamp: 199
    )
    let mismatchedVoiceRecord = browsingRecord(
      id: deterministicUUID(215),
      runID: mismatchedVoiceRunID,
      trigger: .manual,
      text: "must not cross trigger boundary",
      timestamp: 249
    )
    let orphanRecord = browsingRecord(
      id: deterministicUUID(213),
      runID: orphanRunID,
      trigger: .manual,
      text: "orphan voice",
      timestamp: 100
    )
    let emptyVoiceRecord = browsingRecord(
      id: deterministicUUID(214),
      runID: deterministicUUID(204),
      trigger: .manual,
      text: " \n ",
      timestamp: 90
    )
    try await store.insertTerminal(voiceReceipt)
    try await store.insertTerminal(clipboardReceipt)
    try await store.insertTerminal(mismatchedVoiceReceipt)
    for record in [
      voiceRecord,
      clipboardRecord,
      mismatchedVoiceRecord,
      orphanRecord,
      emptyVoiceRecord,
    ] {
      try await store.save(record)
    }

    let allRuns = try await store.page(
      .first(
        scope: .allRuns,
        retentionCutoff: nil,
        contentAccess: .full,
        limit: 10
      )
    )
    let voiceEntry = try XCTUnwrap(allRuns.entries.first { $0.id == voiceRunID })
    XCTAssertEqual(voiceEntry.record?.finalText, longBody)
    let clipboardEntry = try XCTUnwrap(
      allRuns.entries.first { $0.id == clipboardRunID }
    )
    XCTAssertNil(clipboardEntry.recordMetadata)
    XCTAssertNil(clipboardEntry.record)
    let mismatchedEntry = try XCTUnwrap(
      allRuns.entries.first { $0.id == mismatchedVoiceRunID }
    )
    XCTAssertNil(mismatchedEntry.recordMetadata)
    XCTAssertNil(mismatchedEntry.record)
    let orphanEntry = try XCTUnwrap(allRuns.entries.first { $0.id == orphanRunID })
    XCTAssertEqual(orphanEntry.record?.id, orphanRecord.id)

    let voiceResults = try await store.page(
      .first(
        scope: .voiceResults,
        retentionCutoff: nil,
        contentAccess: .metadataOnly,
        limit: 10
      )
    )
    XCTAssertEqual(voiceResults.entries.map(\.id), [voiceRunID, orphanRunID])
    XCTAssertTrue(voiceResults.entries.allSatisfy { $0.record == nil })
  }

  func testRunHistoryContentAccessAvoidsBodyOpensAndCapsRestrictedProjection() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let protector = try RecordingLocalDataProtector(byte: 0x6A)
    let store = try SQLitePersistenceStore(
      databaseURL: directoryURL.appendingPathComponent("content-access.sqlite"),
      localDataProtector: protector
    )
    let body = String(repeating: "private body ", count: 20)
    let record = WorkflowResultRecord(
      id: deterministicUUID(301),
      runID: deterministicUUID(302),
      workflow: WorkflowPresentation(fallbackName: "Private workflow"),
      finalText: body,
      timestamp: Date(timeIntervalSince1970: 100),
      outcome: .completed,
      correctionSource: RecognitionCorrectionSource(
        preMappingText: "private pre-mapping body",
        context: VocabularyRuleContext(locale: "en-US"),
        languageModelInputTexts: ["private LLM input"],
        processingSteps: [
          WorkflowTextStep(kind: .recognizeSpeech, outputText: body),
          WorkflowTextStep(kind: .llmRewrite, outputText: body,
                           tokenUsage: .init(inputTokens: 120, outputTokens: 24, totalTokens: 144))
        ]
      ),
      trigger: .manual
    )
    try await store.save(record)

    protector.resetOpenedContexts()
    let metadataPage = try await store.page(
      .first(
        scope: .allRuns,
        retentionCutoff: nil,
        contentAccess: .metadataOnly,
        limit: 10
      )
    )
    XCTAssertNil(metadataPage.entries.first?.record)
    XCTAssertTrue(protector.openedContexts().isEmpty)

    protector.resetOpenedContexts()
    let restrictedPage = try await store.page(
      .first(
        scope: .allRuns,
        retentionCutoff: nil,
        contentAccess: .restrictedPreview,
        limit: 10
      )
    )
    let restricted = try XCTUnwrap(restrictedPage.entries.first?.record)
    XCTAssertEqual(
      restricted.finalText,
      RecordTextFormatting.previewText(
        body,
        limit: RunHistoryContentAccess.restrictedPreviewCharacterLimit
      )
    )
    XCTAssertEqual(restricted.correctionSource, record.correctionSource?.restrictedStepPreview)
    XCTAssertEqual(restricted.correctionSource?.processingSteps?.first?.outputText, restricted.finalText)
    XCTAssertEqual(restricted.correctionSource?.processingSteps?.last?.tokenUsage,
                   .init(inputTokens: 120, outputTokens: 24, totalTokens: 144))
    XCTAssertNil(restricted.correctionSource?.languageModelInputTexts)
    XCTAssertTrue(protector.openedContexts().contains { $0.field == "final_text" })

    protector.resetOpenedContexts()
    let fullPage = try await store.page(
      .first(
        scope: .allRuns,
        retentionCutoff: nil,
        contentAccess: .full,
        limit: 10
      )
    )
    XCTAssertEqual(fullPage.entries.first?.record, record)
    XCTAssertTrue(protector.openedContexts().contains { $0.field == "correction_source_json" })
  }

  func testRunHistoryBrowseSkipsMoreThanOneRawBatchOfCorruptRows() async throws {
    let store = try makeStore()
    let databaseURL = await store.databaseURL
    let valid = try browsingReceipt(
      runID: deterministicUUID(401),
      trigger: .hotkey,
      timestamp: Date(timeIntervalSince1970: 1)
    )
    try await store.insertTerminal(valid)
    var corruptReceipts: [WorkflowRunReceipt] = []
    for offset in 0 ..< 70 {
      let receipt = try browsingReceipt(
        runID: deterministicUUID(500 + offset),
        trigger: .hotkey,
        timestamp: Date(timeIntervalSince1970: TimeInterval(100 + offset))
      )
      corruptReceipts.append(receipt)
      try await store.insertTerminal(receipt)
    }
    for receipt in corruptReceipts {
      try replaceRunReceiptPayload(
        "invalid-protected-receipt",
        runID: receipt.runID,
        at: databaseURL
      )
    }

    let page = try await store.page(
      .first(
        scope: .allRuns,
        retentionCutoff: nil,
        contentAccess: .metadataOnly,
        limit: 1
      )
    )
    XCTAssertEqual(page.entries.map(\.id), [valid.runID])
    XCTAssertNil(page.nextCursor)
  }

  func testRunHistoryClearInvalidatesCursorAndRetentionDoesNotResurrectTarget() async throws {
    let store = try makeStore()
    let firstReceipt = try browsingReceipt(
      runID: deterministicUUID(601),
      trigger: .hotkey,
      timestamp: Date(timeIntervalSince1970: 20)
    )
    let secondReceipt = try browsingReceipt(
      runID: deterministicUUID(602),
      trigger: .hotkey,
      timestamp: Date(timeIntervalSince1970: 10)
    )
    try await store.insertTerminal(firstReceipt)
    try await store.insertTerminal(secondReceipt)
    let firstPage = try await store.page(
      .first(
        scope: .allRuns,
        retentionCutoff: nil,
        contentAccess: .metadataOnly,
        limit: 1
      )
    )
    let cursor = try XCTUnwrap(firstPage.nextCursor)
    let transition = try RunHistoryClearTransition(
      advancing: firstPage.session.generation
    )
    _ = try await store.deleteReceipts(
      obsoletedBy: transition,
      preservingLegacyRowsAfter: nil
    )
    do {
      _ = try await store.page(.next(cursor: cursor, limit: 1))
      XCTFail("Expected a logical clear to invalidate the read session.")
    } catch let error as RunHistoryBrowsingError {
      XCTAssertEqual(
        error,
        .sessionInvalidated(
          expected: firstPage.session.generation,
          actual: transition.nextGeneration
        )
      )
    }

    let retainedTarget = try browsingReceipt(
      runID: deterministicUUID(603),
      trigger: .hotkey,
      timestamp: Date(timeIntervalSince1970: 30)
    )
    try await store.insertTerminal(retainedTarget)
    let locatedValue = try await store.page(
      containing: retainedTarget.runID,
      scope: .allRuns,
      retentionCutoff: nil,
      contentAccess: .metadataOnly,
      limit: 10
    )
    let located = try XCTUnwrap(locatedValue)
    _ = try await store.deleteReceipts(olderThan: Date(timeIntervalSince1970: 31))
    let afterRetention = try await store.page(
      containing: retainedTarget.runID,
      in: located.session,
      limit: 10
    )
    XCTAssertNil(afterRetention)
  }

  func testRunHistoryOrphanDeepLinksUseRunAndRecordAliasesAndDedupeSameRun() async throws {
    let store = try makeStore()
    let runID = deterministicUUID(701)
    let older = browsingRecord(
      id: deterministicUUID(702),
      runID: runID,
      trigger: .manual,
      text: "older",
      timestamp: 10
    )
    let newer = browsingRecord(
      id: deterministicUUID(703),
      runID: runID,
      trigger: .manual,
      text: "newer",
      timestamp: 20
    )
    try await store.save(older)
    try await store.save(newer)

    let page = try await store.page(
      .first(
        scope: .allRuns,
        retentionCutoff: nil,
        contentAccess: .metadataOnly,
        limit: 10
      )
    )
    XCTAssertEqual(page.entries.map(\.id), [runID])
    XCTAssertEqual(page.entries.first?.recordMetadata?.recordID, newer.id)
    let runLookup = try await store.page(
      containing: runID,
      scope: .allRuns,
      retentionCutoff: nil,
      contentAccess: .metadataOnly,
      limit: 10
    )
    XCTAssertNotNil(runLookup)
    let recordLookup = try await store.page(
      containing: newer.id,
      scope: .allRuns,
      retentionCutoff: nil,
      contentAccess: .metadataOnly,
      limit: 10
    )
    XCTAssertNotNil(recordLookup)
    let discardedRecordLookup = try await store.page(
      containing: older.id,
      scope: .allRuns,
      retentionCutoff: nil,
      contentAccess: .metadataOnly,
      limit: 10
    )
    XCTAssertNil(discardedRecordLookup)
  }

  func testRunHistoryStableContentRevisionPreservesSnapshotAndIdentityMutationFails() async throws {
    let store = try makeStore()
    let databaseURL = await store.databaseURL
    let recordID = deterministicUUID(801)
    let runID = deterministicUUID(802)
    let original = browsingRecord(
      id: recordID,
      runID: runID,
      trigger: .manual,
      text: "original body",
      timestamp: 50
    )
    try await store.save(original)
    let first = try await store.page(
      .first(
        scope: .allRuns,
        retentionCutoff: nil,
        contentAccess: .full,
        limit: 10
      )
    )
    let originalOrdinal = try historyWriteOrdinal(recordID: recordID, at: databaseURL)
    let revised = WorkflowResultRecord(
      id: original.id,
      runID: original.runID,
      workflowID: original.workflowID,
      workflow: WorkflowPresentation(fallbackName: "Revised workflow"),
      finalText: "revised body",
      timestamp: original.timestamp,
      isRecordRelated: original.isRecordRelated,
      outcome: original.outcome,
      correctionSource: RecognitionCorrectionSource(
        preMappingText: "original body",
        context: VocabularyRuleContext(locale: "en-US")
      ),
      trigger: original.trigger
    )
    try await store.save(revised)
    XCTAssertEqual(
      try historyWriteOrdinal(recordID: recordID, at: databaseURL),
      originalOrdinal
    )
    let locatedValue = try await store.page(
      containing: recordID,
      in: first.session,
      limit: 10
    )
    let located = try XCTUnwrap(locatedValue)
    XCTAssertEqual(located.entries.first?.record, revised)

    let conflicting = WorkflowResultRecord(
      id: revised.id,
      runID: revised.runID,
      workflowID: revised.workflowID,
      workflow: revised.workflow,
      finalText: revised.finalText,
      timestamp: revised.timestamp,
      isRecordRelated: revised.isRecordRelated,
      outcome: revised.outcome,
      correctionSource: revised.correctionSource,
      trigger: .recordReplay
    )
    do {
      try await store.save(conflicting)
      XCTFail("Expected an indexed history identity mutation to fail closed.")
    } catch let error as HistoryRepositoryError {
      XCTAssertEqual(error, .conflictingHistoryRecord(recordID: recordID))
    }
  }

  func testRunHistoryBrowseRejectsLimitsOutsideProductBound() async throws {
    let store = try makeStore()
    for limit in [0, 51] {
      do {
        _ = try await store.page(
          .first(
            scope: .allRuns,
            retentionCutoff: nil,
            contentAccess: .metadataOnly,
            limit: limit
          )
        )
        XCTFail("Expected limit \(limit) to be rejected.")
      } catch let error as RunHistoryBrowsingError {
        XCTAssertEqual(error, .invalidLimit(limit))
      }
    }
  }

  private func deterministicUUID(_ value: Int) -> UUID {
    UUID(
      uuidString: String(
        format: "00000000-0000-0000-0000-%012llX",
        Int64(value)
      )
    )!
  }

  private func browsingReceipt(
    runID: UUID,
    trigger: WorkflowRunTriggerKind,
    timestamp: Date
  ) throws -> WorkflowRunReceipt {
    try WorkflowRunReceipt(
      runID: runID,
      workflowID: deterministicUUID(999),
      trigger: trigger,
      timestamp: timestamp,
      duration: .under250ms,
      termination: .completed
    )
  }

  private func browsingRecord(
    id: UUID,
    runID: UUID?,
    trigger: WorkflowRunTriggerKind?,
    text: String,
    timestamp: TimeInterval
  ) -> WorkflowResultRecord {
    WorkflowResultRecord(
      id: id,
      runID: runID,
      workflowID: deterministicUUID(999),
      workflow: WorkflowPresentation(fallbackName: "Browse workflow"),
      finalText: text,
      timestamp: Date(timeIntervalSince1970: timestamp),
      outcome: .completed,
      trigger: trigger
    )
  }

  private func historyWriteOrdinal(recordID: UUID, at databaseURL: URL) throws -> Int64 {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
      databaseURL.path,
      &database,
      SQLITE_OPEN_READONLY,
      nil
    ) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase(
        "Failed to inspect history write ordinal."
      )
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
      database,
      "SELECT write_ordinal FROM history_records WHERE id = ?;",
      -1,
      &statement,
      nil
    ) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement(
        "Failed to inspect history write ordinal."
      )
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let bindResult = recordID.uuidString.withCString {
      sqlite3_bind_text(statement, 1, $0, -1, transient)
    }
    guard bindResult == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else {
      throw SQLitePersistenceError.steppingStatement(
        "Failed to inspect history write ordinal."
      )
    }
    return sqlite3_column_int64(statement, 0)
  }

  private func makeStore(file: StaticString = #filePath, line: UInt = #line) throws
    -> SQLitePersistenceStore
  {
    let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      return try SQLitePersistenceStore(
        databaseURL: directoryURL.appendingPathComponent("rill-test.sqlite")
      )
    } catch {
      XCTFail("Failed to create SQLitePersistenceStore: \(error)", file: file, line: line)
      throw error
    }
  }

  private func historyRecord(text: String, timestamp: TimeInterval) -> WorkflowResultRecord {
    WorkflowResultRecord(
      workflow: WorkflowPresentation(fallbackName: "History"),
      finalText: text,
      timestamp: Date(timeIntervalSince1970: timestamp),
      outcome: .completed
    )
  }

  private func workflowRunReceipt(
    workflowID: UUID? = UUID(),
    trigger: WorkflowRunTriggerKind = .manual,
    timestamp: TimeInterval
  ) throws -> WorkflowRunReceipt {
    try WorkflowRunReceipt(
      runID: UUID(),
      workflowID: workflowID,
      trigger: trigger,
      timestamp: Date(timeIntervalSince1970: timestamp),
      duration: .under250ms,
      termination: .completed
    )
  }

  private func diagnosticEvent(name: String, timestamp: TimeInterval) -> DiagnosticEvent {
    DiagnosticEvent(
      timestamp: Date(timeIntervalSince1970: timestamp),
      subsystem: .session,
      level: .info,
      event: "diagnostic.\(name)",
      message: name
    )
  }

  private func testProtector(byte: UInt8) throws -> AESGCMDataProtector {
    try AESGCMDataProtector(
      key: Data(repeating: byte, count: AESGCMDataProtector.keyByteCount)
    )
  }

  private func createDowngradedExactV4Fixture(
    at databaseURL: URL,
    protector: any LocalDataProtector
  ) throws -> DowngradedExactV4Fixture {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase(
        "Failed to create an exact-v4 recovery fixture."
      )
    }
    defer { sqlite3_close(database) }

    let schema = """
      PRAGMA user_version = 1;
      PRAGMA secure_delete = OFF;
      CREATE TABLE history_records (
          id TEXT PRIMARY KEY,
          run_id TEXT,
          workflow_id TEXT,
          workflow_fallback_name TEXT NOT NULL,
          workflow_title_key TEXT,
          final_text TEXT,
          failure_message TEXT,
          timestamp REAL NOT NULL,
          is_stack_related INTEGER NOT NULL,
          outcome TEXT NOT NULL,
          correction_source_json TEXT
      );
      CREATE INDEX idx_history_records_timestamp
      ON history_records (timestamp DESC);
      CREATE TABLE diagnostic_events (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          timestamp REAL NOT NULL,
          run_id TEXT,
          subsystem TEXT NOT NULL,
          level TEXT NOT NULL,
          level_severity INTEGER NOT NULL,
          event TEXT NOT NULL,
          message TEXT NOT NULL,
          metadata_json TEXT NOT NULL
      );
      CREATE INDEX idx_diagnostic_events_timestamp
      ON diagnostic_events (timestamp DESC);
      CREATE TABLE app_settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL,
          updated_at REAL NOT NULL
      );
      CREATE TABLE export_metadata (
          id TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          destination_path TEXT NOT NULL,
          item_count INTEGER NOT NULL,
          created_at REAL NOT NULL,
          metadata_json TEXT NOT NULL
      );
      CREATE INDEX idx_export_metadata_created_at
      ON export_metadata (created_at DESC);
      CREATE TABLE local_data_protection (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          key_verification TEXT NOT NULL,
          cleanup_pending INTEGER NOT NULL CHECK (cleanup_pending IN (0, 1))
      );
      """
    guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
      throw SQLitePersistenceError.executingSQL(
        "Failed to create an exact-v4 recovery schema."
      )
    }

    let firstHistoryID = UUID()
    let secondHistoryID = UUID()
    let exportID = UUID()
    let firstFallbackPlaintext = "protected-v4-fallback-\(UUID().uuidString)"
    let firstFinalTextPlaintext = "plaintext-v4-final-\(UUID().uuidString)"
    let firstCorrectionPlaintext = "protected-v4-correction-\(UUID().uuidString)"
    let secondFallbackPlaintext = "plaintext-v4-fallback-\(UUID().uuidString)"
    let secondFinalTextPlaintext = "protected-v4-final-\(UUID().uuidString)"
    let secondCorrectionPlaintext = "plaintext-v4-correction-\(UUID().uuidString)"
    let firstFailurePlaintext = "plaintext-v4-failure-\(UUID().uuidString)"
    let secondFailurePlaintext = "plaintext-v4-failure-\(UUID().uuidString)"
    let protectedSettingPlaintext = "protected-v4-setting-\(UUID().uuidString)"
    let plainSettingValue = UUID().uuidString
    let exportPathPlaintext = "/tmp/protected-v4-export-\(UUID().uuidString).json"
    let exportMetadataPlaintext =
      "{\"sentinel\":\"plaintext-v4-export-\(UUID().uuidString)\"}"
    let diagnosticEventPlaintext = "unsafe-v4-event-\(UUID().uuidString)"
    let diagnosticMessagePlaintext = "plaintext-v4-diagnostic-\(UUID().uuidString)"
    let diagnosticMetadataPlaintext =
      "{\"sentinel\":\"plaintext-v4-diagnostic-metadata-\(UUID().uuidString)\"}"

    let markerEnvelope = try protector.seal(
      Data("Rill local data key verification v1".utf8),
      context: LocalDataProtectionContext(
        namespace: "local_data_protection",
        recordID: "1",
        field: "key_verification"
      )
    )
    let firstFallbackEnvelope = try protector.seal(
      Data(firstFallbackPlaintext.utf8),
      context: LocalDataProtectionContext(
        namespace: "history_records",
        recordID: firstHistoryID.uuidString,
        field: "workflow_fallback_name"
      )
    )
    let firstCorrectionEnvelope = try protector.seal(
      Data(firstCorrectionPlaintext.utf8),
      context: LocalDataProtectionContext(
        namespace: "history_records",
        recordID: firstHistoryID.uuidString,
        field: "correction_source_json"
      )
    )
    let secondFinalTextEnvelope = try protector.seal(
      Data(secondFinalTextPlaintext.utf8),
      context: LocalDataProtectionContext(
        namespace: "history_records",
        recordID: secondHistoryID.uuidString,
        field: "final_text"
      )
    )
    let protectedSettingEnvelope = try protector.seal(
      Data(protectedSettingPlaintext.utf8),
      context: LocalDataProtectionContext(
        namespace: "app_settings",
        recordID: AppSettingKey.interfaceLanguage.rawValue,
        field: "value"
      )
    )
    let protectedExportPathEnvelope = try protector.seal(
      Data(exportPathPlaintext.utf8),
      context: LocalDataProtectionContext(
        namespace: "export_metadata",
        recordID: exportID.uuidString,
        field: "destination_path"
      )
    )

    try executeBoundFixtureSQL(
      """
      INSERT INTO local_data_protection (id, key_verification, cleanup_pending)
      VALUES (1, ?, 0);
      """,
      bindings: [markerEnvelope],
      on: database
    )
    try executeBoundFixtureSQL(
      """
      INSERT INTO history_records (
          id, workflow_fallback_name, final_text, failure_message,
          timestamp, is_stack_related, outcome, correction_source_json
      ) VALUES (?, ?, ?, ?, 1, 0, 'completed', ?);
      """,
      bindings: [
        firstHistoryID.uuidString,
        firstFallbackEnvelope,
        firstFinalTextPlaintext,
        firstFailurePlaintext,
        firstCorrectionEnvelope,
      ],
      on: database
    )
    try executeBoundFixtureSQL(
      """
      INSERT INTO history_records (
          id, workflow_fallback_name, final_text, failure_message,
          timestamp, is_stack_related, outcome, correction_source_json
      ) VALUES (?, ?, ?, ?, 2, 0, 'completed', ?);
      """,
      bindings: [
        secondHistoryID.uuidString,
        secondFallbackPlaintext,
        secondFinalTextEnvelope,
        secondFailurePlaintext,
        secondCorrectionPlaintext,
      ],
      on: database
    )
    try executeBoundFixtureSQL(
      "INSERT INTO app_settings (key, value, updated_at) VALUES (?, ?, 1);",
      bindings: [AppSettingKey.interfaceLanguage.rawValue, protectedSettingEnvelope],
      on: database
    )
    try executeBoundFixtureSQL(
      "INSERT INTO app_settings (key, value, updated_at) VALUES (?, ?, 2);",
      bindings: [AppSettingKey.selectedWorkflowID.rawValue, plainSettingValue],
      on: database
    )
    try executeBoundFixtureSQL(
      """
      INSERT INTO export_metadata (
          id, kind, destination_path, item_count, created_at, metadata_json
      ) VALUES (?, 'history', ?, 2, 3, ?);
      """,
      bindings: [
        exportID.uuidString,
        protectedExportPathEnvelope,
        exportMetadataPlaintext,
      ],
      on: database
    )
    try executeBoundFixtureSQL(
      """
      INSERT INTO diagnostic_events (
          timestamp, subsystem, level, level_severity, event, message, metadata_json
      ) VALUES (4, 'persistence', 'warning', 2, ?, ?, ?);
      """,
      bindings: [
        diagnosticEventPlaintext,
        diagnosticMessagePlaintext,
        diagnosticMetadataPlaintext,
      ],
      on: database
    )

    return DowngradedExactV4Fixture(
      markerEnvelope: markerEnvelope,
      firstHistoryID: firstHistoryID,
      firstFallbackEnvelope: firstFallbackEnvelope,
      firstFinalTextPlaintext: firstFinalTextPlaintext,
      firstCorrectionEnvelope: firstCorrectionEnvelope,
      secondHistoryID: secondHistoryID,
      secondFallbackPlaintext: secondFallbackPlaintext,
      secondFinalTextEnvelope: secondFinalTextEnvelope,
      protectedSettingEnvelope: protectedSettingEnvelope,
      plainSettingValue: plainSettingValue,
      exportID: exportID,
      protectedExportPathEnvelope: protectedExportPathEnvelope,
      exportMetadataPlaintext: exportMetadataPlaintext,
      diagnosticEventPlaintext: diagnosticEventPlaintext,
      plaintextResidueSentinels: [
        firstFinalTextPlaintext,
        secondFallbackPlaintext,
        secondCorrectionPlaintext,
        firstFailurePlaintext,
        secondFailurePlaintext,
        plainSettingValue,
        exportMetadataPlaintext,
        diagnosticEventPlaintext,
        diagnosticMessagePlaintext,
        diagnosticMetadataPlaintext,
      ]
    )
  }

  private func executeBoundFixtureSQL(
    _ sql: String,
    bindings: [String],
    on database: OpaquePointer?
  ) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement(
        "Failed to prepare an exact-v4 fixture statement."
      )
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (offset, value) in bindings.enumerated() {
      let result = value.withCString {
        sqlite3_bind_text(statement, Int32(offset + 1), $0, -1, transient)
      }
      guard result == SQLITE_OK else {
        throw SQLitePersistenceError.bindingValue(
          "Failed to bind an exact-v4 fixture statement."
        )
      }
    }
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw SQLitePersistenceError.steppingStatement(
        "Failed to execute an exact-v4 fixture statement."
      )
    }
  }

  private func downgradedV4LogicalSnapshot(
    fixture: DowngradedExactV4Fixture,
    at databaseURL: URL
  ) throws -> DowngradedV4LogicalSnapshot {
    DowngradedV4LogicalSnapshot(
      version: try schemaVersion(at: databaseURL),
      cleanupPending: try cleanupPendingValue(at: databaseURL),
      markerEnvelope: try rawKeyVerificationEnvelope(at: databaseURL),
      values: [
        try rawHistoryValue(
          column: "workflow_fallback_name",
          recordID: fixture.firstHistoryID,
          at: databaseURL
        ),
        try rawHistoryValue(
          column: "final_text",
          recordID: fixture.firstHistoryID,
          at: databaseURL
        ),
        try rawHistoryValue(
          column: "correction_source_json",
          recordID: fixture.firstHistoryID,
          at: databaseURL
        ),
        try rawTextValue(
          "failure_message",
          table: "history_records",
          identifierColumn: "id",
          identifier: fixture.firstHistoryID.uuidString,
          at: databaseURL
        ),
        try rawHistoryValue(
          column: "workflow_fallback_name",
          recordID: fixture.secondHistoryID,
          at: databaseURL
        ),
        try rawHistoryValue(
          column: "final_text",
          recordID: fixture.secondHistoryID,
          at: databaseURL
        ),
        try rawHistoryValue(
          column: "correction_source_json",
          recordID: fixture.secondHistoryID,
          at: databaseURL
        ),
        try rawSettingValue(forKey: .interfaceLanguage, at: databaseURL),
        try rawSettingValue(forKey: .selectedWorkflowID, at: databaseURL),
        try rawExportValue(
          column: "destination_path",
          recordID: fixture.exportID,
          at: databaseURL
        ),
        try rawExportValue(
          column: "metadata_json",
          recordID: fixture.exportID,
          at: databaseURL
        ),
        try rawTextValue(
          "event",
          table: "diagnostic_events",
          identifierColumn: "id",
          identifier: "1",
          at: databaseURL
        ),
        try rawTextValue(
          "message",
          table: "diagnostic_events",
          identifierColumn: "id",
          identifier: "1",
          at: databaseURL
        ),
        try rawTextValue(
          "metadata_json",
          table: "diagnostic_events",
          identifierColumn: "id",
          identifier: "1",
          at: databaseURL
        ),
      ],
      rowCounts: [
        try rowCount(in: "history_records", at: databaseURL),
        try rowCount(in: "app_settings", at: databaseURL),
        try rowCount(in: "export_metadata", at: databaseURL),
        try rowCount(in: "diagnostic_events", at: databaseURL),
      ]
    )
  }

  private func rawTextValue(
    _ column: String,
    table: String,
    identifierColumn: String,
    identifier: String,
    at databaseURL: URL
  ) throws -> String? {
    let allowedCoordinates = Set([
      "history_records:id:failure_message",
      "diagnostic_events:id:event",
      "diagnostic_events:id:message",
      "diagnostic_events:id:metadata_json",
    ])
    guard allowedCoordinates.contains("\(table):\(identifierColumn):\(column)") else {
      throw SQLitePersistenceError.preparingStatement("Unsupported test coordinate.")
    }
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to inspect an exact-v4 fixture.")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT \(column) FROM \(table) WHERE \(identifierColumn) = ?;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement(
        "Failed to inspect an exact-v4 fixture value."
      )
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    identifier.withCString {
      XCTAssertEqual(sqlite3_bind_text(statement, 1, $0, -1, transient), SQLITE_OK)
    }
    guard sqlite3_step(statement) == SQLITE_ROW,
      let value = sqlite3_column_text(statement, 0)
    else {
      return nil
    }
    return String(cString: value)
  }

  private func rowCount(in table: String, at databaseURL: URL) throws -> Int {
    let allowedTables = Set([
      "history_records",
      "app_settings",
      "export_metadata",
      "diagnostic_events",
    ])
    guard allowedTables.contains(table) else {
      throw SQLitePersistenceError.preparingStatement("Unsupported test table.")
    }
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to count exact-v4 fixture rows.")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT COUNT(*) FROM \(table);",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement,
      sqlite3_step(statement) == SQLITE_ROW
    else {
      throw SQLitePersistenceError.preparingStatement("Failed to count exact-v4 fixture rows.")
    }
    defer { sqlite3_finalize(statement) }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func executeFixtureSQL(_ sql: String, at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to modify a test fixture.")
    }
    defer { sqlite3_close(database) }
    try SQLiteWriterBarrier.registerCapability(on: database)
    try SQLiteSchemaWriterBarrier.catalog.register(on: database)
    try SQLiteSchemaWriterBarrier.memory.register(on: database)
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw SQLitePersistenceError.executingSQL("Failed to modify a test fixture.")
    }
  }

  private func createV3Database(
    at databaseURL: URL,
    records: [WorkflowResultRecord],
    settingKey: AppSettingKey,
    settingValue: String
  ) throws {
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
    guard let database else { return }
    defer { sqlite3_close(database) }

    let schema = """
      PRAGMA user_version = 3;
      CREATE TABLE history_records (
          id TEXT PRIMARY KEY,
          run_id TEXT,
          workflow_id TEXT,
          workflow_fallback_name TEXT NOT NULL,
          workflow_title_key TEXT,
          final_text TEXT,
          failure_message TEXT,
          timestamp REAL NOT NULL,
          is_stack_related INTEGER NOT NULL,
          outcome TEXT NOT NULL,
          correction_source_json TEXT
      );
      CREATE TABLE app_settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL,
          updated_at REAL NOT NULL
      );
      CREATE TABLE diagnostic_events (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          timestamp REAL NOT NULL,
          run_id TEXT,
          subsystem TEXT NOT NULL,
          level TEXT NOT NULL,
          level_severity INTEGER NOT NULL,
          event TEXT NOT NULL,
          message TEXT NOT NULL,
          metadata_json TEXT NOT NULL
      );
      CREATE TABLE export_metadata (
          id TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          destination_path TEXT NOT NULL,
          item_count INTEGER NOT NULL,
          created_at REAL NOT NULL,
          metadata_json TEXT NOT NULL
      );
      """
    XCTAssertEqual(sqlite3_exec(database, schema, nil, nil, nil), SQLITE_OK)
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    for record in records {
      var statement: OpaquePointer?
      XCTAssertEqual(
        sqlite3_prepare_v2(
          database,
          """
          INSERT INTO history_records (
              id, workflow_fallback_name, final_text, timestamp,
              is_stack_related, outcome, correction_source_json
          ) VALUES (?, ?, ?, ?, ?, ?, ?);
          """,
          -1,
          &statement,
          nil
        ),
        SQLITE_OK
      )
      guard let statement else { continue }
      defer { sqlite3_finalize(statement) }
      record.id.uuidString.withCString {
        XCTAssertEqual(sqlite3_bind_text(statement, 1, $0, -1, transient), SQLITE_OK)
      }
      record.workflow.fallbackName.withCString {
        XCTAssertEqual(sqlite3_bind_text(statement, 2, $0, -1, transient), SQLITE_OK)
      }
      if let finalText = record.finalText {
        finalText.withCString {
          XCTAssertEqual(sqlite3_bind_text(statement, 3, $0, -1, transient), SQLITE_OK)
        }
      } else {
        XCTAssertEqual(sqlite3_bind_null(statement, 3), SQLITE_OK)
      }
      XCTAssertEqual(
        sqlite3_bind_double(statement, 4, record.timestamp.timeIntervalSince1970),
        SQLITE_OK
      )
      XCTAssertEqual(sqlite3_bind_int(statement, 5, record.isRecordRelated ? 1 : 0), SQLITE_OK)
      record.outcome.rawValue.withCString {
        XCTAssertEqual(sqlite3_bind_text(statement, 6, $0, -1, transient), SQLITE_OK)
      }
      if let correctionSource = record.correctionSource {
        let encoded = String(
          decoding: try JSONEncoder().encode(correctionSource),
          as: UTF8.self
        )
        encoded.withCString {
          XCTAssertEqual(sqlite3_bind_text(statement, 7, $0, -1, transient), SQLITE_OK)
        }
      } else {
        XCTAssertEqual(sqlite3_bind_null(statement, 7), SQLITE_OK)
      }
      XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    var settingStatement: OpaquePointer?
    XCTAssertEqual(
      sqlite3_prepare_v2(
        database,
        "INSERT INTO app_settings (key, value, updated_at) VALUES (?, ?, 1);",
        -1,
        &settingStatement,
        nil
      ),
      SQLITE_OK
    )
    guard let settingStatement else { return }
    defer { sqlite3_finalize(settingStatement) }
    settingKey.rawValue.withCString {
      XCTAssertEqual(
        sqlite3_bind_text(settingStatement, 1, $0, -1, transient),
        SQLITE_OK
      )
    }
    settingValue.withCString {
      XCTAssertEqual(
        sqlite3_bind_text(settingStatement, 2, $0, -1, transient),
        SQLITE_OK
      )
    }
    XCTAssertEqual(sqlite3_step(settingStatement), SQLITE_DONE)
  }

  private func insertLegacyDiagnostic(
    eventCode: String = "legacy.provider.failure",
    message: String,
    metadataJSON: String,
    at databaseURL: URL
  ) throws {
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
    guard let database else { return }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    XCTAssertEqual(
      sqlite3_prepare_v2(
        database,
        """
        INSERT INTO diagnostic_events (
            timestamp, subsystem, level, level_severity, event, message, metadata_json
        ) VALUES (1, 'providers', 'error', 3, ?, ?, ?);
        """,
        -1,
        &statement,
        nil
      ),
      SQLITE_OK
    )
    guard let statement else { return }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    eventCode.withCString {
      XCTAssertEqual(sqlite3_bind_text(statement, 1, $0, -1, transient), SQLITE_OK)
    }
    message.withCString {
      XCTAssertEqual(sqlite3_bind_text(statement, 2, $0, -1, transient), SQLITE_OK)
    }
    metadataJSON.withCString {
      XCTAssertEqual(sqlite3_bind_text(statement, 3, $0, -1, transient), SQLITE_OK)
    }
    XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
  }

  private func insertLegacyExport(
    _ export: ExportMetadata,
    at databaseURL: URL
  ) throws {
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
    guard let database else { return }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    XCTAssertEqual(
      sqlite3_prepare_v2(
        database,
        """
        INSERT INTO export_metadata (
            id, kind, destination_path, item_count, created_at, metadata_json
        ) VALUES (?, ?, ?, ?, ?, ?);
        """,
        -1,
        &statement,
        nil
      ),
      SQLITE_OK
    )
    guard let statement else { return }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let metadataJSON = String(
      decoding: try JSONEncoder().encode(export.metadata),
      as: UTF8.self
    )
    for (index, value) in [
      export.id.uuidString,
      export.kind.rawValue,
      export.destinationPath,
    ].enumerated() {
      value.withCString {
        XCTAssertEqual(
          sqlite3_bind_text(statement, Int32(index + 1), $0, -1, transient),
          SQLITE_OK
        )
      }
    }
    XCTAssertEqual(sqlite3_bind_int64(statement, 4, Int64(export.itemCount)), SQLITE_OK)
    XCTAssertEqual(
      sqlite3_bind_double(statement, 5, export.createdAt.timeIntervalSince1970),
      SQLITE_OK
    )
    metadataJSON.withCString {
      XCTAssertEqual(sqlite3_bind_text(statement, 6, $0, -1, transient), SQLITE_OK)
    }
    XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
  }

  private func enableWALMode(at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to enable WAL for a test fixture.")
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, "PRAGMA journal_mode = WAL;", nil, nil, nil) == SQLITE_OK else {
      throw SQLitePersistenceError.executingSQL("Failed to enable WAL for a test fixture.")
    }
  }

  private func setSchemaVersion(_ version: Int, at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to set a test schema version.")
    }
    defer { sqlite3_close(database) }
    guard
      sqlite3_exec(
        database,
        "PRAGMA user_version = \(version);",
        nil,
        nil,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.executingSQL("Failed to set a test schema version.")
    }
  }

  private func createVersionZeroDatabaseWithDeletedHistoryResidue(
    at databaseURL: URL,
    sentinel: String
  ) throws {
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
    guard let database else { return }
    defer { sqlite3_close(database) }

    let schema = """
      PRAGMA user_version = 0;
      PRAGMA secure_delete = OFF;
      CREATE TABLE history_records (
          id TEXT PRIMARY KEY,
          run_id TEXT,
          workflow_id TEXT,
          workflow_fallback_name TEXT NOT NULL,
          workflow_title_key TEXT,
          final_text TEXT,
          failure_message TEXT,
          timestamp REAL NOT NULL,
          is_stack_related INTEGER NOT NULL,
          outcome TEXT NOT NULL
      );
      """
    XCTAssertEqual(sqlite3_exec(database, schema, nil, nil, nil), SQLITE_OK)

    var statement: OpaquePointer?
    XCTAssertEqual(
      sqlite3_prepare_v2(
        database,
        """
        INSERT INTO history_records (
            id, workflow_fallback_name, final_text, timestamp, is_stack_related, outcome
        ) VALUES (?, 'Deleted v0 workflow', ?, 1, 0, 'completed');
        """,
        -1,
        &statement,
        nil
      ),
      SQLITE_OK
    )
    guard let statement else { return }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    UUID().uuidString.withCString {
      XCTAssertEqual(sqlite3_bind_text(statement, 1, $0, -1, transient), SQLITE_OK)
    }
    sentinel.withCString {
      XCTAssertEqual(sqlite3_bind_text(statement, 2, $0, -1, transient), SQLITE_OK)
    }
    XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    sqlite3_finalize(statement)
    XCTAssertEqual(
      sqlite3_exec(database, "DELETE FROM history_records;", nil, nil, nil),
      SQLITE_OK
    )
  }

  private func createV1HistoryDatabase(at databaseURL: URL, failureMessage: String) throws {
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
    guard let database else { return }
    defer { sqlite3_close(database) }

    let schema = """
      PRAGMA user_version = 1;
      CREATE TABLE history_records (
          id TEXT PRIMARY KEY,
          run_id TEXT,
          workflow_id TEXT,
          workflow_fallback_name TEXT NOT NULL,
          workflow_title_key TEXT,
          final_text TEXT,
          failure_message TEXT,
          timestamp REAL NOT NULL,
          is_stack_related INTEGER NOT NULL,
          outcome TEXT NOT NULL
      );
      """
    XCTAssertEqual(sqlite3_exec(database, schema, nil, nil, nil), SQLITE_OK)

    var statement: OpaquePointer?
    XCTAssertEqual(
      sqlite3_prepare_v2(
        database,
        """
        INSERT INTO history_records (
            id, workflow_fallback_name, failure_message, timestamp, is_stack_related, outcome
        ) VALUES (?, 'Legacy failure', ?, 1, 0, 'failed');
        """,
        -1,
        &statement,
        nil
      ),
      SQLITE_OK
    )
    guard let statement else { return }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    UUID().uuidString.withCString {
      XCTAssertEqual(sqlite3_bind_text(statement, 1, $0, -1, transient), SQLITE_OK)
    }
    failureMessage.withCString {
      XCTAssertEqual(sqlite3_bind_text(statement, 2, $0, -1, transient), SQLITE_OK)
    }
    XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
  }

  private func createV2HistoryDatabase(at databaseURL: URL, recordID: UUID) throws {
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
    guard let database else { return }
    defer { sqlite3_close(database) }

    let schema = """
      PRAGMA user_version = 2;
      CREATE TABLE history_records (
          id TEXT PRIMARY KEY,
          run_id TEXT,
          workflow_id TEXT,
          workflow_fallback_name TEXT NOT NULL,
          workflow_title_key TEXT,
          final_text TEXT,
          failure_message TEXT,
          timestamp REAL NOT NULL,
          is_stack_related INTEGER NOT NULL,
          outcome TEXT NOT NULL
      );
      """
    XCTAssertEqual(sqlite3_exec(database, schema, nil, nil, nil), SQLITE_OK)

    var statement: OpaquePointer?
    XCTAssertEqual(
      sqlite3_prepare_v2(
        database,
        """
        INSERT INTO history_records (
            id, workflow_fallback_name, final_text, timestamp, is_stack_related, outcome
        ) VALUES (?, 'Legacy v2 workflow', 'legacy v2 history', 2, 0, 'completed');
        """,
        -1,
        &statement,
        nil
      ),
      SQLITE_OK
    )
    guard let statement else { return }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    recordID.uuidString.withCString {
      XCTAssertEqual(sqlite3_bind_text(statement, 1, $0, -1, transient), SQLITE_OK)
    }
    XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
  }

  private func simulateInterruptedV3Migration(at databaseURL: URL) throws {
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
    guard let database else { return }
    defer { sqlite3_close(database) }

    XCTAssertEqual(
      sqlite3_exec(
        database,
        "ALTER TABLE history_records ADD COLUMN correction_source_json TEXT;",
        nil,
        nil,
        nil
      ),
      SQLITE_OK
    )
  }

  private func schemaVersion(at databaseURL: URL) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to inspect schema version.")
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement("Failed to inspect schema version.")
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw SQLitePersistenceError.steppingStatement("Failed to inspect schema version.")
    }
    return Int(sqlite3_column_int(statement, 0))
  }

  private func historyColumnNames(at databaseURL: URL) throws -> Set<String> {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to inspect history columns.")
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, "PRAGMA table_info(history_records);", -1, &statement, nil)
        == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement("Failed to inspect history columns.")
    }
    defer { sqlite3_finalize(statement) }

    var names: Set<String> = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let rawName = sqlite3_column_text(statement, 1) else { continue }
      names.insert(String(cString: rawName))
    }
    return names
  }

  private func columnNames(in tableName: String, at databaseURL: URL) throws -> Set<String> {
    let allowedTableNames = Set([
      "history_records",
      "workflow_run_receipts",
      "diagnostic_events",
    ])
    guard allowedTableNames.contains(tableName) else {
      throw SQLitePersistenceError.preparingStatement("Unsupported test table.")
    }
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to inspect table columns.")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "PRAGMA table_info(\(tableName));",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement("Failed to inspect table columns.")
    }
    defer { sqlite3_finalize(statement) }
    var names: Set<String> = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let rawName = sqlite3_column_text(statement, 1) else { continue }
      names.insert(String(cString: rawName))
    }
    return names
  }

  private func rawHistoryValue(
    column: String,
    recordID: UUID,
    at databaseURL: URL
  ) throws -> String? {
    let allowedColumns = Set([
      "workflow_fallback_name",
      "final_text",
      "correction_source_json",
    ])
    guard allowedColumns.contains(column) else {
      throw SQLitePersistenceError.preparingStatement("Unsupported test column.")
    }

    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to inspect protected history.")
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT \(column) FROM history_records WHERE id = ?;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement("Failed to inspect protected history.")
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    recordID.uuidString.withCString {
      XCTAssertEqual(sqlite3_bind_text(statement, 1, $0, -1, transient), SQLITE_OK)
    }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    guard let rawValue = sqlite3_column_text(statement, 0) else { return nil }
    return String(cString: rawValue)
  }

  private func replaceHistoryValue(
    _ value: String,
    column: String,
    recordID: UUID,
    at databaseURL: URL
  ) throws {
    let allowedColumns = Set([
      "workflow_fallback_name",
      "final_text",
      "correction_source_json",
    ])
    guard allowedColumns.contains(column) else {
      throw SQLitePersistenceError.preparingStatement("Unsupported test column.")
    }

    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to open history corruption fixture.")
    }
    defer { sqlite3_close(database) }
    try SQLiteWriterBarrier.registerCapability(on: database)
    try SQLiteSchemaWriterBarrier.catalog.register(on: database)
    try SQLiteSchemaWriterBarrier.memory.register(on: database)

    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "UPDATE history_records SET \(column) = ? WHERE id = ?;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement(
        "Failed to prepare history corruption fixture."
      )
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let valueBinding = value.withCString {
      sqlite3_bind_text(statement, 1, $0, -1, transient)
    }
    let recordIDBinding = recordID.uuidString.withCString {
      sqlite3_bind_text(statement, 2, $0, -1, transient)
    }
    guard valueBinding == SQLITE_OK,
      recordIDBinding == SQLITE_OK,
      sqlite3_step(statement) == SQLITE_DONE,
      sqlite3_changes(database) == 1
    else {
      throw SQLitePersistenceError.executingSQL(
        "Failed to apply history corruption fixture."
      )
    }
  }

  private func rawSettingValue(
    forKey key: AppSettingKey,
    at databaseURL: URL
  ) throws -> String? {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to inspect protected setting.")
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT value FROM app_settings WHERE key = ?;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement("Failed to inspect protected setting.")
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    key.rawValue.withCString {
      XCTAssertEqual(sqlite3_bind_text(statement, 1, $0, -1, transient), SQLITE_OK)
    }
    guard sqlite3_step(statement) == SQLITE_ROW,
      let rawValue = sqlite3_column_text(statement, 0)
    else {
      return nil
    }
    return String(cString: rawValue)
  }

  private func replaceRawSettingValue(
    _ value: String,
    forKey key: AppSettingKey,
    at databaseURL: URL
  ) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to open settings corruption fixture.")
    }
    defer { sqlite3_close(database) }
    try SQLiteWriterBarrier.registerCapability(on: database)
    try SQLiteSchemaWriterBarrier.catalog.register(on: database)
    try SQLiteSchemaWriterBarrier.memory.register(on: database)

    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "UPDATE app_settings SET value = ? WHERE key = ?;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement(
        "Failed to prepare settings corruption fixture."
      )
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let valueBinding = value.withCString {
      sqlite3_bind_text(statement, 1, $0, -1, transient)
    }
    let keyBinding = key.rawValue.withCString {
      sqlite3_bind_text(statement, 2, $0, -1, transient)
    }
    guard valueBinding == SQLITE_OK,
      keyBinding == SQLITE_OK,
      sqlite3_step(statement) == SQLITE_DONE,
      sqlite3_changes(database) == 1
    else {
      throw SQLitePersistenceError.executingSQL(
        "Failed to apply settings corruption fixture."
      )
    }
  }

  private func rawExportValue(
    column: String,
    recordID: UUID,
    at databaseURL: URL
  ) throws -> String? {
    guard ["destination_path", "metadata_json"].contains(column) else {
      throw SQLitePersistenceError.preparingStatement("Unsupported export test column.")
    }
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to inspect protected export.")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT \(column) FROM export_metadata WHERE id = ?;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement("Failed to inspect protected export.")
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    recordID.uuidString.withCString {
      XCTAssertEqual(sqlite3_bind_text(statement, 1, $0, -1, transient), SQLITE_OK)
    }
    guard sqlite3_step(statement) == SQLITE_ROW,
      let rawValue = sqlite3_column_text(statement, 0)
    else {
      return nil
    }
    return String(cString: rawValue)
  }

  private func rawKeyVerificationEnvelope(at databaseURL: URL) throws -> String? {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to inspect key verification data.")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT key_verification FROM local_data_protection WHERE id = 1;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement(
        "Failed to inspect key verification data."
      )
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      let rawValue = sqlite3_column_text(statement, 0)
    else {
      return nil
    }
    return String(cString: rawValue)
  }

  private func cleanupPendingValue(at databaseURL: URL) throws -> Int? {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to inspect cleanup state.")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT cleanup_pending FROM local_data_protection WHERE id = 1;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement("Failed to inspect cleanup state.")
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return Int(sqlite3_column_int(statement, 0))
  }

  private func replaceKeyVerificationEnvelope(
    _ envelope: String,
    at databaseURL: URL
  ) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to tamper key verification data.")
    }
    defer { sqlite3_close(database) }
    try SQLiteWriterBarrier.registerCapability(on: database)
    try SQLiteSchemaWriterBarrier.catalog.register(on: database)
    try SQLiteSchemaWriterBarrier.memory.register(on: database)
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "UPDATE local_data_protection SET key_verification = ? WHERE id = 1;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement(
        "Failed to tamper key verification data."
      )
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    envelope.withCString {
      XCTAssertEqual(sqlite3_bind_text(statement, 1, $0, -1, transient), SQLITE_OK)
    }
    XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
  }

  private func localDataProtectionTableExists(at databaseURL: URL) throws -> Bool {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to inspect protection tables.")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'local_data_protection';",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement("Failed to inspect protection tables.")
    }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_ROW
  }

  private func runReceiptTableExists(at databaseURL: URL) throws -> Bool {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to inspect receipt storage.")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'workflow_run_receipts';",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement("Failed to inspect receipt storage.")
    }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_ROW
  }

  private func runHistoryGenerationTableExists(at databaseURL: URL) throws -> Bool {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to inspect clear protection.")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'run_history_generation';",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement(
        "Failed to inspect clear protection."
      )
    }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_ROW
  }

  private func runHistoryGeneration(at databaseURL: URL) throws -> Int64? {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to inspect clear protection.")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT current_generation FROM run_history_generation WHERE id = 1;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement(
        "Failed to inspect clear protection."
      )
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return sqlite3_column_int64(statement, 0)
  }

  private func rawRunReceiptPayload(runID: UUID, at databaseURL: URL) throws -> String? {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to inspect receipt payload.")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT payload FROM workflow_run_receipts WHERE run_id = ?;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement("Failed to inspect receipt payload.")
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let bindResult = runID.uuidString.withCString {
      sqlite3_bind_text(statement, 1, $0, -1, transient)
    }
    guard bindResult == SQLITE_OK else {
      throw SQLitePersistenceError.bindingValue("Failed to inspect receipt payload.")
    }
    guard sqlite3_step(statement) == SQLITE_ROW,
      let rawValue = sqlite3_column_text(statement, 0)
    else {
      return nil
    }
    return String(cString: rawValue)
  }

  private func replaceRunReceiptPayload(
    _ payload: String,
    runID: UUID,
    at databaseURL: URL
  ) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to open receipt corruption fixture.")
    }
    defer { sqlite3_close(database) }
    try SQLiteWriterBarrier.registerCapability(on: database)
    try SQLiteSchemaWriterBarrier.catalog.register(on: database)
    try SQLiteSchemaWriterBarrier.memory.register(on: database)
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "UPDATE workflow_run_receipts SET payload = ? WHERE run_id = ?;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement(
        "Failed to prepare receipt corruption fixture."
      )
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let payloadBinding = payload.withCString {
      sqlite3_bind_text(statement, 1, $0, -1, transient)
    }
    let runIDBinding = runID.uuidString.withCString {
      sqlite3_bind_text(statement, 2, $0, -1, transient)
    }
    guard payloadBinding == SQLITE_OK,
      runIDBinding == SQLITE_OK,
      sqlite3_step(statement) == SQLITE_DONE,
      sqlite3_changes(database) == 1
    else {
      throw SQLitePersistenceError.executingSQL(
        "Failed to apply receipt corruption fixture."
      )
    }
  }

  private func replaceDiagnosticMetadata(
    _ metadataJSON: String,
    eventCode: String,
    timestamp: Date,
    at databaseURL: URL
  ) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase(
        "Failed to open diagnostic corruption fixture."
      )
    }
    defer { sqlite3_close(database) }
    try SQLiteWriterBarrier.registerCapability(on: database)
    try SQLiteSchemaWriterBarrier.catalog.register(on: database)
    try SQLiteSchemaWriterBarrier.memory.register(on: database)
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "UPDATE diagnostic_events SET metadata_json = ? WHERE event = ? AND timestamp = ?;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement(
        "Failed to prepare diagnostic corruption fixture."
      )
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let metadataBinding = metadataJSON.withCString {
      sqlite3_bind_text(statement, 1, $0, -1, transient)
    }
    let eventBinding = eventCode.withCString {
      sqlite3_bind_text(statement, 2, $0, -1, transient)
    }
    guard metadataBinding == SQLITE_OK,
      eventBinding == SQLITE_OK,
      sqlite3_bind_double(statement, 3, timestamp.timeIntervalSince1970) == SQLITE_OK,
      sqlite3_step(statement) == SQLITE_DONE,
      sqlite3_changes(database) == 1
    else {
      throw SQLitePersistenceError.executingSQL(
        "Failed to apply diagnostic corruption fixture."
      )
    }
  }

  private func removeV11StorageBoundary(at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase(
        "Failed to open the v11 storage boundary fixture."
      )
    }
    defer { sqlite3_close(database) }
    try SQLiteWriterBarrier.registerCapability(on: database)
    try SQLiteSchemaWriterBarrier.catalog.register(on: database)
    try SQLiteSchemaWriterBarrier.memory.register(on: database)
    try removeV11StorageBoundary(on: database)
  }

  private func removeV11StorageBoundary(on database: OpaquePointer?) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        """
        SELECT name
        FROM sqlite_schema
        WHERE type = 'trigger'
          AND (name GLOB 'rill_writer_barrier_v11_*' OR name GLOB 'rill_catalog_v13_*' OR name GLOB 'rill_memory_v14_*' OR name GLOB 'context_source_*')
        ORDER BY name ASC;
        """,
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement(
        "Failed to inspect the v11 writer boundary."
      )
    }
    var triggerNames: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let name = sqlite3_column_text(statement, 0) else {
        sqlite3_finalize(statement)
        throw SQLitePersistenceError.decodingRow(
          "Failed to decode the v11 writer boundary."
        )
      }
      triggerNames.append(String(cString: name))
    }
    sqlite3_finalize(statement)

    for triggerName in triggerNames {
      guard
        !triggerName.isEmpty,
        triggerName.utf8.allSatisfy({
          $0 == 95 || (48...57).contains($0) || (97...122).contains($0)
        }),
        sqlite3_exec(database, "DROP TRIGGER \(triggerName);", nil, nil, nil) == SQLITE_OK
      else {
        throw SQLitePersistenceError.executingSQL(
          "Failed to remove the v11 writer boundary."
        )
      }
    }
    guard
      sqlite3_exec(
        database,
        "DROP TABLE IF EXISTS record_catalog_nodes; DROP TABLE IF EXISTS context_memories; DROP TABLE IF EXISTS context_memory_sources; DROP TABLE IF EXISTS context_memory_exclusions; DROP TABLE IF EXISTS context_memory_control; DROP TABLE rill_authenticated_schema_floor;",
        nil,
        nil,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.executingSQL(
        "Failed to remove the v11 authenticated schema floor."
      )
    }
  }

  private func simulateV4DatabaseByRemovingReceiptStorage(at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to create the v4 migration fixture.")
    }
    defer { sqlite3_close(database) }
    try SQLiteWriterBarrier.registerCapability(on: database)
    try SQLiteSchemaWriterBarrier.catalog.register(on: database)
    try SQLiteSchemaWriterBarrier.memory.register(on: database)
    try removeV11StorageBoundary(on: database)
    guard
      sqlite3_exec(
        database,
        "DROP TABLE workflow_run_receipts; PRAGMA user_version = 4;",
        nil,
        nil,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.executingSQL("Failed to create the v4 migration fixture.")
    }
  }

  private func simulateV8DatabaseByRemovingV11StorageBoundary(at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to create the v8 migration fixture.")
    }
    defer { sqlite3_close(database) }
    try SQLiteWriterBarrier.registerCapability(on: database)
    try SQLiteSchemaWriterBarrier.catalog.register(on: database)
    try SQLiteSchemaWriterBarrier.memory.register(on: database)
    try removeV11StorageBoundary(on: database)
    guard sqlite3_exec(database, "PRAGMA user_version = 8;", nil, nil, nil) == SQLITE_OK else {
      throw SQLitePersistenceError.executingSQL("Failed to create the v8 migration fixture.")
    }
  }

  private func simulateV5DatabaseByRemovingGenerationStorage(at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to create the v5 migration fixture.")
    }
    defer { sqlite3_close(database) }
    try SQLiteWriterBarrier.registerCapability(on: database)
    try SQLiteSchemaWriterBarrier.catalog.register(on: database)
    try SQLiteSchemaWriterBarrier.memory.register(on: database)
    try removeV11StorageBoundary(on: database)
    guard
      sqlite3_exec(
        database,
        "DROP TABLE run_history_generation; PRAGMA user_version = 5;",
        nil,
        nil,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.executingSQL("Failed to create the v5 migration fixture.")
    }
  }

  private func simulateV6DatabaseByRemovingHistoryTrigger(at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to create the v6 migration fixture.")
    }
    defer { sqlite3_close(database) }
    try SQLiteWriterBarrier.registerCapability(on: database)
    try SQLiteSchemaWriterBarrier.catalog.register(on: database)
    try SQLiteSchemaWriterBarrier.memory.register(on: database)
    try removeV11StorageBoundary(on: database)
    let sql = """
      BEGIN IMMEDIATE TRANSACTION;
      CREATE TABLE history_records_v6 (
          id TEXT PRIMARY KEY,
          run_id TEXT,
          workflow_id TEXT,
          workflow_fallback_name TEXT NOT NULL,
          workflow_title_key TEXT,
          final_text TEXT,
          failure_message TEXT,
          timestamp REAL NOT NULL,
          is_stack_related INTEGER NOT NULL,
          outcome TEXT NOT NULL,
          correction_source_json TEXT
      );
      INSERT INTO history_records_v6 (
          id, run_id, workflow_id, workflow_fallback_name, workflow_title_key,
          final_text, failure_message, timestamp, is_stack_related, outcome,
          correction_source_json
      )
      SELECT
          id, run_id, workflow_id, workflow_fallback_name, workflow_title_key,
          final_text, failure_message, timestamp, is_stack_related, outcome,
          correction_source_json
      FROM history_records;
      DROP TABLE history_records;
      ALTER TABLE history_records_v6 RENAME TO history_records;
      CREATE INDEX idx_history_records_timestamp ON history_records (timestamp DESC);
      PRAGMA user_version = 6;
      COMMIT;
      """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      _ = sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
      throw SQLitePersistenceError.executingSQL("Failed to create the v6 migration fixture.")
    }
  }

  private func simulateV7DatabaseWithoutLogicalGeneration(at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to create the v7 migration fixture.")
    }
    defer { sqlite3_close(database) }
    try SQLiteWriterBarrier.registerCapability(on: database)
    try SQLiteSchemaWriterBarrier.catalog.register(on: database)
    try SQLiteSchemaWriterBarrier.memory.register(on: database)
    try removeV11StorageBoundary(on: database)
    let sql = """
      BEGIN IMMEDIATE TRANSACTION;
      CREATE TABLE history_records_v7 (
          id TEXT PRIMARY KEY,
          run_id TEXT,
          workflow_id TEXT,
          workflow_fallback_name TEXT NOT NULL,
          workflow_title_key TEXT,
          final_text TEXT,
          failure_message TEXT,
          timestamp REAL NOT NULL,
          is_stack_related INTEGER NOT NULL,
          outcome TEXT NOT NULL,
          correction_source_json TEXT,
          trigger_kind TEXT
      );
      INSERT INTO history_records_v7
      SELECT id, run_id, workflow_id, workflow_fallback_name, workflow_title_key,
             final_text, failure_message, timestamp, is_stack_related, outcome,
             correction_source_json, trigger_kind
      FROM history_records;
      DROP TABLE history_records;
      ALTER TABLE history_records_v7 RENAME TO history_records;
      CREATE INDEX idx_history_records_timestamp ON history_records (timestamp DESC);

      CREATE TABLE workflow_run_receipts_v7 (
          run_id TEXT PRIMARY KEY,
          timestamp REAL NOT NULL,
          payload TEXT NOT NULL
      );
      INSERT INTO workflow_run_receipts_v7
      SELECT run_id, timestamp, payload FROM workflow_run_receipts;
      DROP TABLE workflow_run_receipts;
      ALTER TABLE workflow_run_receipts_v7 RENAME TO workflow_run_receipts;
      CREATE INDEX idx_workflow_run_receipts_timestamp
      ON workflow_run_receipts (timestamp DESC);

      CREATE TABLE diagnostic_events_v7 (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          timestamp REAL NOT NULL,
          run_id TEXT,
          subsystem TEXT NOT NULL,
          level TEXT NOT NULL,
          level_severity INTEGER NOT NULL,
          event TEXT NOT NULL,
          message TEXT NOT NULL,
          metadata_json TEXT NOT NULL
      );
      INSERT INTO diagnostic_events_v7
      SELECT id, timestamp, run_id, subsystem, level, level_severity,
             event, message, metadata_json
      FROM diagnostic_events;
      DROP TABLE diagnostic_events;
      ALTER TABLE diagnostic_events_v7 RENAME TO diagnostic_events;
      CREATE INDEX idx_diagnostic_events_timestamp
      ON diagnostic_events (timestamp DESC);

      DROP TABLE run_history_generation;
      CREATE TABLE run_history_clear_barrier (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          clear_through REAL NOT NULL
      );
      INSERT INTO run_history_clear_barrier (id, clear_through) VALUES (1, 20);
      PRAGMA user_version = 7;
      COMMIT;
      """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      _ = sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
      throw SQLitePersistenceError.executingSQL("Failed to create the v7 migration fixture.")
    }
  }

  private func persistedDatabaseBytes(
    at databaseURL: URL
  ) throws -> [(name: String, data: Data)] {
    try [
      databaseURL,
      URL(fileURLWithPath: databaseURL.path + "-wal"),
      URL(fileURLWithPath: databaseURL.path + "-shm"),
    ].compactMap { url in
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      return (url.lastPathComponent, try Data(contentsOf: url))
    }
  }
}

private final class BlockingHistorySealProtector: LocalDataProtector, @unchecked Sendable {
  private let base: any LocalDataProtector
  private let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var shouldBlock = true
  private var isUnblocked = false
  private var didBlock = false
  private var blockWaiters: [CheckedContinuation<Void, Never>] = []

  init(base: any LocalDataProtector) {
    self.base = base
  }

  func seal(_ plaintext: Data, context: LocalDataProtectionContext) throws -> String {
    let blocksThisSeal: Bool
    lock.lock()
    blocksThisSeal = shouldBlock && context.namespace == "history_records"
    let waiters: [CheckedContinuation<Void, Never>]
    if blocksThisSeal {
      shouldBlock = false
      didBlock = true
      waiters = blockWaiters
      blockWaiters.removeAll()
    } else {
      waiters = []
    }
    lock.unlock()

    if blocksThisSeal {
      for waiter in waiters {
        waiter.resume()
      }
      release.wait()
    }
    return try base.seal(plaintext, context: context)
  }

  func open(_ envelope: String, context: LocalDataProtectionContext) throws -> Data {
    try base.open(envelope, context: context)
  }

  func waitUntilBlocked() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      guard !didBlock else {
        lock.unlock()
        continuation.resume()
        return
      }
      blockWaiters.append(continuation)
      lock.unlock()
    }
  }

  func unblock() {
    lock.lock()
    guard !isUnblocked else {
      lock.unlock()
      return
    }
    isUnblocked = true
    lock.unlock()
    release.signal()
  }
}

private final class FailingLocalDataProtector: LocalDataProtector, @unchecked Sendable {
  private enum ForcedFailure: Error {
    case sealLimitReached
  }

  private let base: any LocalDataProtector
  private let successfulSealLimit: Int
  private let lock = NSLock()
  private var successfulSealCount = 0

  init(base: any LocalDataProtector, successfulSealLimit: Int) {
    self.base = base
    self.successfulSealLimit = successfulSealLimit
  }

  func seal(_ plaintext: Data, context: LocalDataProtectionContext) throws -> String {
    lock.lock()
    defer { lock.unlock() }
    guard successfulSealCount < successfulSealLimit else {
      throw ForcedFailure.sealLimitReached
    }
    successfulSealCount += 1
    return try base.seal(plaintext, context: context)
  }

  func open(_ envelope: String, context: LocalDataProtectionContext) throws -> Data {
    try base.open(envelope, context: context)
  }
}

extension SQLitePersistenceStore {
  fileprivate init(databaseURL: URL) throws {
    try self.init(
      databaseURL: databaseURL,
      localDataProtector: AESGCMDataProtector(
        key: Data(repeating: 0xA5, count: AESGCMDataProtector.keyByteCount)
      )
    )
  }
}
