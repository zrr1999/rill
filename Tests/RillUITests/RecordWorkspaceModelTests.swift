import XCTest

@testable import RillCore
@testable import RillRuntime
@testable import RillUI

@MainActor
final class RecordWorkspaceModelTests: XCTestCase {
    func testAllRecordsDeduplicatesSharedRecordAndMembershipRemovalKeepsItVisible() async throws {
        let store = RecordStore()
        let second = try await store.createCollection(name: "Second", preset: .queue)
        let projection = try await store.ingest(
            draft("shared"),
            into: [RecordCollection.inboxID, second.id]
        )
        let model = RecordWorkspaceModel(store: store)
        await model.refresh()

        XCTAssertEqual(model.visibleRecords.map(\.id), [projection.id])
        model.selectCollection(second.id)
        XCTAssertEqual(model.visibleRecords.map(\.id), [projection.id])

        let membership = try XCTUnwrap(model.visibleRecords.first?.memberships.first {
            $0.collectionID == second.id
        })
        await model.removeMembership(membership)
        XCTAssertNotNil(model.cleanup.plan)
        await model.cleanup.confirm()
        await model.refresh()

        XCTAssertTrue(model.visibleRecords.isEmpty)
        model.selectCollection(nil)
        XCTAssertEqual(model.visibleRecords.map(\.id), [projection.id])
        XCTAssertEqual(model.visibleRecords.first?.memberships.map(\.collectionID), [
            RecordCollection.inboxID,
        ])
    }

    func testBatchMembershipPinAndSearchAreRecordLevel() async throws {
        let store = RecordStore()
        let second = try await store.createCollection(name: "Second", preset: .list)
        let third = try await store.createCollection(name: "Third", preset: .stack)
        let projection = try await store.ingest(draft("Needle text"), into: [])
        let model = RecordWorkspaceModel(store: store)
        await model.refresh()

        await model.addRecord(projection.id, to: [second.id, third.id, second.id])
        let updated = try XCTUnwrap(model.snapshot.records.first(where: { $0.id == projection.id }))
        XCTAssertEqual(Set(updated.memberships.map(\.collectionID)), [second.id, third.id])

        await model.updateMetadata(for: updated, tags: ["Project Alpha"], isPinned: true)
        model.searchText = "project alpha"
        await waitForSearch(model)
        model.showsPinnedOnly = true
        XCTAssertEqual(model.visibleRecords.map(\.id), [projection.id])

        model.searchText = "missing"
        XCTAssertTrue(model.visibleRecords.isEmpty)
    }

    func testCollectionDeletionRequiresExplicitReferenceResolution() async throws {
        let store = RecordStore()
        let source = try await store.createCollection(name: "Routed", preset: .stack)
        try await store.replaceDeliveryRules([
            DeliveryRouteRule(
                matcher: DeliveryRouteMatcher(),
                priority: 10,
                sourceCollectionIDs: [source.id],
                sink: .focusedApplication
            )
        ])
        let model = RecordWorkspaceModel(store: store)
        await model.refresh()

        await model.requestCollectionDeletion(source.id)
        XCTAssertEqual(model.pendingCollectionDeletion?.collectionID, source.id)
        XCTAssertNotNil(model.snapshot.collections.first(where: { $0.id == source.id }))

        await model.confirmCollectionDeletion(source.id, resolution: .disableAffectedRoutes)
        XCTAssertNil(model.snapshot.collections.first(where: { $0.id == source.id }))
        XCTAssertEqual(model.snapshot.deliveryRules.first?.isEnabled, false)
    }

    func testSelectedListDeliverySubjectRequiresActiveMembershipInSelectedList() async throws {
        let store = RecordStore()
        let list = try await store.createCollection(name: "Reusable", preset: .list)
        let projection = try await store.ingest(draft("selected"), into: [list.id])
        let membership = try XCTUnwrap(projection.memberships.first)
        let model = RecordWorkspaceModel(store: store)
        await model.refresh()

        model.selectCollection(list.id)
        model.selectedRecordID = projection.id

        XCTAssertEqual(
            model.selectedListDeliverySubject,
            RecordDeliverySubject(
                recordID: projection.id,
                membershipID: membership.id,
                membershipRevision: membership.revision,
                collectionID: list.id,
                payloadKind: .text
            )
        )

        model.selectCollection(RecordCollection.inboxID)
        model.selectedRecordID = projection.id
        XCTAssertNil(model.selectedListDeliverySubject)

        _ = try await store.updateCollection(
            list.id,
            selectionPolicy: .manual,
            consumptionPolicy: .consumeAfterSuccessfulDelivery
        )
        await model.refresh()
        model.selectCollection(list.id)
        model.selectedRecordID = projection.id

        XCTAssertNil(model.selectedListDeliverySubject)

        _ = try await store.updateCollection(list.id, preset: .list)
        await model.refresh()
        model.selectCollection(list.id)
        model.selectedRecordID = projection.id

        XCTAssertEqual(model.selectedListDeliverySubject?.membershipID, membership.id)
    }

