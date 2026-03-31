import Foundation

public enum WorkflowRunStage: String, Codable, Sendable, Equatable {
    case preparing
    case capturingInput
    case recognizing
    case resolving
    case transforming
    case delivering
    case completed
    case failed
}

public struct WorkflowTriggerEvent: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var binding: TriggerBinding
    public var workflowID: UUID?
    public var sourceID: String
    public var metadata: [String: String]
    public var triggeredAt: Date

    public init(
        id: UUID = UUID(),
        binding: TriggerBinding,
        workflowID: UUID? = nil,
        sourceID: String,
        metadata: [String: String] = [:],
        triggeredAt: Date = Date()
    ) {
        self.id = id
        self.binding = binding
        self.workflowID = workflowID
        self.sourceID = sourceID
        self.metadata = metadata
        self.triggeredAt = triggeredAt
    }
}

public struct WorkflowRunStageSnapshot: Codable, Sendable, Equatable {
    public var runID: UUID
    public var workflowID: UUID
    public var workflow: WorkflowPresentation
    public var stage: WorkflowRunStage
    public var updatedAt: Date

    public init(
        runID: UUID,
        workflowID: UUID,
        workflow: WorkflowPresentation,
        stage: WorkflowRunStage,
        updatedAt: Date = Date()
    ) {
        self.runID = runID
        self.workflowID = workflowID
        self.workflow = workflow
        self.stage = stage
        self.updatedAt = updatedAt
    }
}
