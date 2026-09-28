
@testable import RillCore
@testable import RillWorkflows
import XCTest
@testable import RillUI

private actor ShutdownBlockingLocalHistoryMaintenance: LocalHistoryMaintaining {
    private typealias CallWaiter = (
        target: Int,
        continuation: CheckedContinuation<Void, Never>
    )

    private var calls: [UITestLocalHistoryMaintenanceCall] = []
    private var callWaiters: [CallWaiter] = []
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private var observedCancellation = false

    func performRetention(
        recordRetention: HistoryRetentionPeriod,
        runRetention: HistoryRetentionPeriod,
        now: Date
    ) async -> LocalHistoryMaintenanceResult {
        await recordAndWait(.performRetention(recordRetention, runRetention))
    }

    func clearRecordHistory() async -> LocalHistoryMaintenanceResult {
        await recordAndWait(.clearClipboard)
    }

    func clearRunHistory() async -> LocalHistoryMaintenanceResult {
        await recordAndWait(.clearRun)
    }

    func retryPendingMaintenance() async -> LocalHistoryMaintenanceResult {
        await recordAndWait(.retryPending)
    }

    func waitUntilCallCount(reaches target: Int) async {
        guard calls.count < target else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((target, continuation))
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let waiters = operationWaiters
        operationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func callSnapshot() -> [UITestLocalHistoryMaintenanceCall] {
        calls
    }

    func didObserveCancellation() -> Bool {
        observedCancellation
    }

    private func recordAndWait(
        _ call: UITestLocalHistoryMaintenanceCall
    ) async -> LocalHistoryMaintenanceResult {
        calls.append(call)
        let currentCount = calls.count
        let waiters = callWaiters
        callWaiters.removeAll()
        for waiter in waiters {
            if currentCount >= waiter.target {
                waiter.continuation.resume()
            } else {
                callWaiters.append(waiter)
            }
        }
        if !isReleased {
            await withCheckedContinuation { continuation in
                operationWaiters.append(continuation)
            }
        }
        observedCancellation = Task.isCancelled
        return .completed(LocalHistoryMaintenanceCounts())
    }
}

private final class ShutdownProjectionReadLatch: @unchecked Sendable {
    private typealias CountWaiter = (
        target: Int,
        continuation: CheckedContinuation<Void, Never>
    )

    private let lock = NSLock()
    private var readCount = 0
    private var shouldBlockNextRead = false
    private var countWaiters: [CountWaiter] = []
    private var readReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWasObserved = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func blockNextRead() {
        lock.lock()
        shouldBlockNextRead = true
        lock.unlock()
    }

    func performRead() async {
        let shouldBlock = beginRead()
        guard shouldBlock else { return }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                readReleaseWaiters.append(continuation)
                lock.unlock()
            }
        } onCancel: {
            self.recordCancellation()
        }
    }

    func waitUntilReadCount(reaches target: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if readCount >= target {
                lock.unlock()
                continuation.resume()
            } else {
                countWaiters.append((target, continuation))
                lock.unlock()
            }
        }
    }

    func waitUntilCancellationIsObserved() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if cancellationWasObserved {
                lock.unlock()
                continuation.resume()
            } else {
                cancellationWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func releaseBlockedReads() {
        lock.lock()
        shouldBlockNextRead = false
        let waiters = readReleaseWaiters
        readReleaseWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func currentReadCount() -> Int {
        lock.lock()
        let count = readCount
        lock.unlock()
        return count
    }

    private func beginRead() -> Bool {
        lock.lock()
        readCount += 1
        let currentCount = readCount
        let shouldBlock = shouldBlockNextRead
        shouldBlockNextRead = false
        let readyWaiters = countWaiters.filter { $0.target <= currentCount }
        countWaiters.removeAll { $0.target <= currentCount }
        lock.unlock()
        readyWaiters.forEach { $0.continuation.resume() }
        return shouldBlock
    }

    private func recordCancellation() {
        lock.lock()
        cancellationWasObserved = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }
    }
}

private struct ShutdownProjectionHistoryRepository: HistoryRepository {
    func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration { .initial }
    func save(_ value: WorkflowResultRecord, generation: RunHistoryWriteGeneration) async throws {
        guard generation == .initial else { throw RunHistoryGenerationError.unsupported }
        try await (self as any HistoryRepository).save(value)
    }

    let readLatch: ShutdownProjectionReadLatch

    func save(_ record: WorkflowResultRecord) async throws {}

