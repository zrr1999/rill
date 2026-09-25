import RillDomainTestSupport
import XCTest
@testable import RillCore
@testable import RillRuntime

private actor WorkflowPolicyProbe {
    private var contextCaptureCount = 0
    private var recognitionCount = 0
    private var actionCount = 0

    func recordContextCapture() { contextCaptureCount += 1 }
    func recordRecognition() { recognitionCount += 1 }
    func recordAction() { actionCount += 1 }

    func snapshot() -> (context: Int, recognition: Int, action: Int) {
        (contextCaptureCount, recognitionCount, actionCount)
    }
}

private actor WorkflowPolicyOptionsProbe {
    private var count = 0
    func record() -> SpeechRecognitionRequestOptions {
        count += 1
        return .empty
    }
    func snapshot() -> Int { count }
}

private struct WorkflowPolicyContextProvider: ContextProvider {
    let probe: WorkflowPolicyProbe

    func captureContext() async -> ContextSnapshot {
        await probe.recordContextCapture()
        return .empty
    }
}

private struct WorkflowPolicyRecognizer: SpeechRecognizer {
    let id = "policy.recognizer"
    let probe: WorkflowPolicyProbe

    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        await probe.recordRecognition()
        return RecognitionResult(rawText: "unused", bestText: "unused")
    }
}

private struct WorkflowPolicyAction: OutputAction {
    let id = "policy.action"
    let probe: WorkflowPolicyProbe

    func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
        _ = try record.requireText(for: id)
        await probe.recordAction()
        return .copiedToClipboard
    }
}

final class WorkflowExecutionPolicyTests: XCTestCase {
    func testPlannedPresetFailsClosedBeforeRuntimeComponents() {
        var workflow = makeWorkflow(eventType: "manual")
        workflow.metadata[WorkflowMetadataKey.availability] = WorkflowAvailability.planned.rawValue

        XCTAssertEqual(
            WorkflowExecutionPolicy.issue(for: workflow),
            .plannedCapabilityUnavailable
        )
        XCTAssertFalse(WorkflowExecutionPolicy.supports(workflow))
        XCTAssertEqual(
            WorkflowExecutionPolicy.decision(for: workflow, on: .interactiveCapture),
            .invalidConfiguration
        )
    }

    func testPolicyClassifiesEveryLegacyClipboardEventType() {
        for eventType in ["groupItemCreated", "groupItemEdited", "groupItemRemoved"] {
            let workflow = makeWorkflow(eventType: eventType)

            XCTAssertEqual(
                WorkflowExecutionPolicy.issue(for: workflow),
                .legacyClipboardAutomationUnsupported
            )
            XCTAssertFalse(WorkflowExecutionPolicy.supports(workflow))
        }

        XCTAssertTrue(WorkflowExecutionPolicy.supports(makeWorkflow(eventType: "manual")))
        XCTAssertEqual(
            WorkflowExecutionPolicy.issue(for: makeWorkflow(eventType: "groupItemCopied")),
            .invalidEventType
        )
        XCTAssertFalse(
            WorkflowExecutionPolicy.supports(makeWorkflow(eventType: "groupItemCopied"))
        )
    }

    func testPolicyKeepsInteractiveAndGroupExecutionSurfacesDisjoint() {
        let interactive = makeWorkflow(eventType: "manual")
        let group = makeStrictGroupWorkflow()
        let malformedGroup = makeWorkflow(eventType: "groupItemCreated")

        XCTAssertEqual(
            WorkflowExecutionPolicy.decision(for: interactive, on: .interactiveCapture),
            .supported
        )
        XCTAssertEqual(
            WorkflowExecutionPolicy.decision(for: interactive, on: .clipboardItemReplay),
            .supported
        )
        XCTAssertEqual(
            WorkflowExecutionPolicy.decision(for: interactive, on: .recordCollectionEvent),
            .wrongSurface
        )
        XCTAssertEqual(
            WorkflowExecutionPolicy.decision(for: group, on: .interactiveCapture),
            .wrongSurface
        )
        XCTAssertEqual(
            WorkflowExecutionPolicy.decision(for: group, on: .clipboardItemReplay),
            .wrongSurface
        )
        XCTAssertEqual(
            WorkflowExecutionPolicy.decision(for: group, on: .recordCollectionEvent),
            .supported
        )
        XCTAssertEqual(
            WorkflowExecutionPolicy.decision(
                for: malformedGroup,
                on: .recordCollectionEvent
            ),
            .invalidConfiguration
        )
    }

