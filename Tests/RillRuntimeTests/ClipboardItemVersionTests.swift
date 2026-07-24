import XCTest
@testable import RillCore
@testable import RillRuntime

final class ClipboardItemVersionTests: XCTestCase {
    func testExactSubjectChangesOnlyWhenItsItemChanges() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "first", changeCount: 1),
            context: ClipboardRouteContext(),
            disposition: .historyOnly
        )
        let initialSnapshot = await stack.clipboardSnapshot()
        let first = try XCTUnwrap(initialSnapshot.items.first)
        let resolvedFirstSubject = await stack.clipboardItemDryRunSubject(itemID: first.id)
        let firstSubject = try XCTUnwrap(resolvedFirstSubject)

        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "second", changeCount: 2),
            context: ClipboardRouteContext(),
            disposition: .historyOnly
        )
        let snapshot = await stack.clipboardSnapshot()
        let second = try XCTUnwrap(snapshot.items.first(where: { $0.id != first.id }))
        await stack.updateItemText(
            second.id,
            text: "second changed",
            captureTags: second.captureTags
        )

        let subjectAfterUnrelatedMutation = await stack.clipboardItemDryRunSubject(itemID: first.id)
        XCTAssertEqual(subjectAfterUnrelatedMutation, firstSubject)

        await stack.updateItemText(
            first.id,
            text: "first changed",
            captureTags: first.captureTags
        )
        let resolvedChangedSubject = await stack.clipboardItemDryRunSubject(itemID: first.id)
        let changedSubject = try XCTUnwrap(resolvedChangedSubject)

        XCTAssertEqual(changedSubject.itemVersion.generationID, firstSubject.itemVersion.generationID)
        XCTAssertEqual(changedSubject.itemVersion.revision, firstSubject.itemVersion.revision + 1)
        XCTAssertNotEqual(changedSubject, firstSubject)
        let staleItem = await stack.item(matching: firstSubject)
        let currentItem = await stack.item(matching: changedSubject)
        XCTAssertNil(staleItem)
        XCTAssertNotNil(currentItem)
    }

    func testDeleteAndRecreateSameIDUsesNewGeneration() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let itemID = UUID()
        await stack.push(
            DeliveryItem(
                id: itemID,
                workflowID: UUID(),
                text: "original"
            )
        )
        let resolvedOriginal = await stack.clipboardItemDryRunSubject(itemID: itemID)
        let original = try XCTUnwrap(resolvedOriginal)

        await stack.deleteItem(id: itemID)
        await stack.push(
            DeliveryItem(
                id: itemID,
                workflowID: UUID(),
                text: "replacement"
            )
        )
        let resolvedReplacement = await stack.clipboardItemDryRunSubject(itemID: itemID)
        let replacement = try XCTUnwrap(resolvedReplacement)

        XCTAssertEqual(replacement.itemID, original.itemID)
        XCTAssertNotEqual(replacement.itemVersion.generationID, original.itemVersion.generationID)
        let staleItem = await stack.item(matching: original)
        let currentItem = await stack.item(matching: replacement)
        XCTAssertNil(staleItem)
        XCTAssertNotNil(currentItem)
    }

    func testExactReplacementCASNeverOverwritesOrRecreatesAStaleSource() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let itemID = UUID()
        let workflowID = UUID()
        await stack.push(
            DeliveryItem(
                id: itemID,
                workflowID: workflowID,
                text: "original"
            )
        )
        let resolvedOriginalSubject = await stack.clipboardItemDryRunSubject(itemID: itemID)
        let originalSubject = try XCTUnwrap(resolvedOriginalSubject)

        await stack.updateItemText(
            itemID,
            text: "edited concurrently",
            captureTags: []
        )
        let changedResult = await stack.replace(
            DeliveryItem(
                workflowID: workflowID,
                text: "stale replacement"
            ),
            replacing: originalSubject
        )
        XCTAssertEqual(changedResult, .sourceChanged)
        let changedItem = await stack.item(id: itemID)
        XCTAssertEqual(changedItem?.text, "edited concurrently")

        await stack.deleteItem(id: itemID)
        let deletedResult = await stack.replace(
            DeliveryItem(
                workflowID: workflowID,
                text: "must not revive"
            ),
            replacing: originalSubject
        )
        XCTAssertEqual(deletedResult, .sourceUnavailable)
        let deletedItem = await stack.item(id: itemID)
        XCTAssertNil(deletedItem)

        await stack.push(
            DeliveryItem(
                id: itemID,
                workflowID: workflowID,
                text: "new incarnation"
            )
        )
        let recreatedResult = await stack.replace(
            DeliveryItem(
                workflowID: workflowID,
                text: "must not overwrite ABA"
            ),
            replacing: originalSubject
        )
        XCTAssertEqual(recreatedResult, .sourceChanged)
        let recreatedItem = await stack.item(id: itemID)
        XCTAssertEqual(recreatedItem?.text, "new incarnation")
    }

    func testExactUseLeaseHasOneOwnerAndConsumesTheSelectedVersion() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let itemID = UUID()
        await stack.push(
            DeliveryItem(
                id: itemID,
                workflowID: UUID(),
                text: "claim once"
            )
        )
        let resolvedSubject = await stack.clipboardItemDryRunSubject(itemID: itemID)
        let subject = try XCTUnwrap(resolvedSubject)

        let lease = try await stack.beginClipboardItemUseLease(matching: subject)
        XCTAssertEqual(lease.item.text, "claim once")
        do {
            _ = try await stack.beginClipboardItemUseLease(matching: subject)
            XCTFail("A second claimant must not share the same item lease.")
        } catch let error as ClipboardItemUseLeaseError {
            XCTAssertEqual(error, .alreadyInUse)
        }

        await stack.completeDelivery(leaseID: lease.leaseID)
        let completedItem = await stack.item(id: itemID)
        XCTAssertEqual(completedItem?.useCount, 1)
        XCTAssertEqual(completedItem?.lastUsedAt == nil, false)

        do {
            _ = try await stack.beginClipboardItemUseLease(matching: subject)
            XCTFail("Completion must invalidate the previously selected version.")
        } catch let error as ClipboardItemUseLeaseError {
            XCTAssertEqual(error, .sourceChanged)
        }
    }

    func testEveryExistingItemMutationAdvancesExactVersionOnce() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        let itemID = UUID()
        let workflowID = UUID()
        let bundleIdentifier = "com.example.VersionedItem"
        let context = ClipboardRouteContext(
            applicationName: "Versioned Item",
            bundleIdentifier: bundleIdentifier
        )
        await stack.push(
            DeliveryItem(
                id: itemID,
                workflowID: workflowID,
                text: "initial",
                sourceApplicationName: context.applicationName,
                sourceBundleIdentifier: bundleIdentifier
            )
        )
        await stack.setMode(.list, forGroup: ClipboardGroup.defaultGroupID)

        try await assertSingleAdvance(stack: stack, itemID: itemID) {
            await stack.markUsed(itemID: itemID)
        }
        try await assertSingleAdvance(stack: stack, itemID: itemID) {
            await stack.updateItemText(
                itemID,
                text: "edited",
                captureTags: [.polishGenerated]
            )
        }
        try await assertSingleAdvance(stack: stack, itemID: itemID) {
            await stack.updateItemTags(itemID, tags: ["reviewed"])
        }

        let targetGroup = (await stack.createGroup(named: "Versioned")).group!
        try await assertSingleAdvance(stack: stack, itemID: itemID) {
            await stack.assignApplication(
                bundleIdentifier: bundleIdentifier,
                applicationName: "Versioned Item",
                toGroup: targetGroup.id
            )
        }
        await stack.setMode(.list, forGroup: targetGroup.id)

        try await assertSingleAdvance(stack: stack, itemID: itemID) {
            await stack.push(
                DeliveryItem(
                    id: itemID,
                    workflowID: workflowID,
                    text: "same-ID upsert",
                    sourceApplicationName: context.applicationName,
                    sourceBundleIdentifier: bundleIdentifier,
                    targetGroupID: targetGroup.id
                )
            )
        }
        try await assertSingleAdvance(stack: stack, itemID: itemID) {
            await stack.replace(
                DeliveryItem(
                    id: itemID,
                    workflowID: workflowID,
                    text: "workflow replacement",
                    sourceApplicationName: context.applicationName,
                    sourceBundleIdentifier: bundleIdentifier,
                    targetGroupID: targetGroup.id
                ),
                replacing: itemID
            )
        }

        let completionCandidate = await stack.beginDeliveryLease(for: context)
        let completionLease = try XCTUnwrap(completionCandidate)
        try await assertSingleAdvance(stack: stack, itemID: itemID) {
            await stack.completeDelivery(leaseID: completionLease.leaseID)
        }

        let failureCandidate = await stack.beginDeliveryLease(for: context)
        let failureLease = try XCTUnwrap(failureCandidate)
        try await assertSingleAdvance(stack: stack, itemID: itemID) {
            await stack.failDelivery(
                leaseID: failureLease.leaseID,
                error: "fixed-error-code"
            )
        }
    }

    private func assertSingleAdvance(
        stack: DeliveryStack,
        itemID: UUID,
        operation: () async -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let beforeCandidate = await stack.clipboardItemDryRunSubject(itemID: itemID)
        let before = try XCTUnwrap(
            beforeCandidate,
            file: file,
            line: line
        )
        await operation()
        let afterCandidate = await stack.clipboardItemDryRunSubject(itemID: itemID)
        let after = try XCTUnwrap(
            afterCandidate,
            file: file,
            line: line
        )

        XCTAssertEqual(
            after.itemVersion.generationID,
            before.itemVersion.generationID,
            file: file,
            line: line
        )
        XCTAssertEqual(
            after.itemVersion.revision,
            before.itemVersion.revision + 1,
            file: file,
            line: line
        )
    }
}
