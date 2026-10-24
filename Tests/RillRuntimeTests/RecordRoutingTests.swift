@testable import RillWorkflows
@testable import RillRecords
import RillDomainTestSupport
import Foundation
import XCTest

@testable import RillCore

final class RecordRoutingTests: XCTestCase {
  func testCaptureCreatesOneRecordInStableUnionOfCollections() async throws {
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
    let envelope = RecordCaptureEnvelope(
      draft: draft("captured", source: .workflow),
      requestedCollectionIDs: [RecordCollection.voiceInputID]
    )

    let projection = try await RecordIngestionCoordinator(store: store).ingest(envelope)

    XCTAssertEqual(
      projection.memberships.map(\.collectionID),
      [RecordCollection.voiceInputID, second.id, RecordCollection.inboxID]
    )
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
    let coordinator = RecordDeliveryCoordinator(store: store)

    let preparation = try await coordinator.beginDelivery(
      to: FocusedApplicationIdentity(bundleIdentifier: "dev.rill.target")
    )
    XCTAssertEqual(preparation.lease.record.id, shared.id)
    XCTAssertEqual(preparation.sink, .systemClipboard)
    let receipt = try await coordinator.completeDelivery(preparation.lease.id)

    XCTAssertEqual(receipt.recordID, shared.id)
    XCTAssertEqual(receipt.sink, .systemClipboard)
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

  func testSessionDeliveryAddsMembershipWithoutDuplicatingRecord() async throws {
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
    let bus = EventBus()
    let coordinator = makeTestSessionCoordinator(
      recognizerRegistry: .init(recognizers: []),
      transformerRegistry: .init(transformers: []),
      actionRegistry: .init(actions: []),
      candidateResolver: CandidateResolver(eventBus: bus),
      recordStore: store,
      eventBus: bus
    )

    await coordinator.deliverNextRecord()
    await coordinator.shutdownRecordDeliverySettlements()

    let snapshot = try await store.snapshot()
    XCTAssertEqual(snapshot.records.count, 1)
    let updated = try XCTUnwrap(snapshot.records.first(where: { $0.id == projection.id }))
    XCTAssertEqual(
      Set(updated.memberships.map(\.collectionID)),
      [RecordCollection.inboxID, destination.id]
    )
    XCTAssertEqual(updated.activity.useCount, 1)
    XCTAssertEqual(updated.memberships.first(where: { $0.collectionID == RecordCollection.inboxID })?.state, .consumed)
    XCTAssertEqual(updated.memberships.first(where: { $0.collectionID == destination.id })?.state, .active)
  }

  private func draft(_ text: String, source: RecordSourceKind = .systemClipboard) -> RecordDraft {
    RecordDraft(
      payload: .text(text),
      provenance: RecordProvenance(source: RecordSourceIdentity(kind: source))
    )
  }
}
