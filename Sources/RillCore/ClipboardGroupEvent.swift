import Foundation

// MARK: - Group Event Kinds

public enum ClipboardGroupEventKind: String, Codable, Sendable, Equatable, CaseIterable {
    case itemCreated
    case itemEdited
    case itemRemoved
}

// MARK: - Group Action Kinds

public enum ClipboardGroupActionKind: String, Codable, Sendable, Equatable, CaseIterable {
    case createItem
    case editItem
    case removeItem
}

// MARK: - Group Event Lineage

/// A transient, content-free trace of the workflows that produced an event.
///
/// The path is carried only between the clipboard store and group scheduler. It
/// must not be copied into durable receipts or diagnostics. A fixed hop limit
/// bounds multi-workflow chains, while the visited path prevents a workflow
/// from re-entering the same lineage even before that limit is reached.
public struct ClipboardGroupEventLineage: Codable, Sendable, Equatable {
    public static let maximumHopCount = 8

    public let rootEventID: UUID
    public let workflowPath: [UUID]

    public init(rootEventID: UUID) {
        self.rootEventID = rootEventID
        workflowPath = []
    }

    private init(rootEventID: UUID, workflowPath: [UUID]) {
        self.rootEventID = rootEventID
        self.workflowPath = workflowPath
    }

    public var hopCount: Int {
        workflowPath.count
    }

    public func isValid(for eventID: UUID) -> Bool {
        !workflowPath.isEmpty || rootEventID == eventID
    }

    public func advancing(
        through workflowID: UUID
    ) -> ClipboardGroupEventLineageAdvanceResult {
        guard !workflowPath.contains(workflowID) else {
            return .workflowAlreadyVisited
        }
        guard workflowPath.count < Self.maximumHopCount else {
            return .hopLimitReached
        }
        return .advanced(
            ClipboardGroupEventLineage(
                rootEventID: rootEventID,
                workflowPath: workflowPath + [workflowID]
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case rootEventID
        case workflowPath
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rootEventID = try container.decode(UUID.self, forKey: .rootEventID)
        let workflowPath = try container.decode([UUID].self, forKey: .workflowPath)
        guard workflowPath.count <= Self.maximumHopCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .workflowPath,
                in: container,
                debugDescription: "Clipboard group lineage exceeds its hop limit."
            )
        }
        guard Set(workflowPath).count == workflowPath.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .workflowPath,
                in: container,
                debugDescription: "Clipboard group lineage repeats a workflow."
            )
        }
        self.init(rootEventID: rootEventID, workflowPath: workflowPath)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rootEventID, forKey: .rootEventID)
        try container.encode(workflowPath, forKey: .workflowPath)
    }
}

public enum ClipboardGroupEventLineageAdvanceResult: Sendable, Equatable {
    case advanced(ClipboardGroupEventLineage)
    case workflowAlreadyVisited
    case hopLimitReached

    public var permitsExecution: Bool {
        if case .advanced = self { return true }
        return false
    }
}

// MARK: - Group Event Payload

/// The content-free portion of a clipboard group event.
///
/// Runtime scheduling uses this descriptor instead of a clipboard history item,
/// which may contain text, images, file paths, or application metadata. The
/// descriptor itself is transient: durable diagnostics must further reduce it
/// to fixed classifications and must not persist its group/item identifiers or
/// exact timestamp.
public struct ClipboardGroupEventDescriptor: Identifiable, Codable, Sendable, Equatable {
    public var eventID: UUID
    public var kind: ClipboardGroupEventKind
    public var groupID: UUID
    public var itemID: UUID
    public var itemVersion: ClipboardItemVersion?
    public var storeRevision: UInt64
    public var captureTags: [ClipboardCaptureTag]?
    public var lineage: ClipboardGroupEventLineage
    public var timestamp: Date

    public var id: UUID { eventID }

