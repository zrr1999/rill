import Foundation
import VoxTypeCore

public actor DiagnosticsRecorder {
    private let capacity: Int
    private var events: [DiagnosticEvent] = []
    private let eventBus: EventBus?
    private let repository: (any DiagnosticRepository)?

    public init(
        capacity: Int = 200,
        eventBus: EventBus? = nil,
        repository: (any DiagnosticRepository)? = nil
    ) {
        self.capacity = capacity
        self.eventBus = eventBus
        self.repository = repository
    }

    public func record(_ event: DiagnosticEvent) async {
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        if let repository {
            do {
                try await repository.save(event)
            } catch {
                let failureEvent = DiagnosticEvent(
                    runID: event.runID,
                    subsystem: .session,
                    level: .error,
                    event: "diagnostics.repository.save.failed",
                    message: error.localizedDescription,
                    metadata: ["event": event.event]
                )
                events.append(failureEvent)
                if events.count > capacity {
                    events.removeFirst(events.count - capacity)
                }
                if let eventBus {
                    await eventBus.publish(.diagnostic(failureEvent))
                }
            }
        }
        if let eventBus {
            await eventBus.publish(.diagnostic(event))
        }
    }

    public func snapshot() -> [DiagnosticEvent] {
        events
    }

    public func snapshot(matching query: DiagnosticQuery) -> [DiagnosticEvent] {
        var filtered = events

        if let runID = query.runID {
            filtered = filtered.filter { $0.runID == runID }
        }

        if let subsystem = query.subsystem {
            filtered = filtered.filter { $0.subsystem == subsystem }
        }

        if let minimumLevel = query.minimumLevel {
            filtered = filtered.filter { $0.level.severity >= minimumLevel.severity }
        }

        if let since = query.since {
            filtered = filtered.filter { $0.timestamp >= since }
        }

        filtered.sort { $0.timestamp > $1.timestamp }

        if let limit = query.limit, limit >= 0 {
            filtered = Array(filtered.prefix(limit))
        }

        return filtered
    }
}
