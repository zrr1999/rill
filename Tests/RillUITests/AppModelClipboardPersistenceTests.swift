import XCTest
@testable import RillCore
@testable import RillRuntime
@testable import RillUI

private actor ClipboardPersistenceRetryStore: SettingsStore, ClipboardPersistenceStore {
    enum StoreError: Error {
        case writeFailed
    }

    private var storage: [AppSettingKey: String] = [:]
    private var remainingWriteFailures = 1
    private var shouldBlockNextSuccessfulWrite = true
    private var writeAttempts = 0
    private var didBlockWrite = false
    private var blockWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedWriteContinuation: CheckedContinuation<Void, Never>?
    private var currentMetadata: Data?
    private var currentRevision: Int64?
    private var imageBlobsByID: [UUID: ClipboardPersistenceImageBlob] = [:]

    func string(forKey key: AppSettingKey) async throws -> String? {
        storage[key]
    }

    func settingsSnapshot(
        forKeys keys: [AppSettingKey]
    ) async throws -> SettingsStoreReadSnapshot {
        let requestedKeys = Set(keys)
        return SettingsStoreReadSnapshot(
            values: storage.filter { requestedKeys.contains($0.key) }
        )
    }

    func setString(_ value: String, forKey key: AppSettingKey) async throws {
        writeAttempts += 1
        if remainingWriteFailures > 0 {
            remainingWriteFailures -= 1
            throw StoreError.writeFailed
        }
        if shouldBlockNextSuccessfulWrite {
            shouldBlockNextSuccessfulWrite = false
            didBlockWrite = true
            let waiters = blockWaiters
            blockWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                blockedWriteContinuation = continuation
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

    func loadClipboardPersistence() async throws -> ClipboardPersistenceReadSnapshot {
        guard let currentMetadata, let currentRevision else { return .empty }
        return .current(
            revision: currentRevision,
            metadata: currentMetadata,
            imageBlobs: Array(imageBlobsByID.values)
        )
    }

    func replaceClipboardPersistence(
        with snapshot: ClipboardPersistenceWriteSnapshot
    ) async throws -> Int64 {
        guard snapshot.expectedRevision == currentRevision else {
            throw StoreError.writeFailed
        }

        var nextBlobs: [UUID: ClipboardPersistenceImageBlob] = [:]
        for reference in snapshot.retainedImageBlobReferences {
            guard let blob = imageBlobsByID[reference.blobID],
                  blob.reference == reference else {
                throw StoreError.writeFailed
            }
            nextBlobs[reference.blobID] = blob
        }
        for blob in snapshot.newImageBlobs {
            guard blob.reference.byteCount == blob.payload.count else {
                throw StoreError.writeFailed
            }
            nextBlobs[blob.reference.blobID] = blob
        }

        try await setString(
            String(decoding: snapshot.metadata, as: UTF8.self),
            forKey: .clipboardPersistedState
        )
        let nextRevision = (currentRevision ?? 0) + 1
        currentMetadata = snapshot.metadata
        currentRevision = nextRevision
        imageBlobsByID = nextBlobs
        return nextRevision
    }

    func removeClipboardPersistence() async throws -> ClipboardPersistenceRemovalResult {
        try await removeValue(forKey: .clipboardPersistedState)
        currentMetadata = nil
        currentRevision = nil
        imageBlobsByID.removeAll()
        return .removed
    }

    func waitUntilWriteBlocks() async {
        guard !didBlockWrite else { return }
        await withCheckedContinuation { continuation in
            blockWaiters.append(continuation)
        }
    }

    func resumeBlockedWrite() {
        blockedWriteContinuation?.resume()
        blockedWriteContinuation = nil
    }

    func writeAttemptCount() -> Int {
        writeAttempts
    }
}

private actor ClipboardPersistenceResetStore: SettingsStore, ClipboardPersistenceStore {
    enum StoreError: Error {
        case readFailed
        case removalFailed
    }

    private var storedState: String? = "protected-unreadable-clipboard-state"
    private var isStateUnavailable = true
    private var remainingRemovalFailures: Int
    private var removalAttempts = 0

    init(remainingRemovalFailures: Int = 0) {
        self.remainingRemovalFailures = remainingRemovalFailures
    }

    func string(forKey key: AppSettingKey) async throws -> String? {
        key == .clipboardPersistedState ? storedState : nil
    }

    func settingsSnapshot(
        forKeys keys: [AppSettingKey]
    ) async throws -> SettingsStoreReadSnapshot {
        let requestedKeys = Set(keys)
        let values: [AppSettingKey: String]
        if requestedKeys.contains(.clipboardPersistedState), let storedState {
            values = [.clipboardPersistedState: storedState]
        } else {
            values = [:]
        }
        return SettingsStoreReadSnapshot(
            values: values,
            unavailableKeys: isStateUnavailable && requestedKeys.contains(.clipboardPersistedState)
                ? [.clipboardPersistedState]
                : []
        )
    }

    func setString(_ value: String, forKey key: AppSettingKey) async throws {
        guard key == .clipboardPersistedState else { return }
        storedState = value
    }

    func setStringsAtomically(_ values: [AppSettingKey: String]) async throws {
        if let value = values[.clipboardPersistedState] {
            storedState = value
        }
    }

    func removeValue(forKey key: AppSettingKey) async throws {
        guard key == .clipboardPersistedState else { return }
        removalAttempts += 1
        if remainingRemovalFailures > 0 {
            remainingRemovalFailures -= 1
            throw StoreError.removalFailed
        }
        storedState = nil
        isStateUnavailable = false
    }

    func loadClipboardPersistence() async throws -> ClipboardPersistenceReadSnapshot {
        guard !isStateUnavailable else { throw StoreError.readFailed }
        guard let storedState else { return .empty }
        return .legacy(metadata: Data(storedState.utf8))
    }

    func replaceClipboardPersistence(
        with snapshot: ClipboardPersistenceWriteSnapshot
    ) async throws -> Int64 {
        storedState = String(decoding: snapshot.metadata, as: UTF8.self)
        return 1
    }

    func removeClipboardPersistence() async throws -> ClipboardPersistenceRemovalResult {
        try await removeValue(forKey: .clipboardPersistedState)
        return .removed
    }

    func storedClipboardState() -> String? {
        storedState
    }

    func removalAttemptCount() -> Int {
        removalAttempts
    }
}

@MainActor
final class AppModelClipboardPersistenceTests: XCTestCase {
    func testClipboardSnapshotMapsPersistenceAvailabilityIntoAppModel() async {
        let harness = makeHarness()
        await waitForListenerSetup()

        await harness.eventBus.publish(
            .clipboardUpdated(
                ClipboardStoreSnapshot(
                    items: [],
                    groups: [],
                    appAssignments: [],
                    persistenceAvailability: .loadUnavailable
                )
            )
        )
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.clipboardPersistenceAvailability, .loadUnavailable)
    }

    func testImmediateRetryIsSingleFlightAndReconcilesFromAuthoritativeSnapshot() async {
        let settingsStore = ClipboardPersistenceRetryStore()
        let harness = makeHarness(
            deliveryStackFactory: { eventBus in
                DeliveryStack(
                    eventBus: eventBus,
                    clipboardPersistenceStore: settingsStore,
                    persistenceRetryDelays: [.seconds(60)]
                )
            }
        )
        await waitForListenerSetup()
        await harness.deliveryStack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(
                plainText: "retry from main clipboard",
                changeCount: 1
            ),
            context: ClipboardRouteContext(),
            disposition: .historyAndWorkflows
        )
        let failedFlush = await harness.deliveryStack.flushPendingPersistenceWrites()
        XCTAssertEqual(failedFlush, .saveFailed)
        await waitForEventProcessing()
        XCTAssertEqual(harness.model.clipboardPersistenceAvailability, .saveFailed)

        harness.model.retryClipboardPersistenceNow()
        await settingsStore.waitUntilWriteBlocks()
        harness.model.retryClipboardPersistenceNow()

        let attemptsWhileBlocked = await settingsStore.writeAttemptCount()
        XCTAssertTrue(harness.model.isRetryingClipboardPersistence)
        XCTAssertEqual(attemptsWhileBlocked, 2)

        await settingsStore.resumeBlockedWrite()
        await waitForEventProcessing()

        let finalAttempts = await settingsStore.writeAttemptCount()
        XCTAssertFalse(harness.model.isRetryingClipboardPersistence)
        XCTAssertEqual(harness.model.clipboardPersistenceAvailability, .available)
        XCTAssertEqual(finalAttempts, 2)
    }

    func testConfirmedResetClearsUnavailableSessionProjectionAndReconcilesAvailableState() async {
        let settingsStore = ClipboardPersistenceResetStore()
        let harness = makeHarness(
            deliveryStackFactory: { eventBus in
                DeliveryStack(
                    eventBus: eventBus,
                    clipboardPersistenceStore: settingsStore
                )
            }
        )
        await waitForListenerSetup()
        await waitForEventProcessing()
        XCTAssertEqual(harness.model.clipboardPersistenceAvailability, .loadUnavailable)

        await harness.deliveryStack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "session only", changeCount: 1),
            context: ClipboardRouteContext(),
            disposition: .historyAndWorkflows
        )
        await waitForEventProcessing()
        XCTAssertEqual(harness.model.clipboardItems.map(\.text), ["session only"])

        harness.model.resetUnavailableClipboardPersistence()
        XCTAssertTrue(harness.model.isResettingClipboardPersistence)
        await waitForResetCompletion(harness.model)

        let removalAttempts = await settingsStore.removalAttemptCount()
        let storedState = await settingsStore.storedClipboardState()
        XCTAssertEqual(removalAttempts, 1)
        XCTAssertNil(storedState)
        XCTAssertFalse(harness.model.isResettingClipboardPersistence)
        XCTAssertFalse(harness.model.clipboardPersistenceResetFailed)
        XCTAssertEqual(harness.model.clipboardPersistenceAvailability, .available)
        XCTAssertTrue(harness.model.clipboardItems.isEmpty)
        XCTAssertTrue(harness.model.clipboardAppAssignments.isEmpty)
    }

    func testFailedResetKeepsUnavailableWarningAndProtectedStateThenAllowsRetry() async {
        let settingsStore = ClipboardPersistenceResetStore(remainingRemovalFailures: 1)
        let harness = makeHarness(
            deliveryStackFactory: { eventBus in
                DeliveryStack(
                    eventBus: eventBus,
                    clipboardPersistenceStore: settingsStore
                )
            }
        )
        await waitForListenerSetup()
        await waitForEventProcessing()

        harness.model.resetUnavailableClipboardPersistence()
        await waitForResetCompletion(harness.model)

        var removalAttempts = await settingsStore.removalAttemptCount()
        var storedState = await settingsStore.storedClipboardState()
        XCTAssertEqual(removalAttempts, 1)
        XCTAssertEqual(storedState, "protected-unreadable-clipboard-state")
        XCTAssertEqual(harness.model.clipboardPersistenceAvailability, .loadUnavailable)
        XCTAssertTrue(harness.model.clipboardPersistenceResetFailed)

        harness.model.resetUnavailableClipboardPersistence()
        await waitForResetCompletion(harness.model)

        removalAttempts = await settingsStore.removalAttemptCount()
        storedState = await settingsStore.storedClipboardState()
        XCTAssertEqual(removalAttempts, 2)
        XCTAssertNil(storedState)
        XCTAssertEqual(harness.model.clipboardPersistenceAvailability, .available)
        XCTAssertFalse(harness.model.clipboardPersistenceResetFailed)
    }

    private func waitForResetCompletion(_ model: AppModel) async {
        for _ in 0..<100 where model.isResettingClipboardPersistence {
            await Task.yield()
        }
        await waitForEventProcessing()
    }
}