    public init(
        eventID: UUID = UUID(),
        kind: ClipboardGroupEventKind,
        groupID: UUID,
        itemID: UUID,
        itemVersion: ClipboardItemVersion? = nil,
        storeRevision: UInt64 = 0,
        captureTags: [ClipboardCaptureTag]? = nil,
        lineage: ClipboardGroupEventLineage? = nil,
        timestamp: Date = Date()
    ) {
        self.eventID = eventID
        self.kind = kind
        self.groupID = groupID
        self.itemID = itemID
        self.itemVersion = itemVersion
        self.storeRevision = storeRevision
        self.captureTags = captureTags
        self.lineage = lineage ?? ClipboardGroupEventLineage(rootEventID: eventID)
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case eventID
        case kind
        case groupID
        case itemID
        case itemVersion
        case storeRevision
        case captureTags
        case lineage
        case timestamp
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try container.decode(UUID.self, forKey: .eventID)
        kind = try container.decode(ClipboardGroupEventKind.self, forKey: .kind)
        groupID = try container.decode(UUID.self, forKey: .groupID)
        itemID = try container.decode(UUID.self, forKey: .itemID)
        itemVersion = try container.decodeIfPresent(
            ClipboardItemVersion.self,
            forKey: .itemVersion
        )
        storeRevision = try container.decodeIfPresent(UInt64.self, forKey: .storeRevision) ?? 0
        captureTags = try container.decodeIfPresent(
            [ClipboardCaptureTag].self,
            forKey: .captureTags
        )
        lineage = try container.decodeIfPresent(
            ClipboardGroupEventLineage.self,
            forKey: .lineage
        ) ?? ClipboardGroupEventLineage(rootEventID: eventID)
        guard lineage.isValid(for: eventID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .lineage,
                in: container,
                debugDescription: "A root clipboard group lineage must match its event."
            )
        }
        timestamp = try container.decode(Date.self, forKey: .timestamp)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(kind, forKey: .kind)
        try container.encode(groupID, forKey: .groupID)
        try container.encode(itemID, forKey: .itemID)
        try container.encodeIfPresent(itemVersion, forKey: .itemVersion)
        try container.encode(storeRevision, forKey: .storeRevision)
        try container.encodeIfPresent(captureTags, forKey: .captureTags)
        try container.encode(lineage, forKey: .lineage)
        try container.encode(timestamp, forKey: .timestamp)
    }
}

// MARK: - Trigger Condition

public enum ClipboardGroupTriggerCondition: Codable, Sendable, Equatable {
    case always
    case excludingTag(ClipboardCaptureTag)
    case matchingGroup(UUID)
}

extension ClipboardGroupTriggerCondition {
    public func evaluate(descriptor: ClipboardGroupEventDescriptor) -> Bool {
        switch self {
        case .always:
            return true
        case .excludingTag(let tag):
            guard let captureTags = descriptor.captureTags else { return false }
            return !captureTags.contains(tag)
        case .matchingGroup(let groupID):
            return descriptor.groupID == groupID
        }
    }

    func skipReason(
        for descriptor: ClipboardGroupEventDescriptor
    ) -> ClipboardGroupTriggerSkipReason {
        switch self {
        case .always:
            return .conditionFailed
        case .excludingTag(let tag):
            guard let captureTags = descriptor.captureTags else { return .itemMissing }
            if tag == .polishGenerated, captureTags.contains(.polishGenerated) {
                return .loopPrevented
            }
            return .excludedByCaptureTag
        case .matchingGroup:
            return .conditionFailed
        }
    }
}

// MARK: - Group Trigger Match Result

public enum ClipboardGroupTriggerSkipReason: String, Codable, Sendable, Equatable, CaseIterable {
    case eventKindMismatch
    case sourceGroupMismatch
    case excludedByCaptureTag
    case conditionFailed
    case itemMissing
    case loopPrevented

    public var workflowRunSkipCode: WorkflowRunSkipCode {
        switch self {
        case .eventKindMismatch:
            return .eventKindMismatch
        case .sourceGroupMismatch:
            return .sourceGroupMismatch
        case .excludedByCaptureTag:
            return .excludedByCaptureTag
        case .conditionFailed:
            return .conditionFailed
        case .itemMissing:
            return .itemMissing
        case .loopPrevented:
            return .loopPrevented
        }
    }
}

