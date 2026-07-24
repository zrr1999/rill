import XCTest
@testable import RillCore
@testable import RillRuntime

extension DeliveryStackTests {
    func testWorkflowExcludedItemsStayInHistoryWithoutAnyGroupEvents() async throws {
        let eventBus = EventBus()
        let stack = DeliveryStack(eventBus: eventBus)
        let stream = await eventBus.stream()
        let eventTask = Task { () -> [ClipboardGroupEventDescriptor] in
            var groupEvents: [ClipboardGroupEventDescriptor] = []
            for await event in stream {
                if case .diagnostic(let diagnostic) = event,
                   diagnostic.event == "diagnostic.boundary" {
                    return groupEvents
                }
                if case .clipboardGroupEvent(let groupEvent) = event {
                    groupEvents.append(groupEvent)
                }
            }
            return groupEvents
        }
        let excludedTags: [ClipboardCaptureTag] = [.excludeFromWorkflowCapture]

        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(
                plainText: "system protected",
                changeCount: 1,
                captureTags: excludedTags
            ),
            context: ClipboardRouteContext()
        )
        var snapshot = await stack.clipboardSnapshot()
        let systemItemID = try XCTUnwrap(snapshot.items.first?.id)
        await stack.updateItemText(systemItemID, text: "system edited", captureTags: excludedTags)
        await stack.deleteItem(id: systemItemID)

        let pushedItemID = UUID()
        await stack.push(
            DeliveryItem(
                id: pushedItemID,
                workflowID: UUID(),
                text: "workflow protected",
                captureTags: excludedTags
            )
        )
        await stack.replace(
            DeliveryItem(
                id: pushedItemID,
                workflowID: UUID(),
                text: "workflow replaced",
                captureTags: excludedTags
            ),
            replacing: pushedItemID
        )
        await stack.deleteItem(id: pushedItemID)

        await stack.captureWorkflowClipboardCopy(
            text: "copy protected",
            workflowID: UUID(),
            workflow: WorkflowPresentation(fallbackName: "Protected Copy"),
            context: ClipboardRouteContext(),
            alternatives: [],
            captureTags: excludedTags
        )
        snapshot = await stack.clipboardSnapshot()
        XCTAssertEqual(snapshot.items.map(\.text), ["copy protected"])

        await eventBus.publish(
            .diagnostic(
                DiagnosticEvent(
                    subsystem: .clipboard,
                    level: .debug,
                    event: "diagnostic.boundary",
                    message: "boundary"
                )
            )
        )
        let groupEvents = await eventTask.value
        XCTAssertTrue(groupEvents.isEmpty)
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
        let initialStack = DeliveryStack(
            eventBus: eventBus,
            clipboardPersistenceStore: settingsStore
        )
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

        let restoredStack = DeliveryStack(
            eventBus: eventBus,
            clipboardPersistenceStore: settingsStore
        )
        let restoredSnapshot = try await Self.waitForSnapshot(from: restoredStack) { snapshot in
            snapshot.items.count == 1
        }

        let item = try XCTUnwrap(restoredSnapshot.items.first)
        XCTAssertEqual(item.contentKind, .files)
        XCTAssertEqual(item.fileURLs, fileURLs)
        XCTAssertEqual(item.text, "alpha.txt, beta.png")
        XCTAssertTrue(item.supportsDirectPaste)
        XCTAssertFalse(item.supportsWorkflowReplay)
        XCTAssertTrue(restoredSnapshot.groups.allSatisfy { $0.count == 0 })
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

    func testGroupSummaryPreviewOrderFollowsPasteMode() async {
        let cases: [(mode: ClipboardPasteMode, expected: [String])] = [
            (.stack, ["fourth", "third", "second"]),
            (.queue, ["first", "second", "third"]),
        ]

        for testCase in cases {
            let stack = DeliveryStack(eventBus: EventBus())
            let context = ClipboardRouteContext(
                applicationName: "Notes",
                bundleIdentifier: "com.apple.Notes"
            )
            let group = (await stack.createGroup(named: "Preview order")).group!
            await stack.assignApplication(
                bundleIdentifier: "com.apple.Notes",
                applicationName: "Notes",
                toGroup: group.id
            )
            await stack.setMode(testCase.mode, forGroup: group.id)

            for (offset, text) in ["first", "second", "third", "fourth"].enumerated() {
                await stack.captureSystemClipboard(
                    snapshot: ClipboardSnapshot(plainText: text, changeCount: offset + 1),
                    context: context
                )
            }

            let snapshot = await stack.clipboardSnapshot()
            let summary = snapshot.groups.first(where: { $0.group.id == group.id })

            XCTAssertEqual(
                previewTexts(in: summary, from: snapshot),
                testCase.expected,
                "Unexpected preview order for \(testCase.mode)."
            )
        }
    }

    func testGroupSummaryIncludesMultiplePreviewItemsWithImages() async {
        let stack = DeliveryStack(eventBus: EventBus())
        let context = ClipboardRouteContext(
            applicationName: "Preview",
            bundleIdentifier: "com.apple.Preview"
        )
        let group = (await stack.createGroup(named: "Preview")).group!
        await stack.assignApplication(
            bundleIdentifier: "com.apple.Preview",
            applicationName: "Preview",
            toGroup: group.id
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
        let summary = snapshot.groups.first(where: { $0.group.id == group.id })

        XCTAssertEqual(previewTexts(in: summary, from: snapshot), ["beta", "Copied image", "alpha"])
    }

}
