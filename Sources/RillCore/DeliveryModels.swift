import Foundation

public enum ActionResult: Sendable, Equatable {
    case injected
    case copiedToClipboard
    case storedRecord
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
    public var sourceRecordSubject: RecordDeliverySubject?
    public var startedAt: Date
    public var finishedAt: Date

    public var sourceRecordID: RecordID? {
        sourceRecordSubject?.recordID
    }

    public init(
        runID: UUID,
        workflow: WorkflowDefinition,
        contextSnapshot: ContextSnapshot,
        recognitionResult: RecognitionResult,
        finalText: String,
        sourceRecordSubject: RecordDeliverySubject? = nil,
        startedAt: Date,
        finishedAt: Date
    ) {
        self.runID = runID
        self.workflow = workflow
        self.contextSnapshot = contextSnapshot
        self.recognitionResult = recognitionResult
        self.finalText = finalText
        self.sourceRecordSubject = sourceRecordSubject
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

/// The minimal retained input provenance for a completed voice run.
///
/// This deliberately excludes the full recognition result and captured application
/// context so run history does not retain unrelated recognition or foreground-app data.
/// Ordered LLM inputs are optional for backward compatibility and remain inside the
/// same encrypted, privacy-gated history payload as vocabulary-correction provenance.
public struct RecognitionCorrectionSource: Codable, Sendable, Equatable {
    public var preMappingText: String
    public var context: VocabularyRuleContext
    public var languageModelInputTexts: [String]?
    public var languageModelTraces: [LanguageModelTrace]?

    public init(
        preMappingText: String,
        context: VocabularyRuleContext,
        languageModelInputTexts: [String]? = nil,
        languageModelTraces: [LanguageModelTrace]? = nil
    ) {
        self.preMappingText = preMappingText
        self.context = context
        self.languageModelInputTexts = languageModelInputTexts
        self.languageModelTraces = languageModelTraces
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
