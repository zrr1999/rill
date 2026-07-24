import XCTest
@testable import RillCore
@testable import RillUI

final class HistoryTimelineEntryTests: XCTestCase {
    func testAllRunsUsesReceiptTimelineAndIncludesReceiptOnlyOperations() throws {
        let voiceRunID = UUID()
        let stackRunID = UUID()
        let record = makeRecord(
            runID: voiceRunID,
            timestamp: Date(timeIntervalSince1970: 10),
            outcome: .completed
        )
        let voiceReceipt = try makeReceipt(
            runID: voiceRunID,
            trigger: .hotkey,
            timestamp: Date(timeIntervalSince1970: 11),
            termination: .completed
        )
        let stackReceipt = try makeReceipt(
            runID: stackRunID,
            trigger: .stackDelivery,
            timestamp: Date(timeIntervalSince1970: 12),
            termination: .skipped(reason: .itemMissing)
        )

        let entries = HistoryTimelineBuilder.allRuns(
            records: [record],
            receipts: [voiceReceipt, stackReceipt]
        )

        XCTAssertEqual(entries.map(\.id), [stackRunID, voiceRunID])
        XCTAssertNil(entries[0].record)
        XCTAssertEqual(entries[0].status, .skipped)
        XCTAssertEqual(entries[1].record, record)
    }

    func testReceiptTerminationOverridesLegacyHistoryOutcome() throws {
        let runID = UUID()
        let record = makeRecord(runID: runID, outcome: .completed)
        let receipt = try makeReceipt(
            runID: runID,
            trigger: .clipboardReplay,
            termination: .partiallyCompleted(code: .processing)
        )

        let entry = try XCTUnwrap(
            HistoryTimelineBuilder.allRuns(records: [record], receipts: [receipt]).first
        )

        XCTAssertEqual(entry.status, .partiallyCompleted)
    }

    func testResultsNeverIntroducesReceiptOnlyRows() throws {
        let resultRunID = UUID()
        let receiptOnlyRunID = UUID()
        let record = makeRecord(runID: resultRunID, outcome: .completed)
        let resultReceipt = try makeReceipt(
            runID: resultRunID,
            trigger: .manual,
            termination: .completed
        )
        let receiptOnly = try makeReceipt(
            runID: receiptOnlyRunID,
            trigger: .clipboardUse,
            termination: .completed
        )

        let entries = HistoryTimelineBuilder.results(
            records: [record],
            receiptsByRunID: [
                resultRunID: resultReceipt,
                receiptOnlyRunID: receiptOnly,
            ]
        )

        XCTAssertEqual(entries.map(\.id), [resultRunID])
        XCTAssertEqual(entries.first?.receipt, resultReceipt)
    }

    func testClipboardAndStackReceiptsCannotExposeMisclassifiedRecordBodies() throws {
        let contentFreeTriggers: [WorkflowRunTriggerKind] = [
            .clipboardGroupEvent,
            .stackDelivery,
            .clipboardUse,
            .clipboardReplay,
        ]
        for (index, trigger) in contentFreeTriggers.enumerated() {
            let runID = UUID()
            let record = makeRecord(
                runID: runID,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                outcome: .completed
            )
            let receipt = try makeReceipt(
                runID: runID,
                trigger: trigger,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index + 10)),
                termination: .completed
            )

            let allRuns = HistoryTimelineBuilder.allRuns(
                records: [record],
                receipts: [receipt]
            )
            let results = HistoryTimelineBuilder.results(
                records: [record],
                receiptsByRunID: [runID: receipt]
            )

            XCTAssertEqual(allRuns.count, 1, "Missing content-free row for \(trigger)")
            XCTAssertNil(allRuns.first?.record, "Leaked record body for \(trigger)")
            XCTAssertTrue(results.isEmpty, "Leaked clipboard result for \(trigger)")
        }
    }

    func testCaptureReceiptStillJoinsVoiceRecordAndAppearsInResults() throws {
        let runID = UUID()
        let record = makeRecord(runID: runID, outcome: .completed)
        let receipt = try makeReceipt(
            runID: runID,
            trigger: .failedAudioRecovery,
            termination: .completed
        )

        let allRuns = HistoryTimelineBuilder.allRuns(
            records: [record],
            receipts: [receipt]
        )
        let results = HistoryTimelineBuilder.results(
            records: [record],
            receiptsByRunID: [runID: receipt]
        )

        XCTAssertEqual(allRuns.first?.record, record)
        XCTAssertEqual(results.first?.record, record)
    }

    func testDuplicateLegacyRecordsForOneRunProduceOneStableTimelineEntry() {
        let runID = UUID()
        let older = makeRecord(
            runID: runID,
            timestamp: Date(timeIntervalSince1970: 10),
            outcome: .failed
        )
        let newer = makeRecord(
            runID: runID,
            timestamp: Date(timeIntervalSince1970: 20),
            outcome: .completed
        )

        let entries = HistoryTimelineBuilder.allRuns(
            records: [older, newer],
            receipts: []
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, runID)
        XCTAssertEqual(entries.first?.record, newer)
        XCTAssertEqual(entries.first?.status, .completed)
    }

    func testReceiptLeftJoinSelectsNewestDuplicateRecord() throws {
        let runID = UUID()
        let older = makeRecord(
            runID: runID,
            timestamp: Date(timeIntervalSince1970: 10),
            outcome: .failed
        )
        let newer = makeRecord(
            runID: runID,
            timestamp: Date(timeIntervalSince1970: 20),
            outcome: .completed
        )
        let receipt = try makeReceipt(
            runID: runID,
            trigger: .manual,
            timestamp: Date(timeIntervalSince1970: 30),
            termination: .completed
        )

        let entries = HistoryTimelineBuilder.allRuns(
            records: [newer, older],
            receipts: [receipt]
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, runID)
        XCTAssertEqual(entries.first?.record, newer)
    }

    private func makeRecord(
        runID: UUID,
        timestamp: Date = Date(timeIntervalSince1970: 10),
        outcome: HistoryOutcome
    ) -> HistoryRecord {
        HistoryRecord(
            runID: runID,
            workflow: WorkflowPresentation(fallbackName: "Dictation"),
            finalText: outcome == .completed ? "result" : nil,
            timestamp: timestamp,
            outcome: outcome
        )
    }

    private func makeReceipt(
        runID: UUID,
        trigger: WorkflowRunTriggerKind,
        timestamp: Date = Date(timeIntervalSince1970: 11),
        termination: WorkflowRunTermination
    ) throws -> WorkflowRunReceipt {
        try WorkflowRunReceipt(
            runID: runID,
            workflowID: nil,
            trigger: trigger,
            timestamp: timestamp,
            duration: .under250ms,
            termination: termination
        )
    }
}
