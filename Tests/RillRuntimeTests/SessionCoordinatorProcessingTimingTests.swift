import RillDomainTestSupport
import Foundation
import XCTest
import Testing
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
    let candidateSets: [CandidateSet]

    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        clock.advance(milliseconds: 1_234)
        try outcome.check()
        return RecognitionResult(rawText: "recognized", bestText: "recognized", candidateSets: candidateSets)
    }
}

private struct ProcessingTestTransformer: TracedTextTransformer {
    let id = "timed.transformer"
    let supportedKinds: [PostProcessStepKind] = [.llmRewrite, .llmAnswer, .normalizeWhitespace]
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

    func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
        _ = try record.requireText(for: id)
        clock.advance(milliseconds: 60_000)
        return .copiedToClipboard
    }
}

final class SessionCoordinatorProcessingTimingTests: XCTestCase {
    func testSkippedResolutionHasTheSameStatusInReceiptsAndTextHistory() async throws {
        for mode: ResolutionMode in [.off, .nonBlocking] {
            var harness = makeProcessingHarness(steps: [], candidateSets: mode == .off ? [processingCandidateSet()] : [])
            let index = try XCTUnwrap(harness.workflow.plan.process.steps.firstIndex { $0.kind == .resolveUncertainty })
            harness.workflow.plan.process.steps[index].uncertaintyPolicy = .init(mode: mode)
            let outcome = await harness.coordinator.runReportingOutcome(workflow: harness.workflow, contextSnapshot: .empty)
            guard case .completed(let summary) = outcome else { return XCTFail("Expected speech completion") }
            let receipts = try await harness.repository.receipts(matching: .init(runID: summary.runID))
            let receiptStep = try XCTUnwrap(receipts.first?.stepDetails.first { $0.kind == .resolveUncertainty })
            let textStep = try XCTUnwrap(summary.correctionSource?.processingSteps?.first { $0.kind == .resolveUncertainty })
            XCTAssertEqual(receiptStep.result, .skipped)
            XCTAssertEqual(textStep.result, receiptStep.result)
            XCTAssertNil(receiptStep.durationMilliseconds)
            XCTAssertNil(textStep.durationMilliseconds)
        }
    }

    func testCompletedAndCancelledResolutionShareOneRecordedStatus() async throws {
        for cancel in [false, true] {
            let candidates = processingCandidateSet()
            let selected = try XCTUnwrap(candidates.candidates.first { $0.text == "corrected" })
            let harness = makeProcessingHarness(steps: [], candidateSets: [candidates])
            let runID = UUID()
            let stream = await harness.eventBus.stream()
            let run = Task {
                await harness.coordinator.runReportingOutcome(workflow: harness.workflow, runID: runID, contextSnapshot: .empty)
            }
            var textStep: WorkflowTextStep?
            for await event in stream {
                if case .candidateResolutionRequested(let request) = event {
                    if cancel { run.cancel() }
                    else {
                        _ = await harness.resolver.accept(caseID: request.id,
                            selections: [candidates.id: selected.id])
                    }
                }
                if case .runTextStepRecorded(_, let step) = event, step.kind == .resolveUncertainty {
                    textStep = step
                    break
                }
                if case .runCompleted = event { break }
                if case .runFailed = event { break }
            }
            let outcome = await run.value
            let receipts = try await harness.repository.receipts(matching: .init(runID: runID))
            let receiptStep = try XCTUnwrap(receipts.first?.stepDetails.first { $0.kind == .resolveUncertainty })
            XCTAssertEqual(receiptStep.result, cancel ? .cancelled : .completed)
            XCTAssertEqual(try XCTUnwrap(textStep).result, receiptStep.result)
            if cancel {
                guard case .cancelled = outcome else { return XCTFail("Expected cancellation") }
                XCTAssertTrue(try XCTUnwrap(receipts.first).actionDetails.isEmpty)
            } else {
                guard case .completed(let summary) = outcome else { return XCTFail("Expected completion") }
                XCTAssertEqual(summary.finalText, "corrected")
            }
        }
    }

