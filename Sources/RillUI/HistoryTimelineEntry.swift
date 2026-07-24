import Foundation
import RillCore

enum HistoryTimelineStatus: Sendable, Equatable {
    case completed
    case partiallyCompleted
    case failed
    case cancelled
    case skipped

    init(
        receipt: WorkflowRunReceipt?,
        record: HistoryRecord?,
        recordMetadata: RunHistoryRecordMetadata? = nil
    ) {
        if let receipt {
            switch receipt.termination {
            case .completed:
                self = .completed
            case .partiallyCompleted:
                self = .partiallyCompleted
            case .failed:
                self = .failed
            case .cancelled:
                self = .cancelled
            case .skipped:
                self = .skipped
            }
        } else if (record?.outcome ?? recordMetadata?.outcome) == .completed {
            self = .completed
        } else {
            self = .failed
        }
    }
}

struct HistoryTimelineEntry: Identifiable, Sendable {
    let id: UUID
    let record: HistoryRecord?
    let recordMetadata: RunHistoryRecordMetadata?
    let receipt: WorkflowRunReceipt?

    init(
        id: UUID,
        record: HistoryRecord?,
        receipt: WorkflowRunReceipt?,
        recordMetadata: RunHistoryRecordMetadata? = nil
    ) {
        self.id = id
        self.record = record
        self.recordMetadata = recordMetadata
        self.receipt = receipt
    }

    init(_ entry: RunHistoryEntry) {
        id = entry.id
        record = entry.record
        recordMetadata = entry.recordMetadata
        receipt = entry.receipt
    }

    var timestamp: Date {
        receipt?.timestamp ?? record?.timestamp ?? recordMetadata?.timestamp ?? .distantPast
    }

    var status: HistoryTimelineStatus {
        HistoryTimelineStatus(
            receipt: receipt,
            record: record,
            recordMetadata: recordMetadata
        )
    }

    var workflowID: UUID? {
        receipt?.workflowID ?? record?.workflowID ?? recordMetadata?.workflowID
    }

    var runID: UUID? {
        receipt?.runID ?? record?.runID ?? recordMetadata?.runID
    }

    var isStackRelated: Bool {
        record?.isStackRelated == true || recordMetadata?.isStackRelated == true
    }

    var hasProtectedPreview: Bool {
        let authoritativeTrigger = receipt?.trigger ?? recordMetadata?.trigger
        return authoritativeTrigger?.isVoiceCapture == true
            && recordMetadata?.hasNonemptyFinalText == true
            && record == nil
    }
}

enum HistoryTimelineBuilder {
    /// Uses durable receipts as the primary timeline and left-joins any richer
    /// history record. Legacy records without a receipt remain visible.
    static func allRuns(
        records: [HistoryRecord],
        receipts: [WorkflowRunReceipt]
    ) -> [HistoryTimelineEntry] {
        let records = deduplicatedRecords(records)
        let recordsByRunID = Dictionary(
            records.compactMap { record in
                record.runID.map { ($0, record) }
            },
            uniquingKeysWith: { existing, _ in existing }
        )
        let receiptRunIDs = Set(receipts.map(\.runID))
        var entries = receipts.map { receipt in
            HistoryTimelineEntry(
                id: receipt.runID,
                record: receipt.trigger.isVoiceCapture
                    ? recordsByRunID[receipt.runID]
                    : nil,
                receipt: receipt
            )
        }
        entries.append(contentsOf: records.compactMap { record in
            if let runID = record.runID, receiptRunIDs.contains(runID) {
                return nil
            }
            return HistoryTimelineEntry(
                id: record.runID ?? record.id,
                record: record,
                receipt: nil
            )
        })
        return sorted(entries)
    }

    /// Results remain a body-bearing voice view. A matching receipt enriches
    /// status/details but cannot introduce a receipt-only result row.
    static func results(
        records: [HistoryRecord],
        receiptsByRunID: [UUID: WorkflowRunReceipt]
    ) -> [HistoryTimelineEntry] {
        sorted(deduplicatedRecords(records).compactMap { record in
            let receipt = record.runID.flatMap { receiptsByRunID[$0] }
            if let receipt, !receipt.trigger.isVoiceCapture {
                return nil
            }
            return HistoryTimelineEntry(
                id: record.runID ?? record.id,
                record: record,
                receipt: receipt
            )
        })
    }

    private static func sorted(
        _ entries: [HistoryTimelineEntry]
    ) -> [HistoryTimelineEntry] {
        entries.sorted {
            if $0.timestamp == $1.timestamp {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.timestamp > $1.timestamp
        }
    }

    /// A run has one terminal row. If legacy/event replay produced multiple
    /// HistoryRecords for the same run ID, retain the newest record with a
    /// deterministic ID tie-breaker. Records without a run ID remain distinct.
    private static func deduplicatedRecords(
        _ records: [HistoryRecord]
    ) -> [HistoryRecord] {
        var recordsByRunID: [UUID: HistoryRecord] = [:]
        var recordsWithoutRunID: [HistoryRecord] = []
        for record in records {
            guard let runID = record.runID else {
                recordsWithoutRunID.append(record)
                continue
            }
            guard let existing = recordsByRunID[runID] else {
                recordsByRunID[runID] = record
                continue
            }
            if record.timestamp > existing.timestamp
                || (record.timestamp == existing.timestamp
                    && record.id.uuidString < existing.id.uuidString)
            {
                recordsByRunID[runID] = record
            }
        }
        return Array(recordsByRunID.values) + recordsWithoutRunID
    }
}
