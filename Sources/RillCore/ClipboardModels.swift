import Foundation

private func staticUUID(_ string: String) -> UUID {
    guard let uuid = UUID(uuidString: string) else {
        preconditionFailure("Invalid UUID string: \(string)")
    }
    return uuid
}

public enum ClipboardItemSourceKind: String, Codable, Sendable, Equatable {
    case system
    case rillWorkflow
}

public enum ClipboardCaptureDisposition: String, Codable, Sendable, Equatable {
    case historyOnly
    case historyAndWorkflows
}

public enum ClipboardPasteMode: String, Codable, Sendable, Equatable, CaseIterable {
    case stack
    case queue
    case list
}

public enum ClipboardContentKind: String, Codable, Sendable, Equatable {
    case text
    case image
    case files
}

public struct ClipboardGroup: Identifiable, Codable, Sendable, Equatable {
    public static let defaultGroupID = staticUUID("4C5A3D00-90E6-4BA0-95D7-17E8B6DA0001")
    public static let voiceGroupID = staticUUID("4C5A3D00-90E6-4BA0-95D7-17E8B6DA0002")

    public var id: UUID
    public var name: String
    public var mode: ClipboardPasteMode
    public var allowsCrossGroupPaste: Bool
    public var fallbackPriority: Int?
    public var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case mode
        case allowsCrossGroupPaste
        case fallbackPriority
        case createdAt
    }

    public init(
        id: UUID = UUID(),
        name: String,
        mode: ClipboardPasteMode = .stack,
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

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        mode = try container.decode(ClipboardPasteMode.self, forKey: .mode)
        allowsCrossGroupPaste = try container.decodeIfPresent(Bool.self, forKey: .allowsCrossGroupPaste) ?? false
        fallbackPriority = try container.decodeIfPresent(Int.self, forKey: .fallbackPriority)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(mode, forKey: .mode)
        try container.encode(allowsCrossGroupPaste, forKey: .allowsCrossGroupPaste)
        try container.encodeIfPresent(fallbackPriority, forKey: .fallbackPriority)
        try container.encode(createdAt, forKey: .createdAt)
    }

    public static let defaultGroup = ClipboardGroup(
        id: defaultGroupID,
        name: "Default",
        mode: .stack,
        allowsCrossGroupPaste: false
    )

    public static let voiceGroup = ClipboardGroup(
        id: voiceGroupID,
        name: "语音识别",
        mode: .stack,
        allowsCrossGroupPaste: true
    )
}

public extension ClipboardGroup {
    static let reservedGroupIDs: Set<UUID> = [defaultGroupID, voiceGroupID]

    var usesCrossGroupFallback: Bool {
        allowsCrossGroupPaste
    }

    var isReserved: Bool {
        Self.reservedGroupIDs.contains(id)
    }
}

/// Shared ordering contract for cross-group fallback candidates.
///
/// Explicit positive priorities always precede legacy or invalid missing
/// priorities. Candidate recency, group creation time, and the stable group ID
/// are deterministic tie-breakers only; UI previews and Runtime delivery must
/// call this same comparator so the displayed route cannot disagree with the
/// item that will actually be delivered.
public enum ClipboardFallbackOrdering {
    public static func precedes(
        lhsGroup: ClipboardGroup,
        lhsCandidateCreatedAt: Date,
        rhsGroup: ClipboardGroup,
        rhsCandidateCreatedAt: Date
    ) -> Bool {
        let lhsPriority = positivePriority(lhsGroup.fallbackPriority)
        let rhsPriority = positivePriority(rhsGroup.fallbackPriority)
        switch (lhsPriority, rhsPriority) {
        case let (.some(lhsPriority), .some(rhsPriority))
            where lhsPriority != rhsPriority:
            return lhsPriority < rhsPriority
        case (.some(_), .none):
            return true
        case (.none, .some(_)):
            return false
        case (.some(_), .some(_)), (.none, .none):
            break
        }
        if lhsCandidateCreatedAt != rhsCandidateCreatedAt {
            return lhsCandidateCreatedAt > rhsCandidateCreatedAt
        }
        if lhsGroup.createdAt != rhsGroup.createdAt {
            return lhsGroup.createdAt < rhsGroup.createdAt
        }
        return lhsGroup.id.uuidString < rhsGroup.id.uuidString
    }

