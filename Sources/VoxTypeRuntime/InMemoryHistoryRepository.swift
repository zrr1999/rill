import Foundation
import VoxTypeCore

public actor InMemoryHistoryRepository: HistoryRepository {
    private var storage: [HistoryRecord]

    public init(records: [HistoryRecord] = []) {
        self.storage = records.sorted { $0.timestamp > $1.timestamp }
    }

    public func save(_ record: HistoryRecord) async throws {
        storage.append(record)
        storage.sort { $0.timestamp > $1.timestamp }
    }

    public func records(matching query: HistoryQuery) async throws -> [HistoryRecord] {
        var records = storage

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

        if query.stackRelatedOnly == true {
            records = records.filter(\.isStackRelated)
        }

        if let limit = query.limit, limit >= 0 {
            records = Array(records.prefix(limit))
        }

        return records
    }
}
