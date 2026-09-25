
@testable import RillCore
@testable import RillWorkflows
import XCTest

private actor DiagnosticPrivacyRepository: DiagnosticRepository, DiagnosticHistoryMaintaining {
    func deleteEvents(olderThan cutoff: Date) async throws -> Int {
        XCTFail("This recording test must not perform history maintenance.")
        throw RunHistoryGenerationError.unsupported
    }

    func deleteAllEvents() async throws -> Int {
        XCTFail("This recording test must not perform history maintenance.")
        throw RunHistoryGenerationError.unsupported
    }

    func deleteEvents(obsoletedBy transition: RunHistoryClearTransition, preservingLegacyRowsAfter legacyUpperBound: Date?) async throws -> Int {
        XCTFail("This recording test must not perform history maintenance.")
        throw RunHistoryGenerationError.unsupported
    }

    func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration { .initial }
    func save(_ value: DiagnosticEvent, generation: RunHistoryWriteGeneration) async throws {
        guard generation == .initial else { throw RunHistoryGenerationError.unsupported }
        try await (self as any DiagnosticRepository).save(value)
    }

    private var savedEvents: [DiagnosticEvent] = []

    func save(_ event: DiagnosticEvent) async throws {
        savedEvents.append(event)
    }

    func events(matching query: DiagnosticQuery) async throws -> [DiagnosticEvent] {
        savedEvents
    }

    func snapshot() -> [DiagnosticEvent] {
        savedEvents
    }
}

private struct SensitiveRepositoryError: Error, LocalizedError {
    var errorDescription: String? {
        "Repository failed with Bearer repository-error-canary at /Users/alice/private.db"
    }
}

private actor FailingDiagnosticPrivacyRepository: DiagnosticRepository, DiagnosticHistoryMaintaining {
    func deleteEvents(olderThan cutoff: Date) async throws -> Int {
        XCTFail("This recording test must not perform history maintenance.")
        throw RunHistoryGenerationError.unsupported
    }

    func deleteAllEvents() async throws -> Int {
        XCTFail("This recording test must not perform history maintenance.")
        throw RunHistoryGenerationError.unsupported
    }

    func deleteEvents(obsoletedBy transition: RunHistoryClearTransition, preservingLegacyRowsAfter legacyUpperBound: Date?) async throws -> Int {
        XCTFail("This recording test must not perform history maintenance.")
        throw RunHistoryGenerationError.unsupported
    }

    func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration { .initial }
    func save(_ value: DiagnosticEvent, generation: RunHistoryWriteGeneration) async throws {
        guard generation == .initial else { throw RunHistoryGenerationError.unsupported }
        try await save(value)
    }

    func save(_ event: DiagnosticEvent) async throws {
        throw SensitiveRepositoryError()
    }

    func events(matching query: DiagnosticQuery) async throws -> [DiagnosticEvent] {
        []
    }
}

private actor BlockingClearDiagnosticRepository: DiagnosticRepository, DiagnosticHistoryMaintaining {
    private var generation: RunHistoryWriteGeneration = .initial
    private var lastClearIntentID: UUID?
    private var stored: [DiagnosticEvent] = []
    private var clearAdvanced = false
    private var clearAdvancedWaiters: [CheckedContinuation<Void, Never>] = []
    private var clearReleaseContinuation: CheckedContinuation<Void, Never>?

    func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration {
        generation
    }

    func save(_ event: DiagnosticEvent) async throws {
        try await save(event, generation: generation)
    }

    func save(
        _ event: DiagnosticEvent,
        generation writeGeneration: RunHistoryWriteGeneration
    ) async throws {
        guard writeGeneration == generation else {
            throw DiagnosticRepositoryError.writeObsoletedByClearBarrier
        }
        stored.append(event)
    }

    func events(matching query: DiagnosticQuery) async throws -> [DiagnosticEvent] {
        stored
    }

    func deleteEvents(olderThan cutoff: Date) async throws -> Int { 0 }
    func deleteAllEvents() async throws -> Int { 0 }

    func deleteEvents(
        obsoletedBy transition: RunHistoryClearTransition,
        preservingLegacyRowsAfter legacyUpperBound: Date?
    ) async throws -> Int {
        guard generation == transition.previousGeneration else {
            throw RunHistoryGenerationError.clearTransitionConflict
        }
        generation = transition.nextGeneration
        lastClearIntentID = transition.intentID
        let removedCount = stored.count
        stored.removeAll()
        clearAdvanced = true
        let waiters = clearAdvancedWaiters
        clearAdvancedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            clearReleaseContinuation = continuation
        }
        return removedCount
    }

    func waitUntilClearAdvanced() async {
        if clearAdvanced { return }
        await withCheckedContinuation { continuation in
            clearAdvancedWaiters.append(continuation)
        }
    }

    func releaseClear() {
        clearReleaseContinuation?.resume()
        clearReleaseContinuation = nil
    }
}

