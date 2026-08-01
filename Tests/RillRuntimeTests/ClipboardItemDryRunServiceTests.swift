import Foundation
import XCTest
@testable import RillCore
@testable import RillRuntime

private actor ClipboardDryRunSideEffectProbe {
    struct Snapshot: Equatable {
        var recognitions = 0
        var transformations = 0
        var actions = 0
        var confirmations = 0
    }

    private var snapshot = Snapshot()

    func recordRecognition() { snapshot.recognitions += 1 }
    func recordTransformation() { snapshot.transformations += 1 }
    func recordAction() { snapshot.actions += 1 }
    func recordConfirmation() { snapshot.confirmations += 1 }
    func current() -> Snapshot { snapshot }
}

private struct ClipboardDryRunProbeRecognizer: SpeechRecognizer {
    let id = "remote.speech"
    let probe: ClipboardDryRunSideEffectProbe

    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        await probe.recordRecognition()
        return RecognitionResult(rawText: "CANARY-RECOGNITION", bestText: "CANARY-RECOGNITION")
    }
}

private struct ClipboardDryRunProbeTransformer: TextTransformer {
    let id = "transformer.normalize"
    let supportedKinds: [PostProcessStepKind] = [.normalizeWhitespace]
    let probe: ClipboardDryRunSideEffectProbe

    func transform(
        text: String,
        step: PostProcessStep,
        context: TransformContext
    ) async throws -> String {
        await probe.recordTransformation()
        return text
    }
}

private struct ClipboardDryRunProbeAction: OutputAction {
    let id = "stack.push"
    let probe: ClipboardDryRunSideEffectProbe

    func execute(text: String, context: ActionContext) async throws -> ActionResult {
        await probe.recordAction()
        return .pushedToStack
    }
}

final class ClipboardItemDryRunServiceTests: XCTestCase {
    func testUseSkipsContentFreeUnavailableSourceWithoutEffects() {
        let receipt = ClipboardItemDryRunService().preview(
            subject: makeSubject(hasTransferableContent: false),
            operation: .use
        )

        XCTAssertEqual(receipt.status, .skipped)
        XCTAssertEqual(receipt.reason, .sourceContentUnavailable)
        XCTAssertEqual(receipt.actionEffects, [])
        XCTAssertEqual(receipt.processingDestinations, [])
        XCTAssertEqual(receipt.issues.map(\.kind), [.sourceContentUnavailable])
    }

    private let service = ClipboardItemDryRunService()

    func testUseDescribesEverySupportedPayloadWithoutWorkflowExecution() {
        let cases: [(ClipboardContentKind, ClipboardItemDryRunReadCategory)] = [
            (.text, .sourceItemText),
            (.image, .sourceItemImage),
            (.files, .sourceItemFiles),
        ]

        for (contentKind, sourceRead) in cases {
            let receipt = service.preview(
                subject: makeSubject(contentKind: contentKind),
                operation: .use
            )

            XCTAssertEqual(receipt.status, .ready, "\(contentKind)")
            XCTAssertNil(receipt.workflowID, "\(contentKind)")
            XCTAssertNil(receipt.reason, "\(contentKind)")
            XCTAssertEqual(receipt.sourceReplacementPlan, .notRequested, "\(contentKind)")
            XCTAssertTrue(receipt.reads.contains { $0.category == sourceRead }, "\(contentKind)")
            XCTAssertTrue(receipt.reads.contains { $0.category == .focusedApplicationIdentity })
            XCTAssertTrue(receipt.reads.contains { $0.category == .currentClipboardDescriptor })
            XCTAssertTrue(receipt.reads.contains { $0.category == .currentClipboardContents })
            XCTAssertEqual(
                receipt.actionEffects.map(\.effect),
                [.temporaryClipboardWrite, .focusedApplicationWrite, .clipboardHistoryUsageWrite]
            )
            XCTAssertEqual(receipt.actionEffects.first?.usage, .conditional)
            XCTAssertEqual(receipt.actionEffects.last?.usage, .conditional)
            XCTAssertEqual(
                receipt.processingDestinations,
                [.clipboard, .focusedApplication, .localStorage]
            )
            XCTAssertTrue(receipt.transforms.isEmpty)
            XCTAssertTrue(receipt.issues.isEmpty)
        }
    }

