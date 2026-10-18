@testable import RillCore
@testable import RillWorkflows
import Foundation
import XCTest

private actor WorkflowExplainProbe {
  private var recognitionCount = 0
  private var transformationCount = 0
  private var actionCount = 0

  func recordRecognition() { recognitionCount += 1 }
  func recordTransformation() { transformationCount += 1 }
  func recordAction() { actionCount += 1 }

  func snapshot() -> (recognition: Int, transformation: Int, action: Int) {
    (recognitionCount, transformationCount, actionCount)
  }
}

private struct WorkflowExplainRecognizer: SpeechRecognizer {
  let id: String
  let probe: WorkflowExplainProbe

  func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
    await probe.recordRecognition()
    return RecognitionResult(rawText: "probe", bestText: "probe")
  }
}

private struct WorkflowExplainTransformer: TextTransformer {
  let id: String
  let supportedKinds: [PostProcessStepKind]
  let probe: WorkflowExplainProbe

  func transform(
    text: String,
    step: PostProcessStep,
    context: TransformContext
  ) async throws -> String {
    await probe.recordTransformation()
    return text
  }
}

private struct WorkflowExplainAction: OutputAction {
  let id: String
  let probe: WorkflowExplainProbe

  func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
    _ = try record.requireText(for: id)
    await probe.recordAction()
    return .copiedToClipboard
  }
}

final class WorkflowExplainServiceTests: XCTestCase {
  func testOpenAIRewriteProfileIsClassifiedAsAvailableCloudTextProcessing() async {
    let probe = WorkflowExplainProbe()
    let service = makeService(
      probe: probe,
      recognizerIDs: ["sherpa-onnx.local"],
      transformers: [
        ("transformer.openai.responses.rewrite", [.llmRewrite])
      ],
      actionIDs: ["focused-application.insert"]
    )
    let workflow = makeWorkflow(
      recognizerID: "sherpa-onnx.local",
      steps: [PostProcessStep(kind: .llmRewrite, prompt: "Rewrite", reasoning: .some(.none))],
      actions: [OutputActionReference(id: "focused-application.insert")]
    )

    let receipt = service.explainResolved(
      resolvedPlan(for: workflow),
      privacyEvaluation: PrivacyRunEvaluation(status: .ready)
    )

    XCTAssertEqual(receipt.status, .ready)
    XCTAssertEqual(
      receipt.transforms.first { $0.kind == .languageModelRewrite },
      WorkflowExplanationTransform(
        kind: .languageModelRewrite,
        availability: .available,
        usage: .required,
        processingDestination: .cloudService
      )
    )
    XCTAssertTrue(receipt.processingDestinations.contains(.cloudService))
    await assertProbeWasNotInvoked(probe)
  }

  func testOpenAIAnswerProfileIsClassifiedSeparatelyAsCloudTextProcessing() async {
    let probe = WorkflowExplainProbe()
    let service = makeService(
      probe: probe,
      recognizerIDs: ["sherpa-onnx.local"],
      transformers: [
        ("transformer.openai.responses.rewrite", [.llmRewrite, .llmAnswer])
      ],
      actionIDs: ["speech.speak"]
    )
    let workflow = makeWorkflow(
      recognizerID: "sherpa-onnx.local",
      steps: [PostProcessStep(kind: .llmAnswer, prompt: "Answer", reasoning: .some(.high))],
      actions: [OutputActionReference(id: "speech.speak")]
    )

    let receipt = service.explainResolved(
      resolvedPlan(for: workflow),
      privacyEvaluation: PrivacyRunEvaluation(status: .ready)
    )

    XCTAssertEqual(receipt.status, .ready)
    XCTAssertEqual(
      receipt.transforms.first { $0.kind == .languageModelAnswer },
      WorkflowExplanationTransform(
        kind: .languageModelAnswer,
        availability: .available,
        usage: .required,
        processingDestination: .cloudService
      )
    )
    XCTAssertTrue(receipt.processingDestinations.contains(.cloudService))
    await assertProbeWasNotInvoked(probe)
  }

