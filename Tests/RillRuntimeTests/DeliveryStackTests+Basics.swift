import XCTest
@testable import RillCore
@testable import RillRuntime

extension DeliveryStackTests {
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

    func testPushRespectsExplicitTargetGroupID() async {
        let stack = DeliveryStack(eventBus: EventBus())

        await stack.push(
            DeliveryItem(
                workflowID: UUID(),
                text: "voice result",
                targetGroupID: ClipboardGroup.voiceGroupID
            )
        )

        let snapshot = await stack.clipboardSnapshot()

        XCTAssertEqual(snapshot.items.first?.groupID, ClipboardGroup.voiceGroupID)
        XCTAssertEqual(
            snapshot.groups.first(where: { $0.group.id == ClipboardGroup.voiceGroupID })?.count,
            1
        )
    }

    func testMarkUsedConsumesStackItemButKeepsHistoryRecord() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let itemID = UUID()

        await stack.push(
            DeliveryItem(
                id: itemID,
                workflowID: UUID(),
                text: "stack item"
            )
        )
        await stack.markUsed(itemID: itemID)

        let snapshot = await stack.clipboardSnapshot()
        let item = try XCTUnwrap(snapshot.items.first(where: { $0.id == itemID }))
        XCTAssertTrue(snapshot.remainingItemIDs.isEmpty)
        XCTAssertEqual(snapshot.defaultGroup.count, 0)
        XCTAssertEqual(item.text, "stack item")
        XCTAssertEqual(item.useCount, 1)
        XCTAssertNotNil(item.lastUsedAt)
    }

    func testMarkUsedConsumesQueueItemButKeepsHistoryRecord() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let itemID = UUID()
        await stack.setMode(.queue, forGroup: ClipboardGroup.defaultGroupID)

        await stack.push(
            DeliveryItem(
                id: itemID,
                workflowID: UUID(),
                text: "queue item"
            )
        )
        await stack.markUsed(itemID: itemID)

        let snapshot = await stack.clipboardSnapshot()
        let item = try XCTUnwrap(snapshot.items.first(where: { $0.id == itemID }))
        XCTAssertTrue(snapshot.remainingItemIDs.isEmpty)
        XCTAssertEqual(snapshot.defaultGroup.count, 0)
        XCTAssertEqual(item.text, "queue item")
        XCTAssertEqual(item.useCount, 1)
        XCTAssertNotNil(item.lastUsedAt)
    }

    func testMarkUsedKeepsListItemInCurrentStateAndHistory() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let itemID = UUID()
        await stack.setMode(.list, forGroup: ClipboardGroup.defaultGroupID)

        await stack.push(
            DeliveryItem(
                id: itemID,
                workflowID: UUID(),
                text: "list item"
            )
        )
        await stack.markUsed(itemID: itemID)

        let snapshot = await stack.clipboardSnapshot()
        let item = try XCTUnwrap(snapshot.items.first(where: { $0.id == itemID }))
        XCTAssertEqual(snapshot.remainingItemIDs, [itemID])
        XCTAssertEqual(snapshot.defaultGroup.count, 1)
        XCTAssertEqual(item.text, "list item")
        XCTAssertEqual(item.useCount, 1)
        XCTAssertNotNil(item.lastUsedAt)
    }

    func testVoiceGroupServesAsCrossGroupFallbackWhenAssignedGroupIsEmpty() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let safariContext = ClipboardRouteContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        let browserGroup = (await stack.createGroup(named: "Browser")).group!
        await stack.assignApplication(
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            toGroup: browserGroup.id
        )
        await stack.push(
            DeliveryItem(
                workflowID: UUID(),
                text: "voice result",
                targetGroupID: ClipboardGroup.voiceGroupID
            )
        )

        let routeSnapshot = await stack.routeSnapshot(for: safariContext)
        let leaseCandidate = await stack.beginDeliveryLease(for: safariContext)
        let lease = try XCTUnwrap(leaseCandidate)

        XCTAssertEqual(routeSnapshot.activeGroup.group.id, ClipboardGroup.voiceGroupID)
        XCTAssertEqual(routeSnapshot.previewText, "voice result")
        XCTAssertEqual(lease.item.groupID, ClipboardGroup.voiceGroupID)
        XCTAssertEqual(lease.item.text, "voice result")

        let afterLeaseSnapshot = await stack.clipboardSnapshot()
        XCTAssertEqual(
            afterLeaseSnapshot.groups.first(where: { $0.group.id == ClipboardGroup.voiceGroupID })?.count,
            0
        )
        XCTAssertTrue(afterLeaseSnapshot.remainingItemIDs.isEmpty)
        XCTAssertEqual(
            afterLeaseSnapshot.items.first(where: { $0.id == lease.item.id })?.text,
            "voice result"
        )

        await stack.completeDelivery(leaseID: lease.leaseID)
        let completedSnapshot = await stack.clipboardSnapshot()
        let completedItem = try XCTUnwrap(completedSnapshot.items.first(where: { $0.id == lease.item.id }))
        XCTAssertEqual(completedItem.useCount, 1)
        XCTAssertNotNil(completedItem.lastUsedAt)
    }

    func testAssignedGroupKeepsPriorityOverVoiceGroupFallback() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let safariContext = ClipboardRouteContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        let browserGroup = (await stack.createGroup(named: "Browser")).group!
        await stack.assignApplication(
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            toGroup: browserGroup.id
        )
        await stack.push(
            DeliveryItem(
                workflowID: UUID(),
                text: "voice result",
                targetGroupID: ClipboardGroup.voiceGroupID
            )
        )
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "browser item", changeCount: 1),
            context: safariContext
        )

        let routeSnapshot = await stack.routeSnapshot(for: safariContext)
        let leaseCandidate = await stack.beginDeliveryLease(for: safariContext)
        let lease = try XCTUnwrap(leaseCandidate)

        XCTAssertEqual(routeSnapshot.activeGroup.group.id, browserGroup.id)
        XCTAssertEqual(routeSnapshot.previewText, "browser item")
        XCTAssertEqual(lease.item.groupID, browserGroup.id)
        XCTAssertEqual(lease.item.text, "browser item")
    }

    func testDefaultGroupKeepsPriorityOverVoiceGroupFallbackForUnassignedApp() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let unassignedContext = ClipboardRouteContext(
            applicationName: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode"
        )
        await stack.push(
            DeliveryItem(
                workflowID: UUID(),
                text: "voice result",
                targetGroupID: ClipboardGroup.voiceGroupID
            )
        )
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "default item", changeCount: 1),
            context: ClipboardRouteContext()
        )

        let routeSnapshot = await stack.routeSnapshot(for: unassignedContext)
        let leaseCandidate = await stack.beginDeliveryLease(for: unassignedContext)
        let lease = try XCTUnwrap(leaseCandidate)

        XCTAssertEqual(routeSnapshot.activeGroup.group.id, ClipboardGroup.defaultGroupID)
        XCTAssertEqual(routeSnapshot.previewText, "default item")
        XCTAssertEqual(lease.item.groupID, ClipboardGroup.defaultGroupID)
        XCTAssertEqual(lease.item.text, "default item")
    }

    func testVoiceGroupQueueFallbackConsumesOldestItemFirst() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let safariContext = ClipboardRouteContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        let browserGroup = (await stack.createGroup(named: "Browser")).group!
        await stack.assignApplication(
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            toGroup: browserGroup.id
        )
        await stack.setMode(.queue, forGroup: ClipboardGroup.voiceGroupID)
        let oldestID = UUID()
        let newestID = UUID()
        await stack.push(
            DeliveryItem(
                id: oldestID,
                workflowID: UUID(),
                text: "voice oldest",
                createdAt: Date(timeIntervalSince1970: 10),
                targetGroupID: ClipboardGroup.voiceGroupID
            )
        )
        await stack.push(
            DeliveryItem(
                id: newestID,
                workflowID: UUID(),
                text: "voice newest",
                createdAt: Date(timeIntervalSince1970: 20),
                targetGroupID: ClipboardGroup.voiceGroupID
            )
        )

        let routeSnapshot = await stack.routeSnapshot(for: safariContext)
        let leaseCandidate = await stack.beginDeliveryLease(for: safariContext)
        let lease = try XCTUnwrap(leaseCandidate)

        XCTAssertEqual(routeSnapshot.activeGroup.group.id, ClipboardGroup.voiceGroupID)
        XCTAssertEqual(routeSnapshot.previewText, "voice oldest")
        XCTAssertEqual(lease.item.id, oldestID)
        XCTAssertEqual(lease.item.text, "voice oldest")

        let afterLeaseSnapshot = await stack.clipboardSnapshot()
        XCTAssertEqual(
            afterLeaseSnapshot.groups.first(where: { $0.group.id == ClipboardGroup.voiceGroupID })?.count,
            1
        )
        XCTAssertEqual(afterLeaseSnapshot.remainingItemIDs, [newestID])
    }

    func testLegacyPersistedVoiceGroupEnablesCrossGroupFallback() async throws {
        let eventBus = EventBus()
        let settingsStore = RuntimeTestSettingsStore()
        let encoder = JSONEncoder()
        let voiceItemID = UUID()
        let browserGroup = ClipboardGroup(name: "Browser")
        let legacyVoiceGroup = ClipboardGroup(
            id: ClipboardGroup.voiceGroupID,
            name: "语音识别",
            mode: .stack,
            allowsCrossGroupPaste: false
        )
        let legacyState = LegacyPersistedClipboardState(
            schemaVersion: 4,
            items: [
                ClipboardHistoryItem(
                    id: voiceItemID,
                    groupID: ClipboardGroup.voiceGroupID,
                    text: "legacy voice result",
                    createdAt: Date(timeIntervalSince1970: 10),
                    sourceKind: .rillWorkflow
                )
            ],
            groups: [legacyVoiceGroup, browserGroup],
            groupEntries: [
                .init(groupID: ClipboardGroup.voiceGroupID, itemIDs: [voiceItemID]),
                .init(groupID: browserGroup.id, itemIDs: []),
            ],
            defaultGroupEntries: [],
            defaultGroupMode: .stack,
            appAssignments: [
                ClipboardAppAssignment(
                    bundleIdentifier: "com.apple.Safari",
                    applicationName: "Safari",
                    groupID: browserGroup.id
                )
            ]
        )
        let stateData = try encoder.encode(legacyState)
        try await settingsStore.setString(
            String(decoding: stateData, as: UTF8.self),
            forKey: .clipboardPersistedState
        )
        let restoredStack = DeliveryStack(
            eventBus: eventBus,
            clipboardPersistenceStore: settingsStore
        )
        let safariContext = ClipboardRouteContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )

        let routeSnapshot = await restoredStack.routeSnapshot(for: safariContext)
        let leaseCandidate = await restoredStack.beginDeliveryLease(for: safariContext)
        let lease = try XCTUnwrap(leaseCandidate)

        XCTAssertEqual(routeSnapshot.activeGroup.group.id, ClipboardGroup.voiceGroupID)
        XCTAssertEqual(routeSnapshot.activeGroup.group.allowsCrossGroupPaste, true)
        XCTAssertEqual(routeSnapshot.previewText, "legacy voice result")
        XCTAssertEqual(lease.item.id, voiceItemID)
    }

    func testQueueModeDeliversOldestItemFirst() async {
        let stack = DeliveryStack(eventBus: EventBus())
        let context = ClipboardRouteContext(
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes"
        )
        let group = (await stack.createGroup(named: "Queue")).group!
        await stack.assignApplication(
            bundleIdentifier: "com.apple.Notes",
            applicationName: "Notes",
            toGroup: group.id
        )
        await stack.setMode(.queue, forGroup: group.id)

        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "first", changeCount: 1),
            context: context
        )
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "second", changeCount: 2),
            context: context
        )

        let queueSnapshot = await stack.clipboardSnapshot()
        let queueSummary = queueSnapshot.groups.first(where: { $0.group.id == group.id })
        XCTAssertEqual(previewTexts(in: queueSummary, from: queueSnapshot), ["first", "second"])

        let firstLease = await stack.beginDeliveryLease(for: context)
        XCTAssertEqual(firstLease?.item.text, "first")
        if let firstLease {
            await stack.completeDelivery(leaseID: firstLease.leaseID)
        }

        let secondLease = await stack.beginDeliveryLease(for: context)
        XCTAssertEqual(secondLease?.item.text, "second")
    }

}
