import XCTest
@testable import RillCore
@testable import RillUI

final class VoiceWorkflowPresentationTests: XCTestCase {

  @MainActor
  func testLegacyDraftValidatesLLMRewriteSteps() {

    var draft = WorkflowEditorDraft(
      name: "Custom Rewrite",
      postProcessSteps: [
        .init(kind: .normalizeWhitespace),
        .init(kind: .llmRewrite, prompt: "Rewrite as a concise release note.", reasoning: .some(.none)),
      ]
    )
    XCTAssertNil(draft.outputValidationError(language: .english))

    draft.postProcessSteps[1] = .init(
      kind: .llmAnswer,
      prompt: "Answer the request directly.", reasoning: .some(.high))
    XCTAssertNil(draft.outputValidationError(language: .english))

    draft.postProcessSteps[1].prompt = "  "
    XCTAssertEqual(
      draft.outputValidationError(language: .english),
      "Enter an instruction for every LLM rewrite step."
    )
    XCTAssertEqual(
      draft.outputValidationError(language: .simplifiedChinese),
      "请为每个大模型改写步骤填写指令。"
    )
  }

  func testVoiceTextStyleInferenceCoversBuiltInModes() {
    XCTAssertEqual(VoiceTextStyle.infer(from: []), .rawInput)
    XCTAssertEqual(
      VoiceTextStyle.infer(from: [PostProcessStep(kind: .normalizeWhitespace)]),
      .cleanInput
    )
    XCTAssertEqual(
      VoiceTextStyle.infer(from: [
        PostProcessStep(kind: .normalizeWhitespace),
        PostProcessStep(kind: .llmRewrite, prompt: VoiceTextStyle.formalWritingPrompt, reasoning: .some(.none)),
      ]),
      .formalWriting
    )
    XCTAssertEqual(
      VoiceTextStyle.infer(from: [PostProcessStep(kind: .llmRewrite, prompt: VoiceTextStyle.translatePrompt, reasoning: .some(.none))]),
      .translateInput
    )
    XCTAssertEqual(
      VoiceTextStyle.infer(from: [PostProcessStep(kind: .llmRewrite, prompt: VoiceTextStyle.commandPrompt, reasoning: .some(.none))]),
      .commandMode
    )
  }

  func testDraftTextStyleSelectionWritesCanonicalPipelineAndMetadata() {
    var draft = WorkflowEditorDraft(name: "Command Helper")
    draft.textStyle = .commandMode

    XCTAssertEqual(draft.textStyle, .commandMode)
    XCTAssertTrue(draft.postProcessSteps.contains { $0.kind == .llmRewrite })

    let workflow = draft.makeWorkflow(id: UUID(), hotkeyGesture: "fn-hold")

    XCTAssertEqual(workflow.properties.textStyle, VoiceTextStyle.commandMode.rawValue)
    XCTAssertEqual(VoiceTextStyle.infer(from: workflow), .commandMode)
  }

  func testDraftSpeechRouteNormalizesLegacyAutomaticChoiceToLocalASR() {
    let draft = WorkflowEditorDraft(
      name: "Local Meeting",
      recognizer: .automatic,
      speechLanguageOverride: "zh-CN",
      destination: .saveToQueue
    )

    let workflow = draft.makeWorkflow(id: UUID(), hotkeyGesture: "fn-hold")

    XCTAssertEqual(workflow.plan.setup.speechRoute?.recognizerID, "local-speech")
    XCTAssertEqual(workflow.plan.setup.speechRoute?.selection, .automatic)

    XCTAssertEqual(workflow.plan.setup.speechRoute?.language, "zh-CN")

    let roundTrip = WorkflowEditorDraft(workflow: workflow)
    XCTAssertEqual(roundTrip?.recognizer, .localSpeech)
    XCTAssertEqual(roundTrip?.speechLanguageOverride, "zh-CN")
  }

