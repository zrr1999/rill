import Foundation

// MARK: - Record Collection Event Kinds

public enum RecordCollectionEventKind: String, Codable, Sendable, Equatable, CaseIterable {
    case recordCreated
    case recordEdited
    case recordRemoved

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        let canonicalValue = switch value {
        case "itemCreated": "recordCreated"
        case "itemEdited": "recordEdited"
        case "itemRemoved": "recordRemoved"
        default: value
        }
        guard let kind = Self(rawValue: canonicalValue) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown record collection event kind."
            )
        }
        self = kind
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Record Collection Action Kinds

public enum RecordCollectionActionKind: String, Codable, Sendable, Equatable, CaseIterable {
    case createRecord
    case editRecord
    case removeRecord

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        let canonicalValue = switch value {
        case "createItem": "createRecord"
        case "editItem": "editRecord"
        case "removeItem": "removeRecord"
        default: value
        }
        guard let kind = Self(rawValue: canonicalValue) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown record collection action kind."
            )
        }
        self = kind
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Record Collection Event Lineage

/// A transient, content-free trace of the workflows that produced an event.
///
/// The path is carried only between the RecordStore and collection event coordinator. It
/// must not be copied into durable receipts or diagnostics. A fixed hop limit
/// bounds multi-workflow chains, while the visited path prevents a workflow
/// from re-entering the same lineage even before that limit is reached.
public struct RecordCollectionEventLineage: Codable, Sendable, Equatable {
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
    ) -> RecordCollectionEventLineageAdvanceResult {
        guard !workflowPath.contains(workflowID) else {
            return .workflowAlreadyVisited
        }
        guard workflowPath.count < Self.maximumHopCount else {
            return .hopLimitReached
        }
        return .advanced(
            RecordCollectionEventLineage(
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
                debugDescription: "Record collection lineage exceeds its hop limit."
            )
        }
        guard Set(workflowPath).count == workflowPath.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .workflowPath,
                in: container,
                debugDescription: "Record collection lineage repeats a workflow."
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

public enum RecordCollectionEventLineageAdvanceResult: Sendable, Equatable {
    case advanced(RecordCollectionEventLineage)
    case workflowAlreadyVisited
    case hopLimitReached

    public var permitsExecution: Bool {
        if case .advanced = self { return true }
        return false
    }
}

// MARK: - Record Collection Event Payload

/// The content-free portion of a record collection event.
///
/// Runtime scheduling uses this descriptor instead of a complete Record payload,
/// which may contain text, images, file paths, or application metadata. The
/// descriptor itself is transient: durable diagnostics must further reduce it
/// to fixed classifications and must not persist its collection/record identifiers or
/// exact timestamp.
public struct RecordCollectionEventDescriptor: Identifiable, Codable, Sendable, Equatable {
    public var eventID: UUID
    public var kind: RecordCollectionEventKind
    public var collectionID: RecordCollectionID
    public var recordID: RecordID
    public var membershipID: RecordMembershipID
    public var membershipRevision: UInt64
    public var storeRevision: UInt64
    public var captureTags: [SystemClipboardCaptureTag]?
    public var lineage: RecordCollectionEventLineage
    public var timestamp: Date

    public var id: UUID { eventID }

    public init(
        eventID: UUID = UUID(),
        kind: RecordCollectionEventKind,
        collectionID: RecordCollectionID,
        recordID: RecordID,
        membershipID: RecordMembershipID,
        membershipRevision: UInt64,
        storeRevision: UInt64 = 0,
        captureTags: [SystemClipboardCaptureTag]? = nil,
        lineage: RecordCollectionEventLineage? = nil,
        timestamp: Date = Date()
    ) {
        self.eventID = eventID
        self.kind = kind
        self.collectionID = collectionID
        self.recordID = recordID
        self.membershipID = membershipID
        self.membershipRevision = membershipRevision
        self.storeRevision = storeRevision
        self.captureTags = captureTags
        self.lineage = lineage ?? RecordCollectionEventLineage(rootEventID: eventID)
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case eventID
        case kind
        case collectionID
        case recordID
        case membershipID
        case membershipRevision
        case storeRevision
        case captureTags
        case lineage
        case timestamp
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try container.decode(UUID.self, forKey: .eventID)
        kind = try container.decode(RecordCollectionEventKind.self, forKey: .kind)
        collectionID = try container.decode(RecordCollectionID.self, forKey: .collectionID)
        recordID = try container.decode(RecordID.self, forKey: .recordID)
        membershipID = try container.decode(RecordMembershipID.self, forKey: .membershipID)
        membershipRevision = try container.decode(UInt64.self, forKey: .membershipRevision)
        storeRevision = try container.decodeIfPresent(UInt64.self, forKey: .storeRevision) ?? 0
        captureTags = try container.decodeIfPresent(
            [SystemClipboardCaptureTag].self,
            forKey: .captureTags
        )
        lineage = try container.decodeIfPresent(
            RecordCollectionEventLineage.self,
            forKey: .lineage
        ) ?? RecordCollectionEventLineage(rootEventID: eventID)
        guard lineage.isValid(for: eventID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .lineage,
                in: container,
                debugDescription: "A root Record collection lineage must match its event."
            )
        }
        timestamp = try container.decode(Date.self, forKey: .timestamp)
    }
}

// MARK: - Trigger Condition

public enum RecordCollectionTriggerCondition: Codable, Sendable, Equatable {
    case always
    case excludingTag(SystemClipboardCaptureTag)
    case matchingCollection(RecordCollectionID)
}

