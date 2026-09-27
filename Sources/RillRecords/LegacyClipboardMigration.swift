import CryptoKit
import Foundation
import RillCore

/// The only Runtime boundary allowed to decode the pre-Record clipboard graph.
/// It produces a complete graph in memory; the repository does not delete the
/// legacy rows until the resulting graph and every payload have been validated
/// and committed as one Record graph replacement.
enum LegacyClipboardMigration {
    enum LegacyPasteMode: String, Codable, Sendable, Equatable {
        case stack
        case queue
        case list
    }

    enum LegacyContentKind: String, Codable, Sendable, Equatable {
        case text
        case image
        case files
    }

    enum LegacySourceKind: String, Codable, Sendable, Equatable {
        case system
        case rillWorkflow
    }

    struct LegacyItemVersion: Codable, Sendable, Equatable {
        var generationID: UUID
        var revision: UInt64

        init(generationID: UUID = UUID(), revision: UInt64 = 1) {
            self.generationID = generationID
            self.revision = revision
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            generationID = try container.decode(UUID.self, forKey: .generationID)
            revision = try container.decode(UInt64.self, forKey: .revision)
            guard revision > 0 else { throw RecordStoreError.invalidGraph }
        }

        private enum CodingKeys: String, CodingKey {
            case generationID
            case revision
        }
    }

    struct LegacyGroup: Codable, Sendable, Equatable {
        static let inboxID = UUID(uuidString: "4C5A3D00-90E6-4BA0-95D7-17E8B6DA0001")!
        static let voiceInputID = UUID(uuidString: "4C5A3D00-90E6-4BA0-95D7-17E8B6DA0002")!

        var id: UUID
        var name: String
        var mode: LegacyPasteMode
        var allowsCrossGroupPaste: Bool
        var fallbackPriority: Int?
        var createdAt: Date

        init(
            id: UUID = UUID(),
            name: String,
            mode: LegacyPasteMode = .stack,
            allowsCrossGroupPaste: Bool = false,
            fallbackPriority: Int? = nil,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.name = name
            self.mode = mode
            self.allowsCrossGroupPaste = allowsCrossGroupPaste
            self.fallbackPriority = fallbackPriority
            self.createdAt = createdAt
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            mode = try container.decodeIfPresent(LegacyPasteMode.self, forKey: .mode) ?? .stack
            allowsCrossGroupPaste = try container.decodeIfPresent(
                Bool.self,
                forKey: .allowsCrossGroupPaste
            ) ?? false
            fallbackPriority = try container.decodeIfPresent(Int.self, forKey: .fallbackPriority)
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date.distantPast
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case mode
            case allowsCrossGroupPaste
            case fallbackPriority
            case createdAt
        }

        static let inbox = LegacyGroup(
            id: inboxID,
            name: "Default",
            mode: .stack
        )

        static let voiceInput = LegacyGroup(
            id: voiceInputID,
            name: "语音识别",
            mode: .stack,
            allowsCrossGroupPaste: true
        )

        var usesCrossGroupFallback: Bool { allowsCrossGroupPaste }
    }

    struct LegacyAppAssignment: Codable, Sendable, Equatable {
        var bundleIdentifier: String
        var applicationName: String
        var groupID: UUID?
        var updatedAt: Date

        init(
            bundleIdentifier: String,
            applicationName: String,
            groupID: UUID? = nil,
            updatedAt: Date = Date()
        ) {
            self.bundleIdentifier = bundleIdentifier
            self.applicationName = applicationName
            self.groupID = groupID
            self.updatedAt = updatedAt
        }
    }

