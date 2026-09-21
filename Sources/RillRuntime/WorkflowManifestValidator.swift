import Foundation
import RillCore

public enum WorkflowManifestValidationError: Error, LocalizedError, Equatable {
    case missingRecognizer(workflowID: UUID, recognizerID: String)
    case missingTransformer(workflowID: UUID, stepKind: PostProcessStepKind)
    case missingAction(workflowID: UUID, actionID: String)
    case invalidPlan(workflowID: UUID, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidPlan(_, let message): return message
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
    private let compiler: WorkflowPlanCompiler

    public init(
        recognizerRegistry: SpeechRecognizerRegistry,
        transformerRegistry: TextTransformerRegistry,
        actionRegistry: OutputActionRegistry
    ) {
        compiler = WorkflowPlanCompiler(recognizerRegistry: recognizerRegistry,
            transformerRegistry: transformerRegistry, actionRegistry: actionRegistry)
    }

    public func validate(_ manifest: WorkflowManifest) throws {
        for workflow in manifest.workflows {
            // Planned presets are declarative roadmap entries. They remain
            // visible but fail closed through WorkflowExecutionPolicy until
            // every runtime component is registered.
            guard workflow.availability == .active else { continue }
            do { _ = try compiler.validate(workflow: workflow) }
            catch let error as WorkflowPlanCompilationError {
                switch error {
                case .missingRecognizer(let id):
                    throw WorkflowManifestValidationError.missingRecognizer(workflowID: workflow.id, recognizerID: id)
                case .missingTransformer(let kind):
                    throw WorkflowManifestValidationError.missingTransformer(workflowID: workflow.id, stepKind: kind)
                case .missingAction(let id):
                    throw WorkflowManifestValidationError.missingAction(workflowID: workflow.id, actionID: id)
                default:
                    throw WorkflowManifestValidationError.invalidPlan(workflowID: workflow.id, message: error.localizedDescription)
                }
            }
        }
    }
}
