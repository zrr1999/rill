import Foundation
import XCTest
@testable import RillCore
@testable import RillRuntime
@testable import RillUI

private actor WorkflowExplanationProviderProbe {
    private var workflows: [WorkflowDefinition] = []

    func record(_ plan: WorkflowResolvedExecutionPlan) {
        workflows.append(plan.executionWorkflow)
    }

    func snapshot() -> [WorkflowDefinition] {
        workflows
    }
}

@MainActor
final class AppModelWorkflowExplanationTests: XCTestCase {
    func testProviderReceivesCurrentResolvedRouteAndManualInvocation() async throws {
        let workflow = makeBuiltinPushToTalkWorkflow()
        let probe = WorkflowExplanationProviderProbe()
        let service = makeContentFreeExplainService()
        let harness = makeHarness(
            workflows: [workflow],
            explainResolvedWorkflowAction: { plan in
                await probe.record(plan)
                return service.explainResolved(plan)
            }
        )
        await waitForListenerSetup()
        harness.model.builtinPushToTalkOutputMode = .saveToVoiceGroup

        harness.model.explainWorkflowBeforeRun(workflow)
        await waitForWorkflowExplanation(model: harness.model)

        let calls = await probe.snapshot()
        let captured = try XCTUnwrap(calls.first)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(captured.pipeline.recognizerID, AppModel.localSpeechRecognizerID)
        XCTAssertEqual(captured.pipeline.outputActions.map(\.id), ["inject.text"])
        guard case .loaded(let receipt) = harness.model.workflowExplanationState else {
            return XCTFail("Expected a loaded workflow explanation")
        }
        XCTAssertEqual(receipt.trigger, .manual)
        XCTAssertEqual(receipt.workflowID, workflow.id)
    }

