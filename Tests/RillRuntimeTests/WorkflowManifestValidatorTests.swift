import XCTest
@testable import RillCore
@testable import RillRuntime

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
    func testValidatorAllowsPlannedPresetWithUnavailableFutureComponents() throws {
        let manifest = WorkflowManifest(
            workflows: [
                WorkflowDefinition(
                    name: "Planned Rewrite",
                    pipeline: PipelineDeclaration(
                        recognizerID: "future.recognizer",
                        postProcessSteps: [PostProcessStep(kind: .llmRewrite)],
                        outputActions: [OutputActionReference(id: "future.action")]
                    ),
                    ui: WorkflowUIConfig(symbolName: "wand.and.stars", accentColorName: "purple"),
                    metadata: [
                        WorkflowMetadataKey.availability: WorkflowAvailability.planned.rawValue
                    ]
                ),
            ]
        )
        let validator = WorkflowManifestValidator(
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [])
        )

        XCTAssertNoThrow(try validator.validate(manifest))
    }

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
