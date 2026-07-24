import XCTest
@testable import RillCore
@testable import RillRuntime

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

private actor RecognitionRequestProbe {
    private var requests: [RecognitionRequest] = []

    func record(_ request: RecognitionRequest) {
        requests.append(request)
    }

    func snapshot() -> [RecognitionRequest] {
        requests
    }
}

private struct OptionsProbeRecognizer: SpeechRecognizer {
    let id: String
    let capabilities: SpeechRecognizerCapabilities
    let probe: RecognitionRequestProbe

    init(
        id: String = "options.probe",
        supportsKeyterms: Bool,
        probe: RecognitionRequestProbe
    ) {
        self.id = id
        capabilities = SpeechRecognizerCapabilities(
            supportedHintKinds: supportsKeyterms ? [.keyterm] : []
        )
        self.probe = probe
    }

    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        await probe.record(request)
        return RecognitionResult(rawText: "recognized", bestText: "recognized")
    }
}

private struct TestRecognizerError: Error, LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private struct FailingRecognizer: SpeechRecognizer {
    let id = "failing.recognizer"
    let message: String

    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        throw TestRecognizerError(message: message)
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

private actor ActionContextProbe {
    private var contexts: [ContextSnapshot] = []

    func record(_ context: ContextSnapshot) {
        contexts.append(context)
    }

    func snapshot() -> [ContextSnapshot] { contexts }
}

private struct ContextProbeAction: OutputAction {
    let id = "focus.probe"
    let probe: ActionContextProbe

    func execute(text: String, context: ActionContext) async throws -> ActionResult {
        await probe.record(context.contextSnapshot)
        return .skipped("captured")
    }
}

private actor PrivacyContextCaptureProbe {
    private var captureCount = 0

    func capture(_ context: ContextSnapshot) -> ContextSnapshot {
        captureCount += 1
        return context
    }

    func count() -> Int {
        captureCount
    }
}

private struct FailingContextProbeAction: OutputAction {
    let id = "failing.context.probe"
    let probe: ActionContextProbe