    func testRapidWorkflowSwitchRejectsStaleAsyncResult() async {
        let first = makeExplanationWorkflow(name: "First")
        let second = makeExplanationWorkflow(name: "Second")
        let harness = makeHarness(
            workflows: [first, second],
            explainResolvedWorkflowAction: { plan in
                if plan.executionWorkflow.id == first.id {
                    try? await Task.sleep(for: .milliseconds(160))
                } else {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return makeExplanationReceipt(workflowID: plan.executionWorkflow.id, status: .ready)
            }
        )
        await waitForListenerSetup()

        harness.model.explainWorkflowBeforeRun(first)
        guard case .loading(let loadingID) = harness.model.workflowExplanationState else {
            return XCTFail("Expected loading state")
        }
        XCTAssertEqual(loadingID, first.id)
        await Task.yield()
        harness.model.explainWorkflowBeforeRun(second)
        await waitForWorkflowExplanation(model: harness.model)
        try? await Task.sleep(for: .milliseconds(190))

        guard case .loaded(let receipt) = harness.model.workflowExplanationState else {
            return XCTFail("Expected the second workflow explanation")
        }
        XCTAssertEqual(receipt.workflowID, second.id)
    }

    func testRoutingSettingChangeCancelsPendingPreview() async {
        let workflow = makeExplanationWorkflow(name: "Pending")
        let harness = makeHarness(
            workflows: [workflow],
            explainResolvedWorkflowAction: { plan in
                try? await Task.sleep(for: .milliseconds(100))
                return makeExplanationReceipt(workflowID: plan.executionWorkflow.id, status: .ready)
            }
        )
        await waitForListenerSetup()
        harness.model.builtinPushToTalkOutputMode = .pasteIntoApp

        harness.model.explainWorkflowBeforeRun(workflow)
        harness.model.builtinPushToTalkOutputMode = .saveToVoiceGroup
        try? await Task.sleep(for: .milliseconds(140))

        XCTAssertEqual(harness.model.workflowExplanationState, .idle)
    }

    func testLegacyWorkflowIsBlockedWithoutCallingProvider() async {
        var legacy = makeExplanationWorkflow(name: "Legacy")
        legacy.metadata["eventType"] = "groupItemCreated"
        let probe = WorkflowExplanationProviderProbe()
        let harness = makeHarness(
            workflows: [legacy],
            explainResolvedWorkflowAction: { plan in
                await probe.record(plan)
                return makeExplanationReceipt(workflowID: plan.executionWorkflow.id, status: .ready)
            }
        )
        await waitForListenerSetup()

        harness.model.explainWorkflowBeforeRun(legacy)

        let calls = await probe.snapshot()
        XCTAssertTrue(calls.isEmpty)
        guard case .loaded(let receipt) = harness.model.workflowExplanationState else {
            return XCTFail("Expected a fail-closed legacy receipt")
        }
        XCTAssertEqual(receipt.status, .blocked)
        XCTAssertTrue(receipt.issues.contains { $0.kind == .legacyWorkflowUnsupported })
        XCTAssertEqual(receipt.trigger, .manual)
    }

    func testMissingWorkflowAndProviderErrorUseTypedContentFreeFailures() async {
        let canary = "PRIVATE-/Users/alice/secret.md-https://private.invalid"
        let workflow = makeExplanationWorkflow(name: "Available")
        let harness = makeHarness(
            workflows: [workflow],
            explainResolvedWorkflowAction: { _ in
                throw NSError(
                    domain: canary,
                    code: 99,
                    userInfo: [NSLocalizedDescriptionKey: canary]
                )
            }
        )
        await waitForListenerSetup()

        harness.model.explainWorkflowBeforeRun(workflow)
        await waitForWorkflowExplanation(model: harness.model)
        guard case .failed(let failedID, let reason) = harness.model.workflowExplanationState else {
            return XCTFail("Expected a typed provider failure")
        }
        XCTAssertEqual(failedID, workflow.id)
        XCTAssertEqual(reason, .providerUnavailable)
        XCTAssertFalse(String(describing: harness.model.workflowExplanationState).contains(canary))
        XCTAssertFalse(
            UIStrings.workflowExplanationFailure(reason, language: .english).contains(canary)
        )

        let removed = makeExplanationWorkflow(name: "Removed")
        harness.model.explainWorkflowBeforeRun(removed)
        XCTAssertEqual(
            harness.model.workflowExplanationState,
            .failed(workflowID: removed.id, reason: .workflowUnavailable)
        )
    }

    func testExplicitCancellationPreventsDismissedPreviewFromWritingBack() async {
        let workflow = makeExplanationWorkflow(name: "Dismissed")
        let harness = makeHarness(
            workflows: [workflow],
            explainResolvedWorkflowAction: { plan in
                try? await Task.sleep(for: .milliseconds(80))
                return makeExplanationReceipt(workflowID: plan.executionWorkflow.id, status: .ready)
            }
        )
        await waitForListenerSetup()

        harness.model.explainWorkflowBeforeRun(workflow)
        harness.model.cancelWorkflowExplanation()
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(harness.model.workflowExplanationState, .idle)
    }

    func testPresentationMapsEveryEffectAndPrivacyReasonWithoutRawValues() {
        let workflowID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let receipt = WorkflowExplanationReceipt(
            workflowID: workflowID,
            trigger: .manual,
            inputs: [
                WorkflowExplanationInput(
                    category: .focusedSelection,
                    availability: .unavailable,
                    usage: .conditional,
                    processingDestination: .onDevice
                ),
                WorkflowExplanationInput(
                    category: .microphoneAudio,
                    availability: .unavailable,
                    usage: .required,
                    processingDestination: .cloudService
                ),
                WorkflowExplanationInput(
                    category: .recognitionHints,
                    availability: .available,
                    usage: .conditional,
                    processingDestination: .cloudService
                ),
            ],
            transforms: [
                WorkflowExplanationTransform(
                    kind: .whitespaceNormalization,
                    availability: .available,
                    usage: .required,
                    processingDestination: .onDevice
                ),
            ],
            outputs: [
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
                    effect: .shortcutInvocation,
                    availability: .available,
                    configurationState: .configured,
                    processingDestination: .localAutomation
                ),
            ],
            processingDestinations: [.cloudService, .clipboard, .localStorage, .localAutomation],
            status: .requiresConfirmation,
            issues: [
                WorkflowExplanationIssue(
                    kind: .privacyConfirmationRequired,
                    component: .privacyPolicy
                ),
                WorkflowExplanationIssue(
                    kind: .privacyInputRedacted,
                    component: .privacyPolicy
                ),
            ],
            privacyReasons: [
                .cloudProviderSelected,
                .cloudConfirmationRequired,
                .sensitiveApplication,
                .sensitiveApplication,
            ],
            redactedInputCategories: [.focusedSelection]
        )

        let english = WorkflowExplanationPresentation.make(
            receipt: receipt,
            language: .english
        )
        let chinese = WorkflowExplanationPresentation.make(
            receipt: receipt,
            language: .simplifiedChinese
        )

        XCTAssertEqual(english.statusTitle, "Will ask at runtime")
        XCTAssertEqual(chinese.statusTitle, "运行时将询问")
        XCTAssertEqual(english.outputs.count, 3)
        XCTAssertEqual(chinese.outputs.count, 3)
        XCTAssertEqual(english.privacyReasons.count, 2)
        XCTAssertTrue(english.inputs[0].detail.contains("Omitted by the current privacy preview"))
        XCTAssertTrue(english.inputs[1].detail.contains("Pipeline component unavailable"))
        XCTAssertTrue(english.inputs[2].detail.contains("current content and permission are not checked"))
        XCTAssertTrue(english.destinations.contains { $0.contains("may access the network") })
        XCTAssertTrue(chinese.destinations.contains { $0.contains("可能访问网络") })

        let visibleText = presentationStrings(english).joined(separator: "\n")
        XCTAssertFalse(visibleText.contains(workflowID.uuidString))
        XCTAssertFalse(visibleText.contains("shortcut.secret.name"))
        XCTAssertFalse(visibleText.contains("/Users/alice"))
        XCTAssertFalse(visibleText.contains("private.invalid"))
    }

