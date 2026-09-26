import Foundation

public struct RecordCleanupResult: Sendable, Equatable {
    public let removedCount: Int
    public let preservedActiveCount: Int

    public init(removedCount: Int, preservedActiveCount: Int) {
        self.removedCount = removedCount
        self.preservedActiveCount = preservedActiveCount
    }
}

public struct RecordRouteContext: Sendable, Equatable {
    public var applicationName: String?
    public var bundleIdentifier: String?

    public init(applicationName: String? = nil, bundleIdentifier: String? = nil) {
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
    }
}

public enum RecordActionID {
    public static let store = "record.store"
    public static let systemClipboardCopy = "system-clipboard.copy"
    public static let focusedApplicationInsert = "focused-application.insert"
    public static let collectionRoute = "record.collection"
}

private func recordStaticUUID(_ string: String) -> UUID {
    guard let uuid = UUID(uuidString: string) else {
        preconditionFailure("Invalid UUID string: \(string)")
    }
    return uuid
}

public protocol RecordIdentifier: Codable, Hashable, Sendable, RawRepresentable, CustomStringConvertible
where RawValue == UUID {}

public extension RecordIdentifier {
    var description: String { rawValue.uuidString }
}

public struct RecordID: RecordIdentifier, Identifiable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var id: Self { self }
}

public struct RecordCollectionID: RecordIdentifier, Identifiable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var id: Self { self }
}

public struct RecordMembershipID: RecordIdentifier, Identifiable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var id: Self { self }
}

public struct RecordRouteRuleID: RecordIdentifier, Identifiable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var id: Self { self }
}

public enum RecordPayloadKind: String, Codable, Sendable, CaseIterable {
    case text
    case image
    case files
}

/// Immutable user content. Mutation commands create a new `Record` instead of
/// changing an existing payload in place.
public enum RecordPayload: Codable, Sendable, Equatable {
    case text(String)
    case image(Data)
    case files([URL])

    public var kind: RecordPayloadKind {
        switch self {
        case .text: .text
        case .image: .image
        case .files: .files
        }
    }

    public var textValue: String? {
        guard case .text(let text) = self else { return nil }
        return text
    }

    public var imagePNGData: Data? {
        guard case .image(let data) = self else { return nil }
        return data
    }

    public var fileURLs: [URL] {
        guard case .files(let urls) = self else { return [] }
        return urls
    }
}

public enum RecordSourceKind: String, Codable, Sendable, Equatable {
    case systemClipboard = "system-clipboard"
    case voiceInput = "voice-input"
    case workflow
    case user
}

public struct RecordSourceIdentity: Codable, Sendable, Equatable, Hashable {
    public var kind: RecordSourceKind
    public var identifier: String?

    public init(kind: RecordSourceKind, identifier: String? = nil) {
        self.kind = kind
        self.identifier = identifier
    }
}

public struct RecordProvenance: Codable, Sendable, Equatable {
    public var source: RecordSourceIdentity
    public var sourceApplicationName: String?
    public var sourceBundleIdentifier: String?
    public var workflowID: UUID?
    public var workflowRunID: UUID?
    public var workflow: WorkflowPresentation?
    public var derivedFrom: RecordID?
    public var supersedes: RecordID?
    public var captureTags: [SystemClipboardCaptureTag]
    public var alternatives: [String]

    public init(
        source: RecordSourceIdentity,
        sourceApplicationName: String? = nil,
        sourceBundleIdentifier: String? = nil,
        workflowID: UUID? = nil,
        workflowRunID: UUID? = nil,
        workflow: WorkflowPresentation? = nil,
        derivedFrom: RecordID? = nil,
        supersedes: RecordID? = nil,
        captureTags: [SystemClipboardCaptureTag] = [],
        alternatives: [String] = []
    ) {
        self.source = source
        self.sourceApplicationName = sourceApplicationName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.workflowID = workflowID
        self.workflowRunID = workflowRunID
        self.workflow = workflow
        self.derivedFrom = derivedFrom
        self.supersedes = supersedes
        self.captureTags = captureTags
        self.alternatives = alternatives
    }
}

public struct Record: Identifiable, Codable, Sendable, Equatable {
    public let id: RecordID
    public let payload: RecordPayload
    public let provenance: RecordProvenance
    public let createdAt: Date