    private static func positivePriority(_ priority: Int?) -> Int? {
        priority.flatMap { $0 > 0 ? $0 : nil }
    }
}

public struct ClipboardGroupSummary: Identifiable, Codable, Sendable, Equatable {
    public var group: ClipboardGroup
    public var count: Int
    public var previewText: String?
    public var previewItemIDs: [UUID]
    public var candidateCreatedAt: Date?

    public init(
        group: ClipboardGroup,
        count: Int,
        previewText: String?,
        previewItemIDs: [UUID] = [],
        candidateCreatedAt: Date? = nil
    ) {
        self.group = group
        self.count = count
        self.previewText = previewText
        self.previewItemIDs = previewItemIDs
        self.candidateCreatedAt = candidateCreatedAt
    }

    public var id: UUID { group.id }
}

public struct ClipboardAppAssignment: Identifiable, Codable, Sendable, Equatable {
    public var bundleIdentifier: String
    public var applicationName: String
    public var groupID: UUID?
    public var updatedAt: Date

    public init(
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

    public var id: String { bundleIdentifier }
}

/// Identifies one incarnation and mutation state of a stored clipboard item.
///
/// The generation prevents ABA when an item is deleted and a new item later
/// reuses the same public identifier. The revision changes for every mutation
/// within that generation. This value is persisted only with the protected
/// clipboard state and must not be copied into diagnostics or run receipts.
public struct ClipboardItemVersion: Codable, Sendable, Equatable, Hashable {
    public var generationID: UUID
    public var revision: UInt64

    private enum CodingKeys: String, CodingKey {
        case generationID
        case revision
    }

    public init(generationID: UUID = UUID(), revision: UInt64 = 1) {
        precondition(revision > 0, "Clipboard item revisions start at one.")
        self.generationID = generationID
        self.revision = revision
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generationID = try container.decode(UUID.self, forKey: .generationID)
        revision = try container.decode(UInt64.self, forKey: .revision)
        guard revision > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .revision,
                in: container,
                debugDescription: "Clipboard item revisions start at one."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generationID, forKey: .generationID)
        try container.encode(revision, forKey: .revision)
    }

    /// Advances without wrapping. At the theoretical UInt64 limit, a fresh
    /// generation safely invalidates every subject from the old incarnation.
    public func advanced() -> ClipboardItemVersion {
        guard revision < UInt64.max else {
            return ClipboardItemVersion()
        }
        return ClipboardItemVersion(
            generationID: generationID,
            revision: revision + 1
        )
    }
}

/// The content-free result of an exact source-item replacement attempt.
///
/// Callers must distinguish a missing incarnation from a changed incarnation;
/// neither outcome permits creating or overwriting an item as a fallback.
public enum ClipboardItemReplacementResult: Sendable, Equatable {
    case replaced
    case sourceUnavailable
    case sourceChanged
    case storageRejected(ClipboardStorageRejectionReason)
}

/// The only failure value allowed to cross the clipboard-state persistence boundary.
///
/// Paste implementations may fail with errors that contain file paths, target-app
/// details, provider response bodies, or credentials. Clipboard state is durable and
/// is rendered in the main window, so it must retain only a closed coordinate rather
/// than an arbitrary error description.
public enum ClipboardDeliveryFailureCode: String, Codable, Sendable, Equatable {
    case deliveryFailed = "delivery-failed"

    public static func sanitizedStoredValue(_ value: String?) -> String? {
        value == nil ? nil : Self.deliveryFailed.rawValue
    }
}

