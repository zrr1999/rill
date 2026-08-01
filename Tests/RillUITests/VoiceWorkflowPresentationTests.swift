import XCTest
@testable import RillCore
@testable import RillUI

final class VoiceWorkflowPresentationTests: XCTestCase {
    @MainActor
    func testWorkflowEditorExposesAndValidatesLLMRewriteSteps() {
        XCTAssertTrue(VoiceTextStyle.selectableCases.contains(.formalWriting))
        XCTAssertTrue(VoiceTextStyle.selectableCases.contains(.translateInput))
        XCTAssertTrue(VoiceTextStyle.selectableCases.contains(.commandMode))
        XCTAssertTrue(VoiceTextStyle.selectableCases.contains(.custom))
        XCTAssertTrue(WorkflowsView.availableStepKinds.contains(.llmRewrite))

        var draft = WorkflowEditorDraft(
            name: "Custom Rewrite",
            postProcessSteps: [
                .init(kind: .normalizeWhitespace),
                .init(kind: .llmRewrite, prompt: "Rewrite as a concise release note."),
            ]
        )
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
                PostProcessStep(kind: .llmRewrite, prompt: VoiceTextStyle.formalWritingPrompt),
            ]),
            .formalWriting
        )
        XCTAssertEqual(
            VoiceTextStyle.infer(from: [PostProcessStep(kind: .llmRewrite, prompt: VoiceTextStyle.translatePrompt)]),
            .translateInput
        )
        XCTAssertEqual(
            VoiceTextStyle.infer(from: [PostProcessStep(kind: .llmRewrite, prompt: VoiceTextStyle.commandPrompt)]),
            .commandMode
        )
    }

    func testDraftTextStyleSelectionWritesCanonicalPipelineAndMetadata() {
        var draft = WorkflowEditorDraft(name: "Command Helper")
        draft.textStyle = .commandMode

        XCTAssertEqual(draft.textStyle, .commandMode)
        XCTAssertTrue(draft.postProcessSteps.contains { $0.kind == .llmRewrite })

        let workflow = draft.makeWorkflow(id: UUID(), hotkeyGesture: "fn-hold")

        XCTAssertEqual(workflow.metadata[WorkflowMetadataKey.textStyle], VoiceTextStyle.commandMode.rawValue)
        XCTAssertEqual(VoiceTextStyle.infer(from: workflow), .commandMode)
    }

    func testWorkflowDetailUsesModeAndStyleLanguage() {
        let workflow = WorkflowDefinition(
            name: "Translate Input",
            titleKey: .translateInput,
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: "sherpa-onnx.local",
                postProcessSteps: VoiceTextStyle.translateInput.workflowSteps,
                outputActions: [OutputActionReference(id: "stack.push")],
                deliveryPolicy: DeliveryPolicy(strategy: .stackFirst)
            ),
            ui: WorkflowUIConfig(symbolName: "globe", accentColorName: "blue"),
            metadata: [WorkflowMetadataKey.textStyle: VoiceTextStyle.translateInput.rawValue]
        )

        let englishDetail = UIStrings.workflowDetail(workflow, language: .english)

        XCTAssertEqual(UIStrings.workflowName(workflow.presentation, language: .english), "Translate Input")
        XCTAssertEqual(UIStrings.workflowName(workflow.presentation, language: .simplifiedChinese), "翻译输入")
        XCTAssertTrue(englishDetail.contains("Mode: Translate Input"), englishDetail)
        XCTAssertTrue(englishDetail.contains("Speech: Local Speech"), englishDetail)
        XCTAssertTrue(englishDetail.contains("Language: Auto language"), englishDetail)
        XCTAssertTrue(UIStrings.workflowDetail(workflow, language: .simplifiedChinese).contains("模式：翻译输入"))
    }

    func testDraftSpeechRouteWritesPerWorkflowLocalASRMetadata() {
        let draft = WorkflowEditorDraft(
            name: "Local Meeting",
            recognizer: .automatic,
            speechLanguageOverride: "zh-CN",
            localSpeechModelOverride: "distil-large-v3",
            destination: .saveToQueue
        )

        let workflow = draft.makeWorkflow(id: UUID(), hotkeyGesture: "fn-hold")

        XCTAssertEqual(workflow.pipeline.recognizerID, "sherpa-onnx.local")
        XCTAssertEqual(workflow.metadata[WorkflowMetadataKey.recognizerSelectionMode], "auto")
        XCTAssertEqual(workflow.metadata[WorkflowMetadataKey.languageOverride], "zh-CN")
        XCTAssertEqual(workflow.metadata[WorkflowMetadataKey.localSpeechModelOverride], "distil-large-v3")
        XCTAssertNil(workflow.metadata[WorkflowMetadataKey.legacyWhisperKitModelOverride])

        let roundTrip = WorkflowEditorDraft(workflow: workflow)
        XCTAssertEqual(roundTrip?.recognizer, .automatic)
        XCTAssertEqual(roundTrip?.speechLanguageOverride, "zh-CN")
        XCTAssertEqual(roundTrip?.localSpeechModelOverride, "distil-large-v3")
    }

    func testMenuTitleUsesStyleWithoutDuplicatingBuiltinNames() {
        let cleanWorkflow = WorkflowDefinition(
            name: "Speech to Text",
            titleKey: .pushToTalkCapture,
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "sherpa-onnx.local",
                postProcessSteps: VoiceTextStyle.cleanInput.workflowSteps,
                outputActions: [OutputActionReference(id: "inject.text")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "red"),
            metadata: [WorkflowMetadataKey.textStyle: VoiceTextStyle.cleanInput.rawValue]
        )
        let customWorkflow = WorkflowDefinition(
            name: "Meeting Note Draft",
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: "sherpa-onnx.local",
                postProcessSteps: VoiceTextStyle.formalWriting.workflowSteps,
                outputActions: [OutputActionReference(id: "stack.push")]
            ),
            ui: WorkflowUIConfig(symbolName: "wand.and.stars", accentColorName: "purple")
        )

        XCTAssertEqual(
            VoiceWorkflowPresentation(workflow: cleanWorkflow).menuTitle(
                workflowName: UIStrings.workflowName(cleanWorkflow.presentation, language: .english),
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
        let shortcutAction = shortcutWorkflow.pipeline.outputActions.first
        XCTAssertEqual(shortcutAction?.id, ExternalOutputActionID.shortcutsRun)
        XCTAssertEqual(
            shortcutAction?.configuration[ExternalOutputActionConfigurationKey.shortcutName],
            "Capture Note"
        )
        XCTAssertEqual(WorkflowEditorDraft(workflow: shortcutWorkflow)?.shortcutName, "Capture Note")

        let markdownDraft = WorkflowEditorDraft(
            name: "Markdown Capture",
            destination: .appendToMarkdown,
            markdownAppendPath: " ~/Notes/Capture.md "
        )
        let markdownWorkflow = markdownDraft.makeWorkflow(id: UUID(), hotkeyGesture: "fn-hold")
        let markdownAction = markdownWorkflow.pipeline.outputActions.first
        XCTAssertEqual(markdownAction?.id, ExternalOutputActionID.markdownAppend)
        XCTAssertEqual(
            markdownAction?.configuration[ExternalOutputActionConfigurationKey.markdownAppendPath],
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
                        prompt: "Answer briefly for speech."
                    ),
                ]),
                output: WorkflowOutputPhase(actions: [
                    OutputActionReference(
                        id: SpeechOutputActionID.speak,
                        configuration: [
                            SpeechOutputActionConfigurationKey.provider:
                                SpeechSynthesisProvider.automatic.rawValue,
                            SpeechOutputActionConfigurationKey.voice:
                                Qwen3TTSVoice.ryan.rawValue,
                        ]
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
                .configuration[SpeechOutputActionConfigurationKey.voice],
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
        XCTAssertFalse(WorkflowEditorDraft.DestinationChoice.productionChoices.contains(.sendToWebhook))
        XCTAssertTrue(WorkflowEditorDraft.DestinationChoice.productionChoices.contains(.runShortcut))
        XCTAssertTrue(WorkflowEditorDraft.DestinationChoice.productionChoices.contains(.appendToMarkdown))
        XCTAssertTrue(WorkflowEditorDraft.DestinationChoice.productionChoices.contains(.speakOnly))

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

        XCTAssertEqual(UIStrings.editorDestination(.runShortcut, language: .english), "Run macOS Shortcut")
        XCTAssertEqual(
            UIStrings.editorDestination(.appendToMarkdown, language: .simplifiedChinese),
            "追加到 Obsidian/Markdown"
        )
        XCTAssertEqual(
            UIStrings.actionName(ExternalOutputActionID.markdownAppend, language: .english),
            "Append to Markdown"
        )
        XCTAssertEqual(
            UIStrings.externalOutputHint(.appendToMarkdown, language: .english),
            "Atomically appends to an Obsidian-compatible note in an existing folder. Linked paths and files over 64 MiB are rejected."
        )
        XCTAssertEqual(
            UIStrings.externalOutputHint(.appendToMarkdown, language: .simplifiedChinese),
            "原子追加到现有文件夹中的 Obsidian 兼容笔记；拒绝链接路径和超过 64 MiB 的文件。"
        )
    }
}
