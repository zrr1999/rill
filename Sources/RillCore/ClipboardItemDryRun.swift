import Foundation

/// The minimum stored-item metadata needed to describe a clipboard operation.
///
/// This type deliberately does not conform to `Codable` and cannot carry item
/// text, image bytes, file URLs, alternatives, tags entered by the user, or a
/// source application identity.
public struct ClipboardItemDryRunSubject: Sendable, Equatable {
    public let itemID: UUID
    public let itemVersion: ClipboardItemVersion
    public let groupID: UUID
    public let contentKind: ClipboardContentKind
    public let captureTags: [ClipboardCaptureTag]
    public let hasTransferableContent: Bool

    public init(
        itemID: UUID,
        itemVersion: ClipboardItemVersion,
        groupID: UUID,
        contentKind: ClipboardContentKind,
        captureTags: [ClipboardCaptureTag] = [],
        hasTransferableContent: Bool
    ) {
        self.itemID = itemID
        self.itemVersion = itemVersion
        self.groupID = groupID
        self.contentKind = contentKind
        self.captureTags = Self.orderedUnique(captureTags)
        self.hasTransferableContent = hasTransferableContent
    }

    public var excludesWorkflowCapture: Bool {
        captureTags.contains(.excludeFromWorkflowCapture)
    }

    private static func orderedUnique<T: Equatable>(_ values: [T]) -> [T] {
        var result: [T] = []
        for value in values where !result.contains(value) {
            result.append(value)
        }
        return result
    }
}

public enum ClipboardItemDryRunReceiptVersion: Int, Codable, Sendable, Equatable, CaseIterable {
    case v1 = 1
}

public enum ClipboardItemDryRunOperation: String, Codable, Sendable, Equatable, CaseIterable {
    case use
    case replay
    case replace
}

public enum ClipboardItemDryRunStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case ready
    case requiresConfirmation
    case blocked
    case skipped
}

public enum ClipboardItemDryRunReason: String, Codable, Sendable, Equatable, CaseIterable {
    case sourceContentUnavailable
    case workflowRequired
    case unsupportedContentKind
    case sourceExcludedFromWorkflowCapture
    case legacyWorkflowUnsupported
    case componentUnclassified
    case configurationMissing
    case configurationInvalid
    case privacyEvaluationUnavailable
    case privacyProcessingBlocked
    case noSourceReplacementEffect
    case ambiguousSourceReplacement
}

public enum ClipboardItemDryRunReadCategory: String, Codable, Sendable, Equatable, CaseIterable {
    case sourceItemText
    case sourceItemImage
    case sourceItemFiles
    case focusedApplicationIdentity
    case currentClipboardDescriptor
    case currentClipboardContents
    case privacySettings
    case workflowConfiguration
    case vocabularyRules
    case vocabularyScope
}

public struct ClipboardItemDryRunRead: Codable, Sendable, Equatable {
    public var category: ClipboardItemDryRunReadCategory
    public var usage: WorkflowExplanationUsage

    public init(
        category: ClipboardItemDryRunReadCategory,
        usage: WorkflowExplanationUsage
    ) {
        self.category = category
        self.usage = usage
    }
}

public enum ClipboardItemDryRunEffect: String, Codable, Sendable, Equatable, CaseIterable {
    case temporaryClipboardWrite
    case focusedApplicationWrite
    case clipboardHistoryUsageWrite
    case clipboardWrite
    case clipboardHistoryWrite
    case deliveryStackWrite
    case sourceItemReplacement
    case webhookRequest
    case shortcutInvocation
    case temporaryFileWrite
    case fileAppend
    case unclassified
}

public struct ClipboardItemDryRunActionEffect: Codable, Sendable, Equatable {
    /// `nil` identifies an operation-level effect such as direct paste.
    public var sourceActionIndex: Int?
    public var effect: ClipboardItemDryRunEffect
    public var usage: WorkflowExplanationUsage
    public var configurationState: WorkflowExplanationConfigurationState
    public var processingDestination: WorkflowExplanationProcessingDestination

