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
    public var targetGroupID: UUID?
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
        targetGroupID: UUID? = nil,
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
        self.targetGroupID = targetGroupID
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
    case externalOutput(String)
    case skipped(String)
    case failed(String)
}

public struct ActionContext: Sendable, Equatable {
    public var runID: UUID
    public var workflow: WorkflowDefinition
    public var contextSnapshot: ContextSnapshot
    public var recognitionResult: RecognitionResult
    public var finalText: String
    public var sourceClipboardItemSubject: ClipboardItemDryRunSubject?
    public var startedAt: Date
    public var finishedAt: Date

    public var sourceClipboardItemID: UUID? {
        sourceClipboardItemSubject?.itemID
    }

    public init(
        runID: UUID,
        workflow: WorkflowDefinition,
        contextSnapshot: ContextSnapshot,
        recognitionResult: RecognitionResult,
        finalText: String,
        sourceClipboardItemSubject: ClipboardItemDryRunSubject? = nil,
        startedAt: Date,
        finishedAt: Date
    ) {
        self.runID = runID
        self.workflow = workflow
        self.contextSnapshot = contextSnapshot
        self.recognitionResult = recognitionResult
        self.finalText = finalText
        self.sourceClipboardItemSubject = sourceClipboardItemSubject
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

/// The minimal recognition input needed to propose a future vocabulary correction.
///
/// This deliberately excludes the full recognition result and captured application
/// context so run history does not retain unrelated recognition or foreground-app data.
public struct RecognitionCorrectionSource: Codable, Sendable, Equatable {
    public var preMappingText: String
    public var context: VocabularyRuleContext

    public init(
        preMappingText: String,
        context: VocabularyRuleContext
    ) {
        self.preMappingText = preMappingText
        self.context = context
    }
}

public struct WorkflowRunSummary: Sendable, Equatable {
    public var runID: UUID
    public var workflowID: UUID
    public var workflow: WorkflowPresentation
    public var trigger: WorkflowRunTriggerKind
    public var finalText: String
    public var correctionSource: RecognitionCorrectionSource?
    public var finishedAt: Date

    public init(
        runID: UUID,
        workflowID: UUID,
        workflow: WorkflowPresentation,
        trigger: WorkflowRunTriggerKind,
        finalText: String,
        correctionSource: RecognitionCorrectionSource? = nil,
        finishedAt: Date = Date()
    ) {
        self.runID = runID
        self.workflowID = workflowID
        self.workflow = workflow
        self.trigger = trigger
        self.finalText = finalText
        self.correctionSource = correctionSource
        self.finishedAt = finishedAt
    }
}

public struct RunSnapshot: Sendable, Equatable {
    public var runID: UUID
    public var workflowID: UUID
    public var workflow: WorkflowPresentation
    public var trigger: WorkflowRunTriggerKind
    public var startedAt: Date

    public init(
        runID: UUID,
        workflowID: UUID,
        workflow: WorkflowPresentation,
        trigger: WorkflowRunTriggerKind,
        startedAt: Date = Date()
    ) {
        self.runID = runID
        self.workflowID = workflowID
        self.workflow = workflow
        self.trigger = trigger
        self.startedAt = startedAt
    }
}
