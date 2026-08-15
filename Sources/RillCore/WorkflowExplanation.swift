import Foundation

public enum WorkflowExplanationStatus: String, Codable, Sendable, Equatable {
    case ready
    case requiresConfirmation
    case blocked
}

public enum WorkflowExplanationTriggerCategory: String, Codable, Sendable, Equatable {
    case manual
    case hotkey
    case menuBar
    case wakeWord
}

public enum WorkflowExplanationInputCategory: String, Codable, Sendable, Equatable {
    case microphoneAudio
    case recognitionHints
    case focusedSelection
    case clipboardText
    case unclassified
}

public enum WorkflowExplanationAvailability: String, Codable, Sendable, Equatable {
    case available
    case unavailable
    case unclassified
}

public enum WorkflowExplanationUsage: String, Codable, Sendable, Equatable {
    case required
    case conditional
    case unclassified
}

public enum WorkflowExplanationTransformKind: String, Codable, Sendable, Equatable {
    case vocabularyMapping
    case snippetReplacement
    case languageModelRewrite
    case languageModelAnswer
    case whitespaceNormalization
}

public enum WorkflowExplanationOutputEffect: String, Codable, Sendable, Equatable {
    case clipboardWrite
    case focusedApplicationWrite
    case recordStoreWrite
    case webhookRequest
    case shortcutInvocation
    case fileAppend
    case speechPlayback
    case unclassified
}

public enum WorkflowExplanationConfigurationState: String, Codable, Sendable, Equatable {
    case notRequired
    case configured
    case missing
    case invalid
    case unclassified
}

public enum WorkflowExplanationProcessingDestination: String, Codable, Sendable, Equatable {
    case onDevice
    case cloudService
    case clipboard
    case focusedApplication
    case localStorage
    case localAutomation
    case localFile
    case remoteEndpoint
    case unclassified
}

public enum WorkflowExplanationComponentKind: String, Codable, Sendable, Equatable {
    case workflow
    case privacyPolicy
    case recognizer
    case transformer
    case outputAction
}

public enum WorkflowExplanationIssueKind: String, Codable, Sendable, Equatable {
    case executionPlanUnresolved
    case legacyWorkflowUnsupported
    case privacyEvaluationUnavailable
    case privacyConfirmationRequired
    case privacyProcessingBlocked
    case privacyInputRedacted
    case componentUnavailable
    case componentUnclassified
    case configurationMissing
    case configurationInvalid
}

public struct WorkflowExplanationIssue: Codable, Sendable, Equatable {
    public var kind: WorkflowExplanationIssueKind
    public var component: WorkflowExplanationComponentKind
    public var componentIndex: Int?

    public init(
        kind: WorkflowExplanationIssueKind,
        component: WorkflowExplanationComponentKind,
        componentIndex: Int? = nil
    ) {
        self.kind = kind
        self.component = component
        self.componentIndex = componentIndex
    }
}

public struct WorkflowExplanationInput: Codable, Sendable, Equatable {
    public var category: WorkflowExplanationInputCategory
    public var availability: WorkflowExplanationAvailability
    public var usage: WorkflowExplanationUsage
    public var processingDestination: WorkflowExplanationProcessingDestination

    public init(
        category: WorkflowExplanationInputCategory,
        availability: WorkflowExplanationAvailability,
        usage: WorkflowExplanationUsage,
        processingDestination: WorkflowExplanationProcessingDestination
    ) {
        self.category = category
        self.availability = availability
        self.usage = usage
        self.processingDestination = processingDestination
    }
}

public struct WorkflowExplanationTransform: Codable, Sendable, Equatable {
    public var kind: WorkflowExplanationTransformKind
    public var availability: WorkflowExplanationAvailability
    public var usage: WorkflowExplanationUsage
    public var processingDestination: WorkflowExplanationProcessingDestination

    public init(
        kind: WorkflowExplanationTransformKind,
        availability: WorkflowExplanationAvailability,
        usage: WorkflowExplanationUsage,
        processingDestination: WorkflowExplanationProcessingDestination
    ) {
        self.kind = kind
        self.availability = availability
        self.usage = usage
        self.processingDestination = processingDestination
    }
}

public struct WorkflowExplanationOutput: Codable, Sendable, Equatable {
    public var sourceActionIndex: Int
    public var effect: WorkflowExplanationOutputEffect
    public var availability: WorkflowExplanationAvailability
    public var configurationState: WorkflowExplanationConfigurationState
    public var processingDestination: WorkflowExplanationProcessingDestination

    public init(
        sourceActionIndex: Int,
        effect: WorkflowExplanationOutputEffect,
        availability: WorkflowExplanationAvailability,
        configurationState: WorkflowExplanationConfigurationState,
        processingDestination: WorkflowExplanationProcessingDestination
    ) {
        self.sourceActionIndex = sourceActionIndex
        self.effect = effect
        self.availability = availability
        self.configurationState = configurationState
        self.processingDestination = processingDestination
    }
}

/// A content-free, serializable plan for explaining a workflow before execution.
///
/// The receipt deliberately carries only stable identifiers, counts, booleans,
/// and closed enums. It cannot carry user text, component identifiers, paths,
/// endpoints, credentials, workflow definitions, or captured context.
public struct WorkflowExplanationReceipt: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var workflowID: UUID
    public var trigger: WorkflowExplanationTriggerCategory
    public var inputs: [WorkflowExplanationInput]
    public var transforms: [WorkflowExplanationTransform]
    public var outputs: [WorkflowExplanationOutput]
    public var processingDestinations: [WorkflowExplanationProcessingDestination]
    public var status: WorkflowExplanationStatus
    public var issues: [WorkflowExplanationIssue]
    public var privacyReasons: [PrivacyRunEvaluationReason]
    public var redactedInputCategories: [PrivacyRedactedInputCategory]

    public init(
        id: UUID = UUID(),
        workflowID: UUID,
        trigger: WorkflowExplanationTriggerCategory,
        inputs: [WorkflowExplanationInput],
        transforms: [WorkflowExplanationTransform],
        outputs: [WorkflowExplanationOutput],
        processingDestinations: [WorkflowExplanationProcessingDestination],
        status: WorkflowExplanationStatus,
        issues: [WorkflowExplanationIssue],
        privacyReasons: [PrivacyRunEvaluationReason] = [],
        redactedInputCategories: [PrivacyRedactedInputCategory] = []
    ) {
        self.id = id
        self.workflowID = workflowID
        self.trigger = trigger
        self.inputs = inputs
        self.transforms = transforms
        self.outputs = outputs
        self.processingDestinations = processingDestinations
        self.status = status
        self.issues = issues
        self.privacyReasons = privacyReasons
        self.redactedInputCategories = redactedInputCategories
    }
}
