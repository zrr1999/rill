import XCTest
@testable import RillCore
@testable import RillRuntime
@testable import RillUI

private actor PersistenceFlushStore: SettingsStore, SecureCredentialStore {
    private typealias CountWaiter = (
        target: Int,
        continuation: CheckedContinuation<Void, Never>
    )

    private var settings: [AppSettingKey: String] = [:]
    private var credentials: [SecureCredentialKey: String] = [:]
    private var shouldBlockWrites = false
    private var blockedWriteCount = 0
    private var countWaiters: [CountWaiter] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func string(forKey key: AppSettingKey) async throws -> String? {
        settings[key]
    }

    func strings(forKeys keys: [AppSettingKey]) async throws -> [AppSettingKey: String] {
        keys.reduce(into: [:]) { values, key in
            values[key] = settings[key]
        }
    }

    func setString(_ value: String, forKey key: AppSettingKey) async throws {
        await waitForWriteReleaseIfNeeded()
        settings[key] = value
    }

    func setStringsAtomically(_ values: [AppSettingKey: String]) async throws {
        await waitForWriteReleaseIfNeeded()
        settings.merge(values) { _, newValue in newValue }
    }

    func removeValue(forKey key: AppSettingKey) async throws {
        await waitForWriteReleaseIfNeeded()
        settings.removeValue(forKey: key)
    }

    func credential(for key: SecureCredentialKey) async throws -> String? {
        credentials[key]
    }

    func setCredential(_ value: String, for key: SecureCredentialKey) async throws {
        await waitForWriteReleaseIfNeeded()
        credentials[key] = value
    }

    func removeCredential(for key: SecureCredentialKey) async throws {
        await waitForWriteReleaseIfNeeded()
        credentials.removeValue(forKey: key)
    }

    func blockWrites() {
        shouldBlockWrites = true
    }

    func waitUntilBlockedWriteCount(reaches target: Int) async {
        guard blockedWriteCount < target else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((target, continuation))
        }
    }

    func releaseWrites() {
        shouldBlockWrites = false
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func snapshot() -> (
        settings: [AppSettingKey: String],
        credentials: [SecureCredentialKey: String]
    ) {
        (settings, credentials)
    }

    private func waitForWriteReleaseIfNeeded() async {
        guard shouldBlockWrites else { return }
        blockedWriteCount += 1
        let currentCount = blockedWriteCount
        let waiters = countWaiters
        countWaiters.removeAll()
        for waiter in waiters {
            if currentCount >= waiter.target {
                waiter.continuation.resume()
            } else {
                countWaiters.append(waiter)
            }
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }
}

private actor PersistenceFlushCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private actor PersistenceFlushHistoryRepository: HistoryRepository {
    private var storedRecords: [WorkflowResultRecord] = []
    private var shouldBlockWrites = false
    private var saveStarted = false
    private var saveStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func save(_ record: WorkflowResultRecord) async throws {
        saveStarted = true
        let observations = saveStartedWaiters
        saveStartedWaiters.removeAll()
        observations.forEach { $0.resume() }
        if shouldBlockWrites {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        storedRecords.append(record)
    }

    func records(matching query: HistoryQuery) async throws -> [WorkflowResultRecord] {
        storedRecords.filter { record in
            query.runID.map { record.runID == $0 } ?? true
        }
    }

    func deleteRecords(olderThan cutoff: Date) async throws -> Int {
        let oldCount = storedRecords.count
        storedRecords.removeAll { $0.timestamp < cutoff }
        return oldCount - storedRecords.count
    }

    func deleteRecords(through upperBound: Date) async throws -> Int {
        let oldCount = storedRecords.count
        storedRecords.removeAll { $0.timestamp <= upperBound }
        return oldCount - storedRecords.count
    }

    func deleteAllRecords() async throws -> Int {
        let oldCount = storedRecords.count
        storedRecords.removeAll()
        return oldCount
    }

    func blockWrites() {
        shouldBlockWrites = true
    }

    func waitUntilSaveStarts() async {
        guard !saveStarted else { return }
        await withCheckedContinuation { continuation in
            saveStartedWaiters.append(continuation)
        }
    }

    func releaseWrites() {
        shouldBlockWrites = false
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

@MainActor
final class AppModelPersistenceFlushTests: XCTestCase {
    func testFlushWaitsForLatestSettingsCredentialAndPrivacyWrites() async {
        let store = PersistenceFlushStore()
        let harness = makeHarness(
            settingsStore: store,
            credentialStore: store,
            settingsWriteDebounceDuration: .zero
        )
        await waitForEventProcessing(harness)
        await store.blockWrites()

        let expectedLanguage: AppLanguage = harness.model.language == .english
            ? .simplifiedChinese
            : .english
        harness.model.language = expectedLanguage
        harness.model.openAIBaseURL = "https://latest.example.test"
        harness.model.openAIAPIKey = "latest-key"
        harness.model.setPrivacyCloudConfirmationRequired(false)

        let completion = PersistenceFlushCompletionProbe()
        let flushTask = Task {
            await harness.model.flushPendingPersistenceWrites()
            await completion.markCompleted()
        }
        await store.waitUntilBlockedWriteCount(reaches: 4)
        let didCompleteWhileWritesWereBlocked = await completion.isCompleted()
        XCTAssertFalse(didCompleteWhileWritesWereBlocked)

        await store.releaseWrites()
        await flushTask.value

        let snapshot = await store.snapshot()
        let didCompleteAfterWritesWereReleased = await completion.isCompleted()
        XCTAssertTrue(didCompleteAfterWritesWereReleased)
        XCTAssertEqual(snapshot.settings[.interfaceLanguage], expectedLanguage.rawValue)
        XCTAssertEqual(snapshot.settings[.openAIBaseURL], "https://latest.example.test")
        XCTAssertEqual(snapshot.settings[.privacyCloudConfirmationRequired], "false")
        XCTAssertEqual(snapshot.credentials[.openAIAPIKey], "latest-key")
    }

    func testShutdownDrainsTerminalEventAndFlushWaitsForHistoryWrite() async throws {
        let historyRepository = PersistenceFlushHistoryRepository()
        let workflow = makeBuiltinPushToTalkWorkflow()
        let harness = makeHarness(
            workflows: [workflow],
            historyRepository: historyRepository
        )
        await historyRepository.blockWrites()
        let runID = UUID()

        await harness.eventBus.publish(
            .runStarted(
                RunSnapshot(
                    runID: runID,
                    workflowID: workflow.id,
                    workflow: workflow.presentation,
                    trigger: .hotkey
                )
            )
        )
        await harness.eventBus.publish(
            .runCompleted(
                WorkflowRunSummary(
                    runID: runID,
                    workflowID: workflow.id,
                    workflow: workflow.presentation,
                    trigger: .hotkey,
                    finalText: "terminal result"
                )
            )
        )

        async let firstDrain: Void = harness.model
            .drainAndStopEventListenerForApplicationShutdown()
        async let concurrentDrain: Void = harness.model
            .drainAndStopEventListenerForApplicationShutdown()
        _ = await (firstDrain, concurrentDrain)
        await historyRepository.waitUntilSaveStarts()

        let completion = PersistenceFlushCompletionProbe()
        let flushTask = Task {
            await harness.model.flushPendingPersistenceWrites()
            await completion.markCompleted()
        }
        await Task.yield()
        let completedWhileHistoryWriteWasBlocked = await completion.isCompleted()
        XCTAssertFalse(completedWhileHistoryWriteWasBlocked)

        await historyRepository.releaseWrites()
        await flushTask.value

        let completedAfterHistoryWriteWasReleased = await completion.isCompleted()
        XCTAssertTrue(completedAfterHistoryWriteWasReleased)
        let stored = try await historyRepository.records(
            matching: HistoryQuery(runID: runID)
        )
        XCTAssertEqual(stored.first?.finalText, "terminal result")
        XCTAssertEqual(harness.model.recentVoiceResultRecords.first?.runID, runID)
    }

    func testImmediateFailureBeforeListenerTaskRunsIsPersistedDuringShutdown() async throws {
        let historyRepository = InMemoryHistoryRepository()
        let workflow = makeBuiltinPushToTalkWorkflow()
        let harness = makeHarness(
            workflows: [workflow],
            historyRepository: historyRepository
        )
        let runID = UUID()

        // Intentionally do not yield or sleep after AppModel initialization.
        // The lifecycle delivery stream is reserved when EventBus is created,
        // so terminal events cannot fall into a subscription-registration gap.
        await harness.eventBus.publish(
            .runStarted(
                RunSnapshot(
                    runID: runID,
                    workflowID: workflow.id,
                    workflow: workflow.presentation,
                    trigger: .hotkey
                )
            )
        )
        await harness.eventBus.publish(
            .runFailed(
                runID: runID,
                workflow: nil,
                message: "Immediate failure"
            )
        )

        await harness.model.drainAndStopEventListenerForApplicationShutdown()
        await harness.model.flushPendingPersistenceWrites()

        let stored = try await historyRepository.records(
            matching: HistoryQuery(runID: runID)
        )
        XCTAssertEqual(stored.first?.outcome, .failed)
        XCTAssertEqual(
            stored.first?.failureMessage,
            HistoryFailureSanitizer.genericMessage
        )
        XCTAssertEqual(stored.first?.trigger, .hotkey)
    }
}
