import RillPlatform
import Foundation
import RillCore
import Testing
@testable import RillProviders

struct CleanupBudgetProviderTests {
  enum Scenario: CaseIterable, Sendable {
    case canonical, contextual, customRewrite, answer, voiceAssistantRewrite, voiceAssistantAnswer, canonicalWithCustomStep

    func usesShortBudget(deepSeek: Bool) -> Bool {
      switch self {
      case .answer, .voiceAssistantAnswer: false
      default: true
      }
    }
  }

  @Test(arguments: Scenario.allCases, ["gpt-5.6-luna", LLMTextProcessing.deepSeekModel])
  func transportBudgetFollowsWorkflowWhileDeepSeekParametersStayIndependent(scenario: Scenario, model: String) async throws {
    let settings = settings(model: model)
    let fixture = try fixture(scenario)
    let client = EchoBudgetClient()
    let transformer = OpenAITextRewriteTransformer(settingsProvider: { _ in settings }, clientFactory: { client })
    #expect(try await transformer.transform(text: "预算五百元", step: fixture.step, context: fixture.context) == "预算五百元")
    let request = try #require(await client.requests.first)
    let deepSeek = model == LLMTextProcessing.deepSeekModel
    #expect(request.timeoutInterval == (scenario.usesShortBudget(deepSeek: deepSeek) ? 5 : 60))
    let deepSeekRewrite = deepSeek && fixture.step.kind == .llmRewrite && fixture.step.reasoning == .some(.none)
    #expect(request.reasoning == fixture.step.reasoning)
    #expect(request.temperature == (deepSeekRewrite ? 0.1 : nil))
    #expect(request.maxOutputTokens == (fixture.step.kind == .llmRewrite ? 4_096 : 16_384))
    await transformer.shutdown()
  }

