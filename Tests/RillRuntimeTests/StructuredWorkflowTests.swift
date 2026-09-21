import Foundation
import RillCore
import Testing

@testable import RillRuntime

private actor StructuredOutputProbe {
    var deliveries: [String] = []
    func record(_ value: String) { deliveries.append(value) }
}
private struct StructuredOutput: OutputAction {
    let id: String
    let probe: StructuredOutputProbe
    var fails = false
    func execute(text: String, context: ActionContext) async throws -> ActionResult {
        await probe.record(id + ":" + text)
        return fails ? .failed("fixture failure") : .copiedToClipboard
    }
}
private struct StructuredTransformer: TextTransformer {
    let id = "test.transformer"
    let supportedKinds: [PostProcessStepKind] = [.llmRewrite, .normalizeWhitespace]
    func transform(text: String, step: PostProcessStep, context: TransformContext) async throws
        -> String
    {
        text + (step.prompt ?? " clean")
    }
}
private struct StructuredContext: ContextProvider {
    func captureContext() async -> ContextSnapshot { .empty }
}

struct StructuredWorkflowTests {
    @Test func branchesAndSkippedOutputsProduceOrderedReceipts() async throws {
        let (coordinator, probe, receipts) = makeCoordinator()
        let workflow = makeWorkflow()
        let result = await coordinator.runReportingOutcome(
            workflow: workflow, contextSnapshot: .empty, preRecognizedText: "match")
        guard case .completed(let summary) = result else {
            Issue.record("Expected a completed run")
            return
        }
        #expect(summary.finalText == "match then")
        #expect(summary.correctionSource?.processingSteps?.map(\.kind) == [.recognizeSpeech, .conditional, .llmRewrite])
        #expect(summary.correctionSource?.processingSteps?.map(\.outputText) == ["match", nil, "match then"])
        #expect(summary.correctionSource?.processingSteps?[1].result == .thenBranch)
        #expect(await probe.deliveries == ["second:match then"])
        let receipt = try #require(try await receipts.receipts(matching: .all).first)
        #expect(receipt.actionDetails.map(\.result) == [.skipped, .copiedToClipboard])
        #expect(receipt.stepDetails.map(\.kind) == [.conditional, .llmRewrite])
        #expect(receipt.stepDetails.map(\.result) == [.thenBranch, .completed])
        let json = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        #expect(!json.contains("match"))
        #expect(!json.contains("then\""))
    }

    @Test func laterOutputFailurePreservesEarlierEffectAndStopsRemainingOutputs() async throws {
        let (coordinator, probe, receipts) = makeCoordinator()
        var workflow = makeWorkflow()
        workflow.plan.output.actions = [
            OutputActionReference(id: "second"), OutputActionReference(id: "failure"),
            OutputActionReference(id: "second"),
        ]
        _ = await coordinator.runReportingOutcome(
            workflow: workflow, contextSnapshot: .empty, preRecognizedText: "other")
        #expect(await probe.deliveries == ["second:other else", "failure:other else"])
        let receipt = try #require(try await receipts.receipts(matching: .all).first)
        #expect(receipt.termination == .partiallyCompleted(code: .processing))
        #expect(receipt.actionDetails.map(\.result) == [.copiedToClipboard, .failed])
        #expect(receipt.stepDetails.first?.result == .elseBranch)
    }

