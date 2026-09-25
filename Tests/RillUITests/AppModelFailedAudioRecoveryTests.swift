import Foundation
import XCTest
@testable import RillCore
@testable import RillRuntime
@testable import RillUI

private actor FailedAudioRecoveryActionProbe {
    private(set) var refreshValues: [Bool] = []
    private(set) var retries: [(UUID, UUID)] = []
    private(set) var deletedIDs: [UUID] = []
    private(set) var clearCount = 0

    func recordRefresh(_ isEnabled: Bool) {
        refreshValues.append(isEnabled)
    }

    func recordRetry(id: UUID, workflowID: UUID) {
        retries.append((id, workflowID))
    }

    func recordDelete(_ id: UUID) {
        deletedIDs.append(id)
    }

    func recordClear() {
        clearCount += 1
    }
}

private actor CancellationIgnoringFailedAudioRecoveryRetry {
    private var didStart = false
    private var didObserveCancellation = false
    private var invocationCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<
        FailedAudioRecoveryController.RetryResult,
        Never
    >?

    func run() async -> FailedAudioRecoveryController.RetryResult {
        invocationCount += 1
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion = continuation
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilCancellationObserved() async {
        guard !didObserveCancellation else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    func release() {
        completion?.resume(returning: .completed)
        completion = nil
    }

    func count() -> Int {
        invocationCount
    }

    private func recordCancellation() {
        guard !didObserveCancellation else { return }
        didObserveCancellation = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor CancellationIgnoringFailedAudioRecoveryLoad {
    private var didStart = false
    private var didObserveCancellation = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<[FailedAudioRecoveryReceipt], Never>?

    func run() async -> [FailedAudioRecoveryReceipt] {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion = continuation
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilCancellationObserved() async {
        guard !didObserveCancellation else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    func release(with receipts: [FailedAudioRecoveryReceipt]) {
        completion?.resume(returning: receipts)
        completion = nil
    }

    private func recordCancellation() {
        didObserveCancellation = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor FailedAudioRecoveryShutdownCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private actor RollbackFailingRecoverySettingsStore: SettingsStore {
    private var storage: [AppSettingKey: String] = [:]
    private var recoveryWriteCount = 0

    func string(forKey key: AppSettingKey) async throws -> String? {
        storage[key]
    }

    func strings(forKeys keys: [AppSettingKey]) async throws -> [AppSettingKey: String] {
        keys.reduce(into: [:]) { result, key in result[key] = storage[key] }
    }

    func setString(_ value: String, forKey key: AppSettingKey) async throws {
        if key == .failedAudioRecoveryEnabled {
            recoveryWriteCount += 1
            if recoveryWriteCount == 2 {
                throw UITestSettingsStoreError.requestedFailure
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
}

@MainActor
extension AppModelTests {
    func testFailedAudioRecoveryMutationIsRejectedDuringInitialSettingsRead() async {
        let settingsStore = UITestSettingsStore(
            storage: [.failedAudioRecoveryEnabled: "true"],
            suspendBatchReads: true
        )
        let probe = FailedAudioRecoveryActionProbe()
        let harness = makeHarness(
            settingsStore: settingsStore,
            refreshFailedAudioRecoveryAction: { isEnabled in
                await probe.recordRefresh(isEnabled)
            }
        )
        await settingsStore.waitUntilBatchReadIsSuspended()

        harness.model.setFailedAudioRecoveryEnabled(true)
        await Task.yield()

        var activity = await settingsStore.activitySnapshot()
        let refreshValuesBeforeLoad = await probe.refreshValues
        XCTAssertNil(activity.setCounts[.failedAudioRecoveryEnabled])
        XCTAssertFalse(harness.model.voice.failedAudioRecoveryEnabled)
        XCTAssertTrue(refreshValuesBeforeLoad.isEmpty)

        await settingsStore.resumeBatchRead()
        await waitForFailedAudioRecovery(harness)

        activity = await settingsStore.activitySnapshot()
        let refreshValuesAfterLoad = await probe.refreshValues
        XCTAssertTrue(harness.model.voice.failedAudioRecoveryEnabled)
        XCTAssertNil(activity.setCounts[.failedAudioRecoveryEnabled])
        XCTAssertTrue(refreshValuesAfterLoad.isEmpty)
    }

    func testFailedAudioRecoveryIsDefaultOffAndPersistsExplicitChanges() async throws {
        let settingsStore = UITestSettingsStore()
        let probe = FailedAudioRecoveryActionProbe()
        let harness = makeHarness(
            settingsStore: settingsStore,
            refreshFailedAudioRecoveryAction: { isEnabled in
                await probe.recordRefresh(isEnabled)
            }
        )
        await waitForFailedAudioRecovery(harness)

        XCTAssertFalse(harness.model.voice.failedAudioRecoveryEnabled)

        harness.model.setFailedAudioRecoveryEnabled(true)
        await waitForFailedAudioRecovery(harness)
        XCTAssertTrue(harness.model.voice.failedAudioRecoveryEnabled)
        let enabledValue = try await settingsStore.string(
            forKey: .failedAudioRecoveryEnabled
        )
        XCTAssertEqual(enabledValue, "true")

        harness.model.setFailedAudioRecoveryEnabled(false)
        await waitForFailedAudioRecovery(harness)
        XCTAssertFalse(harness.model.voice.failedAudioRecoveryEnabled)
        let disabledValue = try await settingsStore.string(
            forKey: .failedAudioRecoveryEnabled
        )
        XCTAssertEqual(disabledValue, "false")
        let refreshValues = await probe.refreshValues
        XCTAssertEqual(refreshValues, [true, false])
    }

    func testFailedAudioRecoveryPersistenceFailureCannotCreateInMemoryOptIn() async {
        let settingsStore = UITestSettingsStore(
            failingSetKeys: [.failedAudioRecoveryEnabled]
        )
        let probe = FailedAudioRecoveryActionProbe()
        let harness = makeHarness(
            settingsStore: settingsStore,
            refreshFailedAudioRecoveryAction: { isEnabled in
                await probe.recordRefresh(isEnabled)
            }
        )
        await waitForFailedAudioRecovery(harness)

        harness.model.setFailedAudioRecoveryEnabled(true)
        await waitForFailedAudioRecovery(harness)

        XCTAssertFalse(harness.model.voice.failedAudioRecoveryEnabled)
        XCTAssertNotNil(harness.model.voice.failedAudioRecoveryError)
        let refreshValues = await probe.refreshValues
        XCTAssertTrue(refreshValues.isEmpty)
    }

    func testEnableRollbackFailureKeepsUIAlignedWithDurableOptInAndWarnsRuntimeIsOff() async {
        let settingsStore = RollbackFailingRecoverySettingsStore()
        let harness = makeHarness(
            settingsStore: settingsStore,
            refreshFailedAudioRecoveryAction: { _ in
                throw FailedAudioRecoveryError.storageUnavailable
            }
        )
        await harness.model.waitForInitialVoiceConfiguration()
        await harness.model.waitForFailedAudioRecoveryLoad()
        harness.model.applyLanguage(.english)

        harness.model.setFailedAudioRecoveryEnabled(true)
        await harness.model.flushPendingPersistenceWrites()

        XCTAssertTrue(harness.model.voice.failedAudioRecoveryEnabled)
        let persistedValue = try? await settingsStore.string(
            forKey: .failedAudioRecoveryEnabled
        )
        XCTAssertEqual(persistedValue, "true")
        XCTAssertTrue(
            harness.model.voice.failedAudioRecoveryError?.contains("No new failed audio") ?? false
        )
    }

    func testEnabledStartupLoadsEncryptedRecoveryReceiptsDirectly() async {
        let workflow = makeDefaultWorkflow()
        let receipt = makeFailedAudioRecoveryReceipt(workflowID: workflow.id)
        let harness = makeHarness(
            workflow: workflow,
            settingsStore: UITestSettingsStore(
                storage: [.failedAudioRecoveryEnabled: "true"]
            ),
            loadFailedAudioRecoveryReceiptsAction: { [receipt] in [receipt] }
        )

        await harness.model.waitForInitialVoiceConfiguration()
        await harness.model.waitForFailedAudioRecoveryLoad()

        XCTAssertTrue(harness.model.voice.failedAudioRecoveryEnabled)
        XCTAssertEqual(harness.model.voice.failedAudioRecoveryReceipts, [receipt])
    }

    func testRecoveryReceiptEventDrivesRetryDeleteAndClearActions() async {
        let probe = FailedAudioRecoveryActionProbe()
        let workflow = makeDefaultWorkflow()
        let harness = makeHarness(
            workflow: workflow,
            settingsStore: UITestSettingsStore(
                storage: [.failedAudioRecoveryEnabled: "true"]
            ),
            retryFailedAudioRecoveryAction: { id, workflow in
                await probe.recordRetry(id: id, workflowID: workflow.id)
                return .completed
            },
            deleteFailedAudioRecoveryAction: { id in
                await probe.recordDelete(id)
            },
            clearFailedAudioRecoveryAction: {
                await probe.recordClear()
            }
        )
        await waitForFailedAudioRecovery(harness)
        let receipt = makeFailedAudioRecoveryReceipt(workflowID: workflow.id)

        await harness.eventBus.publish(.failedAudioRecoveryUpdated([receipt]))
        await waitForFailedAudioRecovery(harness)

        XCTAssertEqual(harness.model.voice.failedAudioRecoveryReceipts, [receipt])
        XCTAssertEqual(
            harness.model.failedAudioRecoveryReceipt(for: receipt.originalRunID),
            receipt
        )

        harness.model.retryFailedAudioRecovery(receipt)
        await waitForFailedAudioRecovery(harness)
        let retries = await probe.retries
        XCTAssertEqual(retries.count, 1)
        XCTAssertEqual(retries.first?.0, receipt.id)
        XCTAssertEqual(retries.first?.1, workflow.id)

        harness.model.deleteFailedAudioRecovery(receipt)
        await waitForFailedAudioRecovery(harness)
        let deletedIDs = await probe.deletedIDs
        XCTAssertEqual(deletedIDs, [receipt.id])

        harness.model.clearFailedAudioRecoveries()
        await waitForFailedAudioRecovery(harness)
        let clearCount = await probe.clearCount
        XCTAssertEqual(clearCount, 1)
    }

    func testRetryRefusesReceiptWhoseWorkflowNoLongerExists() async {
        let probe = FailedAudioRecoveryActionProbe()
        let harness = makeHarness(
            settingsStore: UITestSettingsStore(
                storage: [.failedAudioRecoveryEnabled: "true"]
            ),
            retryFailedAudioRecoveryAction: { id, workflow in
                await probe.recordRetry(id: id, workflowID: workflow.id)
                return .completed
            }
        )
        await harness.model.waitForInitialVoiceConfiguration()
        await harness.model.waitForFailedAudioRecoveryLoad()
        let receipt = makeFailedAudioRecoveryReceipt(workflowID: UUID())

        harness.model.retryFailedAudioRecovery(receipt)
        await waitForFailedAudioRecovery(harness)

        XCTAssertNotNil(harness.model.voice.failedAudioRecoveryError)
        let retries = await probe.retries
        XCTAssertTrue(retries.isEmpty)
    }

    func testInterruptedRetryReceiptCannotTriggerAnotherProviderRequest() async {
        let probe = FailedAudioRecoveryActionProbe()
        let workflow = makeDefaultWorkflow()
        var receipt = makeFailedAudioRecoveryReceipt(workflowID: workflow.id)
        receipt.status = .retrying(
            attemptID: UUID(),
            startedAt: Date(timeIntervalSince1970: 150)
        )
        let harness = makeHarness(
            workflow: workflow,
            settingsStore: UITestSettingsStore(
                storage: [.failedAudioRecoveryEnabled: "true"]
            ),
            retryFailedAudioRecoveryAction: { id, workflow in
                await probe.recordRetry(id: id, workflowID: workflow.id)
                return .completed
            }
        )
        await harness.model.waitForInitialVoiceConfiguration()
        await harness.model.waitForFailedAudioRecoveryLoad()

        harness.model.retryFailedAudioRecovery(receipt)
        await waitForFailedAudioRecovery(harness)

        XCTAssertNotNil(harness.model.voice.failedAudioRecoveryError)
        let retries = await probe.retries
        XCTAssertTrue(retries.isEmpty)
    }

    func testCompletedRetryWithCleanupPendingIsTruthfulAndRemovedLocally() async {
        let workflow = makeDefaultWorkflow()
        let receipt = makeFailedAudioRecoveryReceipt(workflowID: workflow.id)
        let harness = makeHarness(
            workflow: workflow,
            settingsStore: UITestSettingsStore(
                storage: [.failedAudioRecoveryEnabled: "true"]
            ),
            retryFailedAudioRecoveryAction: { _, _ in .completedCleanupPending }
        )
        await waitForFailedAudioRecovery(harness)
        harness.model.applyLanguage(.english)
        await harness.eventBus.publish(.failedAudioRecoveryUpdated([receipt]))
        await waitForFailedAudioRecovery(harness)

        harness.model.retryFailedAudioRecovery(receipt)
        await waitForFailedAudioRecovery(harness)

        XCTAssertFalse(
            harness.model.voice.failedAudioRecoveryReceipts.contains { $0.id == receipt.id }
        )
        XCTAssertTrue(
            harness.model.voice.failedAudioRecoveryError?.contains("unencrypted temporary recording")
                ?? false
        )
        XCTAssertTrue(
            harness.model.voice.failedAudioRecoveryError?.contains("will keep retrying") ?? false
        )
        XCTAssertTrue(
            harness.model.voice.failedAudioRecoveryError?.contains("will not repeat") ?? false
        )
    }

    func testApplicationShutdownCancelsAndWaitsForFailedAudioRetryWithoutLateSuccess() async {
        let workflow = makeDefaultWorkflow()
        let receipt = makeFailedAudioRecoveryReceipt(workflowID: workflow.id)
        var secondReceipt = makeFailedAudioRecoveryReceipt(workflowID: workflow.id)
        secondReceipt.id = UUID()
        let retry = CancellationIgnoringFailedAudioRecoveryRetry()
        let harness = makeHarness(
            workflow: workflow,
            settingsStore: UITestSettingsStore(
                storage: [.failedAudioRecoveryEnabled: "true"]
            ),
            retryFailedAudioRecoveryAction: { _, _ in
                await retry.run()
            }
        )
        await waitForFailedAudioRecovery(harness)
        await harness.eventBus.publish(.failedAudioRecoveryUpdated([receipt]))
        await waitForFailedAudioRecovery(harness)

        harness.model.retryFailedAudioRecovery(receipt)
        await retry.waitUntilStarted()

        let completion = FailedAudioRecoveryShutdownCompletionProbe()
        let shutdownTask = Task {
            await harness.model.stopFailedAudioRecoveryRetriesForApplicationShutdown()
            await completion.markCompleted()
        }
        await retry.waitUntilCancellationObserved()

        let completedWhileRuntimeWasBlocked = await completion.isCompleted()
        XCTAssertFalse(completedWhileRuntimeWasBlocked)
        XCTAssertTrue(harness.model.voice.retryingFailedAudioRecoveryIDs.contains(receipt.id))

        harness.model.retryFailedAudioRecovery(secondReceipt)
        let retryCountDuringShutdown = await retry.count()
        XCTAssertEqual(retryCountDuringShutdown, 1)

        await retry.release()
        await shutdownTask.value

        XCTAssertFalse(harness.model.voice.retryingFailedAudioRecoveryIDs.contains(receipt.id))
        XCTAssertTrue(harness.model.voice.failedAudioRecoveryRetryTasks.isEmpty)
        XCTAssertTrue(
            harness.model.voice.failedAudioRecoveryReceipts.contains { $0.id == receipt.id },
            "A cancellation-ignoring provider must not publish a late completed UI state."
        )
        XCTAssertNil(harness.model.voice.failedAudioRecoveryError)
        let didComplete = await completion.isCompleted()
        XCTAssertTrue(didComplete)
    }

    func testApplicationShutdownCancellationBeforeRetryTaskStartsSkipsRuntimeAction() async {
        let workflow = makeDefaultWorkflow()
        let receipt = makeFailedAudioRecoveryReceipt(workflowID: workflow.id)
        let probe = FailedAudioRecoveryActionProbe()
        let harness = makeHarness(
            workflow: workflow,
            settingsStore: UITestSettingsStore(
                storage: [.failedAudioRecoveryEnabled: "true"]
            ),
            retryFailedAudioRecoveryAction: { id, workflow in
                await probe.recordRetry(id: id, workflowID: workflow.id)
                return .completed
            }
        )
        await waitForFailedAudioRecovery(harness)
        await harness.eventBus.publish(.failedAudioRecoveryUpdated([receipt]))
        await waitForFailedAudioRecovery(harness)

        // Both calls execute synchronously on MainActor until shutdown awaits
        // the stored task, so cancellation deterministically wins before its
        // body can enter the runtime action.
        harness.model.retryFailedAudioRecovery(receipt)
        await harness.model.stopFailedAudioRecoveryRetriesForApplicationShutdown()

        let retries = await probe.retries
        XCTAssertTrue(retries.isEmpty)
        XCTAssertTrue(harness.model.voice.failedAudioRecoveryRetryTasks.isEmpty)
        XCTAssertTrue(
            harness.model.voice.failedAudioRecoveryReceipts.contains { $0.id == receipt.id }
        )
    }

    func testApplicationShutdownDrainsCancellationIgnoringRecoveryIndexLoadWithoutLateWrite() async {
        let workflow = makeDefaultWorkflow()
        let receipt = makeFailedAudioRecoveryReceipt(workflowID: workflow.id)
        let load = CancellationIgnoringFailedAudioRecoveryLoad()
        let harness = makeHarness(
            workflow: workflow,
            settingsStore: UITestSettingsStore(
                storage: [.failedAudioRecoveryEnabled: "true"]
            ),
            loadFailedAudioRecoveryReceiptsAction: {
                await load.run()
            }
        )
        await harness.model.waitForInitialVoiceConfiguration()
        await load.waitUntilStarted()

        let completion = FailedAudioRecoveryShutdownCompletionProbe()
        let shutdownTask = Task { @MainActor in
            await harness.model.stopFailedAudioRecoveryRetriesForApplicationShutdown()
            await completion.markCompleted()
        }
        await load.waitUntilCancellationObserved()

        let completedWhileLoadWasBlocked = await completion.isCompleted()
        XCTAssertFalse(completedWhileLoadWasBlocked)
        await load.release(with: [receipt])
        await shutdownTask.value

        XCTAssertTrue(harness.model.voice.failedAudioRecoveryReceipts.isEmpty)
        XCTAssertNil(harness.model.voice.failedAudioRecoveryLoadTask)
        let completedAfterLoadSettled = await completion.isCompleted()
        XCTAssertTrue(completedAfterLoadSettled)
    }

    func testPlaintextCleanupPendingErrorIsLocalized() async {
        let workflow = makeDefaultWorkflow()
        let receipt = makeFailedAudioRecoveryReceipt(workflowID: workflow.id)
        let harness = makeHarness(
            workflow: workflow,
            settingsStore: UITestSettingsStore(
                storage: [.failedAudioRecoveryEnabled: "true"]
            ),
            retryFailedAudioRecoveryAction: { _, _ in
                throw FailedAudioRecoveryController.ControllerError.plaintextCleanupPending
            }
        )
        await waitForFailedAudioRecovery(harness)
        harness.model.applyLanguage(.simplifiedChinese)
        await harness.eventBus.publish(.failedAudioRecoveryUpdated([receipt]))
        await waitForFailedAudioRecovery(harness)

        harness.model.retryFailedAudioRecovery(receipt)
        await waitForFailedAudioRecovery(harness)

        XCTAssertTrue(
            harness.model.voice.failedAudioRecoveryError?.contains("未加密的恢复临时录音可能仍待清理")
                ?? false
        )
    }

    func testRecoveryUnavailableEventUsesLocalizedContentFreeReason() async {
        let harness = makeHarness()
        await waitForFailedAudioRecovery(harness)
        harness.model.applyLanguage(.simplifiedChinese)

        await harness.eventBus.publish(
            .failedAudioRecoveryUnavailable(
                runID: UUID(),
                reason: .entryTooLarge
            )
        )
        await waitForFailedAudioRecovery(harness)

        XCTAssertEqual(
            harness.model.voice.failedAudioRecoveryError,
            "无法保留失败录音。失败录音超过恢复大小上限。"
        )
        XCTAssertFalse(
            harness.model.voice.failedAudioRecoveryError?.contains("exceeds") ?? true
        )
    }

    func testRecoveryUnavailableReasonRemainsBoundToItsRunAcrossUnrelatedIndexUpdates() async {
        let harness = makeHarness()
        await waitForFailedAudioRecovery(harness)
        let failedRunID = UUID()
        let otherRunID = UUID()
        var otherReceipt = makeFailedAudioRecoveryReceipt(workflowID: UUID())
        otherReceipt.originalRunID = otherRunID

        await harness.eventBus.publish(
            .failedAudioRecoveryUnavailable(
                runID: failedRunID,
                reason: .storageUnavailable
            )
        )
        await waitForFailedAudioRecovery(harness)
        await harness.eventBus.publish(.failedAudioRecoveryUpdated([otherReceipt]))
        await waitForFailedAudioRecovery(harness)

        XCTAssertEqual(
            harness.model.voice.failedAudioRecoveryUnavailableReasonsByRunID[failedRunID],
            .storageUnavailable
        )
        XCTAssertNotNil(harness.model.voice.failedAudioRecoveryError)

        var matchingReceipt = otherReceipt
        matchingReceipt.id = UUID()
        matchingReceipt.originalRunID = failedRunID
        await harness.eventBus.publish(.failedAudioRecoveryUpdated([matchingReceipt]))
        await waitForFailedAudioRecovery(harness)

        XCTAssertNil(
            harness.model.voice.failedAudioRecoveryUnavailableReasonsByRunID[failedRunID]
        )
    }

    func testClearingRunHistoryAlsoClearsFailedRecordingArtifacts() async {
        let probe = FailedAudioRecoveryActionProbe()
        let workflow = makeDefaultWorkflow()
        let receipt = makeFailedAudioRecoveryReceipt(workflowID: workflow.id)
        let harness = makeHarness(
            workflow: workflow,
            settingsStore: UITestSettingsStore(
                storage: [.failedAudioRecoveryEnabled: "true"]
            ),
            localHistoryMaintenance: UITestLocalHistoryMaintenance(),
            clearFailedAudioRecoveryAction: {
                await probe.recordClear()
            },
            loadFailedAudioRecoveryReceiptsAction: { [receipt] in [receipt] }
        )
        await waitForFailedAudioRecovery(harness)

        harness.model.clearRunHistory()
        await waitForFailedAudioRecovery(harness)
        await waitForFailedAudioRecovery(harness)

        let clearCount = await probe.clearCount
        XCTAssertEqual(clearCount, 1)
    }

    private func makeFailedAudioRecoveryReceipt(
        workflowID: UUID
    ) -> FailedAudioRecoveryReceipt {
        FailedAudioRecoveryReceipt(
            originalRunID: UUID(),
            workflowID: workflowID,
            createdAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 200),
            durationSeconds: 1,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            plaintextByteCount: 3,
            failureStage: .recognizing,
            failureCode: .processing
        )
    }
}