public struct ClipboardHistoryItem: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var version: ClipboardItemVersion
    public var groupID: UUID
    public var workflowID: UUID?
    public var workflow: WorkflowPresentation?
    public var contentKind: ClipboardContentKind
    public var text: String
    public var imagePNGData: Data?
    public var fileURLs: [URL]
    public var captureTags: [ClipboardCaptureTag]
    public var alternatives: [String]
    public var createdAt: Date
    public var sourceKind: ClipboardItemSourceKind
    public var sourceApplicationName: String?
    public var sourceBundleIdentifier: String?
    public var latestError: String?
    public var useCount: Int
    public var lastUsedAt: Date?
    public var tags: [String]

    public init(
        id: UUID = UUID(),
        version: ClipboardItemVersion = ClipboardItemVersion(),
        groupID: UUID,
        workflowID: UUID? = nil,
        workflow: WorkflowPresentation? = nil,
        contentKind: ClipboardContentKind = .text,
        text: String,
        imagePNGData: Data? = nil,
        fileURLs: [URL] = [],
        captureTags: [ClipboardCaptureTag] = [],
        alternatives: [String] = [],
        createdAt: Date = Date(),
        sourceKind: ClipboardItemSourceKind,
        sourceApplicationName: String? = nil,
        sourceBundleIdentifier: String? = nil,
        latestError: String? = nil,
        useCount: Int = 0,
        lastUsedAt: Date? = nil,
        tags: [String] = []
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
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        version = try container.decodeIfPresent(ClipboardItemVersion.self, forKey: .version)
            ?? ClipboardItemVersion()
        groupID = try container.decode(UUID.self, forKey: .groupID)
        workflowID = try container.decodeIfPresent(UUID.self, forKey: .workflowID)
        workflow = try container.decodeIfPresent(WorkflowPresentation.self, forKey: .workflow)
        contentKind = try container.decode(ClipboardContentKind.self, forKey: .contentKind)
        text = try container.decode(String.self, forKey: .text)
        imagePNGData = try container.decodeIfPresent(Data.self, forKey: .imagePNGData)
        fileURLs = try container.decodeIfPresent([URL].self, forKey: .fileURLs) ?? []
        captureTags = try container.decodeIfPresent([ClipboardCaptureTag].self, forKey: .captureTags) ?? []
        alternatives = try container.decodeIfPresent([String].self, forKey: .alternatives) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        sourceKind = try container.decode(ClipboardItemSourceKind.self, forKey: .sourceKind)
        sourceApplicationName = try container.decodeIfPresent(String.self, forKey: .sourceApplicationName)
        sourceBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .sourceBundleIdentifier)
        latestError = try container.decodeIfPresent(String.self, forKey: .latestError)
        useCount = try container.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(version, forKey: .version)
        try container.encode(groupID, forKey: .groupID)
        try container.encodeIfPresent(workflowID, forKey: .workflowID)
        try container.encodeIfPresent(workflow, forKey: .workflow)
        try container.encode(contentKind, forKey: .contentKind)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(imagePNGData, forKey: .imagePNGData)
        try container.encode(fileURLs, forKey: .fileURLs)
        try container.encode(captureTags, forKey: .captureTags)
        try container.encode(alternatives, forKey: .alternatives)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(sourceKind, forKey: .sourceKind)
        try container.encodeIfPresent(sourceApplicationName, forKey: .sourceApplicationName)
        try container.encodeIfPresent(sourceBundleIdentifier, forKey: .sourceBundleIdentifier)
        try container.encodeIfPresent(latestError, forKey: .latestError)
        try container.encode(useCount, forKey: .useCount)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try container.encode(tags, forKey: .tags)
    }
}

public extension ClipboardHistoryItem {
    mutating func advanceVersion() {
        version = version.advanced()
    }

    var clipboardSnapshot: ClipboardSnapshot {
        let plainText: String
        switch contentKind {
        case .text:
            plainText = text
        case .image, .files:
            plainText = ""
        }

        return ClipboardSnapshot(
            plainText: plainText,
            imagePNGData: imagePNGData,
            fileURLs: fileURLs,
            changeCount: 0,
            captureTags: captureTags
        )
    }

    var supportsWorkflowReplay: Bool {
        contentKind == .text
    }

    var supportsDirectPaste: Bool {
        switch contentKind {
        case .text:
            return !text.isEmpty
        case .image, .files:
            return imagePNGData != nil || !fileURLs.isEmpty
        }
    }
}

/// Whether the protected clipboard state can be read and safely updated.
///
/// An unavailable state may still accept session-only clipboard mutations, but
/// callers must not imply that those mutations are durable.
public enum ClipboardPersistenceAvailability: Sendable, Equatable {
    case available
    /// Durable clipboard storage was not configured for this process. The
    /// clipboard remains usable for the current session, but nothing is saved.
    case notConfigured
    /// Logical deletion completed, but encrypted database or WAL residue could
    /// not yet be purged. Cleanup is retried before storage opens next time.
    case cleanupPending
    /// The stored row could not be read or validated. It must remain untouched
    /// so a later restart can recover it after storage access is restored.
    case loadUnavailable
    /// The in-memory state is newer than the last confirmed durable write.
    case saveFailed
}