    public init(
        id: RecordID = RecordID(),
        payload: RecordPayload,
        provenance: RecordProvenance,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.payload = payload
        self.provenance = provenance
        self.createdAt = createdAt
    }
}

public struct RecordDraft: Sendable, Equatable {
    public var payload: RecordPayload
    public var provenance: RecordProvenance
    public var createdAt: Date
    public var tags: [String]
    public var isPinned: Bool

    public init(
        payload: RecordPayload,
        provenance: RecordProvenance,
        createdAt: Date = Date(),
        tags: [String] = [],
        isPinned: Bool = false
    ) {
        self.payload = payload
        self.provenance = provenance
        self.createdAt = createdAt
        self.tags = tags
        self.isPinned = isPinned
    }
}

public struct RecordMetadata: Codable, Sendable, Equatable {
    public var recordID: RecordID
    public var tags: [String]
    public var isPinned: Bool
    public var revision: UInt64

    public init(
        recordID: RecordID,
        tags: [String] = [],
        isPinned: Bool = false,
        revision: UInt64 = 1
    ) {
        precondition(revision > 0, "Record metadata revisions start at one.")
        self.recordID = recordID
        self.tags = tags
        self.isPinned = isPinned
        self.revision = revision
    }

    public mutating func advanceRevision() {
        revision = revision == .max ? 1 : revision + 1
    }
}

public enum RecordDeliveryFailureCode: String, Codable, Sendable, Equatable {
    case deliveryFailed = "delivery-failed"

    public static func sanitizedStoredValue(_ value: String?) -> Self? {
        value == nil ? nil : .deliveryFailed
    }
}

public struct RecordActivity: Codable, Sendable, Equatable {
    public var recordID: RecordID
    public var useCount: Int
    public var copyCount: Int
    public var lastDeliveredAt: Date?
    public var latestFailure: RecordDeliveryFailureCode?
    public var revision: UInt64

    public init(
        recordID: RecordID,
        useCount: Int = 0,
        copyCount: Int = 0,
        lastDeliveredAt: Date? = nil,
        latestFailure: RecordDeliveryFailureCode? = nil,
        revision: UInt64 = 1
    ) {
        precondition(useCount >= 0, "Record use counts cannot be negative.")
        precondition(copyCount >= 0, "Record copy counts cannot be negative.")
        precondition(revision > 0, "Record activity revisions start at one.")
        self.recordID = recordID
        self.useCount = useCount
        self.copyCount = copyCount
        self.lastDeliveredAt = lastDeliveredAt
        self.latestFailure = latestFailure
        self.revision = revision
    }

    public mutating func recordDelivery(at date: Date = Date()) {
        useCount += 1
        lastDeliveredAt = date
        latestFailure = nil
        revision = revision == .max ? 1 : revision + 1
    }

    public mutating func recordCopy() {
        copyCount += 1
        revision = revision == .max ? 1 : revision + 1
    }

    private enum CodingKeys: String, CodingKey {
        case recordID
        case useCount
        case copyCount
        case lastDeliveredAt
        case latestFailure
        case revision
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recordID = try container.decode(RecordID.self, forKey: .recordID)
        let useCount = try container.decode(Int.self, forKey: .useCount)
        let copyCount = try container.decodeIfPresent(Int.self, forKey: .copyCount) ?? 0
        let revision = try container.decode(UInt64.self, forKey: .revision)
        guard useCount >= 0, copyCount >= 0, revision > 0 else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: container.codingPath, debugDescription: "Record activity counts are invalid.")
            )
        }
        self.recordID = recordID
        self.useCount = useCount
        self.copyCount = copyCount
        self.lastDeliveredAt = try container.decodeIfPresent(Date.self, forKey: .lastDeliveredAt)
        self.latestFailure = try container.decodeIfPresent(RecordDeliveryFailureCode.self, forKey: .latestFailure)
        self.revision = revision
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recordID, forKey: .recordID)
        try container.encode(useCount, forKey: .useCount)
        try container.encode(copyCount, forKey: .copyCount)
        try container.encodeIfPresent(lastDeliveredAt, forKey: .lastDeliveredAt)
        try container.encodeIfPresent(latestFailure, forKey: .latestFailure)
        try container.encode(revision, forKey: .revision)
    }

    public mutating func recordFailure(_ failure: RecordDeliveryFailureCode) {
        latestFailure = failure
        revision = revision == .max ? 1 : revision + 1
    }
}

