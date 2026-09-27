import Foundation
import RillCore

public actor DiagnosticsRecorder: DiagnosticHistoryMaintaining {
    private struct CachedEvent: Sendable {
        var event: DiagnosticEvent
        var generation: RunHistoryWriteGeneration
    }

    private let capacity: Int
    private var events: [CachedEvent] = []
    private var currentGeneration: RunHistoryWriteGeneration = .initial
    private var lastClearIntentID: UUID?
    private let eventBus: EventBus?
    private let repository: (any DiagnosticRepository & DiagnosticHistoryMaintaining)?

    public init(
        capacity: Int = 200,
        eventBus: EventBus? = nil,
        repository: (any DiagnosticRepository & DiagnosticHistoryMaintaining)? = nil
    ) {
        self.capacity = capacity
        self.eventBus = eventBus
        self.repository = repository
    }

    public func record(_ event: DiagnosticEvent) async {
        let generation: RunHistoryWriteGeneration
        do {
            generation = try await captureRunHistoryWriteGeneration()
        } catch {
            return
        }
        await record(event, generation: generation)
    }

    func record(
        _ event: DiagnosticEvent,
        generation: RunHistoryWriteGeneration
    ) async {
        let sanitizedEvent = DiagnosticEventSanitizer.sanitize(event)
        if generation > currentGeneration {
            currentGeneration = generation
            lastClearIntentID = nil
        }
        guard generation == currentGeneration else { return }
        var repositoryFailureEvent: DiagnosticEvent?
        if let repository {
            do {
                try await repository.save(sanitizedEvent, generation: generation)
            } catch DiagnosticRepositoryError.writeObsoletedByClearBarrier {
                return
            } catch {
                guard generation == currentGeneration else { return }
                repositoryFailureEvent = DiagnosticEventSanitizer.sanitize(
                    DiagnosticEvent(
                        runID: sanitizedEvent.runID,
                        subsystem: .session,
                        level: .error,
                        event: .diagnosticsRepositorySaveFailed,
                        message: "The diagnostic repository rejected an event.",
                        metadata: ["event": sanitizedEvent.event]
                    )
                )
            }
        }
        guard generation == currentGeneration else { return }
        appendToCache(sanitizedEvent, generation: generation)
        if let repositoryFailureEvent {
            appendToCache(repositoryFailureEvent, generation: generation)
            if let eventBus {
                await eventBus.publish(.diagnostic(repositoryFailureEvent))
            }
        }
        guard generation == currentGeneration else { return }
        if let eventBus {
            await eventBus.publish(.diagnostic(sanitizedEvent))
        }
    }

    public func snapshot() -> [DiagnosticEvent] {
        events.map(\.event)
    }

    public func snapshot(matching query: DiagnosticQuery) -> [DiagnosticEvent] {
        var filtered = events.map(\.event)

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

    public func deleteEvents(olderThan cutoff: Date) async throws -> Int {
        let removedCount: Int
        if let repository {
            removedCount = try await repository.deleteEvents(olderThan: cutoff)
        } else {
            removedCount = events.count(where: { $0.event.timestamp < cutoff })
        }
        events.removeAll { $0.event.timestamp < cutoff }
        return removedCount
    }

    public func deleteEvents(
        obsoletedBy transition: RunHistoryClearTransition,
        preservingLegacyRowsAfter legacyUpperBound: Date?
    ) async throws -> Int {
        try validateAndAdvance(transition)
        if let legacyUpperBound {
            for index in events.indices
            where events[index].generation < transition.nextGeneration
                && events[index].event.timestamp > legacyUpperBound
            {
                events[index].generation = transition.nextGeneration
            }
        }
        let cachedRemovedCount = events.count(where: {
            $0.generation < transition.nextGeneration
        })
        events.removeAll { $0.generation < transition.nextGeneration }
        guard let repository else { return cachedRemovedCount }
        return try await repository.deleteEvents(
            obsoletedBy: transition,
            preservingLegacyRowsAfter: legacyUpperBound
        )
    }

    public func deleteAllEvents() async throws -> Int {
        let removedCount: Int
        if let repository {
            removedCount = try await repository.deleteAllEvents()
        } else {
            removedCount = events.count
        }
        events.removeAll(keepingCapacity: false)
        return removedCount
    }

    public func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration {
        if let repository {
            return try await repository.captureRunHistoryWriteGeneration()
        }
        return currentGeneration
    }

    private func appendToCache(
        _ event: DiagnosticEvent,
        generation: RunHistoryWriteGeneration
    ) {
        events.append(CachedEvent(event: event, generation: generation))
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    private func validateAndAdvance(_ transition: RunHistoryClearTransition) throws {
        if currentGeneration == transition.nextGeneration,
            lastClearIntentID == transition.intentID
        {
            return
        }
        if events.isEmpty, currentGeneration < transition.previousGeneration {
            currentGeneration = transition.previousGeneration
            lastClearIntentID = nil
        }
        guard currentGeneration == transition.previousGeneration else {
            throw RunHistoryGenerationError.clearTransitionConflict
        }
        currentGeneration = transition.nextGeneration
        lastClearIntentID = transition.intentID
    }
}

extension DiagnosticsRecorder: DiagnosticRecording {}
