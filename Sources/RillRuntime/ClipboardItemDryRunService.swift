import Foundation
import RillCore

/// Builds a content-free clipboard-operation receipt from static workflow
/// declarations, a closed capability catalog, and an already projected privacy
/// evaluation.
///
/// The service is deliberately synchronous and has no access to recognizers,
/// transformers, output actions, confirmation providers, coordinators, event
/// buses, persistence, pasteboards, or clipboard payloads.
public struct ClipboardItemDryRunService: Sendable {
    private let profileRegistry: WorkflowComponentProfileRegistry

    public init(
        profileRegistry: WorkflowComponentProfileRegistry = .init()
    ) {
        self.profileRegistry = profileRegistry
    }

    public func preview(
        subject: ClipboardItemDryRunSubject,
        operation: ClipboardItemDryRunOperation,
        workflow: WorkflowDefinition? = nil,
        privacyEvaluation: PrivacyRunEvaluation? = nil
    ) -> ClipboardItemDryRunReceipt {
        switch operation {
        case .use:
            return directUseReceipt(for: subject)
        case .replay, .replace:
            return workflowReceipt(
                for: subject,
                operation: operation,
                workflow: workflow,
                privacyEvaluation: privacyEvaluation
            )
        }
    }
}

private extension ClipboardItemDryRunService {
    struct WorkflowProjection {
        var transforms: [WorkflowExplanationTransform]
        var effects: [ClipboardItemDryRunActionEffect]
        var reads: [ClipboardItemDryRunRead]
        var issues: [ClipboardItemDryRunIssue]
    }

    func directUseReceipt(
        for subject: ClipboardItemDryRunSubject
    ) -> ClipboardItemDryRunReceipt {
        guard subject.hasTransferableContent else {
            return ClipboardItemDryRunReceipt(
                workflowID: nil,
                operation: .use,
                status: .skipped,
                reason: .sourceContentUnavailable,
                reads: [
                    ClipboardItemDryRunRead(
                        category: sourceReadCategory(for: subject.contentKind),
                        usage: .required
                    ),
                ],
                actionEffects: [],
                processingDestinations: [],
                issues: [
                    ClipboardItemDryRunIssue(kind: .sourceContentUnavailable),
                ]
            )
        }
        let reads = [
            ClipboardItemDryRunRead(
                category: sourceReadCategory(for: subject.contentKind),
                usage: .required
            ),
            ClipboardItemDryRunRead(
                category: .focusedApplicationIdentity,
                usage: .required
            ),
            ClipboardItemDryRunRead(
                category: .currentClipboardDescriptor,
                usage: .required
            ),
            ClipboardItemDryRunRead(
                category: .currentClipboardContents,
                usage: .conditional
            ),
        ]
        let effects = [
            ClipboardItemDryRunActionEffect(
                sourceActionIndex: nil,
                effect: .temporaryClipboardWrite,
                usage: .conditional,
                configurationState: .notRequired,
                processingDestination: .clipboard
            ),
            ClipboardItemDryRunActionEffect(
                sourceActionIndex: nil,
                effect: .focusedApplicationWrite,
                configurationState: .notRequired,
                processingDestination: .focusedApplication
            ),
            ClipboardItemDryRunActionEffect(
                sourceActionIndex: nil,
                effect: .clipboardHistoryUsageWrite,
                usage: .conditional,
                configurationState: .notRequired,
                processingDestination: .localStorage
            ),
        ]
        return ClipboardItemDryRunReceipt(
            workflowID: nil,
            operation: .use,
            status: .ready,
            reads: reads,
            actionEffects: effects,
            processingDestinations: orderedUnique(
                effects.map(\.processingDestination)
            )
        )
    }