  func testKnownLocalWorkflowProducesAccurateContentFreeStaticPlan() async throws {
    let probe = WorkflowExplainProbe()
    let service = makeService(
      probe: probe,
      recognizerIDs: ["sherpa-onnx.local"],
      transformers: [("transformer.normalize", [.normalizeWhitespace])],
      actionIDs: ["focused-application.insert"]
    )
    let workflow = makeWorkflow(
      recognizerID: "sherpa-onnx.local",
      steps: [PostProcessStep(kind: .normalizeWhitespace, prompt: "must not escape")],
      actions: [OutputActionReference(id: "focused-application.insert")]
    )

    let receipt = service.explainResolved(resolvedPlan(for: workflow))

    XCTAssertEqual(receipt.workflowID, workflow.id)
    XCTAssertEqual(receipt.trigger, .hotkey)
    XCTAssertEqual(
      receipt.inputs,
      [
        WorkflowExplanationInput(
          category: .microphoneAudio,
          availability: .available,
          usage: .required,
          processingDestination: .onDevice
        )
      ]
    )
    XCTAssertEqual(
      receipt.transforms,
      [
        WorkflowExplanationTransform(
          kind: .vocabularyMapping,
          availability: .available,
          usage: .conditional,
          processingDestination: .onDevice
        ),
        WorkflowExplanationTransform(
          kind: .whitespaceNormalization,
          availability: .available,
          usage: .required,
          processingDestination: .onDevice
        ),
      ]
    )
    XCTAssertEqual(
      receipt.outputs,
      [
        WorkflowExplanationOutput(
          sourceActionIndex: 0,
          effect: .focusedApplicationWrite,
          availability: .available,
          configurationState: .notRequired,
          processingDestination: .focusedApplication
        )
      ]
    )
    XCTAssertEqual(receipt.processingDestinations, [.onDevice, .focusedApplication])
    XCTAssertEqual(receipt.status, .blocked)
    XCTAssertEqual(
      receipt.issues,
      [
        WorkflowExplanationIssue(
          kind: .privacyEvaluationUnavailable,
          component: .privacyPolicy
        )
      ]
    )
    await assertProbeWasNotInvoked(probe)
  }

  func testMultiEffectOutputsRetainSourceActionIndexBesideUnknownAction() async {
    let probe = WorkflowExplainProbe()
    let service = makeService(
      probe: probe,
      recognizerIDs: ["context.selection"],
      actionIDs: ["system-clipboard.copy", "unknown.CANARY-ACTION"]
    )
    let workflow = makeWorkflow(
      recognizerID: "context.selection",
      actions: [
        OutputActionReference(id: "system-clipboard.copy"),
        OutputActionReference(id: "unknown.CANARY-ACTION"),
      ]
    )

    let receipt = service.explainResolved(resolvedPlan(for: workflow))

    XCTAssertEqual(
      receipt.outputs,
      [
        WorkflowExplanationOutput(
          sourceActionIndex: 0,
          effect: .clipboardWrite,
          availability: .available,
          configurationState: .notRequired,
          processingDestination: .clipboard
        ),
        WorkflowExplanationOutput(
          sourceActionIndex: 1,
          effect: .unclassified,
          availability: .unclassified,
          configurationState: .unclassified,
          processingDestination: .unclassified
        ),
      ]
    )
    XCTAssertTrue(
      receipt.issues.contains(
        WorkflowExplanationIssue(
          kind: .componentUnclassified,
          component: .outputAction,
          componentIndex: 1
        )
      ))
    XCTAssertEqual(receipt.transforms.map(\.kind), [.vocabularyMapping])
    XCTAssertEqual(receipt.transforms.map(\.usage), [.conditional])
    XCTAssertTrue(receipt.processingDestinations.contains(.clipboard))
    XCTAssertFalse(receipt.processingDestinations.contains(.localStorage))
    await assertProbeWasNotInvoked(probe)
  }