    func testSessionCoordinatorBlocksUnsupportedEventsBeforeRunningComponents() async {
        let cases = [
            (
                eventType: "groupItemCreated",
                failureMessage: "Legacy clipboard automation must fail before execution."
            ),
            (
                eventType: "groupItemCopied",
                failureMessage: "An unknown event type must fail before execution."
            ),
        ]

        for testCase in cases {
            let probe = WorkflowPolicyProbe()
            let eventBus = EventBus()
            let coordinator = makeTestSessionCoordinator(

                recognizerRegistry: SpeechRecognizerRegistry(
                    recognizers: [WorkflowPolicyRecognizer(probe: probe)]
                ),
                transformerRegistry: TextTransformerRegistry(transformers: []),
                actionRegistry: OutputActionRegistry(
                    actions: [WorkflowPolicyAction(probe: probe)]
                ),
                candidateResolver: CandidateResolver(eventBus: eventBus),
                eventBus: eventBus
            )

            let result = await coordinator.runReportingOutcome(
                workflow: makeWorkflow(eventType: testCase.eventType)
            )
            let counts = await probe.snapshot()

            guard case .failed(let failure) = result else {
                XCTFail(testCase.failureMessage)
                continue
            }
            XCTAssertEqual(failure.stage, .preparing, testCase.failureMessage)
            XCTAssertEqual(failure.code, .configuration, testCase.failureMessage)
            XCTAssertEqual(counts.context, 0, testCase.failureMessage)
            XCTAssertEqual(counts.recognition, 0, testCase.failureMessage)
            XCTAssertEqual(counts.action, 0, testCase.failureMessage)
            let state = await coordinator.currentState()
            XCTAssertEqual(state, .idle, testCase.failureMessage)
        }
    }

    func testSessionCoordinatorRequiresExplicitAuthorizedContextBeforeComponents() async {
        let probe = WorkflowPolicyProbe()
        let optionsProbe = WorkflowPolicyOptionsProbe()
        let eventBus = EventBus()
        let coordinator = makeTestSessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [WorkflowPolicyRecognizer(probe: probe)]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(
                actions: [WorkflowPolicyAction(probe: probe)]
            ),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            eventBus: eventBus,
            recognitionOptionsProvider: { _, _ in await optionsProbe.record() }
        )

        let result = await coordinator.runReportingOutcome(
            workflow: makeWorkflow(eventType: "manual")
        )
        let counts = await probe.snapshot()
        let optionsCount = await optionsProbe.snapshot()

        guard case .failed(let failure) = result else {
            return XCTFail("Expected missing context to fail before component resolution")
        }
        XCTAssertNotNil(failure.runID)
        XCTAssertEqual(failure.stage, .preparing)
        XCTAssertEqual(failure.code, .configuration)
        XCTAssertEqual(counts.context, 0)
        XCTAssertEqual(counts.recognition, 0)
        XCTAssertEqual(counts.action, 0)
        XCTAssertEqual(optionsCount, 0)
        let state = await coordinator.currentState()
        XCTAssertEqual(state, .idle)
    }

    private func makeWorkflow(eventType: String) -> WorkflowDefinition {
        WorkflowDefinition(
            name: "Legacy Clipboard Automation",
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: "policy.recognizer",
                outputActions: [OutputActionReference(id: "policy.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "bolt", accentColorName: "orange"),
            metadata: ["eventType": eventType]
        )
    }

    private func makeStrictGroupWorkflow() -> WorkflowDefinition {
        var workflow = makeWorkflow(eventType: "groupItemCreated")
        workflow.metadata[WorkflowMetadataKey.legacySourceCollectionID] =
            RecordCollection.voiceInputID.rawValue.uuidString
        workflow.metadata[WorkflowMetadataKey.legacyExcludePolishTag] = "true"
        workflow.metadata[WorkflowMetadataKey.legacyGroupActionKind] =
            RecordCollectionActionKind.editRecord.rawValue
        return workflow
    }
}
