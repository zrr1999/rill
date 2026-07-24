import XCTest
@testable import RillCore
@testable import RillRuntime
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
        clipboardRetention: HistoryRetentionPeriod,
        runRetention: HistoryRetentionPeriod,
        now: Date
    ) async -> LocalHistoryMaintenanceResult {
        await recordAndWait(.performRetention(clipboardRetention, runRetention))
    }

    func clearClipboardHistory() async -> LocalHistoryMaintenanceResult {
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
    let readLatch: ShutdownProjectionReadLatch

    func save(_ record: HistoryRecord) async throws {}

    func records(matching query: HistoryQuery) async throws -> [HistoryRecord] {
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

        await waitForEventProcessing()

        XCTAssertEqual(harness.model.clipboardHistoryRetentionPeriod, .thirtyDays)
        XCTAssertEqual(harness.model.runHistoryRetentionPeriod, .thirtyDays)
    }

    func testRetentionMutationIsRejectedWhileInitialSettingsReadIsPending() async {
        let settingsStore = UITestSettingsStore(
            storage: [
                .clipboardHistoryRetentionPeriod: HistoryRetentionPeriod.oneDay.rawValue,
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
        XCTAssertTrue(harness.model.isLoadingSettings)

        harness.model.setClipboardHistoryRetentionPeriod(.forever)
        await Task.yield()

        let activityBeforeResume = await settingsStore.activitySnapshot()
        let maintenanceBeforeResume = await maintenance.callSnapshot()
        XCTAssertNil(activityBeforeResume.setCounts[.clipboardHistoryRetentionPeriod])
        XCTAssertTrue(maintenanceBeforeResume.isEmpty)
        XCTAssertEqual(harness.model.clipboardHistoryRetentionPeriod, .thirtyDays)

        await settingsStore.resumeBatchRead()
        await waitForEventProcessing()

        XCTAssertFalse(harness.model.isLoadingSettings)
        XCTAssertEqual(harness.model.clipboardHistoryRetentionPeriod, .oneDay)
        let storedValue = try? await settingsStore.string(
            forKey: .clipboardHistoryRetentionPeriod
        )
        XCTAssertEqual(storedValue, HistoryRetentionPeriod.oneDay.rawValue)
    }

    func testInvalidHistoryRetentionFailsSafeToForever() async {
        let settingsStore = UITestSettingsStore(
            storage: [
                .clipboardHistoryRetentionPeriod: "invalid-clipboard-retention",
                .runHistoryRetentionPeriod: "invalid-run-retention",
            ]
        )
        let harness = makeHarness(settingsStore: settingsStore)

        await waitForEventProcessing()

        XCTAssertEqual(harness.model.clipboardHistoryRetentionPeriod, .forever)
        XCTAssertEqual(harness.model.runHistoryRetentionPeriod, .forever)
        XCTAssertTrue(harness.model.areHistoryRetentionSettingsAvailable)
        XCTAssertNotNil(harness.model.historyRetentionSettingsError)
        XCTAssertTrue(
            harness.model.historyRetentionSettingsError?.contains("暂停") == true ||
                harness.model.historyRetentionSettingsError?.contains("paused") == true
        )
    }

    func testUnreadableRetentionSettingPausesOnlyItsDomain() async {
        let settingsStore = UITestSettingsStore(
            storage: [
                .clipboardHistoryRetentionPeriod: "damaged-protected-value",
                .runHistoryRetentionPeriod: HistoryRetentionPeriod.oneWeek.rawValue,
            ],
            unavailableKeys: [.clipboardHistoryRetentionPeriod]
        )
        let harness = makeHarness(settingsStore: settingsStore)

        await waitForEventProcessing()

        XCTAssertEqual(harness.model.clipboardHistoryRetentionPeriod, .forever)
        XCTAssertEqual(harness.model.runHistoryRetentionPeriod, .oneWeek)
        XCTAssertTrue(harness.model.areHistoryRetentionSettingsAvailable)
        XCTAssertNotNil(harness.model.historyRetentionSettingsError)
        let activity = await settingsStore.activitySnapshot()
        XCTAssertEqual(
            activity.storage[.clipboardHistoryRetentionPeriod],
            "damaged-protected-value"
        )
        XCTAssertNil(activity.setCounts[.clipboardHistoryRetentionPeriod])
        XCTAssertNil(activity.removeCounts[.clipboardHistoryRetentionPeriod])
    }

    func testSettingsReadFailurePausesCleanupWithoutPresentingForeverAsUserChoice() async {
        let settingsStore = UITestSettingsStore(failBatchReads: true)
        let maintenance = UITestLocalHistoryMaintenance()
        let harness = makeHarness(
            settingsStore: settingsStore,
            historyRetentionMaintenanceInterval: .milliseconds(40),
            localHistoryMaintenance: maintenance
        )

        await waitForEventProcessing()
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(harness.model.clipboardHistoryRetentionPeriod, .thirtyDays)
        XCTAssertEqual(harness.model.runHistoryRetentionPeriod, .thirtyDays)
        XCTAssertFalse(harness.model.areHistoryRetentionSettingsAvailable)
        XCTAssertNotNil(harness.model.historyRetentionSettingsError)
        XCTAssertNil(harness.model.periodicHistoryRetentionMaintenanceTask)
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

        await waitForEventProcessing()
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(harness.model.clipboardHistoryRetentionPeriod, .thirtyDays)
        XCTAssertEqual(harness.model.runHistoryRetentionPeriod, .thirtyDays)
        XCTAssertFalse(harness.model.areHistoryRetentionSettingsAvailable)
        XCTAssertNotNil(harness.model.historyRetentionSettingsError)
        XCTAssertNil(harness.model.periodicHistoryRetentionMaintenanceTask)
        let maintenanceCalls = await maintenance.callSnapshot()
        XCTAssertTrue(maintenanceCalls.isEmpty)
    }

    func testExplicitForeverRetentionRemainsValidWithoutDamageWarning() async {
        let harness = makeHarness(
            settingsStore: UITestSettingsStore(
                storage: [
                    .clipboardHistoryRetentionPeriod: HistoryRetentionPeriod.forever.rawValue,
                    .runHistoryRetentionPeriod: HistoryRetentionPeriod.forever.rawValue,
                ]
            ),
            localHistoryMaintenance: UITestLocalHistoryMaintenance()
        )

        await waitForEventProcessing()

        XCTAssertEqual(harness.model.clipboardHistoryRetentionPeriod, .forever)
        XCTAssertEqual(harness.model.runHistoryRetentionPeriod, .forever)
        XCTAssertTrue(harness.model.areHistoryRetentionSettingsAvailable)
        XCTAssertNil(harness.model.historyRetentionSettingsError)
    }

    func testSavingDisplayedForeverRepairsInvalidRetentionState() async {
        let settingsStore = UITestSettingsStore(
            storage: [
                .clipboardHistoryRetentionPeriod: "damaged-value",
                .runHistoryRetentionPeriod: HistoryRetentionPeriod.thirtyDays.rawValue,
            ]
        )
        let harness = makeHarness(
            settingsStore: settingsStore,
            localHistoryMaintenance: UITestLocalHistoryMaintenance()
        )
        await waitForEventProcessing()
        XCTAssertTrue(harness.model.clipboardHistoryRetentionSettingIsInvalid)

        harness.model.setClipboardHistoryRetentionPeriod(.forever)
        await waitForEventProcessing()

        let storedValue = try? await settingsStore.string(forKey: .clipboardHistoryRetentionPeriod)
        XCTAssertEqual(storedValue, HistoryRetentionPeriod.forever.rawValue)
        XCTAssertFalse(harness.model.clipboardHistoryRetentionSettingIsInvalid)
        XCTAssertNil(harness.model.historyRetentionSettingsError)
    }

    func testHistoryRetentionRoundTripsAndShorteningRunsMaintenanceAfterPersistence() async {
        let settingsStore = UITestSettingsStore()
        let maintenance = UITestLocalHistoryMaintenance()
        let harness = makeHarness(
            settingsStore: settingsStore,
            localHistoryMaintenance: maintenance
        )
        await waitForEventProcessing()
        await maintenance.resetCalls()

        harness.model.setClipboardHistoryRetentionPeriod(.oneWeek)
        await waitForEventProcessing()

        let storedValue = try? await settingsStore.string(forKey: .clipboardHistoryRetentionPeriod)
        let maintenanceCalls = await maintenance.callSnapshot()
        XCTAssertEqual(storedValue, HistoryRetentionPeriod.oneWeek.rawValue)
        XCTAssertEqual(harness.model.clipboardHistoryRetentionPeriod, .oneWeek)
        XCTAssertEqual(
            maintenanceCalls,
            [.performRetention(.oneWeek, .thirtyDays)]
        )

        let reloadedMaintenance = UITestLocalHistoryMaintenance()
        let reloadedHarness = makeHarness(
            settingsStore: settingsStore,
            localHistoryMaintenance: reloadedMaintenance
        )
        await waitForEventProcessing()

        XCTAssertEqual(reloadedHarness.model.clipboardHistoryRetentionPeriod, .oneWeek)
        XCTAssertEqual(reloadedHarness.model.runHistoryRetentionPeriod, .thirtyDays)
    }

    func testRetentionPersistenceFailureDoesNotChangeSettingOrStartCleanup() async {
        let settingsStore = UITestSettingsStore(
            failingSetKeys: [.clipboardHistoryRetentionPeriod]
        )
        let maintenance = UITestLocalHistoryMaintenance()
        let harness = makeHarness(
            settingsStore: settingsStore,
            localHistoryMaintenance: maintenance
        )
        await waitForEventProcessing()
        await maintenance.resetCalls()

        harness.model.setClipboardHistoryRetentionPeriod(.oneWeek)
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.clipboardHistoryRetentionPeriod, .thirtyDays)
        XCTAssertNotNil(harness.model.historyRetentionSettingsError)
        let maintenanceCalls = await maintenance.callSnapshot()
        XCTAssertTrue(maintenanceCalls.isEmpty)
        let storedValue = try? await settingsStore.string(forKey: .clipboardHistoryRetentionPeriod)
        XCTAssertNil(storedValue)
    }

    func testShorterRetentionWithoutMaintenanceServiceReportsDeferredCleanup() async {
        let settingsStore = UITestSettingsStore()
        let harness = makeHarness(
            settingsStore: settingsStore,
            historyRetentionMaintenanceInterval: .milliseconds(40)
        )
        await waitForEventProcessing()

        harness.model.setClipboardHistoryRetentionPeriod(.oneWeek)
        await waitForEventProcessing()

        let storedValue = try? await settingsStore.string(forKey: .clipboardHistoryRetentionPeriod)
        XCTAssertEqual(storedValue, HistoryRetentionPeriod.oneWeek.rawValue)
        XCTAssertEqual(harness.model.clipboardHistoryRetentionPeriod, .oneWeek)
        let blockedReason = harness.model.localHistoryMaintenanceBlockedReason ?? ""
        XCTAssertFalse(blockedReason.isEmpty)
        XCTAssertTrue(
            blockedReason.contains("saved") || blockedReason.contains("已保存")
        )
        XCTAssertNil(harness.model.periodicHistoryRetentionMaintenanceTask)
    }

    func testClearOperationsRemainScopedAndPublishCounts() async {
        let maintenance = UITestLocalHistoryMaintenance(
            results: [
                .completed(LocalHistoryMaintenanceCounts()),
                .completed(
                    LocalHistoryMaintenanceCounts(
                        clipboardRemovedCount: 2,
                        preservedActiveClipboardCount: 1
                    )
                ),
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
        await waitForEventProcessing()
        await maintenance.resetCalls()

        harness.model.clearClipboardHistory()
        await waitForEventProcessing()

        let clipboardCalls = await maintenance.callSnapshot()
        XCTAssertEqual(clipboardCalls, [.clearClipboard])
        XCTAssertEqual(harness.model.lastLocalHistoryRemovedCount, 2)
        XCTAssertEqual(harness.model.lastPreservedActiveClipboardCount, 1)
        XCTAssertNil(harness.model.localHistoryMaintenancePendingReason)
        XCTAssertNil(harness.model.localHistoryMaintenanceBlockedReason)

        harness.model.diagnosticEvents = [
            DiagnosticEvent(
                subsystem: .session,
                level: .info,
                event: "diagnostic.before-clear",
                message: "diagnostic-before-clear"
            ),
        ]
        harness.model.lastCompletedText = "transcript-before-clear"
        harness.model.lastFailure = "failure-before-clear"
        harness.model.deepgramTestTranscript = "deepgram-before-clear"
        harness.model.deepgramTestError = "deepgram-error-before-clear"
        harness.model.eventFeed = [
            EventFeedEntry(
                english: "content-before-clear",
                simplifiedChinese: "清理前内容"
            ),
        ]
        harness.model.liveSubtitleSnapshot = LiveSubtitleSnapshot(
            runID: UUID(),
            phase: .processing,
            confirmedText: "subtitle-before-clear"
        )
        harness.model.clearRunHistory()
        await waitForEventProcessing()

        let allCalls = await maintenance.callSnapshot()
        XCTAssertEqual(allCalls, [.clearClipboard, .clearRun])
        XCTAssertEqual(harness.model.lastLocalHistoryRemovedCount, 5)
        XCTAssertEqual(harness.model.lastPreservedActiveClipboardCount, 0)
        XCTAssertTrue(harness.model.diagnosticEvents.isEmpty)
        XCTAssertNil(harness.model.lastCompletedText)
        XCTAssertNil(harness.model.lastFailure)
        XCTAssertNil(harness.model.deepgramTestTranscript)
        XCTAssertNil(harness.model.deepgramTestError)
        XCTAssertTrue(harness.model.eventFeed.isEmpty)
        XCTAssertNil(harness.model.liveSubtitleSnapshot)
    }

    func testPendingMaintenanceIsVisibleAndRetryable() async {
        let maintenance = UITestLocalHistoryMaintenance(
            results: [
                .completed(LocalHistoryMaintenanceCounts()),
                .pending(
                    LocalHistoryMaintenanceCounts(clipboardRemovedCount: 1),
                    .physicalPurgeFailed
                ),
                .completed(LocalHistoryMaintenanceCounts()),
            ]
        )
        let harness = makeHarness(
            settingsStore: UITestSettingsStore(),
            localHistoryMaintenance: maintenance
        )
        await waitForEventProcessing()
        await maintenance.resetCalls()

        harness.model.clearClipboardHistory()
        await waitForEventProcessing()

        XCTAssertNotNil(harness.model.localHistoryMaintenancePendingReason)
        XCTAssertNil(harness.model.localHistoryMaintenanceBlockedReason)

        harness.model.retryPendingLocalHistoryMaintenance()
        await waitForEventProcessing()

        let maintenanceCalls = await maintenance.callSnapshot()
        XCTAssertEqual(maintenanceCalls, [.clearClipboard, .retryPending])
        XCTAssertNil(harness.model.localHistoryMaintenancePendingReason)
        XCTAssertNil(harness.model.localHistoryMaintenanceBlockedReason)
    }

    func testActiveRunBlocksRunHistoryClear() async {
        let maintenance = UITestLocalHistoryMaintenance()
        let harness = makeHarness(
            settingsStore: UITestSettingsStore(),
            localHistoryMaintenance: maintenance
        )
        await waitForEventProcessing()
        await maintenance.resetCalls()
        harness.model.isRunning = true

        harness.model.clearRunHistory()

        XCTAssertFalse(harness.model.canClearRunHistory)
        XCTAssertNotNil(harness.model.localHistoryMaintenanceBlockedReason)
        let maintenanceCalls = await maintenance.callSnapshot()
        XCTAssertTrue(maintenanceCalls.isEmpty)
    }

    func testQueuedRunBlocksRunHistoryClear() async {
        let maintenance = UITestLocalHistoryMaintenance()
        let harness = makeHarness(
            settingsStore: UITestSettingsStore(),
            localHistoryMaintenance: maintenance
        )
        await waitForEventProcessing()
        await maintenance.resetCalls()
        harness.model.audioProcessingQueueSnapshot = AudioProcessingQueueSnapshot(
            processingRunID: UUID(),
            pendingCount: 1
        )

        harness.model.clearRunHistory()

        XCTAssertFalse(harness.model.canClearRunHistory)
        XCTAssertNotNil(harness.model.localHistoryMaintenanceBlockedReason)
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
        await waitForEventProcessing()
        await maintenance.resetCalls()

        harness.model.clearClipboardHistory()
        await waitForEventProcessing()

        XCTAssertNil(harness.model.localHistoryMaintenancePendingReason)
        XCTAssertNotNil(harness.model.localHistoryMaintenanceBlockedReason)

        harness.model.retryPendingLocalHistoryMaintenance()
        await waitForEventProcessing()

        XCTAssertNil(harness.model.localHistoryMaintenancePendingReason)
        XCTAssertNil(harness.model.localHistoryMaintenanceBlockedReason)
        let maintenanceCalls = await maintenance.callSnapshot()
        XCTAssertEqual(maintenanceCalls, [.clearClipboard, .retryPending])
    }

    func testRetentionRequestDuringMaintenanceRunsAgainWithCurrentPeriods() async {
        let maintenance = UITestLocalHistoryMaintenance(delay: .milliseconds(80))
        let harness = makeHarness(
            settingsStore: UITestSettingsStore(),
            localHistoryMaintenance: maintenance
        )
        try? await Task.sleep(for: .milliseconds(120))
        await maintenance.resetCalls()

        harness.model.performLocalHistoryRetention(now: Date(timeIntervalSince1970: 100))
        harness.model.performLocalHistoryRetention(now: Date(timeIntervalSince1970: 200))
        XCTAssertTrue(harness.model.historyRetentionRerunRequested)

        try? await Task.sleep(for: .milliseconds(220))

        let maintenanceCalls = await maintenance.callSnapshot()
        XCTAssertEqual(
            maintenanceCalls,
            [
                .performRetention(.thirtyDays, .thirtyDays),
                .performRetention(.thirtyDays, .thirtyDays),
            ]
        )
        XCTAssertFalse(harness.model.historyRetentionRerunRequested)
        XCTAssertFalse(harness.model.isLocalHistoryMaintenanceRunning)
        XCTAssertTrue(harness.model.localHistoryMaintenanceTasks.isEmpty)
    }

    func testPeriodicRetentionMaintenanceRunsAgainAfterInitialLoad() async {
        let maintenance = UITestLocalHistoryMaintenance()
        let harness = makeHarness(
            settingsStore: UITestSettingsStore(),
            historyRetentionMaintenanceInterval: .milliseconds(40),
            localHistoryMaintenance: maintenance
        )

        try? await Task.sleep(for: .milliseconds(150))

        let maintenanceCalls = await maintenance.callSnapshot()
        let retentionCalls = maintenanceCalls.filter { call in
            if case .performRetention = call { return true }
            return false
        }
        XCTAssertGreaterThanOrEqual(retentionCalls.count, 2)
        XCTAssertTrue(harness.model.isLocalHistoryMaintenanceAvailable)
    }

    func testShutdownWaitsForActiveHistoryMaintenanceWithoutCancellingIt() async {
        let maintenance = ShutdownBlockingLocalHistoryMaintenance()
        let harness = makeHarness(
            settingsStore: UITestSettingsStore(),
            historyRetentionMaintenanceInterval: .seconds(60),
            localHistoryMaintenance: maintenance
        )
        await maintenance.waitUntilCallCount(reaches: 1)
        XCTAssertTrue(harness.model.isLocalHistoryMaintenanceRunning)
        XCTAssertEqual(harness.model.localHistoryMaintenanceTasks.count, 1)

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
        XCTAssertTrue(harness.model.isLocalHistoryMaintenanceRunning)

        await maintenance.release()
        await shutdownTask.value

        let completedAfterMaintenanceWasReleased = await completion.isCompleted()
        XCTAssertTrue(completedAfterMaintenanceWasReleased)
        XCTAssertFalse(harness.model.isLocalHistoryMaintenanceRunning)
        XCTAssertTrue(harness.model.localHistoryMaintenanceTasks.isEmpty)
        XCTAssertNil(harness.model.periodicHistoryRetentionMaintenanceTask)
        XCTAssertFalse(harness.model.historyRetentionRerunRequested)
        XCTAssertFalse(harness.model.shouldStartPeriodicHistoryRetentionMaintenance)
        let didObserveCancellation = await maintenance.didObserveCancellation()
        XCTAssertFalse(didObserveCancellation)

        harness.model.clearClipboardHistory()
        harness.model.retryPendingLocalHistoryMaintenance()
        harness.model.performLocalHistoryRetention()
        let calls = await maintenance.callSnapshot()
        XCTAssertEqual(calls, [.performRetention(.thirtyDays, .thirtyDays)])
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
        XCTAssertFalse(harness.model.historyProjectionLoadTasks.isEmpty)

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
        XCTAssertTrue(harness.model.historyProjectionLoadTasks.isEmpty)
        XCTAssertFalse(harness.model.isLocalHistoryMaintenanceRunning)
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
        XCTAssertEqual(harness.model.runHistoryRetentionPeriod, .thirtyDays)
        XCTAssertTrue(harness.model.historyProjectionLoadTasks.isEmpty)
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
        await waitForEventProcessing()

        XCTAssertFalse(harness.model.isLoadingSettings)
        XCTAssertTrue(harness.model.localHistoryMaintenanceTasks.isEmpty)
        XCTAssertNil(harness.model.periodicHistoryRetentionMaintenanceTask)
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
        await waitForEventProcessing()
        XCTAssertNotNil(harness.model.periodicHistoryRetentionMaintenanceTask)

        await harness.model.stopLocalHistoryMaintenanceForApplicationShutdown()

        XCTAssertNil(harness.model.periodicHistoryRetentionMaintenanceTask)
        XCTAssertTrue(harness.model.localHistoryMaintenanceTasks.isEmpty)
        let calls = await maintenance.callSnapshot()
        XCTAssertEqual(calls, [.performRetention(.thirtyDays, .thirtyDays)])
    }
}