    func execute(text: String, context: ActionContext) async throws -> ActionResult {
        await probe.record(context.contextSnapshot)
        throw TestRecognizerError(message: "injection failed")
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

private struct ResultAction: OutputAction {
    let id: String
    let result: ActionResult
    let probe: ActionProbe

    func execute(text: String, context: ActionContext) async throws -> ActionResult {
        await probe.record(id)
        return result
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
        if let sourceSubject = context.sourceClipboardItemSubject {
            let replacement = await stack.replace(item, replacing: sourceSubject)
            guard replacement == .replaced else {
                return .failed("source replacement rejected")
            }
            return .pushedToStack
        }
        await stack.push(item)
        return .pushedToStack
    }
}

private struct GroupAwareStackAction: OutputAction {
    let id = "group.stack.action"
    let stack: DeliveryStack

    func execute(text: String, context: ActionContext) async throws -> ActionResult {
        let item = DeliveryItem(
            workflowID: context.workflow.id,
            workflow: context.workflow.presentation,
            text: text,
            alternatives: context.recognitionResult.candidateSets.flatMap { $0.candidates.map(\.text) },
            targetGroupID: context.workflow.targetClipboardGroupID
        )
        await stack.push(item)
        return .pushedToStack
    }
}

private actor BlockingGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isSignaled = false

    func wait() async {
        if isSignaled {
            isSignaled = false
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        if let continuation {
            continuation.resume()
        } else {
            isSignaled = true
        }
        continuation = nil
    }
}

private actor BlockingInitializationSettingsStore: SettingsStore, ClipboardPersistenceStore {
    private let loadStarted: BlockingGate
    private let releaseLoad: BlockingGate

    init(loadStarted: BlockingGate, releaseLoad: BlockingGate) {
        self.loadStarted = loadStarted
        self.releaseLoad = releaseLoad
    }

    func string(forKey _: AppSettingKey) async throws -> String? {
        await loadStarted.resume()
        await releaseLoad.wait()
        return nil
    }

    func setString(_: String, forKey _: AppSettingKey) async throws {}

    func setStringsAtomically(_: [AppSettingKey: String]) async throws {}

    func removeValue(forKey _: AppSettingKey) async throws {}

    func loadClipboardPersistence() async throws -> ClipboardPersistenceReadSnapshot {
        await loadStarted.resume()
        await releaseLoad.wait()
        return .empty
    }

    func replaceClipboardPersistence(
        with _: ClipboardPersistenceWriteSnapshot
    ) async throws -> Int64 {
        1
    }

    func removeClipboardPersistence() async throws -> ClipboardPersistenceRemovalResult {
        .removed
    }
}

private actor CompletionProbe {
    private var isComplete = false

    func complete() {
        isComplete = true
    }

    func snapshot() -> Bool {
        isComplete
    }
}

private enum BlockingDiagnosticTarget: Sendable {
    case completedStage
    case failedStage
    case failureEvent
}

private actor BlockingDiagnosticRepository: DiagnosticRepository {
    private let target: BlockingDiagnosticTarget
    private let gate: BlockingGate
    private var savedEvents: [DiagnosticEvent] = []

    init(target: BlockingDiagnosticTarget, gate: BlockingGate) {
        self.target = target
        self.gate = gate
    }

    func save(_ event: DiagnosticEvent) async throws {
        savedEvents.append(event)

        switch target {
        case .completedStage:
            if event.event == "session.stage", event.metadata["stage"] == "completed" {
                await gate.wait()
            }
        case .failedStage:
            if event.event == "session.stage", event.metadata["stage"] == "failed" {
                await gate.wait()
            }
        case .failureEvent:
            if event.event == "session.failure" {
                await gate.wait()
            }
        }
    }

    func events(matching query: DiagnosticQuery) async throws -> [DiagnosticEvent] {
        var filtered = savedEvents

        if let runID = query.runID {
            filtered = filtered.filter { $0.runID == runID }
        }

        if let subsystem = query.subsystem {
            filtered = filtered.filter { $0.subsystem == subsystem }
        }

        if let minimumLevel = query.minimumLevel {
            filtered = filtered.filter { $0.level.severity >= minimumLevel.severity }
        }

        if let since = query.since {
            filtered = filtered.filter { $0.timestamp >= since }
        }

        filtered.sort { $0.timestamp > $1.timestamp }

        if let limit = query.limit, limit >= 0 {
            filtered = Array(filtered.prefix(limit))
        }

        return filtered
    }

    func snapshot() -> [DiagnosticEvent] {
        savedEvents
    }
}

private actor QueueActionProbe {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

private struct BlockingQueueAction: OutputAction {
    let id = "blocking.queue.action"
    let probe: QueueActionProbe
    let gate: BlockingGate

    func execute(text: String, context: ActionContext) async throws -> ActionResult {
        await probe.record(context.workflow.name)
        await gate.wait()
        return .skipped(text)
    }
}

final class SessionCoordinatorTests: XCTestCase {
    func testCoordinatorResolvesAndPassesTypedRecognitionOptions() async {
        let eventBus = EventBus()
        let deliveryStack = DeliveryStack(eventBus: eventBus)
        let requestProbe = RecognitionRequestProbe()
        let actionProbe = ActionProbe()
        let workflow = WorkflowDefinition(
            name: "Hints",
            pipeline: PipelineDeclaration(
                recognizerID: "options.probe",
                outputActions: [OutputActionReference(id: "probe.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
        let expectedOptions = SpeechRecognitionRequestOptions(
            language: "zh-CN",
            hints: RecognitionHints(keyterms: ["Rill", "multi word"])
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [
                    OptionsProbeRecognizer(
                        supportsKeyterms: true,
                        probe: requestProbe
                    ),
                ]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: actionProbe)]),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            deliveryStack: deliveryStack,
            eventBus: eventBus,
            recognitionOptionsProvider: { _, _ in expectedOptions }
        )

        await coordinator.run(workflow: workflow, contextSnapshot: .empty)

        let requests = await requestProbe.snapshot()
        XCTAssertEqual(requests.map(\.options), [expectedOptions])
    }

    func testCoordinatorDropsUnsupportedHintsWithoutPublishingTheirContent() async {
        let keytermCanary = "private-keyterm-canary"
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let requestProbe = RecognitionRequestProbe()
        let actionProbe = ActionProbe()
        let workflow = WorkflowDefinition(
            name: "Unsupported Hints",
            pipeline: PipelineDeclaration(
                recognizerID: "options.probe",
                outputActions: [OutputActionReference(id: "probe.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [
                    OptionsProbeRecognizer(
                        supportsKeyterms: false,
                        probe: requestProbe
                    ),
                ]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: actionProbe)]),
            candidateResolver: CandidateResolver(eventBus: eventBus, diagnostics: diagnostics),
            deliveryStack: DeliveryStack(eventBus: eventBus, diagnostics: diagnostics),
            eventBus: eventBus,
            diagnostics: diagnostics
        )

        await coordinator.run(
            workflow: workflow,
            contextSnapshot: .empty,
            recognitionOptions: SpeechRecognitionRequestOptions(
                language: "en",
                hints: RecognitionHints(keyterms: [keytermCanary])
            )
        )

        let requests = await requestProbe.snapshot()
        XCTAssertEqual(requests.first?.options.language, "en")
        XCTAssertEqual(requests.first?.options.hints, .empty)
        let events = await diagnostics.snapshot(matching: DiagnosticQuery())
        let unsupported = events.first { $0.event == "session.recognition-hints.unsupported" }
        XCTAssertEqual(unsupported?.metadata["outcome"], "unsupported-recognizer")
        XCTAssertEqual(unsupported?.metadata["count"], "1")
        XCTAssertFalse(String(describing: events).contains(keytermCanary))
    }

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
        let collector = Task { () -> [RillEvent] in
            var events: [RillEvent] = []
            for await event in stream {
                events.append(event)
                if case .runCompleted = event {
                    break
                }
            }
            return events
        }
        await Task.yield()

        await coordinator.run(workflow: workflow, contextSnapshot: .empty)
        let events = await collector.value
        let probeValues = await probe.snapshot()

        XCTAssertEqual(probeValues, ["hello transformed"])
        XCTAssertTrue(events.contains { event in
            if case .recognitionCompleted(let recognition) = event {
                return recognition.bestText == "hello"
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .transformationApplied = event { return true }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .runCompleted = event { return true }
            return false
        })
    }

    func testWhitespaceOnlyRecognitionFailsBeforeCompletionTransformOrDelivery() async throws {
        let eventBus = EventBus()
        let repository = InMemoryWorkflowRunReceiptRepository()
        let recorder = WorkflowRunReceiptRecorder(repository: repository, eventBus: eventBus)
        let deliveryStack = DeliveryStack(eventBus: eventBus)
        let actionProbe = ActionProbe()
        let workflow = WorkflowDefinition(
            name: "No Speech Workflow",
            pipeline: PipelineDeclaration(
                recognizerID: "mock.recognizer",
                postProcessSteps: [PostProcessStep(kind: .normalizeWhitespace)],
                outputActions: [OutputActionReference(id: "probe.action")],
                uncertaintyPolicy: .init(mode: .off),
                deliveryPolicy: .init(strategy: .immediate)
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "orange")
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [
                    MockRecognizer(
                        result: RecognitionResult(rawText: "  \n\t", bestText: "  \n\t")
                    ),
                ]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: [MockTransformer()]),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: actionProbe)]),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            deliveryStack: deliveryStack,
            eventBus: eventBus,
            runReceiptRecorder: recorder
        )
        let runID = UUID()
        let stream = await eventBus.stream()
        let collector = Task { () -> [RillEvent] in
            var events: [RillEvent] = []
            for await event in stream {
                events.append(event)
                if case .runFailed = event { break }
            }
            return events
        }
        await Task.yield()

        let result = await coordinator.runReportingOutcome(
            workflow: workflow,
            runID: runID,
            contextSnapshot: .empty
        )
        let events = await collector.value
        let actions = await actionProbe.snapshot()
        let receipts = try await repository.receipts(matching: .init(runID: runID))

        XCTAssertEqual(
            result,
            .failed(
                WorkflowRunFailureSummary(
                    runID: runID,
                    stage: .recognizing,
                    code: .noSpeech
                )
            )
        )
        XCTAssertEqual(
            receipts.first?.termination,
            .failed(stage: .recognizing, code: .noSpeech)
        )
        XCTAssertEqual(actions, [])
        XCTAssertTrue(events.contains { event in
            if case .runFailed(let eventRunID, _, let message) = event {
                return eventRunID == runID
                    && message == SessionCoordinator.SessionError.noSpeech.localizedDescription
            }
            return false
        })
        XCTAssertFalse(events.contains { event in
            if case .recognitionCompleted = event { return true }
            return false
        })
        XCTAssertFalse(events.contains { event in
            if case .transformationApplied = event { return true }
            return false
        })
        XCTAssertFalse(events.contains { event in
            if case .actionExecuted = event { return true }
            return false
        })
        XCTAssertFalse(events.contains { event in
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
        let collector = Task { () -> [RillEvent] in
            var events: [RillEvent] = []
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
                return summary.workflow.titleKey == .stackDelivery
                    && summary.trigger == .stackDelivery
                    && summary.finalText == "stack item"
            }
            return false
        })
        let completion = events.compactMap { event -> WorkflowRunSummary? in
            guard case .runCompleted(let summary) = event else { return nil }
            return summary
        }.first
        XCTAssertNil(completion?.correctionSource)
    }