  func testLivePreviewPlacementDefaultsToOverlayAndRoundTripsCursor() throws {
    let legacyWorkflow = WorkflowEditorDraft(name: "Legacy")
      .makeWorkflow(id: UUID(), hotkeyGesture: "fn-hold")
    XCTAssertEqual(
      WorkflowEditorDraft(workflow: legacyWorkflow)?.livePreviewPlacement,
      .overlay
    )

    let draft = WorkflowEditorDraft(
      name: "Cursor Preview",
      livePreviewEnabled: true,
      livePreviewPlacement: .cursor
    )
    let workflow = draft.makeWorkflow(id: UUID(), hotkeyGesture: "fn-hold")

    XCTAssertEqual(
      workflow.plan.setup.speechRoute?.livePreviewPlacement.rawValue,
      LivePreviewPlacement.cursor.rawValue
    )
    XCTAssertEqual(
      WorkflowEditorDraft(workflow: workflow)?.livePreviewPlacement,
      .cursor
    )
  }

  func testMenuTitleUsesStyleWithoutDuplicatingBuiltinNames() {
    let cleanWorkflow = WorkflowDefinition(
      name: "Speech to Text",
      titleKey: .pushToTalkCapture,
      trigger: .hotkey,
      plan: WorkflowPlan(
        setup: WorkflowSetupPhase(speechRoute: WorkflowSpeechRoute(recognizerID: "sherpa-onnx.local")),
        process: WorkflowProcessPhase(
          steps: [
            WorkflowProcessStep(kind: .recognizeSpeech), WorkflowProcessStep(kind: .resolveUncertainty, uncertaintyPolicy: .init()),
            WorkflowProcessStep(kind: .applyVocabulary),
          ] + (VoiceTextStyle.cleanInput.workflowSteps).map(WorkflowProcessStep.init)),
        output: WorkflowOutputPhase(actions: [OutputActionReference(id: "focused-application.insert")], deliveryPolicy: .init(strategy: .immediate))),
      ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "red"),
      properties: .init(textStyle: VoiceTextStyle.cleanInput.rawValue))
    let customWorkflow = WorkflowDefinition(
      name: "Meeting Note Draft",
      trigger: .manual,
      plan: WorkflowPlan(
        setup: WorkflowSetupPhase(speechRoute: WorkflowSpeechRoute(recognizerID: "sherpa-onnx.local")),
        process: WorkflowProcessPhase(
          steps: [
            WorkflowProcessStep(kind: .recognizeSpeech), WorkflowProcessStep(kind: .resolveUncertainty, uncertaintyPolicy: .init()),
            WorkflowProcessStep(kind: .applyVocabulary),
          ] + (VoiceTextStyle.formalWriting.workflowSteps).map(WorkflowProcessStep.init)),
        output: WorkflowOutputPhase(actions: [OutputActionReference(id: "record.store")], deliveryPolicy: .init(strategy: .immediate))),
      ui: WorkflowUIConfig(symbolName: "wand.and.stars", accentColorName: "purple")
    )

