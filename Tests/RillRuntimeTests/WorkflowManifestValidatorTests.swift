import RillDomainTestSupport
@testable import RillCore
@testable import RillWorkflows
import XCTest

private struct ValidatorRecognizer: SpeechRecognizer {
  let id = "validator.recognizer"

  func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
    RecognitionResult(rawText: "hello", bestText: "hello")
  }
}

private struct ValidatorAction: OutputAction {
  let id = "validator.action"

  func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
    _ = try record.requireText(for: id)
    return .copiedToClipboard
  }
}

final class WorkflowManifestValidatorTests: XCTestCase {
  func testValidatorAllowsPlannedPresetWithUnavailableFutureComponents() throws {
    let manifest = WorkflowManifest(
      workflows: [
        WorkflowDefinition(
          name: "Planned Rewrite",
          plan: WorkflowPlan(
            setup: WorkflowSetupPhase(speechRoute: WorkflowSpeechRoute(recognizerID: "future.recognizer")),
            process: WorkflowProcessPhase(
              steps: [
                WorkflowProcessStep(kind: .recognizeSpeech), WorkflowProcessStep(kind: .resolveUncertainty, uncertaintyPolicy: .init()),
                WorkflowProcessStep(kind: .applyVocabulary),
              ] + ([PostProcessStep(kind: .llmRewrite, reasoning: .some(.none))]).map(WorkflowProcessStep.init)),
            output: WorkflowOutputPhase(actions: [OutputActionReference(id: "future.action")], deliveryPolicy: .init(strategy: .immediate))),
          ui: WorkflowUIConfig(symbolName: "wand.and.stars", accentColorName: "purple"),
          properties: .init(availability: WorkflowAvailability(rawValue: WorkflowAvailability.planned.rawValue) ?? .planned))
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
          plan: makeTestAudioPlan(recognizerID: "missing.recognizer", actions: [OutputActionReference(id: "validator.action")]),
          ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
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
          plan: makeTestAudioPlan(recognizerID: "validator.recognizer", actions: [OutputActionReference(id: "validator.action")]),
          ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
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
