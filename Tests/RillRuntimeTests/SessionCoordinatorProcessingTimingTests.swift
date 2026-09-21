import Foundation
import XCTest
@testable import RillCore
@testable import RillRuntime

private final class ProcessingTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: UInt64 = 0

    func now() -> UInt64 { lock.withLock { nanoseconds } }

    func advance(milliseconds: UInt64) {
        lock.withLock { nanoseconds += milliseconds * 1_000_000 }
    }
}

private enum ProcessingTestOutcome: Sendable {
    case success, failure, cancelled, timeout

    func check() throws {
        switch self {
        case .success: break
        case .failure: throw ProcessingTestError()
        case .cancelled: throw CancellationError()
        case .timeout: throw RecognitionDeadlineError.timedOut
        }
    }
}

private struct ProcessingTestError: SpeechTextFallbackEligibleError {
    let allowsSpeechTextFallback = true
}

private struct ProcessingTestRecognizer: SpeechRecognizer {
    let id = "timed.recognizer"
    let clock: ProcessingTestClock
    let outcome: ProcessingTestOutcome

    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        clock.advance(milliseconds: 1_234)
        try outcome.check()
        return RecognitionResult(rawText: "recognized", bestText: "recognized")
    }
}

private struct ProcessingTestTransformer: TracedTextTransformer {
    let id = "timed.transformer"
    let supportedKinds: [PostProcessStepKind] = [.llmRewrite, .llmAnswer]
    let clock: ProcessingTestClock
    let outcome: ProcessingTestOutcome

    func transform(text: String, step: PostProcessStep, context: TransformContext) async throws -> String {
        try await transformWithTrace(text: text, step: step, context: context).text
    }

    func transformWithTrace(text: String, step: PostProcessStep, context: TransformContext) async throws -> TracedTextTransformation {
        clock.advance(milliseconds: step.kind == .llmRewrite ? 2_500 : 87)
        try outcome.check()
        let output = text + " transformed"
        return TracedTextTransformation(text: output, trace: LanguageModelTrace(
            providerID: id, modelID: "test", systemPrompt: "", workflowPrompt: "",
            messages: [.init(role: .user, content: text)], responseText: output
        ))
    }
}

private struct ProcessingTestContext: ContextProvider {
    func captureContext() async -> ContextSnapshot { .empty }
}

private struct ProcessingTestAction: OutputAction {
    let id = "timed.action"
    let clock: ProcessingTestClock

    func execute(text: String, context: ActionContext) async throws -> ActionResult {
        clock.advance(milliseconds: 60_000)
        return .copiedToClipboard
    }
}

final class SessionCoordinatorProcessingTimingTests: XCTestCase {
    func testRecognitionAndEachLanguageModelStepRetainSeparateDurationsExcludingDelivery() async throws {
        let harness = makeHarness(steps: [.llmRewrite, .llmAnswer])
        let result = await harness.coordinator.runReportingOutcome(workflow: harness.workflow, contextSnapshot: .empty)
        guard case .completed(let summary) = result else { return XCTFail("Expected completion") }
        let steps = try XCTUnwrap(summary.correctionSource?.processingSteps)
        XCTAssertEqual(steps.first?.durationMilliseconds, 1_234)
        XCTAssertEqual(steps.filter { [.llmRewrite, .llmAnswer].contains($0.kind) }.map(\.durationMilliseconds), [2_500, 87])
        let receipts = try await harness.repository.receipts(matching: .init(runID: summary.runID))
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(receipt.stepDetails.filter { [.recognizeSpeech, .llmRewrite, .llmAnswer].contains($0.kind) }.map(\.durationMilliseconds), [1_234, 2_500, 87])
        XCTAssertEqual(receipt.actionDetails.first?.duration, .m1Plus)
        XCTAssertEqual(summary.finalText, "recognized transformed transformed")
    }

    func testTextInputDoesNotInventRecognitionDuration() async throws {
        let harness = makeHarness(steps: [.llmRewrite], recognition: .failure)
        let result = await harness.coordinator.runReportingOutcome(
            workflow: harness.workflow, contextSnapshot: .empty, preRecognizedText: "existing text"
        )
        guard case .completed(let summary) = result else { return XCTFail("Expected text processing") }
        XCTAssertNil(summary.correctionSource?.processingSteps?.first?.durationMilliseconds)
        XCTAssertEqual(summary.correctionSource?.processingSteps?.last?.durationMilliseconds, 2_500)
        let receipts = try await harness.repository.receipts(matching: .init(runID: summary.runID))
        XCTAssertFalse(try XCTUnwrap(receipts.first).stepDetails.contains { $0.kind == .recognizeSpeech })
    }

