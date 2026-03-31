import XCTest
@testable import VoxTypeCore
@testable import VoxTypeRuntime

private struct ValidatorRecognizer: SpeechRecognizer {
    let id = "validator.recognizer"

    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        RecognitionResult(rawText: "hello", bestText: "hello")
    }
}

private struct ValidatorAction: OutputAction {
    let id = "validator.action"

    func execute(text: String, context: ActionContext) async throws -> ActionResult {
        .copiedToClipboard
    }
}

final class WorkflowManifestValidatorTests: XCTestCase {
    func testValidatorRejectsMissingRecognizer() throws {
        let manifest = WorkflowManifest(
            workflows: [
                WorkflowDefinition(
                    name: "Invalid Workflow",
                    pipeline: PipelineDeclaration(
                        recognizerID: "missing.recognizer",
                        outputActions: [OutputActionReference(id: "validator.action")]
                    ),
                    ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
                ),
            ]
        )

        let validator = WorkflowManifestValidator(
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: [ValidatorRecognizer()]),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [ValidatorAction()])
        )

        XCTAssertThrowsError(try validator.validate(manifest)) { error in
            guard case .missingRecognizer(_, "missing.recognizer") = error as? WorkflowManifestValidationError else {
                return XCTFail("Expected missingRecognizer error, got \(error)")
            }
        }
    }

    func testValidatorAcceptsRegisteredDependencies() throws {
        let manifest = WorkflowManifest(
            workflows: [
                WorkflowDefinition(
                    name: "Valid Workflow",
                    pipeline: PipelineDeclaration(
                        recognizerID: "validator.recognizer",
                        outputActions: [OutputActionReference(id: "validator.action")]
                    ),
                    ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
                ),
            ]
        )

        let validator = WorkflowManifestValidator(
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: [ValidatorRecognizer()]),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [ValidatorAction()])
        )

        XCTAssertNoThrow(try validator.validate(manifest))
    }
}