    func records(matching query: HistoryQuery) async throws -> [WorkflowResultRecord] {
        await readLatch.performRead()
        return []
    }

    func deleteRecords(olderThan cutoff: Date) async throws -> Int { 0 }

    func deleteAllRecords() async throws -> Int { 0 }
}

private actor ShutdownRetentionSettingsStore: SettingsStore {
    private var storage: [AppSettingKey: String] = [:]
    private var shouldBlockRunRetentionWrite = false
    private var runRetentionWrites = 0
    private var writeStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var writeReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    func string(forKey key: AppSettingKey) async throws -> String? {
        storage[key]
    }

    func strings(forKeys keys: [AppSettingKey]) async throws -> [AppSettingKey: String] {
        keys.reduce(into: [:]) { values, key in
            values[key] = storage[key]
        }
    }

    func setString(_ value: String, forKey key: AppSettingKey) async throws {
        if key == .runHistoryRetentionPeriod {
            runRetentionWrites += 1
        }
        if key == .runHistoryRetentionPeriod, shouldBlockRunRetentionWrite {
            shouldBlockRunRetentionWrite = false
            let waiters = writeStartWaiters
            writeStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                writeReleaseWaiters.append(continuation)
            }
        }
        storage[key] = value
    }

    func setStringsAtomically(_ values: [AppSettingKey: String]) async throws {
        storage.merge(values) { _, newValue in newValue }
    }

    func removeValue(forKey key: AppSettingKey) async throws {
        storage.removeValue(forKey: key)
    }

    func blockNextRunRetentionWrite() {
        shouldBlockRunRetentionWrite = true
    }

    func waitUntilRunRetentionWriteStarts() async {
        guard runRetentionWrites == 0 else { return }
        await withCheckedContinuation { continuation in
            writeStartWaiters.append(continuation)
        }
    }

    func releaseRunRetentionWrites() {
        let waiters = writeReleaseWaiters
        writeReleaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func runRetentionWriteCount() -> Int {
        runRetentionWrites
    }
}

private actor HistoryShutdownCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

@MainActor
extension AppModelTests {
    func testHistoryRetentionDefaultsToThirtyDaysWhenSettingsAreUnset() async {
        let harness = makeHarness(settingsStore: UITestSettingsStore())

        await waitForHistoryMaintenance(harness)

        XCTAssertEqual(harness.model.recordRetentionPeriod, .thirtyDays)
        XCTAssertEqual(harness.model.history.runHistoryRetentionPeriod, .thirtyDays)
    }

    func testRetentionMutationIsRejectedWhileInitialSettingsReadIsPending() async {
        let settingsStore = UITestSettingsStore(
            storage: [
                .recordRetentionPeriod: HistoryRetentionPeriod.oneDay.rawValue,
                .runHistoryRetentionPeriod: HistoryRetentionPeriod.thirtyDays.rawValue,
            ],
            suspendBatchReads: true
        )
        let maintenance = UITestLocalHistoryMaintenance()
        let harness = makeHarness(
            settingsStore: settingsStore,
            localHistoryMaintenance: maintenance
        )
        await settingsStore.waitUntilBatchReadIsSuspended()
        XCTAssertTrue(harness.model.settings.isLoading)

        harness.model.setRecordRetentionPeriod(.forever)
        await Task.yield()

        let activityBeforeResume = await settingsStore.activitySnapshot()
        let maintenanceBeforeResume = await maintenance.callSnapshot()
        XCTAssertNil(activityBeforeResume.setCounts[.recordRetentionPeriod])
        XCTAssertTrue(maintenanceBeforeResume.isEmpty)
        XCTAssertEqual(harness.model.recordRetentionPeriod, .thirtyDays)

        await settingsStore.resumeBatchRead()
        await waitForHistoryMaintenance(harness)

        XCTAssertFalse(harness.model.settings.isLoading)
        XCTAssertEqual(harness.model.recordRetentionPeriod, .oneDay)
        let storedValue = try? await settingsStore.string(
            forKey: .recordRetentionPeriod
        )
        XCTAssertEqual(storedValue, HistoryRetentionPeriod.oneDay.rawValue)
    }

