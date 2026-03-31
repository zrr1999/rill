import Foundation

public enum HistoryOutcome: String, Codable, Sendable, Equatable {
    case completed
    case failed
}

public struct HistoryRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let runID: UUID?
    public let workflowID: UUID?
    public let workflow: WorkflowPresentation
    public let finalText: String?
    public let failureMessage: String?
    public let timestamp: Date
    public let isStackRelated: Bool
    public let outcome: HistoryOutcome

    public init(
        id: UUID = UUID(),
        runID: UUID? = nil,
        workflowID: UUID? = nil,
        workflow: WorkflowPresentation,
        finalText: String? = nil,
        failureMessage: String? = nil,
        timestamp: Date = Date(),
        isStackRelated: Bool = false,
        outcome: HistoryOutcome
    ) {
        self.id = id
        self.runID = runID
        self.workflowID = workflowID
        self.workflow = workflow
        self.finalText = finalText
        self.failureMessage = failureMessage
        self.timestamp = timestamp
        self.isStackRelated = isStackRelated
        self.outcome = outcome
    }
}

public struct HistoryQuery: Sendable, Equatable {
    public var runID: UUID?
    public var workflowID: UUID?
    public var outcome: HistoryOutcome?
    public var since: Date?
    public var stackRelatedOnly: Bool?
    public var limit: Int?

    public init(
        runID: UUID? = nil,
        workflowID: UUID? = nil,
        outcome: HistoryOutcome? = nil,
        since: Date? = nil,
        stackRelatedOnly: Bool? = nil,
        limit: Int? = nil
    ) {
        self.runID = runID
        self.workflowID = workflowID
        self.outcome = outcome
        self.since = since
        self.stackRelatedOnly = stackRelatedOnly
        self.limit = limit
    }
}

public extension HistoryQuery {
    static let all = HistoryQuery()
}
