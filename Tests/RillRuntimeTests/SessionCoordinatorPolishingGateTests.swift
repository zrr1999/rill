import Foundation
import Testing
@testable import RillCore
@testable import RillRuntime
import RillProviders

struct SessionCoordinatorPolishingGateTests {
  @Test(arguments: [true, false])
  func predictionControlsLLMAndPreservesStoreBeforeDelivery(skip: Bool) async throws {
    let fixture = try fixture(skip: skip)
    let outcome = await fixture.coordinator.runReportingOutcome(
      workflow: fixture.workflow, contextSnapshot: .empty, preRecognizedText: "  明天开会。  ")
    guard case .completed(let summary) = outcome else {
      Issue.record("Expected completion: \(outcome)")
      return
    }
    let expected = skip ? "明天开会。" : "明天开会。 rewritten"
    #expect(summary.finalText == expected)
    #expect(await fixture.gate.inputs == ["明天开会。"])
    #expect(await fixture.transformer.calls == (skip ? 0 : 1))
    #expect(await fixture.delivery.texts == [expected])
    #expect(await fixture.delivery.wasStoredBeforeDelivery)
    let snapshot = try await fixture.store.catalogSnapshot()
    let storedID = try #require(snapshot.records.first?.id)
    #expect(try await fixture.store.record(id: storedID)?.record.payload == .text(expected))
    let step = try #require(summary.correctionSource?.processingSteps?.last)
    #expect(step.result == (skip ? .skipped : .completed))
    #expect(step.didChange == !skip)
    if skip {
      #expect(summary.correctionSource?.languageModelInputTexts == nil)
      #expect(summary.correctionSource?.languageModelTraces == nil)
      #expect(step.durationMilliseconds == nil)
      #expect(step.tokenUsage == nil)
    } else {
      #expect(summary.correctionSource?.languageModelInputTexts == ["明天开会。"])
      #expect(summary.correctionSource?.languageModelTraces?.count == 1)
    }
    let receipts = try await fixture.receipts.receipts(matching: .init(runID: summary.runID))
    let receipt = try #require(receipts.first)
    #expect(receipt.stepDetails.last?.result == step.result)
    #expect(receipt.actionDetails.map(\.result) == [.storedRecord, .injected])
    if skip { #expect(receipt.stepDetails.last?.durationMilliseconds == nil) }
  }

  @Test func cancellationDuringPredictionDoesNotRewriteOrDeliver() async throws {
    let fixture = try fixture(skip: true, cancel: true)
    let runID = UUID()
    let outcome = await fixture.coordinator.runReportingOutcome(
      workflow: fixture.workflow, runID: runID, contextSnapshot: .empty, preRecognizedText: "保留。")
    guard case .cancelled = outcome else {
      Issue.record("Expected cancellation: \(outcome)")
      return
    }
    #expect(await fixture.transformer.calls == 0)
    #expect(await fixture.delivery.texts.isEmpty)
    #expect(try await fixture.store.catalogSnapshot().records.isEmpty)
    let receipts = try await fixture.receipts.receipts(matching: .init(runID: runID))
    #expect(receipts.first?.stepDetails.last?.result == .cancelled)
    #expect(receipts.first?.actionDetails.isEmpty == true)
  }

  @Test func answersNeverConsultThePolishingGate() async throws {
    var fixture = try fixture(skip: true)
    let index = try #require(fixture.workflow.plan.process.steps.firstIndex { $0.kind == .llmRewrite })
    fixture.workflow.plan.process.steps[index].kind = .llmAnswer
    let outcome = await fixture.coordinator.runReportingOutcome(
      workflow: fixture.workflow, contextSnapshot: .empty, preRecognizedText: "Answer me")
    guard case .completed = outcome else {
      Issue.record("Expected answer completion: \(outcome)")
      return
    }
    #expect(await fixture.gate.inputs.isEmpty)
    #expect(await fixture.transformer.calls == 1)
  }

  private struct Fixture {
    let coordinator: SessionCoordinator
    var workflow: WorkflowDefinition
    let gate: PolishingGateProbe
    let transformer: PolishingTransformerProbe
    let store: RecordStore
    let delivery: PolishingDeliveryProbe
    let receipts: InMemoryWorkflowRunReceiptRepository
  }

  private func fixture(skip: Bool, cancel: Bool = false) throws -> Fixture {
    let store = RecordStore()
    let eventBus = EventBus()
    let gate = PolishingGateProbe(skip: skip, cancel: cancel)
    let transformer = PolishingTransformerProbe()
    let delivery = PolishingDeliveryProbe(store: store)
    let receipts = InMemoryWorkflowRunReceiptRepository()
    let workflow = try #require(BuiltinWorkflowCatalog().manifest().workflows.first { $0.titleKey == .smartCleanup })
    let coordinator = SessionCoordinator(

      recognizerRegistry: .init(recognizers: []),
      transformerRegistry: .init(transformers: [WhitespaceNormalizerTransformer(), transformer]),
      textPolishingGate: gate,
      actionRegistry: .init(actions: [RecordStoreAction(ingestion: RecordIngestionCoordinator(store: store)), delivery]),
      candidateResolver: CandidateResolver(eventBus: eventBus), recordStore: store,
      eventBus: eventBus, runReceiptRecorder: WorkflowRunReceiptRecorder(repository: receipts))
    return Fixture(coordinator: coordinator, workflow: workflow, gate: gate, transformer: transformer,
      store: store, delivery: delivery, receipts: receipts)
  }
}

private struct PolishingContextProvider: ContextProvider {
  func captureContext() async -> ContextSnapshot { .empty }
}

private actor PolishingGateProbe: TextPolishingGate {
  let skip: Bool
  let cancel: Bool
  var inputs: [String] = []
  init(skip: Bool, cancel: Bool) { self.skip = skip; self.cancel = cancel }
  func shouldSkip(text: String, step: PostProcessStep, context: TransformContext) throws -> Bool {
    inputs.append(text)
    if cancel { throw CancellationError() }
    return skip
  }
}

private actor PolishingTransformerProbe: TracedTextTransformer {
  nonisolated let id = "polishing.test"
  nonisolated let supportedKinds: [PostProcessStepKind] = [.llmRewrite, .llmAnswer]
  var calls = 0
  func transform(text: String, step: PostProcessStep, context: TransformContext) throws -> String {
    try transformWithTrace(text: text, step: step, context: context).text
  }
  func transformWithTrace(text: String, step: PostProcessStep, context: TransformContext) throws -> TracedTextTransformation {
    calls += 1
    let output = text + " rewritten"
    return .init(text: output, trace: .init(providerID: id, modelID: "test",
      systemPrompt: "", workflowPrompt: step.prompt ?? "", messages: [.init(role: .user, content: text)],
      responseText: output))
  }
}

private actor PolishingDeliveryProbe: OutputAction {
  nonisolated let id = "focused-application.insert"
  let store: RecordStore
  var texts: [String] = []
  var wasStoredBeforeDelivery = false
  init(store: RecordStore) { self.store = store }
  func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
      let text = try record.requireText(for: id)
    texts.append(text)
    let snapshot = try await store.catalogSnapshot()
    if let id = snapshot.records.first?.id {
      wasStoredBeforeDelivery = try await store.record(id: id)?.record.payload == .text(text)
    }
    return .injected
  }
}
