import Foundation
import RillCore

public enum WorkflowManifestValidationError: Error, LocalizedError, Equatable {
    case missingRecognizer(workflowID: UUID, recognizerID: String)
    case missingTransformer(workflowID: UUID, stepKind: PostProcessStepKind)
    case missingAction(workflowID: UUID, actionID: String)

    public var errorDescription: String? {
        switch self {
        case .missingRecognizer(_, let recognizerID):
            return "No speech recognizer is registered for \(recognizerID)."
        case .missingTransformer(_, let stepKind):
            return "No transformer is registered for \(stepKind.rawValue)."
        case .missingAction(_, let actionID):
            return "No output action is registered for \(actionID)."
        }
    }
}

public struct WorkflowManifestValidator: Sendable {
    private let recognizerRegistry: SpeechRecognizerRegistry
    private let transformerRegistry: TextTransformerRegistry
    private let actionRegistry: OutputActionRegistry

    public init(
        recognizerRegistry: SpeechRecognizerRegistry,
        transformerRegistry: TextTransformerRegistry,
        actionRegistry: OutputActionRegistry
    ) {
        self.recognizerRegistry = recognizerRegistry
        self.transformerRegistry = transformerRegistry
        self.actionRegistry = actionRegistry
    }

    public func validate(_ manifest: WorkflowManifest) throws {
        for workflow in manifest.workflows {
            // Planned presets are declarative roadmap entries. They remain
            // visible but fail closed through WorkflowExecutionPolicy until
            // every runtime component is registered.
            guard workflow.availability == .active else { continue }
            guard let route = workflow.plan.setup.speechRoute else {
                throw WorkflowManifestValidationError.missingRecognizer(
                    workflowID: workflow.id,
                    recognizerID: ""
                )
            }
            if recognizerRegistry.recognizer(for: route.recognizerID) == nil {
                throw WorkflowManifestValidationError.missingRecognizer(
                    workflowID: workflow.id,
                    recognizerID: route.recognizerID
                )
            }

            for step in workflow.plan.process.allSteps {
                guard let kind = step.kind.postProcessKind else { continue }
                guard transformerRegistry.transformer(for: kind) == nil else { continue }
                throw WorkflowManifestValidationError.missingTransformer(
                    workflowID: workflow.id,
                    stepKind: kind
                )
            }

            for action in workflow.plan.output.actions where actionRegistry.action(for: action.id) == nil {
                throw WorkflowManifestValidationError.missingAction(
                    workflowID: workflow.id,
                    actionID: action.id
                )
            }
        }
    }
}