    func testInvalidHistoryRetentionFailsSafeToForever() async {
        let settingsStore = UITestSettingsStore(
            storage: [
                .recordRetentionPeriod: "invalid-clipboard-retention",
                .runHistoryRetentionPeriod: "invalid-run-retention",
            ]
        )
        let harness = makeHarness(settingsStore: settingsStore)

        await waitForHistoryMaintenance(harness)

        XCTAssertEqual(harness.model.recordRetentionPeriod, .forever)
        XCTAssertEqual(harness.model.history.runHistoryRetentionPeriod, .forever)
        XCTAssertTrue(harness.model.history.areHistoryRetentionSettingsAvailable)
        XCTAssertNotNil(harness.model.history.historyRetentionSettingsError)
        XCTAssertTrue(
            harness.model.history.historyRetentionSettingsError?.contains("暂停") == true ||
                harness.model.history.historyRetentionSettingsError?.contains("paused") == true
        )
    }

    func testUnreadableRetentionSettingPausesOnlyItsDomain() async {
        let settingsStore = UITestSettingsStore(
            storage: [
                .recordRetentionPeriod: "damaged-protected-value",
                .runHistoryRetentionPeriod: HistoryRetentionPeriod.oneWeek.rawValue,
            ],
            unavailableKeys: [.recordRetentionPeriod]
        )
        let harness = makeHarness(settingsStore: settingsStore)

        await waitForHistoryMaintenance(harness)

        XCTAssertEqual(harness.model.recordRetentionPeriod, .forever)
        XCTAssertEqual(harness.model.history.runHistoryRetentionPeriod, .oneWeek)
        XCTAssertTrue(harness.model.history.areHistoryRetentionSettingsAvailable)
        XCTAssertNotNil(harness.model.history.historyRetentionSettingsError)
        let activity = await settingsStore.activitySnapshot()
        XCTAssertEqual(
            activity.storage[.recordRetentionPeriod],
            "damaged-protected-value"
        )
        XCTAssertNil(activity.setCounts[.recordRetentionPeriod])
        XCTAssertNil(activity.removeCounts[.recordRetentionPeriod])
    }

    func testSettingsReadFailurePausesCleanupWithoutPresentingForeverAsUserChoice() async {
        let settingsStore = UITestSettingsStore(failBatchReads: true)
        let maintenance = UITestLocalHistoryMaintenance()
        let harness = makeHarness(
            settingsStore: settingsStore,
            historyRetentionMaintenanceInterval: .milliseconds(40),
            localHistoryMaintenance: maintenance
        )

        await waitForHistoryMaintenance(harness)

        XCTAssertEqual(harness.model.recordRetentionPeriod, .thirtyDays)
        XCTAssertEqual(harness.model.history.runHistoryRetentionPeriod, .thirtyDays)
        XCTAssertFalse(harness.model.history.areHistoryRetentionSettingsAvailable)
        XCTAssertNotNil(harness.model.history.historyRetentionSettingsError)
        XCTAssertNil(harness.model.history.periodicHistoryRetentionMaintenanceTask)
        let maintenanceCalls = await maintenance.callSnapshot()
        XCTAssertTrue(maintenanceCalls.isEmpty)
    }

    func testCredentialOnlyStartupDoesNotTreatMissingSettingsStoreAsSavedRetention() async {
        let maintenance = UITestLocalHistoryMaintenance()
        let harness = makeHarness(
            usesEphemeralSettingsStoreWhenNil: false,
            credentialStore: UITestSecureCredentialStore(),
            historyRetentionMaintenanceInterval: .milliseconds(40),
            localHistoryMaintenance: maintenance
        )

        await waitForHistoryMaintenance(harness)

        XCTAssertEqual(harness.model.recordRetentionPeriod, .thirtyDays)
        XCTAssertEqual(harness.model.history.runHistoryRetentionPeriod, .thirtyDays)
        XCTAssertFalse(harness.model.history.areHistoryRetentionSettingsAvailable)
        XCTAssertNotNil(harness.model.history.historyRetentionSettingsError)
        XCTAssertNil(harness.model.history.periodicHistoryRetentionMaintenanceTask)
        let maintenanceCalls = await maintenance.callSnapshot()
        XCTAssertTrue(maintenanceCalls.isEmpty)
    }

