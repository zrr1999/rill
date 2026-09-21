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

/// One executed text-processing step, retained in encrypted activity history.
public struct WorkflowTextStep: Codable, Sendable, Equatable {
    public let kind: WorkflowProcessStepKind
    public let result: WorkflowStepResultCode
    public let outputText: String?
    public let didChange: Bool?
    public let tokenUsage: LanguageModelTokenUsage?

    public init(
        kind: WorkflowProcessStepKind,
        result: WorkflowStepResultCode = .completed,
        outputText: String? = nil,
        didChange: Bool? = nil,
        tokenUsage: LanguageModelTokenUsage? = nil
    ) {
        self.kind = kind
        self.result = result
        self.outputText = outputText
        self.didChange = didChange
        self.tokenUsage = tokenUsage
    }
}

/// Voice-run provenance and ordered text results. Optional traces preserve
/// compatibility with older history and exclude credentials and captured app content.
public struct RecognitionCorrectionSource: Codable, Sendable, Equatable {
    public var preMappingText: String
    public var context: VocabularyRuleContext
    public var languageModelInputTexts: [String]?
    public var languageModelTraces: [LanguageModelTrace]?
    public var processingSteps: [WorkflowTextStep]?
    public var references: CorrectionReferenceReceipt?
    public var userCorrections: [ConfirmedMemoryCorrection]?

    public init(
        preMappingText: String,
        context: VocabularyRuleContext,
        languageModelInputTexts: [String]? = nil,
        languageModelTraces: [LanguageModelTrace]? = nil,
        processingSteps: [WorkflowTextStep]? = nil,
        references: CorrectionReferenceReceipt? = nil,
        userCorrections: [ConfirmedMemoryCorrection]? = nil
    ) {
        self.preMappingText = preMappingText
        self.context = context
        self.languageModelInputTexts = languageModelInputTexts
        self.languageModelTraces = languageModelTraces
        self.processingSteps = processingSteps
        self.references = references
        self.userCorrections = userCorrections
    }

    /// Restricted activity exposes step previews, never prompts or captured context.
    public var restrictedStepPreview: RecognitionCorrectionSource? {
        guard let processingSteps, !processingSteps.isEmpty else { return nil }
        return RecognitionCorrectionSource(
            preMappingText: "",
            context: VocabularyRuleContext(),
            processingSteps: processingSteps.map { step in
                WorkflowTextStep(
                    kind: step.kind,
                    result: step.result,
                    outputText: step.outputText.map {
                        RecordTextFormatting.previewText(
                            $0, limit: RunHistoryContentAccess.restrictedPreviewCharacterLimit
                        )
                    },
                    didChange: step.didChange,
                    tokenUsage: step.tokenUsage
                )
            }
        )
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
    public var contextHistoryUpdate: CorrectionHistoryUpdate?

    public init(
        runID: UUID,
        workflowID: UUID,
        workflow: WorkflowPresentation,
        trigger: WorkflowRunTriggerKind,
        finalText: String,
        correctionSource: RecognitionCorrectionSource? = nil,
        finishedAt: Date = Date(),
        contextHistoryUpdate: CorrectionHistoryUpdate? = nil
    ) {
        self.runID = runID
        self.workflowID = workflowID
        self.workflow = workflow
        self.trigger = trigger
        self.finalText = finalText
        self.correctionSource = correctionSource
        self.finishedAt = finishedAt
        self.contextHistoryUpdate = contextHistoryUpdate
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
