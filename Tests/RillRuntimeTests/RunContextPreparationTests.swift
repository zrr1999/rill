import Foundation
import Testing
@testable import RillCore
@testable import RillRuntime

struct RunContextPreparationTests {
    @Test func explicitSelectionVocabularyAndCleanupSurviveWithoutRefreshingFrozenReferences() async throws {
        let imageGate = ContextTestGate<ScreenReferenceSummary>()
        let preparation = try await prepare(summarizer: ContextTestSummarizer(
            image: { await imageGate.wait() }, memory: { throw TestFailure.failed }))
        preparation.recordingStarted()
        try await imageGate.started()
        let selected = Candidate(text: "vux type", confidence: 0.7, source: .user)
        let set = CandidateSet(surfaceText: "vux tipe", range: .init(lowerBound: 2, upperBound: 10),
            candidates: [.init(text: "vux typo", confidence: 0.9, source: .asr), selected])
        let recognition = RecognitionResult(rawText: "  vux tipe  ", bestText: "  vux tipe  ", candidateSets: [set])
        let vocabulary = VocabularyLegacyMigrator.migrate([.init(pattern: "vux type", replacement: "Rill")])
        let bus = EventBus()
        let resolver = CandidateResolver(eventBus: bus)
        let transformer = ContextQueueTransformer()
        let coordinator = SessionCoordinator(contextProvider: ContextQueueContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: [ContextQueueRecognizer(result: recognition)]),
            transformerRegistry: TextTransformerRegistry(transformers: [transformer]),
            actionRegistry: OutputActionRegistry(actions: [ContextQueueAction()]), candidateResolver: resolver, eventBus: bus,
            vocabularyCollectionProvider: { vocabulary.collections })
        var workflow = WorkflowDefinition(name: "Context selection", pipeline: .init(recognizerID: "context.test",
            postProcessSteps: [.init(kind: .normalizeWhitespace), .init(kind: .llmRewrite, prompt: "Cleanup")],
            outputActions: [.init(id: "context.output")], uncertaintyPolicy: .init(mode: .blocking, timeoutSeconds: 2)),
            ui: .init(symbolName: "waveform", accentColorName: "blue"))
        workflow.plan.setup.vocabularyBindings = vocabulary.bindings
        let stream = await bus.stream()
        let selection = Task {
            for await event in stream {
                if case .candidateResolutionRequested(let request) = event {
                    await imageGate.resolve(.init(terms: ["TooLate"], observations: []))
                    try await waitUntil { preparation.preparedReceipt.imageSummary == .ready }
                    _ = await resolver.accept(caseID: request.id, selections: [set.id: selected.id])
                    return
                }
            }
        }
        defer { selection.cancel() }
        await coordinator.run(workflow: workflow, contextSnapshot: .empty, contextPreparation: preparation)
        selection.cancel()
        try await selection.value
        let requests = await transformer.requests
        #expect(requests.count == 1)
        #expect(requests.first?.transcript == "Rill")
        #expect(requests.first?.referenceImage != nil)
        #expect(requests.first?.imageSummary == nil)
    }

    @Test func cancellationInvalidatesAScreenWriteAlreadyWaitingForPersistence() async throws {
        let pendingWrite = ContextTestGate<Void>()
        let grant = ContextReferenceAuthorization(providerFingerprint: "fixture")
        let late = ContextLateSummaryProbe()
        let preparation = try await RunContextPreparation.prepare(
            focus: ContextSnapshot.empty.focus, screenEnabled: true, memoryEnabled: false, excludedApplications: [],
            capture: ContextTestCapture { try image() }, summarizer: ContextTestSummarizer(), memories: { [] },
            authorization: grant, audioLifetime: AudioCaptureLifetime(runID: UUID()),
            saveLateSummary: { summary, authorization in
                await pendingWrite.wait()
                if authorization.isValid { await late.record(summary) }
            })
        preparation.recordingStarted()
        try await waitUntil { preparation.preparedReceipt.imageSummary == .ready }
        _ = try preparation.freeze(transcript: "正文")
        let save = Task { await preparation.historyUpdate.historySaved() }
        try await pendingWrite.started()
        preparation.cancel()
        await pendingWrite.resolve(())
        await save.value
        #expect(await late.count == 0)
        #expect(grant.isValid)
    }

    @Test func freezeDoesNotWaitForEitherSummaryAndLateMemoryIsDiscarded() async throws {
        let imageGate = ContextTestGate<ScreenReferenceSummary>()
        let memoryGate = ContextTestGate<CorrectionMemorySummary>()
        let late = ContextLateSummaryProbe()
        let memory = sampleMemory()
        let preparation = try await prepare(
            summarizer: ContextTestSummarizer(image: { await imageGate.wait() }, memory: { await memoryGate.wait() }),
            memories: [memory], late: late
        )
        preparation.recordingStarted()
        try await imageGate.started()
        try await memoryGate.started()
        let start = ContinuousClock.now
        let frozen = try preparation.freeze(transcript: "预算 500")
        #expect(start.duration(to: .now) < .milliseconds(100))
        #expect(frozen.request.transcript == "预算 500")
        #expect(frozen.request.referenceImage != nil)
        #expect(frozen.request.imageSummary == nil)
        #expect(frozen.request.memorySummary == nil)
        #expect(frozen.receipt.imageSummary == .pending)
        await preparation.historyUpdate.historySaved()
        await imageGate.resolve(ScreenReferenceSummary(terms: ["预算 2000"], observations: []))
        await memoryGate.resolve(try CorrectionMemorySummary(memoryIDs: [memory.id], terms: ["OldProject"], corrections: []))
        try await late.wait()
        #expect(await late.count == 1)
        #expect(frozen.request.imageSummary == nil)
        #expect(frozen.request.memorySummary == nil)
        #expect(throws: ContextCorrectionError.self) { try preparation.freeze(transcript: "must not run twice") }
    }

    @Test func completedSummariesAreIndependentAndScreenCanArriveBeforeHistory() async throws {
        let imageGate = ContextTestGate<ScreenReferenceSummary>()
        let memoryGate = ContextTestGate<CorrectionMemorySummary>()
        let late = ContextLateSummaryProbe()
        let memory = sampleMemory()
        let preparation = try await prepare(
            summarizer: ContextTestSummarizer(image: { await imageGate.wait() }, memory: { await memoryGate.wait() }),
            memories: [memory], late: late
        )
        preparation.recordingStarted()
        try await imageGate.started()
        try await memoryGate.started()
        await memoryGate.resolve(try CorrectionMemorySummary(memoryIDs: [memory.id], terms: ["Rill"], corrections: []))
        try await waitUntil { preparation.preparedReceipt.memorySummary == .ready }
        let frozen = try preparation.freeze(transcript: "Rill")
        #expect(frozen.request.memorySummary?.memoryIDs == [memory.id])
        #expect(frozen.request.imageSummary == nil)
        await imageGate.resolve(ScreenReferenceSummary(terms: ["Rill"], observations: []))
        try await waitUntil { preparation.preparedReceipt.screenSummary != nil }
        #expect(await late.count == 0)
        await preparation.historyUpdate.historySaved()
        #expect(await late.count == 1)
        #expect(frozen.receipt.imageSummary == .pending)
    }

    @Test func captureDeadlineDiscardsAnUncooperativeLateFrame() async throws {
        let lateFrame = try image()
        let gate = ContextTestGate<CorrectionReferenceImage>()
        let completed = ContextTestGate<Result<RunContextPreparation, Error>>()
        let preparationTask = Task {
            do {
                let preparation = try await prepare(
                    capture: ContextTestCapture { await gate.wait() }, captureTimeout: .seconds(1)
                )
                await completed.resolve(.success(preparation))
            } catch { await completed.resolve(.failure(error)) }
        }
        let frozenResult: Result<RunContextPreparation.Frozen, Error>
        do {
            try await gate.started()
            let preparation = try await completed.resolved().get()
            frozenResult = .success(try preparation.freeze(transcript: "正文"))
        } catch { frozenResult = .failure(error) }
        // Release before draining, including when the deadline implementation joins the capture.
        await gate.resolve(lateFrame)
        await preparationTask.value
        let frozen = try frozenResult.get()
        #expect(frozen.receipt.image == .timedOut)
        #expect(frozen.request.referenceImage == nil)
    }

    @Test func summaryDeadlinesDoNotJoinUncooperativeRequests() async throws {
        let memory = sampleMemory()
        let lateMemory = try CorrectionMemorySummary(memoryIDs: [memory.id], terms: ["late"], corrections: [])
        let imageGate = ContextTestGate<ScreenReferenceSummary>()
        let memoryGate = ContextTestGate<CorrectionMemorySummary>()
        let preparation = try await prepare(
            summarizer: ContextTestSummarizer(
                image: { await imageGate.wait() }, memory: { await memoryGate.wait() }
            ),
            memories: [memory], summaryTimeout: .seconds(1)
        )
        preparation.recordingStarted()
        let frozenResult: Result<RunContextPreparation.Frozen, Error>
        do {
            try await imageGate.started()
            try await memoryGate.started()
            try await waitUntil {
                preparation.preparedReceipt.imageSummary == .timedOut
                    && preparation.preparedReceipt.memorySummary == .timedOut
            }
            frozenResult = .success(try preparation.freeze(transcript: "正文"))
        } catch { frozenResult = .failure(error) }
        await imageGate.resolve(ScreenReferenceSummary(terms: ["late"], observations: []))
        await memoryGate.resolve(lateMemory)
        preparation.cancel()
        let frozen = try frozenResult.get()
        #expect(frozen.receipt.imageSummary == .timedOut)
        #expect(frozen.receipt.memorySummary == .timedOut)
        #expect(frozen.request.imageSummary == nil)
        #expect(frozen.request.memorySummary == nil)
    }

    @Test func cancellationAndRevocationPreventFreezeAndLateWrites() async throws {
        let gate = ContextTestGate<ScreenReferenceSummary>()
        let late = ContextLateSummaryProbe()
        let authorization = ContextReferenceAuthorization(providerFingerprint: "fixture")
        let preparation = try await prepare(
            summarizer: ContextTestSummarizer(image: { await gate.wait() }, memory: { throw TestFailure.failed }),
            authorization: authorization, late: late
        )
        preparation.recordingStarted()
        try await gate.started()
        await preparation.historyUpdate.historySaved()
        authorization.revoke()
        preparation.cancel()
        await gate.resolve(ScreenReferenceSummary(terms: ["discard"], observations: []))
        #expect(throws: CancellationError.self) { try preparation.freeze(transcript: "正文") }
        #expect(await late.count == 0)
    }

    @Test func queuedAudioPassesFrozenReferencesToOneMainTransformation() async throws {
        let imageGate = ContextTestGate<ScreenReferenceSummary>()
        let preparation = try await prepare(summarizer: ContextTestSummarizer(
            image: { await imageGate.wait() }, memory: { throw TestFailure.failed }
        ))
        preparation.recordingStarted()
        try await imageGate.started()
        let transformer = ContextQueueTransformer()
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let coordinator = SessionCoordinator(
            contextProvider: ContextQueueContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: [ContextQueueRecognizer()]),
            transformerRegistry: TextTransformerRegistry(transformers: [transformer]),
            actionRegistry: OutputActionRegistry(actions: [ContextQueueAction()]),
            candidateResolver: CandidateResolver(eventBus: eventBus), eventBus: eventBus, diagnostics: diagnostics
        )
        let queue = CapturedAudioProcessingQueue(sessionCoordinator: coordinator, eventBus: eventBus)
        let workflow = WorkflowDefinition(name: "Context queue", pipeline: PipelineDeclaration(
            recognizerID: "context.test", postProcessSteps: [PostProcessStep(kind: .llmRewrite, prompt: "Cleanup")], outputActions: [OutputActionReference(id: "context.output")]
        ), ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue"))
        let audio = try CapturedAudio(durationSeconds: 0.2,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16), inlineData: Data([0, 0]))
        let transfer = await queue.enqueue(authorizationLease: makeAudioProcessingTestLease(
            runID: UUID(), workflow: workflow, contextPreparation: preparation
        ), triggerEvent: nil, deferredCapture: .resolved(audio))
        #expect(transfer == .accepted)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await queue.pendingCount > 0 && ContinuousClock.now < deadline { await Task.yield() }
        #expect(await queue.pendingCount == 0)
        let requests = await transformer.requests
        let events = await diagnostics.snapshot()
        #expect(requests.count == 1, "\(events)")
        #expect(requests.first?.transcript == "预算 500")
        #expect(requests.first?.referenceImage != nil)
        #expect(requests.first?.imageSummary == nil)
        await imageGate.resolve(ScreenReferenceSummary(terms: ["预算 2000"], observations: []))
        try await waitUntil { preparation.isFinished }
        #expect(await transformer.requests.count == 1)
        await queue.shutdown()
    }

    private func prepare(capture: (any ScreenContextCapturing)? = nil,
                         summarizer: ContextTestSummarizer = ContextTestSummarizer(),
                         memories: [LongTermMemory] = [],
                         authorization: ContextReferenceAuthorization = ContextReferenceAuthorization(providerFingerprint: "fixture"),
                         captureTimeout: Duration = .seconds(2), summaryTimeout: Duration = .seconds(10),
                         late: ContextLateSummaryProbe = ContextLateSummaryProbe()) async throws -> RunContextPreparation {
        try await RunContextPreparation.prepare(
            focus: .init(applicationName: "Editor", bundleIdentifier: "test.editor", processIdentifier: 1,
                         focusedRole: nil, selectedText: "", secureInput: false),
            screenEnabled: true, memoryEnabled: true, excludedApplications: [],
            capture: capture ?? ContextTestCapture { try image() }, summarizer: summarizer,
            memories: { memories }, authorization: authorization, audioLifetime: AudioCaptureLifetime(runID: UUID()),
            captureTimeout: captureTimeout, summaryTimeout: summaryTimeout,
            saveLateSummary: { summary, _ in await late.record(summary) }
        )
    }

    private func image() throws -> CorrectionReferenceImage {
        try CorrectionReferenceImage(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), width: 8, height: 8)
    }

    private func sampleMemory() -> LongTermMemory {
        LongTermMemory(scope: ContextMemoryScope(workflowID: UUID(), applicationBundleID: "test.editor", language: nil),
                       summary: "Rill", terms: ["Rill"], evidenceKind: .userStatement,
                       sources: [MemorySourceVersion(sourceID: UUID(), revision: 1)])
    }

    private func waitUntil(_ ready: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !ready(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(ready())
    }
}