extension RecordCollectionTriggerCondition {
    public func evaluate(descriptor: RecordCollectionEventDescriptor) -> Bool {
        switch self {
        case .always:
            return true
        case .excludingTag(let tag):
            guard let captureTags = descriptor.captureTags else { return false }
            return !captureTags.contains(tag)
        case .matchingCollection(let collectionID):
            return descriptor.collectionID == collectionID
        }
    }

    func skipReason(
        for descriptor: RecordCollectionEventDescriptor
    ) -> RecordCollectionTriggerSkipReason {
        switch self {
        case .always:
            return .conditionFailed
        case .excludingTag(let tag):
            guard let captureTags = descriptor.captureTags else { return .recordMissing }
            if tag == .polishGenerated, captureTags.contains(.polishGenerated) {
                return .loopPrevented
            }
            return .excludedByCaptureTag
        case .matchingCollection:
            return .conditionFailed
        }
    }
}

// MARK: - Record Collection Trigger Match Result

public enum RecordCollectionTriggerSkipReason: String, Codable, Sendable, Equatable, CaseIterable {
    case eventKindMismatch
    case sourceCollectionMismatch
    case excludedByCaptureTag
    case conditionFailed
    case recordMissing
    case loopPrevented

    public var workflowRunSkipCode: WorkflowRunSkipCode {
        switch self {
        case .eventKindMismatch:
            return .eventKindMismatch
        case .sourceCollectionMismatch:
            return .sourceCollectionMismatch
        case .excludedByCaptureTag:
            return .excludedByCaptureTag
        case .conditionFailed:
            return .conditionFailed
        case .recordMissing:
            return .recordMissing
        case .loopPrevented:
            return .loopPrevented
        }
    }
}

public struct RecordCollectionTriggerMatchResult: Codable, Sendable, Equatable {
    public var matched: Bool
    public var skipReason: RecordCollectionTriggerSkipReason?
    public var failedConditionIndex: Int?

    public init(
        matched: Bool,
        skipReason: RecordCollectionTriggerSkipReason? = nil,
        failedConditionIndex: Int? = nil
    ) {
        self.matched = matched
        self.skipReason = skipReason
        self.failedConditionIndex = failedConditionIndex
    }

    public static let matched = RecordCollectionTriggerMatchResult(matched: true)

    public static func skipped(
        _ reason: RecordCollectionTriggerSkipReason,
        failedConditionIndex: Int? = nil
    ) -> RecordCollectionTriggerMatchResult {
        RecordCollectionTriggerMatchResult(
            matched: false,
            skipReason: reason,
            failedConditionIndex: failedConditionIndex
        )
    }
}

// MARK: - Record Collection Trigger Rule

/// The content-free matching policy for one record collection automation.
public struct RecordCollectionTriggerRule: Codable, Sendable, Equatable {
    public var eventKind: RecordCollectionEventKind
    public var sourceCollectionID: RecordCollectionID?
    public var conditions: [RecordCollectionTriggerCondition]

    public init(
        eventKind: RecordCollectionEventKind,
        sourceCollectionID: RecordCollectionID? = nil,
        conditions: [RecordCollectionTriggerCondition] = []
    ) {
        self.eventKind = eventKind
        self.sourceCollectionID = sourceCollectionID
        self.conditions = conditions
    }

    public func matches(descriptor: RecordCollectionEventDescriptor) -> Bool {
        matchResult(for: descriptor).matched
    }

    public func matchResult(
        for descriptor: RecordCollectionEventDescriptor
    ) -> RecordCollectionTriggerMatchResult {
        guard descriptor.kind == eventKind else {
            return .skipped(.eventKindMismatch)
        }
        if let sourceCollectionID, descriptor.collectionID != sourceCollectionID {
            return .skipped(.sourceCollectionMismatch)
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

// MARK: - Record Collection Trigger Definition

public struct RecordCollectionTrigger: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var eventKind: RecordCollectionEventKind
    public var sourceCollectionID: RecordCollectionID?
    public var conditions: [RecordCollectionTriggerCondition]
    public var actionKind: RecordCollectionActionKind
    public var actionConfiguration: [String: String]

    public init(
        id: UUID = UUID(),
        name: String,
        eventKind: RecordCollectionEventKind,
        sourceCollectionID: RecordCollectionID? = nil,
        conditions: [RecordCollectionTriggerCondition] = [],
        actionKind: RecordCollectionActionKind,
        actionConfiguration: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.eventKind = eventKind
        self.sourceCollectionID = sourceCollectionID
        self.conditions = conditions
        self.actionKind = actionKind
        self.actionConfiguration = actionConfiguration
    }

    public func matches(descriptor: RecordCollectionEventDescriptor) -> Bool {
        rule.matches(descriptor: descriptor)
    }

    public func matchResult(
        for descriptor: RecordCollectionEventDescriptor
    ) -> RecordCollectionTriggerMatchResult {
        rule.matchResult(for: descriptor)
    }

    public var rule: RecordCollectionTriggerRule {
        RecordCollectionTriggerRule(
            eventKind: eventKind,
            sourceCollectionID: sourceCollectionID,
            conditions: conditions
        )
    }
}

// MARK: - Builtin Trigger: Voice Input Polish

public extension RecordCollectionTrigger {
    static let voiceInputPolish = RecordCollectionTrigger(
        name: "Voice Input Auto-Polish",
        eventKind: .recordCreated,
        sourceCollectionID: RecordCollection.voiceInputID,
        conditions: [
            .excludingTag(.polishGenerated)
        ],
        actionKind: .editRecord,
        actionConfiguration: [
            "action": "llmRewrite",
            "prompt": "Polish into a concise final message while preserving meaning and language."
        ]
    )
}
