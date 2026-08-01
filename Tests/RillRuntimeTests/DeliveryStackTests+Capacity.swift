import XCTest
@testable import RillCore
@testable import RillRuntime

extension DeliveryStackTests {
    func testEmptyImageCaptureDoesNotCreateAnUnpersistableBlob() async {
        let stack = DeliveryStack(eventBus: EventBus())

        let emptyOnlyResult = await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(
                plainText: "",
                imagePNGData: Data(),
                changeCount: 1
            ),
            context: ClipboardRouteContext(),
            disposition: .historyAndWorkflows
        )
        let textResult = await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(
                plainText: "fallback text",
                imagePNGData: Data(),
                changeCount: 2
            ),
            context: ClipboardRouteContext(),
            disposition: .historyAndWorkflows
        )
        let snapshot = await stack.clipboardSnapshot()

        XCTAssertTrue(emptyOnlyResult.wasAccepted)
        XCTAssertTrue(textResult.wasAccepted)
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items.first?.contentKind, .text)
        XCTAssertNil(snapshot.items.first?.imagePNGData)
    }

    func testDirectEmptyImageItemIsRejectedBeforePersistence() async {
        let stack = DeliveryStack(eventBus: EventBus())
        let item = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroupID,
            contentKind: .image,
            text: "Copied image",
            imagePNGData: Data(),
            sourceKind: .system
        )

        let rejection = await stack.rawItemStorageRejectionReason(for: item)

        XCTAssertEqual(rejection, .imageRepresentationInvalid)
    }

    func testImageCapacityAccountingUsesRawBytesWithoutBase64Expansion() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        var imageItem = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroupID,
            contentKind: .image,
            text: "Copied image",
            imagePNGData: Data(repeating: 0xFF, count: 4_097),
            sourceKind: .system
        )
        let imageByteCount = try XCTUnwrap(imageItem.imagePNGData?.count)
        let accountedWithImage = try await stack.accountedEncodedItemByteCount(
            for: imageItem
        )
        imageItem.imagePNGData = nil
        let accountedWithoutImage = try await stack.accountedEncodedItemByteCount(
            for: imageItem
        )

        XCTAssertEqual(
            accountedWithImage - accountedWithoutImage,
            imageByteCount
        )
    }

    func testFullActiveBudgetRejectsNewIngressWithoutEvictingAnyMode() async {
        for mode in ClipboardPasteMode.allCases {
            var limits = ClipboardStorageLimits.productDefault
            limits.maximumActiveItemCount = 2
            limits.maximumActiveItemCountPerGroup = 2
            let stack = DeliveryStack(eventBus: EventBus(), storageLimits: limits)
            await stack.setMode(mode, forGroup: ClipboardGroup.defaultGroupID)

            let first = DeliveryItem(workflowID: UUID(), text: "first")
            let second = DeliveryItem(workflowID: UUID(), text: "second")
            let rejected = DeliveryItem(workflowID: UUID(), text: "rejected")
            let firstResult = await stack.push(first)
            let secondResult = await stack.push(second)
            XCTAssertTrue(firstResult.wasAccepted)
            XCTAssertTrue(secondResult.wasAccepted)

            let result = await stack.push(rejected)
            let snapshot = await stack.clipboardSnapshot()

            XCTAssertEqual(result, .rejected(.activeItemLimitReached), "mode=\(mode)")
            XCTAssertEqual(snapshot.items.map(\.id), [second.id, first.id], "mode=\(mode)")
            XCTAssertEqual(snapshot.remainingItemIDs, [second.id, first.id], "mode=\(mode)")
            XCTAssertEqual(snapshot.lastStorageRejection, .activeItemLimitReached)
            XCTAssertEqual(snapshot.storagePressureContext, .mutationRejected)
        }
    }

    func testSingleItemUTF8AndImageByteBoundariesRejectWithoutMutation() async {
        var limits = ClipboardStorageLimits.productDefault
        limits.maximumTextUTF8ByteCount = 4
        limits.maximumImageByteCount = 4
        let stack = DeliveryStack(eventBus: EventBus(), storageLimits: limits)

        let acceptedText = await stack.push(
            DeliveryItem(workflowID: UUID(), text: "éé")
        )
        let snapshotBeforeTextRejection = await stack.clipboardSnapshot()
        let rejectedText = await stack.push(
            DeliveryItem(workflowID: UUID(), text: "ééé")
        )
        let snapshotAfterTextRejection = await stack.clipboardSnapshot()

        XCTAssertTrue(acceptedText.wasAccepted)
        XCTAssertEqual(rejectedText, .rejected(.itemTooLarge))
        XCTAssertEqual(
            snapshotAfterTextRejection.items.map(\.id),
            snapshotBeforeTextRejection.items.map(\.id)
        )

        var imageLimits = ClipboardStorageLimits.productDefault
        imageLimits.maximumImageByteCount = 4
        let imageStack = DeliveryStack(eventBus: EventBus(), storageLimits: imageLimits)
        let acceptedImage = await imageStack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(
                plainText: "",
                imagePNGData: Data(repeating: 1, count: 4),
                changeCount: 1
            ),
            context: ClipboardRouteContext(),
            disposition: .historyAndWorkflows
        )
        let snapshotBeforeImageRejection = await imageStack.clipboardSnapshot()
        let rejectedImage = await imageStack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(
                plainText: "",
                imagePNGData: Data(repeating: 2, count: 5),
                changeCount: 2
            ),
            context: ClipboardRouteContext(),
            disposition: .historyAndWorkflows
        )
        let snapshotAfterImageRejection = await imageStack.clipboardSnapshot()

        XCTAssertTrue(acceptedImage.wasAccepted)
        XCTAssertEqual(rejectedImage, .rejected(.itemTooLarge))
        XCTAssertEqual(
            snapshotAfterImageRejection.items.map(\.id),
            snapshotBeforeImageRejection.items.map(\.id)
        )
    }

    func testNonTextAndMetadataShapesRejectBeforeItemEncoding() async {
        var limits = ClipboardStorageLimits.productDefault
        limits.maximumTextUTF8ByteCount = 4
        limits.maximumCaptureTagCount = 1
        limits.maximumWorkflowNameUTF8ByteCount = 4
        limits.maximumSourceApplicationNameUTF8ByteCount = 4
        limits.maximumSourceBundleIdentifierUTF8ByteCount = 4
        let stack = DeliveryStack(eventBus: EventBus(), storageLimits: limits)

        let oversizedNonText = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroupID,
            contentKind: .image,
            text: "12345",
            imagePNGData: Data([1]),
            sourceKind: .system
        )
        let duplicateCaptureTags = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroupID,
            text: "ok",
            captureTags: [.polishGenerated, .polishGenerated],
            sourceKind: .system
        )
        let oversizedWorkflowName = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroupID,
            workflow: WorkflowPresentation(fallbackName: "12345"),
            text: "ok",
            sourceKind: .rillWorkflow
        )
        let oversizedSourceName = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroupID,
            text: "ok",
            sourceKind: .system,
            sourceApplicationName: "12345"
        )
        let oversizedBundleIdentifier = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroupID,
            text: "ok",
            sourceKind: .system,
            sourceBundleIdentifier: "12345"
        )

        for item in [
            oversizedNonText,
            duplicateCaptureTags,
            oversizedWorkflowName,
            oversizedSourceName,
            oversizedBundleIdentifier,
        ] {
            let result = await stack.store(item, inGroup: item.groupID)
            XCTAssertEqual(result, .rejected(.itemTooLarge))
        }
        let snapshot = await stack.clipboardSnapshot()
        XCTAssertTrue(snapshot.items.isEmpty)
    }

    func testGroupAndApplicationMetadataLimitsRejectAtomically() async throws {
        var limits = ClipboardStorageLimits.productDefault
        limits.maximumCustomGroupCount = 1
        limits.maximumGroupNameUTF8ByteCount = 4
        limits.maximumApplicationAssignmentCount = 1
        limits.maximumAssignmentApplicationNameUTF8ByteCount = 4
        limits.maximumAssignmentBundleIdentifierUTF8ByteCount = 4
        let stack = DeliveryStack(eventBus: EventBus(), storageLimits: limits)

        let oversizedGroup = await stack.createGroup(named: "12345")
        XCTAssertEqual(oversizedGroup, .rejected(.metadataLimitReached))
        let createdGroupResult = await stack.createGroup(named: "Work")
        let createdGroup = try XCTUnwrap(createdGroupResult.group)
        let excessGroup = await stack.createGroup(named: "More")
        XCTAssertEqual(excessGroup, .rejected(.metadataLimitReached))

        var assignment = await stack.assignApplication(
            bundleIdentifier: "toolx",
            applicationName: "Tool",
            toGroup: createdGroup.id
        )
        XCTAssertEqual(assignment, .rejected(.metadataLimitReached))
        assignment = await stack.assignApplication(
            bundleIdentifier: "one",
            applicationName: "12345",
            toGroup: createdGroup.id
        )
        XCTAssertEqual(assignment, .rejected(.metadataLimitReached))
        assignment = await stack.assignApplication(
            bundleIdentifier: "one",
            applicationName: "One",
            toGroup: createdGroup.id
        )
        XCTAssertTrue(assignment.wasAccepted)
        assignment = await stack.assignApplication(
            bundleIdentifier: "two",
            applicationName: "Two",
            toGroup: createdGroup.id
        )
        XCTAssertEqual(assignment, .rejected(.metadataLimitReached))

        let snapshot = await stack.clipboardSnapshot()
        let customGroupIDs = snapshot.groups.map(\.group.id).filter {
            !ClipboardGroup.reservedGroupIDs.contains($0)
        }
        XCTAssertEqual(customGroupIDs, [createdGroup.id])
        XCTAssertEqual(snapshot.appAssignments.map(\.bundleIdentifier), ["one"])
    }

    func testHistoryOnlyItemsAreEvictedOldestFirstToAdmitNewItem() async throws {
        var limits = ClipboardStorageLimits.productDefault
        limits.maximumHistoryOnlyItemCount = 2
        let stack = DeliveryStack(eventBus: EventBus(), storageLimits: limits)

        for text in ["oldest", "middle", "newest"] {
            let result = await stack.push(DeliveryItem(workflowID: UUID(), text: text))
            XCTAssertTrue(result.wasAccepted)
            let leaseCandidate = await stack.beginDeliveryLease(for: ClipboardRouteContext())
            let lease = try XCTUnwrap(leaseCandidate)
            await stack.completeDelivery(leaseID: lease.leaseID)
        }

        let snapshot = await stack.clipboardSnapshot()
        XCTAssertEqual(snapshot.items.map(\.text), ["newest", "middle"])
        XCTAssertFalse(snapshot.items.contains { $0.text == "oldest" })
    }

    func testHistoryCapacityPreservesPinnedItemAndEvictsOldestUnpinnedItem() async throws {
        var limits = ClipboardStorageLimits.productDefault
        limits.maximumHistoryOnlyItemCount = 2
        let stack = DeliveryStack(eventBus: EventBus(), storageLimits: limits)

        var itemIDsByText: [String: UUID] = [:]
        for text in ["pinned oldest", "evictable middle", "newest"] {
            let item = DeliveryItem(workflowID: UUID(), text: text)
            itemIDsByText[text] = item.id
            let result = await stack.push(item)
            XCTAssertTrue(result.wasAccepted)
            let leaseCandidate = await stack.beginDeliveryLease(
                for: ClipboardRouteContext()
            )
            let lease = try XCTUnwrap(leaseCandidate)
            await stack.completeDelivery(leaseID: lease.leaseID)

            if text == "pinned oldest" {
                let pinResult = await stack.setItemsPinned(true, itemIDs: [item.id])
                XCTAssertTrue(pinResult.wasAccepted)
            }
        }

        let snapshot = await stack.clipboardSnapshot()
        let middleID = try XCTUnwrap(itemIDsByText["evictable middle"])

        XCTAssertEqual(snapshot.items.map(\.text), ["newest", "pinned oldest"])
        XCTAssertTrue(snapshot.items.last?.isPinned == true)
        XCTAssertFalse(snapshot.items.contains { $0.id == middleID })
    }

    func testBytePressureEvictsHistoryOnlyBeforeRejectingActiveContent() async throws {
        let probe = DeliveryStack(eventBus: EventBus())
        let sample = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroupID,
            contentKind: .image,
            text: "Copied image",
            imagePNGData: Data(repeating: 7, count: 32),
            sourceKind: .system,
            tags: ["image"]
        )
        let oneItemCost = try await probe.accountedEncodedItemByteCount(for: sample)
        var limits = ClipboardStorageLimits.productDefault
        limits.maximumEncodedItemByteCount = oneItemCost + 256
        limits.maximumTotalEncodedItemByteCount = oneItemCost + 256
        let stack = DeliveryStack(eventBus: EventBus(), storageLimits: limits)

        let firstCapture = await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(
                plainText: "",
                imagePNGData: Data(repeating: 1, count: 32),
                changeCount: 1
            ),
            context: ClipboardRouteContext(),
            disposition: .historyAndWorkflows
        )
        XCTAssertTrue(firstCapture.wasAccepted)
        let firstLeaseCandidate = await stack.beginDeliveryLease(for: ClipboardRouteContext())
        let firstLease = try XCTUnwrap(firstLeaseCandidate)
        let firstID = firstLease.item.id
        await stack.completeDelivery(leaseID: firstLease.leaseID)

        let admittedAfterEviction = await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(
                plainText: "",
                imagePNGData: Data(repeating: 2, count: 32),
                changeCount: 2
            ),
            context: ClipboardRouteContext(),
            disposition: .historyAndWorkflows
        )
        let snapshotAfterEviction = await stack.clipboardSnapshot()
        XCTAssertEqual(admittedAfterEviction, .accepted(evictedHistoryItemCount: 1))
        let evictedItem = await stack.item(id: firstID)
        XCTAssertNil(evictedItem)
        XCTAssertEqual(snapshotAfterEviction.items.count, 1)

        let rejectedActive = await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(
                plainText: "",
                imagePNGData: Data(repeating: 3, count: 32),
                changeCount: 3
            ),
            context: ClipboardRouteContext(),
            disposition: .historyAndWorkflows
        )
        XCTAssertEqual(rejectedActive, .rejected(.totalByteLimitReached))
        let snapshotAfterRejection = await stack.clipboardSnapshot()
        XCTAssertEqual(snapshotAfterRejection.items, snapshotAfterEviction.items)
    }

    func testRejectedOversizedTargetDoesNotCreateRecoveredGroupOrEvents() async {
        var limits = ClipboardStorageLimits.productDefault
        limits.maximumTextUTF8ByteCount = 4
        let eventBus = EventBus()
        let stack = DeliveryStack(eventBus: eventBus, storageLimits: limits)
        let targetGroupID = UUID()
        let item = DeliveryItem(
            workflowID: UUID(),
            text: "oversized",
            targetGroupID: targetGroupID
        )

        let result = await stack.push(item)
        let snapshot = await stack.clipboardSnapshot()

        XCTAssertEqual(result, .rejected(.itemTooLarge))
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertFalse(snapshot.groups.contains { $0.group.id == targetGroupID })
        let targetEntryIDs = await stack.groupEntryIDsForTesting(in: targetGroupID)
        XCTAssertTrue(targetEntryIDs.isEmpty)
    }

    func testRejectedReplacementPreservesExactItemVersionAndRoute() async throws {
        var limits = ClipboardStorageLimits.productDefault
        limits.maximumTextUTF8ByteCount = 8
        let stack = DeliveryStack(eventBus: EventBus(), storageLimits: limits)
        let original = DeliveryItem(workflowID: UUID(), text: "original")
        let originalResult = await stack.push(original)
        XCTAssertTrue(originalResult.wasAccepted)
        let subjectCandidate = await stack.clipboardItemDryRunSubject(itemID: original.id)
        let subject = try XCTUnwrap(subjectCandidate)
        let routeBefore = await stack.routeSnapshot(for: ClipboardRouteContext())

        let result = await stack.replace(
            DeliveryItem(workflowID: UUID(), text: "replacement is too large"),
            replacing: subject
        )
        let routeAfter = await stack.routeSnapshot(for: ClipboardRouteContext())
        let itemAfter = await stack.item(id: original.id)

        XCTAssertEqual(result, .storageRejected(.itemTooLarge))
        XCTAssertEqual(itemAfter?.version, subject.itemVersion)
        XCTAssertEqual(itemAfter?.text, "original")
        XCTAssertEqual(routeAfter, routeBefore)
    }

    func testCurrentSchemaOverActiveLimitFailsClosedWithoutOverwritingRawState() async throws {
        var limits = ClipboardStorageLimits.productDefault
        limits.maximumActiveItemCount = 1
        limits.maximumActiveItemCountPerGroup = 1
        let items = [
            ClipboardHistoryItem(
                groupID: ClipboardGroup.defaultGroupID,
                text: "older",
                sourceKind: .system
            ),
            ClipboardHistoryItem(
                groupID: ClipboardGroup.defaultGroupID,
                text: "newer",
                sourceKind: .system
            ),
        ]
        let state = LegacyPersistedClipboardState(
            schemaVersion: 7,
            items: items,
            groups: [],
            groupEntries: [],
            defaultGroupEntries: items.reversed().map(\.id),
            defaultGroupMode: .stack,
            appAssignments: []
        )
        let rawState = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        let settingsStore = RuntimeTestSettingsStore(
            storage: [.clipboardPersistedState: rawState]
        )
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore,
            storageLimits: limits
        )

        let snapshot = await stack.clipboardSnapshot()
        let storedRawState = try await settingsStore.string(forKey: .clipboardPersistedState)
        let writeCount = await settingsStore.writeCount(forKey: .clipboardPersistedState)

        XCTAssertEqual(snapshot.persistenceAvailability, .loadUnavailable)
        XCTAssertEqual(snapshot.lastStorageRejection, .activeItemLimitReached)
        XCTAssertEqual(snapshot.storagePressureContext, .persistedStateRejected)
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertEqual(storedRawState, rawState)
        XCTAssertEqual(writeCount, 0)
    }

    func testCurrentSchemaOverMetadataLimitFailsClosedWithoutOverwritingRawState() async throws {
        var limits = ClipboardStorageLimits.productDefault
        limits.maximumGroupNameUTF8ByteCount = 4
        let oversizedGroup = ClipboardGroup(name: "12345")
        let state = LegacyPersistedClipboardState(
            schemaVersion: 7,
            items: [],
            groups: [oversizedGroup],
            groupEntries: [
                .init(groupID: oversizedGroup.id, itemIDs: [])
            ],
            defaultGroupEntries: [],
            defaultGroupMode: .stack,
            appAssignments: []
        )
        let rawState = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        let settingsStore = RuntimeTestSettingsStore(
            storage: [.clipboardPersistedState: rawState]
        )
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore,
            storageLimits: limits
        )

        let snapshot = await stack.clipboardSnapshot()
        let storedRawState = try await settingsStore.string(forKey: .clipboardPersistedState)
        let writeCount = await settingsStore.writeCount(forKey: .clipboardPersistedState)

        XCTAssertEqual(snapshot.persistenceAvailability, .loadUnavailable)
        XCTAssertEqual(snapshot.lastStorageRejection, .metadataLimitReached)
        XCTAssertEqual(snapshot.storagePressureContext, .persistedStateRejected)
        XCTAssertTrue(snapshot.groups.allSatisfy { $0.group.id != oversizedGroup.id })
        XCTAssertEqual(storedRawState, rawState)
        XCTAssertEqual(writeCount, 0)
    }

    func testLegacyOverCapacityLoadsWithoutLossAndConvergesAfterShrinking() async throws {
        var limits = ClipboardStorageLimits.productDefault
        limits.maximumActiveItemCount = 1
        limits.maximumActiveItemCountPerGroup = 1
        let older = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroupID,
            text: "older",
            sourceKind: .system
        )
        let newer = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroupID,
            text: "newer",
            sourceKind: .system
        )
        let state = LegacyPersistedClipboardState(
            schemaVersion: 6,
            items: [newer, older],
            groups: [],
            groupEntries: [],
            defaultGroupEntries: [newer.id, older.id],
            defaultGroupMode: .stack,
            appAssignments: []
        )
        let rawState = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        let settingsStore = RuntimeTestSettingsStore(
            storage: [.clipboardPersistedState: rawState]
        )
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore,
            storageLimits: limits
        )

        var snapshot = await stack.clipboardSnapshot()
        XCTAssertEqual(snapshot.items.map(\.id), [newer.id, older.id])
        XCTAssertEqual(snapshot.lastStorageRejection, .activeItemLimitReached)
        XCTAssertEqual(snapshot.storagePressureContext, .legacyOverCapacity)
        let rejected = await stack.push(DeliveryItem(workflowID: UUID(), text: "blocked growth"))
        XCTAssertEqual(rejected, .rejected(.activeItemLimitReached))

        await stack.deleteItem(id: older.id)
        snapshot = await stack.clipboardSnapshot()
        XCTAssertEqual(snapshot.items.map(\.id), [newer.id])
        XCTAssertNil(snapshot.lastStorageRejection)
        XCTAssertNil(snapshot.storagePressureContext)
        let upgradedRawState = try await Self.waitForPersistedState(in: settingsStore) {
            $0.contains("\"schemaVersion\":8")
        }
        XCTAssertTrue(upgradedRawState.contains("\"schemaVersion\":8"))

        let leaseCandidate = await stack.beginDeliveryLease(for: ClipboardRouteContext())
        let lease = try XCTUnwrap(leaseCandidate)
        await stack.completeDelivery(leaseID: lease.leaseID)
        let accepted = await stack.push(DeliveryItem(workflowID: UUID(), text: "after shrink"))
        XCTAssertTrue(accepted.wasAccepted)
    }

    func testLegacyRawOversizedItemsNeverReencodeUntilEveryUnknownSizeIsRemoved() async throws {
        var limits = ClipboardStorageLimits.productDefault
        limits.maximumTextUTF8ByteCount = 4
        let older = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroupID,
            text: "older oversized",
            sourceKind: .system
        )
        let newer = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroupID,
            text: "newer oversized",
            sourceKind: .system
        )
        let state = LegacyPersistedClipboardState(
            schemaVersion: 6,
            items: [newer, older],
            groups: [],
            groupEntries: [],
            defaultGroupEntries: [newer.id, older.id],
            defaultGroupMode: .stack,
            appAssignments: []
        )
        let rawState = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        let settingsStore = RuntimeTestSettingsStore(
            storage: [.clipboardPersistedState: rawState]
        )
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore,
            storageLimits: limits
        )

        var snapshot = await stack.clipboardSnapshot()
        XCTAssertEqual(snapshot.items.map(\.id), [newer.id, older.id])
        XCTAssertEqual(snapshot.storagePressureContext, .legacyOverCapacity)
        var writeCount = await settingsStore.writeCount(forKey: .clipboardPersistedState)
        XCTAssertEqual(writeCount, 0)
        var flushResult = await stack.flushPendingPersistenceWrites()
        XCTAssertEqual(flushResult, .persisted)
        writeCount = await settingsStore.writeCount(forKey: .clipboardPersistedState)
        XCTAssertEqual(writeCount, 0)

        let leaseCandidate = await stack.beginDeliveryLease(for: ClipboardRouteContext())
        let lease = try XCTUnwrap(leaseCandidate)
        XCTAssertEqual(lease.item.id, newer.id)
        await stack.completeDelivery(leaseID: lease.leaseID)
        snapshot = await stack.clipboardSnapshot()
        XCTAssertEqual(snapshot.items.map(\.id), [older.id])
        XCTAssertEqual(snapshot.storagePressureContext, .legacyOverCapacity)
        flushResult = await stack.flushPendingPersistenceWrites()
        XCTAssertEqual(flushResult, .saveFailed)
        let preservedRawState = try await settingsStore.string(
            forKey: .clipboardPersistedState
        )
        XCTAssertEqual(preservedRawState, rawState)

        await stack.deleteItem(id: older.id)
        let upgradedRawState = try await Self.waitForPersistedState(in: settingsStore) {
            $0.contains("\"schemaVersion\":8")
        }
        XCTAssertFalse(upgradedRawState.contains("oversized"))
        flushResult = await stack.flushPendingPersistenceWrites()
        XCTAssertEqual(flushResult, .persisted)
    }

    func testOversizedRawStateFailsClosedWithoutDecodeOrWrite() async throws {
        var limits = ClipboardStorageLimits.productDefault
        limits.maximumPersistedStateUTF8ByteCount = 16
        let rawState = String(repeating: "x", count: 17)
        let settingsStore = RuntimeTestSettingsStore(
            storage: [.clipboardPersistedState: rawState]
        )
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: settingsStore,
            storageLimits: limits
        )

        let snapshot = await stack.clipboardSnapshot()
        let storedRawState = try await settingsStore.string(forKey: .clipboardPersistedState)
        let writeCount = await settingsStore.writeCount(forKey: .clipboardPersistedState)
        XCTAssertEqual(snapshot.persistenceAvailability, .loadUnavailable)
        XCTAssertEqual(snapshot.lastStorageRejection, .totalByteLimitReached)
        XCTAssertEqual(snapshot.storagePressureContext, .persistedStateRejected)
        XCTAssertEqual(storedRawState, rawState)
        XCTAssertEqual(writeCount, 0)
    }
}
