import Foundation
import RillCore

public struct RecordRouter: Sendable {
  private let store: RecordStore

  public init(store: RecordStore) {
    self.store = store
  }

  public func captureDestinations(
    for envelope: RecordCaptureEnvelope
  ) async throws -> [RecordCollectionID] {
    try await store.routedCaptureDestinations(for: envelope)
  }

  public func deliveryRoute(
    for target: FocusedApplicationIdentity
  ) async throws -> DeliveryRouteRule? {
    try await store.resolveDeliveryRoute(target: target)
  }
}

public actor RecordIngestionCoordinator: RecordIngestionSink {
  private let store: RecordStore
  private let router: RecordRouter

  public init(store: RecordStore, router: RecordRouter? = nil) {
    self.store = store
    self.router = router ?? RecordRouter(store: store)
  }

  @discardableResult
  public func ingest(_ envelope: RecordCaptureEnvelope) async throws -> RecordProjection {
    if let intent = envelope.draftInput {
      return try await store.ingestBufferDictation(
        envelope.draft,
        recognitionText: envelope.recognitionText ?? "", for: intent)
    }
    let destinations = try await router.captureDestinations(for: envelope)
    return try await store.ingest(envelope.draft, into: destinations, fulfilling: envelope.bufferEntryID, recognitionText: envelope.recognitionText)
  }

}

public actor RecordDeliveryCoordinator {
  private let store: RecordStore
  private let router: RecordRouter
  public init(store: RecordStore, router: RecordRouter? = nil) {
    self.store = store
    self.router = router ?? RecordRouter(store: store)
  }

  public struct Preparation: Sendable, Equatable {
    public let lease: RecordDeliveryLease
    public let route: DeliveryRouteRule?

    public var sink: RecordSinkIdentity { lease.sink }

    init(lease: RecordDeliveryLease, route: DeliveryRouteRule?) {
      self.lease = lease
      self.route = route
    }
  }

  public func beginDelivery(
    to target: FocusedApplicationIdentity,
    requestedSink: RecordSinkIdentity? = nil,
    manualMembershipID: RecordMembershipID? = nil
  ) async throws -> Preparation {
    let route = try await router.deliveryRoute(for: target)
    let sink = route?.sink ?? requestedSink ?? .focusedApplication
    let lease = try await store.beginDelivery(
      sourceCollectionIDs: route?.sourceCollectionIDs ?? [RecordCollection.inboxID],
      sink: sink,
      manualMembershipID: manualMembershipID
    )
    return Preparation(lease: lease, route: route)
  }

  public func beginDelivery(
    matching subject: RecordDeliverySubject,
    sink: RecordSinkIdentity
  ) async throws -> RecordDeliveryLease {
    try await store.beginDelivery(matching: subject, sink: sink)
  }

  public func beginReuse(_ subject: RecordReuseSubject, sink: RecordSinkIdentity) async throws -> RecordReuseLease {
    try await store.beginReuse(subject, sink: sink)
  }

  @discardableResult
  public func completeDelivery(
    _ leaseID: UUID
  ) async throws -> RecordDeliveryReceipt {
    try await store.completeDelivery(leaseID: leaseID)
  }

  public func failDelivery(_ leaseID: UUID) async throws {
    try await store.failDelivery(leaseID: leaseID)
  }

  public func cancelDelivery(_ leaseID: UUID) async throws {
    try await store.cancelDelivery(leaseID: leaseID)
  }
}
