import Foundation
import RillCore

public struct ClipboardCleanupResult: Sendable, Equatable {
    public let removedCount: Int
    public let preservedActiveCount: Int

    public init(removedCount: Int, preservedActiveCount: Int) {
        self.removedCount = removedCount
        self.preservedActiveCount = preservedActiveCount
    }
}

public enum ClipboardHistoryMaintenanceError: Error, LocalizedError, Sendable, Equatable {
    case persistenceUnavailable

    public var errorDescription: String? {
        switch self {
        case .persistenceUnavailable:
            return "Protected clipboard history is unavailable. No stored history was changed."
        }
    }
}

/// A one-shot claim over the exact clipboard item selected by the user.
///
/// The payload is exposed only after DeliveryStack atomically validates the
/// generation, revision, group, kind, capture tags and content availability.
/// Completion or failure consumes the lease and advances the stored version.
public struct ClipboardItemUseLease: Sendable, Equatable {
    public let leaseID: UUID
    public let item: ClipboardHistoryItem

    init(leaseID: UUID, item: ClipboardHistoryItem) {
        self.leaseID = leaseID
        self.item = item
    }
}

public enum ClipboardItemUseLeaseError: Error, LocalizedError, Sendable, Equatable {
    case sourceUnavailable
    case sourceChanged
    case alreadyInUse

    public var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            return "The selected clipboard item is no longer available."
        case .sourceChanged:
            return "The selected clipboard item changed before it could be used."
        case .alreadyInUse:
            return "The selected clipboard item is already being used."
        }
    }
}

