import Foundation
import VoxTypeCore

public actor InMemoryDiagnosticRepository: DiagnosticRepository {
    private let capacity: Int
    private var storage: [DiagnosticEvent]

    public init(capacity: Int = 200, events: [DiagnosticEvent] = []) {
        self.capacity = capacity
        self.storage = events
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    public func save(_ event: DiagnosticEvent) async throws {
        storage.append(event)
        trimIfNeeded()
    }

    public func events(matching query: DiagnosticQuery) async throws -> [DiagnosticEvent] {
        var events = storage

        if let runID = query.runID {
            events = events.filter { $0.runID == runID }
        }

        if let subsystem = query.subsystem {
            events = events.filter { $0.subsystem == subsystem }
        }

        if let minimumLevel = query.minimumLevel {
            events = events.filter { $0.level.severity >= minimumLevel.severity }
        }

        if let since = query.since {
            events = events.filter { $0.timestamp >= since }
        }

        events.sort { $0.timestamp > $1.timestamp }

        if let limit = query.limit, limit >= 0 {
            events = Array(events.prefix(limit))
        }

        return events
    }

    private func trimIfNeeded() {
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }
}