public struct ClipboardGroupTriggerMatchResult: Codable, Sendable, Equatable {
    public var matched: Bool
    public var skipReason: ClipboardGroupTriggerSkipReason?
    public var failedConditionIndex: Int?

    public init(
        matched: Bool,
        skipReason: ClipboardGroupTriggerSkipReason? = nil,
        failedConditionIndex: Int? = nil
    ) {
        self.matched = matched
        self.skipReason = skipReason
        self.failedConditionIndex = failedConditionIndex
    }

    public static let matched = ClipboardGroupTriggerMatchResult(matched: true)

    public static func skipped(
        _ reason: ClipboardGroupTriggerSkipReason,
        failedConditionIndex: Int? = nil
    ) -> ClipboardGroupTriggerMatchResult {
        ClipboardGroupTriggerMatchResult(
            matched: false,
            skipReason: reason,
            failedConditionIndex: failedConditionIndex
        )
    }
}

// MARK: - Group Trigger Rule

/// The content-free matching policy for one clipboard group automation.
public struct ClipboardGroupTriggerRule: Codable, Sendable, Equatable {
    public var eventKind: ClipboardGroupEventKind
    public var sourceGroupID: UUID?
    public var conditions: [ClipboardGroupTriggerCondition]

    public init(
        eventKind: ClipboardGroupEventKind,
        sourceGroupID: UUID? = nil,
        conditions: [ClipboardGroupTriggerCondition] = []
    ) {
        self.eventKind = eventKind
        self.sourceGroupID = sourceGroupID
        self.conditions = conditions
    }

    public func matches(descriptor: ClipboardGroupEventDescriptor) -> Bool {
        matchResult(for: descriptor).matched
    }

    public func matchResult(
        for descriptor: ClipboardGroupEventDescriptor
    ) -> ClipboardGroupTriggerMatchResult {
        guard descriptor.kind == eventKind else {
            return .skipped(.eventKindMismatch)
        }
        if let sourceGroupID, descriptor.groupID != sourceGroupID {
            return .skipped(.sourceGroupMismatch)
        }
        for (index, condition) in conditions.enumerated()
            where !condition.evaluate(descriptor: descriptor) {
            return .skipped(
                condition.skipReason(for: descriptor),
                failedConditionIndex: index
            )
        }
        return .matched
    }
}

// MARK: - Group Trigger Definition

public struct ClipboardGroupTrigger: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var eventKind: ClipboardGroupEventKind
    public var sourceGroupID: UUID?
    public var conditions: [ClipboardGroupTriggerCondition]
    public var actionKind: ClipboardGroupActionKind
    public var actionConfiguration: [String: String]

    public init(
        id: UUID = UUID(),
        name: String,
        eventKind: ClipboardGroupEventKind,
        sourceGroupID: UUID? = nil,
        conditions: [ClipboardGroupTriggerCondition] = [],
        actionKind: ClipboardGroupActionKind,
        actionConfiguration: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.eventKind = eventKind
        self.sourceGroupID = sourceGroupID
        self.conditions = conditions
        self.actionKind = actionKind
        self.actionConfiguration = actionConfiguration
    }

    public func matches(descriptor: ClipboardGroupEventDescriptor) -> Bool {
        rule.matches(descriptor: descriptor)
    }

    public func matchResult(
        for descriptor: ClipboardGroupEventDescriptor
    ) -> ClipboardGroupTriggerMatchResult {
        rule.matchResult(for: descriptor)
    }

    public var rule: ClipboardGroupTriggerRule {
        ClipboardGroupTriggerRule(
            eventKind: eventKind,
            sourceGroupID: sourceGroupID,
            conditions: conditions
        )
    }
}

// MARK: - Builtin Trigger: Voice Group Polish

public extension ClipboardGroupTrigger {
    static let voiceGroupPolish = ClipboardGroupTrigger(
        name: "Voice Group Auto-Polish",
        eventKind: .itemCreated,
        sourceGroupID: ClipboardGroup.voiceGroupID,
        conditions: [
            .excludingTag(.polishGenerated)
        ],
        actionKind: .editItem,
        actionConfiguration: [
            "action": "llmRewrite",
            "prompt": "Polish into a concise final message while preserving meaning and language."
        ]
    )
}