private enum TestFailure: Error { case failed }
private struct ContextTestCapture: ScreenContextCapturing {
    let action: @Sendable () async throws -> CorrectionReferenceImage
    func capture(focus: FocusSnapshot, excludingApplications: Set<String>) async throws -> CorrectionReferenceImage { try await action() }
}
private struct ContextTestSummarizer: CorrectionContextSummarizing {
    var image: @Sendable () async throws -> ScreenReferenceSummary = { ScreenReferenceSummary(terms: ["Rill"], observations: []) }
    var memory: @Sendable () async throws -> CorrectionMemorySummary = { throw TestFailure.failed }
    func summarizeImage(_ image: CorrectionReferenceImage) async throws -> ScreenReferenceSummary { try await self.image() }
    func summarizeMemories(_ memories: [LongTermMemory]) async throws -> CorrectionMemorySummary { try await memory() }
}
private actor ContextTestGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var hasStarted = false
    private var resolvedValue: Value?

    func wait() async -> Value {
        hasStarted = true
        if let resolvedValue { return resolvedValue }
        return await withCheckedContinuation { continuation = $0 }
    }

    func started() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !hasStarted, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(hasStarted, "The dependency did not start before the test deadline")
    }

    func resolved() async throws -> Value {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while resolvedValue == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        return try #require(resolvedValue, "Preparation did not return while its dependency was held")
    }

    func resolve(_ value: Value) {
        resolvedValue = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}
private actor ContextLateSummaryProbe {
    private(set) var count = 0
    func record(_: ScreenReferenceSummary) { count += 1 }

    func wait() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while count == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(count > 0, "The late summary was not persisted")
    }
}

private struct ContextQueueContextProvider: ContextProvider {
    func captureContext() async -> ContextSnapshot { .empty }
}
private struct ContextQueueRecognizer: SpeechRecognizer {
    let id = "context.test"
    var result = RecognitionResult(rawText: "预算 500", bestText: "预算 500")
    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        result
    }
}
private actor ContextQueueTransformer: TextTransformer {
    nonisolated let id = "context.transform"
    nonisolated let supportedKinds: [PostProcessStepKind] = [.llmRewrite, .normalizeWhitespace]
    private(set) var requests: [ContextualCorrectionRequest] = []
    func transform(text: String, step: PostProcessStep, context: TransformContext) async throws -> String {
        if step.kind == .normalizeWhitespace { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let request = context.correctionRequest { requests.append(request) }
        return text
    }
}

private struct ContextQueueAction: OutputAction {
    let id = "context.output"
    func execute(text: String, context: ActionContext) async throws -> ActionResult { .copiedToClipboard }
}