    func testUseDoesNotTreatWorkflowCaptureExclusionAsAPasteBlock() {
        let receipt = service.preview(
            subject: makeSubject(captureTags: [.excludeFromWorkflowCapture]),
            operation: .use
        )

        XCTAssertEqual(receipt.status, .ready)
        XCTAssertNil(receipt.reason)
    }

    func testReplaySkipsRecognizerAndReportsOnlyActualTransformAndActionDestinations() throws {
        let itemID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let workflow = makeWorkflow(
            name: "CANARY-WORKFLOW-NAME",
            recognizerID: "remote.speech",
            steps: [
                PostProcessStep(
                    kind: .normalizeWhitespace,
                    prompt: "CANARY-PRIVATE-PROMPT"
                ),
            ],
            actions: [
                OutputActionReference(
                    id: "inject.text",
                    configuration: ["CANARY-KEY": "CANARY-CONFIGURATION"]
                ),
            ]
        )

        let receipt = service.preview(
            subject: ClipboardItemDryRunSubject(
                itemID: itemID,
                itemVersion: ClipboardItemVersion(),
                groupID: ClipboardGroup.defaultGroupID,
                contentKind: .text,
                hasTransferableContent: true
            ),
            operation: .replay,
            workflow: workflow,
            privacyEvaluation: .init(status: .ready)
        )
        let json = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)

