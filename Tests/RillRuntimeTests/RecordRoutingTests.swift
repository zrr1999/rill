@testable import RillWorkflows
@testable import RillRecords
import Foundation
import XCTest

@testable import RillCore

final class RecordRoutingTests: XCTestCase {
    func testCaptureSourceCreatesOneRecordInStableUnionOfCollections() async throws {
        let store = RecordStore()
        let second = try await store.createCollection(name: "Second", preset: .queue)
        try await store.replaceCaptureRules([
            CaptureRouteRule(
                matcher: CaptureRouteMatcher(sourceKinds: [.workflow]),
                destinationCollectionIDs: [second.id, RecordCollection.inboxID]
            ),
            CaptureRouteRule(
                matcher: CaptureRouteMatcher(sourceKinds: [.workflow]),
                destinationCollectionIDs: [RecordCollection.inboxID, RecordCollection.voiceInputID]
            ),
        ])
        let source = RoutingRecordSource(
            envelope: RecordCaptureEnvelope(
                draft: draft("captured", source: .workflow),
                requestedCollectionIDs: [RecordCollection.voiceInputID]
            )
        )

        let captured = try await RecordIngestionCoordinator(store: store).capture(from: source)

        let projection = try XCTUnwrap(captured)
        XCTAssertEqual(projection.memberships.map(\.collectionID), [
            RecordCollection.voiceInputID,
            second.id,
            RecordCollection.inboxID,
        ])
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.records.count, 1)
    }

    func testDeliveryRouteFallsThroughOrderedCollectionsAndConsumesOnlyOrigin() async throws {
        let store = RecordStore()
        let empty = try await store.createCollection(name: "Empty", preset: .stack)
        let source = try await store.createCollection(name: "Source", preset: .stack)
        let shared = try await store.ingest(
            draft("deliver"),
            into: [source.id, RecordCollection.inboxID]
        )
        try await store.replaceDeliveryRules([
            DeliveryRouteRule(
                matcher: DeliveryRouteMatcher(targetBundleIdentifiers: ["dev.rill.target"]),
                priority: 50,
                sourceCollectionIDs: [empty.id, source.id],
                sink: .systemClipboard
            )
        ])
        let probe = RoutingSinkProbe()
        let coordinator = try RecordDeliveryCoordinator(
            store: store,
            sinks: [RoutingRecordSink(identity: .systemClipboard, probe: probe)]
        )

        let receipt = try await coordinator.deliver(
            to: FocusedApplicationIdentity(bundleIdentifier: "dev.rill.target")
        )

        XCTAssertEqual(receipt.recordID, shared.id)
        XCTAssertEqual(receipt.sink, .systemClipboard)
        let requests = await probe.requests()
        XCTAssertEqual(requests.map(\.record.id), [shared.id])
        let loadedProjection = try await store.record(id: shared.id)
        let loaded = try XCTUnwrap(loadedProjection)
        XCTAssertEqual(
            loaded.memberships.first(where: { $0.collectionID == source.id })?.state,
            .consumed
        )
        XCTAssertEqual(
            loaded.memberships.first(where: { $0.collectionID == RecordCollection.inboxID })?.state,
            .active
        )
    }

    func testSinkFailureReleasesLeaseWithoutConsumingMembership() async throws {
        let store = RecordStore()
        let projection = try await store.ingest(
            draft("retry"),
            into: [RecordCollection.inboxID]
        )
        let probe = RoutingSinkProbe(shouldFail: true)
        let coordinator = try RecordDeliveryCoordinator(
            store: store,
            sinks: [RoutingRecordSink(identity: .focusedApplication, probe: probe)]
        )

        do {
            _ = try await coordinator.deliver(to: FocusedApplicationIdentity())
            XCTFail("Expected the sink failure")
        } catch RoutingSinkError.rejected {}

        let loadedProjection = try await store.record(id: projection.id)
        let loaded = try XCTUnwrap(loadedProjection)
        XCTAssertEqual(loaded.memberships.first?.state, .active)
        XCTAssertEqual(loaded.activity.latestFailure, .deliveryFailed)
        _ = try await store.beginDelivery(
            sourceCollectionIDs: [RecordCollection.inboxID],
            sink: .focusedApplication
        )
    }

    func testValidatedSinkReceiptBecomesTheDurableDeliveryFact() async throws {
        let store = RecordStore()
        let projection = try await store.ingest(
            draft("receipt"),
            into: [RecordCollection.inboxID]
        )
        let membership = try XCTUnwrap(projection.memberships.first)
        let deliveredAt = Date(timeIntervalSince1970: 1_775_555_555)
        let sinkReceipt = RecordDeliveryReceipt(
            id: UUID(uuidString: "AFA0D50F-2DA8-411D-97BD-50F31E984424")!,
            recordID: projection.id,
            membershipID: membership.id,
            sink: .focusedApplication,
            deliveredAt: deliveredAt
        )
        let coordinator = try RecordDeliveryCoordinator(
            store: store,
            sinks: [FixedReceiptSink(receipt: sinkReceipt)]
        )

        let receipt = try await coordinator.deliver(to: FocusedApplicationIdentity())

        XCTAssertEqual(receipt, sinkReceipt)
        let loaded = try await store.record(id: projection.id)
        let updated = try XCTUnwrap(loaded)
        XCTAssertEqual(updated.activity.lastDeliveredAt, deliveredAt)
        XCTAssertEqual(updated.activity.useCount, 1)
        XCTAssertEqual(updated.memberships.first?.state, .consumed)
    }

    func testMismatchedSinkReceiptFailsClosedAndRestoresTheMembership() async throws {
        let store = RecordStore()
        let projection = try await store.ingest(
            draft("do not consume"),
            into: [RecordCollection.inboxID]
        )
        let membership = try XCTUnwrap(projection.memberships.first)
        let forgedReceipt = RecordDeliveryReceipt(
            recordID: RecordID(),
            membershipID: membership.id,
            sink: .focusedApplication
        )
        let coordinator = try RecordDeliveryCoordinator(
            store: store,
            sinks: [FixedReceiptSink(receipt: forgedReceipt)]
        )

        do {
            _ = try await coordinator.deliver(to: FocusedApplicationIdentity())
            XCTFail("Expected a mismatched sink receipt to fail closed")
        } catch let error as RecordStoreError {
            XCTAssertEqual(error, .invalidDeliveryReceipt)
        }

        let loaded = try await store.record(id: projection.id)
        let updated = try XCTUnwrap(loaded)
        XCTAssertEqual(updated.activity.useCount, 0)
        XCTAssertEqual(updated.activity.latestFailure, .deliveryFailed)
        XCTAssertEqual(updated.memberships.first?.state, .active)
        _ = try await store.beginDelivery(
            sourceCollectionIDs: [RecordCollection.inboxID],
            sink: .focusedApplication
        )
    }

    func testRecordCollectionSinkAddsMembershipWithoutDuplicatingRecord() async throws {
        let store = RecordStore()
        let destination = try await store.createCollection(name: "Destination", preset: .list)
        let projection = try await store.ingest(
            draft("route internally"),
            into: [RecordCollection.inboxID]
        )
        try await store.replaceDeliveryRules([
            DeliveryRouteRule(
                matcher: DeliveryRouteMatcher(),
                priority: 10,
                sourceCollectionIDs: [RecordCollection.inboxID],
                sink: .recordCollection,
                sinkCollectionID: destination.id
            )
        ])

        let receipt = try await RecordDeliveryCoordinator(store: store).deliver(
            to: FocusedApplicationIdentity()
        )

        XCTAssertEqual(receipt.sink, .recordCollection)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.records.count, 1)
        let updated = try XCTUnwrap(snapshot.records.first(where: { $0.id == projection.id }))
        XCTAssertEqual(Set(updated.memberships.map(\.collectionID)), [
            RecordCollection.inboxID,
            destination.id,
        ])
    }

    func testDuplicateSinkFailsBeforeAnyDeliveryOrLease() async throws {
        let store = RecordStore()
        let record = try await store.ingest(draft("keep pending"), into: [RecordCollection.inboxID])
        let before = try await store.snapshot()
        let probe = RoutingSinkProbe()
        let sink = RoutingRecordSink(identity: .focusedApplication, probe: probe)

        XCTAssertThrowsError(try RecordDeliveryCoordinator(store: store, sinks: [sink, sink])) { error in
            XCTAssertEqual(error as? RecordDeliveryCoordinator.RegistrationError, .duplicateSink(.focusedApplication))
        }
        let after = try await store.snapshot()
        XCTAssertEqual(after, before)
        let requests = await probe.requests()
        XCTAssertTrue(requests.isEmpty)
        let lease = try await store.beginDelivery(
            sourceCollectionIDs: [RecordCollection.inboxID], sink: .focusedApplication
        )
        XCTAssertEqual(lease.record.id, record.id)
    }

    private func draft(_ text: String, source: RecordSourceKind = .systemClipboard) -> RecordDraft {
        RecordDraft(
            payload: .text(text),
            provenance: RecordProvenance(source: RecordSourceIdentity(kind: source))
        )
    }
}