    func testClipboardDeliveryPreservesOnlyPrivacySafeFocusIdentity() async {
        let eventBus = EventBus()
        let deliveryStack = DeliveryStack(eventBus: eventBus)
        let contextProbe = ActionContextProbe()
        let identityContext = ContextSnapshot(
            focus: FocusSnapshot(
                applicationName: "Editor",
                bundleIdentifier: "com.example.Editor",
                processIdentifier: 42,
                focusedRole: "AXTextArea",
                selectedText: "",
                secureInput: false
            ),
            clipboard: ClipboardSnapshot(plainText: "", changeCount: 7)
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            privacyContextProvider: { identityContext },
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(
                actions: [ContextProbeAction(probe: contextProbe)]
            ),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            deliveryStack: deliveryStack,
            eventBus: eventBus
        )
        await deliveryStack.push(
            DeliveryItem(workflowID: UUID(), text: "CANARY-DELIVERY")
        )

        await coordinator.deliverTopOfStack(actionID: "focus.probe")

        let contexts = await contextProbe.snapshot()
        XCTAssertEqual(contexts.map(\.focus.bundleIdentifier), ["com.example.Editor"])
        XCTAssertEqual(contexts.map(\.focus.processIdentifier), [42])
        XCTAssertTrue(contexts.allSatisfy { $0.focus.selectedText.isEmpty })
        XCTAssertTrue(contexts.allSatisfy { $0.clipboard.plainText.isEmpty })
    }

    func testExplicitClipboardContextBypassesProviderAndFailureDoesNotMarkItemUsed() async {
        let eventBus = EventBus()
        let deliveryStack = DeliveryStack(eventBus: eventBus)
        let providerProbe = PrivacyContextCaptureProbe()
        let actionProbe = ActionContextProbe()
        let fallbackContext = ContextSnapshot(
            focus: FocusSnapshot(
                applicationName: "Wrong Target",
                bundleIdentifier: "com.example.Wrong",
                processIdentifier: 84,
                focusedRole: nil,
                selectedText: "",
                secureInput: false
            ),
            clipboard: ClipboardSnapshot(plainText: "", changeCount: 1)
        )
        let explicitContext = ContextSnapshot(
            focus: FocusSnapshot(
                applicationName: "Locked Target",
                bundleIdentifier: "com.example.Locked",
                processIdentifier: 42,
                focusedRole: "AXTextArea",
                selectedText: "",
                secureInput: false
            ),
            clipboard: ClipboardSnapshot(plainText: "", changeCount: 2)
        )
        let item = DeliveryItem(workflowID: UUID(), text: "saved text")
        await deliveryStack.push(item)
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            privacyContextProvider: { await providerProbe.capture(fallbackContext) },
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(
                actions: [FailingContextProbeAction(probe: actionProbe)]
            ),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            deliveryStack: deliveryStack,
            eventBus: eventBus
        )
        guard let subject = await deliveryStack.clipboardItemDryRunSubject(itemID: item.id) else {
            return XCTFail("Expected an exact clipboard item subject.")
        }

        await coordinator.deliverClipboardItem(
            subject: subject,
            actionID: "failing.context.probe",
            contextSnapshot: explicitContext
        )

        let providerCaptureCount = await providerProbe.count()
        let recordedContexts = await actionProbe.snapshot()
        let storedItem = await deliveryStack.item(id: item.id)
        let finalState = await coordinator.currentState()
        XCTAssertEqual(providerCaptureCount, 0)
        XCTAssertEqual(recordedContexts, [explicitContext])
        XCTAssertEqual(storedItem?.useCount, 0)
        XCTAssertNil(storedItem?.lastUsedAt)
        XCTAssertEqual(finalState, .idle)
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

        await coordinator.run(workflow: workflow, contextSnapshot: .empty)
        let stageEvents = await diagnostics.snapshot(
            matching: DiagnosticQuery(subsystem: .session)
        ).filter { $0.event == "session.stage" }

        let stages = Set(stageEvents.compactMap { $0.metadata["stage"] })
        let workflows = Set(stageEvents.compactMap { $0.metadata["workflow"] })

        XCTAssertTrue(stages.isSuperset(of: ["preparing", "recognizing", "transforming", "delivering", "completed"]))
        XCTAssertTrue(workflows.isEmpty, "User-authored workflow names must not enter diagnostics.")
        XCTAssertEqual(
            stageEvents.first { $0.metadata["stage"] == "recognizing" }?.metadata["recognizerID"],
            "mock.recognizer"
        )
        XCTAssertEqual(stageEvents.first { $0.metadata["stage"] == "transforming" }?.metadata["stepCount"], "1")
        XCTAssertEqual(stageEvents.first { $0.metadata["stage"] == "delivering" }?.metadata["actionCount"], "1")
        XCTAssertNotNil(stageEvents.first { $0.metadata["stage"] == "completed" }?.metadata["durationMillis"])

        let transformStepEvents = await diagnostics.snapshot(matching: DiagnosticQuery(subsystem: .session))
            .filter { $0.event == "session.transform.step" }
        XCTAssertEqual(transformStepEvents.first?.metadata["stepKind"], PostProcessStepKind.normalizeWhitespace.rawValue)
        XCTAssertEqual(transformStepEvents.first?.metadata["transformerID"], "mock.transformer")

