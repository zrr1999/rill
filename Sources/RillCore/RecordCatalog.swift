import Foundation

/// The catalog never retains a payload. Opening a record is a separate read.
public struct RecordHeader: Codable, Sendable, Equatable, Identifiable {
  public let id: RecordID
  public let kind: RecordPayloadKind
  public let byteCount: Int
  public let preview: String
  public let provenance: RecordProvenance
  public let createdAt: Date

  public init(record: Record, byteCount: Int) {
    id = record.id
    kind = record.payload.kind
    self.byteCount = byteCount
    switch record.payload {
    case .text(let text):
      preview = String(
        decoding: RecordTextFormatting.previewText(text).utf8.prefix(1_024), as: UTF8.self)
    case .image: preview = ""
    case .files(let urls):
      preview = String(
        decoding: urls.map(\.lastPathComponent).joined(separator: ", ").utf8.prefix(1_024),
        as: UTF8.self)
    }
    provenance = record.provenance
    createdAt = record.createdAt
  }

  public func materialize(_ payload: RecordPayload) -> Record {
    Record(id: id, payload: payload, provenance: provenance, createdAt: createdAt)
  }
}

public struct RecordSummary: Identifiable, Sendable, Equatable {
  public let header: RecordHeader
  public let metadata: RecordMetadata
  public let activity: RecordActivity
  public let memberships: [RecordMembership]
  public var id: RecordID { header.id }

  public init(
    header: RecordHeader, metadata: RecordMetadata, activity: RecordActivity,
    memberships: [RecordMembership]
  ) {
    self.header = header
    self.metadata = metadata
    self.activity = activity
    self.memberships = memberships
  }

  public var reuseSubject: RecordReuseSubject {
    RecordReuseSubject(recordID: id, metadataRevision: metadata.revision)
  }
}

public struct RecordReuseSubject: Sendable, Equatable, Hashable {
  public let recordID: RecordID
  public let metadataRevision: UInt64

  public init(recordID: RecordID, metadataRevision: UInt64) {
    self.recordID = recordID
    self.metadataRevision = metadataRevision
  }
}

public struct RecordCapacity: Sendable, Equatable {
  public let count: Int
  public let byteCount: Int
  public let maximumCount: Int
  public let maximumByteCount: Int
  public let admissionWasLimited: Bool

  public init(
    count: Int, byteCount: Int, limits: RecordStorageLimits = .productDefault,
    admissionWasLimited: Bool = false
  ) {
    self.count = count
    self.admissionWasLimited = admissionWasLimited
    self.byteCount = byteCount
    maximumCount = limits.maximumRecordCount
    maximumByteCount = limits.maximumTotalPayloadByteCount
  }

  public var isWarning: Bool {
    count >= (maximumCount + 1) / 2 || byteCount >= (maximumByteCount + 1) / 2
  }

  public var isCaptureLimited: Bool { isFull || admissionWasLimited }

  public var isFull: Bool { count >= maximumCount || byteCount >= maximumByteCount }
}

public struct RecordCatalogSnapshot: Sendable, Equatable {
  public let revision: UInt64
  public let records: [RecordSummary]
  public let collections: [RecordCollection]
  public let captureRules: [CaptureRouteRule]
  public let deliveryRules: [DeliveryRouteRule]
  public let capacity: RecordCapacity

  public init(
    revision: UInt64, records: [RecordSummary], collections: [RecordCollection],
    captureRules: [CaptureRouteRule], deliveryRules: [DeliveryRouteRule], capacity: RecordCapacity
  ) {
    self.revision = revision
    self.records = records
    self.collections = collections
    self.captureRules = captureRules
    self.deliveryRules = deliveryRules
    self.capacity = capacity
  }

  public static let empty = Self(
    revision: 0, records: [], collections: [], captureRules: [], deliveryRules: [],
    capacity: .init(count: 0, byteCount: 0))
}

public enum RecordQueryMatching: Sendable, Equatable {
  case literal
  case approximate
}

public struct RecordQuery: Sendable, Equatable {
  public var text: String
  public var collectionID: RecordCollectionID?
  public var sourceBundleIdentifier: String?
  public var kind: RecordPayloadKind?
  public var pinnedOnly: Bool
  public var matching: RecordQueryMatching

  public init(
    text: String = "", collectionID: RecordCollectionID? = nil,
    sourceBundleIdentifier: String? = nil, kind: RecordPayloadKind? = nil, pinnedOnly: Bool = false,
    matching: RecordQueryMatching = .literal
  ) {
    self.text = text
    self.collectionID = collectionID
    self.sourceBundleIdentifier = sourceBundleIdentifier
    self.kind = kind
    self.pinnedOnly = pinnedOnly
    self.matching = matching
  }
}

