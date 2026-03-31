import XCTest
@testable import VoxTypeCore
@testable import VoxTypeRuntime

private actor RuntimeTestSettingsStore: SettingsStore {
    private var storage: [AppSettingKey: String] = [:]
    private var writeCounts: [AppSettingKey: Int] = [:]

    func string(forKey key: AppSettingKey) async throws -> String? {
        storage[key]
    }

    func setString(_ value: String, forKey key: AppSettingKey) async throws {
        storage[key] = value
        writeCounts[key, default: 0] += 1
    }

    func removeValue(forKey key: AppSettingKey) async throws {
        storage.removeValue(forKey: key)
    }

    func writeCount(forKey key: AppSettingKey) -> Int {
        writeCounts[key, default: 0]
    }
}

final class DeliveryStackTests: XCTestCase {
    func testPushAndPopFollowLifoOrder() async {
        let eventBus = EventBus()
        let stack = DeliveryStack(eventBus: eventBus)

        await stack.push(DeliveryItem(workflowID: UUID(), text: "first"))
        await stack.push(DeliveryItem(workflowID: UUID(), text: "second"))

        let firstPop = await stack.popNext()
        let secondPop = await stack.popNext()

        XCTAssertEqual(firstPop?.text, "second")
        XCTAssertEqual(secondPop?.text, "first")
        let snapshot = await stack.snapshot()
        XCTAssertEqual(snapshot.count, 0)
    }

    func testQueueModeDeliversOldestItemFirst() async {
        let stack = DeliveryStack(eventBus: EventBus())
        await stack.setMode(.queue, forGroup: ClipboardGroup.defaultGroup.id)

        await stack.push(DeliveryItem(workflowID: UUID(), text: "first"))
        await stack.push(DeliveryItem(workflowID: UUID(), text: "second"))

        let queueSnapshot = await stack.clipboardSnapshot()
        let queueSummary = queueSnapshot.groups.first(where: { $0.group.id == ClipboardGroup.defaultGroup.id })
        XCTAssertEqual(previewTexts(in: queueSummary, from: queueSnapshot), ["first", "second"])

        let firstLease = await stack.beginDeliveryLease(for: ClipboardRouteContext())
        XCTAssertEqual(firstLease?.item.text, "first")
        if let firstLease {
            await stack.completeDelivery(leaseID: firstLease.leaseID)
        }

        let secondLease = await stack.beginDeliveryLease(for: ClipboardRouteContext())
        XCTAssertEqual(secondLease?.item.text, "second")
    }

    func testListModeDoesNotConsumeItems() async {
        let stack = DeliveryStack(eventBus: EventBus())
        await stack.setMode(.list, forGroup: ClipboardGroup.defaultGroup.id)

        await stack.push(DeliveryItem(workflowID: UUID(), text: "persistent"))

        let listSnapshot = await stack.clipboardSnapshot()
        let listSummary = listSnapshot.groups.first(where: { $0.group.id == ClipboardGroup.defaultGroup.id })
        XCTAssertEqual(previewTexts(in: listSummary, from: listSnapshot), ["persistent"])

        let firstLease = await stack.beginDeliveryLease(for: ClipboardRouteContext())
        XCTAssertEqual(firstLease?.item.text, "persistent")
        if let firstLease {
            await stack.completeDelivery(leaseID: firstLease.leaseID)
        }

        let secondLease = await stack.beginDeliveryLease(for: ClipboardRouteContext())
        XCTAssertEqual(secondLease?.item.text, "persistent")
        let snapshot = await stack.snapshot()
        XCTAssertEqual(snapshot.count, 1)
    }

    func testGroupAssignmentKeepsApplicationStateIndependent() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let safariContext = ClipboardRouteContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        let xcodeContext = ClipboardRouteContext(
            applicationName: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode"
        )