public enum RecordSelectionPolicy: String, Codable, Sendable, CaseIterable {
    case newestFirst = "newest-first"
    case oldestFirst = "oldest-first"
    case manual
}

public enum RecordConsumptionPolicy: String, Codable, Sendable, CaseIterable {
    case retain
    case consumeAfterSuccessfulDelivery = "consume-after-successful-delivery"
}

public enum RecordCollectionPreset: String, Codable, Sendable, CaseIterable {
    case stack
    case queue
    case list

    public var selectionPolicy: RecordSelectionPolicy {
        switch self {
        case .stack: .newestFirst
        case .queue: .oldestFirst
        case .list: .manual
        }
    }

    public var consumptionPolicy: RecordConsumptionPolicy {
        switch self {
        case .stack, .queue: .consumeAfterSuccessfulDelivery
        case .list: .retain
        }
    }
}

public struct RecordCollection: Identifiable, Codable, Sendable, Equatable {
    /// These identities intentionally preserve the two historical built-in
    /// groups during forward migration. They confer no reserved privileges.
    public static let inboxID = RecordCollectionID(
        recordStaticUUID("4C5A3D00-90E6-4BA0-95D7-17E8B6DA0001")
    )
    public static let voiceInputID = RecordCollectionID(
        recordStaticUUID("4C5A3D00-90E6-4BA0-95D7-17E8B6DA0002")
    )

    public var id: RecordCollectionID
    public var name: String
    public var selectionPolicy: RecordSelectionPolicy
    public var consumptionPolicy: RecordConsumptionPolicy
    public var createdAt: Date
    public var revision: UInt64

    public init(
        id: RecordCollectionID = RecordCollectionID(),
        name: String,
        selectionPolicy: RecordSelectionPolicy = .newestFirst,
        consumptionPolicy: RecordConsumptionPolicy = .consumeAfterSuccessfulDelivery,
        createdAt: Date = Date(),
        revision: UInt64 = 1
    ) {
        precondition(revision > 0, "Record collection revisions start at one.")
        self.id = id
        self.name = name
        self.selectionPolicy = selectionPolicy
        self.consumptionPolicy = consumptionPolicy
        self.createdAt = createdAt
        self.revision = revision
    }

    public init(
        id: RecordCollectionID = RecordCollectionID(),
        name: String,
        preset: RecordCollectionPreset,
        createdAt: Date = Date(),
        revision: UInt64 = 1
    ) {
        self.init(
            id: id,
            name: name,
            selectionPolicy: preset.selectionPolicy,
            consumptionPolicy: preset.consumptionPolicy,
            createdAt: createdAt,
            revision: revision
        )
    }

    public var matchingPreset: RecordCollectionPreset? {
        RecordCollectionPreset.allCases.first {
            $0.selectionPolicy == selectionPolicy && $0.consumptionPolicy == consumptionPolicy
        }
    }

    public mutating func apply(_ preset: RecordCollectionPreset) {
        selectionPolicy = preset.selectionPolicy
        consumptionPolicy = preset.consumptionPolicy
        revision = revision == .max ? 1 : revision + 1
    }

    public static let inbox = RecordCollection(
        id: inboxID,
        name: "Inbox",
        preset: .stack
    )

    public static let voiceInput = RecordCollection(
        id: voiceInputID,
        name: "Voice Input",
        preset: .stack
    )
}

public enum RecordMembershipState: String, Codable, Sendable {
    case active
    case consumed
}

public struct RecordMembership: Identifiable, Codable, Sendable, Equatable {
    public let id: RecordMembershipID
    public let recordID: RecordID
    public let collectionID: RecordCollectionID
    public let ordinal: UInt64
    public var state: RecordMembershipState
    public var revision: UInt64

    public init(
        id: RecordMembershipID = RecordMembershipID(),
        recordID: RecordID,
        collectionID: RecordCollectionID,
        ordinal: UInt64,
        state: RecordMembershipState = .active,
        revision: UInt64 = 1
    ) {
        precondition(revision > 0, "Record membership revisions start at one.")
        self.id = id
        self.recordID = recordID
        self.collectionID = collectionID
        self.ordinal = ordinal
        self.state = state
        self.revision = revision
    }

