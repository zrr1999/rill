import Foundation

public enum DeliveryItemState: String, Codable, Sendable {
    case pending
    case delivering
    case delivered
    case failed
    case expired
}

public struct DeliveryItem: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var workflowID: UUID
    public var workflow: WorkflowPresentation?
    public var text: String
    public var alternatives: [String]
    public var createdAt: Date
    public var state: DeliveryItemState
    public var latestError: String?
    public var sourceApplicationName: String?
    public var sourceBundleIdentifier: String?
    public var captureTags: [ClipboardCaptureTag]

    public init(
        id: UUID = UUID(),
        workflowID: UUID,
        workflow: WorkflowPresentation? = nil,
        text: String,
        alternatives: [String] = [],
        createdAt: Date = Date(),
        state: DeliveryItemState = .pending,
        latestError: String? = nil,
        sourceApplicationName: String? = nil,
        sourceBundleIdentifier: String? = nil,
        captureTags: [ClipboardCaptureTag] = []
    ) {
        self.id = id
        self.workflowID = workflowID
        self.workflow = workflow
        self.text = text
        self.alternatives = alternatives
        self.createdAt = createdAt
        self.state = state
        self.latestError = latestError
        self.sourceApplicationName = sourceApplicationName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.captureTags = captureTags
    }
}

public struct DeliveryStackSnapshot: Sendable, Equatable {
    public var count: Int
    public var topPreview: String?

    public init(count: Int, topPreview: String?) {
        self.count = count
        self.topPreview = topPreview
    }
}

public enum ActionResult: Sendable, Equatable {
    case injected
    case copiedToClipboard
    case pushedToStack
    case skipped(String)
    case failed(String)
}

public struct ActionContext: Sendable, Equatable {
    public var runID: UUID
    public var workflow: WorkflowDefinition
    public var contextSnapshot: ContextSnapshot
    public var recognitionResult: RecognitionResult
    public var finalText: String
    public var sourceClipboardItemID: UUID?
    public var startedAt: Date
    public var finishedAt: Date

    public init(
        runID: UUID,
        workflow: WorkflowDefinition,
        contextSnapshot: ContextSnapshot,
        recognitionResult: RecognitionResult,
        finalText: String,
        sourceClipboardItemID: UUID? = nil,
        startedAt: Date,
        finishedAt: Date
    ) {
        self.runID = runID
        self.workflow = workflow
        self.contextSnapshot = contextSnapshot
        self.recognitionResult = recognitionResult
        self.finalText = finalText
        self.sourceClipboardItemID = sourceClipboardItemID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public struct WorkflowRunSummary: Sendable, Equatable {
    public var runID: UUID
    public var workflowID: UUID
    public var workflow: WorkflowPresentation
    public var finalText: String
    public var finishedAt: Date

    public init(
        runID: UUID,
        workflowID: UUID,
        workflow: WorkflowPresentation,
        finalText: String,
        finishedAt: Date = Date()
    ) {
        self.runID = runID
        self.workflowID = workflowID
        self.workflow = workflow
        self.finalText = finalText
        self.finishedAt = finishedAt
    }
}

public struct RunSnapshot: Sendable, Equatable {
    public var runID: UUID
    public var workflowID: UUID
    public var workflow: WorkflowPresentation
    public var startedAt: Date

    public init(
        runID: UUID,
        workflowID: UUID,
        workflow: WorkflowPresentation,
        startedAt: Date = Date()
    ) {
        self.runID = runID
        self.workflowID = workflowID
        self.workflow = workflow
        self.startedAt = startedAt
    }
}