        let actionEvents = await diagnostics.snapshot(matching: DiagnosticQuery(subsystem: .session))
            .filter { $0.event == "session.action" }
        XCTAssertEqual(actionEvents.first?.metadata["actionID"], "probe.action")
        XCTAssertEqual(actionEvents.first?.metadata["resultCode"], "skipped")
        XCTAssertNil(actionEvents.first?.metadata["result"])
        XCTAssertFalse(actionEvents.contains { event in
            event.message.contains("captured") || event.metadata.values.contains(where: { $0.contains("captured") })
        })
    }

    func testCoordinatorUsesProvidedRunIDWhenSupplied() async {
        let eventBus = EventBus()
        let deliveryStack = DeliveryStack(eventBus: eventBus)
        let resolver = CandidateResolver(eventBus: eventBus)
        let probe = ActionProbe()
        let expectedRunID = UUID()

        let workflow = WorkflowDefinition(
            name: "Explicit RunID Workflow",
            pipeline: PipelineDeclaration(
                recognizerID: "mock.recognizer",
                outputActions: [OutputActionReference(id: "probe.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "testtube.2", accentColorName: "green")
        )

        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [MockRecognizer(result: RecognitionResult(rawText: "hello", bestText: "hello"))]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: probe)]),
            candidateResolver: resolver,
            deliveryStack: deliveryStack,
            eventBus: eventBus
        )

        let stream = await eventBus.stream()
        let collector = Task { () -> [RillEvent] in
            var events: [RillEvent] = []
            for await event in stream {
                events.append(event)
                if case .runCompleted = event {
                    break
                }
            }
            return events
        }
        await Task.yield()

        await coordinator.run(
            workflow: workflow,
            runID: expectedRunID,
            contextSnapshot: .empty
        )
        let events = await collector.value

        XCTAssertTrue(events.contains { event in
            if case .runStarted(let snapshot) = event {
                return snapshot.runID == expectedRunID
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .runCompleted(let summary) = event {
                return summary.runID == expectedRunID && summary.trigger == .manual
            }
            return false
        })
    }

    func testCoordinatorPushesVoiceResultIntoTargetClipboardGroup() async {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let deliveryStack = DeliveryStack(eventBus: eventBus, diagnostics: diagnostics)
        let resolver = CandidateResolver(eventBus: eventBus, diagnostics: diagnostics)
        let workflow = WorkflowDefinition(
            name: "Voice Group Workflow",
            pipeline: PipelineDeclaration(
                recognizerID: "mock.recognizer",
                outputActions: [OutputActionReference(id: "group.stack.action")],
                uncertaintyPolicy: UncertaintyPolicy(mode: .off, confidenceThreshold: 0, timeoutSeconds: 0),
                deliveryPolicy: DeliveryPolicy(strategy: .stackFirst)
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "purple"),
            metadata: [WorkflowMetadataKey.targetClipboardGroupID: ClipboardGroup.voiceGroupID.uuidString]
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [MockRecognizer(result: RecognitionResult(rawText: "voice result", bestText: "voice result"))]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [GroupAwareStackAction(stack: deliveryStack)]),
            candidateResolver: resolver,
            deliveryStack: deliveryStack,
            eventBus: eventBus,
            diagnostics: diagnostics
        )

        await coordinator.run(workflow: workflow, contextSnapshot: .empty)
        let snapshot = await deliveryStack.clipboardSnapshot()
        let sessionDiagnostics = await diagnostics.snapshot(matching: DiagnosticQuery(subsystem: .session))

        XCTAssertEqual(snapshot.items.first?.text, "voice result")
        XCTAssertEqual(snapshot.items.first?.groupID, ClipboardGroup.voiceGroupID)
        XCTAssertEqual(snapshot.remainingItemIDs, snapshot.items.map(\.id))
        XCTAssertTrue(sessionDiagnostics.contains { event in
            event.event == "session.action" && event.metadata["actionID"] == "group.stack.action"
        })
    }

    func testRecognizerFailurePublishesFailureEventAndDiagnostics() async {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let deliveryStack = DeliveryStack(eventBus: eventBus, diagnostics: diagnostics)
        let resolver = CandidateResolver(eventBus: eventBus, diagnostics: diagnostics)
        let actionProbe = ActionProbe()
        let expectedRunID = UUID()
        let workflow = WorkflowDefinition(
            name: "Failing Workflow",
            pipeline: PipelineDeclaration(
                recognizerID: "failing.recognizer",
                outputActions: [OutputActionReference(id: "probe.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "red")
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [FailingRecognizer(message: "Recognizer unavailable")]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: actionProbe)]),
            candidateResolver: resolver,
            deliveryStack: deliveryStack,
            eventBus: eventBus,
            diagnostics: diagnostics
        )
        let stream = await eventBus.stream()
        let collector = Task { () -> [RillEvent] in
            var events: [RillEvent] = []
            for await event in stream {
                events.append(event)
                if case .runFailed = event {
                    break
                }
            }
            return events
        }
        await Task.yield()

        await coordinator.run(
            workflow: workflow,
            runID: expectedRunID,
            contextSnapshot: .empty
        )
        let events = await collector.value
        let diagnosticEvents = await diagnostics.snapshot(matching: DiagnosticQuery(subsystem: .session))

        XCTAssertTrue(events.contains { event in
            if case .runFailed(let runID, let presentation, let message) = event {
                return runID == expectedRunID && presentation == workflow.presentation && message == "Recognizer unavailable"
            }
            return false
        })
        XCTAssertTrue(diagnosticEvents.contains { event in
            event.event == "session.stage" && event.metadata["stage"] == "failed"
        })
        XCTAssertTrue(diagnosticEvents.contains { event in
            event.event == "session.failure"
                && event.message == DiagnosticEventSanitizer.sanitizedMessage
        })
        XCTAssertFalse(diagnosticEvents.contains { event in
            event.message.contains("Recognizer unavailable")
                || event.metadata.values.contains(where: { $0.contains("Recognizer unavailable") })
        })
        let finalState = await coordinator.currentState()
        XCTAssertEqual(finalState, .idle)
    }

    func testCoordinatorAppliesScopedVocabularyMappingsBeforePostProcessing() async {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let deliveryStack = DeliveryStack(eventBus: eventBus, diagnostics: diagnostics)
        let resolver = CandidateResolver(eventBus: eventBus, diagnostics: diagnostics)
        let probe = ActionProbe()
        let workflow = WorkflowDefinition(
            name: "Vocabulary Workflow",
            pipeline: PipelineDeclaration(
                recognizerID: "mock.recognizer",
                postProcessSteps: [PostProcessStep(kind: .normalizeWhitespace)],
                outputActions: [OutputActionReference(id: "probe.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "text.badge.checkmark", accentColorName: "green"),
            metadata: [
                WorkflowMetadataKey.targetClipboardGroupID: ClipboardGroup.voiceGroupID.uuidString,
                WorkflowMetadataKey.languageOverride: "zh",
            ]
        )
        let context = ContextSnapshot(
            focus: FocusSnapshot(
                applicationName: "Editor",
                bundleIdentifier: "com.example.editor",
                processIdentifier: 42,
                focusedRole: "AXTextArea",
                selectedText: "",
                secureInput: false
            ),
            clipboard: ClipboardSnapshot(plainText: "", changeCount: 0)
        )
        let rules = [
            VocabularyRule(
                pattern: "vux type",
                replacement: "Rill",
                scope: VocabularyRuleScope(
                    bundleIdentifier: "com.example.editor",
                    clipboardGroupID: ClipboardGroup.voiceGroupID,
                    locale: "zh"
                )
            ),
            VocabularyRule(
                pattern: "stay local",
                replacement: "leave the device",
                scope: VocabularyRuleScope(bundleIdentifier: "com.example.other")
            ),
            VocabularyRule(kind: .hotword, pattern: "local", replacement: "cloud")
        ]
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [
                    MockRecognizer(
                        result: RecognitionResult(
                            rawText: "vux type should stay local",
                            bestText: "vux type should stay local"
                        )
                    )
                ]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: [MockTransformer()]),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: probe)]),
            candidateResolver: resolver,
            deliveryStack: deliveryStack,
            eventBus: eventBus,
            diagnostics: diagnostics,
            vocabularyRuleProvider: { rules }
        )

        await coordinator.run(workflow: workflow, contextSnapshot: context)

        let deliveredValues = await probe.snapshot()
        XCTAssertEqual(deliveredValues, ["Rill should stay local transformed"])
        let vocabularyEvent = await diagnostics.snapshot(matching: DiagnosticQuery(subsystem: .session))
            .first { $0.event == "session.vocabulary.applied" }
        XCTAssertEqual(vocabularyEvent?.metadata["applicationCount"], "1")
        XCTAssertEqual(vocabularyEvent?.metadata["replacementCount"], "1")
        XCTAssertEqual(vocabularyEvent?.metadata["issueCount"], "0")
    }

    func testCompletionCarriesResolvedPreMappingTextAndVocabularyContext() async throws {
        let eventBus = EventBus()
        let deliveryStack = DeliveryStack(eventBus: eventBus)
        let resolver = CandidateResolver(eventBus: eventBus)
        let probe = ActionProbe()
        let targetGroupID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let candidateSetID = UUID(uuidString: "00000000-0000-0000-0000-000000000043")!
        let selectedCandidateID = UUID(uuidString: "00000000-0000-0000-0000-000000000044")!
        let recognition = RecognitionResult(
            rawText: "vux tipe",
            bestText: "vux tipe",
            candidateSets: [
                CandidateSet(
                    id: candidateSetID,
                    surfaceText: "vux tipe",
                    range: TextRange(lowerBound: 0, upperBound: 8),
                    candidates: [
                        Candidate(text: "vux typo", confidence: 0.9, source: .asr),
                        Candidate(
                            id: selectedCandidateID,
                            text: "vux type",
                            confidence: 0.7,
                            source: .user
                        ),
                    ]
                ),
            ]
        )
        let workflow = WorkflowDefinition(
            name: "Correction Source Workflow",
            pipeline: PipelineDeclaration(
                recognizerID: "mock.recognizer",
                postProcessSteps: [PostProcessStep(kind: .normalizeWhitespace)],
                outputActions: [OutputActionReference(id: "probe.action")],
                uncertaintyPolicy: UncertaintyPolicy(
                    mode: .blocking,
                    confidenceThreshold: 0.72,
                    timeoutSeconds: 30
                )
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue"),
            metadata: [
                WorkflowMetadataKey.targetClipboardGroupID: targetGroupID.uuidString,
                WorkflowMetadataKey.languageOverride: "en-US",
            ]
        )
        let context = ContextSnapshot(
            focus: FocusSnapshot(
                applicationName: "Editor",
                bundleIdentifier: "com.example.editor",
                processIdentifier: 42,
                focusedRole: "AXTextArea",
                selectedText: "unrelated selected text",
                secureInput: false
            ),
            clipboard: ClipboardSnapshot(plainText: "unrelated clipboard text", changeCount: 7)
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [MockRecognizer(result: recognition)]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: [MockTransformer()]),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: probe)]),
            candidateResolver: resolver,
            deliveryStack: deliveryStack,
            eventBus: eventBus,
            vocabularyRuleProvider: {
                [
                    VocabularyRule(
                        pattern: "vux type",
                        replacement: "Rill",
                        scope: VocabularyRuleScope(
                            bundleIdentifier: "com.example.editor",
                            clipboardGroupID: targetGroupID,
                            locale: "zh-CN"
                        )
                    ),
                ]
            }
        )

        let stream = await eventBus.stream()
        let summaryTask = Task { () -> WorkflowRunSummary? in
            for await event in stream {
                switch event {
                case .candidateResolutionRequested(let candidateCase):
                    _ = await resolver.accept(
                        caseID: candidateCase.id,
                        selections: [candidateSetID: selectedCandidateID]
                    )
                case .runCompleted(let summary):
                    return summary
                default:
                    continue
                }
            }
            return nil
        }
        await Task.yield()

        await coordinator.run(
            workflow: workflow,
            contextSnapshot: context,
            recognitionOptions: SpeechRecognitionRequestOptions(language: "zh-CN")
        )

        let optionalSummary = await summaryTask.value
        let deliveredTexts = await probe.snapshot()
        let summary = try XCTUnwrap(optionalSummary)
        XCTAssertEqual(deliveredTexts, ["Rill transformed"])
        XCTAssertEqual(summary.finalText, "Rill transformed")
        XCTAssertEqual(summary.correctionSource?.preMappingText, "vux type")
        XCTAssertEqual(
            summary.correctionSource?.context,
            VocabularyRuleContext(
                bundleIdentifier: "com.example.editor",
                clipboardGroupID: targetGroupID,
                locale: "zh-CN"
            )
        )
    }

    func testVocabularyProviderFailureDoesNotDiscardRecognizedText() async {
        struct LoadFailure: Error {}

        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let deliveryStack = DeliveryStack(eventBus: eventBus, diagnostics: diagnostics)
        let resolver = CandidateResolver(eventBus: eventBus, diagnostics: diagnostics)
        let probe = ActionProbe()
        let workflow = WorkflowDefinition(
            name: "Vocabulary Fallback Workflow",
            pipeline: PipelineDeclaration(
                recognizerID: "mock.recognizer",
                outputActions: [OutputActionReference(id: "probe.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "text.badge.xmark", accentColorName: "orange")
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [MockRecognizer(result: RecognitionResult(rawText: "original", bestText: "original"))]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: probe)]),
            candidateResolver: resolver,
            deliveryStack: deliveryStack,
            eventBus: eventBus,
            diagnostics: diagnostics,
            vocabularyRuleProvider: { throw LoadFailure() }
        )

        await coordinator.run(workflow: workflow, contextSnapshot: .empty)

        let deliveredValues = await probe.snapshot()
        XCTAssertEqual(deliveredValues, ["original"])
        let events = await diagnostics.snapshot(matching: DiagnosticQuery(subsystem: .session))
        XCTAssertTrue(events.contains { $0.event == "session.vocabulary.load-failed" && $0.level == .warning })
    }

    func testMissingTransformerFailsInsteadOfSilentlyReturningUnprocessedText() async {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let deliveryStack = DeliveryStack(eventBus: eventBus, diagnostics: diagnostics)
        let probe = ActionProbe()
        let workflow = WorkflowDefinition(
            name: "Unsupported Rewrite",
            pipeline: PipelineDeclaration(
                recognizerID: "mock.recognizer",
                postProcessSteps: [PostProcessStep(kind: .llmRewrite, prompt: "Rewrite")],
                outputActions: [OutputActionReference(id: "probe.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "exclamationmark.triangle", accentColorName: "orange")
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [MockRecognizer(result: RecognitionResult(rawText: "raw", bestText: "raw"))]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: probe)]),
            candidateResolver: CandidateResolver(eventBus: eventBus, diagnostics: diagnostics),
            deliveryStack: deliveryStack,
            eventBus: eventBus,
            diagnostics: diagnostics
        )

        await coordinator.run(workflow: workflow, contextSnapshot: .empty)

        let deliveredValues = await probe.snapshot()
        XCTAssertTrue(deliveredValues.isEmpty)
        let events = await diagnostics.snapshot(matching: DiagnosticQuery(subsystem: .session))
        XCTAssertTrue(events.contains { event in
            event.event == "session.failure"
                && event.message == DiagnosticEventSanitizer.sanitizedMessage
        })
    }

    func testUnregisteredOutputActionFailsBeforeRecognitionStarts() async {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let workflow = WorkflowDefinition(
            name: "Legacy Webhook Workflow",
            pipeline: PipelineDeclaration(
                recognizerID: "failing.recognizer",
                outputActions: [OutputActionReference(id: ExternalOutputActionID.webhookPost)]
            ),
            ui: WorkflowUIConfig(symbolName: "network.slash", accentColorName: "orange")
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [FailingRecognizer(message: "Recognizer must not run")]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus, diagnostics: diagnostics),
            deliveryStack: DeliveryStack(eventBus: eventBus, diagnostics: diagnostics),
            eventBus: eventBus,
            diagnostics: diagnostics
        )

        await coordinator.run(workflow: workflow, contextSnapshot: .empty)

        let events = await diagnostics.snapshot(matching: DiagnosticQuery(subsystem: .session))
        XCTAssertTrue(events.contains { event in
            event.event == "session.failure"
                && event.message == DiagnosticEventSanitizer.sanitizedMessage
        })
        XCTAssertFalse(events.contains { event in
            event.event == "session.failure" && event.message == "Recognizer must not run"
        })
        XCTAssertFalse(events.contains { event in
            event.event == "session.stage" && event.metadata["stage"] == "recognizing"
        })
    }

    func testReportedRecognizerFailureUsesContentFreeRecoverableClassification() async {
        let eventBus = EventBus()
        let workflow = WorkflowDefinition(
            name: "Reported Failure",
            pipeline: PipelineDeclaration(
                recognizerID: "failing.recognizer",
                outputActions: []
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "red")
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [FailingRecognizer(message: "private provider detail")]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            deliveryStack: DeliveryStack(eventBus: eventBus),
            eventBus: eventBus
        )
        let runID = UUID()

        let result = await coordinator.runReportingOutcome(
            workflow: workflow,
            runID: runID,
            contextSnapshot: .empty
        )

        XCTAssertEqual(
            result,
            .failed(
                WorkflowRunFailureSummary(
                    runID: runID,
                    stage: .recognizing,
                    code: .processing
                )
            )
        )
        guard case .failed(let failure) = result else {
            return XCTFail("Expected a failure result.")
        }
        XCTAssertTrue(failure.isCapturedAudioRecoveryEligible)
    }

    func testReturnedActionFailureTerminatesRunAndStopsLaterActions() async {
        let eventBus = EventBus()
        let actionProbe = ActionProbe()
        let failureCanary = "ACTION-FAILURE-CANARY"
        let workflow = WorkflowDefinition(
            name: "Returned Action Failure",
            pipeline: PipelineDeclaration(
                recognizerID: "mock.recognizer",
                outputActions: [
                    OutputActionReference(id: "reported.failure"),
                    OutputActionReference(id: "must.not.run"),
                ]
            ),
            ui: WorkflowUIConfig(symbolName: "xmark.octagon", accentColorName: "red")
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [MockRecognizer(result: RecognitionResult(rawText: "input", bestText: "input"))]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [
                ResultAction(id: "reported.failure", result: .failed(failureCanary), probe: actionProbe),
                ResultAction(id: "must.not.run", result: .copiedToClipboard, probe: actionProbe),
            ]),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            deliveryStack: DeliveryStack(eventBus: eventBus),
            eventBus: eventBus
        )
        let stream = await eventBus.stream()
        let collector = Task { () -> [RillEvent] in
            var events: [RillEvent] = []
            for await event in stream {
                events.append(event)
                if case .runFailed = event { break }
            }
            return events
        }
        await Task.yield()

        let result = await coordinator.runReportingOutcome(
            workflow: workflow,
            contextSnapshot: .empty
        )
        let events = await collector.value
        let executedActionIDs = await actionProbe.snapshot()

        XCTAssertEqual(executedActionIDs, ["reported.failure"])
        guard case .failed(let failure) = result else {
            return XCTFail("Expected the returned action failure to fail the run.")
        }
        XCTAssertEqual(failure.stage, .delivering)
        XCTAssertEqual(failure.code, .processing)
        XCTAssertTrue(events.contains { event in
            if case .actionExecuted(actionID: "reported.failure", result: .failed(failureCanary)) = event {
                return true
            }
            return false
        })
        XCTAssertFalse(events.contains { event in
            if case .runCompleted = event { return true }
            return false
        })
    }

    func testReturnedStackActionFailureDoesNotConsumeLeasedItem() async {
        let eventBus = EventBus()
        let deliveryStack = DeliveryStack(eventBus: eventBus)
        let actionProbe = ActionProbe()
        let itemID = UUID()
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [
                ResultAction(
                    id: "reported.failure",
                    result: .failed("STACK-FAILURE-CANARY"),
                    probe: actionProbe
                ),
            ]),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            deliveryStack: deliveryStack,
            eventBus: eventBus
        )
        await deliveryStack.push(
            DeliveryItem(id: itemID, workflowID: UUID(), text: "retain me")
        )

        await coordinator.deliverTopOfStack(actionID: "reported.failure")

        let snapshot = await deliveryStack.clipboardSnapshot()
        let executedActionIDs = await actionProbe.snapshot()
        XCTAssertEqual(executedActionIDs, ["reported.failure"])
        XCTAssertTrue(snapshot.remainingItemIDs.contains(itemID))
        XCTAssertEqual(snapshot.items.first(where: { $0.id == itemID })?.useCount, 0)
    }

    func testReportedConfigurationFailureIsClassifiedBeforeRecognition() async {
        let eventBus = EventBus()
        let workflow = WorkflowDefinition(
            name: "Missing Output",
            pipeline: PipelineDeclaration(
                recognizerID: "failing.recognizer",
                outputActions: [OutputActionReference(id: "missing.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "red")
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [FailingRecognizer(message: "recognizer must not run")]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            deliveryStack: DeliveryStack(eventBus: eventBus),
            eventBus: eventBus
        )
        let runID = UUID()

        let result = await coordinator.runReportingOutcome(
            workflow: workflow,
            runID: runID,
            contextSnapshot: .empty
        )

        XCTAssertEqual(
            result,
            .failed(
                WorkflowRunFailureSummary(
                    runID: runID,
                    stage: .preparing,
                    code: .configuration
                )
            )
        )
    }

    func testMissingAuthorizedContextFailsBeforeRecognizerAndActions() async {
        let eventBus = EventBus()
        let requestProbe = RecognitionRequestProbe()
        let actionProbe = ActionProbe()
        let workflow = WorkflowDefinition(
            name: "Authorization Boundary",
            pipeline: PipelineDeclaration(
                recognizerID: "options.probe",
                outputActions: [OutputActionReference(id: "probe.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "lock.shield", accentColorName: "red")
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [
                    OptionsProbeRecognizer(
                        supportsKeyterms: false,
                        probe: requestProbe
                    ),
                ]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: actionProbe)]),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            deliveryStack: DeliveryStack(eventBus: eventBus),
            eventBus: eventBus
        )
        let runID = UUID()

        let result = await coordinator.runReportingOutcome(
            workflow: workflow,
            runID: runID
        )

        XCTAssertEqual(
            result,
            .failed(
                WorkflowRunFailureSummary(
                    runID: runID,
                    stage: .preparing,
                    code: .configuration
                )
            )
        )
        let recognitionRequests = await requestProbe.snapshot()
        let actionValues = await actionProbe.snapshot()
        let state = await coordinator.currentState()
        XCTAssertTrue(recognitionRequests.isEmpty)
        XCTAssertTrue(actionValues.isEmpty)
        XCTAssertEqual(state, .idle)
    }

}

extension SessionCoordinatorTests {
    func testStackDeliveryReservesCoordinatorBeforeAwaitingStackInitialization() async {
        let loadStarted = BlockingGate()
        let releaseLoad = BlockingGate()
        let settingsStore = BlockingInitializationSettingsStore(
            loadStarted: loadStarted,
            releaseLoad: releaseLoad
        )
        let eventBus = EventBus()
        let deliveryStack = DeliveryStack(
            eventBus: eventBus,
            clipboardPersistenceStore: settingsStore
        )
        await loadStarted.wait()

        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            deliveryStack: deliveryStack,
            eventBus: eventBus
        )
        let firstDelivery = Task {
            await coordinator.deliverTopOfStack()
        }

        var reservedBeforeStackLoad = false
        for _ in 0..<200 {
            if case .delivering = await coordinator.currentState() {
                reservedBeforeStackLoad = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(
            reservedBeforeStackLoad,
            "The coordinator must become busy before awaiting another actor."
        )

        let secondCompletion = CompletionProbe()
        let secondDelivery = Task {
            await coordinator.deliverTopOfStack()
            await secondCompletion.complete()
        }
        for _ in 0..<200 {
            if await secondCompletion.snapshot() { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        let rejectedWhileFirstWasBlocked = await secondCompletion.snapshot()
        XCTAssertTrue(
            rejectedWhileFirstWasBlocked,
            "A concurrent delivery must be rejected instead of entering the blocked stack call."
        )

        await releaseLoad.resume()
        await firstDelivery.value
        await secondDelivery.value
        let finalState = await coordinator.currentState()
        XCTAssertEqual(finalState, .idle)
    }

    func testCapturedAudioQueuePreservesTheCaptureTimeOptionsSnapshot() async throws {
        let eventBus = EventBus()
        let requestProbe = RecognitionRequestProbe()
        let actionProbe = ActionProbe()
        let workflow = WorkflowDefinition(
            name: "Queued Hints",
            pipeline: PipelineDeclaration(
                recognizerID: "options.probe",
                outputActions: [OutputActionReference(id: "probe.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
        let capturedOptions = SpeechRecognitionRequestOptions(
            language: "zh-CN",
            hints: RecognitionHints(keyterms: ["capture-time-term"])
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [
                    OptionsProbeRecognizer(
                        supportsKeyterms: true,
                        probe: requestProbe
                    ),
                ]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: actionProbe)]),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            deliveryStack: DeliveryStack(eventBus: eventBus),
            eventBus: eventBus,
            recognitionOptionsProvider: { _, _ in
                SpeechRecognitionRequestOptions(
                    language: "stale",
                    hints: RecognitionHints(keyterms: ["stale-term"])
                )
            }
        )
        let queue = CapturedAudioProcessingQueue(
            sessionCoordinator: coordinator,
            eventBus: eventBus
        )
        let audio = try CapturedAudio(
            durationSeconds: 1,
            format: AudioFormat(
                sampleRateHz: 16_000,
                channelCount: 1,
                encoding: .pcm16
            ),
            inlineData: Data()
        )

        await queue.enqueue(
            authorizationLease: makeAudioProcessingTestLease(
                runID: UUID(),
                workflow: workflow,
                recognitionOptions: capturedOptions
            ),
            triggerEvent: nil,
            deferredCapture: .resolved(audio)
        )

        for _ in 0..<200 {
            if await requestProbe.snapshot().count == 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let requests = await requestProbe.snapshot()
        XCTAssertEqual(requests.map(\.options), [capturedOptions])
    }

    func testDeliverTopOfStackKeepsStateBusyUntilCompletedDiagnosticsFinish() async {
        let eventBus = EventBus()
        let gate = BlockingGate()
        let repository = BlockingDiagnosticRepository(target: .completedStage, gate: gate)
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus, repository: repository)
        let deliveryStack = DeliveryStack(eventBus: eventBus, diagnostics: diagnostics)
        let resolver = CandidateResolver(eventBus: eventBus, diagnostics: diagnostics)
        let probe = ActionProbe()

        await deliveryStack.push(
            DeliveryItem(
                workflowID: UUID(),
                text: "stack item"
            )
        )

        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [MockRecognizer(result: RecognitionResult(rawText: "hello", bestText: "hello"))]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: probe)]),
            candidateResolver: resolver,
            deliveryStack: deliveryStack,
            eventBus: eventBus,
            diagnostics: diagnostics
        )

        let task = Task {
            await coordinator.deliverTopOfStack(actionID: "probe.action")
        }

        var sawCompletedStage = false
        for _ in 0..<200 {
            let events = await repository.snapshot()
            if events.contains(where: { $0.event == "session.stage" && $0.metadata["stage"] == "completed" }) {
                sawCompletedStage = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(sawCompletedStage)

        let stateWhileBlocked = await coordinator.currentState()
        if case .delivering = stateWhileBlocked {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected the coordinator to stay busy until completed diagnostics finished.")
        }

        await gate.resume()
        await task.value

        let finalState = await coordinator.currentState()
        let probeValues = await probe.snapshot()
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(probeValues, ["stack item"])
    }

    func testRunFailureKeepsStateBusyUntilFailureDiagnosticsFinish() async {
        let eventBus = EventBus()
        let gate = BlockingGate()
        let repository = BlockingDiagnosticRepository(target: .failureEvent, gate: gate)
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus, repository: repository)
        let deliveryStack = DeliveryStack(eventBus: eventBus, diagnostics: diagnostics)
        let resolver = CandidateResolver(eventBus: eventBus, diagnostics: diagnostics)
        let actionProbe = ActionProbe()
        let workflow = WorkflowDefinition(
            name: "Failure State Workflow",
            pipeline: PipelineDeclaration(
                recognizerID: "missing.recognizer",
                outputActions: [OutputActionReference(id: "probe.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "testtube.2", accentColorName: "green")
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: actionProbe)]),
            candidateResolver: resolver,
            deliveryStack: deliveryStack,
            eventBus: eventBus,
            diagnostics: diagnostics
        )
        let expectedRunID = UUID()

        let task = Task {
            await coordinator.run(
                workflow: workflow,
                runID: expectedRunID,
                contextSnapshot: .empty
            )
        }

        var sawFailureEvent = false
        for _ in 0..<200 {
            let events = await repository.snapshot()
            if events.contains(where: { $0.event == "session.failure" }) {
                sawFailureEvent = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(sawFailureEvent)

        let stateWhileBlocked = await coordinator.currentState()
        XCTAssertEqual(stateWhileBlocked, .running(expectedRunID))

        await gate.resume()
        await task.value

        let finalState = await coordinator.currentState()
        XCTAssertEqual(finalState, .idle)
    }

    func testCapturedAudioProcessingQueueProcessesJobsSequentially() async throws {
        let eventBus = EventBus()
        let deliveryStack = DeliveryStack(eventBus: eventBus)
        let resolver = CandidateResolver(eventBus: eventBus)
        let gate = BlockingGate()
        let probe = QueueActionProbe()
        let audio = try CapturedAudio(
            durationSeconds: 1.0,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: URL(fileURLWithPath: "/tmp/rill-queue-test.caf")
        )
        let workflowA = WorkflowDefinition(
            name: "Queue Workflow A",
            pipeline: PipelineDeclaration(
                recognizerID: "mock.recognizer",
                outputActions: [OutputActionReference(id: "blocking.queue.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "testtube.2", accentColorName: "green")
        )
        let workflowB = WorkflowDefinition(
            name: "Queue Workflow B",
            pipeline: PipelineDeclaration(
                recognizerID: "mock.recognizer",
                outputActions: [OutputActionReference(id: "blocking.queue.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "testtube.2", accentColorName: "blue")
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [MockRecognizer(result: RecognitionResult(rawText: "queue text", bestText: "queue text"))]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [
                BlockingQueueAction(probe: probe, gate: gate)
            ]),
            candidateResolver: resolver,
            deliveryStack: deliveryStack,
            eventBus: eventBus
        )
        let queue = CapturedAudioProcessingQueue(sessionCoordinator: coordinator, eventBus: eventBus)
        let firstRunID = UUID()
        let secondRunID = UUID()

        await queue.enqueue(
            authorizationLease: makeAudioProcessingTestLease(
                runID: firstRunID,
                workflow: workflowA
            ),
            triggerEvent: nil,
            deferredCapture: .resolved(audio)
        )

        var sawFirstJob = false
        for _ in 0..<200 {
            let snapshot = await queue.snapshot()
            if snapshot.processingRunID == firstRunID {
                sawFirstJob = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(sawFirstJob)

        await queue.enqueue(
            authorizationLease: makeAudioProcessingTestLease(
                runID: secondRunID,
                workflow: workflowB
            ),
            triggerEvent: nil,
            deferredCapture: .resolved(audio)
        )

        let queuedSnapshot = await queue.snapshot()
        XCTAssertEqual(queuedSnapshot.processingRunID, firstRunID)
        XCTAssertEqual(queuedSnapshot.pendingCount, 2)

        for _ in 0..<200 {
            let values = await probe.snapshot()
            if values.count == 1 {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        await gate.resume()

        for _ in 0..<200 {
            let values = await probe.snapshot()
            if values.count == 2 {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let secondSnapshot = await queue.snapshot()
        XCTAssertEqual(secondSnapshot.processingRunID, secondRunID)
        XCTAssertEqual(secondSnapshot.pendingCount, 1)

        await gate.resume()

        for _ in 0..<200 {
            let snapshot = await queue.snapshot()
            if snapshot.pendingCount == 0 {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let finalValues = await probe.snapshot()
        let finalQueueSnapshot = await queue.snapshot()
        XCTAssertEqual(finalValues, ["Queue Workflow A", "Queue Workflow B"])
        XCTAssertEqual(finalQueueSnapshot.pendingCount, 0)
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

        let stream = await eventBus.stream()
        let completionTask = Task { () -> WorkflowRunSummary? in
            for await event in stream {
                if case .runCompleted(let summary) = event {
                    return summary
                }
            }
            return nil
        }
        await Task.yield()

        await coordinator.replayClipboardItem(
            itemID: itemID,
            workflow: workflow,
            contextSnapshot: .empty,
            recognitionOptions: .empty
        )
        let probeValues = await probe.snapshot()
        let completion = await completionTask.value

        XCTAssertEqual(probeValues, ["saved item transformed"])
        XCTAssertEqual(completion?.trigger, .clipboardReplay)
        XCTAssertNil(completion?.correctionSource)
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
            contextSnapshot: .empty,
            recognitionOptions: .empty,
            replacingSourceItem: true
        )

        let updatedSnapshot = await deliveryStack.clipboardSnapshot()
        let updatedRoute = await deliveryStack.routeSnapshot(
            for: ClipboardRouteContext(
                applicationName: "Safari",
                bundleIdentifier: "com.apple.Safari"
            )
        )
        XCTAssertEqual(updatedSnapshot.items.count, 1)
        XCTAssertEqual(updatedSnapshot.items.first?.id, originalItem.id)
        XCTAssertEqual(updatedSnapshot.items.first?.groupID, originalItem.groupID)
        XCTAssertEqual(updatedSnapshot.items.first?.text, "saved item transformed")
        XCTAssertEqual(updatedRoute.count, 1)
        XCTAssertEqual(updatedRoute.previewText, "saved item transformed")
        XCTAssertNil(updatedSnapshot.groups.first(where: { $0.group.id == originalItem.groupID }))
    }
}
