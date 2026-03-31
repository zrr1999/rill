import XCTest
@testable import VoxTypeCore
@testable import VoxTypeRuntime

private struct MockContextProvider: ContextProvider {
    func captureContext() async -> ContextSnapshot { .empty }
}

private struct MockRecognizer: SpeechRecognizer {
    let id = "mock.recognizer"
    let result: RecognitionResult

    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        result
    }
}

private struct MockTransformer: TextTransformer {
    let id = "mock.transformer"
    let supportedKinds: [PostProcessStepKind] = [.normalizeWhitespace]

    func transform(text: String, step: PostProcessStep, context: TransformContext) async throws -> String {
        text + " transformed"
    }
}

private actor ActionProbe {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

private struct ProbeAction: OutputAction {
    let id = "probe.action"
    let probe: ActionProbe

    func execute(text: String, context: ActionContext) async throws -> ActionResult {
        await probe.record(text)
        return .skipped("captured")
    }
}

private struct ReplaceAwareStackAction: OutputAction {
    let id = "replace.stack.action"
    let stack: DeliveryStack

    func execute(text: String, context: ActionContext) async throws -> ActionResult {
        let item = DeliveryItem(
            workflowID: context.workflow.id,
            workflow: context.workflow.presentation,
            text: text
        )
        if let sourceClipboardItemID = context.sourceClipboardItemID {
            await stack.replace(item, replacing: sourceClipboardItemID)
        } else {
            await stack.push(item)
        }
        return .pushedToStack
    }
}

final class SessionCoordinatorTests: XCTestCase {
    func testCoordinatorRunsPipelineAndExecutesActions() async {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let deliveryStack = DeliveryStack(eventBus: eventBus, diagnostics: diagnostics)
        let resolver = CandidateResolver(eventBus: eventBus, diagnostics: diagnostics)
        let probe = ActionProbe()

        let workflow = WorkflowDefinition(
            name: "Test Workflow",
            pipeline: PipelineDeclaration(
                recognizerID: "mock.recognizer",
                postProcessSteps: [PostProcessStep(kind: .normalizeWhitespace)],
                outputActions: [OutputActionReference(id: "probe.action")],
                uncertaintyPolicy: UncertaintyPolicy(mode: .off, confidenceThreshold: 0.0, timeoutSeconds: 0),
                deliveryPolicy: DeliveryPolicy(strategy: .immediate)
            ),
            ui: WorkflowUIConfig(symbolName: "testtube.2", accentColorName: "green")
        )

        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [MockRecognizer(result: RecognitionResult(rawText: "hello", bestText: "hello"))]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: [MockTransformer()]),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: probe)]),
            candidateResolver: resolver,
            deliveryStack: deliveryStack,
            eventBus: eventBus,
            diagnostics: diagnostics
        )

        let stream = await eventBus.stream()
        let collector = Task { () -> [VoxTypeEvent] in
            var events: [VoxTypeEvent] = []
            for await event in stream {
                events.append(event)
                if case .runCompleted = event {
                    break
                }
            }
            return events
        }
        await Task.yield()

        await coordinator.run(workflow: workflow)
        let events = await collector.value
        let probeValues = await probe.snapshot()

        XCTAssertEqual(probeValues, ["hello transformed"])
        XCTAssertTrue(events.contains { event in
            if case .runCompleted = event { return true }
            return false
        })
    }

    func testDeliverTopOfStackPublishesCompletionSummary() async {
        let eventBus = EventBus()
        let deliveryStack = DeliveryStack(eventBus: eventBus)
        let resolver = CandidateResolver(eventBus: eventBus)
        let probe = ActionProbe()

        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: probe)]),
            candidateResolver: resolver,
            deliveryStack: deliveryStack,
            eventBus: eventBus
        )

        await deliveryStack.push(
            DeliveryItem(
                workflowID: UUID(),
                text: "stack item"
            )
        )

        let stream = await eventBus.stream()
        let collector = Task { () -> [VoxTypeEvent] in
            var events: [VoxTypeEvent] = []
            for await event in stream {
                events.append(event)
                if case .runCompleted = event {
                    break
                }
            }
            return events
        }
        await Task.yield()

        await coordinator.deliverTopOfStack(actionID: "probe.action")
        let events = await collector.value

        XCTAssertTrue(events.contains { event in
            if case .actionExecuted(actionID: "probe.action", result: .skipped("captured")) = event {
                return true
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .runCompleted(let summary) = event {
                return summary.workflow.titleKey == .stackDelivery && summary.finalText == "stack item"
            }
            return false
        })
    }

    func testCoordinatorRecordsStageDiagnostics() async {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let deliveryStack = DeliveryStack(eventBus: eventBus, diagnostics: diagnostics)
        let resolver = CandidateResolver(eventBus: eventBus, diagnostics: diagnostics)
        let probe = ActionProbe()

        let workflow = WorkflowDefinition(
            name: "Stage Diagnostic Workflow",
            pipeline: PipelineDeclaration(
                recognizerID: "mock.recognizer",
                postProcessSteps: [PostProcessStep(kind: .normalizeWhitespace)],
                outputActions: [OutputActionReference(id: "probe.action")],
                uncertaintyPolicy: UncertaintyPolicy(mode: .off, confidenceThreshold: 0.0, timeoutSeconds: 0),
                deliveryPolicy: DeliveryPolicy(strategy: .immediate)
            ),
            ui: WorkflowUIConfig(symbolName: "testtube.2", accentColorName: "green")
        )

        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [MockRecognizer(result: RecognitionResult(rawText: "hello", bestText: "hello"))]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: [MockTransformer()]),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: probe)]),
            candidateResolver: resolver,
            deliveryStack: deliveryStack,
            eventBus: eventBus,
            diagnostics: diagnostics
        )

        await coordinator.run(workflow: workflow)
        let stageEvents = await diagnostics.snapshot(
            matching: DiagnosticQuery(subsystem: .session)
        ).filter { $0.event == "session.stage" }

        let stages = Set(stageEvents.compactMap { $0.metadata["stage"] })
        let workflows = Set(stageEvents.compactMap { $0.metadata["workflow"] })

        XCTAssertTrue(stages.isSuperset(of: ["preparing", "recognizing", "transforming", "delivering", "completed"]))
        XCTAssertEqual(workflows, [workflow.name])
    }

    func testReplayClipboardItemBypassesRecognitionAndUsesStoredText() async throws {
        let eventBus = EventBus()
        let deliveryStack = DeliveryStack(eventBus: eventBus)
        let resolver = CandidateResolver(eventBus: eventBus)
        let probe = ActionProbe()

        await deliveryStack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "saved item", changeCount: 1),
            context: ClipboardRouteContext(
                applicationName: "Safari",
                bundleIdentifier: "com.apple.Safari"
            )
        )
        let clipboardSnapshot = await deliveryStack.clipboardSnapshot()
        let itemID = try XCTUnwrap(clipboardSnapshot.items.first?.id)

        let workflow = WorkflowDefinition(
            name: "Replay Workflow",
            pipeline: PipelineDeclaration(
                recognizerID: "missing.recognizer",
                postProcessSteps: [PostProcessStep(kind: .normalizeWhitespace)],
                outputActions: [OutputActionReference(id: "probe.action")],
                uncertaintyPolicy: UncertaintyPolicy(mode: .off, confidenceThreshold: 0.0, timeoutSeconds: 0),
                deliveryPolicy: DeliveryPolicy(strategy: .immediate)
            ),
            ui: WorkflowUIConfig(symbolName: "testtube.2", accentColorName: "green")
        )

        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: [MockTransformer()]),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: probe)]),
            candidateResolver: resolver,
            deliveryStack: deliveryStack,
            eventBus: eventBus
        )

        await coordinator.replayClipboardItem(itemID: itemID, workflow: workflow)
        let probeValues = await probe.snapshot()

        XCTAssertEqual(probeValues, ["saved item transformed"])
    }

    func testReplayClipboardItemCanReplaceSourceItemInPlace() async throws {
        let eventBus = EventBus()
        let deliveryStack = DeliveryStack(eventBus: eventBus)
        let resolver = CandidateResolver(eventBus: eventBus)

        await deliveryStack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "saved item", changeCount: 1),
            context: ClipboardRouteContext(
                applicationName: "Safari",
                bundleIdentifier: "com.apple.Safari"
            )
        )
        let originalSnapshot = await deliveryStack.clipboardSnapshot()
        let originalItem = try XCTUnwrap(originalSnapshot.items.first)

        let workflow = WorkflowDefinition(
            name: "Replace Workflow",
            pipeline: PipelineDeclaration(
                recognizerID: "missing.recognizer",
                postProcessSteps: [PostProcessStep(kind: .normalizeWhitespace)],
                outputActions: [OutputActionReference(id: "replace.stack.action")],
                uncertaintyPolicy: UncertaintyPolicy(mode: .off, confidenceThreshold: 0.0, timeoutSeconds: 0),
                deliveryPolicy: DeliveryPolicy(strategy: .immediate)
            ),
            ui: WorkflowUIConfig(symbolName: "testtube.2", accentColorName: "green")
        )

        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: [MockTransformer()]),
            actionRegistry: OutputActionRegistry(actions: [ReplaceAwareStackAction(stack: deliveryStack)]),
            candidateResolver: resolver,
            deliveryStack: deliveryStack,
            eventBus: eventBus
        )

        await coordinator.replayClipboardItem(
            itemID: originalItem.id,
            workflow: workflow,
            replacingSourceItem: true
        )

        let updatedSnapshot = await deliveryStack.clipboardSnapshot()
        XCTAssertEqual(updatedSnapshot.items.count, 1)
        XCTAssertEqual(updatedSnapshot.items.first?.id, originalItem.id)
        XCTAssertEqual(updatedSnapshot.items.first?.groupID, originalItem.groupID)
        XCTAssertEqual(updatedSnapshot.items.first?.text, "saved item transformed")
        XCTAssertEqual(
            updatedSnapshot.groups.first(where: { $0.group.id == originalItem.groupID })?.count,
            1
        )
    }
}