    func testExplicitForeverRetentionRemainsValidWithoutDamageWarning() async {
        let harness = makeHarness(
            settingsStore: UITestSettingsStore(
                storage: [
                    .recordRetentionPeriod: HistoryRetentionPeriod.forever.rawValue,
                    .runHistoryRetentionPeriod: HistoryRetentionPeriod.forever.rawValue,
                ]
            ),
            localHistoryMaintenance: UITestLocalHistoryMaintenance()
        )

        await waitForHistoryMaintenance(harness)

        XCTAssertEqual(harness.model.recordRetentionPeriod, .forever)
        XCTAssertEqual(harness.model.history.runHistoryRetentionPeriod, .forever)
        XCTAssertTrue(harness.model.history.areHistoryRetentionSettingsAvailable)
        XCTAssertNil(harness.model.history.historyRetentionSettingsError)
    }

    func testSavingDisplayedForeverRepairsInvalidRetentionState() async {
        let settingsStore = UITestSettingsStore(
            storage: [
                .recordRetentionPeriod: "damaged-value",
                .runHistoryRetentionPeriod: HistoryRetentionPeriod.thirtyDays.rawValue,
            ]
        )
        let harness = makeHarness(
            settingsStore: settingsStore,
            localHistoryMaintenance: UITestLocalHistoryMaintenance()
        )
        await harness.model.waitForInitialVoiceConfiguration()
        await harness.model.waitForLocalHistoryMaintenance()
        XCTAssertTrue(harness.model.history.clipboardHistoryRetentionSettingIsInvalid)

        harness.model.setRecordRetentionPeriod(.forever)
        await harness.model.flushPendingPersistenceWrites()

        let storedValue = try? await settingsStore.string(forKey: .recordRetentionPeriod)
        XCTAssertEqual(storedValue, HistoryRetentionPeriod.forever.rawValue)
        XCTAssertFalse(harness.model.history.clipboardHistoryRetentionSettingIsInvalid)
        XCTAssertNil(harness.model.history.historyRetentionSettingsError)
    }

    func testHistoryRetentionRoundTripsAndShorteningRunsMaintenanceAfterPersistence() async {
        let settingsStore = UITestSettingsStore()
        let maintenance = UITestLocalHistoryMaintenance()
        let harness = makeHarness(
            settingsStore: settingsStore,
            localHistoryMaintenance: maintenance
        )
        await waitForHistoryMaintenance(harness)
        await maintenance.resetCalls()

        harness.model.setRecordRetentionPeriod(.oneWeek)
        await waitForHistoryMaintenance(harness)

        let storedValue = try? await settingsStore.string(forKey: .recordRetentionPeriod)
        let maintenanceCalls = await maintenance.callSnapshot()
        XCTAssertEqual(storedValue, HistoryRetentionPeriod.oneWeek.rawValue)
        XCTAssertEqual(harness.model.recordRetentionPeriod, .oneWeek)
        XCTAssertEqual(
            maintenanceCalls,
            [.performRetention(.forever, .thirtyDays)]
        )

        let reloadedMaintenance = UITestLocalHistoryMaintenance()
        let reloadedHarness = makeHarness(
            settingsStore: settingsStore,
            localHistoryMaintenance: reloadedMaintenance
        )
        await waitForHistoryMaintenance(reloadedHarness)

        XCTAssertEqual(reloadedHarness.model.recordRetentionPeriod, .oneWeek)
        XCTAssertEqual(reloadedHarness.model.history.runHistoryRetentionPeriod, .thirtyDays)
    }

    func testRetentionPersistenceFailureDoesNotChangeSettingOrStartCleanup() async {
        let settingsStore = UITestSettingsStore(
            failingSetKeys: [.recordRetentionPeriod]
        )
        let maintenance = UITestLocalHistoryMaintenance()
        let harness = makeHarness(
            settingsStore: settingsStore,
            localHistoryMaintenance: maintenance
        )
        await harness.model.waitForInitialVoiceConfiguration()
        await harness.model.waitForLocalHistoryMaintenance()
        await maintenance.resetCalls()

        harness.model.setRecordRetentionPeriod(.oneWeek)
        await harness.model.flushPendingPersistenceWrites()

        XCTAssertEqual(harness.model.recordRetentionPeriod, .thirtyDays)
        XCTAssertNotNil(harness.model.history.historyRetentionSettingsError)
        let maintenanceCalls = await maintenance.callSnapshot()
        XCTAssertTrue(maintenanceCalls.isEmpty)
        let storedValue = try? await settingsStore.string(forKey: .recordRetentionPeriod)
        XCTAssertNil(storedValue)
    }