  @Test(arguments: Scenario.allCases, ["gpt-5.6-luna", LLMTextProcessing.deepSeekModel])
  func localDeadlineUsesTheSameEligibility(scenario: Scenario, model: String) async throws {
    let settings = settings(model: model)
    let fixture = try fixture(scenario)
    let client = EchoBudgetClient()
    let transformer = OpenAITextRewriteTransformer(settingsProvider: { _ in settings }, clientFactory: { client }, rewriteTimeout: .zero)
    if scenario.usesShortBudget(deepSeek: model == LLMTextProcessing.deepSeekModel) {
      await #expect(throws: OpenAITextRewriteError.timedOut) {
        _ = try await transformer.transform(text: "预算五百元", step: fixture.step, context: fixture.context)
      }
      #expect(await client.requests.isEmpty)
    } else {
      #expect(try await transformer.transform(text: "预算五百元", step: fixture.step, context: fixture.context) == "预算五百元")
      #expect(await client.requests.first?.timeoutInterval == 60)
    }
    await transformer.shutdown()
  }

  @Test(arguments: [false, true])
  func deepSeekLimitChecksTheActualCorrectionTranscript(upstreamIsLong: Bool) async throws {
    let settings = settings(model: LLMTextProcessing.deepSeekModel)
    var fixture = try fixture(.contextual)
    let long = String(repeating: "字", count: 4_001)
    let input = upstreamIsLong ? "预算五百元" : long
    fixture.context.correctionRequest = .init(transcript: input)
    let client = EchoBudgetClient()
    let transformer = OpenAITextRewriteTransformer(settingsProvider: { _ in settings }, clientFactory: { client })
    if upstreamIsLong {
      #expect(try await transformer.transform(text: long, step: fixture.step, context: fixture.context) == input)
      #expect(await client.requests.map(\.input) == [input])
    } else {
      await #expect(throws: OpenAITextRewriteError.incomplete) {
        _ = try await transformer.transform(text: "预算五百元", step: fixture.step, context: fixture.context)
      }
      #expect(await client.requests.isEmpty)
    }
    await transformer.shutdown()
  }

  @Test(arguments: [Scenario.canonical, .contextual, .customRewrite], ReasoningLevel.allCases)
  func explicitRolesPreserveCleanupBudgets(scenario: Scenario, role: ReasoningLevel) async throws {
    let settings = settings(model: LLMTextProcessing.deepSeekModel)
    var fixture = try fixture(scenario)
    fixture.step.reasoning = role
    let client = EchoBudgetClient()
    let transformer = OpenAITextRewriteTransformer(settingsProvider: { _ in settings }, clientFactory: { client })
    _ = try await transformer.transform(text: "预算五百元", step: fixture.step, context: fixture.context)
    let request = try #require(await client.requests.first)
    #expect(request.reasoning == role)
    #expect(request.maxOutputTokens == 4_096)
    #expect(request.timeoutInterval == 5)
    await transformer.shutdown()
  }

  @Test func compatibleCleanupDoesNotInheritDeepSeekInputLimit() async throws {
    let settings = settings(model: "gpt-5.6-luna")
    let fixture = try fixture(.canonical)
    let input = String(repeating: "字", count: 4_001)
    let client = EchoBudgetClient()
    let transformer = OpenAITextRewriteTransformer(settingsProvider: { _ in settings }, clientFactory: { client })
    #expect(try await transformer.transform(text: input, step: fixture.step, context: fixture.context) == input)
    #expect(await client.requests.map(\.input) == [input])
    await transformer.shutdown()
  }

  @Test func cancelledLateResponsesRetainOwnerSlotsAndCannotCompleteCleanup() async throws {
    let settings = settings(model: "gpt-5.6-luna")
    let fixture = try fixture(.canonical)
    let client = HeldBudgetClient()
    let diagnostics = BudgetDiagnosticProbe()
    let transformer = OpenAITextRewriteTransformer(
      settingsProvider: { _ in settings }, clientFactory: { client }, diagnosticReporter: { await diagnostics.record($0) })
    let attempts = (0..<2).map { _ in
      Task { try await transformer.transform(text: "预算五百元", step: fixture.step, context: fixture.context) }
    }
    await client.waitUntilStarted(count: 2)
    for attempt in attempts { attempt.cancel() }
    for attempt in attempts {
      await #expect(throws: CancellationError.self) { try await attempt.value }
    }
    // Cancellation returns before this dependency releases; its two slots remain owned.
    await #expect(throws: OpenAITextRewriteError.timedOut) {
      _ = try await transformer.transform(text: "预算五百元", step: fixture.step, context: fixture.context)
    }
    #expect(await client.requests.count == 2)
    let shutdown = Task { await transformer.shutdown() }
    await client.releaseAll()
    await shutdown.value
    #expect(await client.returnedCount == 2)
    #expect(await diagnostics.events.allSatisfy { $0.event != DiagnosticEventName.providerOpenaiRewriteCompleted.rawValue })
    await #expect(throws: OpenAITextRewriteError.timedOut) {
      _ = try await transformer.transform(text: "预算五百元", step: fixture.step, context: fixture.context)
    }
    #expect(await client.requests.count == 2)
  }

  private func settings(model: String) -> OpenAISettings {
    .init(apiKey: "synthetic-test-key", baseURL: model.hasPrefix("deepseek") ? LLMTextProcessing.deepSeekBaseURL : OpenAISettings.defaultBaseURL, model: model)
  }

  private func fixture(_ scenario: Scenario) throws -> (step: PostProcessStep, context: TransformContext) {
    var workflow = try #require(try BuiltinWorkflowCatalog().manifest().workflows.first { $0.preservesTranscriptContent })
    var step = PostProcessStep(kind: .llmRewrite, prompt: LLMTextProcessing.cleanupPrompt, reasoning: .some(.none))
    if scenario == .customRewrite || scenario == .contextual {
      step.prompt = "Rewrite in a formal style."
      workflow = .init(
        name: "Custom rewrite",
        plan: WorkflowPlan(
          setup: WorkflowSetupPhase(speechRoute: WorkflowSpeechRoute(recognizerID: "fixture")),
          process: WorkflowProcessPhase(
            steps: [
              WorkflowProcessStep(kind: .recognizeSpeech), WorkflowProcessStep(kind: .resolveUncertainty, uncertaintyPolicy: .init()),
              WorkflowProcessStep(kind: .applyVocabulary),
            ] + ([step]).map(WorkflowProcessStep.init)), output: WorkflowOutputPhase(actions: [], deliveryPolicy: .init(strategy: .immediate))),
        ui: .init(symbolName: "waveform", accentColorName: "blue"))
    }
    if scenario == .canonicalWithCustomStep { step.prompt = "Rewrite in a formal style." }
    if scenario == .answer || scenario == .voiceAssistantAnswer { step.kind = .llmAnswer }
    if scenario == .voiceAssistantRewrite || scenario == .voiceAssistantAnswer {

    }
    var context = TransformContext(
      runID: UUID(), workflow: workflow, contextSnapshot: .empty,
      recognitionResult: .init(rawText: "预算五百元", bestText: "预算五百元"))
    if scenario == .contextual { context.correctionRequest = .init(transcript: "预算五百元") }
    return (step, context)
  }
}

private actor EchoBudgetClient: OpenAIResponsesServing {
  private(set) var requests: [OpenAIResponsesRequest] = []
  func createResponse(request: OpenAIResponsesRequest, apiKey: String) async throws -> OpenAIResponsesResult {
    requests.append(request)
    return .init(status: .completed, outputText: request.input, containsRefusal: false, httpStatusCode: 200)
  }
}

private actor HeldBudgetClient: OpenAIResponsesServing {
  private(set) var requests: [OpenAIResponsesRequest] = []
  private(set) var returnedCount = 0
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private var startedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

  func createResponse(request: OpenAIResponsesRequest, apiKey: String) async throws -> OpenAIResponsesResult {
    requests.append(request)
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
      let ready = startedWaiters.filter { $0.0 <= continuations.count }
      startedWaiters.removeAll { $0.0 <= continuations.count }
      for (_, waiter) in ready { waiter.resume() }
    }
    returnedCount += 1
    return .init(status: .completed, outputText: request.input, containsRefusal: false, httpStatusCode: 200)
  }

  func waitUntilStarted(count: Int) async {
    if continuations.count >= count { return }
    await withCheckedContinuation { startedWaiters.append((count, $0)) }
  }

  func releaseAll() {
    let pending = continuations
    continuations.removeAll()
    for continuation in pending { continuation.resume() }
  }
}

private actor BudgetDiagnosticProbe {
  private(set) var events: [DiagnosticEvent] = []
  func record(_ event: DiagnosticEvent) { events.append(event) }
}