    @Test func testUsesSameBranchSemanticsAndNeverEmitsOutputsOrReceipts() async throws {
        let (coordinator, probe, receipts) = makeCoordinator()
        var workflow = makeWorkflow()
        workflow.plan.output.actions = []
        let authorization = AuthorizedWorkflowRunContext(
            workflow: workflow, contextSnapshot: .empty, recognitionOptions: .empty)
        let results = try await coordinator.testProcess(
            text: "match", authorizedContext: authorization)
        #expect(results.last?.output == "match then")
        #expect(results.first?.branch == true)
        #expect(await probe.deliveries.isEmpty)
        #expect(try await receipts.receipts(matching: .all).isEmpty)
        await #expect(throws: (any Error).self) {
            try await coordinator.testProcess(text: "match", authorizedContext: authorization)
        }
        let unsafeAuthorization = AuthorizedWorkflowRunContext(
            workflow: makeWorkflow(), contextSnapshot: .empty, recognitionOptions: .empty)
        await #expect(throws: WorkflowDocumentError.self) {
            try await coordinator.testProcess(text: "match", authorizedContext: unsafeAuthorization)
        }
        #expect(await probe.deliveries.isEmpty)
    }

    @Test func testStopsAtSelectionAndPinsOnlyExplicitSamples() async throws {
        let (coordinator, _, _) = makeCoordinator()
        var workflow = makeWorkflow()
        workflow.plan.output.actions = []
        let condition = workflow.plan.process.steps[0]
        let stopped = try await coordinator.testProcess(
            text: "match", stopAfter: condition.id,
            authorizedContext: AuthorizedWorkflowRunContext(
                workflow: workflow, contextSnapshot: .empty, recognitionOptions: .empty))
        #expect(stopped.count == 1)
        #expect(stopped[0].output == "match")
        let thenID = try #require(condition.thenSteps?.first?.id)
        let pinned = try await coordinator.testProcess(
            text: "match", fixedSamples: [thenID: "fixed result"],
            authorizedContext: AuthorizedWorkflowRunContext(
                workflow: workflow, contextSnapshot: .empty, recognitionOptions: .empty))
        #expect(pinned.last?.output == "fixed result")
    }

    @Test func missingContextFailsBeforeAnyOutput() async throws {
        let (coordinator, probe, receipts) = makeCoordinator()
        var workflow = makeWorkflow()
        workflow.plan.process.steps[0].condition = .comparison(
            field: .appBundleID, operation: .equals, value: "unavailable")
        _ = await coordinator.runReportingOutcome(
            workflow: workflow, contextSnapshot: .empty, preRecognizedText: "match")
        #expect(await probe.deliveries.isEmpty)
        let receipt = try #require(try await receipts.receipts(matching: .all).first)
        #expect(receipt.stepDetails.first?.result == .failed)
    }

    private func makeWorkflow() -> WorkflowDefinition {
        var condition = WorkflowProcessStep(kind: .conditional)
        condition.condition = .comparison(field: .text, operation: .equals, value: "match")
        condition.thenSteps = [WorkflowProcessStep(kind: .llmRewrite, prompt: " then")]
        condition.elseSteps = [WorkflowProcessStep(kind: .llmRewrite, prompt: " else")]
        var skipped = OutputActionReference(id: "first")
        skipped.condition = .comparison(field: .text, operation: .equals, value: "skip")
        return WorkflowDefinition(
            name: "Structured", trigger: .manual,
            plan: WorkflowPlan(
                setup: WorkflowSetupPhase(), process: WorkflowProcessPhase(steps: [condition]),
                output: WorkflowOutputPhase(actions: [skipped, OutputActionReference(id: "second")])
            ), ui: WorkflowUIConfig(symbolName: "sparkles", accentColorName: "blue"))
    }

    private func makeCoordinator() -> (
        SessionCoordinator, StructuredOutputProbe, InMemoryWorkflowRunReceiptRepository
    ) {
        let probe = StructuredOutputProbe()
        let receipts = InMemoryWorkflowRunReceiptRepository()
        let eventBus = EventBus()
        let coordinator = SessionCoordinator(
            contextProvider: StructuredContext(),
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: [StructuredTransformer()]),
            actionRegistry: OutputActionRegistry(actions: [
                StructuredOutput(id: "first", probe: probe),
                StructuredOutput(id: "second", probe: probe),
                StructuredOutput(id: "failure", probe: probe, fails: true),
            ]), candidateResolver: CandidateResolver(eventBus: eventBus), eventBus: eventBus,
            runReceiptRecorder: WorkflowRunReceiptRecorder(repository: receipts))
        return (coordinator, probe, receipts)
    }
}