        let workGroup = await stack.createGroup(named: "Work")
        await stack.assignApplication(
            bundleIdentifier: "com.apple.dt.Xcode",
            applicationName: "Xcode",
            toGroup: workGroup.id
        )

        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "safari item", changeCount: 1),
            context: safariContext
        )
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "xcode item", changeCount: 2),
            context: xcodeContext
        )

        let safariRoute = await stack.routeSnapshot(for: safariContext)
        let xcodeRoute = await stack.routeSnapshot(for: xcodeContext)
        XCTAssertEqual(safariRoute.activeGroup.group.id, ClipboardGroup.defaultGroup.id)
        XCTAssertEqual(xcodeRoute.activeGroup.group.id, workGroup.id)
        XCTAssertEqual(safariRoute.previewText, "safari item")
        XCTAssertEqual(xcodeRoute.previewText, "xcode item")

        let safariLeaseCandidate = await stack.beginDeliveryLease(for: safariContext)
        let safariLease = try XCTUnwrap(safariLeaseCandidate)
        XCTAssertEqual(safariLease.item.text, "safari item")
        await stack.completeDelivery(leaseID: safariLease.leaseID)

        let refreshedSafariRoute = await stack.routeSnapshot(for: safariContext)
        let refreshedXcodeRoute = await stack.routeSnapshot(for: xcodeContext)
        XCTAssertEqual(refreshedSafariRoute.count, 0)
        XCTAssertEqual(refreshedXcodeRoute.count, 1)

        let snapshot = await stack.clipboardSnapshot()
        XCTAssertEqual(
            snapshot.groups.first(where: { $0.group.id == ClipboardGroup.defaultGroup.id })?.count,
            0
        )
        XCTAssertEqual(
            snapshot.groups.first(where: { $0.group.id == workGroup.id })?.count,
            1
        )
    }

    func testAssignApplicationMovesExistingItemsIntoNewGroup() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let safariContext = ClipboardRouteContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )

        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "https://example.com", changeCount: 1),
            context: safariContext
        )
        let customGroup = await stack.createGroup(named: "Browser")
        await stack.assignApplication(
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            toGroup: customGroup.id
        )

        let snapshot = await stack.clipboardSnapshot()
        XCTAssertEqual(snapshot.items.first?.groupID, customGroup.id)
        XCTAssertEqual(
            snapshot.groups.first(where: { $0.group.id == ClipboardGroup.defaultGroup.id })?.count,
            0
        )
        XCTAssertEqual(
            snapshot.groups.first(where: { $0.group.id == customGroup.id })?.count,
            1
        )
        XCTAssertEqual(snapshot.appAssignments.first?.groupID, customGroup.id)
    }

    func testClipboardStatePersistsAcrossRestarts() async throws {
        let eventBus = EventBus()
        let settingsStore = RuntimeTestSettingsStore()
        let initialStack = DeliveryStack(eventBus: eventBus, settingsStore: settingsStore)
        let notesGroup = await initialStack.createGroup(named: "Notes")
        await initialStack.setMode(.queue, forGroup: notesGroup.id)
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

        let restoredStack = DeliveryStack(eventBus: eventBus, settingsStore: settingsStore)
        let restoredSnapshot = try await Self.waitForSnapshot(from: restoredStack) { snapshot in
            snapshot.items.count == 1 && snapshot.appAssignments.count == 1 && snapshot.groups.count >= 2
        }

        XCTAssertEqual(restoredSnapshot.items.first?.text, "remember this")
        XCTAssertEqual(restoredSnapshot.items.first?.groupID, notesGroup.id)
        XCTAssertEqual(
            restoredSnapshot.groups.first(where: { $0.group.id == notesGroup.id })?.group.mode,
            .queue
        )
        XCTAssertEqual(restoredSnapshot.appAssignments.first?.groupID, notesGroup.id)
    }

    func testBurstMutationsPublishImmediatelyAndDebouncePersistence() async throws {
        let eventBus = EventBus()
        let settingsStore = RuntimeTestSettingsStore()
        let stack = DeliveryStack(eventBus: eventBus, settingsStore: settingsStore)
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
        XCTAssertEqual(
            finalSnapshot.groups.first(where: { $0.group.id == ClipboardGroup.defaultGroup.id })?.count,
            0
        )
        XCTAssertEqual(routeSnapshot.count, 0)
        let remainingLease = await stack.beginDeliveryLease(for: context)
        XCTAssertNil(remainingLease)
    }

    func testImageClipboardItemsParticipateInDefaultGroupDelivery() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let context = ClipboardRouteContext(
            applicationName: "Preview",
            bundleIdentifier: "com.apple.Preview"
        )

        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "queued text", changeCount: 1),
            context: context
        )
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "", imagePNGData: imageData, changeCount: 2),
            context: context
        )

        let storeSnapshot = await stack.clipboardSnapshot()
        XCTAssertEqual(storeSnapshot.items.count, 2)
        XCTAssertEqual(storeSnapshot.items.first?.contentKind, .image)
        XCTAssertEqual(storeSnapshot.items.first?.imagePNGData, imageData)
        XCTAssertFalse(storeSnapshot.items.first?.supportsWorkflowReplay ?? true)
        XCTAssertTrue(storeSnapshot.items.first?.supportsDirectPaste ?? false)
        XCTAssertEqual(storeSnapshot.items.first?.clipboardSnapshot.plainText, "")

        let routeSnapshot = await stack.routeSnapshot(for: context)
        XCTAssertEqual(routeSnapshot.count, 2)
        XCTAssertEqual(routeSnapshot.previewText, "Copied image")
        XCTAssertEqual(routeSnapshot.previewContentKind, .image)
        XCTAssertEqual(routeSnapshot.previewSnapshot?.imagePNGData, imageData)

        let leaseCandidate = await stack.beginDeliveryLease(for: context)
        let lease = try XCTUnwrap(leaseCandidate)
        XCTAssertEqual(lease.item.contentKind, .image)
        XCTAssertEqual(lease.item.imagePNGData, imageData)
        await stack.completeDelivery(leaseID: lease.leaseID)

        let refreshedRouteSnapshot = await stack.routeSnapshot(for: context)
        XCTAssertEqual(refreshedRouteSnapshot.count, 1)
        XCTAssertEqual(refreshedRouteSnapshot.previewText, "queued text")
    }

    func testImageClipboardItemsParticipateInQueueMode() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let context = ClipboardRouteContext(
            applicationName: "Preview",
            bundleIdentifier: "com.apple.Preview"
        )
        await stack.setMode(.queue, forGroup: ClipboardGroup.defaultGroup.id)

        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "", imagePNGData: imageData, changeCount: 1),
            context: context
        )
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "later text", changeCount: 2),
            context: context
        )

        let routeSnapshot = await stack.routeSnapshot(for: context)
        XCTAssertEqual(routeSnapshot.count, 2)
        XCTAssertEqual(routeSnapshot.previewContentKind, .image)
        XCTAssertEqual(routeSnapshot.previewSnapshot?.imagePNGData, imageData)

        let leaseCandidate = await stack.beginDeliveryLease(for: context)
        let lease = try XCTUnwrap(leaseCandidate)
        XCTAssertEqual(lease.item.contentKind, .image)
        await stack.completeDelivery(leaseID: lease.leaseID)

        let refreshedRouteSnapshot = await stack.routeSnapshot(for: context)
        XCTAssertEqual(refreshedRouteSnapshot.count, 1)
        XCTAssertEqual(refreshedRouteSnapshot.previewText, "later text")
    }

    func testImageClipboardItemsParticipateInListModeWithoutConsumption() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let context = ClipboardRouteContext(
            applicationName: "Preview",
            bundleIdentifier: "com.apple.Preview"
        )
        await stack.setMode(.list, forGroup: ClipboardGroup.defaultGroup.id)

        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "", imagePNGData: imageData, changeCount: 1),
            context: context
        )

        let firstLeaseCandidate = await stack.beginDeliveryLease(for: context)
        let firstLease = try XCTUnwrap(firstLeaseCandidate)
        XCTAssertEqual(firstLease.item.contentKind, .image)
        await stack.completeDelivery(leaseID: firstLease.leaseID)

        let secondLeaseCandidate = await stack.beginDeliveryLease(for: context)
        let secondLease = try XCTUnwrap(secondLeaseCandidate)
        XCTAssertEqual(secondLease.item.contentKind, .image)

        let routeSnapshot = await stack.routeSnapshot(for: context)
        XCTAssertEqual(routeSnapshot.count, 1)
        XCTAssertEqual(routeSnapshot.previewContentKind, .image)
    }

    func testFileClipboardItemsPersistAcrossRestartsWithoutEnteringDeliveryQueue() async throws {
        let eventBus = EventBus()
        let settingsStore = RuntimeTestSettingsStore()
        let initialStack = DeliveryStack(eventBus: eventBus, settingsStore: settingsStore)
        let context = ClipboardRouteContext(
            applicationName: "Finder",
            bundleIdentifier: "com.apple.finder"
        )
        let fileURLs = [
            URL(fileURLWithPath: "/tmp/alpha.txt"),
            URL(fileURLWithPath: "/tmp/beta.png"),
        ]

        await initialStack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "", fileURLs: fileURLs, changeCount: 1),
            context: context
        )
        _ = try await Self.waitForPersistedState(in: settingsStore) { rawState in
            rawState.contains("alpha.txt") && rawState.contains("beta.png") && rawState.contains("com.apple.finder")
        }

        let restoredStack = DeliveryStack(eventBus: eventBus, settingsStore: settingsStore)
        let restoredSnapshot = try await Self.waitForSnapshot(from: restoredStack) { snapshot in
            snapshot.items.count == 1
        }

        let item = try XCTUnwrap(restoredSnapshot.items.first)
        XCTAssertEqual(item.contentKind, .files)
        XCTAssertEqual(item.fileURLs, fileURLs)
        XCTAssertEqual(item.text, "alpha.txt, beta.png")
        XCTAssertTrue(item.supportsDirectPaste)
        XCTAssertFalse(item.supportsWorkflowReplay)
        XCTAssertEqual(
            restoredSnapshot.groups.first(where: { $0.group.id == ClipboardGroup.defaultGroup.id })?.count,
            0
        )
        let restoredLease = await restoredStack.beginDeliveryLease(for: context)
        XCTAssertNil(restoredLease)
    }

    func testRouteSnapshotPreservesCaptureTagsForMirroredWorkflowItems() async {
        let stack = DeliveryStack(eventBus: EventBus())
        let protectedItem = DeliveryItem(
            workflowID: UUID(),
            text: "protected",
            captureTags: [.excludeFromWorkflowCapture]
        )
        await stack.push(protectedItem)

        let routeSnapshot = await stack.routeSnapshot(for: ClipboardRouteContext())

        XCTAssertEqual(routeSnapshot.previewText, "protected")
        XCTAssertEqual(routeSnapshot.previewCaptureTags, [.excludeFromWorkflowCapture])
    }

    func testGroupSummaryIncludesMultiplePreviewItemsInStackOrder() async {
        let stack = DeliveryStack(eventBus: EventBus())

        await stack.push(DeliveryItem(workflowID: UUID(), text: "first"))
        await stack.push(DeliveryItem(workflowID: UUID(), text: "second"))
        await stack.push(DeliveryItem(workflowID: UUID(), text: "third"))
        await stack.push(DeliveryItem(workflowID: UUID(), text: "fourth"))

        let snapshot = await stack.clipboardSnapshot()
        let summary = snapshot.groups.first(where: { $0.group.id == ClipboardGroup.defaultGroup.id })

        XCTAssertEqual(previewTexts(in: summary, from: snapshot), ["fourth", "third", "second"])
    }

    func testGroupSummaryIncludesMultiplePreviewItemsInQueueOrder() async {
        let stack = DeliveryStack(eventBus: EventBus())
        await stack.setMode(.queue, forGroup: ClipboardGroup.defaultGroup.id)

        await stack.push(DeliveryItem(workflowID: UUID(), text: "first"))
        await stack.push(DeliveryItem(workflowID: UUID(), text: "second"))
        await stack.push(DeliveryItem(workflowID: UUID(), text: "third"))
        await stack.push(DeliveryItem(workflowID: UUID(), text: "fourth"))

        let snapshot = await stack.clipboardSnapshot()
        let summary = snapshot.groups.first(where: { $0.group.id == ClipboardGroup.defaultGroup.id })

        XCTAssertEqual(previewTexts(in: summary, from: snapshot), ["first", "second", "third"])
    }

    func testGroupSummaryIncludesMultiplePreviewItemsWithImages() async {
        let stack = DeliveryStack(eventBus: EventBus())
        let context = ClipboardRouteContext(
            applicationName: "Preview",
            bundleIdentifier: "com.apple.Preview"
        )

        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "alpha", changeCount: 1),
            context: context
        )
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "", imagePNGData: Data([0x89, 0x50]), changeCount: 2),
            context: context
        )
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "beta", changeCount: 3),
            context: context
        )

        let snapshot = await stack.clipboardSnapshot()
        let summary = snapshot.groups.first(where: { $0.group.id == ClipboardGroup.defaultGroup.id })

        XCTAssertEqual(previewTexts(in: summary, from: snapshot), ["beta", "Copied image", "alpha"])
    }

    private static func waitForSnapshot(
        from stack: DeliveryStack,
        until predicate: (ClipboardStoreSnapshot) -> Bool
    ) async throws -> ClipboardStoreSnapshot {
        for _ in 0..<50 {
            let snapshot = await stack.clipboardSnapshot()
            if predicate(snapshot) {
                return snapshot
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        return await stack.clipboardSnapshot()
    }

    private static func waitForPersistedState(
        in settingsStore: RuntimeTestSettingsStore,
        until predicate: (String) -> Bool
    ) async throws -> String {
        for _ in 0..<80 {
            if let rawState = try await settingsStore.string(forKey: .clipboardPersistedState), predicate(rawState) {
                return rawState
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        let rawState = try await settingsStore.string(forKey: .clipboardPersistedState)
        return try XCTUnwrap(rawState)
    }

    private static func nextClipboardUpdate(
        from stream: AsyncStream<VoxTypeEvent>,
        until predicate: @escaping @Sendable (ClipboardStoreSnapshot) -> Bool = { _ in true }
    ) async throws -> ClipboardStoreSnapshot {
        try await withThrowingTaskGroup(of: ClipboardStoreSnapshot.self) { group in
            group.addTask {
                for await event in stream {
                    if case .clipboardUpdated(let snapshot) = event, predicate(snapshot) {
                        return snapshot
                    }
                }
                throw CancellationError()
            }

            group.addTask {
                try await Task.sleep(for: .seconds(1))
                throw CancellationError()
            }

            let nextSnapshot = try await group.next()
            let snapshot = try XCTUnwrap(nextSnapshot)
            group.cancelAll()
            return snapshot
        }
    }

    private func previewTexts(
        in summary: ClipboardGroupSummary?,
        from snapshot: ClipboardStoreSnapshot
    ) -> [String] {
        guard let summary else { return [] }
        let itemsByID = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        return summary.previewItemIDs.compactMap { itemsByID[$0]?.text }
    }
}
