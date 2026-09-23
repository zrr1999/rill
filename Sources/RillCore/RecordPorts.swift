import Foundation

public struct RecordCaptureEnvelope: Sendable, Equatable {
    public var draft: RecordDraft
    public var requestedCollectionIDs: [RecordCollectionID]
    public var bufferEntryID: BufferEntryID?

    public init(
        draft: RecordDraft,
        requestedCollectionIDs: [RecordCollectionID] = [],
        bufferEntryID: BufferEntryID? = nil
    ) {
        precondition(requestedCollectionIDs.count <= RecordGraphLimits.maximumRouteCollections)
        self.bufferEntryID = bufferEntryID
        self.draft = draft
        self.requestedCollectionIDs = requestedCollectionIDs
    }
}

public protocol RecordSource: Sendable {
    func capture() async throws -> RecordCaptureEnvelope?
}

public protocol RecordIngestionSink: Sendable {
    @discardableResult
    func ingest(_ envelope: RecordCaptureEnvelope) async throws -> RecordProjection
}

public struct RecordDeliveryRequest: Sendable, Equatable {
    public let record: Record
    public let membershipID: RecordMembershipID
    public let collectionID: RecordCollectionID
    public let targetApplication: FocusedApplicationIdentity?

    public init(
        record: Record,
        membershipID: RecordMembershipID,
        collectionID: RecordCollectionID,
        targetApplication: FocusedApplicationIdentity? = nil
    ) {
        self.record = record
        self.membershipID = membershipID
        self.collectionID = collectionID
        self.targetApplication = targetApplication
    }
}

public struct RecordDeliveryReceipt: Codable, Sendable, Equatable {
    public let id: UUID
    public let recordID: RecordID
    public let membershipID: RecordMembershipID?
    public let sink: RecordSinkIdentity
    public let deliveredAt: Date

    public init(
        id: UUID = UUID(),
        recordID: RecordID,
        membershipID: RecordMembershipID?,
        sink: RecordSinkIdentity,
        deliveredAt: Date = Date()
    ) {
        self.id = id
        self.recordID = recordID
        self.membershipID = membershipID
        self.sink = sink
        self.deliveredAt = deliveredAt
    }
}

public protocol RecordSink: Sendable {
    var identity: RecordSinkIdentity { get }
    func deliver(_ request: RecordDeliveryRequest) async throws -> RecordDeliveryReceipt
}

public struct RecordGraphPersistenceBlobReference: Codable, Sendable, Equatable, Hashable {
    public let blobID: UUID
    public let recordID: RecordID
    public let kind: RecordPayloadKind
    public let byteCount: Int

    public init(
        blobID: UUID,
        recordID: RecordID,
        kind: RecordPayloadKind,
        byteCount: Int
    ) {
        precondition(byteCount > 0)
        self.blobID = blobID
        self.recordID = recordID
        self.kind = kind
        self.byteCount = byteCount
    }
}

public struct RecordGraphPersistenceBlob: Sendable, Equatable {
    public let reference: RecordGraphPersistenceBlobReference
    public let payload: Data

    public init(reference: RecordGraphPersistenceBlobReference, payload: Data) {
        self.reference = reference
        self.payload = payload
    }
}

public enum RecordGraphPersistenceReadSnapshot: Sendable, Equatable {
    case empty
    case legacyClipboard(metadata: Data, imageBlobs: [LegacyRecordGraphImageBlob])
    case current(revision: Int64, graph: Data, payloadBlobs: [RecordGraphPersistenceBlob])
}

public struct RecordGraphPersistenceWriteSnapshot: Sendable, Equatable {
    public let expectedRevision: Int64?
    public let graph: Data
    public let newPayloadBlobs: [RecordGraphPersistenceBlob]
    public let retainedPayloadBlobReferences: [RecordGraphPersistenceBlobReference]

    public init(
        expectedRevision: Int64?,
        graph: Data,
        newPayloadBlobs: [RecordGraphPersistenceBlob],
        retainedPayloadBlobReferences: [RecordGraphPersistenceBlobReference]
    ) {
        self.expectedRevision = expectedRevision
        self.graph = graph
        self.newPayloadBlobs = newPayloadBlobs
        self.retainedPayloadBlobReferences = retainedPayloadBlobReferences
    }
}

public protocol RecordGraphPersistenceStore: Sendable {
    func loadRecordGraph() async throws -> RecordGraphPersistenceReadSnapshot
    func replaceRecordGraph(with snapshot: RecordGraphPersistenceWriteSnapshot) async throws -> Int64
    func removeRecordGraph() async throws -> RecordGraphRemovalResult
}