    public mutating func setState(_ state: RecordMembershipState) {
        guard self.state != state else { return }
        self.state = state
        revision = revision == .max ? 1 : revision + 1
    }
}

public struct RecordProjection: Identifiable, Sendable, Equatable {
    public var record: Record
    public var metadata: RecordMetadata
    public var activity: RecordActivity
    public var memberships: [RecordMembership]

    public init(
        record: Record,
        metadata: RecordMetadata,
        activity: RecordActivity,
        memberships: [RecordMembership]
    ) {
        self.record = record
        self.metadata = metadata
        self.activity = activity
        self.memberships = memberships
    }

    public var id: RecordID { record.id }
}

public struct RecordCollectionProjection: Identifiable, Sendable, Equatable {
    public var collection: RecordCollection
    public var memberships: [RecordMembership]
    public var recordsByID: [RecordID: Record]

    public init(
        collection: RecordCollection,
        memberships: [RecordMembership],
        recordsByID: [RecordID: Record]
    ) {
        self.collection = collection
        self.memberships = memberships
        self.recordsByID = recordsByID
    }

    public var id: RecordCollectionID { collection.id }
}

/// Exact immutable Record plus Membership CAS coordinate used by previews,
/// replay, Replace, and delivery authorization.
public struct RecordDeliverySubject: Codable, Sendable, Equatable, Hashable {
    public let recordID: RecordID
    public let membershipID: RecordMembershipID
    public let membershipRevision: UInt64
    public let collectionID: RecordCollectionID
    public let payloadKind: RecordPayloadKind
    public let captureTags: [SystemClipboardCaptureTag]

    public init(
        recordID: RecordID,
        membershipID: RecordMembershipID,
        membershipRevision: UInt64,
        collectionID: RecordCollectionID,
        payloadKind: RecordPayloadKind,
        captureTags: [SystemClipboardCaptureTag] = []
    ) {
        self.recordID = recordID
        self.membershipID = membershipID
        self.membershipRevision = membershipRevision
        self.collectionID = collectionID
        self.payloadKind = payloadKind
        self.captureTags = captureTags
    }
}

public struct RecordRouteProjection: Sendable, Equatable {
    public var collection: RecordCollection?
    public var count: Int
    public var previewText: String?
    public var previewSubject: RecordDeliverySubject?
    public var previewPayload: RecordPayload?

    public init(
        collection: RecordCollection? = nil,
        count: Int = 0,
        previewText: String? = nil,
        previewSubject: RecordDeliverySubject? = nil,
        previewPayload: RecordPayload? = nil
    ) {
        self.collection = collection
        self.count = count
        self.previewText = previewText
        self.previewSubject = previewSubject
        self.previewPayload = previewPayload
    }
}

public struct RecordStoreSnapshot: Sendable, Equatable {
    public var revision: UInt64
    public var records: [RecordProjection]
    public var collections: [RecordCollection]
    public var captureRules: [CaptureRouteRule]
    public var deliveryRules: [DeliveryRouteRule]

    public init(
        revision: UInt64,
        records: [RecordProjection],
        collections: [RecordCollection],
        captureRules: [CaptureRouteRule],
        deliveryRules: [DeliveryRouteRule]
    ) {
        self.revision = revision
        self.records = records
        self.collections = collections
        self.captureRules = captureRules
        self.deliveryRules = deliveryRules
    }
}

public struct CaptureRouteMatcher: Codable, Sendable, Equatable {
    public var sourceKinds: Set<RecordSourceKind>
    public var sourceBundleIdentifiers: Set<String>
    public var workflowIDs: Set<UUID>

    public init(
        sourceKinds: Set<RecordSourceKind> = [],
        sourceBundleIdentifiers: Set<String> = [],
        workflowIDs: Set<UUID> = []
    ) {
        self.sourceKinds = sourceKinds
        self.sourceBundleIdentifiers = sourceBundleIdentifiers
        self.workflowIDs = workflowIDs
    }