    struct LegacyItem: Codable, Sendable, Equatable {
        var id: UUID
        var version: LegacyItemVersion
        var groupID: UUID
        var workflowID: UUID?
        var workflow: WorkflowPresentation?
        var contentKind: LegacyContentKind
        var text: String
        var imagePNGData: Data?
        var fileURLs: [URL]
        var captureTags: [SystemClipboardCaptureTag]
        var alternatives: [String]
        var createdAt: Date
        var sourceKind: LegacySourceKind
        var sourceApplicationName: String?
        var sourceBundleIdentifier: String?
        var latestError: String?
        var useCount: Int
        var lastUsedAt: Date?
        var tags: [String]
        var isPinned: Bool

        init(
            id: UUID = UUID(),
            version: LegacyItemVersion = LegacyItemVersion(),
            groupID: UUID,
            workflowID: UUID? = nil,
            workflow: WorkflowPresentation? = nil,
            contentKind: LegacyContentKind = .text,
            text: String,
            imagePNGData: Data? = nil,
            fileURLs: [URL] = [],
            captureTags: [SystemClipboardCaptureTag] = [],
            alternatives: [String] = [],
            createdAt: Date = Date(),
            sourceKind: LegacySourceKind,
            sourceApplicationName: String? = nil,
            sourceBundleIdentifier: String? = nil,
            latestError: String? = nil,
            useCount: Int = 0,
            lastUsedAt: Date? = nil,
            tags: [String] = [],
            isPinned: Bool = false
        ) {
            self.id = id
            self.version = version
            self.groupID = groupID
            self.workflowID = workflowID
            self.workflow = workflow
            self.contentKind = contentKind
            self.text = text
            self.imagePNGData = imagePNGData
            self.fileURLs = fileURLs
            self.captureTags = captureTags
            self.alternatives = alternatives
            self.createdAt = createdAt
            self.sourceKind = sourceKind
            self.sourceApplicationName = sourceApplicationName
            self.sourceBundleIdentifier = sourceBundleIdentifier
            self.latestError = latestError
            self.useCount = useCount
            self.lastUsedAt = lastUsedAt
            self.tags = tags
            self.isPinned = isPinned
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case version
            case groupID
            case workflowID
            case workflow
            case contentKind
            case text
            case imagePNGData
            case fileURLs
            case captureTags
            case alternatives
            case createdAt
            case sourceKind
            case sourceApplicationName
            case sourceBundleIdentifier
            case latestError
            case useCount
            case lastUsedAt
            case tags
            case isPinned
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            version = try container.decodeIfPresent(LegacyItemVersion.self, forKey: .version)
                ?? LegacyItemVersion()
            groupID = try container.decode(UUID.self, forKey: .groupID)
            workflowID = try container.decodeIfPresent(UUID.self, forKey: .workflowID)
            workflow = try container.decodeIfPresent(WorkflowPresentation.self, forKey: .workflow)
            contentKind = try container.decode(LegacyContentKind.self, forKey: .contentKind)
            text = try container.decode(String.self, forKey: .text)
            imagePNGData = try container.decodeIfPresent(Data.self, forKey: .imagePNGData)
            fileURLs = try container.decodeIfPresent([URL].self, forKey: .fileURLs) ?? []
            captureTags = try container.decodeIfPresent(
                [SystemClipboardCaptureTag].self,
                forKey: .captureTags
            ) ?? []
            alternatives = try container.decodeIfPresent([String].self, forKey: .alternatives) ?? []
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            sourceKind = try container.decode(LegacySourceKind.self, forKey: .sourceKind)
            sourceApplicationName = try container.decodeIfPresent(
                String.self,
                forKey: .sourceApplicationName
            )
            sourceBundleIdentifier = try container.decodeIfPresent(
                String.self,
                forKey: .sourceBundleIdentifier
            )
            latestError = try container.decodeIfPresent(String.self, forKey: .latestError)
            useCount = try container.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
            lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
            tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
            isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        }
    }

    struct MigratedGraph {
        var records: [Record]
        var metadata: [RecordMetadata]
        var activity: [RecordActivity]
        var collections: [RecordCollection]
        var memberships: [RecordMembership]
        var captureRules: [CaptureRouteRule]
        var deliveryRules: [DeliveryRouteRule]
        var nextMembershipOrdinal: UInt64
    }