final class DiagnosticsRecorderPrivacyTests: XCTestCase {
    func testRecordSanitizesMemoryRepositoryAndPublishedEvent() async throws {
        let eventBus = EventBus()
        let repository = DiagnosticPrivacyRepository()
        let recorder = DiagnosticsRecorder(eventBus: eventBus, repository: repository)
        let stream = await eventBus.stream()
        let publishedEvent = Task { () -> DiagnosticEvent? in
            for await event in stream {
                if case .diagnostic(let diagnosticEvent) = event {
                    return diagnosticEvent
                }
            }
            return nil
        }
        await Task.yield()

        await recorder.record(
            DiagnosticEvent(
                runID: UUID(),
                subsystem: .providers,
                level: .error,
                event: "provider.request.failed",
                message: "recognized-text-recorder-canary",
                metadata: [
                    "Authorization": "Bearer authorization-recorder-canary",
                    "apiKey": "api-key-recorder-canary",
                    "count": "2",
                    "reason": "request-failed",
                    "responseBody": "response-body-recorder-canary",
                    "statusCode": "403",
                    "url": "https://example.com/listen?token=query-recorder-canary",
                ]
            )
        )

        let memoryEvents = await recorder.snapshot()
        let repositoryEvents = await repository.snapshot()
        let published = await publishedEvent.value
        let memoryEvent = try XCTUnwrap(memoryEvents.first)
        let repositoryEvent = try XCTUnwrap(repositoryEvents.first)
        let busEvent = try XCTUnwrap(published)

        XCTAssertEqual(memoryEvent, repositoryEvent)
        XCTAssertEqual(memoryEvent, busEvent)
        XCTAssertEqual(memoryEvent.message, DiagnosticEventSanitizer.sanitizedMessage)
        XCTAssertEqual(
            memoryEvent.metadata,
            ["count": "2", "reason": "request-failed", "statusCode": "403"]
        )
        assertContainsNoCanary(memoryEvent)
    }

    func testRepositoryFailureDiagnosticDoesNotRetainRepositoryErrorDescription() async throws {
        let recorder = DiagnosticsRecorder(repository: FailingDiagnosticPrivacyRepository())

        await recorder.record(
            DiagnosticEvent(
                subsystem: .session,
                level: .info,
                event: "session.stage",
                message: "safe producer message",
                metadata: ["stage": "completed"]
            )
        )

        let events = await recorder.snapshot()
        let failure = try XCTUnwrap(events.first { $0.event == "diagnostics.repository.save.failed" })
        XCTAssertEqual(failure.message, DiagnosticEventSanitizer.sanitizedMessage)
        XCTAssertEqual(failure.metadata, ["event": "session.stage"])
        assertContainsNoCanary(failure)
    }

