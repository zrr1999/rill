import XCTest
@testable import RillCore
@testable import RillRuntime

private enum ClipboardSettingsStoreTestError: Error {
    case writeRejected
}

private actor FailingClipboardSettingsStore: ClipboardPersistenceStore {
    private var storage: [AppSettingKey: String] = [:]

    func loadClipboardPersistence() async throws -> ClipboardPersistenceReadSnapshot {
        .empty
    }

    func replaceClipboardPersistence(
        with _: ClipboardPersistenceWriteSnapshot
    ) async throws -> Int64 {
        throw ClipboardSettingsStoreTestError.writeRejected
    }

    func removeClipboardPersistence() async throws -> ClipboardPersistenceRemovalResult {
        .removed
    }
}

private actor BlockingClipboardSettingsStore: SettingsStore, ClipboardPersistenceStore {
    private var storage: [AppSettingKey: String] = [:]
    private var currentMetadata: Data?
    private var currentRevision: Int64?
    private var imageBlobsByID: [UUID: ClipboardPersistenceImageBlob] = [:]
    private var shouldBlockNextClipboardWrite = false
    private var blockedClipboardWriteCount = 0
    private var clipboardWriteCount = 0
    private var blockedWriteContinuations: [CheckedContinuation<Void, Never>] = []

    func string(forKey key: AppSettingKey) async throws -> String? {
        storage[key]
    }

    func setString(_ value: String, forKey key: AppSettingKey) async throws {
        if key == .clipboardPersistedState {
            if shouldBlockNextClipboardWrite {
                shouldBlockNextClipboardWrite = false
                blockedClipboardWriteCount += 1
                await withCheckedContinuation { continuation in
                    blockedWriteContinuations.append(continuation)
                }
            }
            clipboardWriteCount += 1
        }
        storage[key] = value
    }

    func setStringsAtomically(_ values: [AppSettingKey: String]) async throws {
        for (key, value) in values {
            storage[key] = value
        }
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
            throw ClipboardSettingsStoreTestError.writeRejected
        }
        if shouldBlockNextClipboardWrite {
            shouldBlockNextClipboardWrite = false
            blockedClipboardWriteCount += 1
            await withCheckedContinuation { continuation in
                blockedWriteContinuations.append(continuation)
            }
        }

        var nextBlobs: [UUID: ClipboardPersistenceImageBlob] = [:]
        for reference in snapshot.retainedImageBlobReferences {
            guard let blob = imageBlobsByID[reference.blobID],
                  blob.reference == reference else {
                throw ClipboardSettingsStoreTestError.writeRejected
            }
            nextBlobs[reference.blobID] = blob
        }
        for blob in snapshot.newImageBlobs {
            guard blob.reference.byteCount == blob.payload.count else {
                throw ClipboardSettingsStoreTestError.writeRejected
            }
            nextBlobs[blob.reference.blobID] = blob
        }

        clipboardWriteCount += 1
        let nextRevision = (currentRevision ?? 0) + 1
        currentMetadata = snapshot.metadata
        currentRevision = nextRevision
        imageBlobsByID = nextBlobs
        storage[.clipboardPersistedState] = String(decoding: snapshot.metadata, as: UTF8.self)
        return nextRevision
    }

    func removeClipboardPersistence() async throws -> ClipboardPersistenceRemovalResult {
        storage.removeValue(forKey: .clipboardPersistedState)
        currentMetadata = nil
        currentRevision = nil
        imageBlobsByID.removeAll()
        return .removed
    }

    func blockNextClipboardWrite() {
        shouldBlockNextClipboardWrite = true
    }

    func blockedWriteCount() -> Int {
        blockedClipboardWriteCount
    }

    func writeCount() -> Int {
        clipboardWriteCount
    }

    func releaseBlockedWrites() {
        let continuations = blockedWriteContinuations
        blockedWriteContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private actor MaintenanceOperationProbe {
    private var startedOperations: Set<String> = []
    private var completedOperations: Set<String> = []

    func start(_ operation: String) {
        startedOperations.insert(operation)
    }

    func complete(_ operation: String) {
        completedOperations.insert(operation)
    }

    func started() -> Set<String> {
        startedOperations
    }

    func completed() -> Set<String> {
        completedOperations
    }
}

extension DeliveryStackTests {
    func testActivePerGroupLimitRejectsNewestListItemWithoutEvictingExistingItems() async {
        let stack = DeliveryStack(eventBus: EventBus())
        await stack.setMode(.list, forGroup: ClipboardGroup.defaultGroupID)

        var finalResult: ClipboardStorageMutationResult?
        for index in 0...500 {
            finalResult = await stack.push(
                DeliveryItem(workflowID: UUID(), text: "list-\(index)")
            )
        }

        let snapshot = await stack.clipboardSnapshot()

        XCTAssertEqual(finalResult, .rejected(.activeItemLimitReached))
        XCTAssertEqual(snapshot.items.count, 500)
        XCTAssertEqual(snapshot.defaultGroup.count, 500)
        XCTAssertEqual(snapshot.items.first?.text, "list-499")
        XCTAssertEqual(snapshot.items.last?.text, "list-0")
        XCTAssertFalse(snapshot.items.contains { $0.text == "list-500" })
    }

    func testActivePerGroupLimitPreservesLeaseAndRejectsNewestIngress() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        await stack.push(DeliveryItem(workflowID: UUID(), text: "leased-oldest"))
        let leasedCandidate = await stack.beginDeliveryLease(for: ClipboardRouteContext())
        let lease = try XCTUnwrap(leasedCandidate)

        var finalResult: ClipboardStorageMutationResult?
        for index in 0..<500 {
            finalResult = await stack.push(
                DeliveryItem(workflowID: UUID(), text: "active-\(index)")
            )
        }

        let itemDuringLease = await stack.item(id: lease.item.id)
        let snapshotDuringLease = await stack.clipboardSnapshot()
        XCTAssertEqual(itemDuringLease?.text, "leased-oldest")
        XCTAssertEqual(finalResult, .rejected(.activeItemLimitReached))
        XCTAssertEqual(snapshotDuringLease.items.count, 500)
        XCTAssertFalse(snapshotDuringLease.items.contains { $0.text == "active-499" })

        await stack.completeDelivery(leaseID: lease.leaseID)
        let itemAfterLease = await stack.item(id: lease.item.id)
        XCTAssertEqual(itemAfterLease?.useCount, 1)
    }

    func testHistoryLimitEvictsOnlyOldestHistoryOnlyItems() async {
        let stack = DeliveryStack(eventBus: EventBus())

        for index in 0...500 {
            await stack.push(DeliveryItem(workflowID: UUID(), text: "history-\(index)"))
            guard let lease = await stack.beginDeliveryLease(for: ClipboardRouteContext()) else {
                XCTFail("Expected delivery lease for history-\(index)")
                return
            }
            await stack.completeDelivery(leaseID: lease.leaseID)
        }

        let snapshot = await stack.clipboardSnapshot()

        XCTAssertEqual(snapshot.items.count, 500)
        XCTAssertEqual(snapshot.items.first?.text, "history-500")
        XCTAssertEqual(snapshot.items.last?.text, "history-1")
        XCTAssertFalse(snapshot.items.contains { $0.text == "history-0" })
    }

    func testPruneHistoryRemovesOnlyExpiredHistoryOnlyItems() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let oldHistoryID = try await addHistoryOnlyItem(
            to: stack,
            text: "expired history",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let recentHistoryID = try await addHistoryOnlyItem(
            to: stack,
            text: "recent history",
            createdAt: Date(timeIntervalSince1970: 90)
        )
        let activeItem = DeliveryItem(
            workflowID: UUID(),
            text: "expired active",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        await stack.push(activeItem)

        let result = try await stack.pruneHistory(
            olderThan: Date(timeIntervalSince1970: 50)
        )
        let snapshot = await stack.clipboardSnapshot()
        let oldHistoryItem = await stack.item(id: oldHistoryID)
        let recentHistoryItem = await stack.item(id: recentHistoryID)
        let retainedActiveItem = await stack.item(id: activeItem.id)

        XCTAssertEqual(result, ClipboardCleanupResult(removedCount: 1, preservedActiveCount: 1))
        XCTAssertNil(oldHistoryItem)
        XCTAssertNotNil(recentHistoryItem)
        XCTAssertNotNil(retainedActiveItem)
        XCTAssertEqual(snapshot.defaultGroup.count, 1)
        XCTAssertEqual(snapshot.defaultGroup.previewText, "expired active")
    }

    func testClearHistoryPreservesActiveItems() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        _ = try await addHistoryOnlyItem(to: stack, text: "history one")
        _ = try await addHistoryOnlyItem(to: stack, text: "history two")
        let activeItem = DeliveryItem(workflowID: UUID(), text: "active")
        await stack.push(activeItem)

        let result = try await stack.clearHistory()
        let snapshot = await stack.clipboardSnapshot()

        XCTAssertEqual(result, ClipboardCleanupResult(removedCount: 2, preservedActiveCount: 1))
        XCTAssertEqual(snapshot.items.map(\.id), [activeItem.id])
        XCTAssertEqual(snapshot.remainingItemIDs, [activeItem.id])
    }

    func testClearHistoryDoesNotCommitWhenProtectedPersistenceFails() async throws {
        let settingsStore = FailingClipboardSettingsStore()
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore
        )
        let historyID = try await addHistoryOnlyItem(to: stack, text: "must survive")

        do {
            _ = try await stack.clearHistory()
            XCTFail("Expected protected clipboard-state persistence to fail")
        } catch ClipboardSettingsStoreTestError.writeRejected {
            // Expected: the in-memory commit must remain untouched.
        }

        let survivingItem = await stack.item(id: historyID)
        XCTAssertEqual(survivingItem?.text, "must survive")
    }

    func testClearHistoryWaitsForOldDebounceBeforeWritingSanitizedState() async throws {
        let settingsStore = BlockingClipboardSettingsStore()
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore
        )
        _ = try await addHistoryOnlyItem(to: stack, text: "remove old debounce")
        await settingsStore.blockNextClipboardWrite()
        try await waitForBlockedWrite(in: settingsStore, count: 1)

        let cleanupTask = Task { try await stack.clearHistory() }
        try await waitForMaintenanceGate(in: stack)
        let concurrentItem = DeliveryItem(workflowID: UUID(), text: "keep concurrent capture")
        let pushTask = Task { await stack.push(concurrentItem) }
        await settingsStore.releaseBlockedWrites()

        let result = try await cleanupTask.value
        _ = await pushTask.value
        let rawState = try await waitForPersistedState(in: settingsStore) { rawState in
            rawState.contains("keep concurrent capture")
                && !rawState.contains("remove old debounce")
        }
        let snapshot = await stack.clipboardSnapshot()

        XCTAssertEqual(result.removedCount, 1)
        XCTAssertFalse(rawState.contains("remove old debounce"))
        XCTAssertTrue(rawState.contains("keep concurrent capture"))
        XCTAssertEqual(snapshot.items.map(\.id), [concurrentItem.id])
    }

    func testClearHistoryBlocksConcurrentMutationsUntilSanitizedCommit() async throws {
        let settingsStore = BlockingClipboardSettingsStore()
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore
        )
        _ = try await addHistoryOnlyItem(to: stack, text: "remove during cleanup")
        _ = try await waitForPersistedState(in: settingsStore) { rawState in
            rawState.contains("remove during cleanup")
        }
        let activeItem = DeliveryItem(workflowID: UUID(), text: "active before cleanup")
        await stack.push(activeItem)
        let writesBeforeCleanup = await settingsStore.writeCount()
        await settingsStore.blockNextClipboardWrite()

        let cleanupTask = Task { try await stack.clearHistory() }
        try await waitForBlockedWrite(in: settingsStore, count: 1)
        let probe = MaintenanceOperationProbe()
        let concurrentItem = DeliveryItem(workflowID: UUID(), text: "captured while cleaning")
        let pushTask = Task {
            await probe.start("push")
            await stack.push(concurrentItem)
            await probe.complete("push")
        }
        let leaseTask = Task {
            await probe.start("lease")
            let lease = await stack.beginDeliveryLease(for: ClipboardRouteContext())
            await probe.complete("lease")
            return lease
        }
        let routeTask = Task {
            await probe.start("route")
            let snapshot = await stack.routeSnapshot(
                for: ClipboardRouteContext(
                    applicationName: "Concurrent Editor",
                    bundleIdentifier: "com.example.concurrent-editor"
                )
            )
            await probe.complete("route")
            return snapshot
        }
        try await waitForStartedOperations(in: probe, count: 3)
        let completedWhileBlocked = await probe.completed()
        XCTAssertTrue(completedWhileBlocked.isEmpty)
        await settingsStore.releaseBlockedWrites()

        let result = try await cleanupTask.value
        await pushTask.value
        _ = await leaseTask.value
        _ = await routeTask.value
        let rawState = try await waitForPersistedState(in: settingsStore) { rawState in
            rawState.contains("captured while cleaning")
                && rawState.contains("com.example.concurrent-editor")
                && !rawState.contains("remove during cleanup")
        }
        let writesAfterCleanup = await settingsStore.writeCount()
        let snapshot = await stack.clipboardSnapshot()

        XCTAssertEqual(result.removedCount, 1)
        XCTAssertGreaterThanOrEqual(writesAfterCleanup - writesBeforeCleanup, 2)
        XCTAssertFalse(rawState.contains("remove during cleanup"))
        XCTAssertTrue(rawState.contains("captured while cleaning"))
        XCTAssertTrue(snapshot.items.contains { $0.id == activeItem.id })
        XCTAssertTrue(snapshot.items.contains { $0.id == concurrentItem.id })
        let completedAfterCleanup = await probe.completed()
        XCTAssertEqual(completedAfterCleanup, Set(["lease", "push", "route"]))
    }

    private func addHistoryOnlyItem(
        to stack: DeliveryStack,
        text: String,
        createdAt: Date = Date()
    ) async throws -> UUID {
        let item = DeliveryItem(workflowID: UUID(), text: text, createdAt: createdAt)
        await stack.push(item)
        let leaseCandidate = await stack.beginDeliveryLease(for: ClipboardRouteContext())
        let lease = try XCTUnwrap(leaseCandidate)
        await stack.completeDelivery(leaseID: lease.leaseID)
        return item.id
    }

    private func waitForBlockedWrite(
        in settingsStore: BlockingClipboardSettingsStore,
        count: Int
    ) async throws {
        for _ in 0..<100 {
            if await settingsStore.blockedWriteCount() >= count {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for blocked clipboard-state persistence")
    }

    private func waitForMaintenanceGate(in stack: DeliveryStack) async throws {
        for _ in 0..<100 {
            if await stack.isHistoryMaintenanceActive {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for clipboard history maintenance gate")
    }

    private func waitForStartedOperations(
        in probe: MaintenanceOperationProbe,
        count: Int
    ) async throws {
        for _ in 0..<100 {
            if await probe.started().count >= count {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for concurrent clipboard operations to start")
    }

    private func waitForPersistedState(
        in settingsStore: BlockingClipboardSettingsStore,
        until predicate: (String) -> Bool
    ) async throws -> String {
        for _ in 0..<100 {
            if let rawState = try await settingsStore.string(forKey: .clipboardPersistedState),
               predicate(rawState) {
                return rawState
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let rawState = try await settingsStore.string(forKey: .clipboardPersistedState)
        return try XCTUnwrap(rawState)
    }
}
