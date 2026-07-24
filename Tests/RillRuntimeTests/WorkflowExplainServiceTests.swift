import Foundation
import XCTest
@testable import RillCore
@testable import RillRuntime

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

    func execute(text: String, context: ActionContext) async throws -> ActionResult {
        await probe.recordAction()
        return .copiedToClipboard
    }
}

final class WorkflowExplainServiceTests: XCTestCase {
    func testKnownLocalWorkflowProducesAccurateContentFreeStaticPlan() async throws {
        let probe = WorkflowExplainProbe()
        let service = makeService(
            probe: probe,
            recognizerIDs: ["sherpa-onnx.local"],
            transformers: [("transformer.normalize", [.normalizeWhitespace])],
            actionIDs: ["inject.text"]
        )
        let workflow = makeWorkflow(
            recognizerID: "sherpa-onnx.local",
            steps: [PostProcessStep(kind: .normalizeWhitespace, prompt: "must not escape")],
            actions: [OutputActionReference(id: "inject.text")]
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
                ),
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
                ),
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
                ),
            ]
        )
        await assertProbeWasNotInvoked(probe)
    }

    func testMultiEffectOutputsRetainSourceActionIndexBesideUnknownAction() async {
        let probe = WorkflowExplainProbe()
        let service = makeService(
            probe: probe,
            recognizerIDs: ["context.selection"],
            actionIDs: ["clipboard.copy", "unknown.CANARY-ACTION"]
        )
        let workflow = makeWorkflow(
            recognizerID: "context.selection",
            actions: [
                OutputActionReference(id: "clipboard.copy"),
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
                    sourceActionIndex: 0,
                    effect: .clipboardHistoryWrite,
                    availability: .available,
                    configurationState: .notRequired,
                    processingDestination: .localStorage
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
        XCTAssertTrue(receipt.issues.contains(
            WorkflowExplanationIssue(
                kind: .componentUnclassified,
                component: .outputAction,
                componentIndex: 1
            )
        ))
        XCTAssertEqual(receipt.transforms.map(\.kind), [.vocabularyMapping])
        XCTAssertEqual(receipt.transforms.map(\.usage), [.conditional])
        XCTAssertTrue(receipt.processingDestinations.contains(.clipboard))
        XCTAssertTrue(receipt.processingDestinations.contains(.localStorage))
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
            pipeline: PipelineDeclaration(
                recognizerID: "sherpa-onnx.local",
                postProcessSteps: [
                    PostProcessStep(
                        kind: .normalizeWhitespace,
                        prompt: "CANARY-PROMPT-CONTENT"
                    ),
                ],
                outputActions: [
                    OutputActionReference(
                        id: ExternalOutputActionID.webhookPost,
                        configuration: [
                            ExternalOutputActionConfigurationKey.webhookURL:
                                "https://CANARY.example.invalid/hook",
                            ExternalOutputActionConfigurationKey.webhookHeadersJSON:
                                #"{"Authorization":"Bearer CANARY-AUTH"}"#,
                        ]
                    ),
                    OutputActionReference(
                        id: ExternalOutputActionID.shortcutsRun,
                        configuration: [
                            ExternalOutputActionConfigurationKey.shortcutName:
                                "CANARY-SHORTCUT-NAME",
                        ]
                    ),
                    OutputActionReference(
                        id: ExternalOutputActionID.markdownAppend,
                        configuration: [
                            ExternalOutputActionConfigurationKey.markdownAppendPath:
                                "/Users/CANARY/private.md",
                        ]
                    ),
                    OutputActionReference(id: "unknown.CANARY-COMPONENT"),
                ]
            ),
            ui: WorkflowUIConfig(
                symbolName: "CANARY-SYMBOL",
                accentColorName: "CANARY-COLOR"
            ),
            metadata: [
                "CANARY-METADATA-KEY": "CANARY-METADATA-VALUE",
                "secret": "Bearer CANARY-METADATA-TOKEN",
            ]
        )

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
        XCTAssertEqual(receipt.outputs.map(\.configurationState), [
            .configured,
            .configured,
            .configured,
            .unclassified,
        ])
        XCTAssertEqual(receipt.outputs.last?.effect, .unclassified)
        XCTAssertTrue(receipt.issues.contains(
            WorkflowExplanationIssue(
                kind: .componentUnclassified,
                component: .outputAction,
                componentIndex: 3
            )
        ))
        XCTAssertEqual(receipt.status, .blocked)
        await assertProbeWasNotInvoked(probe)
    }

    func testLegacyWorkflowIsBlockedBySharedExecutionPolicy() {
        var workflow = makeWorkflow(
            recognizerID: "context.selection",
            actions: [OutputActionReference(id: "clipboard.copy")]
        )
        workflow.metadata["eventType"] = "groupItemCreated"

        guard case .blocked(let receipt) = WorkflowExecutionPlanResolver.resolve(
            workflow,
            initiatedBy: .hotkey,
            recognizer: .declared,
            output: .declared
        ) else {
            return XCTFail("Legacy workflows must not produce execution plans.")
        }

        XCTAssertEqual(receipt.status, .blocked)
        XCTAssertTrue(receipt.issues.contains(
            WorkflowExplanationIssue(
                kind: .legacyWorkflowUnsupported,
                component: .workflow
            )
        ))
        XCTAssertEqual(
            WorkflowExecutionPolicy.issue(for: workflow),
            .legacyClipboardAutomationUnsupported
        )
    }

    func testKnownCloudAndExternalOutputsReportDestinationsAndConfigurationIssues() async {
        let probe = WorkflowExplainProbe()
        let service = makeService(
            probe: probe,
            recognizerIDs: ["deepgram.prerecorded"],
            actionIDs: [
                ExternalOutputActionID.webhookPost,
                ExternalOutputActionID.markdownAppend,
            ]
        )
        let workflow = makeWorkflow(
            recognizerID: "deepgram.prerecorded",
            actions: [
                OutputActionReference(id: ExternalOutputActionID.webhookPost),
                OutputActionReference(
                    id: ExternalOutputActionID.markdownAppend,
                    configuration: [
                        ExternalOutputActionConfigurationKey.markdownAppendPath:
                            "/Users/CANARY/not-markdown.txt",
                    ]
                ),
            ]
        )

        let receipt = service.explainResolved(resolvedPlan(for: workflow))

        XCTAssertEqual(
            receipt.inputs.map(\.category),
            [.microphoneAudio, .recognitionHints]
        )
        XCTAssertEqual(receipt.inputs.map(\.usage), [.required, .conditional])
        XCTAssertTrue(receipt.inputs.allSatisfy { $0.processingDestination == .cloudService })
        XCTAssertEqual(receipt.outputs.map(\.processingDestination), [.remoteEndpoint, .localFile])
        XCTAssertEqual(receipt.outputs.map(\.sourceActionIndex), [0, 1])
        XCTAssertEqual(receipt.outputs.map(\.configurationState), [.missing, .invalid])
        XCTAssertTrue(receipt.issues.contains(
            WorkflowExplanationIssue(
                kind: .configurationMissing,
                component: .outputAction,
                componentIndex: 0
            )
        ))
        XCTAssertTrue(receipt.issues.contains(
            WorkflowExplanationIssue(
                kind: .configurationInvalid,
                component: .outputAction,
                componentIndex: 1
            )
        ))
        XCTAssertEqual(receipt.status, .blocked)
        await assertProbeWasNotInvoked(probe)
    }

    func testAutomaticSelectionsMustBeExplicitlyResolvedToCloudAndStack() async {
        let probe = WorkflowExplainProbe()
        let service = makeService(
            probe: probe,
            recognizerIDs: ["deepgram.prerecorded"],
            actionIDs: ["stack.push"]
        )
        var workflow = makeWorkflow(
            recognizerID: "sherpa-onnx.local",
            actions: [OutputActionReference(id: "inject.text")]
        )
        workflow.metadata[WorkflowMetadataKey.recognizerSelectionMode] = "auto"
        workflow.metadata[WorkflowMetadataKey.settingsExposeOutputMode] = "true"
        workflow.metadata[WorkflowMetadataKey.catalog] = BuiltinWorkflowRoutingValue.catalog
        workflow.metadata[WorkflowMetadataKey.triggerGesture] =
            BuiltinWorkflowRoutingValue.pushToTalkGesture
        workflow.metadata[WorkflowMetadataKey.builtinKind] = "push-to-talk.dictation"

        let plan = resolvedPlan(
            for: workflow,
            recognizer: .cloudSpeech,
            output: .builtinSaveToVoiceGroup
        )
        let receipt = service.explainResolved(plan)

        XCTAssertEqual(
            receipt.inputs.map(\.category),
            [.microphoneAudio, .recognitionHints]
        )
        XCTAssertEqual(receipt.inputs.map(\.usage), [.required, .conditional])
        XCTAssertTrue(receipt.inputs.allSatisfy { $0.processingDestination == .cloudService })
        XCTAssertEqual(
            receipt.outputs,
            [
                WorkflowExplanationOutput(
                    sourceActionIndex: 0,
                    effect: .deliveryStackWrite,
                    availability: .available,
                    configurationState: .notRequired,
                    processingDestination: .localStorage
                ),
            ]
        )
        XCTAssertFalse(receipt.outputs.contains { $0.effect == .focusedApplicationWrite })
        await assertProbeWasNotInvoked(probe)
    }

    func testOutputModeDoesNotRewriteManualInvocationOrCustomMetadata() {
        var builtinWorkflow = makeWorkflow(
            recognizerID: "sherpa-onnx.local",
            actions: [OutputActionReference(id: "inject.text")]
        )
        builtinWorkflow.metadata[WorkflowMetadataKey.catalog] = BuiltinWorkflowRoutingValue.catalog
        builtinWorkflow.metadata[WorkflowMetadataKey.triggerGesture] =
            BuiltinWorkflowRoutingValue.pushToTalkGesture
        builtinWorkflow.metadata[WorkflowMetadataKey.builtinKind] = "push-to-talk.dictation"

        let manuallyInitiated = resolvedPlan(
            for: builtinWorkflow,
            initiatedBy: .manual,
            output: .builtinSaveToVoiceGroup
        ).executionWorkflow
        XCTAssertEqual(manuallyInitiated.pipeline.outputActions.map(\.id), ["inject.text"])

        var customWorkflow = makeWorkflow(
            recognizerID: "sherpa-onnx.local",
            actions: [OutputActionReference(id: "clipboard.copy")]
        )
        customWorkflow.metadata[WorkflowMetadataKey.settingsExposeOutputMode] = "true"
        customWorkflow.metadata[WorkflowMetadataKey.catalog] = "custom"
        customWorkflow.metadata[WorkflowMetadataKey.triggerGesture] =
            BuiltinWorkflowRoutingValue.pushToTalkGesture
        customWorkflow.metadata[WorkflowMetadataKey.builtinKind] = "push-to-talk.custom"

        let customResolved = resolvedPlan(
            for: customWorkflow,
            initiatedBy: .hotkey,
            output: .builtinSaveToVoiceGroup
        ).executionWorkflow
        XCTAssertEqual(customResolved.pipeline.outputActions.map(\.id), ["clipboard.copy"])
    }

    func testManualInvocationOfHotkeyWorkflowControlsResolvedAndBlockedReceiptTrigger() async {
        let probe = WorkflowExplainProbe()
        let service = makeService(
            probe: probe,
            recognizerIDs: ["sherpa-onnx.local"],
            actionIDs: ["inject.text"]
        )
        var workflow = makeWorkflow(
            recognizerID: "sherpa-onnx.local",
            actions: [OutputActionReference(id: "inject.text")]
        )
        workflow.metadata[WorkflowMetadataKey.recognizerSelectionMode] = "auto"
        workflow.metadata[WorkflowMetadataKey.catalog] = BuiltinWorkflowRoutingValue.catalog
        workflow.metadata[WorkflowMetadataKey.triggerGesture] =
            BuiltinWorkflowRoutingValue.pushToTalkGesture
        workflow.metadata[WorkflowMetadataKey.builtinKind] = "push-to-talk.dictation"

        let resolved = resolvedPlan(
            for: workflow,
            initiatedBy: .manual,
            recognizer: .localSpeech,
            output: .builtinSaveToVoiceGroup
        )
        XCTAssertEqual(service.explainResolved(resolved).trigger, .manual)

        guard case .blocked(let blocked) = WorkflowExecutionPlanResolver.resolve(
            workflow,
            initiatedBy: .manual,
            recognizer: .unresolved,
            output: .builtinSaveToVoiceGroup
        ) else {
            return XCTFail("Unresolved recognizer routing must remain blocked.")
        }
        XCTAssertEqual(blocked.trigger, .manual)
        await assertProbeWasNotInvoked(probe)
    }

    func testUnresolvedAutomaticSelectionsReturnTypedBlockedReceiptWithoutStaleClaims() throws {
        var workflow = makeWorkflow(
            recognizerID: "sherpa-onnx.local",
            actions: [OutputActionReference(id: "inject.text")]
        )
        workflow.name = "CANARY-UNRESOLVED-WORKFLOW"
        workflow.metadata[WorkflowMetadataKey.recognizerSelectionMode] = "auto"
        workflow.metadata[WorkflowMetadataKey.settingsExposeOutputMode] = "true"
        workflow.metadata[WorkflowMetadataKey.catalog] = BuiltinWorkflowRoutingValue.catalog
        workflow.metadata[WorkflowMetadataKey.triggerGesture] =
            BuiltinWorkflowRoutingValue.pushToTalkGesture
        workflow.metadata[WorkflowMetadataKey.builtinKind] = "push-to-talk.dictation"
        workflow.metadata["CANARY-SECRET"] = "Bearer CANARY-TOKEN"

        guard case .blocked(let receipt) = WorkflowExecutionPlanResolver.resolve(
            workflow,
            initiatedBy: .hotkey,
            recognizer: .unresolved,
            output: .unresolved
        ) else {
            return XCTFail("Unresolved automatic choices must not produce an execution plan.")
        }
        let json = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)

        XCTAssertEqual(receipt.status, .blocked)
        XCTAssertEqual(receipt.inputs.first?.category, .unclassified)
        XCTAssertEqual(receipt.outputs.first?.effect, .unclassified)
        XCTAssertEqual(receipt.processingDestinations, [.unclassified])
        XCTAssertTrue(receipt.issues.contains(
            WorkflowExplanationIssue(
                kind: .executionPlanUnresolved,
                component: .recognizer
            )
        ))
        XCTAssertTrue(receipt.issues.contains(
            WorkflowExplanationIssue(
                kind: .executionPlanUnresolved,
                component: .outputAction
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
            actions: [OutputActionReference(id: "stack.push")]
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
            actionIDs: ["inject.text"]
        )
        let workflow = makeWorkflow(
            recognizerID: "sherpa-onnx.local",
            actions: [OutputActionReference(id: "inject.text")]
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

    func testDynamicCloudPrivacyEvaluationRequiresConfirmationWithoutExecutingComponents() async {
        let probe = WorkflowExplainProbe()
        let service = makeService(
            probe: probe,
            recognizerIDs: ["deepgram.prerecorded"],
            actionIDs: [ExternalOutputActionID.webhookPost]
        )
        let workflow = makeWorkflow(
            recognizerID: "deepgram.prerecorded",
            actions: [
                OutputActionReference(
                    id: ExternalOutputActionID.webhookPost,
                    configuration: [
                        ExternalOutputActionConfigurationKey.webhookURL:
                            "https://example.invalid/hook",
                    ]
                ),
            ]
        )
        let evaluation = PrivacyRunEvaluation(
            status: .requiresConfirmation,
            reasons: [.cloudProviderSelected, .cloudConfirmationRequired]
        )

        let receipt = service.explainResolved(
            resolvedPlan(for: workflow),
            privacyEvaluation: evaluation
        )

        XCTAssertEqual(receipt.status, .requiresConfirmation)
        XCTAssertEqual(receipt.privacyReasons, evaluation.reasons)
        XCTAssertEqual(
            receipt.issues,
            [
                WorkflowExplanationIssue(
                    kind: .privacyConfirmationRequired,
                    component: .privacyPolicy
                ),
            ]
        )
        XCTAssertEqual(
            service.privacyProcessingDestinations(for: resolvedPlan(for: workflow)),
            .classified([.cloudSpeech, .cloudText])
        )
        await assertProbeWasNotInvoked(probe)
    }

    func testDynamicRedactionsMakeContextInputsUnavailableWithoutLeakingContent() async throws {
        let probe = WorkflowExplainProbe()
        let service = makeService(
            probe: probe,
            recognizerIDs: ["context.selection"],
            actionIDs: ["clipboard.copy"]
        )
        let workflow = makeWorkflow(
            recognizerID: "context.selection",
            actions: [OutputActionReference(id: "clipboard.copy")]
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
            cloudConfirmationProvider: { _, _, _ in
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
        XCTAssertTrue(receipt.issues.contains(WorkflowExplanationIssue(
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
            actions: [OutputActionReference(id: "inject.text")]
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
        XCTAssertTrue(unavailable.issues.contains(WorkflowExplanationIssue(
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
            steps: [PostProcessStep(kind: .llmRewrite, prompt: "CANARY-PROMPT")],
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
        recognizer: WorkflowRecognizerResolution = .declared,
        output: WorkflowOutputResolution = .declared
    ) -> WorkflowResolvedExecutionPlan {
        switch WorkflowExecutionPlanResolver.resolve(
            workflow,
            initiatedBy: trigger ?? workflow.trigger,
            recognizer: recognizer,
            output: output
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
        WorkflowDefinition(
            name: "Workflow",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: recognizerID,
                postProcessSteps: steps,
                outputActions: actions
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
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
        clipboard: ClipboardSnapshot(plainText: "clipboard", changeCount: 1)
    )
}