    func testShorterRetentionWithoutMaintenanceServiceReportsDeferredCleanup() async {
        let settingsStore = UITestSettingsStore()
        let harness = makeHarness(
            settingsStore: settingsStore,
            historyRetentionMaintenanceInterval: .milliseconds(40)
        )
        await waitForHistoryMaintenance(harness)

        harness.model.setRecordRetentionPeriod(.oneWeek)
        await waitForHistoryMaintenance(harness)

        let storedValue = try? await settingsStore.string(forKey: .recordRetentionPeriod)
        XCTAssertEqual(storedValue, HistoryRetentionPeriod.oneWeek.rawValue)
        XCTAssertEqual(harness.model.recordRetentionPeriod, .oneWeek)
        let blockedReason = harness.model.history.localHistoryMaintenanceBlockedReason ?? ""
        XCTAssertFalse(blockedReason.isEmpty)
        XCTAssertTrue(
            blockedReason.contains("saved") || blockedReason.contains("已保存")
        )
        XCTAssertNil(harness.model.history.periodicHistoryRetentionMaintenanceTask)
    }

    func testClearOperationsRemainScopedAndPublishCounts() async {
        let maintenance = UITestLocalHistoryMaintenance(
            results: [
                .completed(LocalHistoryMaintenanceCounts()),
                .completed(
                    LocalHistoryMaintenanceCounts(
                        runRemovedCount: 3,
                        diagnosticRemovedCount: 2
                    )
                ),
            ]
        )
        let harness = makeHarness(
            settingsStore: UITestSettingsStore(),
            localHistoryMaintenance: maintenance
        )
        await waitForHistoryMaintenance(harness)
        await maintenance.resetCalls()

        harness.model.clearRecordHistory()
        await waitForHistoryMaintenance(harness)

        let clipboardCalls = await maintenance.callSnapshot()
        XCTAssertTrue(clipboardCalls.isEmpty)
        XCTAssertNotNil(harness.model.recordWorkspace.cleanup.plan)
        harness.model.recordWorkspace.cleanup.cancel()
        XCTAssertEqual(harness.model.history.lastLocalHistoryRemovedCount, 0)
        XCTAssertEqual(harness.model.history.lastPreservedActiveRecordCount, 0)
        XCTAssertNil(harness.model.history.localHistoryMaintenancePendingReason)
        XCTAssertNil(harness.model.history.localHistoryMaintenanceBlockedReason)

        harness.model.history.diagnosticEvents = [
            DiagnosticEvent(
                subsystem: .session,
                level: .info,
                event: .diagnosticBeforeClear,
                message: "diagnostic-before-clear"
            ),
        ]
        harness.model.voice.lastCompletedText = "transcript-before-clear"
        harness.model.lastFailure = "failure-before-clear"
        harness.model.history.eventFeed = [
            EventFeedEntry(
                english: "content-before-clear",
                simplifiedChinese: "清理前内容"
            ),
        ]
        harness.model.voice.liveSubtitleSnapshot = LiveSubtitleSnapshot(
            runID: UUID(),
            phase: .processing,
            confirmedText: "subtitle-before-clear"
        )
        harness.model.clearRunHistory()
        await waitForHistoryMaintenance(harness)

        let allCalls = await maintenance.callSnapshot()
        XCTAssertEqual(allCalls, [.clearRun])
        XCTAssertEqual(harness.model.history.lastLocalHistoryRemovedCount, 5)
        XCTAssertEqual(harness.model.history.lastPreservedActiveRecordCount, 0)
        XCTAssertTrue(harness.model.history.diagnosticEvents.isEmpty)
        XCTAssertNil(harness.model.voice.lastCompletedText)
        XCTAssertNil(harness.model.lastFailure)
        XCTAssertTrue(harness.model.history.eventFeed.isEmpty)
        XCTAssertNil(harness.model.voice.liveSubtitleSnapshot)
    }

    func testPendingMaintenanceIsVisibleAndRetryable() async {
        let maintenance = UITestLocalHistoryMaintenance(
            results: [
                .completed(LocalHistoryMaintenanceCounts()),
                .pending(
                    LocalHistoryMaintenanceCounts(recordRemovedCount: 1),
                    .physicalPurgeFailed
                ),
                .completed(LocalHistoryMaintenanceCounts()),
            ]
        )
        let harness = makeHarness(
            settingsStore: UITestSettingsStore(),
            localHistoryMaintenance: maintenance
        )
        await waitForHistoryMaintenance(harness)
        await maintenance.resetCalls()

        harness.model.clearRunHistory()
        await waitForHistoryMaintenance(harness)

        XCTAssertNotNil(harness.model.history.localHistoryMaintenancePendingReason)
        XCTAssertNil(harness.model.history.localHistoryMaintenanceBlockedReason)

        harness.model.retryPendingLocalHistoryMaintenance()
        await waitForHistoryMaintenance(harness)

        let maintenanceCalls = await maintenance.callSnapshot()
        XCTAssertEqual(maintenanceCalls, [.clearRun, .retryPending])
        XCTAssertNil(harness.model.history.localHistoryMaintenancePendingReason)
        XCTAssertNil(harness.model.history.localHistoryMaintenanceBlockedReason)
    }