public actor DeliveryStack: DeliveryStackSink, ClipboardCaptureSink {
    struct DeliveryLease: Sendable {
        let id: UUID
        let itemID: UUID
        let groupID: UUID
        let consumesItem: Bool
    }

    struct PersistedClipboardState: Codable {
        static let currentSchemaVersion = 8

        struct GroupEntry: Codable {
            var groupID: UUID
            var itemIDs: [UUID]
        }

        struct ImageBlobReference: Codable, Sendable, Equatable, Hashable {
            var blobID: UUID
            var byteCount: Int

            private enum CodingKeys: String, CodingKey {
                case blobID
                case byteCount
            }

            init(blobID: UUID = UUID(), byteCount: Int) {
                precondition(byteCount >= 0, "Clipboard image blob sizes cannot be negative.")
                self.blobID = blobID
                self.byteCount = byteCount
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                blobID = try container.decode(UUID.self, forKey: .blobID)
                byteCount = try container.decode(Int.self, forKey: .byteCount)
                guard byteCount > 0 else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .byteCount,
                        in: container,
                        debugDescription: "Clipboard image blobs must contain bytes."
                    )
                }
            }
        }

        struct ItemEntry: Codable {
            var metadata: ClipboardHistoryItem
            var imageBlob: ImageBlobReference?

            private enum CodingKeys: String, CodingKey {
                case metadata
                case imageBlob
            }

            private enum MetadataCodingKeys: String, CodingKey {
                case version
            }

            init(item: ClipboardHistoryItem, imageBlob: ImageBlobReference?) {
                var metadata = item
                metadata.imagePNGData = nil
                self.metadata = metadata
                self.imageBlob = imageBlob
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let metadataDecoder = try container.superDecoder(forKey: .metadata)
                let metadataContainer = try metadataDecoder.container(
                    keyedBy: MetadataCodingKeys.self
                )
                guard metadataContainer.contains(.version),
                      !(try metadataContainer.decodeNil(forKey: .version)) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .metadata,
                        in: container,
                        debugDescription: "Clipboard schema 8 requires an exact item version."
                    )
                }
                metadata = try ClipboardHistoryItem(from: metadataDecoder)
                imageBlob = try container.decodeIfPresent(
                    ImageBlobReference.self,
                    forKey: .imageBlob
                )
            }
        }

        var schemaVersion: Int?
        var items: [ClipboardHistoryItem]
        var imageBlobReferencesByItemID: [UUID: ImageBlobReference]
        var groups: [ClipboardGroup]
        var groupEntries: [GroupEntry]
        var defaultGroupEntries: [UUID]?
        var defaultGroupMode: ClipboardPasteMode?
        var appAssignments: [ClipboardAppAssignment]

        init(
            schemaVersion: Int?,
            items: [ClipboardHistoryItem],
            imageBlobReferencesByItemID: [UUID: ImageBlobReference] = [:],
            groups: [ClipboardGroup],
            groupEntries: [GroupEntry],
            defaultGroupEntries: [UUID]?,
            defaultGroupMode: ClipboardPasteMode?,
            appAssignments: [ClipboardAppAssignment]
        ) {
            self.schemaVersion = schemaVersion
            self.items = items
            self.imageBlobReferencesByItemID = imageBlobReferencesByItemID
            self.groups = groups
            self.groupEntries = groupEntries
            self.defaultGroupEntries = defaultGroupEntries
            self.defaultGroupMode = defaultGroupMode
            self.appAssignments = appAssignments
        }
    }

    static let groupPreviewItemLimit = 3
    static let persistenceDebounceInterval = Duration.milliseconds(250)

    var historyIDs: [UUID] = []
    var itemsByID: [UUID: ClipboardHistoryItem] = [:]
    var encodedItemByteCountsByID: [UUID: Int] = [:]
    /// Legacy rows can contain shapes that predate raw item budgets. Keep their
    /// identity separate from ordinary byte accounting so no code path needs to
    /// encode them merely to discover their size, and so multiple unknown sizes
    /// cannot be collapsed by `Int.max - Int.max` arithmetic.
    var rawOversizedLegacyItemIDs: Set<UUID> = []
    var groupsByID: [UUID: ClipboardGroup] = [
        ClipboardGroup.defaultGroup.id: .defaultGroup,
        ClipboardGroup.voiceGroup.id: .voiceGroup,
    ]
    var groupOrder: [UUID] = [ClipboardGroup.defaultGroup.id, ClipboardGroup.voiceGroup.id]
    var groupEntries: [UUID: [UUID]] = [
        ClipboardGroup.defaultGroup.id: [],
        ClipboardGroup.voiceGroup.id: [],
    ]
    var appAssignments: [String: ClipboardAppAssignment] = [:]
    var pendingLeases: [UUID: DeliveryLease] = [:]
    var compatibilityLeaseIDsByItemID: [UUID: UUID] = [:]
    var pendingPersistenceTask: Task<Void, Never>?
    var pendingPersistenceGeneration: UInt64 = 0
    var stateRevision: UInt64 = 0
    var isHistoryMaintenanceActive = false
    var isPersistenceResetActive = false
    var historyMaintenanceWaiters: [CheckedContinuation<Void, Never>] = []
    var isInitialized = false
    var pendingContinuations: [CheckedContinuation<Void, Never>] = []
    var pendingGroupEvents: [ClipboardGroupEventDescriptor] = []
    var pendingGroupEventDescriptors: [ClipboardGroupEventDescriptor] = []
    var clipboardGroupEventSink: (any ClipboardGroupEventSink)?
    var clipboardGroupEventSinkDetachWaiters: [CheckedContinuation<Void, Never>] = []
    var publicationTailTask: Task<Void, Never>?
    var publicationGeneration: UInt64 = 0
    var lastCapturedPublicationRevision: UInt64 = 0
    var publicationRevisionWaiters: [(
        revision: UInt64,
        continuation: CheckedContinuation<Void, Never>
    )] = []
    var persistenceAvailability: ClipboardPersistenceAvailability = .available
    var isPersistenceCleanupPending = false
    var hasPendingPersistence = false
    var persistenceRetryAttempt = 0
    var lastStorageRejection: ClipboardStorageRejectionReason?
    var storagePressureContext: ClipboardStoragePressureContext?
    var hasLegacyOverCapacityState = false
    var hasPersistedStateCapacityRejection = false

    /// The actor is the sole owner of the logical clipboard graph and its
    /// durable CAS coordinate. The repository owns only encryption and the
    /// atomic SQLite representation.
    var repositoryRevision: Int64?
    var blobReferencesByItemID: [UUID: PersistedClipboardState.ImageBlobReference] = [:]
    var persistedBlobIDs: Set<UUID> = []

    let eventBus: EventBus
    let diagnostics: DiagnosticsRecorder?
    let clipboardPersistenceStore: (any ClipboardPersistenceStore)?
    let persistenceRetryDelays: [Duration]
    let persistenceSleep: @Sendable (Duration) async throws -> Void
    let storageLimits: ClipboardStorageLimits
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    public init(
        eventBus: EventBus,
        diagnostics: DiagnosticsRecorder? = nil,
        clipboardPersistenceStore: (any ClipboardPersistenceStore)? = nil,
        clipboardGroupEventSink: (any ClipboardGroupEventSink)? = nil,
        persistenceRetryDelays: [Duration] = [
            .milliseconds(500),
            .seconds(1),
            .seconds(2),
            .seconds(4),
            .seconds(8),
        ],
        persistenceSleep: @escaping @Sendable (Duration) async throws -> Void = { delay in
            try await Task.sleep(for: delay)
        },
        storageLimits: ClipboardStorageLimits = .productDefault
    ) {
        self.eventBus = eventBus
        self.diagnostics = diagnostics
        self.clipboardPersistenceStore = clipboardPersistenceStore
        self.clipboardGroupEventSink = clipboardGroupEventSink
        self.persistenceRetryDelays = persistenceRetryDelays.isEmpty
            ? [.seconds(1)]
            : persistenceRetryDelays
        self.persistenceSleep = persistenceSleep
        self.storageLimits = storageLimits

        if clipboardPersistenceStore != nil {
            Task {
                await self.loadPersistedState()
                await self.markInitialized()
            }
        } else {
            persistenceAvailability = .notConfigured
            isInitialized = true
        }
    }

    func ensureInitialized() async {
        if isInitialized { return }
        await withCheckedContinuation { continuation in
            pendingContinuations.append(continuation)
        }
    }

    func markInitialized() {
        isInitialized = true
        for continuation in pendingContinuations {
            continuation.resume()
        }
        pendingContinuations.removeAll()
    }

    /// Detaches the observer and waits for every publication that captured it.
    /// Callers may shut the scheduler down after this write barrier returns.
    public func removeClipboardGroupEventSink() async {
        clipboardGroupEventSink = nil
        let detachWaiters = clipboardGroupEventSinkDetachWaiters
        clipboardGroupEventSinkDetachWaiters.removeAll()
        for waiter in detachWaiters {
            waiter.resume()
        }

        let capturedPublicationTail = publicationTailTask
        if let capturedPublicationTail {
            await capturedPublicationTail.value
        }
    }

    func waitUntilClipboardGroupEventSinkDetachedForTesting() async {
        guard clipboardGroupEventSink != nil else { return }
        await withCheckedContinuation { continuation in
            clipboardGroupEventSinkDetachWaiters.append(continuation)
        }
    }

    func waitUntilPublicationRevisionForTesting(_ revision: UInt64) async {
        guard lastCapturedPublicationRevision < revision else { return }
        await withCheckedContinuation { continuation in
            publicationRevisionWaiters.append((revision, continuation))
        }
    }

}