  func testReceiptSerializationDoesNotLeakWorkflowOrConfigurationCanaries() async throws {
    let probe = WorkflowExplainProbe()
    let service = makeService(
      probe: probe,
      recognizerIDs: ["sherpa-onnx.local"],
      transformers: [("transformer.normalize", [.normalizeWhitespace])],
      actionIDs: [
        ExternalOutputActionID.webhookPost,
        ExternalOutputActionID.shortcutsRun,
        ExternalOutputActionID.markdownAppend,
        "unknown.CANARY-COMPONENT",
      ]
    )
    let workflow = WorkflowDefinition(
      name: "CANARY-WORKFLOW-NAME",
      trigger: .menuBar,
      plan: WorkflowPlan(
        setup: WorkflowSetupPhase(speechRoute: WorkflowSpeechRoute(recognizerID: "sherpa-onnx.local")),
        process: WorkflowProcessPhase(
          steps: [
            WorkflowProcessStep(kind: .recognizeSpeech), WorkflowProcessStep(kind: .resolveUncertainty, uncertaintyPolicy: .init()),
            WorkflowProcessStep(kind: .applyVocabulary),
          ]
            + ([
              PostProcessStep(
                kind: .normalizeWhitespace,
                prompt: "CANARY-PROMPT-CONTENT"
              )
            ]).map(WorkflowProcessStep.init)),
        output: WorkflowOutputPhase(
          actions: [
            OutputActionReference(
              id: ExternalOutputActionID.webhookPost,
              configuration: .init(webhookURL: "https://CANARY.example.invalid/hook", webhookHeadersJSON: #"{"Authorization":"Bearer CANARY-AUTH"}"#)
            ),
            OutputActionReference(
              id: ExternalOutputActionID.shortcutsRun,
              configuration: .init(shortcutName: "CANARY-SHORTCUT-NAME")
            ),
            OutputActionReference(
              id: ExternalOutputActionID.markdownAppend,
              configuration: .init(markdownPath: "/Users/CANARY/private.md")
            ),
            OutputActionReference(id: "unknown.CANARY-COMPONENT"),
          ], deliveryPolicy: .init(strategy: .immediate))),
      ui: WorkflowUIConfig(
        symbolName: "CANARY-SYMBOL",
        accentColorName: "CANARY-COLOR"
      ),
      properties: .init())

    let receipt = service.explainResolved(resolvedPlan(for: workflow))
    let json = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)

    for forbidden in [
      "CANARY",
      "://",
      "/Users",
      "Authorization",
      "Bearer",
      "unknown.",
    ] {
      XCTAssertFalse(json.contains(forbidden), "Receipt leaked \(forbidden)")
    }
    XCTAssertEqual(
      receipt.outputs.map(\.configurationState),
      [
        .configured,
        .configured,
        .configured,
        .unclassified,
      ])
    XCTAssertEqual(receipt.outputs.last?.effect, .unclassified)
    XCTAssertTrue(
      receipt.issues.contains(
        WorkflowExplanationIssue(
          kind: .componentUnclassified,
          component: .outputAction,
          componentIndex: 3
        )
      ))
    XCTAssertEqual(receipt.status, .blocked)
    await assertProbeWasNotInvoked(probe)
  }

  func testOutputDeclarationsArePreservedForEveryInvocation() {
    var workflow = makeWorkflow(recognizerID: "sherpa-onnx.local", actions: [OutputActionReference(id: "system-clipboard.copy")])
    workflow.properties.gesture = "fn-hold"
    workflow.properties.isBuiltin = true
    for trigger in [TriggerBinding.manual, .hotkey] {
      XCTAssertEqual(resolvedPlan(for: workflow, initiatedBy: trigger).executionWorkflow.plan.output.actions, workflow.plan.output.actions)
    }
  }

  func testManualInvocationOfHotkeyWorkflowControlsResolvedAndBlockedReceiptTrigger() async {
    let probe = WorkflowExplainProbe()
    let service = makeService(
      probe: probe,
      recognizerIDs: ["sherpa-onnx.local"],
      actionIDs: ["focused-application.insert"]
    )
    var workflow = makeWorkflow(
      recognizerID: "sherpa-onnx.local",
      actions: [OutputActionReference(id: "focused-application.insert")]
    )
    workflow.plan.setup.speechRoute?.selection = .automatic
    workflow.properties.gesture =
      "fn-hold"

    let resolved = resolvedPlan(
      for: workflow,
      initiatedBy: .manual,
      recognizer: .localSpeech
    )
    XCTAssertEqual(service.explainResolved(resolved).trigger, .manual)

    guard
      case .blocked(let blocked) = WorkflowExecutionPlanResolver.resolve(
        workflow,
        initiatedBy: .manual,
        recognizer: .unresolved
      )
    else {
      return XCTFail("Unresolved recognizer routing must remain blocked.")
    }
    XCTAssertEqual(blocked.trigger, .manual)
    await assertProbeWasNotInvoked(probe)
  }