    func workflowReceipt(
        for subject: ClipboardItemDryRunSubject,
        operation: ClipboardItemDryRunOperation,
        workflow: WorkflowDefinition?,
        privacyEvaluation: PrivacyRunEvaluation?
    ) -> ClipboardItemDryRunReceipt {
        precondition(operation == .replay || operation == .replace)

        if !subject.hasTransferableContent {
            return terminalWorkflowReceipt(
                workflowID: workflow?.id,
                operation: operation,
                status: .skipped,
                reason: .sourceContentUnavailable,
                reads: [
                    ClipboardItemDryRunRead(
                        category: sourceReadCategory(for: subject.contentKind),
                        usage: .required
                    ),
                ],
                issue: ClipboardItemDryRunIssue(kind: .sourceContentUnavailable)
            )
        }
        if subject.excludesWorkflowCapture {
            return terminalWorkflowReceipt(
                workflowID: workflow?.id,
                operation: operation,
                status: .blocked,
                reason: .sourceExcludedFromWorkflowCapture,
                reads: sourceWorkflowReads,
                issue: ClipboardItemDryRunIssue(
                    kind: .sourceExcludedFromWorkflowCapture,
                    component: .privacyPolicy
                )
            )
        }
        guard subject.contentKind == .text else {
            return terminalWorkflowReceipt(
                workflowID: workflow?.id,
                operation: operation,
                status: .skipped,
                reason: .unsupportedContentKind,
                reads: [
                    ClipboardItemDryRunRead(
                        category: sourceReadCategory(for: subject.contentKind),
                        usage: .required
                    ),
                ],
                issue: ClipboardItemDryRunIssue(kind: .unsupportedContentKind)
            )
        }
        guard let workflow else {
            return terminalWorkflowReceipt(
                workflowID: nil,
                operation: operation,
                status: .skipped,
                reason: .workflowRequired,
                reads: sourceWorkflowReads,
                issue: ClipboardItemDryRunIssue(
                    kind: .workflowRequired,
                    component: .workflow
                )
            )
        }
        if WorkflowExecutionPolicy.issue(for: workflow) != nil {
            return terminalWorkflowReceipt(
                workflowID: workflow.id,
                operation: operation,
                status: .blocked,
                reason: .legacyWorkflowUnsupported,
                reads: sourceWorkflowReads,
                issue: ClipboardItemDryRunIssue(
                    kind: .legacyWorkflowUnsupported,
                    component: .workflow
                )
            )
        }

        var projection = projectWorkflow(workflow, operation: operation)
        let replacementPlan = profileRegistry.clipboardItemSourceReplacementPlan(
            for: workflow,
            operation: operation
        )
        let destinations = orderedUnique(
            projection.transforms.map(\.processingDestination)
                + projection.effects.map(\.processingDestination)
        )

        if projection.issues.contains(where: { $0.kind == .componentUnclassified }) {
            return receipt(
                workflow: workflow,
                operation: operation,
                status: .blocked,
                reason: .componentUnclassified,
                projection: projection,
                destinations: destinations,
                replacementPlan: replacementPlan,
                privacyEvaluation: privacyEvaluation
            )
        }
        if projection.issues.contains(where: { $0.kind == .configurationInvalid }) {
            return receipt(
                workflow: workflow,
                operation: operation,
                status: .blocked,
                reason: .configurationInvalid,
                projection: projection,
                destinations: destinations,
                replacementPlan: replacementPlan,
                privacyEvaluation: privacyEvaluation
            )
        }
        if projection.issues.contains(where: { $0.kind == .configurationMissing }) {
            return receipt(
                workflow: workflow,
                operation: operation,
                status: .blocked,
                reason: .configurationMissing,
                projection: projection,
                destinations: destinations,
                replacementPlan: replacementPlan,
                privacyEvaluation: privacyEvaluation
            )
        }

        switch replacementPlan {
        case .unavailable:
            projection.issues.append(
                ClipboardItemDryRunIssue(
                    kind: .sourceReplacementUnavailable,
                    component: .outputAction
                )
            )
            return receipt(
                workflow: workflow,
                operation: operation,
                status: .skipped,
                reason: .noSourceReplacementEffect,
                projection: projection,
                destinations: destinations,
                replacementPlan: replacementPlan,
                privacyEvaluation: privacyEvaluation
            )
        case .ambiguous:
            projection.issues.append(
                ClipboardItemDryRunIssue(
                    kind: .sourceReplacementAmbiguous,
                    component: .outputAction
                )
            )
            return receipt(
                workflow: workflow,
                operation: operation,
                status: .blocked,
                reason: .ambiguousSourceReplacement,
                projection: projection,
                destinations: destinations,
                replacementPlan: replacementPlan,
                privacyEvaluation: privacyEvaluation
            )
        case .notRequested, .exactlyOne:
            break
        }

        guard let privacyEvaluation else {
            projection.issues.append(
                ClipboardItemDryRunIssue(
                    kind: .privacyEvaluationUnavailable,
                    component: .privacyPolicy
                )
            )
            return receipt(
                workflow: workflow,
                operation: operation,
                status: .blocked,
                reason: .privacyEvaluationUnavailable,
                projection: projection,
                destinations: destinations,
                replacementPlan: replacementPlan,
                privacyEvaluation: nil
            )
        }

        if privacyEvaluation.reasons.contains(.privacySettingsUnavailable)
            || privacyEvaluation.reasons.contains(.processingDestinationUnavailable)
        {
            projection.issues.append(
                ClipboardItemDryRunIssue(
                    kind: .privacyEvaluationUnavailable,
                    component: .privacyPolicy
                )
            )
            return receipt(
                workflow: workflow,
                operation: operation,
                status: .blocked,
                reason: .privacyEvaluationUnavailable,
                projection: projection,
                destinations: destinations,
                replacementPlan: replacementPlan,
                privacyEvaluation: privacyEvaluation
            )
        }

        switch privacyEvaluation.status {
        case .ready:
            return receipt(
                workflow: workflow,
                operation: operation,
                status: .ready,
                reason: nil,
                projection: projection,
                destinations: destinations,
                replacementPlan: replacementPlan,
                privacyEvaluation: privacyEvaluation
            )
        case .requiresConfirmation:
            projection.issues.append(
                ClipboardItemDryRunIssue(
                    kind: .privacyConfirmationRequired,
                    component: .privacyPolicy
                )
            )
            return receipt(
                workflow: workflow,
                operation: operation,
                status: .requiresConfirmation,
                reason: nil,
                projection: projection,
                destinations: destinations,
                replacementPlan: replacementPlan,
                privacyEvaluation: privacyEvaluation
            )
        case .blocked:
            projection.issues.append(
                ClipboardItemDryRunIssue(
                    kind: .privacyProcessingBlocked,
                    component: .privacyPolicy
                )
            )
            return receipt(
                workflow: workflow,
                operation: operation,
                status: .blocked,
                reason: .privacyProcessingBlocked,
                projection: projection,
                destinations: destinations,
                replacementPlan: replacementPlan,
                privacyEvaluation: privacyEvaluation
            )
        }
    }

