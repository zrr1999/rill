import XCTest
@testable import RillCore
@testable import RillRuntime

private actor ControlledPersistenceSleepGate {
    struct Snapshot: Sendable, Equatable {
        let requestedDelays: [Duration]
        let cancellationCount: Int
        let completionCount: Int
    }

    private struct Waiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var requestedDelays: [Duration] = []
    private var pendingSleeps: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelledSleepIDs: Set<UUID> = []
    private var completedSleepIDs: Set<UUID> = []
    private var entryWaiters: [Waiter] = []
    private var completionWaiters: [Waiter] = []

    func sleep(for delay: Duration) async throws {
        let sleepID = UUID()
        requestedDelays.append(delay)
        resumeSatisfiedWaiters(&entryWaiters, currentCount: requestedDelays.count)
        defer {
            completedSleepIDs.insert(sleepID)
            resumeSatisfiedWaiters(
                &completionWaiters,
                currentCount: completedSleepIDs.count
            )
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    cancelledSleepIDs.insert(sleepID)
                    continuation.resume(throwing: CancellationError())
                } else {
                    pendingSleeps[sleepID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelSleep(id: sleepID) }
        }
    }

    func waitUntilEntered(count: Int = 1) async {
        guard requestedDelays.count < count else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(
                Waiter(expectedCount: count, continuation: continuation)
            )
        }
    }

    func waitUntilCompleted(count: Int = 1) async {
        guard completedSleepIDs.count < count else { return }
        await withCheckedContinuation { continuation in
            completionWaiters.append(
                Waiter(expectedCount: count, continuation: continuation)
            )
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            requestedDelays: requestedDelays,
            cancellationCount: cancelledSleepIDs.count,
            completionCount: completedSleepIDs.count
        )
    }

    private func cancelSleep(id: UUID) {
        guard !completedSleepIDs.contains(id) else { return }
        cancelledSleepIDs.insert(id)
        pendingSleeps.removeValue(forKey: id)?.resume(
            throwing: CancellationError()
        )
    }

    private func resumeSatisfiedWaiters(
        _ waiters: inout [Waiter],
        currentCount: Int
    ) {
        var remaining: [Waiter] = []
        for waiter in waiters {
            if currentCount >= waiter.expectedCount {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}

private actor BlockingClipboardResetSettingsStore: SettingsStore, ClipboardPersistenceStore {
    private var storage: [AppSettingKey: String]
    private var unavailableKeys: Set<AppSettingKey>
    private var didEnterRemoval = false
    private var removalEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var removalContinuation: CheckedContinuation<Void, Never>?

    init(protectedState: String) {
        storage = [.clipboardPersistedState: protectedState]
        unavailableKeys = [.clipboardPersistedState]
    }

    func string(forKey key: AppSettingKey) async throws -> String? {
        storage[key]
    }

    func settingsSnapshot(
        forKeys keys: [AppSettingKey]
    ) async throws -> SettingsStoreReadSnapshot {
        let requestedKeys = Set(keys)
        return SettingsStoreReadSnapshot(
            values: storage.filter { requestedKeys.contains($0.key) },
            unavailableKeys: unavailableKeys.intersection(requestedKeys)
        )
    }

    func setString(_ value: String, forKey key: AppSettingKey) async throws {
        storage[key] = value
    }

    func setStringsAtomically(_ values: [AppSettingKey: String]) async throws {
        storage.merge(values) { _, newValue in newValue }
    }

    func removeValue(forKey key: AppSettingKey) async throws {
        try await performRemoval(forKey: key)
    }

    func loadClipboardPersistence() async throws -> ClipboardPersistenceReadSnapshot {
        if unavailableKeys.contains(.clipboardPersistedState) {
            throw RuntimeTestSettingsStore.StoreError.readFailed
        }
        guard let rawState = storage[.clipboardPersistedState] else { return .empty }
        return .legacy(metadata: Data(rawState.utf8))
    }

    func replaceClipboardPersistence(
        with _: ClipboardPersistenceWriteSnapshot
    ) async throws -> Int64 {
        throw RuntimeTestSettingsStore.StoreError.writeFailed
    }

    func removeClipboardPersistence() async throws -> ClipboardPersistenceRemovalResult {
        try await performRemoval(forKey: .clipboardPersistedState)
        return .removed
    }

    private func performRemoval(forKey key: AppSettingKey) async throws {
        didEnterRemoval = true
        let waiters = removalEntryWaiters
        removalEntryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            removalContinuation = continuation
        }
        storage.removeValue(forKey: key)
        unavailableKeys.remove(key)
    }

    func waitUntilRemovalBlocks() async {
        guard !didEnterRemoval else { return }
        await withCheckedContinuation { continuation in
            removalEntryWaiters.append(continuation)
        }
    }

    func resumeRemoval() {
        removalContinuation?.resume()
        removalContinuation = nil
    }
}

private actor ClipboardResetOperationProbe {
    private var didComplete = false

    func markCompleted() {
        didComplete = true
    }

    func hasCompleted() -> Bool {
        didComplete
    }
}

extension DeliveryStackTests {
    func testMissingDurableBackendIsExplicitlySessionOnly() async {
        let stack = DeliveryStack(eventBus: EventBus())
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "session only", changeCount: 1),
            context: ClipboardRouteContext()
        )

        let snapshot = await stack.clipboardSnapshot()
        let flushResult = await stack.flushPendingPersistenceWrites()

        XCTAssertEqual(snapshot.persistenceAvailability, .notConfigured)
        XCTAssertEqual(snapshot.items.map(\.text), ["session only"])
        XCTAssertEqual(flushResult, .notConfigured)
    }

    func testUnavailablePersistedClipboardStateCannotBeOverwrittenByCaptureFlushOrClear() async throws {
        let protectedSentinel = "protected-unreadable-clipboard-state"
        let settingsStore = RuntimeTestSettingsStore(
            storage: [.clipboardPersistedState: protectedSentinel],
            unavailableKeys: [.clipboardPersistedState]
        )
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore
        )

        let unavailableSnapshot = await stack.clipboardSnapshot()
        XCTAssertEqual(unavailableSnapshot.persistenceAvailability, .loadUnavailable)

        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "session only", changeCount: 1),
            context: ClipboardRouteContext()
        )
        let flushResult = await stack.flushPendingPersistenceWrites()

        do {
            _ = try await stack.clearHistory()
            XCTFail("Unavailable protected history must not report a durable clear.")
        } catch let error as ClipboardHistoryMaintenanceError {
            XCTAssertEqual(error, .persistenceUnavailable)
        }

        let sessionSnapshot = await stack.clipboardSnapshot()
        let storedValue = await settingsStore.storedString(forKey: .clipboardPersistedState)
        let writeCount = await settingsStore.writeCount(forKey: .clipboardPersistedState)
        XCTAssertEqual(sessionSnapshot.items.map(\.text), ["session only"])
        XCTAssertEqual(sessionSnapshot.persistenceAvailability, .loadUnavailable)
        XCTAssertEqual(flushResult, .loadUnavailable)
        XCTAssertEqual(storedValue, protectedSentinel)
        XCTAssertEqual(writeCount, 0)
    }

    func testConfirmedUnavailableStateResetDeletesProtectedAndSessionStateThenRestoresWrites() async throws {
        let protectedSentinel = "protected-unreadable-clipboard-state"
        let settingsStore = RuntimeTestSettingsStore(
            storage: [.clipboardPersistedState: protectedSentinel],
            unavailableKeys: [.clipboardPersistedState]
        )
        let diagnostics = DiagnosticsRecorder()
        let stack = DeliveryStack(
            eventBus: EventBus(),
            diagnostics: diagnostics,
            clipboardPersistenceStore: settingsStore
        )

        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "session only", changeCount: 1),
            context: ClipboardRouteContext()
        )
        let sessionGroup = (await stack.createGroup(named: "Session Group")).group!
        _ = await stack.assignApplication(
            bundleIdentifier: "com.example.Session",
            applicationName: "Session",
            toGroup: sessionGroup.id
        )

        let resetResult = await stack.resetUnavailablePersistedState()
        let resetSnapshot = await stack.clipboardSnapshot()
        let storedAfterReset = await settingsStore.storedString(forKey: .clipboardPersistedState)
        let removalAttempts = await settingsStore.removalAttemptCount()

        XCTAssertEqual(resetResult, .reset)
        XCTAssertEqual(resetSnapshot.persistenceAvailability, .available)
        XCTAssertTrue(resetSnapshot.items.isEmpty)
        XCTAssertFalse(resetSnapshot.groups.contains { $0.group.id == sessionGroup.id })
        XCTAssertTrue(resetSnapshot.appAssignments.isEmpty)
        XCTAssertNil(resetSnapshot.lastStorageRejection)
        XCTAssertNil(resetSnapshot.storagePressureContext)
        XCTAssertNil(storedAfterReset)
        XCTAssertEqual(removalAttempts, 1)

        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "durable after reset", changeCount: 2),
            context: ClipboardRouteContext()
        )
        let flushResult = await stack.flushPendingPersistenceWrites()
        XCTAssertEqual(flushResult, .persisted)

        let restoredStack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore
        )
        let restoredSnapshot = await restoredStack.clipboardSnapshot()
        XCTAssertEqual(restoredSnapshot.items.map(\.text), ["durable after reset"])
        XCTAssertEqual(restoredSnapshot.persistenceAvailability, .available)

        let resetDiagnostic = await diagnostics.snapshot().first(where: {
            $0.event == "clipboard.state.reset"
        })
        XCTAssertEqual(resetDiagnostic?.message, DiagnosticEventSanitizer.sanitizedMessage)
        XCTAssertEqual(resetDiagnostic?.metadata, [:])
    }

    func testResetSerializesConcurrentResetAndCaptureBehindDurableDeletion() async throws {
        let settingsStore = BlockingClipboardResetSettingsStore(
            protectedState: "protected-unreadable-clipboard-state"
        )
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore
        )
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "before confirmation", changeCount: 1),
            context: ClipboardRouteContext()
        )

        let resetTask = Task { await stack.resetUnavailablePersistedState() }
        await settingsStore.waitUntilRemovalBlocks()

        let secondResetTask = Task { await stack.resetUnavailablePersistedState() }
        let captureProbe = ClipboardResetOperationProbe()
        let captureTask = Task {
            let result = await stack.captureSystemClipboard(
                snapshot: ClipboardSnapshot(plainText: "after confirmation", changeCount: 2),
                context: ClipboardRouteContext(),
                disposition: .historyAndWorkflows
            )
            await captureProbe.markCompleted()
            return result
        }

        let didQueueBothOperations = await waitForMaintenanceWaiterCount(
            2,
            in: stack
        )
        let captureCompletedWhileDeletionBlocked = await captureProbe.hasCompleted()
        XCTAssertTrue(didQueueBothOperations)
        XCTAssertFalse(captureCompletedWhileDeletionBlocked)

        await settingsStore.resumeRemoval()
        let resetResult = await resetTask.value
        let secondResetResult = await secondResetTask.value
        let captureResult = await captureTask.value
        let finalSnapshot = await stack.clipboardSnapshot()

        XCTAssertEqual(resetResult, .reset)
        XCTAssertEqual(secondResetResult, .notRequired)
        XCTAssertTrue(captureResult.wasAccepted)
        XCTAssertEqual(finalSnapshot.persistenceAvailability, .available)
        XCTAssertEqual(finalSnapshot.items.map(\.text), ["after confirmation"])
    }

    func testResetSerializesConcurrentLeaseSoItCannotEscapeWithDeletedItem() async throws {
        let settingsStore = BlockingClipboardResetSettingsStore(
            protectedState: "protected-unreadable-clipboard-state"
        )
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore
        )
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "before confirmation", changeCount: 1),
            context: ClipboardRouteContext()
        )

        let resetTask = Task { await stack.resetUnavailablePersistedState() }
        await settingsStore.waitUntilRemovalBlocks()

        let leaseProbe = ClipboardResetOperationProbe()
        let leaseTask = Task {
            let lease = await stack.beginDeliveryLease(for: ClipboardRouteContext())
            await leaseProbe.markCompleted()
            return lease
        }

        let didQueueLease = await waitForMaintenanceWaiterCount(1, in: stack)
        let leaseCompletedWhileDeletionBlocked = await leaseProbe.hasCompleted()
        XCTAssertTrue(didQueueLease)
        XCTAssertFalse(leaseCompletedWhileDeletionBlocked)

        await settingsStore.resumeRemoval()
        let resetResult = await resetTask.value
        let lease = await leaseTask.value
        let finalSnapshot = await stack.clipboardSnapshot()

        XCTAssertEqual(resetResult, .reset)
        XCTAssertNil(lease)
        XCTAssertTrue(finalSnapshot.items.isEmpty)
        XCTAssertTrue(finalSnapshot.remainingItemIDs.isEmpty)
    }

    func testResetSerializesDirectPayloadReadSoDeletedItemCannotEscape() async throws {
        let settingsStore = BlockingClipboardResetSettingsStore(
            protectedState: "protected-unreadable-clipboard-state"
        )
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore
        )
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "before confirmation", changeCount: 1),
            context: ClipboardRouteContext()
        )
        let snapshotBeforeReset = await stack.clipboardSnapshot()
        let itemID = try XCTUnwrap(snapshotBeforeReset.items.first?.id)

        let resetTask = Task { await stack.resetUnavailablePersistedState() }
        await settingsStore.waitUntilRemovalBlocks()

        let readProbe = ClipboardResetOperationProbe()
        let readTask = Task {
            let item = await stack.item(id: itemID)
            await readProbe.markCompleted()
            return item
        }

        let didQueueRead = await waitForMaintenanceWaiterCount(1, in: stack)
        let completedWhileDeletionBlocked = await readProbe.hasCompleted()
        XCTAssertTrue(didQueueRead)
        XCTAssertFalse(completedWhileDeletionBlocked)

        await settingsStore.resumeRemoval()
        let resetResult = await resetTask.value
        let escapedItem = await readTask.value
        XCTAssertEqual(resetResult, .reset)
        XCTAssertNil(escapedItem)
    }

    func testFailedUnavailableStateResetPreservesProtectedAndSessionStateAndCanRetry() async throws {
        let protectedSentinel = "protected-unreadable-clipboard-state"
        let settingsStore = RuntimeTestSettingsStore(
            storage: [.clipboardPersistedState: protectedSentinel],
            unavailableKeys: [.clipboardPersistedState],
            remainingRemovalFailures: 1
        )
        let diagnostics = DiagnosticsRecorder()
        let stack = DeliveryStack(
            eventBus: EventBus(),
            diagnostics: diagnostics,
            clipboardPersistenceStore: settingsStore
        )

        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "session only", changeCount: 1),
            context: ClipboardRouteContext()
        )
        let failedResult = await stack.resetUnavailablePersistedState()
        let failedSnapshot = await stack.clipboardSnapshot()
        let storedAfterFailure = await settingsStore.storedString(
            forKey: .clipboardPersistedState
        )
        let writeAttemptsAfterFailure = await settingsStore.writeAttemptCount()

        XCTAssertEqual(failedResult, .failed)
        XCTAssertEqual(failedSnapshot.persistenceAvailability, .loadUnavailable)
        XCTAssertEqual(failedSnapshot.items.map(\.text), ["session only"])
        XCTAssertEqual(storedAfterFailure, protectedSentinel)
        XCTAssertEqual(writeAttemptsAfterFailure, 0)

        let failureDiagnostic = await diagnostics.snapshot().first(where: {
            $0.event == "clipboard.state.reset-failed"
        })
        XCTAssertEqual(failureDiagnostic?.message, DiagnosticEventSanitizer.sanitizedMessage)
        XCTAssertEqual(failureDiagnostic?.metadata, [:])

        let retryResult = await stack.resetUnavailablePersistedState()
        let removalAttempts = await settingsStore.removalAttemptCount()
        let storedAfterRetry = await settingsStore.storedString(forKey: .clipboardPersistedState)
        XCTAssertEqual(retryResult, .reset)
        XCTAssertEqual(removalAttempts, 2)
        XCTAssertNil(storedAfterRetry)
    }

    func testUnavailableStateResetSurfacesPendingPhysicalCleanupWithoutRetainingPayload() async {
        let settingsStore = RuntimeTestSettingsStore(
            storage: [.clipboardPersistedState: "protected-unreadable-clipboard-state"],
            unavailableKeys: [.clipboardPersistedState],
            clipboardRemovalResult: .removedCleanupPending
        )
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore
        )
        _ = await stack.clipboardSnapshot()
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "session secret", changeCount: 1),
            context: ClipboardRouteContext()
        )

        let result = await stack.resetUnavailablePersistedState()
        let snapshot = await stack.clipboardSnapshot()
        let flushResult = await stack.flushPendingPersistenceWrites()
        let snapshotAfterFlush = await stack.clipboardSnapshot()

        XCTAssertEqual(result, .resetCleanupPending)
        XCTAssertEqual(snapshot.persistenceAvailability, .cleanupPending)
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertEqual(flushResult, .persisted)
        XCTAssertEqual(snapshotAfterFlush.persistenceAvailability, .cleanupPending)
    }

    func testOversizedRawStateCanBeExplicitlyResetAndReplacedByValidState() async throws {
        var limits = ClipboardStorageLimits.productDefault
        limits.maximumPersistedStateUTF8ByteCount = 8_192
        let oversizedRaw = String(repeating: "x", count: 8_193)
        let settingsStore = RuntimeTestSettingsStore(
            storage: [.clipboardPersistedState: oversizedRaw]
        )
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore,
            storageLimits: limits
        )

        let unavailableSnapshot = await stack.clipboardSnapshot()
        let storedBeforeReset = await settingsStore.storedString(
            forKey: .clipboardPersistedState
        )
        XCTAssertEqual(unavailableSnapshot.persistenceAvailability, .loadUnavailable)
        XCTAssertEqual(unavailableSnapshot.storagePressureContext, .persistedStateRejected)
        XCTAssertEqual(storedBeforeReset, oversizedRaw)

        let resetResult = await stack.resetUnavailablePersistedState()
        XCTAssertEqual(resetResult, .reset)
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "valid state", changeCount: 1),
            context: ClipboardRouteContext()
        )
        let flushResult = await stack.flushPendingPersistenceWrites()
        XCTAssertEqual(flushResult, .persisted)

        let persistedValue = await settingsStore.storedString(forKey: .clipboardPersistedState)
        let storedValidState = try XCTUnwrap(persistedValue)
        XCTAssertLessThanOrEqual(storedValidState.utf8.count, 8_192)
        XCTAssertNotEqual(storedValidState, oversizedRaw)
        XCTAssertTrue(storedValidState.contains("valid state"))
    }

    func testDuplicatePersistedClipboardItemIDsFailClosedWithoutOverwritingState() async throws {
        let item = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroupID,
            text: "duplicate item",
            sourceKind: .system
        )
        let rawState = try encodedLegacyState(
            items: [item, item],
            appAssignments: []
        )

        try await assertInvalidPersistedStateRemainsUntouched(rawState)
    }

    func testDuplicatePersistedClipboardBundleIdentifiersFailClosedWithoutOverwritingState() async throws {
        let firstAssignment = ClipboardAppAssignment(
            bundleIdentifier: "com.example.Editor",
            applicationName: "Editor"
        )
        let secondAssignment = ClipboardAppAssignment(
            bundleIdentifier: "com.example.Editor",
            applicationName: "Renamed Editor"
        )
        let rawState = try encodedLegacyState(
            items: [],
            appAssignments: [firstAssignment, secondAssignment]
        )

        try await assertInvalidPersistedStateRemainsUntouched(rawState)
    }

    func testDuplicatePersistedClipboardGroupIDsFailClosedWithoutOverwritingState() async throws {
        let group = ClipboardGroup(name: "Duplicate")
        let state = LegacyPersistedClipboardState(
            schemaVersion: 6,
            items: [],
            groups: [group, group],
            groupEntries: [],
            defaultGroupEntries: [],
            defaultGroupMode: .stack,
            appAssignments: []
        )

        try await assertInvalidPersistedStateRemainsUntouched(
            String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        )
    }

    func testDuplicatePersistedClipboardGroupEntryIDsFailClosedWithoutOverwritingState() async throws {
        let groupID = UUID()
        let state = LegacyPersistedClipboardState(
            schemaVersion: 6,
            items: [],
            groups: [],
            groupEntries: [
                .init(groupID: groupID, itemIDs: []),
                .init(groupID: groupID, itemIDs: []),
            ],
            defaultGroupEntries: [],
            defaultGroupMode: .stack,
            appAssignments: []
        )

        try await assertInvalidPersistedStateRemainsUntouched(
            String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        )
    }

    func testDuplicatePersistedClipboardGroupItemIDsFailClosedWithoutOverwritingState() async throws {
        let item = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroupID,
            text: "duplicate group entry",
            sourceKind: .system
        )
        let state = LegacyPersistedClipboardState(
            schemaVersion: 6,
            items: [item],
            groups: [],
            groupEntries: [],
            defaultGroupEntries: [item.id, item.id],
            defaultGroupMode: .stack,
            appAssignments: []
        )

        try await assertInvalidPersistedStateRemainsUntouched(
            String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        )
    }

    func testDuplicatePersistedClipboardCustomGroupItemIDsFailClosedWithoutOverwritingState() async throws {
        let group = ClipboardGroup(name: "Custom")
        let item = ClipboardHistoryItem(
            groupID: group.id,
            text: "duplicate custom entry",
            sourceKind: .system
        )
        let state = LegacyPersistedClipboardState(
            schemaVersion: 6,
            items: [item],
            groups: [group],
            groupEntries: [
                .init(groupID: group.id, itemIDs: [item.id, item.id]),
            ],
            defaultGroupEntries: [],
            defaultGroupMode: .stack,
            appAssignments: []
        )

        try await assertInvalidPersistedStateRemainsUntouched(
            String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        )
    }

    func testPersistedClipboardItemWithUnknownGroupFailsClosedWithoutOverwritingState() async throws {
        let unknownGroupID = UUID()
        let item = ClipboardHistoryItem(
            groupID: unknownGroupID,
            text: "unknown item group",
            sourceKind: .system
        )
        let rawState = try encodedPersistedState(items: [item])

        try await assertInvalidPersistedStateRemainsUntouched(
            rawState,
            forbiddenGroupIDs: [unknownGroupID]
        )
    }

    func testPersistedClipboardEntryWithUnknownGroupFailsClosedWithoutOverwritingState() async throws {
        let unknownGroupID = UUID()
        let rawState = try encodedPersistedState(
            groupEntries: [
                .init(groupID: unknownGroupID, itemIDs: []),
            ]
        )

        try await assertInvalidPersistedStateRemainsUntouched(
            rawState,
            forbiddenGroupIDs: [unknownGroupID]
        )
    }

    func testPersistedClipboardEntryWithMissingItemFailsClosedWithoutOverwritingState() async throws {
        let group = ClipboardGroup(name: "Missing item")
        let rawState = try encodedPersistedState(
            groups: [group],
            groupEntries: [
                .init(groupID: group.id, itemIDs: [UUID()]),
            ]
        )

        try await assertInvalidPersistedStateRemainsUntouched(
            rawState,
            forbiddenGroupIDs: [group.id]
        )
    }

    func testPersistedClipboardItemReferencedByMultipleEntriesFailsClosedWithoutOverwritingState() async throws {
        let item = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroupID,
            text: "multiply referenced item",
            sourceKind: .system
        )
        let state = DeliveryStack.PersistedClipboardState(
            schemaVersion: 8,
            items: [item],
            groups: [],
            groupEntries: [
                .init(groupID: ClipboardGroup.defaultGroupID, itemIDs: [item.id]),
            ],
            defaultGroupEntries: [item.id],
            defaultGroupMode: .stack,
            appAssignments: []
        )
        let rawState = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)

        try await assertInvalidPersistedStateRemainsUntouched(rawState)
    }

    func testPersistedClipboardEntryItemGroupMismatchFailsClosedWithoutOverwritingState() async throws {
        let itemGroup = ClipboardGroup(name: "Item group")
        let entryGroup = ClipboardGroup(name: "Entry group")
        let item = ClipboardHistoryItem(
            groupID: itemGroup.id,
            text: "mismatched item",
            sourceKind: .system
        )
        let rawState = try encodedPersistedState(
            items: [item],
            groups: [itemGroup, entryGroup],
            groupEntries: [
                .init(groupID: entryGroup.id, itemIDs: [item.id]),
            ]
        )

        try await assertInvalidPersistedStateRemainsUntouched(
            rawState,
            forbiddenGroupIDs: [itemGroup.id, entryGroup.id]
        )
    }

    func testPersistedClipboardAssignmentWithUnknownGroupFailsClosedWithoutOverwritingState() async throws {
        let unknownGroupID = UUID()
        let rawState = try encodedPersistedState(
            appAssignments: [
                ClipboardAppAssignment(
                    bundleIdentifier: "com.example.UnknownGroup",
                    applicationName: "Unknown Group",
                    groupID: unknownGroupID
                )
            ]
        )

        try await assertInvalidPersistedStateRemainsUntouched(
            rawState,
            routingContext: ClipboardRouteContext(
                bundleIdentifier: "com.example.UnknownGroup"
            ),
            forbiddenGroupIDs: [unknownGroupID]
        )
    }

    func testPersistedClipboardDefaultAssignmentRemainsValidAndNormalizesToNil() async throws {
        let rawState = try encodedPersistedState(
            appAssignments: [
                ClipboardAppAssignment(
                    bundleIdentifier: "com.example.DefaultGroup",
                    applicationName: "Default Group",
                    groupID: ClipboardGroup.defaultGroupID
                )
            ]
        )
        let settingsStore = RuntimeTestSettingsStore(
            storage: [.clipboardPersistedState: rawState]
        )
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore
        )

        let snapshot = await stack.clipboardSnapshot()

        XCTAssertEqual(snapshot.persistenceAvailability, .available)
        XCTAssertEqual(snapshot.appAssignments.count, 1)
        XCTAssertNil(snapshot.appAssignments.first?.groupID)
    }

    func testPersistedClipboardNonPositiveFallbackPriorityFailsClosedWithoutOverwritingState() async throws {
        let group = ClipboardGroup(
            name: "Invalid priority",
            allowsCrossGroupPaste: true,
            fallbackPriority: 0
        )
        let rawState = try encodedPersistedState(groups: [group])

        try await assertInvalidPersistedStateRemainsUntouched(
            rawState,
            forbiddenGroupIDs: [group.id]
        )
    }

    func testPersistedClipboardDuplicateFallbackPrioritiesFailClosedWithoutOverwritingState() async throws {
        let firstGroup = ClipboardGroup(
            name: "First priority",
            allowsCrossGroupPaste: true,
            fallbackPriority: 1
        )
        let secondGroup = ClipboardGroup(
            name: "Second priority",
            allowsCrossGroupPaste: true,
            fallbackPriority: 1
        )
        let rawState = try encodedPersistedState(groups: [firstGroup, secondGroup])

        try await assertInvalidPersistedStateRemainsUntouched(
            rawState,
            forbiddenGroupIDs: [firstGroup.id, secondGroup.id]
        )
    }

    func testSchemaFiveFallbackWithoutPriorityRemainsAValidLegacyUpgrade() async throws {
        let group = ClipboardGroup(
            name: "Legacy fallback",
            allowsCrossGroupPaste: true,
            fallbackPriority: nil,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let item = ClipboardHistoryItem(
            groupID: group.id,
            text: "legacy fallback item",
            createdAt: Date(timeIntervalSince1970: 20),
            sourceKind: .system
        )
        let rawState = try encodedPersistedState(
            schemaVersion: 5,
            items: [item],
            groups: [group],
            groupEntries: [
                .init(groupID: group.id, itemIDs: [item.id]),
            ]
        )
        let settingsStore = RuntimeTestSettingsStore(
            storage: [.clipboardPersistedState: rawState]
        )
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore
        )

        let snapshot = await stack.clipboardSnapshot()
        let routeSnapshot = await stack.routeSnapshot(for: ClipboardRouteContext())

        XCTAssertEqual(snapshot.persistenceAvailability, .available)
        XCTAssertEqual(
            snapshot.groups.first(where: { $0.group.id == group.id })?.group.fallbackPriority,
            nil
        )
        XCTAssertEqual(routeSnapshot.activeGroup.group.id, group.id)
        XCTAssertEqual(routeSnapshot.previewText, "legacy fallback item")
    }

    func testFailedClipboardPersistenceFlushRemainsObservableAndRetriesLatestRevision() async throws {
        let settingsStore = RuntimeTestSettingsStore(remainingWriteFailures: 1)
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore
        )
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "retry latest", changeCount: 1),
            context: ClipboardRouteContext()
        )

        let firstFlush = await stack.flushPendingPersistenceWrites()
        let failedSnapshot = await stack.clipboardSnapshot()
        let pendingAfterFailure = await stack.hasPendingPersistence
        let storedValueAfterFailure = await settingsStore.storedString(
            forKey: .clipboardPersistedState
        )
        XCTAssertEqual(firstFlush, .saveFailed)
        XCTAssertEqual(failedSnapshot.persistenceAvailability, .saveFailed)
        XCTAssertTrue(pendingAfterFailure)
        XCTAssertNil(storedValueAfterFailure)

        let retryFlush = await stack.flushPendingPersistenceWrites()
        let recoveredSnapshot = await stack.clipboardSnapshot()
        let pendingAfterRetry = await stack.hasPendingPersistence
        let storedValue = await settingsStore.storedString(forKey: .clipboardPersistedState)
        XCTAssertEqual(retryFlush, .persisted)
        XCTAssertEqual(recoveredSnapshot.persistenceAvailability, .available)
        XCTAssertFalse(pendingAfterRetry)
        XCTAssertTrue(try XCTUnwrap(storedValue).contains("retry latest"))
    }

    func testClipboardPersistenceSaveFailureAutomaticallyRetriesWithBackoff() async throws {
        let eventBus = EventBus()
        let eventStream = await eventBus.stream()
        let settingsStore = RuntimeTestSettingsStore(remainingWriteFailures: 1)
        let stack = DeliveryStack(
            eventBus: eventBus,
            clipboardPersistenceStore: settingsStore,
            persistenceRetryDelays: [.milliseconds(10)]
        )
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "automatic retry", changeCount: 1),
            context: ClipboardRouteContext()
        )

        let failedPublication = try await Self.nextClipboardUpdate(
            from: eventStream,
            until: { $0.persistenceAvailability == .saveFailed }
        )
        let storedValue = try await Self.waitForPersistedState(in: settingsStore) {
            $0.contains("automatic retry")
        }
        let recoveredSnapshot = try await Self.waitForSnapshot(from: stack) {
            $0.persistenceAvailability == .available
        }
        let attempts = await settingsStore.writeAttemptCount()

        XCTAssertEqual(failedPublication.persistenceAvailability, .saveFailed)
        XCTAssertTrue(storedValue.contains("automatic retry"))
        XCTAssertEqual(recoveredSnapshot.persistenceAvailability, .available)
        XCTAssertGreaterThanOrEqual(attempts, 2)
    }

    func testApplicationShutdownPersistenceDrainWaitsForBackoffAndRecovery() async throws {
        let settingsStore = RuntimeTestSettingsStore(remainingWriteFailures: 2)
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore,
            persistenceRetryDelays: [.milliseconds(20)]
        )
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "shutdown retry", changeCount: 1),
            context: ClipboardRouteContext()
        )

        let clock = ContinuousClock()
        let startedAt = clock.now
        let result = await stack.drainPersistenceForApplicationShutdown()
        let elapsed = startedAt.duration(to: clock.now)
        let attempts = await settingsStore.writeAttemptCount()
        let storedValue = await settingsStore.storedString(forKey: .clipboardPersistedState)

        XCTAssertEqual(result, .persisted)
        XCTAssertEqual(attempts, 3)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(35))
        XCTAssertTrue(try XCTUnwrap(storedValue).contains("shutdown retry"))
    }

    func testApplicationShutdownPersistenceDrainConvergesAfterCleanupPendingRetry() async throws {
        let settingsStore = RuntimeTestSettingsStore(
            storage: [.clipboardPersistedState: "protected-unreadable-clipboard-state"],
            unavailableKeys: [.clipboardPersistedState],
            remainingWriteFailures: 1,
            clipboardRemovalResult: .removedCleanupPending
        )
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore,
            persistenceRetryDelays: [.milliseconds(10)]
        )
        _ = await stack.clipboardSnapshot()
        let resetResult = await stack.resetUnavailablePersistedState()
        XCTAssertEqual(resetResult, .resetCleanupPending)

        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(
                plainText: "cleanup-pending shutdown retry",
                changeCount: 1
            ),
            context: ClipboardRouteContext()
        )

        let result = await stack.drainPersistenceForApplicationShutdown()
        let attempts = await settingsStore.writeAttemptCount()
        let snapshot = await stack.clipboardSnapshot()
        let storedValue = await settingsStore.storedString(forKey: .clipboardPersistedState)

        XCTAssertEqual(result, .persisted)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(snapshot.persistenceAvailability, .cleanupPending)
        XCTAssertTrue(
            try XCTUnwrap(storedValue).contains("cleanup-pending shutdown retry")
        )
    }

    func testPersistedClipboardSchemaSevenRequiresExactItemVersions() throws {
        let item = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroupID,
            text: "exact item",
            sourceKind: .system
        )
        let state = LegacyPersistedClipboardState(
            schemaVersion: 7,
            items: [item],
            groups: [],
            groupEntries: [],
            defaultGroupEntries: [item.id],
            defaultGroupMode: .stack,
            appAssignments: []
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )
        var items = try XCTUnwrap(object["items"] as? [[String: Any]])
        items[0].removeValue(forKey: "version")
        object["items"] = items
        let damagedData = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                DeliveryStack.PersistedClipboardState.self,
                from: damagedData
            )
        )

        object["schemaVersion"] = 6
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let upgraded = try JSONDecoder().decode(
            DeliveryStack.PersistedClipboardState.self,
            from: legacyData
        )
        XCTAssertEqual(upgraded.items.first?.version.revision, 1)

        object["schemaVersion"] = 8
        let futureData = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                DeliveryStack.PersistedClipboardState.self,
                from: futureData
            )
        )
    }

    func testLegacyClipboardVersionUpgradePersistsGenerationAcrossRestart() async throws {
        let item = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroupID,
            text: "legacy exact item",
            sourceKind: .system
        )
        let legacyState = LegacyPersistedClipboardState(
            schemaVersion: 5,
            items: [item],
            groups: [],
            groupEntries: [],
            defaultGroupEntries: [item.id],
            defaultGroupMode: .stack,
            appAssignments: []
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(legacyState)
            ) as? [String: Any]
        )
        var items = try XCTUnwrap(object["items"] as? [[String: Any]])
        items[0].removeValue(forKey: "version")
        object["items"] = items
        let settingsStore = RuntimeTestSettingsStore()
        try await settingsStore.setString(
            String(
                decoding: try JSONSerialization.data(withJSONObject: object),
                as: UTF8.self
            ),
            forKey: .clipboardPersistedState
        )

        let firstStack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore
        )
        let firstSnapshot = await firstStack.clipboardSnapshot()
        let upgradedVersion = try XCTUnwrap(firstSnapshot.items.first?.version)
        _ = try await Self.waitForPersistedState(in: settingsStore) { rawState in
            rawState.contains("\"schemaVersion\":8")
                && rawState.contains("\"generationID\"")
        }

        let restoredStack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore
        )
        let restoredSnapshot = await restoredStack.clipboardSnapshot()

        XCTAssertEqual(restoredSnapshot.items.first?.version, upgradedVersion)
    }

    func testClipboardStatePersistsAcrossRestarts() async throws {
        let eventBus = EventBus()
        let settingsStore = RuntimeTestSettingsStore()
        let initialStack = DeliveryStack(
            eventBus: eventBus,
            clipboardPersistenceStore: settingsStore
        )
        let notesGroup = (await initialStack.createGroup(named: "Notes")).group!
        await initialStack.setMode(.queue, forGroup: notesGroup.id)
        await initialStack.setAllowsCrossGroupPaste(true, forGroup: notesGroup.id)
        await initialStack.assignApplication(
            bundleIdentifier: "com.apple.Notes",
            applicationName: "Notes",
            toGroup: notesGroup.id
        )
        await initialStack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "remember this", changeCount: 1),
            context: ClipboardRouteContext(
                applicationName: "Notes",
                bundleIdentifier: "com.apple.Notes"
            )
        )
        _ = try await Self.waitForPersistedState(in: settingsStore) { rawState in
            rawState.contains("remember this") && rawState.contains("com.apple.Notes")
        }

        let restoredStack = DeliveryStack(
            eventBus: eventBus,
            clipboardPersistenceStore: settingsStore
        )
        let restoredSnapshot = try await Self.waitForSnapshot(from: restoredStack) { snapshot in
            snapshot.items.count == 1
                && snapshot.appAssignments.count == 1
                && snapshot.groups.contains(where: { $0.group.id == notesGroup.id })
        }

        XCTAssertEqual(restoredSnapshot.items.first?.text, "remember this")
        XCTAssertEqual(restoredSnapshot.items.first?.groupID, notesGroup.id)
        XCTAssertEqual(
            restoredSnapshot.groups.first(where: { $0.group.id == notesGroup.id })?.group.mode,
            .queue
        )
        XCTAssertEqual(
            restoredSnapshot.groups.first(where: { $0.group.id == notesGroup.id })?.group.allowsCrossGroupPaste,
            true
        )
        XCTAssertEqual(
            restoredSnapshot.groups.first(where: { $0.group.id == notesGroup.id })?.group.fallbackPriority,
            1
        )
        XCTAssertEqual(restoredSnapshot.appAssignments.first?.groupID, notesGroup.id)
    }

    func testRestoredFallbackPrioritiesRemainAuthoritativeForRouting() async throws {
        let settingsStore = RuntimeTestSettingsStore()
        let initialStack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore
        )
        let highPriorityGroup = (await initialStack.createGroup(named: "High priority")).group!
        let lowPriorityGroup = (await initialStack.createGroup(named: "Low priority")).group!
        await initialStack.setAllowsCrossGroupPaste(true, forGroup: highPriorityGroup.id)
        await initialStack.setAllowsCrossGroupPaste(true, forGroup: lowPriorityGroup.id)
        await initialStack.push(
            DeliveryItem(
                workflowID: UUID(),
                text: "older high-priority item",
                createdAt: Date(timeIntervalSince1970: 10),
                targetGroupID: highPriorityGroup.id
            )
        )
        await initialStack.push(
            DeliveryItem(
                workflowID: UUID(),
                text: "newer low-priority item",
                createdAt: Date(timeIntervalSince1970: 20),
                targetGroupID: lowPriorityGroup.id
            )
        )
        let persistenceResult = await initialStack.flushPendingPersistenceWrites()
        XCTAssertEqual(persistenceResult, .persisted)

        let restoredStack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore
        )
        let restoredSnapshot = await restoredStack.clipboardSnapshot()
        let routeSnapshot = await restoredStack.routeSnapshot(for: ClipboardRouteContext())

        XCTAssertEqual(
            restoredSnapshot.groups.first(where: { $0.group.id == highPriorityGroup.id })?
                .group.fallbackPriority,
            1
        )
        XCTAssertEqual(
            restoredSnapshot.groups.first(where: { $0.group.id == lowPriorityGroup.id })?
                .group.fallbackPriority,
            2
        )
        XCTAssertEqual(routeSnapshot.activeGroup.group.id, highPriorityGroup.id)
        XCTAssertEqual(routeSnapshot.previewText, "older high-priority item")
    }

    func testDeliveryFailureDescriptionsAreSanitizedBeforePersistence() async throws {
        let sentinel = "DO_NOT_LEAK_/Users/private/clipboard_API_KEY_123"
        let settingsStore = RuntimeTestSettingsStore()
        let context = ClipboardRouteContext()
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore
        )
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "retry me", changeCount: 1),
            context: context
        )
        let leaseCandidate = await stack.beginDeliveryLease(for: context)
        let lease = try XCTUnwrap(leaseCandidate)

        await stack.failDelivery(leaseID: lease.leaseID, error: sentinel)
        await stack.flushPendingPersistenceWrites()

        let snapshot = await stack.clipboardSnapshot()
        let storedState = try await settingsStore.string(forKey: .clipboardPersistedState)
        let rawState = try XCTUnwrap(storedState)
        XCTAssertEqual(
            snapshot.items.first?.latestError,
            ClipboardDeliveryFailureCode.deliveryFailed.rawValue
        )
        XCTAssertFalse(rawState.contains(sentinel))
        XCTAssertTrue(rawState.contains(ClipboardDeliveryFailureCode.deliveryFailed.rawValue))
    }

    func testLegacyPersistedDeliveryFailureIsSanitizedAndRewritten() async throws {
        let sentinel = "DO_NOT_LEAK_/Users/private/legacy_clipboard_API_KEY_123"
        let item = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroupID,
            text: "legacy retry",
            sourceKind: .system,
            latestError: sentinel
        )
        let state = LegacyPersistedClipboardState(
            schemaVersion: 6,
            items: [item],
            groups: [],
            groupEntries: [],
            defaultGroupEntries: [item.id],
            defaultGroupMode: .stack,
            appAssignments: []
        )
        let settingsStore = RuntimeTestSettingsStore()
        try await settingsStore.setString(
            String(decoding: try JSONEncoder().encode(state), as: UTF8.self),
            forKey: .clipboardPersistedState
        )

        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore
        )
        let snapshot = await stack.clipboardSnapshot()
        let rewritten = try await Self.waitForPersistedState(in: settingsStore) { rawState in
            rawState.contains(ClipboardDeliveryFailureCode.deliveryFailed.rawValue)
                && !rawState.contains(sentinel)
        }

        XCTAssertEqual(
            snapshot.items.first?.latestError,
            ClipboardDeliveryFailureCode.deliveryFailed.rawValue
        )
        XCTAssertFalse(rewritten.contains(sentinel))
    }

    func testDefaultGroupModePersistsAcrossRestarts() async throws {
        let eventBus = EventBus()
        let settingsStore = RuntimeTestSettingsStore()
        let initialStack = DeliveryStack(
            eventBus: eventBus,
            clipboardPersistenceStore: settingsStore
        )
        await initialStack.setMode(.queue, forGroup: ClipboardGroup.defaultGroup.id)
        await initialStack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "remember default mode", changeCount: 1),
            context: ClipboardRouteContext()
        )
        _ = try await Self.waitForPersistedState(in: settingsStore) { rawState in
            rawState.contains("remember default mode") && rawState.contains("\"defaultGroupMode\":\"queue\"")
        }

        let restoredStack = DeliveryStack(
            eventBus: eventBus,
            clipboardPersistenceStore: settingsStore
        )
        let restoredSnapshot = try await Self.waitForSnapshot(from: restoredStack) { snapshot in
            snapshot.items.count == 1 && snapshot.defaultGroup.group.mode == .queue
        }

        XCTAssertEqual(restoredSnapshot.defaultGroup.group.mode, .queue)
        XCTAssertEqual(restoredSnapshot.defaultGroup.previewText, "remember default mode")
    }

    func testBurstMutationsPublishImmediatelyAndDebouncePersistence() async throws {
        let eventBus = EventBus()
        let settingsStore = RuntimeTestSettingsStore()
        let stack = DeliveryStack(
            eventBus: eventBus,
            clipboardPersistenceStore: settingsStore
        )
        let eventStream = await eventBus.stream()

        await stack.push(DeliveryItem(workflowID: UUID(), text: "first"))

        let firstSnapshot = try await Self.nextClipboardUpdate(from: eventStream) { snapshot in
            snapshot.items.map(\.text) == ["first"]
        }
        XCTAssertEqual(firstSnapshot.items.map(\.text), ["first"])
        let writeCountBeforeDebounce = await settingsStore.writeCount(forKey: .clipboardPersistedState)
        XCTAssertEqual(writeCountBeforeDebounce, 0)

        await stack.push(DeliveryItem(workflowID: UUID(), text: "second"))
        await stack.push(DeliveryItem(workflowID: UUID(), text: "third"))

        _ = try await Self.waitForPersistedState(in: settingsStore) { rawState in
            rawState.contains("first") && rawState.contains("second") && rawState.contains("third")
        }
        let writeCountAfterDebounce = await settingsStore.writeCount(forKey: .clipboardPersistedState)
        XCTAssertEqual(writeCountAfterDebounce, 1)
    }

    func testFlushPendingPersistenceWritesLatestStateWithoutWaitingForDebounce() async throws {
        let settingsStore = RuntimeTestSettingsStore()
        let sleepGate = ControlledPersistenceSleepGate()
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore,
            persistenceSleep: { delay in
                try await sleepGate.sleep(for: delay)
            }
        )

        await stack.push(DeliveryItem(workflowID: UUID(), text: "shutdown state"))
        await sleepGate.waitUntilEntered()
        let writeCountBeforeFlush = await settingsStore.writeCount(
            forKey: .clipboardPersistedState
        )
        XCTAssertEqual(writeCountBeforeFlush, 0)

        await stack.flushPendingPersistenceWrites()

        let storedState = try await settingsStore.string(forKey: .clipboardPersistedState)
        let persistedState = try XCTUnwrap(storedState)
        XCTAssertTrue(persistedState.contains("shutdown state"))
        let writeCountAfterFlush = await settingsStore.writeCount(
            forKey: .clipboardPersistedState
        )
        XCTAssertEqual(writeCountAfterFlush, 1)

        await sleepGate.waitUntilCompleted()
        let sleepSnapshot = await sleepGate.snapshot()
        let writeCountAfterDebounceWindow = await settingsStore.writeCount(
            forKey: .clipboardPersistedState
        )
        XCTAssertEqual(sleepSnapshot.requestedDelays, [.milliseconds(250)])
        XCTAssertEqual(sleepSnapshot.cancellationCount, 1)
        XCTAssertEqual(sleepSnapshot.completionCount, 1)
        XCTAssertEqual(
            writeCountAfterDebounceWindow,
            1,
            "The cancelled debounce task must not write again after the shutdown flush."
        )
    }

    func testDeleteItemsRemovesMergedClipboardRowsInSingleMutation() async {
        let stack = DeliveryStack(eventBus: EventBus())
        let context = ClipboardRouteContext(
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes"
        )

        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "alpha", changeCount: 1),
            context: context
        )
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "beta", changeCount: 2),
            context: context
        )

        let initialSnapshot = await stack.clipboardSnapshot()
        XCTAssertEqual(initialSnapshot.items.map(\.text), ["beta", "alpha"])

        await stack.deleteItems(ids: initialSnapshot.items.map(\.id))

        let finalSnapshot = await stack.clipboardSnapshot()
        let routeSnapshot = await stack.routeSnapshot(for: context)

        XCTAssertTrue(finalSnapshot.items.isEmpty)
        XCTAssertTrue(finalSnapshot.groups.allSatisfy { $0.count == 0 })
        XCTAssertEqual(routeSnapshot.count, 0)
        let remainingLease = await stack.beginDeliveryLease(for: context)
        XCTAssertNil(remainingLease)
    }

    func testClipboardSnapshotTracksRemainingDeliverableItems() async {
        let stack = DeliveryStack(eventBus: EventBus())
        let context = ClipboardRouteContext(
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes"
        )

        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "alpha", changeCount: 1),
            context: context
        )
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "beta", changeCount: 2),
            context: context
        )

        let initialSnapshot = await stack.clipboardSnapshot()
        XCTAssertEqual(initialSnapshot.items.map(\.text), ["beta", "alpha"])
        XCTAssertEqual(
            initialSnapshot.remainingItemIDs,
            initialSnapshot.items.map(\.id)
        )

        let lease = await stack.beginDeliveryLease(for: context)
        XCTAssertEqual(lease?.item.text, "beta")

        let remainingSnapshot = await stack.clipboardSnapshot()
        XCTAssertEqual(remainingSnapshot.items.map(\.text), ["beta", "alpha"])
        XCTAssertEqual(
            remainingSnapshot.remainingItemIDs,
            remainingSnapshot.items
                .filter { $0.text == "alpha" }
                .map(\.id)
        )
    }

    private func encodedLegacyState(
        items: [ClipboardHistoryItem],
        appAssignments: [ClipboardAppAssignment]
    ) throws -> String {
        try encodedPersistedState(
            items: items,
            defaultGroupEntries: items.map(\.id),
            appAssignments: appAssignments
        )
    }

    private func encodedPersistedState(
        schemaVersion: Int = 7,
        items: [ClipboardHistoryItem] = [],
        groups: [ClipboardGroup] = [],
        groupEntries: [LegacyPersistedClipboardState.GroupEntry] = [],
        defaultGroupEntries: [UUID]? = [],
        appAssignments: [ClipboardAppAssignment] = []
    ) throws -> String {
        let state = LegacyPersistedClipboardState(
            schemaVersion: schemaVersion,
            items: items,
            groups: groups,
            groupEntries: groupEntries,
            defaultGroupEntries: defaultGroupEntries,
            defaultGroupMode: .stack,
            appAssignments: appAssignments
        )
        return String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
    }

    private func assertInvalidPersistedStateRemainsUntouched(
        _ rawState: String,
        routingContext: ClipboardRouteContext = ClipboardRouteContext(),
        forbiddenGroupIDs: Set<UUID> = []
    ) async throws {
        let settingsStore = RuntimeTestSettingsStore(
            storage: [.clipboardPersistedState: rawState]
        )
        let diagnostics = DiagnosticsRecorder()
        let stack = DeliveryStack(
            eventBus: EventBus(),
            diagnostics: diagnostics,
            clipboardPersistenceStore: settingsStore
        )

        let snapshotBeforeRoute = await stack.clipboardSnapshot()
        let routeSnapshot = await stack.routeSnapshot(for: routingContext)
        let snapshotAfterRoute = await stack.clipboardSnapshot()
        let flushResult = await stack.flushPendingPersistenceWrites()

        let storedValue = await settingsStore.storedString(forKey: .clipboardPersistedState)
        let writeCount = await settingsStore.writeCount(forKey: .clipboardPersistedState)
        let writeAttemptCount = await settingsStore.writeAttemptCount()
        let loadDiagnostic = await diagnostics.snapshot().first(where: {
            $0.event == "clipboard.state.load-failed"
        })
        XCTAssertTrue(snapshotBeforeRoute.items.isEmpty)
        XCTAssertTrue(snapshotAfterRoute.items.isEmpty)
        XCTAssertEqual(snapshotBeforeRoute.persistenceAvailability, .loadUnavailable)
        XCTAssertEqual(snapshotAfterRoute.persistenceAvailability, .loadUnavailable)
        XCTAssertEqual(routeSnapshot.activeGroup.group.id, ClipboardGroup.defaultGroupID)
        XCTAssertEqual(flushResult, .loadUnavailable)
        XCTAssertFalse(snapshotAfterRoute.groups.contains(where: {
            $0.group.name == "Recovered Group" || forbiddenGroupIDs.contains($0.group.id)
        }))
        XCTAssertEqual(storedValue, rawState)
        XCTAssertEqual(writeCount, 0)
        XCTAssertEqual(writeAttemptCount, 0)
        XCTAssertEqual(loadDiagnostic?.message, DiagnosticEventSanitizer.sanitizedMessage)
        XCTAssertEqual(loadDiagnostic?.metadata, [:])
    }

    private func waitForMaintenanceWaiterCount(
        _ expectedCount: Int,
        in stack: DeliveryStack
    ) async -> Bool {
        for _ in 0..<100 {
            if await stack.maintenanceWaiterCountForTesting() >= expectedCount {
                return true
            }
            await Task.yield()
        }
        return false
    }

}

private extension DeliveryStack {
    func maintenanceWaiterCountForTesting() -> Int {
        historyMaintenanceWaiters.count
    }
}