    XCTAssertEqual(
      VoiceWorkflowPresentation(workflow: cleanWorkflow).menuTitle(
        workflowName: L10n.workflowName(cleanWorkflow.presentation, language: .english),
        language: .english
      ),
      "Clean Input"
    )
    XCTAssertEqual(
      VoiceWorkflowPresentation(workflow: customWorkflow).menuTitle(
        workflowName: customWorkflow.name,
        language: .english
      ),
      "Formal Writing — Meeting Note Draft"
    )
  }

  func testExternalOutputDestinationsRoundTripConfiguration() {
    let shortcutDraft = WorkflowEditorDraft(
      name: "Shortcut Capture",
      destination: .runShortcut,
      shortcutName: " Capture Note "
    )
    let shortcutWorkflow = shortcutDraft.makeWorkflow(id: UUID(), hotkeyGesture: "fn-hold")
    let shortcutAction = shortcutWorkflow.plan.output.actions.first
    XCTAssertEqual(shortcutAction?.id, ExternalOutputActionID.shortcutsRun)
    XCTAssertEqual(
      shortcutAction?.configuration.shortcutName,
      "Capture Note"
    )
    XCTAssertEqual(WorkflowEditorDraft(workflow: shortcutWorkflow)?.shortcutName, "Capture Note")

    let markdownDraft = WorkflowEditorDraft(
      name: "Markdown Capture",
      destination: .appendToMarkdown,
      markdownAppendPath: " ~/Notes/Capture.md "
    )
    let markdownWorkflow = markdownDraft.makeWorkflow(id: UUID(), hotkeyGesture: "fn-hold")
    let markdownAction = markdownWorkflow.plan.output.actions.first
    XCTAssertEqual(markdownAction?.id, ExternalOutputActionID.markdownAppend)
    XCTAssertEqual(
      markdownAction?.configuration.markdownPath,
      "~/Notes/Capture.md"
    )
    XCTAssertEqual(WorkflowEditorDraft(workflow: markdownWorkflow)?.markdownAppendPath, "~/Notes/Capture.md")
  }

  func testSpeechOnlyVoiceAssistantCanBeEditedAndRoundTripsOneTTSAction() throws {
    let assistant = WorkflowDefinition(
      name: "Voice Assistant",
      titleKey: .voiceAssistant,
      trigger: .wakeWord,
      plan: WorkflowPlan(
        setup: WorkflowSetupPhase(
          speechRoute: WorkflowSpeechRoute(
            selection: .automatic,
            recognizerID: "sherpa-onnx.local"
          ),
          vocabularyBindings: [
            VocabularyCollectionBinding(
              collectionID: VocabularyCollection.personalID
            )
          ],
          wakeWord: WakeWordConfiguration(phrases: ["Hey Rill"])
        ),
        process: WorkflowProcessPhase(steps: [
          WorkflowProcessStep(kind: .recognizeSpeech),
          WorkflowProcessStep(kind: .applyVocabulary),
          WorkflowProcessStep(kind: .normalizeWhitespace),
          WorkflowProcessStep(
            kind: .llmRewrite,
            prompt: "Answer briefly for speech.", reasoning: .some(.none)),
        ]),
        output: WorkflowOutputPhase(actions: [
          OutputActionReference(
            id: SpeechOutputActionID.speak,
            configuration: .init(voice: Qwen3TTSVoice.ryan.rawValue)
          )
        ])
      ),
      ui: WorkflowUIConfig(symbolName: "sparkles", accentColorName: "purple")
    )

    let draft = try XCTUnwrap(WorkflowEditorDraft(workflow: assistant))

    XCTAssertEqual(draft.eventType, .wakeWord)
    XCTAssertEqual(draft.destination, .speakOnly)
    XCTAssertTrue(draft.speaksResult)
    XCTAssertEqual(draft.speechVoice, .ryan)
    XCTAssertEqual(draft.postProcessSteps.map(\.kind), [.normalizeWhitespace, .llmRewrite])

    let saved = draft.makeWorkflow(id: UUID(), hotkeyGesture: "fn-hold")
    XCTAssertEqual(saved.plan.output.actions.count, 1)
    XCTAssertEqual(saved.plan.output.actions.first?.id, SpeechOutputActionID.speak)
    XCTAssertEqual(
      saved.plan.output.actions.first?
        .configuration.voice,
      Qwen3TTSVoice.ryan.rawValue
    )
    XCTAssertEqual(saved.plan.process.steps.map(\.kind), assistant.plan.process.steps.map(\.kind))
  }

  func testExternalOutputValidationAndLabelsAreLocalized() {
    let draft = WorkflowEditorDraft(name: "Legacy Webhook", destination: .sendToWebhook)
    XCTAssertEqual(
      draft.outputValidationError(language: .english),
      "Webhook workflows are unavailable until endpoint and header credentials use secure storage."
    )

    let legacyWebhookWorkflow = draft.makeWorkflow(id: UUID(), hotkeyGesture: "fn-hold")
    XCTAssertNil(WorkflowEditorDraft(workflow: legacyWebhookWorkflow))

    var shortcutDraft = WorkflowEditorDraft(name: "Shortcut", destination: .runShortcut)
    XCTAssertEqual(
      shortcutDraft.outputValidationError(language: .english),
      "Enter a Shortcut name before saving."
    )
    shortcutDraft.shortcutName = "Capture Note"
    XCTAssertNil(shortcutDraft.outputValidationError(language: .english))

    var markdownDraft = WorkflowEditorDraft(name: "Markdown", destination: .appendToMarkdown)
    markdownDraft.markdownAppendPath = "~/Notes/Capture.txt"
    XCTAssertEqual(
      markdownDraft.outputValidationError(language: .english),
      "Markdown file path must end in .md or .markdown."
    )
    markdownDraft.markdownAppendPath = "~/Notes/Capture.md"
    XCTAssertNil(markdownDraft.outputValidationError(language: .english))

    XCTAssertEqual(
      L10n.actionName(ExternalOutputActionID.markdownAppend, language: .english),
      "Append to Markdown"
    )
  }
}