extension DeliveryStack.PersistedClipboardState {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case items
        case groups
        case groupEntries
        case defaultGroupEntries
        case defaultGroupMode
        case appAssignments
    }

    private struct DecodedItem: Decodable {
        let item: ClipboardHistoryItem
        let hasExactVersion: Bool

        private enum CodingKeys: String, CodingKey {
            case version
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.version) {
                hasExactVersion = !(try container.decodeNil(forKey: .version))
            } else {
                hasExactVersion = false
            }
            item = try ClipboardHistoryItem(from: decoder)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        if let schemaVersion, schemaVersion > Self.currentSchemaVersion {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported future clipboard-state schema."
            )
        }
        if (schemaVersion ?? 0) >= Self.currentSchemaVersion {
            let entries = try container.decode([ItemEntry].self, forKey: .items)
            guard entries.allSatisfy({ $0.metadata.imagePNGData == nil }) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .items,
                    in: container,
                    debugDescription: "Clipboard schema 8 stores image bytes outside metadata."
                )
            }
            items = entries.map(\.metadata)
            var references: [UUID: ImageBlobReference] = [:]
            var blobIDs: Set<UUID> = []
            for entry in entries {
                guard let reference = entry.imageBlob else { continue }
                guard references[entry.metadata.id] == nil,
                      blobIDs.insert(reference.blobID).inserted else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .items,
                        in: container,
                        debugDescription: "Clipboard schema 8 contains duplicate image references."
                    )
                }
                references[entry.metadata.id] = reference
            }
            imageBlobReferencesByItemID = references
        } else {
            let decodedItems = try container.decode([DecodedItem].self, forKey: .items)
            if (schemaVersion ?? 0) >= 7,
               decodedItems.contains(where: { !$0.hasExactVersion }) {
                throw DecodingError.dataCorruptedError(
                    forKey: .items,
                    in: container,
                    debugDescription: "Clipboard schema 7 requires an exact version for every item."
                )
            }
            items = decodedItems.map(\.item)
            imageBlobReferencesByItemID = [:]
        }
        groups = try container.decode([ClipboardGroup].self, forKey: .groups)
        groupEntries = try container.decode([GroupEntry].self, forKey: .groupEntries)
        defaultGroupEntries = try container.decodeIfPresent([UUID].self, forKey: .defaultGroupEntries)
        defaultGroupMode = try container.decodeIfPresent(ClipboardPasteMode.self, forKey: .defaultGroupMode)
        appAssignments = try container.decode([ClipboardAppAssignment].self, forKey: .appAssignments)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(schemaVersion, forKey: .schemaVersion)
        if (schemaVersion ?? 0) >= Self.currentSchemaVersion {
            let entries = try items.map { item in
                let reference = imageBlobReferencesByItemID[item.id]
                guard (item.imagePNGData == nil) == (reference == nil) else {
                    throw EncodingError.invalidValue(
                        item.id,
                        EncodingError.Context(
                            codingPath: container.codingPath + [CodingKeys.items],
                            debugDescription: "Clipboard image bytes and blob references must have one owner."
                        )
                    )
                }
                if let reference,
                   reference.byteCount != item.imagePNGData?.count {
                    throw EncodingError.invalidValue(
                        item.id,
                        EncodingError.Context(
                            codingPath: container.codingPath + [CodingKeys.items],
                            debugDescription: "Clipboard image blob size does not match its payload."
                        )
                    )
                }
                return ItemEntry(item: item, imageBlob: reference)
            }
            try container.encode(entries, forKey: .items)
        } else {
            try container.encode(items, forKey: .items)
        }
        try container.encode(groups, forKey: .groups)
        try container.encode(groupEntries, forKey: .groupEntries)
        try container.encodeIfPresent(defaultGroupEntries, forKey: .defaultGroupEntries)
        try container.encodeIfPresent(defaultGroupMode, forKey: .defaultGroupMode)
        try container.encode(appAssignments, forKey: .appAssignments)
    }
}