    func testReadyConfirmationAndBlockedStatusCopyRemainsNonAuthorizing() {
        let ready = UIStrings.workflowExplanationStatusTitle(.ready, language: .english)
        let readyDetail = UIStrings.workflowExplanationStatusDetail(.ready, language: .english)
        let confirmation = UIStrings.workflowExplanationStatusTitle(
            .requiresConfirmation,
            language: .simplifiedChinese
        )
        let blocked = UIStrings.workflowExplanationStatusTitle(.blocked, language: .english)

        XCTAssertEqual(ready, "Current privacy preview passed")
        XCTAssertTrue(readyDetail.contains("not a full readiness check"))
        XCTAssertTrue(readyDetail.contains("rechecks"))
        XCTAssertEqual(confirmation, "运行时将询问")
        XCTAssertEqual(blocked, "Blocked in this preview")
        XCTAssertNotEqual(confirmation, UIStrings.workflowExplanationStatusTitle(.blocked, language: .simplifiedChinese))
    }

    func testUnsavedRecognizerOrOutputChangesDisableSavedWorkflowPreview() throws {
        let workflow = makeBuiltinPushToTalkWorkflow()
        let savedDraft = try XCTUnwrap(WorkflowEditorDraft(workflow: workflow))
        XCTAssertTrue(
            WorkflowExplanationSelectionState.canExplainSavedWorkflow(
                draft: savedDraft,
                selectedWorkflow: workflow
            )
        )

        var recognizerDraft = savedDraft
        recognizerDraft.recognizer = .localSpeech
        XCTAssertFalse(
            WorkflowExplanationSelectionState.canExplainSavedWorkflow(
                draft: recognizerDraft,
                selectedWorkflow: workflow
            )
        )

        var outputDraft = savedDraft
        outputDraft.destination = .saveToQueue
        XCTAssertFalse(
            WorkflowExplanationSelectionState.canExplainSavedWorkflow(
                draft: outputDraft,
                selectedWorkflow: workflow
            )
        )
        XCTAssertFalse(
            WorkflowExplanationSelectionState.canExplainSavedWorkflow(
                draft: savedDraft,
                selectedWorkflow: nil
            )
        )
        XCTAssertEqual(
            UIStrings.workflowExplanationCopy(.saveBeforePreview, language: .english),
            "Save the visible changes before previewing this workflow."
        )
        XCTAssertEqual(
            UIStrings.workflowExplanationCopy(.saveBeforePreview, language: .simplifiedChinese),
            "请先保存当前可见改动，再预览此工作流。"
        )
        XCTAssertEqual(
            WorkflowExplanationSelectionState.unavailableFailure(workflowExists: true),
            .providerUnavailable
        )
        XCTAssertEqual(
            WorkflowExplanationSelectionState.unavailableFailure(workflowExists: false),
            .workflowUnavailable
        )
    }

    private func waitForWorkflowExplanation(model: AppModel) async {
        for _ in 0..<80 {
            switch model.workflowExplanationState {
            case .loaded, .failed:
                return
            case .idle, .loading:
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }
}

private func makeExplanationWorkflow(name: String) -> WorkflowDefinition {
    WorkflowDefinition(
        name: name,
        trigger: .manual,
        pipeline: PipelineDeclaration(
            recognizerID: "ui.test.recognizer",
            outputActions: [OutputActionReference(id: "ui.test.action")]
        ),
        ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
    )
}

private func makeExplanationReceipt(
    workflowID: UUID,
    status: WorkflowExplanationStatus
) -> WorkflowExplanationReceipt {
    WorkflowExplanationReceipt(
        workflowID: workflowID,
        trigger: .manual,
        inputs: [],
        transforms: [],
        outputs: [],
        processingDestinations: [],
        status: status,
        issues: []
    )
}

private func makeContentFreeExplainService() -> WorkflowExplainService {
    WorkflowExplainService(
        recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
        transformerRegistry: TextTransformerRegistry(transformers: []),
        actionRegistry: OutputActionRegistry(actions: [])
    )
}

private func presentationStrings(
    _ presentation: WorkflowExplanationPresentation
) -> [String] {
    [
        presentation.statusTitle,
        presentation.statusDetail,
        presentation.trigger,
    ] + presentation.inputs.flatMap { [$0.title, $0.detail] }
        + presentation.transforms.flatMap { [$0.title, $0.detail] }
        + presentation.outputs.flatMap { [$0.title, $0.detail] }
        + presentation.destinations
        + presentation.privacyReasons
        + presentation.issues
}