    func testSourceAppFilterNarrowsVisibleRecordsByBundleIdentifier() async throws {
        let store = RecordStore()
        let safari = try await store.ingest(draft("from safari", bundleID: "com.apple.Safari"), into: [])
        _ = try await store.ingest(draft("from notes", bundleID: "com.apple.Notes"), into: [])
        _ = try await store.ingest(draft("no source app"), into: [])
        let model = RecordWorkspaceModel(store: store)
        await model.refresh()
        XCTAssertEqual(model.visibleRecords.count, 3)

        model.sourceAppFilterBundleIdentifier = "com.apple.Safari"
        XCTAssertEqual(model.visibleRecords.map(\.id), [safari.id])

        model.sourceAppFilterBundleIdentifier = nil
        XCTAssertEqual(model.visibleRecords.count, 3)
    }

    func testDeliverySubjectForVisibleRecordPrefersSelectedCollectionMembership() async throws {
        let store = RecordStore()
        let stack = try await store.createCollection(name: "Stack", preset: .stack)
        let list = try await store.createCollection(name: "Reusable", preset: .list)
        let projection = try await store.ingest(draft("deliverable"), into: [stack.id, list.id])
        let model = RecordWorkspaceModel(store: store)
        await model.refresh()

        // All Records: falls back to the first membership regardless of preset.
        let fallback = try XCTUnwrap(model.deliverySubject(forVisibleRecordAt: 0))
        XCTAssertEqual(fallback.recordID, projection.id)
        XCTAssertEqual(fallback.payloadKind, .text)

        // A selected collection contributes its own membership.
        model.selectCollection(list.id)
        let listMembership = try XCTUnwrap(projection.memberships.first { $0.collectionID == list.id })
        let subject = try XCTUnwrap(model.deliverySubject(forVisibleRecordAt: 0))
        XCTAssertEqual(subject.membershipID, listMembership.id)
        XCTAssertEqual(subject.membershipRevision, listMembership.revision)
        XCTAssertEqual(subject.collectionID, list.id)
    }

    func testDeliverySubjectForVisibleRecordRejectsNoMembershipAndOutOfBounds() async throws {
        let store = RecordStore()
        let projection = try await store.ingest(draft("no collection"), into: [])
        let model = RecordWorkspaceModel(store: store)
        await model.refresh()

        XCTAssertEqual(model.visibleRecords.map(\.id), [projection.id])
        XCTAssertNil(model.deliverySubject(forVisibleRecordAt: 0))
        XCTAssertNil(model.deliverySubject(forVisibleRecordAt: 1))
        XCTAssertNil(model.deliverySubject(forVisibleRecordAt: -1))
    }

    func testDeletingSelectionMovesToNeighborAndKeepsSearch() async throws {
        let store = RecordStore()
        _ = try await store.ingest(draft("needle first"), into: [])
        _ = try await store.ingest(draft("needle second"), into: [])
        let model = RecordWorkspaceModel(store: store)
        await model.refresh()
        model.searchText = "needle"
        await waitForSearch(model)
        let first = try XCTUnwrap(model.visibleRecords.first)
        let neighbor = try XCTUnwrap(model.visibleRecords.last)
        model.selectedRecordID = first.id
        await model.deleteRecord(first.id)
        await model.cleanup.confirm()
        await model.refresh()
        await waitForSearch(model)
        XCTAssertEqual(model.selectedRecordID, neighbor.id)
        XCTAssertEqual(model.searchText, "needle")
        await model.deleteRecord(neighbor.id)
        await model.cleanup.confirm()
        await model.refresh()
        await waitForSearch(model)
        XCTAssertNil(model.selectedRecordID)
    }

    func testFilteredSelectionHidesInspectorAndReturnsWhenFilterClears() async throws {
        let store = RecordStore()
        let record = try await store.ingest(draft("visible record"), into: [])
        let model = RecordWorkspaceModel(store: store)
        await model.refresh()
        model.selectedRecordID = record.id
        XCTAssertEqual(model.selectedVisibleRecord?.id, record.id)
        model.searchText = "no match"
        XCTAssertNil(model.selectedVisibleRecord)
        XCTAssertEqual(model.selectedRecordID, record.id)
        model.searchText = ""
        XCTAssertEqual(model.selectedVisibleRecord?.id, record.id)
    }

    private func waitForSearch(_ model: RecordWorkspaceModel) async {
        for _ in 0..<100 {
            await Task.yield()
            if !model.isSearching { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Search did not settle")
    }

    private func draft(_ text: String, bundleID: String? = nil) -> RecordDraft {
        RecordDraft(
            payload: .text(text),
            provenance: RecordProvenance(
                source: RecordSourceIdentity(kind: .user),
                sourceBundleIdentifier: bundleID
            )
        )
    }
}
