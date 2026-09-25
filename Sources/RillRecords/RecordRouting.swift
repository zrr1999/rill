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
        let destinations = try await router.captureDestinations(for: envelope)
        return try await store.ingest(envelope.draft, into: destinations)
    }

    @discardableResult
    public func capture(from source: any RecordSource) async throws -> RecordProjection? {
        guard let envelope = try await source.capture() else { return nil }
        return try await ingest(envelope)
    }
}

public actor RecordDeliveryCoordinator {
    private let store: RecordStore
    private let router: RecordRouter
    private let sinks: [RecordSinkIdentity: any RecordSink]

    public enum RegistrationError: Error, Sendable, Equatable {
        case duplicateSink(RecordSinkIdentity)
    }

    public init(store: RecordStore, router: RecordRouter? = nil) {
        self.store = store
        self.router = router ?? RecordRouter(store: store)
        self.sinks = [:]
    }

    public init(
        store: RecordStore,
        router: RecordRouter? = nil,
        sinks: [any RecordSink]
    ) throws {
        var registered: [RecordSinkIdentity: any RecordSink] = [:]
        for sink in sinks {
            guard registered[sink.identity] == nil else {
                throw RegistrationError.duplicateSink(sink.identity)
            }
            registered[sink.identity] = sink
        }
        self.store = store
        self.router = router ?? RecordRouter(store: store)
        self.sinks = registered
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
        _ leaseID: UUID,
        receipt: RecordDeliveryReceipt? = nil
    ) async throws -> RecordDeliveryReceipt {
        try await store.completeDelivery(leaseID: leaseID, receipt: receipt)
    }

    public func failDelivery(_ leaseID: UUID) async throws {
        try await store.failDelivery(leaseID: leaseID)
    }

    public func cancelDelivery(_ leaseID: UUID) async throws {
        try await store.cancelDelivery(leaseID: leaseID)
    }

    @discardableResult
    public func deliver(
        to target: FocusedApplicationIdentity,
        manualMembershipID: RecordMembershipID? = nil
    ) async throws -> RecordDeliveryReceipt {
        let preparation = try await beginDelivery(
            to: target,
            manualMembershipID: manualMembershipID
        )
        let rule = preparation.route
        let sinkID = preparation.sink
        let sink: any RecordSink
        if sinkID == .recordCollection, let collectionID = rule?.sinkCollectionID {
            sink = RecordCollectionSink(store: store, collectionID: collectionID)
        } else if let registered = sinks[sinkID] {
            sink = registered
        } else {
            try? await failDelivery(preparation.lease.id)
            throw RecordStoreError.collectionUnavailable
        }
        let lease = preparation.lease
        let request = RecordDeliveryRequest(
            record: lease.record,
            membershipID: lease.membership.id,
            collectionID: lease.membership.collectionID,
            targetApplication: target
        )
        do {
            let receipt = try await sink.deliver(request)
            return try await completeDelivery(lease.id, receipt: receipt)
        } catch {
            try? await failDelivery(lease.id)
            throw error
        }
    }
}

public struct RecordCollectionSink: RecordSink {
    public let identity: RecordSinkIdentity = .recordCollection
    private let store: RecordStore
    private let collectionID: RecordCollectionID

    public init(store: RecordStore, collectionID: RecordCollectionID) {
        self.store = store
        self.collectionID = collectionID
    }

    public func deliver(_ request: RecordDeliveryRequest) async throws -> RecordDeliveryReceipt {
        _ = try await store.addMembership(recordID: request.record.id, to: collectionID)
        return RecordDeliveryReceipt(
            recordID: request.record.id,
            membershipID: request.membershipID,
            sink: identity
        )
    }
}
