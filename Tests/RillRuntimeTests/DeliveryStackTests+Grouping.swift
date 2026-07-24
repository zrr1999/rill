import XCTest
@testable import RillCore
@testable import RillRuntime

extension DeliveryStackTests {
    func testListModeDoesNotConsumeItems() async {
        let stack = DeliveryStack(eventBus: EventBus())
        let context = ClipboardRouteContext(
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes"
        )
        let group = (await stack.createGroup(named: "List")).group!
        await stack.assignApplication(
            bundleIdentifier: "com.apple.Notes",
            applicationName: "Notes",
            toGroup: group.id
        )
        await stack.setMode(.list, forGroup: group.id)

        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "persistent", changeCount: 1),
            context: context
        )

        let listSnapshot = await stack.clipboardSnapshot()
        let listSummary = listSnapshot.groups.first(where: { $0.group.id == group.id })
        XCTAssertEqual(previewTexts(in: listSummary, from: listSnapshot), ["persistent"])

        let firstLease = await stack.beginDeliveryLease(for: context)
        XCTAssertEqual(firstLease?.item.text, "persistent")
        if let firstLease {
            await stack.completeDelivery(leaseID: firstLease.leaseID)
        }

        let secondLease = await stack.beginDeliveryLease(for: context)
        XCTAssertEqual(secondLease?.item.text, "persistent")
        let refreshedRoute = await stack.routeSnapshot(for: context)
        XCTAssertEqual(refreshedRoute.count, 1)
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

        let workGroup = (await stack.createGroup(named: "Work")).group!
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
        XCTAssertNil(snapshot.groups.first(where: { $0.group.id == ClipboardGroup.defaultGroup.id }))
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
        let customGroup = (await stack.createGroup(named: "Browser")).group!
        await stack.assignApplication(
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            toGroup: customGroup.id
        )

        let snapshot = await stack.clipboardSnapshot()
        XCTAssertEqual(snapshot.items.first?.groupID, customGroup.id)
        XCTAssertNil(snapshot.groups.first(where: { $0.group.id == ClipboardGroup.defaultGroup.id }))
        XCTAssertEqual(
            snapshot.groups.first(where: { $0.group.id == customGroup.id })?.count,
            1
        )
        XCTAssertEqual(snapshot.appAssignments.first?.groupID, customGroup.id)
    }

    func testAssignApplicationPreservesNewestFirstStorageAndStackCandidate() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let safariContext = ClipboardRouteContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )

        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "oldest", changeCount: 1),
            context: safariContext
        )
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "middle", changeCount: 2),
            context: safariContext
        )
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "newest", changeCount: 3),
            context: safariContext
        )

        let group = (await stack.createGroup(named: "Browser Stack")).group!
        await stack.assignApplication(
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            toGroup: group.id
        )

        let snapshot = await stack.clipboardSnapshot()
        let expectedNewestFirstIDs = snapshot.items.map(\.id)
        let storedIDs = await stack.groupEntryIDsForTesting(in: group.id)
        let summary = snapshot.groups.first(where: { $0.group.id == group.id })
        let route = await stack.routeSnapshot(for: safariContext)

        XCTAssertEqual(storedIDs, expectedNewestFirstIDs)
        XCTAssertEqual(previewTexts(in: summary, from: snapshot), ["newest", "middle", "oldest"])
        XCTAssertEqual(route.previewText, "newest")

        let leaseCandidate = await stack.beginDeliveryLease(for: safariContext)
        let lease = try XCTUnwrap(leaseCandidate)
        XCTAssertEqual(lease.item.id, expectedNewestFirstIDs.first)
        XCTAssertEqual(lease.item.text, "newest")
    }

    func testReassignApplicationPreservesNewestFirstStorageAndQueueCandidate() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let safariContext = ClipboardRouteContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )

        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "oldest", changeCount: 1),
            context: safariContext
        )
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "middle", changeCount: 2),
            context: safariContext
        )
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "newest", changeCount: 3),
            context: safariContext
        )

        let originalGroup = (await stack.createGroup(named: "Original")).group!
        await stack.assignApplication(
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            toGroup: originalGroup.id
        )
        let queueGroup = (await stack.createGroup(named: "Browser Queue")).group!
        await stack.setMode(.queue, forGroup: queueGroup.id)
        await stack.assignApplication(
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            toGroup: queueGroup.id
        )

        let snapshot = await stack.clipboardSnapshot()
        let expectedNewestFirstIDs = snapshot.items.map(\.id)
        let originalStoredIDs = await stack.groupEntryIDsForTesting(in: originalGroup.id)
        let reassignedStoredIDs = await stack.groupEntryIDsForTesting(in: queueGroup.id)
        let summary = snapshot.groups.first(where: { $0.group.id == queueGroup.id })
        let route = await stack.routeSnapshot(for: safariContext)

        XCTAssertTrue(originalStoredIDs.isEmpty)
        XCTAssertEqual(reassignedStoredIDs, expectedNewestFirstIDs)
        XCTAssertEqual(previewTexts(in: summary, from: snapshot), ["oldest", "middle", "newest"])
        XCTAssertEqual(route.previewText, "oldest")

        let leaseCandidate = await stack.beginDeliveryLease(for: safariContext)
        let lease = try XCTUnwrap(leaseCandidate)
        XCTAssertEqual(lease.item.id, expectedNewestFirstIDs.last)
        XCTAssertEqual(lease.item.text, "oldest")
    }

    func testCreateGroupCanImmediatelyAssignTriggeringApplication() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let safariContext = ClipboardRouteContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )

        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "https://example.com", changeCount: 1),
            context: safariContext
        )

        let creationResult = await stack.createGroup(
            named: "Safari Workspace",
            assigning: ClipboardAppAssignment(
                bundleIdentifier: "com.apple.Safari",
                applicationName: "Safari",
                groupID: nil
            )
        )
        let createdGroup = try XCTUnwrap(creationResult.group)

        let snapshot = await stack.clipboardSnapshot()

        XCTAssertEqual(snapshot.items.first?.groupID, createdGroup.id)
        XCTAssertEqual(
            snapshot.appAssignments.first(where: { $0.bundleIdentifier == "com.apple.Safari" })?.groupID,
            createdGroup.id
        )
        XCTAssertEqual(
            snapshot.groups.first(where: { $0.group.id == createdGroup.id })?.count,
            1
        )
    }

    func testAssignApplicationRejectsAtomicallyWhenTargetGroupWouldExceedCapacity() async {
        var limits = ClipboardStorageLimits.productDefault
        limits.maximumActiveItemCountPerGroup = 2
        let stack = DeliveryStack(eventBus: EventBus(), storageLimits: limits)
        let safariContext = ClipboardRouteContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        let notesContext = ClipboardRouteContext(
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes"
        )
        let targetGroup = (await stack.createGroup(named: "Target")).group!
        let notesAssignment = await stack.assignApplication(
            bundleIdentifier: "com.apple.Notes",
            applicationName: "Notes",
            toGroup: targetGroup.id
        )
        XCTAssertTrue(notesAssignment.wasAccepted)
        let notesCapture = await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "notes", changeCount: 1),
            context: notesContext,
            disposition: .historyAndWorkflows
        )
        XCTAssertTrue(notesCapture.wasAccepted)
        for (index, text) in ["safari older", "safari newer"].enumerated() {
            let capture = await stack.captureSystemClipboard(
                snapshot: ClipboardSnapshot(plainText: text, changeCount: index + 2),
                context: safariContext,
                disposition: .historyAndWorkflows
            )
            XCTAssertTrue(capture.wasAccepted)
        }
        let before = await stack.clipboardSnapshot()

        let result = await stack.assignApplication(
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            toGroup: targetGroup.id
        )
        let after = await stack.clipboardSnapshot()

        XCTAssertEqual(result, .rejected(.activeItemLimitReached))
        XCTAssertEqual(after.items.map(\.id), before.items.map(\.id))
        XCTAssertEqual(
            after.items.filter { $0.sourceBundleIdentifier == "com.apple.Safari" }.map(\.groupID),
            [ClipboardGroup.defaultGroupID, ClipboardGroup.defaultGroupID]
        )
        XCTAssertNil(
            after.appAssignments.first { $0.bundleIdentifier == "com.apple.Safari" }?.groupID
        )
        XCTAssertEqual(
            after.groups.first { $0.group.id == targetGroup.id }?.count,
            1
        )
        XCTAssertEqual(after.lastStorageRejection, .activeItemLimitReached)
        XCTAssertEqual(after.storagePressureContext, .mutationRejected)
    }

    func testAssignApplicationRejectsWhileAffectedItemLeaseIsInFlight() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let safariContext = ClipboardRouteContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        let capture = await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "leased", changeCount: 1),
            context: safariContext,
            disposition: .historyAndWorkflows
        )
        XCTAssertTrue(capture.wasAccepted)
        let targetGroup = (await stack.createGroup(named: "Target")).group!
        let pendingLease = await stack.beginDeliveryLease(for: safariContext)
        let lease = try XCTUnwrap(pendingLease)

        let result = await stack.assignApplication(
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            toGroup: targetGroup.id
        )
        let duringLease = await stack.clipboardSnapshot()

        XCTAssertEqual(result, .rejected(.activeItemInUse))
        XCTAssertEqual(duringLease.items.first?.groupID, ClipboardGroup.defaultGroupID)
        XCTAssertNil(
            duringLease.appAssignments.first { $0.bundleIdentifier == "com.apple.Safari" }?.groupID
        )
        XCTAssertEqual(
            duringLease.groups.first { $0.group.id == targetGroup.id }?.count,
            0
        )

        await stack.completeDelivery(leaseID: lease.leaseID)
        let nextLease = await stack.beginDeliveryLease(for: safariContext)
        let targetEntryIDs = await stack.groupEntryIDsForTesting(in: targetGroup.id)
        XCTAssertNil(nextLease)
        XCTAssertTrue(targetEntryIDs.isEmpty)
    }

    func testAssignApplicationMovesHistoryMetadataWithoutReactivatingConsumedItem() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let safariContext = ClipboardRouteContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        let capture = await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "consumed", changeCount: 1),
            context: safariContext,
            disposition: .historyAndWorkflows
        )
        XCTAssertTrue(capture.wasAccepted)
        let pendingLease = await stack.beginDeliveryLease(for: safariContext)
        let lease = try XCTUnwrap(pendingLease)
        await stack.completeDelivery(leaseID: lease.leaseID)
        let targetGroup = (await stack.createGroup(named: "Archive Route")).group!

        let assignment = await stack.assignApplication(
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            toGroup: targetGroup.id
        )
        let snapshot = await stack.clipboardSnapshot()
        let targetEntryIDs = await stack.groupEntryIDsForTesting(in: targetGroup.id)
        let nextLease = await stack.beginDeliveryLease(for: safariContext)

        XCTAssertTrue(assignment.wasAccepted)
        XCTAssertEqual(snapshot.items.first?.groupID, targetGroup.id)
        XCTAssertTrue(targetEntryIDs.isEmpty)
        XCTAssertNil(nextLease)
    }

    func testCreateAssignedGroupRejectsWithoutCreatingGhostGroup() async {
        var limits = ClipboardStorageLimits.productDefault
        limits.maximumActiveItemCountPerGroup = 1
        let stack = DeliveryStack(eventBus: EventBus(), storageLimits: limits)
        let firstSourceGroup = (await stack.createGroup(named: "First Source")).group!
        let secondSourceGroup = (await stack.createGroup(named: "Second Source")).group!
        for (text, groupID) in [
            ("older", firstSourceGroup.id),
            ("newer", secondSourceGroup.id),
        ] {
            let push = await stack.push(
                DeliveryItem(
                    workflowID: UUID(),
                    text: text,
                    sourceApplicationName: "Safari",
                    sourceBundleIdentifier: "com.apple.Safari",
                    targetGroupID: groupID
                )
            )
            XCTAssertTrue(push.wasAccepted)
        }

        let result = await stack.createGroup(
            named: "Must Not Exist",
            assigning: ClipboardAppAssignment(
                bundleIdentifier: "com.apple.Safari",
                applicationName: "Safari",
                groupID: nil
            )
        )
        let snapshot = await stack.clipboardSnapshot()

        XCTAssertEqual(result, .rejected(.activeItemLimitReached))
        XCTAssertFalse(snapshot.groups.contains { $0.group.name == "Must Not Exist" })
        XCTAssertNil(
            snapshot.appAssignments.first { $0.bundleIdentifier == "com.apple.Safari" }?.groupID
        )
        XCTAssertEqual(
            Set(snapshot.items.map(\.groupID)),
            Set([firstSourceGroup.id, secondSourceGroup.id])
        )
    }

    func testCrossGroupFallbackUsesEligibleGroupWhenAssignedGroupIsEmpty() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let safariContext = ClipboardRouteContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        let notesContext = ClipboardRouteContext(
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes"
        )

        let browserGroup = (await stack.createGroup(named: "Browser")).group!
        let sharedGroup = (await stack.createGroup(named: "Shared")).group!
        await stack.assignApplication(
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            toGroup: browserGroup.id
        )
        await stack.assignApplication(
            bundleIdentifier: "com.apple.Notes",
            applicationName: "Notes",
            toGroup: sharedGroup.id
        )
        await stack.setAllowsCrossGroupPaste(true, forGroup: sharedGroup.id)

        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "shared item", changeCount: 1),
            context: notesContext
        )

        let routeSnapshot = await stack.routeSnapshot(for: safariContext)
        let leaseCandidate = await stack.beginDeliveryLease(for: safariContext)
        let lease = try XCTUnwrap(leaseCandidate)

        XCTAssertEqual(routeSnapshot.activeGroup.group.id, sharedGroup.id)
        XCTAssertEqual(routeSnapshot.previewText, "shared item")
        XCTAssertEqual(lease.item.groupID, sharedGroup.id)
        XCTAssertEqual(lease.item.text, "shared item")
    }

    func testAssignedGroupKeepsPriorityOverCrossGroupFallback() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let safariContext = ClipboardRouteContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        let notesContext = ClipboardRouteContext(
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes"
        )

        let browserGroup = (await stack.createGroup(named: "Browser")).group!
        let sharedGroup = (await stack.createGroup(named: "Shared")).group!
        await stack.assignApplication(
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            toGroup: browserGroup.id
        )
        await stack.assignApplication(
            bundleIdentifier: "com.apple.Notes",
            applicationName: "Notes",
            toGroup: sharedGroup.id
        )
        await stack.setAllowsCrossGroupPaste(true, forGroup: sharedGroup.id)

        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "shared item", changeCount: 1),
            context: notesContext
        )
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "browser item", changeCount: 2),
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

    func testCrossGroupFallbackPriorityDominatesCandidateRecency() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let xcodeContext = ClipboardRouteContext(
            applicationName: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode"
        )

        let queueGroup = (await stack.createGroup(named: "Queue Group")).group!
        let stackGroup = (await stack.createGroup(named: "Stack Group")).group!
        await stack.setMode(.queue, forGroup: queueGroup.id)
        await stack.setAllowsCrossGroupPaste(true, forGroup: queueGroup.id)
        await stack.setAllowsCrossGroupPaste(true, forGroup: stackGroup.id)

        await stack.push(
            DeliveryItem(
                workflowID: UUID(),
                text: "queue oldest",
                createdAt: Date(timeIntervalSince1970: 10),
                targetGroupID: queueGroup.id
            )
        )
        await stack.push(
            DeliveryItem(
                workflowID: UUID(),
                text: "queue newest but not next",
                createdAt: Date(timeIntervalSince1970: 30),
                targetGroupID: queueGroup.id
            )
        )
        await stack.push(
            DeliveryItem(
                workflowID: UUID(),
                text: "stack newest candidate",
                createdAt: Date(timeIntervalSince1970: 20),
                targetGroupID: stackGroup.id
            )
        )

        let routeSnapshot = await stack.routeSnapshot(for: xcodeContext)
        let leaseCandidate = await stack.beginDeliveryLease(for: xcodeContext)
        let lease = try XCTUnwrap(leaseCandidate)

        XCTAssertEqual(routeSnapshot.activeGroup.group.id, queueGroup.id)
        XCTAssertEqual(routeSnapshot.previewText, "queue oldest")
        XCTAssertEqual(lease.item.groupID, queueGroup.id)
        XCTAssertEqual(lease.item.text, "queue oldest")
    }

    func testExplicitFallbackPriorityPrecedesLegacyUnprioritizedGroup() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let explicitGroup = (await stack.createGroup(named: "Explicit priority")).group!
        await stack.setAllowsCrossGroupPaste(true, forGroup: explicitGroup.id)
        await stack.push(
            DeliveryItem(
                workflowID: UUID(),
                text: "older explicit-priority item",
                createdAt: Date(timeIntervalSince1970: 10),
                targetGroupID: explicitGroup.id
            )
        )
        await stack.push(
            DeliveryItem(
                workflowID: UUID(),
                text: "newer legacy voice item",
                createdAt: Date(timeIntervalSince1970: 20),
                targetGroupID: ClipboardGroup.voiceGroupID
            )
        )

        let routeSnapshot = await stack.routeSnapshot(for: ClipboardRouteContext())
        let leaseCandidate = await stack.beginDeliveryLease(for: ClipboardRouteContext())
        let lease = try XCTUnwrap(leaseCandidate)

        XCTAssertEqual(routeSnapshot.activeGroup.group.id, explicitGroup.id)
        XCTAssertEqual(routeSnapshot.previewText, "older explicit-priority item")
        XCTAssertEqual(lease.item.groupID, explicitGroup.id)
    }

    func testFallbackPriorityMustRemainUniqueAcrossGroups() async {
        let stack = DeliveryStack(eventBus: EventBus())
        let firstGroup = (await stack.createGroup(named: "First")).group!
        let secondGroup = (await stack.createGroup(named: "Second")).group!

        await stack.setAllowsCrossGroupPaste(true, forGroup: firstGroup.id)
        await stack.setAllowsCrossGroupPaste(true, forGroup: secondGroup.id)

        let didSetDuplicatePriority = await stack.setFallbackPriority(1, forGroup: secondGroup.id)
        let snapshot = await stack.clipboardSnapshot()
        let firstSummary = snapshot.groups.first(where: { $0.group.id == firstGroup.id })
        let secondSummary = snapshot.groups.first(where: { $0.group.id == secondGroup.id })

        XCTAssertFalse(didSetDuplicatePriority)
        XCTAssertEqual(firstSummary?.group.fallbackPriority, 1)
        XCTAssertEqual(secondSummary?.group.fallbackPriority, 2)
    }

    func testFallbackPriorityMustBePositive() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let group = (await stack.createGroup(named: "Invalid priority")).group!

        let didSetZero = await stack.setFallbackPriority(0, forGroup: group.id)
        let didSetNegative = await stack.setFallbackPriority(-1, forGroup: group.id)
        let snapshot = await stack.clipboardSnapshot()
        let summary = snapshot.groups.first(where: { $0.group.id == group.id })

        XCTAssertFalse(didSetZero)
        XCTAssertFalse(didSetNegative)
        XCTAssertFalse(try XCTUnwrap(summary).group.allowsCrossGroupPaste)
        XCTAssertNil(summary?.group.fallbackPriority)
    }

}