    var sourceWorkflowReads: [ClipboardItemDryRunRead] {
        [
            ClipboardItemDryRunRead(category: .sourceItemText, usage: .required),
            ClipboardItemDryRunRead(category: .focusedApplicationIdentity, usage: .conditional),
            ClipboardItemDryRunRead(category: .currentClipboardDescriptor, usage: .required),
            ClipboardItemDryRunRead(category: .privacySettings, usage: .required),
            ClipboardItemDryRunRead(category: .workflowConfiguration, usage: .required),
            ClipboardItemDryRunRead(category: .vocabularyRules, usage: .conditional),
            ClipboardItemDryRunRead(category: .vocabularyScope, usage: .conditional),
        ]
    }

    func projectWorkflow(
        _ workflow: WorkflowDefinition,
        operation: ClipboardItemDryRunOperation
    ) -> WorkflowProjection {
        var transforms = [
            WorkflowExplanationTransform(
                kind: .vocabularyMapping,
                availability: .available,
                usage: .conditional,
                processingDestination: .onDevice
            ),
        ]
        var effects: [ClipboardItemDryRunActionEffect] = []
        var reads = sourceWorkflowReads
        var issues: [ClipboardItemDryRunIssue] = []

        let postProcessSteps = workflow.plan.process.steps.compactMap(\.postProcessStep)
        for (index, step) in postProcessSteps.enumerated() {
            guard let capability = profileRegistry.closedTransformCapability(for: step.kind) else {
                transforms.append(
                    WorkflowExplanationTransform(
                        kind: transformKind(for: step.kind),
                        availability: .unclassified,
                        usage: .required,
                        processingDestination: .unclassified
                    )
                )
                issues.append(
                    ClipboardItemDryRunIssue(
                        kind: .componentUnclassified,
                        component: .transformer,
                        componentIndex: index
                    )
                )
                continue
            }
            transforms.append(
                WorkflowExplanationTransform(
                    kind: capability.kind,
                    availability: .available,
                    usage: .required,
                    processingDestination: capability.processingDestination
                )
            )
        }

        for (index, reference) in workflow.plan.output.actions.enumerated() {
            guard let capability = profileRegistry.closedOutputCapability(for: reference) else {
                effects.append(
                    ClipboardItemDryRunActionEffect(
                        sourceActionIndex: index,
                        effect: .unclassified,
                        configurationState: .unclassified,
                        processingDestination: .unclassified
                    )
                )
                issues.append(
                    ClipboardItemDryRunIssue(
                        kind: .componentUnclassified,
                        component: .outputAction,
                        componentIndex: index
                    )
                )
                continue
            }

            switch capability.configurationState {
            case .missing:
                issues.append(
                    ClipboardItemDryRunIssue(
                        kind: .configurationMissing,
                        component: .outputAction,
                        componentIndex: index
                    )
                )
            case .invalid:
                issues.append(
                    ClipboardItemDryRunIssue(
                        kind: .configurationInvalid,
                        component: .outputAction,
                        componentIndex: index
                    )
                )
            case .notRequired, .configured, .unclassified:
                break
            }

            let replacesSource = operation == .replace
                && capability.sourceItemReplacement == .replacesSourceItem
            for effect in capability.effects {
                appendEffects(
                    for: effect,
                    sourceActionIndex: index,
                    configurationState: capability.configurationState,
                    replacingSource: replacesSource,
                    to: &effects,
                    reads: &reads
                )
            }
        }

        return WorkflowProjection(
            transforms: transforms,
            effects: effects,
            reads: reads,
            issues: issues
        )
    }