    func testLogicalClearRejectsOldIntentAndAcceptsNewIntentAfterClockRollback() async throws {
        let repository = InMemoryDiagnosticRepository()
        let eventBus = EventBus()
        let recorder = DiagnosticsRecorder(eventBus: eventBus, repository: repository)
        let oldGeneration = try await repository.captureRunHistoryWriteGeneration()
        let transition = try RunHistoryClearTransition(advancing: oldGeneration)
        _ = try await recorder.deleteEvents(
            obsoletedBy: transition,
            preservingLegacyRowsAfter: nil
        )
        let stream = await eventBus.stream()
        let publishedDiagnostic = expectation(description: "New-generation diagnostic is published")
        let listener = Task { () -> DiagnosticEvent? in
            for await event in stream {
                guard case .diagnostic(let diagnostic) = event else { continue }
                publishedDiagnostic.fulfill()
                return diagnostic
            }
            return nil
        }

        await recorder.record(
            DiagnosticEvent(
                timestamp: Date(timeIntervalSince1970: 10_000),
                subsystem: .session,
                level: .info,
                event: "session.old-intent",
                message: "obsolete",
                metadata: ["stage": "completed"]
            ),
            generation: oldGeneration
        )
        let newGeneration = try await repository.captureRunHistoryWriteGeneration()
        let newEvent = DiagnosticEvent(
            timestamp: Date(timeIntervalSince1970: 19),
            subsystem: .session,
            level: .info,
            event: "session.new-intent",
            message: "new",
            metadata: ["stage": "completed"]
        )
        await recorder.record(newEvent, generation: newGeneration)

        await fulfillment(of: [publishedDiagnostic], timeout: 0.2)
        let published = await listener.value
        listener.cancel()
        let cachedEvents = await recorder.snapshot()
        let storedEvents = try await repository.events(matching: .init())
        XCTAssertEqual(cachedEvents, [DiagnosticEventSanitizer.sanitize(newEvent)])
        XCTAssertEqual(storedEvents, [DiagnosticEventSanitizer.sanitize(newEvent)])
        XCTAssertEqual(published, DiagnosticEventSanitizer.sanitize(newEvent))
    }

    func testNewGenerationEventSurvivesRecorderReentrancyWhileRepositoryClearDrains() async throws {
        let repository = BlockingClearDiagnosticRepository()
        let recorder = DiagnosticsRecorder(repository: repository)
        await recorder.record(
            DiagnosticEvent(
                timestamp: Date(timeIntervalSince1970: 100),
                subsystem: .session,
                level: .info,
                event: "session.old",
                message: "old"
            )
        )
        let generation = try await repository.captureRunHistoryWriteGeneration()
        let transition = try RunHistoryClearTransition(advancing: generation)
        let clearTask = Task {
            try await recorder.deleteEvents(
                obsoletedBy: transition,
                preservingLegacyRowsAfter: nil
            )
        }
        await repository.waitUntilClearAdvanced()
        let newEvent = DiagnosticEvent(
            timestamp: Date(timeIntervalSince1970: 1),
            subsystem: .session,
            level: .info,
            event: "session.new",
            message: "new"
        )

        await recorder.record(newEvent)
        await repository.releaseClear()
        _ = try await clearTask.value
        let cached = await recorder.snapshot()
        let stored = try await repository.events(matching: .init())

        XCTAssertEqual(cached, [DiagnosticEventSanitizer.sanitize(newEvent)])
        XCTAssertEqual(stored, [DiagnosticEventSanitizer.sanitize(newEvent)])
    }

    private func assertContainsNoCanary(
        _ event: DiagnosticEvent,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let persistedText = ([event.message] + event.metadata.flatMap { [$0.key, $0.value] })
            .joined(separator: "\n")
            .lowercased()
        XCTAssertFalse(persistedText.contains("canary"), file: file, line: line)
        XCTAssertFalse(persistedText.contains("bearer"), file: file, line: line)
        XCTAssertFalse(persistedText.contains("/users/"), file: file, line: line)
        XCTAssertFalse(persistedText.contains("://"), file: file, line: line)
    }
}
