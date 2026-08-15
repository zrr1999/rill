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

    private func draft(_ text: String) -> RecordDraft {
        RecordDraft(
            payload: .text(text),
            provenance: RecordProvenance(source: RecordSourceIdentity(kind: .user))
        )
    }
}