public struct RecordQueryPage: Sendable, Equatable {
  public let revision: UInt64
  public let records: [RecordSummary]
  public let nextOffset: Int?

  public init(revision: UInt64, records: [RecordSummary], nextOffset: Int?) {
    self.revision = revision
    self.records = records
    self.nextOffset = nextOffset
  }
}

public enum RecordCleanupScope: Sendable, Equatable {
  case history(olderThan: Date)
  case record(RecordID)
  case collection(RecordCollectionID)
  case membership(RecordMembershipID)
}

public struct RecordCleanupPlan: Identifiable, Sendable, Equatable {
  public let id: UUID
  public let revision: UInt64
  public let recordIDs: [RecordID]
  public let byteCount: Int
  public let protectedCount: Int
  public let scope: RecordCleanupScope
  public let membershipIDs: [RecordMembershipID]

  public init(
    id: UUID = UUID(), revision: UInt64, recordIDs: [RecordID], byteCount: Int, protectedCount: Int,
    scope: RecordCleanupScope = .history(olderThan: .distantFuture),
    membershipIDs: [RecordMembershipID] = []
  ) {
    self.id = id
    self.revision = revision
    self.recordIDs = recordIDs
    self.byteCount = byteCount
    self.protectedCount = protectedCount
    self.scope = scope
    self.membershipIDs = membershipIDs
  }
}

public struct RecordCatalogNode: Codable, Sendable, Equatable {
  public enum Kind: String, Codable, Sendable, CaseIterable {
    case record, metadata, activity, membership, collection, captureRule, deliveryRule
  }
  public let kind: Kind
  public let id: String
  public let value: Data

  public init(kind: Kind, id: String, value: Data) {
    self.kind = kind
    self.id = id
    self.value = value
  }

  public var key: String { "\(kind.rawValue)/\(id)" }
}

public struct RecordCatalogManifest: Codable, Sendable, Equatable {
  public let schemaVersion: Int
  public let nextMembershipOrdinal: UInt64
  public let recordOrder: [RecordID]
  public let collectionOrder: [RecordCollectionID]

  public init(
    nextMembershipOrdinal: UInt64, recordOrder: [RecordID], collectionOrder: [RecordCollectionID]
  ) {
    schemaVersion = 2
    self.nextMembershipOrdinal = nextMembershipOrdinal
    self.recordOrder = recordOrder
    self.collectionOrder = collectionOrder
  }
}

public struct RecordCatalogRead: Sendable {
  public let revision: Int64
  public let manifest: RecordCatalogManifest
  public let nodes: [RecordCatalogNode]
  public let references: [RecordGraphPersistenceBlobReference]

  public init(
    revision: Int64, manifest: RecordCatalogManifest, nodes: [RecordCatalogNode],
    references: [RecordGraphPersistenceBlobReference]
  ) {
    self.revision = revision
    self.manifest = manifest
    self.nodes = nodes
    self.references = references
  }
}

public struct RecordCatalogMutation: Sendable {
  public let expectedRevision: Int64?
  public let manifest: RecordCatalogManifest
  public let upserts: [RecordCatalogNode]
  public let removedKeys: [String]
  public let newPayloadBlobs: [RecordGraphPersistenceBlob]
  public let removedPayloadBlobIDs: [UUID]

  public init(
    expectedRevision: Int64?, manifest: RecordCatalogManifest, upserts: [RecordCatalogNode],
    removedKeys: [String], newPayloadBlobs: [RecordGraphPersistenceBlob],
    removedPayloadBlobIDs: [UUID]
  ) {
    self.expectedRevision = expectedRevision
    self.manifest = manifest
    self.upserts = upserts
    self.removedKeys = removedKeys
    self.newPayloadBlobs = newPayloadBlobs
    self.removedPayloadBlobIDs = removedPayloadBlobIDs
  }
}

public protocol RecordCatalogPersistenceStore: RecordGraphPersistenceStore {
  func loadRecordCatalog() async throws -> RecordCatalogRead?
  func commitRecordCatalog(_ mutation: RecordCatalogMutation) async throws -> Int64
  func loadRecordPayload(_ reference: RecordGraphPersistenceBlobReference) async throws -> Data
}

public enum RecordReuseOutcome: Sendable, Equatable {
  case delivered
  case copied
  case blocked
  case targetUnavailable
  case permissionRequired
  case recordUnavailable
  case storageUnavailable
  case failed
  case outputCommittedWithIssue
}
