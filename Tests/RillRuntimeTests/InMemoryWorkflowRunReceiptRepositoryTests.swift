import Foundation
import XCTest
@testable import RillCore
@testable import RillRuntime

final class InMemoryWorkflowRunReceiptRepositoryTests: XCTestCase {
    func testInsertIsIdempotentAndConflictingTerminalFailsClosed() async throws {
        let repository = InMemoryWorkflowRunReceiptRepository()
        let runID = UUID()
        let receipt = try makeReceipt(runID: runID, timestamp: 10)

        try await repository.insertTerminal(receipt)
        try await repository.insertTerminal(receipt)

        let stored = try await repository.receipts(matching: .init(runID: runID))
        XCTAssertEqual(stored, [receipt])

        let conflicting = try makeReceipt(
            runID: runID,
            timestamp: 10,
            termination: .failed(stage: .recognizing, code: .processing)
        )
        do {
            try await repository.insertTerminal(conflicting)
            XCTFail("Expected a conflicting terminal receipt to fail.")
        } catch {
            XCTAssertEqual(
                error as? WorkflowRunReceiptRepositoryError,
                .conflictingTerminalReceipt(runID: runID)
            )
        }
    }

    func testQueryFiltersSortsLimitsAndDeletesByStrictCutoff() async throws {
        let workflowID = UUID()
        let otherWorkflowID = UUID()
        let older = try makeReceipt(
            workflowID: workflowID,
            trigger: .hotkey,
            timestamp: 10,
            termination: .completed
        )
        let matching = try makeReceipt(
            workflowID: workflowID,
            trigger: .hotkey,
            timestamp: 20,
            termination: .failed(stage: .recognizing, code: .processing)
        )
        let other = try makeReceipt(
            workflowID: otherWorkflowID,
            trigger: .manual,
            timestamp: 30,
            termination: .completed
        )
        let repository = try InMemoryWorkflowRunReceiptRepository(
            receipts: [older, other, matching]
        )

        let filtered = try await repository.receipts(
            matching: WorkflowRunReceiptQuery(
                workflowID: workflowID,
                trigger: .hotkey,
                since: Date(timeIntervalSince1970: 10),
                limit: 1
            )
        )
        XCTAssertEqual(filtered, [matching])

        let failures = try await repository.receipts(
            matching: WorkflowRunReceiptQuery(outcome: .failed)
        )
        XCTAssertEqual(failures, [matching])

        let removedAtStrictBoundary = try await repository.deleteReceipts(
            olderThan: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(removedAtStrictBoundary, 0)

        let removed = try await repository.deleteReceipts(
            olderThan: Date(timeIntervalSince1970: 20)
        )
        XCTAssertEqual(removed, 1)
        let remaining = try await repository.receipts(matching: .all)
        XCTAssertEqual(remaining, [other, matching])

        let deletedThroughBoundary = try await repository.deleteReceipts(
            through: Date(timeIntervalSince1970: 20)
        )
        let afterBoundedClear = try await repository.receipts(matching: .all)
        XCTAssertEqual(deletedThroughBoundary, 1)
        XCTAssertEqual(afterBoundedClear, [other])

        let deletedAllCount = try await repository.deleteAllReceipts()
        let afterDeleteAll = try await repository.receipts(matching: .all)
        XCTAssertEqual(deletedAllCount, 1)
        XCTAssertTrue(afterDeleteAll.isEmpty)
    }

    func testQueryFiltersExactRunIDBatchBeforeApplyingLimit() async throws {
        let selectedOlder = try makeReceipt(timestamp: 10)
        let selectedNewer = try makeReceipt(timestamp: 20)
        let unrelatedNewest = try makeReceipt(timestamp: 30)
        let repository = try InMemoryWorkflowRunReceiptRepository(
            receipts: [selectedOlder, selectedNewer, unrelatedNewest]
        )

        let receipts = try await repository.receipts(
            matching: WorkflowRunReceiptQuery(
                runIDs: [selectedOlder.runID, selectedNewer.runID],
                limit: 2
            )
        )

        XCTAssertEqual(receipts, [selectedNewer, selectedOlder])
    }

    func testLogicalClearRejectsOldTerminalIntentAndAcceptsClockRollback() async throws {
        let repository = InMemoryWorkflowRunReceiptRepository()
        let oldGeneration = try await repository.captureRunHistoryWriteGeneration()
        let transition = try RunHistoryClearTransition(advancing: oldGeneration)
        let removedCount = try await repository.deleteReceipts(
            obsoletedBy: transition,
            preservingLegacyRowsAfter: nil
        )
        XCTAssertEqual(removedCount, 0)

        let oldReceipt = try makeReceipt(timestamp: 10_000)
        do {
            try await repository.insertTerminal(oldReceipt, generation: oldGeneration)
            XCTFail("Expected an old-generation terminal receipt to be rejected.")
        } catch {
            XCTAssertEqual(
                error as? WorkflowRunReceiptRepositoryError,
                .writeObsoletedByClearBarrier(runID: oldReceipt.runID)
            )
        }
        let newGeneration = try await repository.captureRunHistoryWriteGeneration()
        let afterClockRollback = try makeReceipt(timestamp: 19)
        try await repository.insertTerminal(
            afterClockRollback,
            generation: newGeneration
        )

        let stored = try await repository.receipts(matching: .all)
        XCTAssertEqual(stored, [afterClockRollback])
    }

    private func makeReceipt(
        runID: UUID = UUID(),
        workflowID: UUID? = UUID(),
        trigger: WorkflowRunTriggerKind = .manual,
        timestamp: TimeInterval,
        termination: WorkflowRunTermination = .completed
    ) throws -> WorkflowRunReceipt {
        try WorkflowRunReceipt(
            runID: runID,
            workflowID: workflowID,
            trigger: trigger,
            timestamp: Date(timeIntervalSince1970: timestamp),
            duration: .under250ms,
            termination: termination
        )
    }
}
