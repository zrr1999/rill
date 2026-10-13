import Foundation
import Testing
import RillCore
@testable import RillProviders

struct CleanupProtectionProviderTests {
  @Test(arguments: [false, true], ["compatible-model", LLMTextProcessing.deepSeekModel])
  func ordinaryAndContextualCleanupRejectChangedQuantities(contextual: Bool, model: String) async throws {
    let client = CleanupProtectionClient(output: "预算两千元。")
    let settings = OpenAISettings(apiKey: "synthetic-test-key", baseURL: "https://gateway.example/v1", model: model)
    let transformer = OpenAITextRewriteTransformer(settingsProvider: { settings }, clientFactory: { client })
    let workflow = try cleanupWorkflow()
    var context = context(workflow)
    if contextual {
      context.correctionRequest = .init(
        transcript: "预算五百元", imageSummary: .init(terms: ["两千元"], observations: []),
        authorization: .init(providerFingerprint: ContextProviderIdentity.fingerprint(settings)))
    }
    await #expect(throws: OpenAITextRewriteError.invalidResponse) {
      _ = try await transformer.transform(text: contextual ? "unrelated upstream text" : "预算五百元", step: cleanupStep, context: context)
    }
    #expect(await client.inputs == ["预算五百元"])
  }

  @Test(arguments: [false, true])
  func cleanupCanAddSentenceBoundariesAndListMarkers(contextual: Bool) async throws {
    let output = "1. 先接接口。\n2. 文档暂时不改。"
    let client = CleanupProtectionClient(output: output)
    let transformer = OpenAITextRewriteTransformer(settingsProvider: { .init(apiKey: "test") }, clientFactory: { client })
    var context = context(try cleanupWorkflow())
    if contextual { context.correctionRequest = .init(transcript: "先接接口 文档暂时不改") }
    let result = try await transformer.transformWithTrace(text: "先接接口 文档暂时不改", step: cleanupStep, context: context)
    #expect(result.text == output)
    #expect(result.trace.responseText == output)
  }

  @Test(arguments: [PostProcessStepKind.llmRewrite, .llmAnswer])
  func explicitCustomInstructionsAreNotContentFiltered(kind: PostProcessStepKind) async throws {
    var workflow = try cleanupWorkflow()
    let instruction = "Translate the words and numbers into English."
    let step = PostProcessStep(kind: kind, prompt: instruction)
    workflow.plan.process.steps = [.init(kind: .init(postProcessKind: kind), prompt: instruction)]
    let client = CleanupProtectionClient(output: "Five hundred yuan.")
    let transformer = OpenAITextRewriteTransformer(settingsProvider: { .init(apiKey: "test") }, clientFactory: { client })
    #expect(try await transformer.transform(text: "五百元", step: step, context: context(workflow)) == "Five hundred yuan.")
  }

  @Test func voiceAssistantRewriteKeepsAnswerSemantics() async throws {
    var workflow = try cleanupWorkflow()
    workflow.metadata[WorkflowMetadataKey.speechMode] = SpeechWorkflowMode.voiceAssistant.rawValue
    let client = CleanupProtectionClient(output: "预算2000元。")
    let transformer = OpenAITextRewriteTransformer(settingsProvider: { .init(apiKey: "test") }, clientFactory: { client })
    #expect(try await transformer.transform(text: "预算五百元", step: cleanupStep, context: context(workflow)) == "预算2000元。")
  }

  private var cleanupStep: PostProcessStep { .init(kind: .llmRewrite, prompt: LLMTextProcessing.cleanupPrompt) }

  private func cleanupWorkflow() throws -> WorkflowDefinition {
    try #require(BuiltinWorkflowCatalog().manifest().workflows.first { $0.isCanonicalSmartCleanup })
  }

  private func context(_ workflow: WorkflowDefinition) -> TransformContext {
    .init(runID: UUID(), workflow: workflow, contextSnapshot: .empty, recognitionResult: .init(rawText: "预算五百元", bestText: "预算五百元"))
  }
}

private actor CleanupProtectionClient: OpenAIResponsesServing {
  let output: String
  private(set) var inputs: [String] = []
  init(output: String) { self.output = output }
  func createResponse(request: OpenAIResponsesRequest, apiKey: String) async throws -> OpenAIResponsesResult {
    inputs.append(request.input)
    return .init(status: .completed, outputText: output, containsRefusal: false, httpStatusCode: 200)
  }
}
