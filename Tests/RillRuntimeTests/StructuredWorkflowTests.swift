@testable import RillWorkflows
import RillDomainTestSupport
import Foundation
import RillCore
import Testing

private actor StructuredOutputProbe {
  var deliveries: [String] = []
  func record(_ value: String) { deliveries.append(value) }
}
private struct StructuredOutput: OutputAction {
  let id: String
  let probe: StructuredOutputProbe
  var fails = false
  func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
    let text = try record.requireText(for: id)
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

  @Test func allOutputsOffCompletesProcessingWithoutExternalActions() async throws {
    let (coordinator, probe, receipts) = makeCoordinator()
    var declared = makeWorkflow()
    for index in declared.plan.output.actions.indices { declared.plan.output.actions[index].optional = true }
    let selected = try WorkflowOutputState(workflowID: declared.id, outputs: ["output-1": false, "output-2": false]).applying(to: declared)
    let result = await coordinator.runReportingOutcome(workflow: selected, contextSnapshot: .empty, preRecognizedText: "match")
    guard case .completed(let summary) = result else {
      Issue.record("Expected processing with no outputs to complete")
      return
    }
    #expect(summary.finalText == "match then")
    #expect(await probe.deliveries.isEmpty)
    let receipt = try #require(try await receipts.receipts(matching: .all).first)
    #expect(receipt.termination == .completed)
    #expect(receipt.actionDetails.isEmpty)
  }

  @Test func optionalUnconfiguredLLMSkipsTheCallAndKeepsInputText() async throws {
    let (coordinator, probe, receipts) = makeCoordinator()
    var value = makeWorkflow()
    var step = WorkflowProcessStep(kind: .llmRewrite, prompt: " should not execute", reasoning: .some(.none))
    step.optional = true
    value.plan.process.steps = [step]
    value.plan.output.actions = [OutputActionReference(id: "second")]
    let bindings = try LanguageModelSettingsSource().snapshot(for: value)
    let result = await coordinator.runReportingOutcome(
      workflow: value, contextSnapshot: .empty,
      preRecognizedText: "original", modelSnapshot: bindings)
    guard case .completed(let summary) = result else {
      Issue.record("Expected optional skip to continue")
      return
    }
    #expect(summary.finalText == "original")
    #expect(await probe.deliveries == ["second:original"])
    let receipt = try #require(try await receipts.receipts(matching: .all).first)
    #expect(receipt.stepDetails.first?.result == .skipped)
  }

  @Test func recordInputCannotBeReplacedWithClipboardOrCommandText() async throws {
    let (coordinator, probe, receipts) = makeCoordinator()
    var value = makeWorkflow()
    value.declaredInputKind = .record
    let context = ContextSnapshot(focus: ContextSnapshot.empty.focus, clipboard: .init(plainText: "match", changeCount: 1))
    await coordinator.run(authorizedContext: .init(workflow: value, contextSnapshot: context, recognitionOptions: .empty))
    await coordinator.runRecognizedText("match", authorizedContext: .init(workflow: value, contextSnapshot: context, recognitionOptions: .empty))
    #expect(await probe.deliveries.isEmpty)
    let recorded = try await receipts.receipts(matching: .all)
    #expect(recorded.count == 2)
    #expect(recorded.allSatisfy { $0.actionDetails.isEmpty && $0.stepDetails.isEmpty })
  }

  private func makeWorkflow() -> WorkflowDefinition {
    var condition = WorkflowProcessStep(kind: .conditional)
    condition.condition = .comparison(field: .text, operation: .equals, value: "match")
    condition.thenSteps = [WorkflowProcessStep(kind: .llmRewrite, prompt: " then", reasoning: .some(.none))]
    condition.elseSteps = [WorkflowProcessStep(kind: .llmRewrite, prompt: " else", reasoning: .some(.none))]
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
    let coordinator = makeTestSessionCoordinator(

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
