import Foundation

private func staticUUID(_ string: String) -> UUID {
    guard let uuid = UUID(uuidString: string) else {
        preconditionFailure("Invalid UUID string: \(string)")
    }
    return uuid
}

public enum ClipboardItemSourceKind: String, Codable, Sendable, Equatable {
    case system
    case voxtypeWorkflow
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

    public var id: UUID
    public var name: String
    public var mode: ClipboardPasteMode
    public var createdAt: Date
    public var isDefault: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        mode: ClipboardPasteMode = .stack,
        createdAt: Date = Date(),
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.createdAt = createdAt
        self.isDefault = isDefault
    }

    public static let defaultGroup = ClipboardGroup(
        id: defaultGroupID,
        name: "Default",
        mode: .stack,
        isDefault: true
    )
}

public struct ClipboardGroupSummary: Identifiable, Codable, Sendable, Equatable {
    public var group: ClipboardGroup
    public var count: Int
    public var previewText: String?
    public var previewItemIDs: [UUID]

    public init(group: ClipboardGroup, count: Int, previewText: String?, previewItemIDs: [UUID] = []) {
        self.group = group
        self.count = count
        self.previewText = previewText
        self.previewItemIDs = previewItemIDs
    }

    public var id: UUID { group.id }
}

public struct ClipboardAppAssignment: Identifiable, Codable, Sendable, Equatable {
    public var bundleIdentifier: String
    public var applicationName: String
    public var groupID: UUID
    public var updatedAt: Date

    public init(
        bundleIdentifier: String,
        applicationName: String,
        groupID: UUID,
        updatedAt: Date = Date()
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.groupID = groupID
        self.updatedAt = updatedAt
    }

    public var id: String { bundleIdentifier }
}

public struct ClipboardHistoryItem: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
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
}

public extension ClipboardHistoryItem {
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

public struct ClipboardStoreSnapshot: Sendable, Equatable {
    public var items: [ClipboardHistoryItem]
    public var groups: [ClipboardGroupSummary]
    public var appAssignments: [ClipboardAppAssignment]

    public init(
        items: [ClipboardHistoryItem],
        groups: [ClipboardGroupSummary],
        appAssignments: [ClipboardAppAssignment]
    ) {
        self.items = items
        self.groups = groups
        self.appAssignments = appAssignments
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

    public init(
        activeGroup: ClipboardGroupSummary,
        count: Int,
        previewText: String?,
        previewCaptureTags: [ClipboardCaptureTag] = [],
        previewContentKind: ClipboardContentKind? = nil,
        previewSnapshot: ClipboardSnapshot? = nil
    ) {
        self.activeGroup = activeGroup
        self.count = count
        self.previewText = previewText
        self.previewCaptureTags = previewCaptureTags
        self.previewContentKind = previewContentKind
        self.previewSnapshot = previewSnapshot
    }
}
