import Foundation
import RillCore

public actor InMemoryHistoryRepository: HistoryRepository, HistoryMaintaining {
    private struct StoredRecord: Sendable {
        var record: WorkflowResultRecord
        var generation: RunHistoryWriteGeneration
    }

    private var storage: [StoredRecord]
    private var currentGeneration: RunHistoryWriteGeneration = .initial
    private var lastClearIntentID: UUID?

    public init(records: [WorkflowResultRecord] = []) {
        self.storage = records
            .map(HistoryRecordSanitizer.sanitize)
            .map { StoredRecord(record: $0, generation: .initial) }
            .sorted { $0.record.timestamp > $1.record.timestamp }
    }

    public func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration {
        currentGeneration
    }

    public func save(_ record: WorkflowResultRecord) async throws {
        try await save(record, generation: currentGeneration)
    }

    public func save(
        _ record: WorkflowResultRecord,
        generation: RunHistoryWriteGeneration
    ) async throws {
        let record = HistoryRecordSanitizer.sanitize(record)
        guard generation == currentGeneration else {
            throw HistoryRepositoryError.writeObsoletedByClearBarrier
        }
        storage.append(StoredRecord(record: record, generation: generation))
        storage.sort { $0.record.timestamp > $1.record.timestamp }
    }

    public func records(matching query: HistoryQuery) async throws -> [WorkflowResultRecord] {
        var records = storage.map(\.record)

        if let runID = query.runID {
            records = records.filter { $0.runID == runID }
        }

        if let workflowID = query.workflowID {
            records = records.filter { $0.workflowID == workflowID }
        }

        if let outcome = query.outcome {
            records = records.filter { $0.outcome == outcome }
        }

        if let since = query.since {
            records = records.filter { $0.timestamp >= since }
        }

        if query.recordRelatedOnly == true {
            records = records.filter(\.isRecordRelated)
        }

        if let limit = query.limit, limit >= 0 {
            records = Array(records.prefix(limit))
        }

        return records
    }

    public func deleteRecords(olderThan cutoff: Date) async throws -> Int {
        let originalCount = storage.count
        storage.removeAll { $0.record.timestamp < cutoff }
        return originalCount - storage.count
    }

    public func deleteRecords(through upperBound: Date) async throws -> Int {
        let originalCount = storage.count
        storage.removeAll { $0.record.timestamp <= upperBound }
        return originalCount - storage.count
    }

    public func deleteRecords(
        obsoletedBy transition: RunHistoryClearTransition,
        preservingLegacyRowsAfter legacyUpperBound: Date?
    ) async throws -> Int {
        try validateAndAdvance(transition)
        if let legacyUpperBound {
            for index in storage.indices
            where storage[index].generation < transition.nextGeneration
                && storage[index].record.timestamp > legacyUpperBound {
                storage[index].generation = transition.nextGeneration
            }
        }
        let originalCount = storage.count
        storage.removeAll { $0.generation < transition.nextGeneration }
        return originalCount - storage.count
    }

    public func deleteAllRecords() async throws -> Int {
        let removedCount = storage.count
        storage.removeAll(keepingCapacity: false)
        return removedCount
    }

    private func validateAndAdvance(_ transition: RunHistoryClearTransition) throws {
        if currentGeneration == transition.nextGeneration,
           lastClearIntentID == transition.intentID {
            return
        }
        guard currentGeneration == transition.previousGeneration else {
            throw RunHistoryGenerationError.clearTransitionConflict
        }
        currentGeneration = transition.nextGeneration
        lastClearIntentID = transition.intentID
    }
}