  func testUnresolvedAutomaticSelectionsReturnTypedBlockedReceiptWithoutStaleClaims() throws {
    var workflow = makeWorkflow(
      recognizerID: "sherpa-onnx.local",
      actions: [OutputActionReference(id: "focused-application.insert")]
    )
    workflow.name = "CANARY-UNRESOLVED-WORKFLOW"
    workflow.plan.setup.speechRoute?.selection = .automatic
    workflow.properties.gesture =
      "fn-hold"

    guard
      case .blocked(let receipt) = WorkflowExecutionPlanResolver.resolve(
        workflow,
        initiatedBy: .hotkey,
        recognizer: .unresolved
      )
    else {
      return XCTFail("Unresolved automatic choices must not produce an execution plan.")
    }
    let json = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)

    XCTAssertEqual(receipt.status, .blocked)
    XCTAssertEqual(receipt.inputs.first?.category, .unclassified)
    XCTAssertTrue(receipt.outputs.isEmpty)
    XCTAssertEqual(receipt.processingDestinations, [.unclassified])
    XCTAssertTrue(
      receipt.issues.contains(
        WorkflowExplanationIssue(
          kind: .executionPlanUnresolved,
          component: .recognizer
        )
      ))
    XCTAssertFalse(json.contains("CANARY"))
    XCTAssertFalse(json.contains("Bearer"))
    XCTAssertFalse(receipt.inputs.contains { $0.processingDestination == .onDevice })
    XCTAssertFalse(receipt.outputs.contains { $0.effect == .focusedApplicationWrite })
  }

  func testKnownButMissingComponentsAreUnavailableAndBlocked() {
    let service = WorkflowExplainService(
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: [])
    )
    let workflow = makeWorkflow(
      recognizerID: "sherpa-onnx.local",
      steps: [PostProcessStep(kind: .normalizeWhitespace)],
      actions: [OutputActionReference(id: "record.store")]
    )

    let receipt = service.explainResolved(resolvedPlan(for: workflow))

    XCTAssertEqual(receipt.status, .blocked)
    XCTAssertEqual(receipt.inputs.first?.availability, .unavailable)
    XCTAssertEqual(
      receipt.transforms.first { $0.kind == .whitespaceNormalization }?.availability,
      .unavailable
    )
    XCTAssertEqual(receipt.outputs.first?.availability, .unavailable)
    XCTAssertEqual(
      receipt.issues.filter { $0.kind == .componentUnavailable }.map(\.component),
      [.recognizer, .transformer, .outputAction]
    )
  }

  func testDynamicLocalPrivacyEvaluationPromotesCompletePlanToReady() async {
    let probe = WorkflowExplainProbe()
    let service = makeService(
      probe: probe,
      recognizerIDs: ["sherpa-onnx.local"],
      actionIDs: ["focused-application.insert"]
    )
    let workflow = makeWorkflow(
      recognizerID: "sherpa-onnx.local",
      actions: [OutputActionReference(id: "focused-application.insert")]
    )

    let receipt = service.explainResolved(
      resolvedPlan(for: workflow),
      privacyEvaluation: PrivacyRunEvaluation(status: .ready)
    )

    XCTAssertEqual(receipt.status, .ready)
    XCTAssertTrue(receipt.issues.isEmpty)
    XCTAssertTrue(receipt.privacyReasons.isEmpty)
    XCTAssertEqual(
      service.privacyProcessingDestinations(for: resolvedPlan(for: workflow)),
      .classified([.localSpeech])
    )
    await assertProbeWasNotInvoked(probe)
  }

  func testDynamicRedactionsMakeContextInputsUnavailableWithoutLeakingContent() async throws {
    let probe = WorkflowExplainProbe()
    let service = makeService(
      probe: probe,
      recognizerIDs: ["context.selection"],
      actionIDs: ["system-clipboard.copy"]
    )
    let workflow = makeWorkflow(
      recognizerID: "context.selection",
      actions: [OutputActionReference(id: "system-clipboard.copy")]
    )
    var context = makeWorkflowPrivacyContext()
    context.focus.secureInput = true
    context.focus.selectedText = "CANARY-SELECTION"
    context.clipboard.plainText = "CANARY-CLIPBOARD"
    context.clipboard.captureTags = [.excludeFromWorkflowCapture]
    let gate = PrivacyRunGate(
      settingsProvider: {
        PrivacyPolicySettings(
          sensitiveAppRules: [],
          cloudConfirmationRequired: false
        )
      },
      cloudConfirmationProvider: { _, _, _, _ in
        XCTFail("Local preview must not request confirmation.")
        return false
      }
    )

    let evaluation = await gate.evaluate(context: context, workflow: workflow)
    let receipt = service.explainResolved(
      resolvedPlan(for: workflow),
      privacyEvaluation: evaluation
    )
    let json = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)

    XCTAssertEqual(receipt.status, .ready)
    XCTAssertEqual(receipt.inputs.map(\.availability), [.unavailable, .unavailable])
    XCTAssertTrue(
      receipt.issues.contains(
        WorkflowExplanationIssue(
          kind: .privacyInputRedacted,
          component: .privacyPolicy
        )))
    XCTAssertTrue(receipt.privacyReasons.contains(.secureInput))
    XCTAssertTrue(receipt.privacyReasons.contains(.itemTaggedExcludeFromWorkflowCapture))
    XCTAssertEqual(
      receipt.redactedInputCategories,
      [.focusedSelection, .clipboardText]
    )
    XCTAssertFalse(json.contains("CANARY"))
    XCTAssertFalse(json.contains("selectedText"))
    await assertProbeWasNotInvoked(probe)
  }

  func testDynamicPrivacyCannotOverrideMissingComponentsOrUnavailableEvaluation() {
    let service = WorkflowExplainService(
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: [])
    )
    let workflow = makeWorkflow(
      recognizerID: "sherpa-onnx.local",
      actions: [OutputActionReference(id: "focused-application.insert")]
    )
    let plan = resolvedPlan(for: workflow)

    let otherwiseReady = service.explainResolved(
      plan,
      privacyEvaluation: PrivacyRunEvaluation(status: .ready)
    )
    let unavailable = service.explainResolved(
      plan,
      privacyEvaluation: PrivacyRunEvaluation(
        status: .blocked,
        reasons: [.privacySettingsUnavailable]
      )
    )

    XCTAssertEqual(otherwiseReady.status, .blocked)
    XCTAssertTrue(otherwiseReady.issues.contains { $0.kind == .componentUnavailable })
    XCTAssertEqual(unavailable.status, .blocked)
    XCTAssertTrue(
      unavailable.issues.contains(
        WorkflowExplanationIssue(
          kind: .privacyEvaluationUnavailable,
          component: .privacyPolicy
        )))
    XCTAssertEqual(unavailable.privacyReasons, [.privacySettingsUnavailable])
  }

  func testUnknownRegisteredComponentsRemainUnclassifiedAndDoNotEchoIdentifiers() async throws {
    let probe = WorkflowExplainProbe()
    let unknownRecognizerID = "unknown.CANARY-RECOGNIZER"
    let unknownTransformerID = "unknown.CANARY-TRANSFORMER"
    let unknownActionID = "unknown.CANARY-ACTION"
    let service = makeService(
      probe: probe,
      recognizerIDs: [unknownRecognizerID],
      transformers: [(unknownTransformerID, [.llmRewrite])],
      actionIDs: [unknownActionID]
    )
    let workflow = makeWorkflow(
      recognizerID: unknownRecognizerID,
      steps: [PostProcessStep(kind: .llmRewrite, prompt: "CANARY-PROMPT", reasoning: .some(.none))],
      actions: [OutputActionReference(id: unknownActionID)]
    )

    let receipt = service.explainResolved(resolvedPlan(for: workflow))
    let json = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)

    XCTAssertEqual(receipt.status, .blocked)
    XCTAssertEqual(receipt.inputs.first?.availability, .unclassified)
    XCTAssertEqual(
      receipt.transforms.first { $0.kind == .languageModelRewrite }?.availability,
      .unclassified
    )
    XCTAssertEqual(receipt.outputs.first?.availability, .unclassified)
    XCTAssertEqual(receipt.issues.filter { $0.kind == .componentUnclassified }.count, 3)
    XCTAssertFalse(json.contains("CANARY"))
    XCTAssertFalse(json.contains("unknown."))
    await assertProbeWasNotInvoked(probe)
  }

  private func resolvedPlan(
    for workflow: WorkflowDefinition,
    initiatedBy trigger: TriggerBinding? = nil,
    recognizer: WorkflowRecognizerResolution = .declared
  ) -> WorkflowResolvedExecutionPlan {
    switch WorkflowExecutionPlanResolver.resolve(
      workflow,
      initiatedBy: trigger ?? workflow.trigger,
      recognizer: recognizer
    ) {
    case .resolved(let plan):
      return plan
    case .blocked:
      preconditionFailure("Expected a resolved workflow execution plan.")
    }
  }

  private func makeService(
    probe: WorkflowExplainProbe,
    recognizerIDs: [String],
    transformers: [(String, [PostProcessStepKind])] = [],
    actionIDs: [String]
  ) -> WorkflowExplainService {
    WorkflowExplainService(
      recognizerRegistry: SpeechRecognizerRegistry(
        recognizers: recognizerIDs.map {
          WorkflowExplainRecognizer(id: $0, probe: probe)
        }
      ),
      transformerRegistry: TextTransformerRegistry(
        transformers: transformers.map {
          WorkflowExplainTransformer(
            id: $0.0,
            supportedKinds: $0.1,
            probe: probe
          )
        }
      ),
      actionRegistry: OutputActionRegistry(
        actions: actionIDs.map { WorkflowExplainAction(id: $0, probe: probe) }
      )
    )
  }

  private func makeWorkflow(
    recognizerID: String,
    steps: [PostProcessStep] = [],
    actions: [OutputActionReference]
  ) -> WorkflowDefinition {
    var workflow = WorkflowDefinition(
      name: "Workflow",
      trigger: .hotkey,
      plan: WorkflowPlan(
        setup: WorkflowSetupPhase(speechRoute: WorkflowSpeechRoute(recognizerID: recognizerID)),
        process: WorkflowProcessPhase(
          steps: [
            WorkflowProcessStep(kind: .recognizeSpeech), WorkflowProcessStep(kind: .resolveUncertainty, uncertaintyPolicy: .init()),
            WorkflowProcessStep(kind: .applyVocabulary),
          ] + (steps).map(WorkflowProcessStep.init)), output: WorkflowOutputPhase(actions: actions, deliveryPolicy: .init(strategy: .immediate))),
      ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
    )
    workflow.plan.setup.vocabularyBindings = [
      VocabularyCollectionBinding(collectionID: VocabularyCollection.personalID)
    ]
    return workflow
  }

  private func assertProbeWasNotInvoked(
    _ probe: WorkflowExplainProbe,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    let counts = await probe.snapshot()
    XCTAssertEqual(counts.recognition, 0, file: file, line: line)
    XCTAssertEqual(counts.transformation, 0, file: file, line: line)
    XCTAssertEqual(counts.action, 0, file: file, line: line)
  }
}

private func makeWorkflowPrivacyContext() -> ContextSnapshot {
  ContextSnapshot(
    focus: FocusSnapshot(
      applicationName: "Notes",
      bundleIdentifier: "com.apple.Notes",
      processIdentifier: nil,
      focusedRole: nil,
      selectedText: "selected",
      secureInput: false
    ),
    clipboard: SystemClipboardSnapshot(plainText: "clipboard", changeCount: 1)
  )
}