    public func matches(_ provenance: RecordProvenance) -> Bool {
        (sourceKinds.isEmpty || sourceKinds.contains(provenance.source.kind))
            && (sourceBundleIdentifiers.isEmpty
                || provenance.sourceBundleIdentifier.map(sourceBundleIdentifiers.contains) == true)
            && (workflowIDs.isEmpty || provenance.workflowID.map(workflowIDs.contains) == true)
    }
}

public struct CaptureRouteRule: Identifiable, Codable, Sendable, Equatable {
    public var id: RecordRouteRuleID
    public var matcher: CaptureRouteMatcher
    public var destinationCollectionIDs: [RecordCollectionID]
    public var isEnabled: Bool
    public var createdAt: Date

    public init(
        id: RecordRouteRuleID = RecordRouteRuleID(),
        matcher: CaptureRouteMatcher,
        destinationCollectionIDs: [RecordCollectionID],
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        precondition(destinationCollectionIDs.count <= RecordGraphLimits.maximumRouteCollections)
        self.id = id
        self.matcher = matcher
        self.destinationCollectionIDs = destinationCollectionIDs
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

public struct FocusedApplicationIdentity: Codable, Sendable, Equatable, Hashable {
    public var bundleIdentifier: String?
    public var applicationName: String?

    public init(bundleIdentifier: String? = nil, applicationName: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
    }
}

public struct DeliveryRouteMatcher: Codable, Sendable, Equatable {
    public var targetBundleIdentifiers: Set<String>

    public init(targetBundleIdentifiers: Set<String> = []) {
        self.targetBundleIdentifiers = targetBundleIdentifiers
    }

    public func matches(_ target: FocusedApplicationIdentity) -> Bool {
        targetBundleIdentifiers.isEmpty
            || target.bundleIdentifier.map(targetBundleIdentifiers.contains) == true
    }
}

public enum RecordSinkIdentity: String, Codable, Sendable, CaseIterable {
    case systemClipboard = "system-clipboard"
    case focusedApplication = "focused-application"
    case recordCollection = "record-collection"
}

public struct DeliveryRouteRule: Identifiable, Codable, Sendable, Equatable {
    public var id: RecordRouteRuleID
    public var matcher: DeliveryRouteMatcher
    public var priority: Int
    public var sourceCollectionIDs: [RecordCollectionID]
    public var sink: RecordSinkIdentity
    public var sinkCollectionID: RecordCollectionID?
    public var isEnabled: Bool
    public var createdAt: Date

    public init(
        id: RecordRouteRuleID = RecordRouteRuleID(),
        matcher: DeliveryRouteMatcher,
        priority: Int,
        sourceCollectionIDs: [RecordCollectionID],
        sink: RecordSinkIdentity,
        sinkCollectionID: RecordCollectionID? = nil,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        precondition(sourceCollectionIDs.count <= RecordGraphLimits.maximumRouteCollections)
        self.id = id
        self.matcher = matcher
        self.priority = priority
        self.sourceCollectionIDs = sourceCollectionIDs
        self.sink = sink
        self.sinkCollectionID = sinkCollectionID
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

public enum RecordGraphLimits {
    public static let maximumMembershipsPerRecord = 32
    public static let maximumMemberships = 320_000
    public static let maximumRouteCollections = 32
}

/// Admission limits for the Record graph. These retain the shipped local-storage
/// content budget while expressing it in Record terms: content is counted once
/// even when a Record has several collection memberships.
public struct RecordStorageLimits: Sendable, Equatable {
    public static let productDefault = RecordStorageLimits(
        maximumRecordCount: 10_000,
        maximumActiveRecordCount: 10_000,
        maximumHistoryOnlyRecordCount: 10_000,
        maximumActiveMembershipCountPerCollection: 10_000,
        maximumTextUTF8ByteCount: 1 * 1_024 * 1_024,
        maximumImageByteCount: 32 * 1_024 * 1_024,
        maximumFileURLCount: 128,
        maximumFileURLUTF8ByteCount: 8 * 1_024,
        maximumTotalFileURLUTF8ByteCount: 512 * 1_024,
        maximumTotalPayloadByteCount: 512 * 1_024 * 1_024,
        maximumTagCount: 32,
        maximumTagUTF8ByteCount: 128,
        maximumTotalTagUTF8ByteCount: 4 * 1_024,
        maximumCollectionCount: 258,
        maximumCollectionNameUTF8ByteCount: 1_024,
        maximumCaptureRouteCount: 1_024,
        maximumDeliveryRouteCount: 1_025
    )

    public var maximumRecordCount: Int
    public var maximumActiveRecordCount: Int
    public var maximumHistoryOnlyRecordCount: Int
    public var maximumActiveMembershipCountPerCollection: Int
    public var maximumTextUTF8ByteCount: Int
    public var maximumImageByteCount: Int
    public var maximumFileURLCount: Int
    public var maximumFileURLUTF8ByteCount: Int
    public var maximumTotalFileURLUTF8ByteCount: Int
    public var maximumTotalPayloadByteCount: Int
    public var maximumTagCount: Int
    public var maximumTagUTF8ByteCount: Int
    public var maximumTotalTagUTF8ByteCount: Int
    public var maximumCollectionCount: Int
    public var maximumCollectionNameUTF8ByteCount: Int
    public var maximumCaptureRouteCount: Int
    public var maximumDeliveryRouteCount: Int

    public init(
        maximumRecordCount: Int,
        maximumActiveRecordCount: Int,
        maximumHistoryOnlyRecordCount: Int,
        maximumActiveMembershipCountPerCollection: Int,
        maximumTextUTF8ByteCount: Int,
        maximumImageByteCount: Int,
        maximumFileURLCount: Int,
        maximumFileURLUTF8ByteCount: Int,
        maximumTotalFileURLUTF8ByteCount: Int,
        maximumTotalPayloadByteCount: Int,
        maximumTagCount: Int,
        maximumTagUTF8ByteCount: Int,
        maximumTotalTagUTF8ByteCount: Int,
        maximumCollectionCount: Int,
        maximumCollectionNameUTF8ByteCount: Int,
        maximumCaptureRouteCount: Int,
        maximumDeliveryRouteCount: Int
    ) {
        precondition(maximumRecordCount > 0)
        precondition(maximumActiveRecordCount > 0)
        precondition(maximumHistoryOnlyRecordCount >= 0)
        precondition(maximumActiveMembershipCountPerCollection > 0)
        precondition(maximumTextUTF8ByteCount > 0)
        precondition(maximumImageByteCount > 0)
        precondition(maximumFileURLCount > 0)
        precondition(maximumFileURLUTF8ByteCount > 0)
        precondition(maximumTotalFileURLUTF8ByteCount >= maximumFileURLUTF8ByteCount)
        precondition(maximumTotalPayloadByteCount >= maximumImageByteCount)
        precondition(maximumTagCount >= 0)
        precondition(maximumTagUTF8ByteCount > 0)
        precondition(maximumTotalTagUTF8ByteCount >= maximumTagUTF8ByteCount)
        precondition(maximumCollectionCount >= 2)
        precondition(maximumCollectionNameUTF8ByteCount > 0)
        precondition(maximumCaptureRouteCount >= 0)
        precondition(maximumDeliveryRouteCount >= 0)
        self.maximumRecordCount = maximumRecordCount
        self.maximumActiveRecordCount = maximumActiveRecordCount
        self.maximumHistoryOnlyRecordCount = maximumHistoryOnlyRecordCount
        self.maximumActiveMembershipCountPerCollection = maximumActiveMembershipCountPerCollection
        self.maximumTextUTF8ByteCount = maximumTextUTF8ByteCount
        self.maximumImageByteCount = maximumImageByteCount
        self.maximumFileURLCount = maximumFileURLCount
        self.maximumFileURLUTF8ByteCount = maximumFileURLUTF8ByteCount
        self.maximumTotalFileURLUTF8ByteCount = maximumTotalFileURLUTF8ByteCount
        self.maximumTotalPayloadByteCount = maximumTotalPayloadByteCount
        self.maximumTagCount = maximumTagCount
        self.maximumTagUTF8ByteCount = maximumTagUTF8ByteCount
        self.maximumTotalTagUTF8ByteCount = maximumTotalTagUTF8ByteCount
        self.maximumCollectionCount = maximumCollectionCount
        self.maximumCollectionNameUTF8ByteCount = maximumCollectionNameUTF8ByteCount
        self.maximumCaptureRouteCount = maximumCaptureRouteCount
        self.maximumDeliveryRouteCount = maximumDeliveryRouteCount
    }
}