    func testRecognitionAndEachLanguageModelStepRetainSeparateDurationsExcludingDelivery() async throws {
        let harness = makeProcessingHarness(steps: [.llmRewrite, .llmAnswer])
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
        let diagnostics = await harness.diagnostics.snapshot(matching: .init(runID: summary.runID))
        let timings = diagnostics.filter { $0.event == "session.process.timing" }
        XCTAssertEqual(timings.count, 3)
        for (kind, duration) in [("recognizeSpeech", "1234"), ("llmRewrite", "2500"), ("llmAnswer", "87")] {
            XCTAssertEqual(timings.first { $0.metadata["stepKind"] == kind }?.metadata["durationMillis"], duration)
        }
        XCTAssertTrue(timings.allSatisfy { $0.metadata["resultCode"] == "completed" })
    }

    func testTextInputDoesNotInventRecognitionDuration() async throws {
        let harness = makeProcessingHarness(steps: [.llmRewrite], recognition: .failure)
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
            let harness = makeProcessingHarness(steps: [.llmRewrite], recognition: outcome)
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
        let harness = makeProcessingHarness(steps: [.llmRewrite], transformation: .failure)
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
            let harness = makeProcessingHarness(steps: [.llmAnswer], transformation: outcome)
            let runID = UUID()
            _ = await harness.coordinator.runReportingOutcome(workflow: harness.workflow, runID: runID, contextSnapshot: .empty)
            let receipts = try await harness.repository.receipts(matching: .init(runID: runID))
            let step = try XCTUnwrap(receipts.first?.stepDetails.last)
            XCTAssertEqual(step.kind, .llmAnswer)
            XCTAssertEqual(step.result, outcome == .cancelled ? .cancelled : .failed)
            XCTAssertEqual(step.durationMilliseconds, 87)
        }
    }

}

private func makeProcessingHarness(
    steps: [PostProcessStepKind],
    recognition: ProcessingTestOutcome = .success,
    transformation: ProcessingTestOutcome = .success,
    candidateSets: [CandidateSet] = []
) -> (coordinator: SessionCoordinator, workflow: WorkflowDefinition, repository: InMemoryWorkflowRunReceiptRepository, eventBus: EventBus, resolver: CandidateResolver, diagnostics: DiagnosticsRecorder) {
    let clock = ProcessingTestClock()
    let eventBus = EventBus()
    let diagnostics = DiagnosticsRecorder()
    let repository = InMemoryWorkflowRunReceiptRepository()
    let resolver = CandidateResolver(eventBus: eventBus)
    let workflow = WorkflowDefinition(
        name: "Timed speech",
        pipeline: PipelineDeclaration(
            recognizerID: "timed.recognizer",
            postProcessSteps: steps.map { PostProcessStep(kind: $0, prompt: $0 == .normalizeWhitespace ? nil : "Process") },
            outputActions: [.init(id: "timed.action")]
        ),
        ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
    )
    let coordinator = makeTestSessionCoordinator(

        recognizerRegistry: SpeechRecognizerRegistry(recognizers: [ProcessingTestRecognizer(clock: clock, outcome: recognition, candidateSets: candidateSets)]),
        transformerRegistry: TextTransformerRegistry(transformers: [ProcessingTestTransformer(clock: clock, outcome: transformation)]),
        actionRegistry: OutputActionRegistry(actions: [ProcessingTestAction(clock: clock)]),
        candidateResolver: resolver, eventBus: eventBus,
        diagnostics: diagnostics,
        runReceiptRecorder: WorkflowRunReceiptRecorder(repository: repository, monotonicClock: { clock.now() }),
        processingClock: { clock.now() }
    )
    return (coordinator, workflow, repository, eventBus, resolver, diagnostics)
}

private func processingCandidateSet() -> CandidateSet {
    CandidateSet(surfaceText: "recognized", range: TextRange(lowerBound: 0, upperBound: 10), candidates: [
        Candidate(text: "recognized", confidence: 0.4, source: .asr),
        Candidate(text: "corrected", confidence: 0.5, source: .asr),
    ])
}

