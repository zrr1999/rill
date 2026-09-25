import Foundation
import XCTest

@testable import RillCore
@testable import RillUI

private actor CancellationIgnoringSettingsReadGate {
    private var isEntered = false
    private var isReleased = false
    private var didObserveCancellation = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        isEntered = true
        let pendingEntryWaiters = entryWaiters
        entryWaiters.removeAll()
        pendingEntryWaiters.forEach { $0.resume() }

        await withTaskCancellationHandler {
            guard !isReleased else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    func waitUntilEntered() async {
        guard !isEntered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func waitUntilCancellationObserved() async {
        guard !didObserveCancellation else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func recordCancellation() {
        guard !didObserveCancellation else { return }
        didObserveCancellation = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor PlannedSettingsReadStore: SettingsStore {
    private var storage: [AppSettingKey: String]
    private var unavailableKeys: Set<AppSettingKey>
    private var readGates: [CancellationIgnoringSettingsReadGate] = []

    init(
        storage: [AppSettingKey: String] = [:],
        unavailableKeys: Set<AppSettingKey> = []
    ) {
        self.storage = storage
        self.unavailableKeys = unavailableKeys
    }

    func string(forKey key: AppSettingKey) async throws -> String? {
        storage[key]
    }

    func settingsSnapshot(
        forKeys keys: [AppSettingKey]
    ) async throws -> SettingsStoreReadSnapshot {
        let requestedKeys = Set(keys)
        let frozenUnavailableKeys = unavailableKeys.intersection(requestedKeys)
        let frozenValues = keys.reduce(into: [AppSettingKey: String]()) { result, key in
            guard !frozenUnavailableKeys.contains(key), let value = storage[key] else { return }
            result[key] = value
        }
        let gate = readGates.isEmpty ? nil : readGates.removeFirst()
        await gate?.wait()
        return SettingsStoreReadSnapshot(
            values: frozenValues,
            unavailableKeys: frozenUnavailableKeys
        )
    }

    func setString(_ value: String, forKey key: AppSettingKey) async throws {
        storage[key] = value
    }

    func setStringsAtomically(_ values: [AppSettingKey: String]) async throws {
        storage.merge(values) { _, newValue in newValue }
    }

    func removeValue(forKey key: AppSettingKey) async throws {
        storage[key] = nil
    }

    func enqueueReadGate(_ gate: CancellationIgnoringSettingsReadGate) {
        readGates.append(gate)
    }

    func setUnavailableKeys(_ keys: Set<AppSettingKey>) {
        unavailableKeys = keys
    }

    func storedValue(for key: AppSettingKey) -> String? {
        storage[key]
    }
}

private actor PlannedCredentialReadStore: SecureCredentialStore {
    private var storage: [SecureCredentialKey: String]
    private var readGates: [CancellationIgnoringSettingsReadGate] = []

    init(storage: [SecureCredentialKey: String] = [:]) {
        self.storage = storage
    }

    func credential(for key: SecureCredentialKey) async throws -> String? {
        let frozenValue = storage[key]
        let gate = readGates.isEmpty ? nil : readGates.removeFirst()
        await gate?.wait()
        return frozenValue
    }

    func setCredential(_ value: String, for key: SecureCredentialKey) async throws {
        storage[key] = value
    }

    func removeCredential(for key: SecureCredentialKey) async throws {
        storage[key] = nil
    }

    func enqueueReadGate(_ gate: CancellationIgnoringSettingsReadGate) {
        readGates.append(gate)
    }

    func storedValue(for key: SecureCredentialKey) -> String? {
        storage[key]
    }
}

private actor SettingsReadShutdownCompletionProbe {
    private var completionCount = 0

    func markCompleted() {
        completionCount += 1
    }

    func count() -> Int {
        completionCount
    }
}

private actor SettingsReadMigrationEventRecorder {
    private var events: [SecureCredentialStoreEvent] = []

    func record(_ event: SecureCredentialStoreEvent) {
        events.append(event)
    }

    func snapshot() -> [SecureCredentialStoreEvent] {
        events
    }
}

@MainActor
final class AppModelSettingsReadTaskOwnerTests: XCTestCase {
    func testReadinessWaitFollowsReplacementAndWaitsForBothGenerations() async {
        let owner = AppModelSettingsReadTaskOwner()
        let slot = AppModelSettingsReadTaskSlot.initialSettingsLoad
        let retiredGate = CancellationIgnoringSettingsReadGate()
        let replacementGate = CancellationIgnoringSettingsReadGate()

        let retiredID = UUID()
        let retiredTask = Task { @MainActor [owner] in
            defer { owner.finish(in: slot, id: retiredID) }
            guard owner.isActive(in: slot, id: retiredID) else { return }
            await retiredGate.wait()
        }
        XCTAssertTrue(owner.replaceActive(in: slot, id: retiredID, with: retiredTask))
        await retiredGate.waitUntilEntered()

        let readinessCompletion = SettingsReadShutdownCompletionProbe()
        let readinessWaitStarted = expectation(
            description: "Readiness began waiting on the initial generation"
        )
        let readinessTask = Task { @MainActor [owner] in
            readinessWaitStarted.fulfill()
            await owner.waitForActiveTask(in: slot)
            await readinessCompletion.markCompleted()
        }
        await fulfillment(of: [readinessWaitStarted], timeout: 1)

        let replacementID = UUID()
        let replacementTask = Task { @MainActor [owner] in
            defer { owner.finish(in: slot, id: replacementID) }
            guard owner.isActive(in: slot, id: replacementID) else { return }
            await replacementGate.wait()
        }
        XCTAssertTrue(
            owner.replaceActive(in: slot, id: replacementID, with: replacementTask)
        )
        await retiredGate.waitUntilCancellationObserved()
        await replacementGate.waitUntilEntered()

        await replacementGate.release()
        for _ in 0..<10 { await Task.yield() }
        let blockedCompletionCount = await readinessCompletion.count()
        XCTAssertEqual(
            blockedCompletionCount,
            0,
            "Readiness must retain the replaced generation until its non-cooperative read exits."
        )

        await retiredGate.release()
        await readinessTask.value
        let finalCompletionCount = await readinessCompletion.count()
        XCTAssertEqual(finalCompletionCount, 1)
        XCTAssertEqual(owner.trackedTaskCount, 0)
    }

    func testReplacementCancelsOldTaskButConcurrentDrainsWaitForRetiredAndActive() async {
        let owner = AppModelSettingsReadTaskOwner()
        let slot = AppModelSettingsReadTaskSlot.openAICredentialRetry
        let retiredGate = CancellationIgnoringSettingsReadGate()
        let activeGate = CancellationIgnoringSettingsReadGate()

        let retiredID = UUID()
        let retiredTask = Task { @MainActor [owner] in
            defer { owner.finish(in: slot, id: retiredID) }
            guard owner.isActive(in: slot, id: retiredID) else { return }
            await retiredGate.wait()
        }
        XCTAssertTrue(owner.replaceActive(in: slot, id: retiredID, with: retiredTask))
        await retiredGate.waitUntilEntered()

        let activeID = UUID()
        let activeTask = Task { @MainActor [owner] in
            defer { owner.finish(in: slot, id: activeID) }
            guard owner.isActive(in: slot, id: activeID) else { return }
            await activeGate.wait()
        }
        XCTAssertTrue(owner.replaceActive(in: slot, id: activeID, with: activeTask))
        await retiredGate.waitUntilCancellationObserved()
        await activeGate.waitUntilEntered()
        XCTAssertFalse(owner.isActive(in: slot, id: retiredID))
        XCTAssertTrue(owner.isActive(in: slot, id: activeID))
        XCTAssertEqual(owner.trackedTaskCount, 2)

        let completion = SettingsReadShutdownCompletionProbe()
        let firstDrain = Task { @MainActor [owner] in
            await owner.cancelAllAndDrain()
            await completion.markCompleted()
        }
        let secondDrain = Task { @MainActor [owner] in
            await owner.cancelAllAndDrain()
            await completion.markCompleted()
        }
        await activeGate.waitUntilCancellationObserved()

        await activeGate.release()
        for _ in 0..<10 { await Task.yield() }
        let completionCountWithRetiredTaskBlocked = await completion.count()
        XCTAssertEqual(completionCountWithRetiredTaskBlocked, 0)

        await retiredGate.release()
        await firstDrain.value
        await secondDrain.value

        let finalCompletionCount = await completion.count()
        XCTAssertEqual(finalCompletionCount, 2)
        XCTAssertEqual(owner.state, .stopped)
        XCTAssertEqual(owner.trackedTaskCount, 0)
    }

    func testStoppedOwnerRejectsNewTasksAndRepeatedDrainIsANoOp() async {
        let owner = AppModelSettingsReadTaskOwner()
        await owner.cancelAllAndDrain()
        XCTAssertEqual(owner.state, .stopped)

        let slot = AppModelSettingsReadTaskSlot.initialSettingsLoad
        let taskID = UUID()
        let rejectedTask = Task { @MainActor [owner] in
            defer { owner.finish(in: slot, id: taskID) }
            guard owner.isActive(in: slot, id: taskID) else { return }
            XCTFail("A stopped owner must not activate a new task.")
        }
        XCTAssertFalse(owner.replaceActive(in: slot, id: taskID, with: rejectedTask))
        await rejectedTask.value
        await owner.cancelAllAndDrain()

        XCTAssertEqual(owner.state, .stopped)
        XCTAssertEqual(owner.trackedTaskCount, 0)
    }
}

@MainActor
final class AppModelSettingsReadShutdownTests: XCTestCase {
    func testShutdownWaitsForInitialLoadAndRejectsLateSnapshot() async {
        let gate = CancellationIgnoringSettingsReadGate()
        let lateBaseURL = "https://late-settings.example/v1"
        let settingsStore = PlannedSettingsReadStore(
            storage: [.openAIBaseURL: lateBaseURL]
        )
        await settingsStore.enqueueReadGate(gate)
        let harness = makeHarness(settingsStore: settingsStore)
        let initialBaseURL = harness.model.settings.openAIBaseURL
        await gate.waitUntilEntered()

        let completion = SettingsReadShutdownCompletionProbe()
        let shutdownTask = Task { @MainActor in
            await harness.model.stopSettingsReadTasksForApplicationShutdown()
            await completion.markCompleted()
        }
        await gate.waitUntilCancellationObserved()
        let completionCountWhileBlocked = await completion.count()
        XCTAssertEqual(completionCountWhileBlocked, 0)
        XCTAssertFalse(harness.model.settings.isLoading)

        await gate.release()
        await shutdownTask.value

        XCTAssertNotEqual(initialBaseURL, lateBaseURL)
        XCTAssertEqual(harness.model.settings.openAIBaseURL, initialBaseURL)
        XCTAssertEqual(harness.model.settings.settingsReadTaskOwner.state, .stopped)
        XCTAssertEqual(harness.model.settings.settingsReadTaskOwner.trackedTaskCount, 0)
    }

    func testShutdownDrainsRetiredAndActiveOpenAIRetriesWithoutPublishing() async throws {
        let settingsStore = PlannedSettingsReadStore()
        let credentialStore = PlannedCredentialReadStore(
            storage: [.openAIAPIKey: "initial-key"]
        )
        let harness = makeHarness(
            settingsStore: settingsStore,
            credentialStore: credentialStore
        )
        await waitUntil { !harness.model.settings.isLoading }
        XCTAssertEqual(harness.model.settings.openAIAPIKey, "initial-key")

        try await credentialStore.setCredential("late-key", for: .openAIAPIKey)
        let retiredGate = CancellationIgnoringSettingsReadGate()
        let activeGate = CancellationIgnoringSettingsReadGate()
        await credentialStore.enqueueReadGate(retiredGate)
        await credentialStore.enqueueReadGate(activeGate)

        harness.model.retryOpenAICredentialLoad()
        await retiredGate.waitUntilEntered()
        harness.model.retryOpenAICredentialLoad()
        await retiredGate.waitUntilCancellationObserved()
        await activeGate.waitUntilEntered()
        XCTAssertEqual(harness.model.settings.settingsReadTaskOwner.trackedTaskCount, 2)

        let completion = SettingsReadShutdownCompletionProbe()
        let shutdownTask = Task { @MainActor in
            await harness.model.stopSettingsReadTasksForApplicationShutdown()
            await completion.markCompleted()
        }
        await activeGate.waitUntilCancellationObserved()
        XCTAssertEqual(harness.model.settings.openAICredentialAvailability, .inaccessible)

        await activeGate.release()
        for _ in 0..<10 { await Task.yield() }
        let completionCountWithRetiredTaskBlocked = await completion.count()
        XCTAssertEqual(completionCountWithRetiredTaskBlocked, 0)

        await retiredGate.release()
        await shutdownTask.value

        XCTAssertEqual(harness.model.settings.openAIAPIKey, "initial-key")
        XCTAssertFalse(
            harness.model.history.eventFeed.contains {
                $0.english == "OpenAI credential access is available again."
            }
        )
        XCTAssertEqual(harness.model.settings.settingsReadTaskOwner.state, .stopped)
        XCTAssertEqual(harness.model.settings.settingsReadTaskOwner.trackedTaskCount, 0)
    }

    func testShutdownWaitsForScalarRetryAndRejectsLateRecoveredValue() async throws {
        let settingsStore = PlannedSettingsReadStore(
            unavailableKeys: [.interfaceLanguage]
        )
        let harness = makeHarness(settingsStore: settingsStore)
        await waitUntil { !harness.model.settings.isLoading }
        let initialLanguage = harness.model.settings.language
        let recoveredLanguage: AppLanguage = initialLanguage == .english
            ? .simplifiedChinese
            : .english

        try await settingsStore.setString(
            recoveredLanguage.rawValue,
            forKey: .interfaceLanguage
        )
        await settingsStore.setUnavailableKeys([])
        let gate = CancellationIgnoringSettingsReadGate()
        await settingsStore.enqueueReadGate(gate)

        harness.model.retryUnavailableScalarSettings(in: .interface)
        await gate.waitUntilEntered()
        XCTAssertTrue(
            harness.model.settings.retryingUnavailableScalarSettingsDomains.contains(.interface)
        )

        let completion = SettingsReadShutdownCompletionProbe()
        let shutdownTask = Task { @MainActor in
            await harness.model.stopSettingsReadTasksForApplicationShutdown()
            await completion.markCompleted()
        }
        await gate.waitUntilCancellationObserved()
        let completionCountWhileBlocked = await completion.count()
        XCTAssertEqual(completionCountWhileBlocked, 0)
        XCTAssertFalse(
            harness.model.settings.retryingUnavailableScalarSettingsDomains.contains(.interface)
        )

        await gate.release()
        await shutdownTask.value

        XCTAssertEqual(harness.model.settings.language, initialLanguage)
        XCTAssertEqual(harness.model.settings.settingsReadTaskOwner.state, .stopped)
        XCTAssertEqual(harness.model.settings.settingsReadTaskOwner.trackedTaskCount, 0)
    }

    func testShutdownWaitsForStoredDomainRetryAndRejectsLateRecovery() async {
        let settingsStore = PlannedSettingsReadStore(
            unavailableKeys: [.customWorkflows]
        )
        let harness = makeHarness(settingsStore: settingsStore)
        await waitUntil { !harness.model.settings.isLoading }
        XCTAssertEqual(harness.model.workflowLibrary.workflowLibraryAvailability, .unavailable)

        await settingsStore.setUnavailableKeys([])
        let gate = CancellationIgnoringSettingsReadGate()
        await settingsStore.enqueueReadGate(gate)

        harness.model.retryUnavailableStoredSettingsDomains()
        await gate.waitUntilEntered()
        XCTAssertTrue(harness.model.settings.isRetryingUnavailableSettingsDomains)
        XCTAssertEqual(harness.model.settings.settingsReadTaskOwner.trackedTaskCount, 1)

        let completion = SettingsReadShutdownCompletionProbe()
        let shutdownTask = Task { @MainActor in
            await harness.model.stopSettingsReadTasksForApplicationShutdown()
            await completion.markCompleted()
        }
        await gate.waitUntilCancellationObserved()
        let completionCountWhileBlocked = await completion.count()
        XCTAssertEqual(completionCountWhileBlocked, 0)
        XCTAssertFalse(harness.model.settings.isRetryingUnavailableSettingsDomains)

        await gate.release()
        await shutdownTask.value

        XCTAssertEqual(harness.model.workflowLibrary.workflowLibraryAvailability, .unavailable)
        XCTAssertFalse(
            harness.model.history.eventFeed.contains {
                $0.english == "Protected settings were loaded again without overwriting stored data."
            }
        )
        XCTAssertEqual(harness.model.settings.settingsReadTaskOwner.state, .stopped)
        XCTAssertEqual(harness.model.settings.settingsReadTaskOwner.trackedTaskCount, 0)
    }

    func testShutdownWaitsForPrivacyRetryAndKeepsRuntimeGateClosed() async throws {
        let protectedKeys: Set<AppSettingKey> = [
            .privacySensitiveAppRules,
            .privacyCloudConfirmationRequired,
            .privacyHistoryPreviewMode,
            .privacySecureInputConservativeMode,
        ]
        let settingsStore = PlannedSettingsReadStore(
            storage: try AppSettingsCodec.privacySettingsStorageValues(for: .defaults),
            unavailableKeys: [.privacyCloudConfirmationRequired]
        )
        let privacySettingsSource = PrivacyPolicySettingsSource()
        let harness = makeHarness(
            settingsStore: settingsStore,
            privacySettingsSource: privacySettingsSource
        )
        await waitUntil { !harness.model.settings.isLoading }
        XCTAssertNotNil(harness.model.privacySettingsLoadError)
        XCTAssertThrowsError(try privacySettingsSource.currentSettings())

        await settingsStore.setUnavailableKeys([])
        let gate = CancellationIgnoringSettingsReadGate()
        await settingsStore.enqueueReadGate(gate)

        harness.model.retryPrivacySettingsLoad()
        await gate.waitUntilEntered()
        XCTAssertTrue(harness.model.isLoadingPrivacySettings)
        XCTAssertEqual(harness.model.settings.settingsReadTaskOwner.trackedTaskCount, 1)

        let completion = SettingsReadShutdownCompletionProbe()
        let shutdownTask = Task { @MainActor in
            await harness.model.stopSettingsReadTasksForApplicationShutdown()
            await completion.markCompleted()
        }
        await gate.waitUntilCancellationObserved()
        let completionCountWhileBlocked = await completion.count()
        XCTAssertEqual(completionCountWhileBlocked, 0)
        XCTAssertFalse(harness.model.isLoadingPrivacySettings)

        await gate.release()
        await shutdownTask.value

        XCTAssertNotNil(harness.model.privacySettingsLoadError)
        XCTAssertThrowsError(try privacySettingsSource.currentSettings())
        let protectedSnapshot = try await settingsStore.settingsSnapshot(
            forKeys: Array(protectedKeys)
        )
        XCTAssertEqual(
            Set(protectedSnapshot.values.keys),
            protectedKeys
        )
        XCTAssertEqual(harness.model.settings.settingsReadTaskOwner.state, .stopped)
        XCTAssertEqual(harness.model.settings.settingsReadTaskOwner.trackedTaskCount, 0)
    }

    func testShutdownRejectsNewPrivacyMutationsAndWrites() async {
        let settingsStore = PlannedSettingsReadStore()
        let privacySettingsSource = PrivacyPolicySettingsSource(initialSettings: .defaults)
        let harness = makeHarness(
            settingsStore: settingsStore,
            privacySettingsSource: privacySettingsSource
        )
        await waitUntil { !harness.model.settings.isLoading }
        let initialPolicy = harness.model.privacyPolicySettings

        await harness.model.stopSettingsReadTasksForApplicationShutdown()
        harness.model.setPrivacyCloudConfirmationRequired(
            !initialPolicy.cloudConfirmationRequired
        )
        harness.model.setPrivacyHistoryPreviewMode(
            initialPolicy.historyPreviewMode == .full ? .disabled : .full
        )
        harness.model.resetPrivacySettingsToSafeDefaults()
        harness.model.retryPrivacySettingsSave()
        await harness.model.flushPendingPersistenceWrites()

        XCTAssertEqual(harness.model.privacyPolicySettings, initialPolicy)
        XCTAssertEqual(try? privacySettingsSource.currentSettings(), initialPolicy)
        let storedValues = await settingsStore.storedValue(
            for: .privacyCloudConfirmationRequired
        )
        XCTAssertNil(storedValues)
    }

    func testShutdownWaitsForCredentialMigrationReporterBeforeCompleting() async {
        let reporterGate = CancellationIgnoringSettingsReadGate()
        let eventRecorder = SettingsReadMigrationEventRecorder()
        let legacyStore = PlannedSettingsReadStore(
            storage: [.openAIAPIKey: "legacy-key"]
        )
        let secureStore = PlannedCredentialReadStore()
        let migratingStore = MigratingSecureCredentialStore(
            secureStore: secureStore,
            legacySettingsStore: legacyStore,
            eventReporter: { event in
                await eventRecorder.record(event)
                if event.kind == .migrationSucceeded,
                   event.key == .openAIAPIKey {
                    await reporterGate.wait()
                }
            }
        )
        let harness = makeHarness(
            settingsStore: legacyStore,
            credentialStore: migratingStore
        )
        await reporterGate.waitUntilEntered()

        let completion = SettingsReadShutdownCompletionProbe()
        let shutdownTask = Task { @MainActor in
            await harness.model.stopSettingsReadTasksForApplicationShutdown()
            await completion.markCompleted()
        }
        for _ in 0..<10 { await Task.yield() }
        let completionCountWhileReporterWasBlocked = await completion.count()
        XCTAssertEqual(completionCountWhileReporterWasBlocked, 0)

        await reporterGate.release()
        await shutdownTask.value

        let secureValue = await secureStore.storedValue(for: .openAIAPIKey)
        let legacyValue = await legacyStore.storedValue(for: .openAIAPIKey)
        let events = await eventRecorder.snapshot()
        XCTAssertEqual(secureValue, "legacy-key")
        XCTAssertNil(legacyValue)
        XCTAssertTrue(
            events.contains {
                $0.kind == .migrationSucceeded && $0.key == .openAIAPIKey
            }
        )
        XCTAssertEqual(harness.model.settings.openAIAPIKey, "")
        XCTAssertEqual(harness.model.settings.openAICredentialAvailability, .inaccessible)
        XCTAssertEqual(harness.model.settings.settingsReadTaskOwner.state, .stopped)
        XCTAssertEqual(harness.model.settings.settingsReadTaskOwner.trackedTaskCount, 0)
    }

    private func waitUntil(
        attempts: Int = 200,
        _ predicate: () -> Bool
    ) async {
        for _ in 0..<attempts {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("The asynchronous condition did not become true.")
    }
}