public enum ClipboardPersistenceFlushResult: Sendable, Equatable {
    case persisted
    case notConfigured
    case loadUnavailable
    case saveFailed
}

/// Result of an explicit destructive recovery of an unreadable clipboard row.
///
/// Recovery is deliberately separate from ordinary persistence retries: the
/// protected row is removed only after the user confirms that its saved and
/// session-only clipboard state may be discarded.
public enum ClipboardPersistenceResetResult: Sendable, Equatable {
    case reset
    case resetCleanupPending
    case notRequired
    case notConfigured
    case failed
}

public struct ClipboardStoreSnapshot: Sendable, Equatable {
    public var items: [ClipboardHistoryItem]
    public var groups: [ClipboardGroupSummary]
    public var defaultGroup: ClipboardGroupSummary
    public var appAssignments: [ClipboardAppAssignment]
    public var remainingItemIDs: [UUID]
    public var persistenceAvailability: ClipboardPersistenceAvailability
    public var storageLimits: ClipboardStorageLimits
    public var lastStorageRejection: ClipboardStorageRejectionReason?
    public var storagePressureContext: ClipboardStoragePressureContext?

    public init(
        items: [ClipboardHistoryItem],
        groups: [ClipboardGroupSummary],
        defaultGroup: ClipboardGroupSummary? = nil,
        appAssignments: [ClipboardAppAssignment],
        remainingItemIDs: [UUID]? = nil,
        persistenceAvailability: ClipboardPersistenceAvailability = .available,
        storageLimits: ClipboardStorageLimits = .productDefault,
        lastStorageRejection: ClipboardStorageRejectionReason? = nil,
        storagePressureContext: ClipboardStoragePressureContext? = nil
    ) {
        self.items = items
        self.groups = groups
        self.defaultGroup = defaultGroup ?? Self.makeDefaultGroupSummary(from: items)
        self.appAssignments = appAssignments
        self.remainingItemIDs = remainingItemIDs ?? items.map(\.id)
        self.persistenceAvailability = persistenceAvailability
        self.storageLimits = storageLimits
        self.lastStorageRejection = lastStorageRejection
        self.storagePressureContext = storagePressureContext
    }

    private static func makeDefaultGroupSummary(from items: [ClipboardHistoryItem]) -> ClipboardGroupSummary {
        let defaultItems = items.filter { $0.groupID == ClipboardGroup.defaultGroup.id }
        return ClipboardGroupSummary(
            group: .defaultGroup,
            count: defaultItems.count,
            previewText: defaultItems.first.map { ClipboardTextFormatting.previewText($0.text) },
            previewItemIDs: defaultItems.prefix(3).map(\.id),
            candidateCreatedAt: defaultItems.first?.createdAt
        )
    }
}

public struct ClipboardRouteContext: Sendable, Equatable {
    public var applicationName: String?
    public var bundleIdentifier: String?

    public init(applicationName: String? = nil, bundleIdentifier: String? = nil) {
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct ClipboardRouteSnapshot: Sendable, Equatable {
    public var activeGroup: ClipboardGroupSummary
    public var count: Int
    public var previewText: String?
    public var previewCaptureTags: [ClipboardCaptureTag]
    public var previewContentKind: ClipboardContentKind?
    public var previewSnapshot: ClipboardSnapshot?
    public var previewSubject: ClipboardItemDryRunSubject?

    public init(
        activeGroup: ClipboardGroupSummary,
        count: Int,
        previewText: String?,
        previewCaptureTags: [ClipboardCaptureTag] = [],
        previewContentKind: ClipboardContentKind? = nil,
        previewSnapshot: ClipboardSnapshot? = nil,
        previewSubject: ClipboardItemDryRunSubject? = nil
    ) {
        self.activeGroup = activeGroup
        self.count = count
        self.previewText = previewText
        self.previewCaptureTags = previewCaptureTags
        self.previewContentKind = previewContentKind
        self.previewSnapshot = previewSnapshot
        self.previewSubject = previewSubject
    }
}