    func testRecognitionFailuresCancellationAndTimeoutRetainElapsedTime() async throws {
        for outcome: ProcessingTestOutcome in [.failure, .cancelled, .timeout] {
            let harness = makeHarness(steps: [.llmRewrite], recognition: outcome)
            let runID = UUID()
            let stream = await harness.eventBus.stream()
            _ = await harness.coordinator.runReportingOutcome(workflow: harness.workflow, runID: runID, contextSnapshot: .empty)
            let receipts = try await harness.repository.receipts(matching: .init(runID: runID))
            let step = try XCTUnwrap(receipts.first?.stepDetails.first)
            XCTAssertEqual(step.kind, .recognizeSpeech)
            XCTAssertEqual(step.result, outcome == .cancelled ? .cancelled : .failed)
            XCTAssertEqual(step.durationMilliseconds, 1_234)
            for await event in stream {
                if case .runTextStepRecorded(_, let textStep) = event {
                    XCTAssertEqual(textStep.durationMilliseconds, 1_234)
                    XCTAssertNil(textStep.outputText)
                    break
                }
            }
        }
    }

    func testRecoverableRewriteFallbackRetainsFailedRequestDuration() async throws {
        let harness = makeHarness(steps: [.llmRewrite], transformation: .failure)
        let result = await harness.coordinator.runReportingOutcome(
            workflow: harness.workflow, contextSnapshot: .empty, preRecognizedText: "keep this"
        )
        guard case .completed(let summary) = result else { return XCTFail("Expected transcript fallback") }
        let step = try XCTUnwrap(summary.correctionSource?.processingSteps?.last)
        XCTAssertEqual(summary.finalText, "keep this")
        XCTAssertEqual(step.result, .skipped)
        XCTAssertEqual(step.durationMilliseconds, 2_500)
        let receipts = try await harness.repository.receipts(matching: .init(runID: summary.runID))
        XCTAssertEqual(receipts.first?.stepDetails.last?.durationMilliseconds, 2_500)
    }

    func testFailedAndCancelledLanguageModelCallsRetainElapsedTime() async throws {
        for outcome: ProcessingTestOutcome in [.failure, .cancelled] {
            let harness = makeHarness(steps: [.llmAnswer], transformation: outcome)
            let runID = UUID()
            _ = await harness.coordinator.runReportingOutcome(workflow: harness.workflow, runID: runID, contextSnapshot: .empty)
            let receipts = try await harness.repository.receipts(matching: .init(runID: runID))
            let step = try XCTUnwrap(receipts.first?.stepDetails.last)
            XCTAssertEqual(step.kind, .llmAnswer)
            XCTAssertEqual(step.result, outcome == .cancelled ? .cancelled : .failed)
            XCTAssertEqual(step.durationMilliseconds, 87)
        }
    }

    private func makeHarness(
        steps: [PostProcessStepKind],
        recognition: ProcessingTestOutcome = .success,
        transformation: ProcessingTestOutcome = .success
    ) -> (coordinator: SessionCoordinator, workflow: WorkflowDefinition, repository: InMemoryWorkflowRunReceiptRepository, eventBus: EventBus) {
        let clock = ProcessingTestClock()
        let eventBus = EventBus()
        let repository = InMemoryWorkflowRunReceiptRepository()
        let workflow = WorkflowDefinition(
            name: "Timed speech",
            pipeline: PipelineDeclaration(
                recognizerID: "timed.recognizer",
                postProcessSteps: steps.map { PostProcessStep(kind: $0, prompt: "Process") },
                outputActions: [.init(id: "timed.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
        let coordinator = SessionCoordinator(
            contextProvider: ProcessingTestContext(),
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: [ProcessingTestRecognizer(clock: clock, outcome: recognition)]),
            transformerRegistry: TextTransformerRegistry(transformers: [ProcessingTestTransformer(clock: clock, outcome: transformation)]),
            actionRegistry: OutputActionRegistry(actions: [ProcessingTestAction(clock: clock)]),
            candidateResolver: CandidateResolver(eventBus: eventBus), eventBus: eventBus,
            runReceiptRecorder: WorkflowRunReceiptRecorder(repository: repository, monotonicClock: { clock.now() }),
            processingClock: { clock.now() }
        )
        return (coordinator, workflow, repository, eventBus)
    }
}
