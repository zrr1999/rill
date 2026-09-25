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

    func testShutdownDrainsPresentationWithoutWritingHistoryFromTerminalEvents() async throws {
        let repository = InMemoryHistoryRepository()
        let workflow = makeBuiltinPushToTalkWorkflow()
        let harness = makeHarness(workflows: [workflow], historyRepository: repository)
        let id = UUID()
        await harness.eventBus.publish(.runStarted(.init(runID: id, workflowID: workflow.id,
            workflow: workflow.presentation, trigger: .hotkey)))
        await harness.eventBus.publish(.runCompleted(.init(runID: id, workflowID: workflow.id,
            workflow: workflow.presentation, trigger: .hotkey, finalText: "terminal result")))
        async let first: Void = harness.model.drainAndStopEventListenerForApplicationShutdown()
        async let second: Void = harness.model.drainAndStopEventListenerForApplicationShutdown()
        _ = await (first, second)
        await harness.model.flushPendingPersistenceWrites()
        let stored = try await repository.records(matching: .all)
        XCTAssertTrue(stored.isEmpty)
        XCTAssertEqual(harness.model.voice.lastCompletedText, "terminal result")
        XCTAssertFalse(harness.model.voice.isRunning)
    }

    func testImmediateSessionOnlyHistoryBeforeListenerStartsSurvivesShutdown() async throws {
        let harness = makeHarness()
        let record = WorkflowResultRecord(runID: UUID(), workflow: .init(fallbackName: "Failed run"),
            finalText: "recoverable text", outcome: .failed, trigger: .hotkey)
        await harness.eventBus.publish(.runHistoryUpdated(.sessionOnly(record)))
        await harness.model.drainAndStopEventListenerForApplicationShutdown()
        XCTAssertEqual(harness.model.history.historyRecords.first?.id, record.id)
        XCTAssertEqual(harness.model.history.historyRecords.first?.finalText, "recoverable text")
    }
}
