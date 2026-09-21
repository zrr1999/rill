import XCTest
@testable import RillCore
@testable import RillRuntime

private struct MockContextProvider: ContextProvider {
    func captureContext() async -> ContextSnapshot { .empty }
}

private func makeStoredRecordDraft(_ text: String) -> RecordDraft {
    RecordDraft(
        payload: .text(text),
        provenance: RecordProvenance(source: .init(kind: .workflow))
    )
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

private enum RecoverableRewriteError: SpeechTextFallbackEligibleError {
    case unavailable

    var allowsSpeechTextFallback: Bool { true }
}

private struct RecoverableFailingRewriteTransformer: TextTransformer {
    let id = "mock.transformer"
    let supportedKinds: [PostProcessStepKind] = [.llmRewrite]

    func transform(
        text _: String,
        step _: PostProcessStep,
        context _: TransformContext
    ) async throws -> String {
        throw RecoverableRewriteError.unavailable
    }
}

private struct ChainedLanguageModelTransformer: TracedTextTransformer {
    let id = "mock.language-model.transformer"
    let supportedKinds: [PostProcessStepKind] = [.llmRewrite, .llmAnswer]

    func transform(
        text: String,
        step: PostProcessStep,
        context _: TransformContext
    ) async throws -> String {
        text + " | " + (step.prompt ?? step.kind.rawValue)
    }

    func transformWithTrace(
        text: String,
        step: PostProcessStep,
        context _: TransformContext
    ) async throws -> TracedTextTransformation {
        let output = text + " | " + (step.prompt ?? step.kind.rawValue)
        return TracedTextTransformation(
            text: output,
            trace: LanguageModelTrace(
                providerID: "test.provider",
                modelID: "test-model",
                systemPrompt: "system contract",
                workflowPrompt: step.prompt ?? "",
                messages: [.init(role: .user, content: text)],
                responseText: output,
                tokenUsage: step.kind == .llmRewrite
                    ? .init(inputTokens: 120, outputTokens: 24, totalTokens: 144)
                    : .init(inputTokens: 180, outputTokens: 36, totalTokens: 216)
            )
        )
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

private struct InjectingProbeAction: OutputAction {
    let id = "selected.record.action"
    let probe: ActionProbe

    func execute(text: String, context: ActionContext) async throws -> ActionResult {
        await probe.record(text)
        return .injected
    }
}

private struct CommittedOutputProbeAction: OutputAction {
    let id = "selected.record.action"
    let probe: ActionProbe

    func execute(text: String, context: ActionContext) async throws -> ActionResult {
        await probe.record(text)
        throw CommittedOutputFailure.clipboardRestorationFailedAfterInjection
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

private actor BlockingInitializationSettingsStore: SettingsStore {
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

}

private actor BlockingRecordGraphPersistenceStore: RecordGraphPersistenceStore {
    private let loadStarted: BlockingGate
    private let releaseLoad: BlockingGate

    init(loadStarted: BlockingGate, releaseLoad: BlockingGate) {
        self.loadStarted = loadStarted
        self.releaseLoad = releaseLoad
    }

    func loadRecordGraph() async throws -> RecordGraphPersistenceReadSnapshot {
        await loadStarted.resume()
        await releaseLoad.wait()
        return .empty
    }

    func replaceRecordGraph(
        with snapshot: RecordGraphPersistenceWriteSnapshot
    ) async throws -> Int64 {
        _ = snapshot
        return 1
    }

    func removeRecordGraph() async throws -> RecordGraphRemovalResult {
        .removed
    }
}

private enum RecoveringRecordGraphPersistenceError: Error {
    case rejected
}

private actor RecoveringRecordGraphPersistenceStore: RecordGraphPersistenceStore {
    private struct WriteWaiter {
        var targetCount: Int
        var continuation: CheckedContinuation<Void, Never>
    }

    private var rejectsWrites = false
    private var writeAttemptCount = 0
    private var repositoryRevision: Int64 = 0
    private var writeWaiters: [WriteWaiter] = []

    func loadRecordGraph() async throws -> RecordGraphPersistenceReadSnapshot {
        .empty
    }

    func replaceRecordGraph(
        with snapshot: RecordGraphPersistenceWriteSnapshot
    ) async throws -> Int64 {
        _ = snapshot
        writeAttemptCount += 1
        resumeSatisfiedWriteWaiters()
        guard !rejectsWrites else {
            throw RecoveringRecordGraphPersistenceError.rejected
        }
        repositoryRevision += 1
        return repositoryRevision
    }

    func removeRecordGraph() async throws -> RecordGraphRemovalResult {
        .removed
    }

    func setRejectsWrites(_ rejectsWrites: Bool) {
        self.rejectsWrites = rejectsWrites
    }

    func waitForWriteAttempts(_ targetCount: Int) async {
        guard writeAttemptCount < targetCount else { return }
        await withCheckedContinuation { continuation in
            writeWaiters.append(
                WriteWaiter(targetCount: targetCount, continuation: continuation)
            )
        }
    }

    private func resumeSatisfiedWriteWaiters() {
        let satisfied = writeWaiters.filter { $0.targetCount <= writeAttemptCount }
        writeWaiters.removeAll { $0.targetCount <= writeAttemptCount }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
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
    func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration { .initial }
    func save(_ value: DiagnosticEvent, generation: RunHistoryWriteGeneration) async throws {
        guard generation == .initial else { throw RunHistoryGenerationError.unsupported }
        try await (self as any DiagnosticRepository).save(value)
    }

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
    func testCancelledRunStillDeliversTerminalUnderBackpressure() async {
        let bus = EventBus(maxBufferedEvents: 1)
        let coordinator = SessionCoordinator(contextProvider: MockContextProvider(),
            recognizerRegistry: .init(recognizers: [MockRecognizer(result: .init(rawText: "text", bestText: "text"))]),
            transformerRegistry: .init(transformers: []), actionRegistry: .init(actions: [ProbeAction(probe: ActionProbe())]),
            candidateResolver: CandidateResolver(eventBus: bus), eventBus: bus)
        let runID = UUID()
        let workflow = WorkflowDefinition(name: "Cancelled", pipeline: .init(recognizerID: "mock.recognizer",
            outputActions: [.init(id: "probe.action")]), ui: .init(symbolName: "waveform", accentColorName: "blue"))
        await bus.publish(.recordPanelRequested)
        let run = Task { await coordinator.run(workflow: workflow, runID: runID, contextSnapshot: .empty) }
        run.cancel()
        var iterator = bus.lifecycleDeliveryStream.makeAsyncIterator()
        while let delivery = await iterator.next() {
            if case .event(.runCancelled(let summary)) = delivery {
                XCTAssertEqual(summary.runID, runID)
                break
            }
        }
        await run.value
    }

    func testCoordinatorResolvesAndPassesTypedRecognitionOptions() async {
        let eventBus = EventBus()
        let requestProbe = RecognitionRequestProbe()
        let actionProbe = ActionProbe()
        let vocabularyMigration = VocabularyLegacyMigrator.migrate([
            VocabularyRule(kind: .hotword, pattern: "Rill", replacement: ""),
            VocabularyRule(kind: .hotword, pattern: "multi word", replacement: ""),
        ])
        var workflow = WorkflowDefinition(
            name: "Hints",
            pipeline: PipelineDeclaration(
                recognizerID: "options.probe",
                outputActions: [OutputActionReference(id: "probe.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
        workflow.plan.setup.vocabularyBindings = vocabularyMigration.bindings
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
            eventBus: eventBus,
            vocabularyCollectionProvider: { vocabularyMigration.collections },
            recognitionOptionsProvider: { _, _ in expectedOptions }
        )

        await coordinator.run(workflow: workflow, contextSnapshot: .empty)

        let requests = await requestProbe.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.options.language, expectedOptions.language)
        XCTAssertEqual(
            requests.first?.options.hints.keyterms.sorted(),
            expectedOptions.hints.keyterms.sorted()
        )
    }

    func testCoordinatorDropsUnsupportedHintsWithoutPublishingTheirContent() async {
        let keytermCanary = "private-keyterm-canary"
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let requestProbe = RecognitionRequestProbe()
        let actionProbe = ActionProbe()
        let vocabularyMigration = VocabularyLegacyMigrator.migrate([
            VocabularyRule(kind: .hotword, pattern: keytermCanary, replacement: ""),
        ])
        var workflow = WorkflowDefinition(
            name: "Unsupported Hints",
            pipeline: PipelineDeclaration(
                recognizerID: "options.probe",
                outputActions: [OutputActionReference(id: "probe.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
        workflow.plan.setup.vocabularyBindings = vocabularyMigration.bindings
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
            eventBus: eventBus,
            diagnostics: diagnostics,
            vocabularyCollectionProvider: { vocabularyMigration.collections }
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
            if case .recognitionCompleted(_, let recognition) = event {
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

    func testCompletionRetainsOrderedInputsSentToLanguageModelSteps() async {
        let eventBus = EventBus()
        let probe = ActionProbe()
        let workflow = WorkflowDefinition(
            name: "Composable Assistant",
            pipeline: PipelineDeclaration(
                recognizerID: "mock.recognizer",
                postProcessSteps: [
                    PostProcessStep(kind: .llmRewrite, prompt: "first"),
                    PostProcessStep(kind: .llmAnswer, prompt: "second"),
                ],
                outputActions: [OutputActionReference(id: "probe.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "sparkles", accentColorName: "purple")
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [
                    MockRecognizer(
                        result: RecognitionResult(rawText: "question", bestText: "question")
                    ),
                ]
            ),
            transformerRegistry: TextTransformerRegistry(
                transformers: [ChainedLanguageModelTransformer()]
            ),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: probe)]),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            eventBus: eventBus
        )

        let result = await coordinator.runReportingOutcome(
            workflow: workflow,
            contextSnapshot: .empty
        )

        guard case .completed(let summary) = result else {
            return XCTFail("Expected the composed workflow to complete")
        }
        XCTAssertEqual(
            summary.correctionSource?.languageModelInputTexts,
            ["question", "question | first"]
        )
        XCTAssertEqual(summary.correctionSource?.languageModelTraces?.count, 2)
        XCTAssertEqual(
            summary.correctionSource?.languageModelTraces?.map(\.workflowPrompt),
            ["first", "second"]
        )
        XCTAssertEqual(
            summary.correctionSource?.languageModelTraces?.map(\.messages),
            [
                [.init(role: .user, content: "question")],
                [.init(role: .user, content: "question | first")],
            ]
        )
        XCTAssertEqual(
            summary.correctionSource?.languageModelTraces?.last?.responseText,
            "question | first | second"
        )
        XCTAssertEqual(summary.finalText, "question | first | second")
        let steps = summary.correctionSource?.processingSteps ?? []
        XCTAssertEqual(steps.filter { [.llmRewrite, .llmAnswer].contains($0.kind) }.map(\.outputText),
                       ["question | first", "question | first | second"])
        XCTAssertEqual(steps.first?.outputText, "question")
        XCTAssertNil(steps.first?.tokenUsage)
        XCTAssertEqual(steps.compactMap(\.tokenUsage), [
            .init(inputTokens: 120, outputTokens: 24, totalTokens: 144),
            .init(inputTokens: 180, outputTokens: 36, totalTokens: 216),
        ])
        let deliveredValues = await probe.snapshot()
        XCTAssertEqual(deliveredValues, ["question | first | second"])
    }

    func testWhitespaceOnlyRecognitionFailsBeforeCompletionTransformOrDelivery() async throws {
        let eventBus = EventBus()
        let repository = InMemoryWorkflowRunReceiptRepository()
        let recorder = WorkflowRunReceiptRecorder(repository: repository, eventBus: eventBus)
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

    func testPreRecognizedWakeCommandSkipsRecognizerAndKeepsWorkflowPipeline() async {
        let eventBus = EventBus()
        let recognitionProbe = RecognitionRequestProbe()
        let actionProbe = ActionProbe()
        var workflow = WorkflowDefinition(
            name: "Voice Assistant",
            trigger: .wakeWord,
            pipeline: PipelineDeclaration(
                recognizerID: "options.probe",
                postProcessSteps: [PostProcessStep(kind: .normalizeWhitespace)],
                outputActions: [OutputActionReference(id: "probe.action")],
                uncertaintyPolicy: .init(mode: .off),
                deliveryPolicy: .init(strategy: .immediate)
            ),
            ui: WorkflowUIConfig(symbolName: "sparkles", accentColorName: "purple")
        )
        workflow.plan.setup.wakeWord = WakeWordConfiguration(
            phrases: ["Hey Rill"]
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [
                    OptionsProbeRecognizer(
                        supportsKeyterms: true,
                        probe: recognitionProbe
                    ),
                ]
            ),
            transformerRegistry: TextTransformerRegistry(
                transformers: [MockTransformer()]
            ),
            actionRegistry: OutputActionRegistry(
                actions: [ProbeAction(probe: actionProbe)]
            ),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            eventBus: eventBus
        )
        let triggerEvent = WorkflowTriggerEvent(
            binding: .wakeWord,
            workflowID: workflow.id,
            sourceID: "wake-word.qwen-asr"
        )
        let authorization = AuthorizedWorkflowRunContext(
            workflow: workflow,
            contextSnapshot: .empty,
            recognitionOptions: .empty
        )

        await coordinator.runRecognizedText(
            "打开客厅灯",
            runID: triggerEvent.id,
            triggerEvent: triggerEvent,
            authorizedContext: authorization
        )

        let recognitionRequests = await recognitionProbe.snapshot()
        let actionValues = await actionProbe.snapshot()
        XCTAssertEqual(recognitionRequests, [])
        XCTAssertEqual(actionValues, ["打开客厅灯 transformed"])
    }

    func testDeliverTopOfStackPublishesCompletionSummary() async {
        let eventBus = EventBus()
        let recordStore = RecordStore()
        let resolver = CandidateResolver(eventBus: eventBus)
        let probe = ActionProbe()

        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: probe)]),
            candidateResolver: resolver,
            recordStore: recordStore,
            eventBus: eventBus
        )

        _ = try? await recordStore.ingest(
            makeStoredRecordDraft("stack item"),
            into: [RecordCollection.inboxID]
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

        await coordinator.deliverNextRecord(actionID: "probe.action")
        let events = await collector.value

        XCTAssertTrue(events.contains { event in
            if case .actionExecuted(run: _, actionID: "probe.action", result: .skipped("captured")) = event {
                return true
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .runCompleted(let summary) = event {
                return summary.workflow.titleKey == .recordDelivery
                    && summary.trigger == .recordDelivery
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
        let recordStore = RecordStore()
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
            clipboard: SystemClipboardSnapshot(plainText: "", changeCount: 7)
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
            recordStore: recordStore,
            eventBus: eventBus
        )
        _ = try? await recordStore.ingest(
            makeStoredRecordDraft("CANARY-DELIVERY"),
            into: [RecordCollection.inboxID]
        )

        await coordinator.deliverNextRecord(actionID: "focus.probe")

        let contexts = await contextProbe.snapshot()
        XCTAssertEqual(contexts.map(\.focus.bundleIdentifier), ["com.example.Editor"])
        XCTAssertEqual(contexts.map(\.focus.processIdentifier), [42])
        XCTAssertTrue(contexts.allSatisfy { $0.focus.selectedText.isEmpty })
        XCTAssertTrue(contexts.allSatisfy { $0.clipboard.plainText.isEmpty })
    }

    func testExactManualRecordDeliveryUsesSelectedSubjectRetainsMembershipAndWritesReceipt() async throws {
        let eventBus = EventBus()
        let repository = InMemoryWorkflowRunReceiptRepository()
        let recorder = WorkflowRunReceiptRecorder(repository: repository, eventBus: eventBus)
        let recordStore = RecordStore()
        let list = try await recordStore.createCollection(name: "Reusable", preset: .list)
        let selected = try await recordStore.ingest(
            makeStoredRecordDraft("selected record"),
            into: [list.id]
        )
        let routed = try await recordStore.ingest(
            makeStoredRecordDraft("automatic route record"),
            into: [RecordCollection.inboxID]
        )
        let membership = try XCTUnwrap(selected.memberships.first)
        let subject = RecordDeliverySubject(
            recordID: selected.id,
            membershipID: membership.id,
            membershipRevision: membership.revision,
            collectionID: membership.collectionID,
            payloadKind: selected.record.payload.kind,
            captureTags: selected.record.provenance.captureTags
        )
        let target = try XCTUnwrap(
            FocusedApplicationTargetIdentity(
                processIdentifier: 42,
                bundleIdentifier: "com.example.Editor"
            )
        )
        let context = ContextSnapshot(
            focus: FocusSnapshot(
                applicationName: "Editor",
                bundleIdentifier: "com.example.Editor",
                processIdentifier: 42,
                focusedRole: "AXTextArea",
                selectedText: "",
                secureInput: false
            ),
            clipboard: SystemClipboardSnapshot(plainText: "", changeCount: 0)
        )
        let probe = ActionProbe()
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            privacyContextProvider: { context },
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [InjectingProbeAction(probe: probe)]),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            recordStore: recordStore,
            eventBus: eventBus,
            runReceiptRecorder: recorder
        )

        await coordinator.deliverRecord(
            matching: subject,
            to: target,
            actionID: "selected.record.action"
        )

        let deliveredValues = await probe.snapshot()
        XCTAssertEqual(deliveredValues, ["selected record"])
        let selectedStored = try await recordStore.record(id: selected.id)
        let routedStored = try await recordStore.record(id: routed.id)
        let selectedAfter = try XCTUnwrap(selectedStored)
        let routedAfter = try XCTUnwrap(routedStored)
        XCTAssertEqual(selectedAfter.memberships.first?.state, .active)
        XCTAssertEqual(selectedAfter.activity.useCount, 1)
        XCTAssertEqual(routedAfter.memberships.first?.state, .active)
        XCTAssertEqual(routedAfter.activity.useCount, 0)
        let receipts = try await repository.receipts(matching: .all)
        let receipt = try XCTUnwrap(receipts.first { $0.trigger == .recordDelivery })
        XCTAssertEqual(receipt.termination, .completed)
        XCTAssertEqual(receipt.actionDetails.map(\.result), [.injected])
    }

    func testCommittedOutputFailureSettlesExactRecordWithoutMarkingItRetryable() async throws {
        let eventBus = EventBus()
        let repository = InMemoryWorkflowRunReceiptRepository()
        let recorder = WorkflowRunReceiptRecorder(repository: repository, eventBus: eventBus)
        let recordStore = RecordStore()
        let list = try await recordStore.createCollection(name: "Reusable", preset: .list)
        let selected = try await recordStore.ingest(
            makeStoredRecordDraft("selected record"),
            into: [list.id]
        )
        let membership = try XCTUnwrap(selected.memberships.first)
        let subject = RecordDeliverySubject(
            recordID: selected.id,
            membershipID: membership.id,
            membershipRevision: membership.revision,
            collectionID: membership.collectionID,
            payloadKind: selected.record.payload.kind,
            captureTags: selected.record.provenance.captureTags
        )
        let target = try XCTUnwrap(
            FocusedApplicationTargetIdentity(
                processIdentifier: 42,
                bundleIdentifier: "com.example.Editor"
            )
        )
        let context = ContextSnapshot(
            focus: FocusSnapshot(
                applicationName: "Editor",
                bundleIdentifier: "com.example.Editor",
                processIdentifier: 42,
                focusedRole: "AXTextArea",
                selectedText: "",
                secureInput: false
            ),
            clipboard: SystemClipboardSnapshot(plainText: "", changeCount: 0)
        )
        let probe = ActionProbe()
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            privacyContextProvider: { context },
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(
                actions: [CommittedOutputProbeAction(probe: probe)]
            ),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            recordStore: recordStore,
            eventBus: eventBus,
            runReceiptRecorder: recorder
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

        await coordinator.deliverRecord(
            matching: subject,
            to: target,
            actionID: "selected.record.action"
        )

        let events = await collector.value
        let deliveredValues = await probe.snapshot()
        let storedProjection = try await recordStore.record(id: selected.id)
        let stored = try XCTUnwrap(storedProjection)
        let receipts = try await repository.receipts(matching: .all)
        let receipt = try XCTUnwrap(receipts.first { $0.trigger == .recordDelivery })

        XCTAssertEqual(deliveredValues, ["selected record"])
        XCTAssertEqual(stored.memberships.first?.state, .active)
        XCTAssertEqual(stored.activity.useCount, 1)
        XCTAssertNil(stored.activity.latestFailure)
        XCTAssertEqual(receipt.termination, .partiallyCompleted(code: .processing))
        XCTAssertEqual(receipt.actionDetails.map(\.result), [.injected])
        XCTAssertTrue(events.contains { event in
            if case .runFailed(_, _, let message) = event {
                return message == CommittedOutputFailure
                    .clipboardRestorationFailedAfterInjection
                    .message
            }
            return false
        })
        XCTAssertFalse(events.contains { event in
            if case .runCompleted = event { return true }
            return false
        })
    }

    func testCommittedOutputRetriesSettlementWithoutReleasingLeaseOrRepeatingAction() async throws {
        let eventBus = EventBus()
        let repository = InMemoryWorkflowRunReceiptRepository()
        let recorder = WorkflowRunReceiptRecorder(repository: repository, eventBus: eventBus)
        let persistence = RecoveringRecordGraphPersistenceStore()
        let recordStore = RecordStore(persistence: persistence)
        let list = try await recordStore.createCollection(name: "Reusable", preset: .list)
        let selected = try await recordStore.ingest(
            makeStoredRecordDraft("selected record"),
            into: [list.id]
        )
        let membership = try XCTUnwrap(selected.memberships.first)
        let subject = RecordDeliverySubject(
            recordID: selected.id,
            membershipID: membership.id,
            membershipRevision: membership.revision,
            collectionID: membership.collectionID,
            payloadKind: selected.record.payload.kind,
            captureTags: selected.record.provenance.captureTags
        )
        let target = try XCTUnwrap(
            FocusedApplicationTargetIdentity(
                processIdentifier: 42,
                bundleIdentifier: "com.example.Editor"
            )
        )
        let context = ContextSnapshot(
            focus: FocusSnapshot(
                applicationName: "Editor",
                bundleIdentifier: "com.example.Editor",
                processIdentifier: 42,
                focusedRole: "AXTextArea",
                selectedText: "",
                secureInput: false
            ),
            clipboard: SystemClipboardSnapshot(plainText: "", changeCount: 0)
        )
        let probe = ActionProbe()
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            privacyContextProvider: { context },
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [InjectingProbeAction(probe: probe)]),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            recordStore: recordStore,
            eventBus: eventBus,
            runReceiptRecorder: recorder
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
        await persistence.setRejectsWrites(true)

        await coordinator.deliverRecord(
            matching: subject,
            to: target,
            actionID: "selected.record.action"
        )
        let events = await collector.value
        await persistence.waitForWriteAttempts(4)

        do {
            _ = try await recordStore.beginDelivery(
                matching: subject,
                sink: .focusedApplication
            )
            XCTFail("Committed output must keep the exact membership leased while settlement retries.")
        } catch let error as RecordStoreError {
            XCTAssertEqual(error, .membershipAlreadyInUse)
        }

        await persistence.setRejectsWrites(false)
        await persistence.waitForWriteAttempts(5)
        let stored = try await recordStore.record(id: selected.id)
        let selectedAfter = try XCTUnwrap(stored)
        let receipts = try await repository.receipts(matching: .all)
        let receipt = try XCTUnwrap(receipts.first { $0.trigger == .recordDelivery })
        let deliveredValues = await probe.snapshot()

        XCTAssertEqual(deliveredValues, ["selected record"])
        XCTAssertEqual(selectedAfter.memberships.first?.state, .active)
        XCTAssertEqual(selectedAfter.activity.useCount, 1)
        XCTAssertNil(selectedAfter.activity.latestFailure)
        XCTAssertEqual(receipt.termination, .partiallyCompleted(code: .processing))
        XCTAssertEqual(receipt.actionDetails.map(\.result), [.injected])
        XCTAssertTrue(events.contains { event in
            if case .runFailed(_, _, let message) = event {
                return message.contains("may already have been delivered")
                    && message.contains("do not repeat this action")
            }
            return false
        })
        XCTAssertFalse(events.contains { event in
            if case .runCompleted = event { return true }
            return false
        })
        await coordinator.shutdownRecordDeliverySettlements()
    }

    func testExactManualRecordDeliveryFailsClosedWhenRestoredTargetChanges() async throws {
        let eventBus = EventBus()
        let recordStore = RecordStore()
        let list = try await recordStore.createCollection(name: "Reusable", preset: .list)
        let selected = try await recordStore.ingest(
            makeStoredRecordDraft("must not deliver"),
            into: [list.id]
        )
        let membership = try XCTUnwrap(selected.memberships.first)
        let subject = RecordDeliverySubject(
            recordID: selected.id,
            membershipID: membership.id,
            membershipRevision: membership.revision,
            collectionID: membership.collectionID,
            payloadKind: .text
        )
        let target = try XCTUnwrap(
            FocusedApplicationTargetIdentity(
                processIdentifier: 42,
                bundleIdentifier: "com.example.Editor"
            )
        )
        let changedContext = ContextSnapshot(
            focus: FocusSnapshot(
                applicationName: "Other",
                bundleIdentifier: "com.example.Other",
                processIdentifier: 84,
                focusedRole: "AXTextArea",
                selectedText: "",
                secureInput: false
            ),
            clipboard: SystemClipboardSnapshot(plainText: "", changeCount: 0)
        )
        let probe = ActionProbe()
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            privacyContextProvider: { changedContext },
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [InjectingProbeAction(probe: probe)]),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            recordStore: recordStore,
            eventBus: eventBus
        )

        await coordinator.deliverRecord(
            matching: subject,
            to: target,
            actionID: "selected.record.action"
        )

        let deliveredValues = await probe.snapshot()
        XCTAssertTrue(deliveredValues.isEmpty)
        let selectedStored = try await recordStore.record(id: selected.id)
        let selectedAfter = try XCTUnwrap(selectedStored)
        XCTAssertEqual(selectedAfter.memberships.first?.state, .active)
        XCTAssertEqual(selectedAfter.activity.useCount, 0)
        XCTAssertEqual(selectedAfter.activity.latestFailure, .deliveryFailed)
    }


    func testCoordinatorRecordsStageDiagnostics() async {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
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
        XCTAssertEqual(
            stageEvents.first { $0.metadata["stage"] == "transforming" }?
                .metadata["stepCount"],
            "3"
        )
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


    func testRecognizerFailurePublishesFailureEventAndDiagnostics() async {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
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
                && event.metadata["stage"] == "recognizing"
                && event.metadata["failureCode"] == "processing"
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
        let resolver = CandidateResolver(eventBus: eventBus, diagnostics: diagnostics)
        let probe = ActionProbe()
        var workflow = WorkflowDefinition(
            name: "Vocabulary Workflow",
            pipeline: PipelineDeclaration(
                recognizerID: "mock.recognizer",
                postProcessSteps: [PostProcessStep(kind: .normalizeWhitespace)],
                outputActions: [OutputActionReference(id: "probe.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "text.badge.checkmark", accentColorName: "green"),
            metadata: [
                WorkflowMetadataKey.legacyTargetRecordCollectionID: RecordCollection.voiceInputID.rawValue.uuidString,
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
            clipboard: SystemClipboardSnapshot(plainText: "", changeCount: 0)
        )
        let rules = [
            VocabularyRule(
                pattern: "vux type",
                replacement: "Rill",
                scope: VocabularyRuleScope(
                    bundleIdentifier: "com.example.editor",
                    recordCollectionID: RecordCollection.voiceInputID.rawValue,
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
        let vocabularyMigration = VocabularyLegacyMigrator.migrate(rules)
        workflow.plan.setup.vocabularyBindings = vocabularyMigration.bindings
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
            eventBus: eventBus,
            diagnostics: diagnostics,
            vocabularyCollectionProvider: { vocabularyMigration.collections }
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
        var workflow = WorkflowDefinition(
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
                WorkflowMetadataKey.legacyTargetRecordCollectionID: targetGroupID.uuidString,
                WorkflowMetadataKey.languageOverride: "en-US",
            ]
        )
        let vocabularyMigration = VocabularyLegacyMigrator.migrate([
            VocabularyRule(
                pattern: "vux type",
                replacement: "Rill",
                scope: VocabularyRuleScope(
                    bundleIdentifier: "com.example.editor",
                    recordCollectionID: targetGroupID,
                    locale: "zh-CN"
                )
            ),
        ])
        workflow.plan.setup.vocabularyBindings = vocabularyMigration.bindings
        let context = ContextSnapshot(
            focus: FocusSnapshot(
                applicationName: "Editor",
                bundleIdentifier: "com.example.editor",
                processIdentifier: 42,
                focusedRole: "AXTextArea",
                selectedText: "unrelated selected text",
                secureInput: false
            ),
            clipboard: SystemClipboardSnapshot(plainText: "unrelated clipboard text", changeCount: 7)
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [MockRecognizer(result: recognition)]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: [MockTransformer()]),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: probe)]),
            candidateResolver: resolver,
            eventBus: eventBus,
            vocabularyCollectionProvider: { vocabularyMigration.collections }
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
        let steps = try XCTUnwrap(summary.correctionSource?.processingSteps)
        XCTAssertEqual(steps.map(\.kind), [.recognizeSpeech, .resolveUncertainty, .applyVocabulary, .normalizeWhitespace])
        XCTAssertEqual(steps.map(\.outputText), ["vux tipe", "vux type", "Rill", "Rill transformed"])
        XCTAssertTrue(steps.dropFirst().allSatisfy { $0.didChange == true })
        XCTAssertEqual(
            summary.correctionSource?.context,
            VocabularyRuleContext(
                bundleIdentifier: "com.example.editor",
                recordCollectionID: targetGroupID,
                locale: "zh-CN"
            )
        )
    }

    func testUnboundWorkflowDoesNotLoadVocabularyCollections() async {
        struct LoadFailure: Error {}

        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
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
            eventBus: eventBus,
            diagnostics: diagnostics,
            vocabularyRuleProvider: { throw LoadFailure() }
        )

        await coordinator.run(workflow: workflow, contextSnapshot: .empty)

        let deliveredValues = await probe.snapshot()
        XCTAssertEqual(deliveredValues, ["original"])
        let events = await diagnostics.snapshot(matching: DiagnosticQuery(subsystem: .session))
        XCTAssertFalse(events.contains { $0.event == "session.vocabulary.load-failed" })
    }

    func testMissingTransformerFailsInsteadOfSilentlyReturningUnprocessedText() async {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
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

    func testRecoverableRewriteFailurePreservesRecognizedSpeechText() async throws {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let probe = ActionProbe()
        let workflow = WorkflowDefinition(
            name: "Recoverable Rewrite",
            pipeline: PipelineDeclaration(
                recognizerID: "mock.recognizer",
                postProcessSteps: [PostProcessStep(kind: .llmRewrite, prompt: "Polish")],
                outputActions: [OutputActionReference(id: "probe.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [
                    MockRecognizer(
                        result: RecognitionResult(rawText: "recognized", bestText: "recognized")
                    ),
                ]
            ),
            transformerRegistry: TextTransformerRegistry(
                transformers: [RecoverableFailingRewriteTransformer()]
            ),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: probe)]),
            candidateResolver: CandidateResolver(eventBus: eventBus, diagnostics: diagnostics),
            eventBus: eventBus,
            diagnostics: diagnostics
        )
        let capturedAudio = try CapturedAudio(
            durationSeconds: 15,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .float32),
            inlineData: Data([0])
        )

        let result = await coordinator.runReportingOutcome(
            workflow: workflow,
            capturedAudio: capturedAudio,
            contextSnapshot: .empty
        )

        guard case .completed(let summary) = result else {
            return XCTFail("Expected recognized speech text to be delivered")
        }
        XCTAssertEqual(summary.finalText, "recognized")
        let skippedStep = try XCTUnwrap(summary.correctionSource?.processingSteps?.last)
        XCTAssertEqual(skippedStep.kind, .llmRewrite)
        XCTAssertEqual(skippedStep.result, .skipped)
        XCTAssertEqual(skippedStep.outputText, "recognized")
        let deliveredValues = await probe.snapshot()
        XCTAssertEqual(deliveredValues, ["recognized"])
        let events = await diagnostics.snapshot(matching: DiagnosticQuery(subsystem: .session))
        XCTAssertTrue(events.contains { event in
            event.event == "session.transform.fallback"
                && event.metadata["stepKind"] == "llmRewrite"
                && event.metadata["outcome"] == "preserved"
        })
    }

    func testVoiceAssistantDoesNotEchoRecognizedTextWhenRewriteFails() async throws {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let probe = ActionProbe()
        let workflow = WorkflowDefinition(
            name: "Voice Assistant",
            pipeline: PipelineDeclaration(
                recognizerID: "mock.recognizer",
                postProcessSteps: [PostProcessStep(kind: .llmRewrite, prompt: "Answer")],
                outputActions: [OutputActionReference(id: "probe.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "sparkles", accentColorName: "purple"),
            metadata: [
                WorkflowMetadataKey.speechMode: SpeechWorkflowMode.voiceAssistant.rawValue,
            ]
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [
                    MockRecognizer(
                        result: RecognitionResult(rawText: "question", bestText: "question")
                    ),
                ]
            ),
            transformerRegistry: TextTransformerRegistry(
                transformers: [RecoverableFailingRewriteTransformer()]
            ),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: probe)]),
            candidateResolver: CandidateResolver(eventBus: eventBus, diagnostics: diagnostics),
            eventBus: eventBus,
            diagnostics: diagnostics
        )
        let capturedAudio = try CapturedAudio(
            durationSeconds: 15,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .float32),
            inlineData: Data([0])
        )

        let stream = await eventBus.stream()
        let result = await coordinator.runReportingOutcome(
            workflow: workflow,
            capturedAudio: capturedAudio,
            contextSnapshot: .empty
        )

        guard case .failed(let summary) = result else {
            return XCTFail("Expected voice assistant rewrite failure to remain strict")
        }
        var recordedSteps: [WorkflowTextStep] = []
        for await event in stream {
            if case .runTextStepRecorded(let runID, let step) = event {
                XCTAssertEqual(runID, summary.runID)
                recordedSteps.append(step)
            }
            if case .runFailed = event { break }
        }
        XCTAssertEqual(recordedSteps.first?.outputText, "question")
        XCTAssertEqual(recordedSteps.last?.kind, .llmRewrite)
        XCTAssertEqual(recordedSteps.last?.result, .failed)
        XCTAssertNil(recordedSteps.last?.outputText)
        XCTAssertEqual(summary.stage, .transforming)
        let deliveredValues = await probe.snapshot()
        XCTAssertTrue(deliveredValues.isEmpty)
        let events = await diagnostics.snapshot(matching: DiagnosticQuery(subsystem: .session))
        XCTAssertFalse(events.contains { $0.event == "session.transform.fallback" })
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
        let actionProbe = ActionProbe()
        let workflow = WorkflowDefinition(
            name: "Reported Failure",
            pipeline: PipelineDeclaration(
                recognizerID: "failing.recognizer",
                outputActions: [OutputActionReference(id: "probe.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "red")
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [FailingRecognizer(message: "private provider detail")]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(
                actions: [ProbeAction(probe: actionProbe)]
            ),
            candidateResolver: CandidateResolver(eventBus: eventBus),
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
            if case .actionExecuted(run: _, actionID: "reported.failure", result: .failed(failureCanary)) = event {
                return true
            }
            return false
        })
        XCTAssertFalse(events.contains { event in
            if case .runCompleted = event { return true }
            return false
        })
    }

    func testCommittedOutputFailureMarksWorkflowActionInjectedAndRunPartial() async throws {
        let eventBus = EventBus()
        let repository = InMemoryWorkflowRunReceiptRepository()
        let recorder = WorkflowRunReceiptRecorder(repository: repository, eventBus: eventBus)
        let probe = ActionProbe()
        let workflow = WorkflowDefinition(
            name: "Committed Output",
            pipeline: PipelineDeclaration(
                recognizerID: "mock.recognizer",
                outputActions: [OutputActionReference(id: "selected.record.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "checkmark", accentColorName: "orange")
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [
                    MockRecognizer(
                        result: RecognitionResult(rawText: "input", bestText: "input")
                    ),
                ]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(
                actions: [CommittedOutputProbeAction(probe: probe)]
            ),
            candidateResolver: CandidateResolver(eventBus: eventBus),
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

        let outcome = await coordinator.runReportingOutcome(
            workflow: workflow,
            runID: runID,
            contextSnapshot: .empty
        )

        let events = await collector.value
        let receipts = try await repository.receipts(matching: .init(runID: runID))
        let receipt = try XCTUnwrap(receipts.first)
        let deliveredValues = await probe.snapshot()

        guard case .failed(let failure) = outcome else {
            return XCTFail("Expected committed recovery failure to keep a failed run outcome.")
        }
        XCTAssertEqual(failure.stage, .delivering)
        XCTAssertEqual(deliveredValues, ["input"])
        XCTAssertEqual(receipt.termination, .partiallyCompleted(code: .processing))
        XCTAssertEqual(receipt.actionDetails.map(\.result), [.injected])
        XCTAssertTrue(events.contains { event in
            if case .actionExecuted(
                run: _,
                actionID: "selected.record.action",
                result: .injected
            ) = event {
                return true
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .runFailed(_, _, let message) = event {
                return message == CommittedOutputFailure
                    .clipboardRestorationFailedAfterInjection
                    .message
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
        let recordStore = RecordStore()
        let actionProbe = ActionProbe()
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
            recordStore: recordStore,
            eventBus: eventBus
        )
        let inserted = try? await recordStore.ingest(
            RecordDraft(
                payload: .text("retain me"),
                provenance: .init(source: .init(kind: .workflow))
            ),
            into: [RecordCollection.inboxID]
        )

        await coordinator.deliverNextRecord(actionID: "reported.failure")

        let stored = try? await recordStore.record(id: inserted?.id ?? RecordID())
        let executedActionIDs = await actionProbe.snapshot()
        XCTAssertEqual(executedActionIDs, ["reported.failure"])
        XCTAssertEqual(stored?.memberships.first?.state, .active)
        XCTAssertEqual(stored?.activity.useCount, 0)
        XCTAssertEqual(stored?.activity.latestFailure, .deliveryFailed)
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
        let persistence = BlockingRecordGraphPersistenceStore(
            loadStarted: loadStarted,
            releaseLoad: releaseLoad
        )
        let eventBus = EventBus()
        let recordStore = RecordStore(persistence: persistence)

        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            recordStore: recordStore,
            eventBus: eventBus
        )
        let firstDelivery = Task {
            await coordinator.deliverNextRecord()
        }
        await loadStarted.wait()

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
            await coordinator.deliverNextRecord()
            await secondCompletion.complete()
        }
        for _ in 0..<200 {
            if await secondCompletion.snapshot() { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        let rejectedWhileFirstWasBlocked = await secondCompletion.snapshot()
        XCTAssertTrue(
            rejectedWhileFirstWasBlocked,
            "A concurrent delivery must be rejected instead of entering the blocked record-store call."
        )

        await releaseLoad.resume()
        await firstDelivery.value
        await secondDelivery.value
        let finalState = await coordinator.currentState()
        XCTAssertEqual(finalState, .idle)
    }

    func testCapturedAudioQueueUsesCaptureTimeLanguageAndPlanOwnedHints() async throws {
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
        let expectedRuntimeOptions = SpeechRecognitionRequestOptions(language: "zh-CN")
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
        XCTAssertEqual(requests.map(\.options), [expectedRuntimeOptions])
    }

    func testCapturedAudioWaitsForActiveRunAndCompletesAfterItsOutput() async throws {
        let eventBus = EventBus()
        let firstRunGate = BlockingGate()
        let firstRunProbe = QueueActionProbe()
        let secondRunProbe = ActionProbe()
        let recognizer = MockRecognizer(
            result: RecognitionResult(rawText: "recognized", bestText: "recognized")
        )
        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: [recognizer]),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(
                actions: [
                    BlockingQueueAction(probe: firstRunProbe, gate: firstRunGate),
                    ProbeAction(probe: secondRunProbe),
                ]
            ),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            eventBus: eventBus
        )
        let firstWorkflow = WorkflowDefinition(
            name: "First Output",
            pipeline: PipelineDeclaration(
                recognizerID: recognizer.id,
                outputActions: [OutputActionReference(id: "blocking.queue.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "1.circle", accentColorName: "blue")
        )
        let secondWorkflow = WorkflowDefinition(
            name: "Second Capture",
            pipeline: PipelineDeclaration(
                recognizerID: recognizer.id,
                outputActions: [OutputActionReference(id: "probe.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "2.circle", accentColorName: "green")
        )
        let firstRunID = UUID()
        let secondRunID = UUID()
        let firstTask = Task {
            await coordinator.runReportingOutcome(
                workflow: firstWorkflow,
                runID: firstRunID,
                contextSnapshot: .empty,
                preRecognizedText: "first"
            )
        }
        for _ in 0..<200 {
            if await firstRunProbe.snapshot() == ["First Output"] { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let startedFirstRuns = await firstRunProbe.snapshot()
        XCTAssertEqual(startedFirstRuns, ["First Output"])

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
        let transfer = await queue.enqueue(
            authorizationLease: makeAudioProcessingTestLease(
                runID: secondRunID,
                workflow: secondWorkflow
            ),
            triggerEvent: nil,
            deferredCapture: .resolved(audio)
        )
        XCTAssertEqual(
            transfer,
            CapturedAudioProcessingQueue.OwnershipTransferResult.accepted
        )

        for _ in 0..<50 {
            if await queue.pendingCount == 1 { break }
            await Task.yield()
        }
        let pendingWhileFirstRunIsActive = await queue.pendingCount
        let secondOutputWhileFirstRunIsActive = await secondRunProbe.snapshot()
        XCTAssertEqual(pendingWhileFirstRunIsActive, 1)
        XCTAssertTrue(secondOutputWhileFirstRunIsActive.isEmpty)

        await firstRunGate.resume()
        _ = await firstTask.value
        for _ in 0..<200 {
            if await secondRunProbe.snapshot() == ["recognized"] { break }
            try? await Task.sleep(for: .milliseconds(2))
        }

        let completedSecondOutputs = await secondRunProbe.snapshot()
        let finalPendingCount = await queue.pendingCount
        XCTAssertEqual(completedSecondOutputs, ["recognized"])
        XCTAssertEqual(finalPendingCount, 0)
        await queue.shutdown()
    }

    func testDeliverTopOfStackKeepsStateBusyUntilCompletedDiagnosticsFinish() async {
        let eventBus = EventBus()
        let gate = BlockingGate()
        let repository = BlockingDiagnosticRepository(target: .completedStage, gate: gate)
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus, repository: repository)
        let recordStore = RecordStore()
        let resolver = CandidateResolver(eventBus: eventBus, diagnostics: diagnostics)
        let probe = ActionProbe()

        _ = try? await recordStore.ingest(
            makeStoredRecordDraft("stack item"),
            into: [RecordCollection.inboxID]
        )

        let coordinator = SessionCoordinator(
            contextProvider: MockContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [MockRecognizer(result: RecognitionResult(rawText: "hello", bestText: "hello"))]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [ProbeAction(probe: probe)]),
            candidateResolver: resolver,
            recordStore: recordStore,
            eventBus: eventBus,
            diagnostics: diagnostics
        )

        let task = Task {
            await coordinator.deliverNextRecord(actionID: "probe.action")
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



}