    func testActiveRunBlocksRunHistoryClear() async {
        let maintenance = UITestLocalHistoryMaintenance()
        let harness = makeHarness(
            settingsStore: UITestSettingsStore(),
            localHistoryMaintenance: maintenance
        )
        await waitForHistoryMaintenance(harness)
        await maintenance.resetCalls()
        harness.model.voice.isRunning = true

        harness.model.clearRunHistory()

        XCTAssertFalse(harness.model.canClearRunHistory)
        XCTAssertNotNil(harness.model.history.localHistoryMaintenanceBlockedReason)
        let maintenanceCalls = await maintenance.callSnapshot()
        XCTAssertTrue(maintenanceCalls.isEmpty)
    }

    func testQueuedRunBlocksRunHistoryClear() async {
        let maintenance = UITestLocalHistoryMaintenance()
        let harness = makeHarness(
            settingsStore: UITestSettingsStore(),
            localHistoryMaintenance: maintenance
        )
        await waitForHistoryMaintenance(harness)
        await maintenance.resetCalls()
        harness.model.voice.audioProcessingQueueSnapshot = AudioProcessingQueueSnapshot(
            processingRunID: UUID(),
            pendingCount: 1
        )

        harness.model.clearRunHistory()

        XCTAssertFalse(harness.model.canClearRunHistory)
        XCTAssertNotNil(harness.model.history.localHistoryMaintenanceBlockedReason)
        let maintenanceCalls = await maintenance.callSnapshot()
        XCTAssertTrue(maintenanceCalls.isEmpty)
    }

    func testBlockedMaintenanceIsVisibleAndRetryable() async {
        let maintenance = UITestLocalHistoryMaintenance(
            results: [
                .completed(LocalHistoryMaintenanceCounts()),
                .blocked(.invalidPendingState),
                .completed(LocalHistoryMaintenanceCounts()),
            ]
        )
        let harness = makeHarness(
            settingsStore: UITestSettingsStore(),
            localHistoryMaintenance: maintenance
        )
        await waitForHistoryMaintenance(harness)
        await maintenance.resetCalls()

        harness.model.clearRunHistory()
        await waitForHistoryMaintenance(harness)

        XCTAssertNil(harness.model.history.localHistoryMaintenancePendingReason)
        XCTAssertNotNil(harness.model.history.localHistoryMaintenanceBlockedReason)

        harness.model.retryPendingLocalHistoryMaintenance()
        await waitForHistoryMaintenance(harness)

        XCTAssertNil(harness.model.history.localHistoryMaintenancePendingReason)
        XCTAssertNil(harness.model.history.localHistoryMaintenanceBlockedReason)
        let maintenanceCalls = await maintenance.callSnapshot()
        XCTAssertEqual(maintenanceCalls, [.clearRun, .retryPending])
    }

    func testRetentionRequestDuringMaintenanceRunsAgainWithCurrentPeriods() async {
        let maintenance = UITestLocalHistoryMaintenance()
        let harness = makeHarness(
            settingsStore: UITestSettingsStore(),
            localHistoryMaintenance: maintenance
        )
        await waitForHistoryMaintenance(harness)
        await maintenance.resetCalls()

        harness.model.performLocalHistoryRetention(now: Date(timeIntervalSince1970: 100))
        harness.model.performLocalHistoryRetention(now: Date(timeIntervalSince1970: 200))
        XCTAssertTrue(harness.model.history.historyRetentionRerunRequested)

        await waitForHistoryMaintenance(harness)

        let maintenanceCalls = await maintenance.callSnapshot()
        XCTAssertEqual(
            maintenanceCalls,
            [
                .performRetention(.forever, .thirtyDays),
                .performRetention(.forever, .thirtyDays),
            ]
        )
        XCTAssertFalse(harness.model.history.historyRetentionRerunRequested)
        XCTAssertFalse(harness.model.history.isLocalHistoryMaintenanceRunning)
        XCTAssertTrue(harness.model.history.localHistoryMaintenanceTasks.isEmpty)
    }

