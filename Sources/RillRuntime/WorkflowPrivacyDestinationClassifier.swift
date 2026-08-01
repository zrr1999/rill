import RillCore

public enum WorkflowPrivacyDestinationClassification: Sendable, Equatable {
    case classified([PrivacyProcessingDestination])
    case unavailable

    public var destinations: [PrivacyProcessingDestination]? {
        guard case .classified(let destinations) = self else { return nil }
        return destinations
    }
}

/// Closed classification shared by privacy preview and live authorization.
/// Unknown components fail closed instead of being guessed to be local.
public enum WorkflowPrivacyDestinationClassifier {
    public static func classify(
        _ workflow: WorkflowDefinition
    ) -> WorkflowPrivacyDestinationClassification {
        classify(workflow, invocation: .capture)
    }

    public static func classify(
        _ workflow: WorkflowDefinition,
        invocation: WorkflowRunInvocation
    ) -> WorkflowPrivacyDestinationClassification {
        var destinations: [PrivacyProcessingDestination] = []

        switch invocation {
        case .capture:
            guard classifyRecognizer(
                workflow.plan.setup.speechRoute?.recognizerID ?? "",
                destinations: &destinations
            ) else {
                return .unavailable
            }
        case .clipboardItem(let subject, let operation):
            guard subject.contentKind == .text,
                  !subject.excludesWorkflowCapture,
                  operation == .replay || operation == .replace else {
                return .unavailable
            }
            // Clipboard replay supplies the stored item as the recognition
            // result and therefore never invokes or classifies the recognizer.
        }

        for step in workflow.plan.process.steps.compactMap(\.postProcessStep) {
            switch step.kind {
            case .snippetReplacement, .normalizeWhitespace:
                break
            case .llmRewrite:
                appendUnique(.cloudText, to: &destinations)
            }
        }

        for action in workflow.plan.output.actions {
            switch action.id {
            case "clipboard.copy", "inject.text", "stack.push",
                 ExternalOutputActionID.shortcutsRun,
                 ExternalOutputActionID.markdownAppend:
                break
            case SpeechOutputActionID.speak:
                appendUnique(.localSpeech, to: &destinations)
            case ExternalOutputActionID.webhookPost:
                appendUnique(.cloudText, to: &destinations)
            default:
                return .unavailable
            }
        }

        return .classified(destinations)
    }

    private static func classifyRecognizer(
        _ identifier: String,
        destinations: inout [PrivacyProcessingDestination]
    ) -> Bool {
        switch identifier {
        case "sherpa-onnx.local", "sherpa-onnx.streaming":
            appendUnique(.localSpeech, to: &destinations)
            return true
        case "context.selection":
            return true
        default:
            return false
        }
    }

    private static func appendUnique(
        _ destination: PrivacyProcessingDestination,
        to destinations: inout [PrivacyProcessingDestination]
    ) {
        guard !destinations.contains(destination) else { return }
        destinations.append(destination)
    }
}