private struct RoutingRecordSource: RecordSource {
    let envelope: RecordCaptureEnvelope?

    func capture() async throws -> RecordCaptureEnvelope? {
        envelope
    }
}

private actor RoutingSinkProbe {
    private var capturedRequests: [RecordDeliveryRequest] = []
    private let shouldFail: Bool

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func accept(_ request: RecordDeliveryRequest) throws {
        capturedRequests.append(request)
        if shouldFail { throw RoutingSinkError.rejected }
    }

    func requests() -> [RecordDeliveryRequest] {
        capturedRequests
    }
}

private struct RoutingRecordSink: RecordSink {
    let identity: RecordSinkIdentity
    let probe: RoutingSinkProbe

    func deliver(_ request: RecordDeliveryRequest) async throws -> RecordDeliveryReceipt {
        try await probe.accept(request)
        return RecordDeliveryReceipt(
            recordID: request.record.id,
            membershipID: request.membershipID,
            sink: identity
        )
    }
}

private struct FixedReceiptSink: RecordSink {
    let identity: RecordSinkIdentity
    let receipt: RecordDeliveryReceipt

    init(receipt: RecordDeliveryReceipt) {
        identity = receipt.sink
        self.receipt = receipt
    }

    func deliver(_ request: RecordDeliveryRequest) async throws -> RecordDeliveryReceipt {
        _ = request
        return receipt
    }
}

private enum RoutingSinkError: Error {
    case rejected
}