    public init(
        sourceActionIndex: Int?,
        effect: ClipboardItemDryRunEffect,
        usage: WorkflowExplanationUsage = .required,
        configurationState: WorkflowExplanationConfigurationState,
        processingDestination: WorkflowExplanationProcessingDestination
    ) {
        self.sourceActionIndex = sourceActionIndex
        self.effect = effect
        self.usage = usage
        self.configurationState = configurationState
        self.processingDestination = processingDestination
    }
}

public enum ClipboardItemDryRunSourceReplacementPlan: String, Codable, Sendable, Equatable, CaseIterable {
    case notRequested
    case unavailable
    case exactlyOne
    case ambiguous
}

public enum ClipboardItemDryRunIssueKind: String, Codable, Sendable, Equatable, CaseIterable {
    case sourceContentUnavailable
    case workflowRequired
    case unsupportedContentKind
    case sourceExcludedFromWorkflowCapture
    case legacyWorkflowUnsupported
    case componentUnclassified
    case configurationMissing
    case configurationInvalid
    case privacyEvaluationUnavailable
    case privacyConfirmationRequired
    case privacyProcessingBlocked
    case sourceReplacementUnavailable
    case sourceReplacementAmbiguous
}

public struct ClipboardItemDryRunIssue: Codable, Sendable, Equatable {
    public var kind: ClipboardItemDryRunIssueKind
    public var component: WorkflowExplanationComponentKind?
    public var componentIndex: Int?

    public init(
        kind: ClipboardItemDryRunIssueKind,
        component: WorkflowExplanationComponentKind? = nil,
        componentIndex: Int? = nil
    ) {
        self.kind = kind
        self.component = component
        self.componentIndex = componentIndex
    }
}

/// A serializable, content-free description of a clipboard operation.
///
/// The receipt is advisory and never grants an authorization. It contains only
/// identifiers needed for UI correlation, counts, booleans, and closed enums.
/// It cannot carry clipboard payloads, workflow names or prompts, component
/// identifiers, paths, endpoints, credentials, or application identities.
public struct ClipboardItemDryRunReceipt: Codable, Sendable, Equatable {
    public static let currentVersion = ClipboardItemDryRunReceiptVersion.v1

    public var version: ClipboardItemDryRunReceiptVersion
    public var workflowID: UUID?
    public var operation: ClipboardItemDryRunOperation
    public var status: ClipboardItemDryRunStatus
    public var reason: ClipboardItemDryRunReason?
    public var reads: [ClipboardItemDryRunRead]
    public var transforms: [WorkflowExplanationTransform]
    public var actionEffects: [ClipboardItemDryRunActionEffect]
    public var processingDestinations: [WorkflowExplanationProcessingDestination]
    public var sourceReplacementPlan: ClipboardItemDryRunSourceReplacementPlan
    public var privacyReasons: [PrivacyRunEvaluationReason]
    public var redactedInputCategories: [PrivacyRedactedInputCategory]
    public var issues: [ClipboardItemDryRunIssue]

    public init(
        version: ClipboardItemDryRunReceiptVersion = Self.currentVersion,
        workflowID: UUID?,
        operation: ClipboardItemDryRunOperation,
        status: ClipboardItemDryRunStatus,
        reason: ClipboardItemDryRunReason? = nil,
        reads: [ClipboardItemDryRunRead],
        transforms: [WorkflowExplanationTransform] = [],
        actionEffects: [ClipboardItemDryRunActionEffect],
        processingDestinations: [WorkflowExplanationProcessingDestination],
        sourceReplacementPlan: ClipboardItemDryRunSourceReplacementPlan = .notRequested,
        privacyReasons: [PrivacyRunEvaluationReason] = [],
        redactedInputCategories: [PrivacyRedactedInputCategory] = [],
        issues: [ClipboardItemDryRunIssue] = []
    ) {
        self.version = version
        self.workflowID = workflowID
        self.operation = operation
        self.status = status
        self.reason = reason
        self.reads = reads
        self.transforms = transforms
        self.actionEffects = actionEffects
        self.processingDestinations = processingDestinations
        self.sourceReplacementPlan = sourceReplacementPlan
        self.privacyReasons = privacyReasons
        self.redactedInputCategories = redactedInputCategories
        self.issues = issues
    }
}