struct ConfigurableProcessingTimingTests {
    @Test(arguments: [true, false])
    func timingSelectionAppliesToReceiptsAndTextHistory(enabled: Bool) async throws {
        var harness = makeProcessingHarness(steps: [.normalizeWhitespace, .llmRewrite])
        for index in harness.workflow.plan.process.steps.indices {
            harness.workflow.plan.process.steps[index].recordDuration = enabled
        }
        let audio = try CapturedAudio(
            durationSeconds: 12.5,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            inlineData: Data([0, 0])
        )
        let outcome = await harness.coordinator.runReportingOutcome(
            workflow: harness.workflow, capturedAudio: audio, contextSnapshot: .empty
        )
        guard case .completed(let summary) = outcome else {
            Issue.record("Expected speech completion, received \(outcome)")
            return
        }
        let receipts = try await harness.repository.receipts(matching: .init(runID: summary.runID))
        let receipt = try #require(receipts.first)
        #expect(receipt.recordingDurationMilliseconds == 12_500)
        #expect(receipt.actionDetails.first?.durationMilliseconds == 60_000)
        let measured = receipt.stepDetails.filter { [.recognizeSpeech, .normalizeWhitespace, .llmRewrite].contains($0.kind) }
        #expect(measured.map(\.durationMilliseconds) == (enabled ? [1_234, 87, 2_500] : [nil, nil, nil]))
        let textSteps = try #require(summary.correctionSource?.processingSteps)
        #expect(textSteps.filter { [.recognizeSpeech, .normalizeWhitespace, .llmRewrite].contains($0.kind) }
            .map(\.durationMilliseconds) == (enabled ? [1_234, 87, 2_500] : [nil, nil, nil]))
    }

    @Test func onlyTheSelectedBranchRecordsItsConfiguredDurations() async throws {
        var harness = makeProcessingHarness(steps: [.normalizeWhitespace])
        var selected = WorkflowProcessStep(kind: .normalizeWhitespace, recordDuration: true)
        selected.documentID = "selected"
        var branch = WorkflowProcessStep(kind: .conditional, recordDuration: true)
        branch.condition = .comparison(field: .text, operation: .contains, value: "recognized")
        branch.thenSteps = [selected]
        branch.elseSteps = [WorkflowProcessStep(kind: .llmRewrite, prompt: "Unused", recordDuration: true)]
        let index = try #require(harness.workflow.plan.process.steps.firstIndex { $0.kind == .normalizeWhitespace })
        harness.workflow.plan.process.steps[index] = branch
        let runID = UUID()
        _ = await harness.coordinator.runReportingOutcome(workflow: harness.workflow, runID: runID, contextSnapshot: .empty)
        let receipts = try await harness.repository.receipts(matching: .init(runID: runID))
        let receipt = try #require(receipts.first)
        #expect(receipt.outcome == .completed)
        #expect(receipt.stepDetails.first { $0.kind == .conditional }?.durationMilliseconds == 0)
        #expect(receipt.stepDetails.first { $0.kind == .normalizeWhitespace }?.durationMilliseconds == 87)
        #expect(!receipt.stepDetails.contains { $0.kind == .llmRewrite })
        #expect(receipt.recordingDurationMilliseconds == nil)
    }

    @Test func recordingLengthSurvivesRecognitionFailure() async throws {
        let harness = makeProcessingHarness(steps: [.llmRewrite], recognition: .failure)
        let audio = try CapturedAudio(
            durationSeconds: 8,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            inlineData: Data([0, 0])
        )
        let runID = UUID()
        _ = await harness.coordinator.runReportingOutcome(
            workflow: harness.workflow, runID: runID, capturedAudio: audio, contextSnapshot: .empty
        )
        let receipts = try await harness.repository.receipts(matching: .init(runID: runID))
        let receipt = try #require(receipts.first)
        #expect(receipt.recordingDurationMilliseconds == 8_000)
        #expect(receipt.stepDetails.first?.durationMilliseconds == 1_234)
        #expect(receipt.stepDetails.first?.result == .failed)
        #expect(!receipt.stepDetails.contains { $0.kind == .llmRewrite })
    }
}
