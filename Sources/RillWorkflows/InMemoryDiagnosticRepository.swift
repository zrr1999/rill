import Foundation
import RillCore

public actor InMemoryDiagnosticRepository: DiagnosticRepository, DiagnosticHistoryMaintaining {
    private struct StoredEvent: Sendable {
        var event: DiagnosticEvent
        var generation: RunHistoryWriteGeneration
    }

    private let capacity: Int
    private var storage: [StoredEvent]
    private var currentGeneration: RunHistoryWriteGeneration = .initial
    private var lastClearIntentID: UUID?

    public init(capacity: Int = 200, events: [DiagnosticEvent] = []) {
        self.capacity = capacity
        self.storage = events.map {
            StoredEvent(
                event: DiagnosticEventSanitizer.sanitize($0),
                generation: .initial
            )
        }
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    public func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration {
        currentGeneration
    }

    public func save(_ event: DiagnosticEvent) async throws {
        try await save(event, generation: currentGeneration)
    }

    public func save(
        _ event: DiagnosticEvent,
        generation: RunHistoryWriteGeneration
    ) async throws {
        let event = DiagnosticEventSanitizer.sanitize(event)
        guard generation == currentGeneration else {
            throw DiagnosticRepositoryError.writeObsoletedByClearBarrier
        }
        storage.append(StoredEvent(event: event, generation: generation))
        trimIfNeeded()
    }

    public func events(matching query: DiagnosticQuery) async throws -> [DiagnosticEvent] {
        var events = storage.map(\.event)

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

    public func deleteEvents(olderThan cutoff: Date) async throws -> Int {
        let originalCount = storage.count
        storage.removeAll { $0.event.timestamp < cutoff }
        return originalCount - storage.count
    }

    public func deleteEvents(through upperBound: Date) async throws -> Int {
        let originalCount = storage.count
        storage.removeAll { $0.event.timestamp <= upperBound }
        return originalCount - storage.count
    }

    public func deleteEvents(
        obsoletedBy transition: RunHistoryClearTransition,
        preservingLegacyRowsAfter legacyUpperBound: Date?
    ) async throws -> Int {
        try validateAndAdvance(transition)
        if let legacyUpperBound {
            for index in storage.indices
            where storage[index].generation < transition.nextGeneration
                && storage[index].event.timestamp > legacyUpperBound {
                storage[index].generation = transition.nextGeneration
            }
        }
        let originalCount = storage.count
        storage.removeAll { $0.generation < transition.nextGeneration }
        return originalCount - storage.count
    }

    public func deleteAllEvents() async throws -> Int {
        let removedCount = storage.count
        storage.removeAll(keepingCapacity: false)
        return removedCount
    }

    private func trimIfNeeded() {
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
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