    func testPeriodicRetentionMaintenanceRunsAgainAfterInitialLoad() async {
        let clock = HistoryMaintenanceClock()
        let maintenance = UITestLocalHistoryMaintenance()
        let harness = makeHarness(settingsStore: UITestSettingsStore(),
            historyRetentionMaintenanceInterval: .seconds(60),
            historyMaintenanceSleep: { try await clock.sleep(for: $0) },
            localHistoryMaintenance: maintenance)
        await waitForHistoryMaintenance(harness)
        await clock.waitUntilSleeping()
        let initial = await maintenance.callSnapshot()
        XCTAssertEqual(initial.count, 1)
        await clock.advance()
        await clock.waitUntilSleeping()
        await harness.model.waitForLocalHistoryMaintenance()
        let calls = await maintenance.callSnapshot()
        XCTAssertEqual(calls.count, 2)
        await harness.model.stopLocalHistoryMaintenanceForApplicationShutdown()
        let pending = await clock.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testShutdownWaitsForActiveHistoryMaintenanceWithoutCancellingIt() async {
        let maintenance = ShutdownBlockingLocalHistoryMaintenance()
        let harness = makeHarness(
            settingsStore: UITestSettingsStore(),
            historyRetentionMaintenanceInterval: .seconds(60),
            localHistoryMaintenance: maintenance
        )
        await maintenance.waitUntilCallCount(reaches: 1)
        XCTAssertTrue(harness.model.history.isLocalHistoryMaintenanceRunning)
        XCTAssertEqual(harness.model.history.localHistoryMaintenanceTasks.count, 1)

        let completion = HistoryShutdownCompletionProbe()
        let shutdownTask = Task { @MainActor in
            await harness.model.stopLocalHistoryMaintenanceForApplicationShutdown()
            await completion.markCompleted()
        }
        while !harness.model.hasBegunApplicationShutdown {
            await Task.yield()
        }

        let completedWhileMaintenanceWasBlocked = await completion.isCompleted()
        XCTAssertFalse(completedWhileMaintenanceWasBlocked)
        XCTAssertTrue(harness.model.history.isLocalHistoryMaintenanceRunning)

        await maintenance.release()
        await shutdownTask.value

        let completedAfterMaintenanceWasReleased = await completion.isCompleted()
        XCTAssertTrue(completedAfterMaintenanceWasReleased)
        XCTAssertFalse(harness.model.history.isLocalHistoryMaintenanceRunning)
        XCTAssertTrue(harness.model.history.localHistoryMaintenanceTasks.isEmpty)
        XCTAssertNil(harness.model.history.periodicHistoryRetentionMaintenanceTask)
        XCTAssertFalse(harness.model.history.historyRetentionRerunRequested)
        XCTAssertFalse(harness.model.history.shouldStartPeriodicHistoryRetentionMaintenance)
        let didObserveCancellation = await maintenance.didObserveCancellation()
        XCTAssertFalse(didObserveCancellation)

        harness.model.clearRecordHistory()
        harness.model.retryPendingLocalHistoryMaintenance()
        harness.model.performLocalHistoryRetention()
        let calls = await maintenance.callSnapshot()
        XCTAssertEqual(calls, [.performRetention(.forever, .thirtyDays)])
    }

    func testShutdownDrainsProjectionReadStartedByMaintenanceCompletion() async {
        let readLatch = ShutdownProjectionReadLatch()
        let maintenance = UITestLocalHistoryMaintenance()
        let harness = makeHarness(
            historyRepository: ShutdownProjectionHistoryRepository(readLatch: readLatch),
            localHistoryMaintenance: maintenance
        )
        await readLatch.waitUntilReadCount(reaches: 1)
        await maintenance.resetCalls()

        readLatch.blockNextRead()
        harness.model.clearRunHistory()
        await readLatch.waitUntilReadCount(reaches: 2)
        XCTAssertFalse(harness.model.history.historyProjectionLoadTasks.isEmpty)

        let completion = HistoryShutdownCompletionProbe()
        let shutdownTask = Task { @MainActor in
            await harness.model.stopLocalHistoryMaintenanceForApplicationShutdown()
            await completion.markCompleted()
        }
        await readLatch.waitUntilCancellationIsObserved()

        let completedWhileProjectionReadWasBlocked = await completion.isCompleted()
        XCTAssertFalse(completedWhileProjectionReadWasBlocked)

        readLatch.releaseBlockedReads()
        await shutdownTask.value

        let completedAfterProjectionReadWasReleased = await completion.isCompleted()
        XCTAssertTrue(completedAfterProjectionReadWasReleased)
        XCTAssertTrue(harness.model.history.historyProjectionLoadTasks.isEmpty)
        XCTAssertFalse(harness.model.history.isLocalHistoryMaintenanceRunning)
        let calls = await maintenance.callSnapshot()
        XCTAssertEqual(calls, [.clearRun])
    }

    func testRetentionWriteCompletionCannotStartProjectionLoadAfterShutdown() async {
        let settingsStore = ShutdownRetentionSettingsStore()
        let readLatch = ShutdownProjectionReadLatch()
        let harness = makeHarness(
            settingsStore: settingsStore,
            historyRepository: ShutdownProjectionHistoryRepository(readLatch: readLatch)
        )
        await readLatch.waitUntilReadCount(reaches: 2)
        let readCountBeforeWrite = readLatch.currentReadCount()

        await settingsStore.blockNextRunRetentionWrite()
        harness.model.setRunHistoryRetentionPeriod(.forever)
        await settingsStore.waitUntilRunRetentionWriteStarts()

        await harness.model.stopLocalHistoryMaintenanceForApplicationShutdown()
        await settingsStore.releaseRunRetentionWrites()
        await harness.model.flushPendingPersistenceWrites()

        XCTAssertEqual(readLatch.currentReadCount(), readCountBeforeWrite)
        XCTAssertEqual(harness.model.history.runHistoryRetentionPeriod, .thirtyDays)
        XCTAssertTrue(harness.model.history.historyProjectionLoadTasks.isEmpty)
        let writeCountBeforeRejectedMutation = await settingsStore.runRetentionWriteCount()

        harness.model.setRunHistoryRetentionPeriod(.oneWeek)
        await harness.model.flushPendingPersistenceWrites()

        let writeCountAfterRejectedMutation = await settingsStore.runRetentionWriteCount()
        XCTAssertEqual(writeCountAfterRejectedMutation, writeCountBeforeRejectedMutation)
    }

    func testLateInitialSettingsSnapshotCannotStartHistoryMaintenanceAfterShutdown() async {
        let settingsStore = UITestSettingsStore(suspendBatchReads: true)
        let maintenance = UITestLocalHistoryMaintenance()
        let harness = makeHarness(
            settingsStore: settingsStore,
            historyRetentionMaintenanceInterval: .milliseconds(20),
            localHistoryMaintenance: maintenance
        )
        await settingsStore.waitUntilBatchReadIsSuspended()

        let settingsReadStop = Task { @MainActor in
            await harness.model.stopSettingsReadTasksForApplicationShutdown()
        }
        await Task.yield()
        await harness.model.stopLocalHistoryMaintenanceForApplicationShutdown()
        await settingsStore.resumeBatchRead()
        await settingsReadStop.value
        await waitForHistoryMaintenance(harness)

        XCTAssertFalse(harness.model.settings.isLoading)
        XCTAssertTrue(harness.model.history.localHistoryMaintenanceTasks.isEmpty)
        XCTAssertNil(harness.model.history.periodicHistoryRetentionMaintenanceTask)
        let calls = await maintenance.callSnapshot()
        XCTAssertTrue(calls.isEmpty)
    }

    func testShutdownCancelsExistingPeriodicHistoryMaintenanceTimer() async {
        let maintenance = UITestLocalHistoryMaintenance()
        let harness = makeHarness(
            settingsStore: UITestSettingsStore(),
            historyRetentionMaintenanceInterval: .seconds(60),
            localHistoryMaintenance: maintenance
        )
        await harness.model.waitForInitialVoiceConfiguration()
        await harness.model.waitForLocalHistoryMaintenance()
        XCTAssertNotNil(harness.model.history.periodicHistoryRetentionMaintenanceTask)

        await harness.model.stopLocalHistoryMaintenanceForApplicationShutdown()

        XCTAssertNil(harness.model.history.periodicHistoryRetentionMaintenanceTask)
        XCTAssertTrue(harness.model.history.localHistoryMaintenanceTasks.isEmpty)
        let calls = await maintenance.callSnapshot()
        XCTAssertEqual(calls, [.performRetention(.forever, .thirtyDays)])
    }
}