    private struct LegacyImageBlobReference: Codable {
        var blobID: UUID
        var byteCount: Int
    }

    private struct LegacyItemEntry: Codable {
        var metadata: LegacyItem
        var imageBlob: LegacyImageBlobReference?
    }

    private struct LegacyGroupEntry: Codable {
        var groupID: UUID
        var itemIDs: [UUID]
    }

    private struct LegacyState: Decodable {
        var schemaVersion: Int?
        var items: [LegacyItem]
        var imageBlobReferencesByItemID: [UUID: LegacyImageBlobReference]
        var groups: [LegacyGroup]
        var groupEntries: [LegacyGroupEntry]
        var defaultGroupEntries: [UUID]?
        var defaultGroupMode: LegacyPasteMode?
        var appAssignments: [LegacyAppAssignment]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case items
            case groups
            case groupEntries
            case defaultGroupEntries
            case defaultGroupMode
            case appAssignments
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            guard (schemaVersion ?? 0) <= 8 else {
                throw RecordStoreError.invalidGraph
            }
            if (schemaVersion ?? 0) >= 8 {
                let entries = try container.decode([LegacyItemEntry].self, forKey: .items)
                items = entries.map(\.metadata)
                imageBlobReferencesByItemID = Dictionary(
                    uniqueKeysWithValues: entries.compactMap { entry in
                        entry.imageBlob.map { (entry.metadata.id, $0) }
                    }
                )
            } else {
                items = try container.decode([LegacyItem].self, forKey: .items)
                imageBlobReferencesByItemID = [:]
            }
            groups = try container.decode([LegacyGroup].self, forKey: .groups)
            groupEntries = try container.decode([LegacyGroupEntry].self, forKey: .groupEntries)
            defaultGroupEntries = try container.decodeIfPresent([UUID].self, forKey: .defaultGroupEntries)
            defaultGroupMode = try container.decodeIfPresent(LegacyPasteMode.self, forKey: .defaultGroupMode)
            appAssignments = try container.decode([LegacyAppAssignment].self, forKey: .appAssignments)
        }
    }

    static func decodeAndMigrate(
        metadata: Data,
        imageBlobs: [LegacyRecordGraphImageBlob]
    ) throws -> MigratedGraph {
        var state = try JSONDecoder().decode(LegacyState.self, from: metadata)
        guard state.items.count == Set(state.items.map(\.id)).count,
              state.groups.count == Set(state.groups.map(\.id)).count,
              state.appAssignments.count == Set(state.appAssignments.map(\.bundleIdentifier)).count
        else { throw RecordStoreError.invalidGraph }

        let blobsByItemID = Dictionary(
            uniqueKeysWithValues: imageBlobs.map { ($0.reference.itemID, $0) }
        )
        guard blobsByItemID.count == state.imageBlobReferencesByItemID.count else {
            throw RecordStoreError.invalidGraph
        }
        for index in state.items.indices {
            let itemID = state.items[index].id
            switch (state.imageBlobReferencesByItemID[itemID], blobsByItemID[itemID]) {
            case (nil, nil):
                break
            case (.some(let expected), .some(let blob)):
                guard expected.blobID == blob.reference.blobID,
                      expected.byteCount == blob.reference.byteCount,
                      blob.payload.count == expected.byteCount,
                      state.items[index].imagePNGData == nil
                else { throw RecordStoreError.invalidGraph }
                state.items[index].imagePNGData = blob.payload
            default:
                throw RecordStoreError.invalidGraph
            }
        }

        var legacyGroupsByID = Dictionary(uniqueKeysWithValues: state.groups.map { ($0.id, $0) })
        var legacyInbox = LegacyGroup.inbox
        legacyInbox.mode = state.defaultGroupMode ?? legacyInbox.mode
        legacyGroupsByID[legacyInbox.id] = legacyInbox
        if legacyGroupsByID[LegacyGroup.voiceInput.id] == nil {
            legacyGroupsByID[LegacyGroup.voiceInput.id] = .voiceInput
        }

        let orderedLegacyGroups = [LegacyGroup.inbox.id, LegacyGroup.voiceInput.id]
            + state.groups.map(\.id).filter {
                $0 != LegacyGroup.inbox.id && $0 != LegacyGroup.voiceInput.id
            }
        let collections = try orderedLegacyGroups.map { legacyID -> RecordCollection in
            guard let group = legacyGroupsByID[legacyID] else {
                throw RecordStoreError.invalidGraph
            }
            return RecordCollection(
                id: RecordCollectionID(group.id),
                name: group.id == LegacyGroup.inbox.id
                    ? "Inbox"
                    : (group.id == LegacyGroup.voiceInput.id ? "Voice Input" : group.name),
                preset: preset(group.mode),
                createdAt: group.createdAt
            )
        }
        let collectionIDs = Set(collections.map(\.id))

        let records = try state.items.map { item in
            Record(
                id: RecordID(item.id),
                payload: try payload(item),
                provenance: RecordProvenance(
                    source: RecordSourceIdentity(kind: sourceKind(item.sourceKind)),
                    sourceApplicationName: item.sourceApplicationName,
                    sourceBundleIdentifier: item.sourceBundleIdentifier,
                    workflowID: item.workflowID,
                    workflow: item.workflow,
                    captureTags: item.captureTags,
                    alternatives: item.alternatives
                ),
                createdAt: item.createdAt
            )
        }
        let metadataRows = state.items.map {
            RecordMetadata(recordID: RecordID($0.id), tags: $0.tags, isPinned: $0.isPinned)
        }
        let activityRows = state.items.map {
            RecordActivity(
                recordID: RecordID($0.id),
                useCount: max(0, $0.useCount),
                lastDeliveredAt: $0.lastUsedAt,
                latestFailure: RecordDeliveryFailureCode.sanitizedStoredValue($0.latestError)
            )
        }

        var activeItemIDsByCollectionID: [RecordCollectionID: Set<UUID>] = [:]
        let defaultEntries = state.defaultGroupEntries
            ?? state.groupEntries.first(where: { $0.groupID == LegacyGroup.inbox.id })?.itemIDs
            ?? []
        activeItemIDsByCollectionID[RecordCollection.inboxID] = Set(defaultEntries)
        for entry in state.groupEntries where entry.groupID != LegacyGroup.inbox.id {
            let collectionID = RecordCollectionID(entry.groupID)
            guard collectionIDs.contains(collectionID),
                  activeItemIDsByCollectionID[collectionID] == nil
            else { throw RecordStoreError.invalidGraph }
            activeItemIDsByCollectionID[collectionID] = Set(entry.itemIDs)
        }
        let knownItemIDs = Set(state.items.map(\.id))
        guard activeItemIDsByCollectionID.values.allSatisfy({ $0.isSubset(of: knownItemIDs) }) else {
            throw RecordStoreError.invalidGraph
        }

        let ordinalByItemID = Dictionary(
            uniqueKeysWithValues: state.items
                .sorted {
                    if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
                .enumerated()
                .map { (itemID: $0.element.id, ordinal: UInt64($0.offset + 1)) }
        )
        let memberships = try state.items.map { item -> RecordMembership in
            let collectionID = RecordCollectionID(item.groupID)
            guard collectionIDs.contains(collectionID), let ordinal = ordinalByItemID[item.id] else {
                throw RecordStoreError.invalidGraph
            }
            return RecordMembership(
                id: RecordMembershipID(item.id),
                recordID: RecordID(item.id),
                collectionID: collectionID,
                ordinal: ordinal,
                state: activeItemIDsByCollectionID[collectionID, default: []].contains(item.id)
                    ? .active
                    : .consumed
            )
        }

        let sortedFallbackCollectionIDs = legacyGroupsByID.values
            .filter { $0.usesCrossGroupFallback }
            .sorted {
                let lhs = $0.fallbackPriority.flatMap { $0 > 0 ? $0 : nil } ?? Int.max
                let rhs = $1.fallbackPriority.flatMap { $0 > 0 ? $0 : nil } ?? Int.max
                if lhs != rhs { return lhs < rhs }
                return $0.id.uuidString < $1.id.uuidString
            }
            .map { RecordCollectionID($0.id) }

        var captureRules: [CaptureRouteRule] = []
        var deliveryRules: [DeliveryRouteRule] = []
        for assignment in state.appAssignments.sorted(by: {
            $0.bundleIdentifier < $1.bundleIdentifier
        }) {
            let assignedCollectionID = assignment.groupID.map { RecordCollectionID($0) }
                ?? RecordCollection.inboxID
            guard collectionIDs.contains(assignedCollectionID) else {
                throw RecordStoreError.invalidGraph
            }
            let routeBase = "legacy-app:\(assignment.bundleIdentifier)"
            captureRules.append(
                CaptureRouteRule(
                    id: RecordRouteRuleID(deterministicUUID(routeBase + ":capture")),
                    matcher: CaptureRouteMatcher(
                        sourceBundleIdentifiers: [assignment.bundleIdentifier]
                    ),
                    destinationCollectionIDs: [assignedCollectionID],
                    createdAt: assignment.updatedAt
                )
            )
            let orderedSources = stableUnique([assignedCollectionID] + sortedFallbackCollectionIDs)
            deliveryRules.append(
                DeliveryRouteRule(
                    id: RecordRouteRuleID(deterministicUUID(routeBase + ":delivery")),
                    matcher: DeliveryRouteMatcher(
                        targetBundleIdentifiers: [assignment.bundleIdentifier]
                    ),
                    priority: 100,
                    sourceCollectionIDs: orderedSources,
                    sink: .focusedApplication,
                    createdAt: assignment.updatedAt
                )
            )
        }
        deliveryRules.append(
            DeliveryRouteRule(
                id: RecordRouteRuleID(deterministicUUID("legacy-default-delivery")),
                matcher: DeliveryRouteMatcher(),
                priority: 0,
                sourceCollectionIDs: stableUnique([RecordCollection.inboxID] + sortedFallbackCollectionIDs),
                sink: .focusedApplication,
                createdAt: .distantPast
            )
        )

        guard memberships.count <= RecordGraphLimits.maximumMemberships else {
            throw RecordStoreError.membershipLimitReached
        }
        return MigratedGraph(
            records: records,
            metadata: metadataRows,
            activity: activityRows,
            collections: collections,
            memberships: memberships,
            captureRules: captureRules,
            deliveryRules: deliveryRules,
            nextMembershipOrdinal: UInt64(memberships.count + 1)
        )
    }

    private static func payload(_ item: LegacyItem) throws -> RecordPayload {
        switch item.contentKind {
        case .text: return .text(item.text)
        case .image:
            guard let data = item.imagePNGData, !data.isEmpty else {
                throw RecordStoreError.invalidGraph
            }
            return .image(data)
        case .files:
            guard !item.fileURLs.isEmpty else { throw RecordStoreError.invalidGraph }
            return .files(item.fileURLs)
        }
    }

    private static func sourceKind(_ kind: LegacySourceKind) -> RecordSourceKind {
        switch kind {
        case .system: .systemClipboard
        case .rillWorkflow: .workflow
        }
    }

    private static func preset(_ mode: LegacyPasteMode) -> RecordCollectionPreset {
        switch mode {
        case .stack: .stack
        case .queue: .queue
        case .list: .list
        }
    }

    private static func deterministicUUID(_ value: String) -> UUID {
        let digest = SHA256.hash(data: Data(value.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func stableUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }
}
