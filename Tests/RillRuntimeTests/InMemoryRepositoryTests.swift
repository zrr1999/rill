import Foundation
import XCTest
@testable import RillCore
@testable import RillRuntime

final class InMemoryRepositoryTests: XCTestCase {
    func testHistoryRepositorySanitizesFailureMessagesAtItsBoundary() async throws {
        let unsafeMessage = "provider response body contains private transcript"
        let repository = InMemoryHistoryRepository()
        try await repository.save(
            HistoryRecord(
                workflow: WorkflowPresentation(fallbackName: "Unsafe failure"),
                failureMessage: unsafeMessage,
                outcome: .failed
            )
        )

        let records = try await repository.records(matching: .all)

        XCTAssertEqual(records.first?.failureMessage, HistoryFailureSanitizer.genericMessage)
        XCTAssertFalse(records.first?.failureMessage?.contains("private transcript") == true)
    }

    func testHistoryRepositoryFiltersByWorkflowAndLimit() async throws {
        let workflowID = UUID()
        let otherWorkflowID = UUID()
        let repository = InMemoryHistoryRepository(
            records: [
                HistoryRecord(
                    runID: UUID(),
                    workflowID: workflowID,
                    workflow: WorkflowPresentation(fallbackName: "Primary"),
                    finalText: "first",
                    timestamp: Date(timeIntervalSince1970: 10),
                    outcome: .completed
                ),
                HistoryRecord(
                    runID: UUID(),
                    workflowID: workflowID,
                    workflow: WorkflowPresentation(fallbackName: "Primary"),
                    finalText: "second",
                    timestamp: Date(timeIntervalSince1970: 20),
                    outcome: .completed
                ),
                HistoryRecord(
                    runID: UUID(),
                    workflowID: otherWorkflowID,
                    workflow: WorkflowPresentation(fallbackName: "Other"),
                    finalText: "other",
                    timestamp: Date(timeIntervalSince1970: 30),
                    outcome: .failed
                ),
            ]
        )

        let records = try await repository.records(matching: HistoryQuery(workflowID: workflowID, limit: 1))

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.workflowID, workflowID)
        XCTAssertEqual(records.first?.finalText, "second")
    }

    func testHistoryDeletionUsesStrictCutoffAndReturnsActualCounts() async throws {
        let cutoff = Date(timeIntervalSince1970: 20)
        let repository = InMemoryHistoryRepository(
            records: [
                historyRecord(text: "older", timestamp: 10),
                historyRecord(text: "boundary", timestamp: 20),
                historyRecord(text: "newer", timestamp: 30),
            ]
        )

        let prunedCount = try await repository.deleteRecords(olderThan: cutoff)
        let afterPrune = try await repository.records(matching: .all)
        let repeatedPruneCount = try await repository.deleteRecords(olderThan: cutoff)
        let deletedThroughBoundary = try await repository.deleteRecords(through: cutoff)
        let afterBoundedClear = try await repository.records(matching: .all)
        let clearedCount = try await repository.deleteAllRecords()
        let repeatedClearCount = try await repository.deleteAllRecords()

        XCTAssertEqual(prunedCount, 1)
        XCTAssertEqual(afterPrune.map(\.finalText), ["newer", "boundary"])
        XCTAssertEqual(repeatedPruneCount, 0)
        XCTAssertEqual(deletedThroughBoundary, 1)
        XCTAssertEqual(afterBoundedClear.map(\.finalText), ["newer"])
        XCTAssertEqual(clearedCount, 1)
        XCTAssertEqual(repeatedClearCount, 0)
        let finalRecords = try await repository.records(matching: .all)
        XCTAssertTrue(finalRecords.isEmpty)
    }

    func testHistoryLogicalClearRejectsOldIntentAndAcceptsNewIntentAfterClockRollback() async throws {
        let repository = InMemoryHistoryRepository()
        let oldGeneration = try await repository.captureRunHistoryWriteGeneration()
        let transition = try RunHistoryClearTransition(advancing: oldGeneration)
        let removedCount = try await repository.deleteRecords(
            obsoletedBy: transition,
            preservingLegacyRowsAfter: nil
        )
        XCTAssertEqual(removedCount, 0)

        do {
            try await repository.save(
                historyRecord(text: "late", timestamp: 10_000),
                generation: oldGeneration
            )
            XCTFail("Expected an old-generation history write to be rejected.")
        } catch {
            XCTAssertEqual(
                error as? HistoryRepositoryError,
                .writeObsoletedByClearBarrier
            )
        }
        let newGeneration = try await repository.captureRunHistoryWriteGeneration()
        let afterClockRollback = historyRecord(text: "new intent", timestamp: 19)
        try await repository.save(afterClockRollback, generation: newGeneration)

        let stored = try await repository.records(matching: .all)
        XCTAssertEqual(stored, [afterClockRollback])
    }

    func testDiagnosticRepositoryFiltersByRunAndMinimumLevel() async throws {
        let runID = UUID()
        let repository = InMemoryDiagnosticRepository(
            events: [
                DiagnosticEvent(
                    timestamp: Date(timeIntervalSince1970: 10),
                    runID: runID,
                    subsystem: .session,
                    level: .debug,
                    event: "session.debug",
                    message: "debug"
                ),
                DiagnosticEvent(
                    timestamp: Date(timeIntervalSince1970: 20),
                    runID: runID,
                    subsystem: .session,
                    level: .error,
                    event: "session.error",
                    message: "error"
                ),
                DiagnosticEvent(
                    timestamp: Date(timeIntervalSince1970: 30),
                    runID: UUID(),
                    subsystem: .providers,
                    level: .warning,
                    event: "providers.warning",
                    message: "warning"
                ),
            ]
        )

        let events = try await repository.events(
            matching: DiagnosticQuery(runID: runID, minimumLevel: .warning)
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.event, "session.error")
    }

    func testDiagnosticDeletionUsesStrictCutoffAndReturnsActualCounts() async throws {
        let cutoff = Date(timeIntervalSince1970: 20)
        let repository = InMemoryDiagnosticRepository(
            events: [
                diagnosticEvent(name: "older", timestamp: 10),
                diagnosticEvent(name: "boundary", timestamp: 20),
                diagnosticEvent(name: "newer", timestamp: 30),
            ]
        )

        let prunedCount = try await repository.deleteEvents(olderThan: cutoff)
        let afterPrune = try await repository.events(matching: DiagnosticQuery())
        let repeatedPruneCount = try await repository.deleteEvents(olderThan: cutoff)
        let deletedThroughBoundary = try await repository.deleteEvents(through: cutoff)
        let afterBoundedClear = try await repository.events(matching: DiagnosticQuery())
        let clearedCount = try await repository.deleteAllEvents()
        let repeatedClearCount = try await repository.deleteAllEvents()

        XCTAssertEqual(prunedCount, 1)
        XCTAssertEqual(afterPrune.map(\.event), ["diagnostic.newer", "diagnostic.boundary"])
        XCTAssertEqual(repeatedPruneCount, 0)
        XCTAssertEqual(deletedThroughBoundary, 1)
        XCTAssertEqual(afterBoundedClear.map(\.event), ["diagnostic.newer"])
        XCTAssertEqual(clearedCount, 1)
        XCTAssertEqual(repeatedClearCount, 0)
    }

    func testDiagnosticLogicalClearRejectsOldIntentAndAcceptsNewIntentAfterClockRollback() async throws {
        let repository = InMemoryDiagnosticRepository()
        let oldGeneration = try await repository.captureRunHistoryWriteGeneration()
        let transition = try RunHistoryClearTransition(advancing: oldGeneration)
        let removedCount = try await repository.deleteEvents(
            obsoletedBy: transition,
            preservingLegacyRowsAfter: nil
        )
        XCTAssertEqual(removedCount, 0)

        do {
            try await repository.save(
                diagnosticEvent(name: "late", timestamp: 10_000),
                generation: oldGeneration
            )
            XCTFail("Expected an old-generation diagnostic write to be rejected.")
        } catch {
            XCTAssertEqual(
                error as? DiagnosticRepositoryError,
                .writeObsoletedByClearBarrier
            )
        }
        let newGeneration = try await repository.captureRunHistoryWriteGeneration()
        let afterClockRollback = diagnosticEvent(name: "new-intent", timestamp: 19)
        try await repository.save(afterClockRollback, generation: newGeneration)

        let stored = try await repository.events(matching: .init())
        XCTAssertEqual(stored, [DiagnosticEventSanitizer.sanitize(afterClockRollback)])
    }

    private func historyRecord(text: String, timestamp: TimeInterval) -> HistoryRecord {
        HistoryRecord(
            workflow: WorkflowPresentation(fallbackName: "History"),
            finalText: text,
            timestamp: Date(timeIntervalSince1970: timestamp),
            outcome: .completed
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
}
