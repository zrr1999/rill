import Foundation
import VoxTypeCore

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
            if recognizerRegistry.recognizer(for: workflow.pipeline.recognizerID) == nil {
                throw WorkflowManifestValidationError.missingRecognizer(
                    workflowID: workflow.id,
                    recognizerID: workflow.pipeline.recognizerID
                )
            }

            for step in workflow.pipeline.postProcessSteps where transformerRegistry.transformer(for: step.kind) == nil {
                throw WorkflowManifestValidationError.missingTransformer(
                    workflowID: workflow.id,
                    stepKind: step.kind
                )
            }

            for action in workflow.pipeline.outputActions where actionRegistry.action(for: action.id) == nil {
                throw WorkflowManifestValidationError.missingAction(
                    workflowID: workflow.id,
                    actionID: action.id
                )
            }
        }
    }
}
