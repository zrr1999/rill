import RillCore

struct WorkflowExplanationPresentationRow: Sendable, Equatable {
    let title: String
    let detail: String
}

struct WorkflowExplanationPresentation: Sendable, Equatable {
    let status: WorkflowExplanationStatus
    let statusTitle: String
    let statusDetail: String
    let trigger: String
    let inputs: [WorkflowExplanationPresentationRow]
    let transforms: [WorkflowExplanationPresentationRow]
    let outputs: [WorkflowExplanationPresentationRow]
    let destinations: [String]
    let privacyReasons: [String]
    let issues: [String]

    static func make(
        receipt: WorkflowExplanationReceipt,
        language: AppLanguage
    ) -> WorkflowExplanationPresentation {
        WorkflowExplanationPresentation(
            status: receipt.status,
            statusTitle: L10n.workflowExplanationStatusTitle(
                receipt.status,
                language: language
            ),
            statusDetail: L10n.workflowExplanationStatusDetail(
                receipt.status,
                language: language
            ),
            trigger: L10n.workflowExplanationTrigger(receipt.trigger, language: language),
            inputs: receipt.inputs.map { input in
                WorkflowExplanationPresentationRow(
                    title: L10n.workflowExplanationInput(input.category, language: language),
                    detail: L10n.workflowExplanationInputDetail(
                        input,
                        privacyRedacted: isPrivacyRedacted(
                            input.category,
                            categories: receipt.redactedInputCategories
                        ),
                        language: language
                    )
                )
            },
            transforms: receipt.transforms.map { transform in
                WorkflowExplanationPresentationRow(
                    title: L10n.workflowExplanationTransform(transform.kind, language: language),
                    detail: L10n.workflowExplanationTransformDetail(transform, language: language)
                )
            },
            outputs: receipt.outputs.map { output in
                WorkflowExplanationPresentationRow(
                    title: L10n.workflowExplanationOutput(output.effect, language: language),
                    detail: L10n.workflowExplanationOutputDetail(output, language: language)
                )
            },
            destinations: receipt.processingDestinations.map {
                L10n.workflowExplanationDestination($0, language: language)
            },
            privacyReasons: L10n.workflowExplanationPrivacyReasons(
                receipt.privacyReasons,
                language: language
            ),
            issues: receipt.issues.map {
                L10n.workflowExplanationIssue($0, language: language)
            }
        )
    }

    private static func isPrivacyRedacted(
        _ input: WorkflowExplanationInputCategory,
        categories: [PrivacyRedactedInputCategory]
    ) -> Bool {
        switch input {
        case .focusedSelection:
            categories.contains(.focusedSelection)
        case .clipboardText:
            categories.contains(.clipboardText)
        case .microphoneAudio, .recognitionHints, .unclassified:
            false
        }
    }
}