    func appendEffects(
        for capability: WorkflowClosedOutputEffectCapability,
        sourceActionIndex: Int,
        configurationState: WorkflowExplanationConfigurationState,
        replacingSource: Bool,
        to effects: inout [ClipboardItemDryRunActionEffect],
        reads: inout [ClipboardItemDryRunRead]
    ) {
        func append(
            _ effect: ClipboardItemDryRunEffect,
            destination: WorkflowExplanationProcessingDestination,
            usage: WorkflowExplanationUsage = .required
        ) {
            effects.append(
                ClipboardItemDryRunActionEffect(
                    sourceActionIndex: sourceActionIndex,
                    effect: effect,
                    usage: usage,
                    configurationState: configurationState,
                    processingDestination: destination
                )
            )
        }

        switch capability.effect {
        case .clipboardWrite:
            append(.clipboardWrite, destination: capability.processingDestination)
        case .clipboardHistoryWrite:
            append(
                replacingSource ? .sourceItemReplacement : .clipboardHistoryWrite,
                destination: capability.processingDestination
            )
        case .focusedApplicationWrite:
            appendUniqueRead(.focusedApplicationIdentity, usage: .required, to: &reads)
            appendUniqueRead(.currentClipboardDescriptor, usage: .required, to: &reads)
            appendUniqueRead(.currentClipboardContents, usage: .conditional, to: &reads)
            append(.temporaryClipboardWrite, destination: .clipboard, usage: .conditional)
            append(.focusedApplicationWrite, destination: capability.processingDestination)
        case .deliveryStackWrite:
            append(
                replacingSource ? .sourceItemReplacement : .deliveryStackWrite,
                destination: capability.processingDestination
            )
        case .webhookRequest:
            append(.webhookRequest, destination: capability.processingDestination)
        case .shortcutInvocation:
            append(.temporaryFileWrite, destination: .localFile)
            append(.shortcutInvocation, destination: capability.processingDestination)
        case .fileAppend:
            append(.fileAppend, destination: capability.processingDestination)
        case .speechPlayback:
            append(.speechPlayback, destination: capability.processingDestination)
        case .unclassified:
            append(.unclassified, destination: .unclassified)
        }
    }