        XCTAssertEqual(receipt.status, .ready)
        XCTAssertEqual(receipt.sourceReplacementPlan, .notRequested)
        XCTAssertEqual(
            receipt.transforms.map(\.kind),
            [.vocabularyMapping, .whitespaceNormalization]
        )
        XCTAssertEqual(
            receipt.actionEffects.map(\.effect),
            [.temporaryClipboardWrite, .focusedApplicationWrite]
        )
        XCTAssertEqual(
            receipt.processingDestinations,
            [.onDevice, .clipboard, .focusedApplication]
        )
        XCTAssertFalse(receipt.processingDestinations.contains(.cloudService))
        XCTAssertTrue(receipt.reads.contains { $0.category == .sourceItemText })
        XCTAssertFalse(json.contains("deepgram"))
        XCTAssertFalse(json.contains("CANARY"))
        XCTAssertFalse(json.contains(itemID.uuidString))
    }

    func testReplayAndReplaceSkipNonTextItemsWithoutProjectingActions() {
        for operation in [ClipboardItemDryRunOperation.replay, .replace] {
            for contentKind in [ClipboardContentKind.image, .files] {
                let receipt = service.preview(
                    subject: makeSubject(contentKind: contentKind),
                    operation: operation,
                    workflow: makeWorkflow(actions: [OutputActionReference(id: "stack.push")]),
                    privacyEvaluation: .init(status: .ready)
                )

                XCTAssertEqual(receipt.status, .skipped)
                XCTAssertEqual(receipt.reason, .unsupportedContentKind)
                XCTAssertTrue(receipt.transforms.isEmpty)
                XCTAssertTrue(receipt.actionEffects.isEmpty)
                XCTAssertEqual(
                    receipt.sourceReplacementPlan,
                    operation == .replace ? .unavailable : .notRequested
                )
            }
        }
    }

    func testExcludedSourceFailsClosedBeforeWorkflowProjection() {
        let canaryWorkflow = makeWorkflow(
            name: "CANARY-EXCLUDED",
            recognizerID: "remote.speech",
            actions: [OutputActionReference(id: ExternalOutputActionID.webhookPost)]
        )

        for operation in [ClipboardItemDryRunOperation.replay, .replace] {
            let receipt = service.preview(
                subject: makeSubject(captureTags: [.excludeFromWorkflowCapture]),
                operation: operation,
                workflow: canaryWorkflow,
                privacyEvaluation: .init(status: .requiresConfirmation)
            )

            XCTAssertEqual(receipt.status, .blocked)
            XCTAssertEqual(receipt.reason, .sourceExcludedFromWorkflowCapture)
            XCTAssertTrue(receipt.transforms.isEmpty)
            XCTAssertTrue(receipt.actionEffects.isEmpty)
            XCTAssertEqual(
                receipt.issues,
                [
                    ClipboardItemDryRunIssue(
                        kind: .sourceExcludedFromWorkflowCapture,
                        component: .privacyPolicy
                    ),
                ]
            )
        }
    }

    func testReplaceCapabilityZeroOneAndManyProduceTypedOutcomes() {
        let privacy = PrivacyRunEvaluation(status: .ready)

        let zero = service.preview(
            subject: makeSubject(),
            operation: .replace,
            workflow: makeWorkflow(actions: [OutputActionReference(id: "inject.text")]),
            privacyEvaluation: privacy
        )
        XCTAssertEqual(zero.status, .skipped)
        XCTAssertEqual(zero.reason, .noSourceReplacementEffect)
        XCTAssertEqual(zero.sourceReplacementPlan, .unavailable)
        XCTAssertFalse(zero.actionEffects.contains { $0.effect == .sourceItemReplacement })

        let one = service.preview(
            subject: makeSubject(),
            operation: .replace,
            workflow: makeWorkflow(actions: [OutputActionReference(id: "stack.push")]),
            privacyEvaluation: privacy
        )
        XCTAssertEqual(one.status, .ready)
        XCTAssertNil(one.reason)
        XCTAssertEqual(one.sourceReplacementPlan, .exactlyOne)
        XCTAssertEqual(one.actionEffects.map(\.effect), [.sourceItemReplacement])

        let many = service.preview(
            subject: makeSubject(),
            operation: .replace,
            workflow: makeWorkflow(
                actions: [
                    OutputActionReference(id: "clipboard.copy"),
                    OutputActionReference(id: "stack.push"),
                ]
            ),
            privacyEvaluation: privacy
        )
        XCTAssertEqual(many.status, .blocked)
        XCTAssertEqual(many.reason, .ambiguousSourceReplacement)
        XCTAssertEqual(many.sourceReplacementPlan, .ambiguous)
        XCTAssertEqual(
            many.actionEffects.filter { $0.effect == .sourceItemReplacement }.count,
            2
        )
        XCTAssertTrue(many.actionEffects.contains { $0.effect == .clipboardWrite })
    }

    func testOutputConfigurationAndPrivacyHaveClosedFailClosedResults() throws {
        let missing = service.preview(
            subject: makeSubject(),
            operation: .replay,
            workflow: makeWorkflow(
                actions: [OutputActionReference(id: ExternalOutputActionID.webhookPost)]
            ),
            privacyEvaluation: .init(status: .ready)
        )
        XCTAssertEqual(missing.status, .blocked)
        XCTAssertEqual(missing.reason, .configurationMissing)

        let invalid = service.preview(
            subject: makeSubject(),
            operation: .replay,
            workflow: makeWorkflow(
                actions: [
                    OutputActionReference(
                        id: ExternalOutputActionID.webhookPost,
                        configuration: [
                            ExternalOutputActionConfigurationKey.webhookURL: "http://private.invalid/hook",
                        ]
                    ),
                ]
            ),
            privacyEvaluation: .init(status: .ready)
        )
        XCTAssertEqual(invalid.status, .blocked)
        XCTAssertEqual(invalid.reason, .configurationInvalid)

        let secureReference = try XCTUnwrap(
            WebhookConfigurationReference(
                workflowID: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!,
                actionIndex: 0
            )
        )
        let protected = service.preview(
            subject: makeSubject(),
            operation: .replay,
            workflow: makeWorkflow(
                actions: [
                    OutputActionReference(
                        id: ExternalOutputActionID.webhookPost,
                        configuration: [
                            ExternalOutputActionConfigurationKey.webhookSecureReference:
                                secureReference.rawValue,
                        ]
                    ),
                ]
            ),
            privacyEvaluation: .init(status: .ready)
        )
        XCTAssertEqual(protected.status, .ready)
        XCTAssertEqual(protected.actionEffects.first?.configurationState, .configured)

        let endpointCanary = "https://private.invalid/CANARY-ENDPOINT"
        let credentialCanary = "Bearer CANARY-CREDENTIAL"
        let confirmation = service.preview(
            subject: makeSubject(),
            operation: .replay,
            workflow: makeWorkflow(
                recognizerID: "remote.speech",
                actions: [
                    OutputActionReference(
                        id: ExternalOutputActionID.webhookPost,
                        configuration: [
                            ExternalOutputActionConfigurationKey.webhookURL: endpointCanary,
                            ExternalOutputActionConfigurationKey.webhookHeadersJSON:
                                "{\"Authorization\":\"(credentialCanary)\"}",
                        ]
                    ),
                ]
            ),
            privacyEvaluation: .init(
                status: .requiresConfirmation,
                reasons: [.cloudProviderSelected, .cloudConfirmationRequired]
            )
        )
        let encoded = String(decoding: try JSONEncoder().encode(confirmation), as: UTF8.self)
        XCTAssertEqual(confirmation.status, .requiresConfirmation)
        XCTAssertNil(confirmation.reason)
        XCTAssertTrue(confirmation.actionEffects.contains { $0.effect == .webhookRequest })
        XCTAssertTrue(confirmation.processingDestinations.contains(.remoteEndpoint))
        XCTAssertFalse(confirmation.processingDestinations.contains(.cloudService))
        XCTAssertFalse(encoded.contains(endpointCanary))
        XCTAssertFalse(encoded.contains(credentialCanary))
        XCTAssertFalse(encoded.contains("private.invalid"))
    }

    func testUnknownLegacyAndUnavailablePrivacyStatesFailClosedWithoutRawIdentifiers() throws {
        let unknownCanary = "unknown.CANARY-COMPONENT"
        let unknown = service.preview(
            subject: makeSubject(),
            operation: .replay,
            workflow: makeWorkflow(
                steps: [PostProcessStep(kind: .llmRewrite, prompt: "CANARY-PROMPT")],
                actions: [
                    OutputActionReference(
                        id: unknownCanary,
                        configuration: ["CANARY-SECRET": "CANARY-VALUE"]
                    ),
                ]
            ),
            privacyEvaluation: .init(status: .ready)
        )
        let encodedUnknown = String(decoding: try JSONEncoder().encode(unknown), as: UTF8.self)
        XCTAssertEqual(unknown.status, .blocked)
        XCTAssertEqual(unknown.reason, .componentUnclassified)
        XCTAssertTrue(unknown.processingDestinations.contains(.unclassified))
        XCTAssertFalse(encodedUnknown.contains("CANARY"))
        XCTAssertFalse(encodedUnknown.contains("unknown."))

        var legacyWorkflow = makeWorkflow(actions: [OutputActionReference(id: "stack.push")])
        legacyWorkflow.metadata["eventType"] = "groupItemCreated"
        let legacy = service.preview(
            subject: makeSubject(),
            operation: .replay,
            workflow: legacyWorkflow,
            privacyEvaluation: .init(status: .ready)
        )
        XCTAssertEqual(legacy.status, .blocked)
        XCTAssertEqual(legacy.reason, .legacyWorkflowUnsupported)

        let noEvaluation = service.preview(
            subject: makeSubject(),
            operation: .replay,
            workflow: makeWorkflow(actions: [OutputActionReference(id: "stack.push")])
        )
        XCTAssertEqual(noEvaluation.status, .blocked)
        XCTAssertEqual(noEvaluation.reason, .privacyEvaluationUnavailable)

        let missingWorkflow = service.preview(
            subject: makeSubject(),
            operation: .replay,
            privacyEvaluation: .init(status: .ready)
        )
        XCTAssertEqual(missingWorkflow.status, .skipped)
        XCTAssertEqual(missingWorkflow.reason, .workflowRequired)

        let unavailable = service.preview(
            subject: makeSubject(),
            operation: .replay,
            workflow: makeWorkflow(actions: [OutputActionReference(id: "stack.push")]),
            privacyEvaluation: .init(
                status: .blocked,
                reasons: [.privacySettingsUnavailable]
            )
        )
        XCTAssertEqual(unavailable.status, .blocked)
        XCTAssertEqual(unavailable.reason, .privacyEvaluationUnavailable)

        let privacyBlocked = service.preview(
            subject: makeSubject(),
            operation: .replay,
            workflow: makeWorkflow(actions: [OutputActionReference(id: "stack.push")]),
            privacyEvaluation: .init(
                status: .blocked,
                reasons: [.sensitiveApplication, .cloudProcessingBlocked]
            )
        )
        XCTAssertEqual(privacyBlocked.status, .blocked)
        XCTAssertEqual(privacyBlocked.reason, .privacyProcessingBlocked)
    }

    func testServiceCannotReachExecutionOrConfirmationObjects() async {
        let probe = ClipboardDryRunSideEffectProbe()
        let recognizerRegistry = SpeechRecognizerRegistry(
            recognizers: [ClipboardDryRunProbeRecognizer(probe: probe)]
        )
        let transformerRegistry = TextTransformerRegistry(
            transformers: [ClipboardDryRunProbeTransformer(probe: probe)]
        )
        let actionRegistry = OutputActionRegistry(
            actions: [ClipboardDryRunProbeAction(probe: probe)]
        )
        let confirmation: @Sendable () async -> Bool = {
            await probe.recordConfirmation()
            return true
        }

        let receipt = service.preview(
            subject: makeSubject(),
            operation: .replace,
            workflow: makeWorkflow(
                recognizerID: "remote.speech",
                steps: [PostProcessStep(kind: .normalizeWhitespace)],
                actions: [OutputActionReference(id: "stack.push")]
            ),
            privacyEvaluation: .init(status: .requiresConfirmation)
        )
        withExtendedLifetime((recognizerRegistry, transformerRegistry, actionRegistry, confirmation)) {}

        let probeSnapshot = await probe.current()
        XCTAssertEqual(receipt.status, .requiresConfirmation)
        XCTAssertEqual(receipt.sourceReplacementPlan, .exactlyOne)
        XCTAssertEqual(probeSnapshot, ClipboardDryRunSideEffectProbe.Snapshot())
        XCTAssertEqual(
            Mirror(reflecting: service).children.compactMap(\.label),
            ["profileRegistry"]
        )
    }

    private func makeSubject(
        contentKind: ClipboardContentKind = .text,
        captureTags: [ClipboardCaptureTag] = [],
        hasTransferableContent: Bool = true
    ) -> ClipboardItemDryRunSubject {
        ClipboardItemDryRunSubject(
            itemID: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            itemVersion: ClipboardItemVersion(
                generationID: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!,
                revision: 1
            ),
            groupID: ClipboardGroup.defaultGroupID,
            contentKind: contentKind,
            captureTags: captureTags,
            hasTransferableContent: hasTransferableContent
        )
    }

    private func makeWorkflow(
        name: String = "Workflow",
        recognizerID: String = "sherpa-onnx.local",
        steps: [PostProcessStep] = [],
        actions: [OutputActionReference]
    ) -> WorkflowDefinition {
        WorkflowDefinition(
            id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!,
            name: name,
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: recognizerID,
                postProcessSteps: steps,
                outputActions: actions
            ),
            ui: WorkflowUIConfig(symbolName: "doc", accentColorName: "blue")
        )
    }
}
