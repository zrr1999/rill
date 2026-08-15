import Foundation

public enum HistoryOutcome: String, Codable, Sendable, Equatable {
    case completed
    case failed
}

public struct WorkflowResultRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let runID: UUID?
    public let workflowID: UUID?
    public let workflow: WorkflowPresentation
    public let finalText: String?
    public let failureMessage: String?
    public let timestamp: Date
    public let isRecordRelated: Bool
    public let outcome: HistoryOutcome
    public let correctionSource: RecognitionCorrectionSource?
    /// The closed invocation kind that was authoritative when this body-bearing
    /// record was created. Legacy records decode this as `nil` and must not have
    /// their body classified from mutable workflow metadata.
    public let trigger: WorkflowRunTriggerKind?

    public init(
        id: UUID = UUID(),
        runID: UUID? = nil,
        workflowID: UUID? = nil,
        workflow: WorkflowPresentation,
        finalText: String? = nil,
        failureMessage: String? = nil,
        timestamp: Date = Date(),
        isRecordRelated: Bool = false,
        outcome: HistoryOutcome,
        correctionSource: RecognitionCorrectionSource? = nil,
        trigger: WorkflowRunTriggerKind? = nil
    ) {
        self.id = id
        self.runID = runID
        self.workflowID = workflowID
        self.workflow = workflow
        self.finalText = finalText
        self.failureMessage = failureMessage
        self.timestamp = timestamp
        self.isRecordRelated = isRecordRelated
        self.outcome = outcome
        self.correctionSource = correctionSource
        self.trigger = trigger
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case runID
        case workflowID
        case workflow
        case finalText
        case failureMessage
        case timestamp
        case isRecordRelated
        case legacyIsStackRelated = "isStackRelated"
        case outcome
        case correctionSource
        case trigger
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        runID = try container.decodeIfPresent(UUID.self, forKey: .runID)
        workflowID = try container.decodeIfPresent(UUID.self, forKey: .workflowID)
        workflow = try container.decode(WorkflowPresentation.self, forKey: .workflow)
        finalText = try container.decodeIfPresent(String.self, forKey: .finalText)
        failureMessage = try container.decodeIfPresent(String.self, forKey: .failureMessage)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isRecordRelated = try container.decodeIfPresent(Bool.self, forKey: .isRecordRelated)
            ?? container.decodeIfPresent(Bool.self, forKey: .legacyIsStackRelated)
            ?? false
        outcome = try container.decode(HistoryOutcome.self, forKey: .outcome)
        correctionSource = try container.decodeIfPresent(
            RecognitionCorrectionSource.self,
            forKey: .correctionSource
        )
        trigger = try container.decodeIfPresent(WorkflowRunTriggerKind.self, forKey: .trigger)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(runID, forKey: .runID)
        try container.encodeIfPresent(workflowID, forKey: .workflowID)
        try container.encode(workflow, forKey: .workflow)
        try container.encodeIfPresent(finalText, forKey: .finalText)
        try container.encodeIfPresent(failureMessage, forKey: .failureMessage)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(isRecordRelated, forKey: .isRecordRelated)
        try container.encode(outcome, forKey: .outcome)
        try container.encodeIfPresent(correctionSource, forKey: .correctionSource)
        try container.encodeIfPresent(trigger, forKey: .trigger)
    }
}

public struct HistoryQuery: Sendable, Equatable {
    public var runID: UUID?
    public var workflowID: UUID?
    public var outcome: HistoryOutcome?
    public var since: Date?
    public var recordRelatedOnly: Bool?
    public var limit: Int?

    public init(
        runID: UUID? = nil,
        workflowID: UUID? = nil,
        outcome: HistoryOutcome? = nil,
        since: Date? = nil,
        recordRelatedOnly: Bool? = nil,
        limit: Int? = nil
    ) {
        self.runID = runID
        self.workflowID = workflowID
        self.outcome = outcome
        self.since = since
        self.recordRelatedOnly = recordRelatedOnly
        self.limit = limit
    }
}

public extension HistoryQuery {
    static let all = HistoryQuery()
}