    func receipt(
        workflow: WorkflowDefinition,
        operation: ClipboardItemDryRunOperation,
        status: ClipboardItemDryRunStatus,
        reason: ClipboardItemDryRunReason?,
        projection: WorkflowProjection,
        destinations: [WorkflowExplanationProcessingDestination],
        replacementPlan: ClipboardItemDryRunSourceReplacementPlan,
        privacyEvaluation: PrivacyRunEvaluation?
    ) -> ClipboardItemDryRunReceipt {
        ClipboardItemDryRunReceipt(
            workflowID: workflow.id,
            operation: operation,
            status: status,
            reason: reason,
            reads: projection.reads,
            transforms: projection.transforms,
            actionEffects: projection.effects,
            processingDestinations: destinations,
            sourceReplacementPlan: replacementPlan,
            privacyReasons: privacyEvaluation?.reasons ?? [],
            redactedInputCategories: privacyEvaluation?.redactedInputCategories ?? [],
            issues: projection.issues
        )
    }

    func terminalWorkflowReceipt(
        workflowID: UUID?,
        operation: ClipboardItemDryRunOperation,
        status: ClipboardItemDryRunStatus,
        reason: ClipboardItemDryRunReason,
        reads: [ClipboardItemDryRunRead],
        issue: ClipboardItemDryRunIssue
    ) -> ClipboardItemDryRunReceipt {
        ClipboardItemDryRunReceipt(
            workflowID: workflowID,
            operation: operation,
            status: status,
            reason: reason,
            reads: reads,
            actionEffects: [],
            processingDestinations: [],
            sourceReplacementPlan: operation == .replace ? .unavailable : .notRequested,
            issues: [issue]
        )
    }

    func sourceReadCategory(
        for contentKind: ClipboardContentKind
    ) -> ClipboardItemDryRunReadCategory {
        switch contentKind {
        case .text: .sourceItemText
        case .image: .sourceItemImage
        case .files: .sourceItemFiles
        }
    }

    func transformKind(
        for kind: PostProcessStepKind
    ) -> WorkflowExplanationTransformKind {
        switch kind {
        case .snippetReplacement: .snippetReplacement
        case .llmRewrite: .languageModelRewrite
        case .llmAnswer: .languageModelAnswer
        case .normalizeWhitespace: .whitespaceNormalization
        }
    }

    func appendUniqueRead(
        _ category: ClipboardItemDryRunReadCategory,
        usage: WorkflowExplanationUsage,
        to reads: inout [ClipboardItemDryRunRead]
    ) {
        guard !reads.contains(where: { $0.category == category }) else { return }
        reads.append(ClipboardItemDryRunRead(category: category, usage: usage))
    }

    func orderedUnique<T: Equatable>(_ values: [T]) -> [T] {
        var result: [T] = []
        for value in values where !result.contains(value) {
            result.append(value)
        }
        return result
    }
}
