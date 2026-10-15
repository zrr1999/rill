import Foundation
import RillCore
import RillDomainTestSupport
import RillKnowledge
import Testing
@testable import RillProviders
@testable import RillWorkflows

struct CleanupProtectionFallbackTests {
  @Test(arguments: [false, true], CleanupFailureMode.allCases)
  func failedCleanupIsSkippedAndDeliversOriginalOnce(contextual: Bool, failureMode: CleanupFailureMode) async throws {
    let settings = OpenAISettings(apiKey: "synthetic-test-key")
    let client = RejectedCleanupClient()
    let transformer = OpenAITextRewriteTransformer(
      settingsProvider: { _, _ in settings }, clientFactory: { client }, rewriteTimeout: failureMode == .timeout ? .zero : .seconds(5))
    let bus = EventBus()
    let diagnostics = DiagnosticsRecorder(eventBus: bus)
    let receipts = InMemoryWorkflowRunReceiptRepository()
    let output = CleanupFallbackOutput()
    var workflow = try #require(BuiltinWorkflowCatalog().manifest().workflows.first { $0.isCanonicalSmartCleanup })
    workflow.plan.output.actions = [.init(id: output.id)]
    let coordinator = makeTestSessionCoordinator(
      recognizerRegistry: .init(recognizers: [CleanupFallbackRecognizer()]),
      transformerRegistry: .init(transformers: [WhitespaceNormalizerTransformer(), transformer]),
      actionRegistry: .init(actions: [output]), candidateResolver: CandidateResolver(eventBus: bus),
      eventBus: bus, diagnostics: diagnostics, runReceiptRecorder: WorkflowRunReceiptRecorder(repository: receipts))
    let runID = UUID()
    let preparation =
      contextual
      ? RunContextPreparation.skipped(
        authorization: .init(providerFingerprint: ContextProviderIdentity.fingerprint(settings)),
        audioLifetime: AudioCaptureLifetime(runID: runID), screenEnabled: false, memoryEnabled: false,
        status: .disabled, vocabularyReference: try CorrectionVocabularyReference(terms: ["两千元"]))
      : nil
    let audio = try CapturedAudio(
      durationSeconds: 0.3, format: .init(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
      inlineData: Data([0, 0]))
    let outcome = await coordinator.runReportingOutcome(
      workflow: workflow, runID: runID, capturedAudio: audio, contextSnapshot: .empty, contextPreparation: preparation)
    guard case .completed(let summary) = outcome else {
      Issue.record("Expected the recognized text to be delivered: \(outcome)")
      return
    }
    #expect(summary.finalText == "预算五百元")
    #expect(await output.texts == ["预算五百元"])
    #expect(await client.inputs == (failureMode == .timeout ? [] : ["预算五百元"]))
    let textStep = try #require(summary.correctionSource?.processingSteps?.last)
    #expect(textStep.kind == .llmRewrite)
    #expect(textStep.result == .skipped)
    #expect(textStep.outputText == "预算五百元")
    #expect(summary.correctionSource?.languageModelTraces?.isEmpty != false)
    #expect(summary.correctionSource?.references?.vocabulary?.status == (contextual ? .deliveryUnconfirmed : nil))
    let receipt = try #require(try await receipts.receipts(matching: .init(runID: runID)).first)
    let rewriteReceipt = try #require(receipt.stepDetails.last)
    #expect(rewriteReceipt.kind == .llmRewrite)
    #expect(rewriteReceipt.result == .skipped)
    #expect(receipt.actionDetails.count == 1)
    let events = await diagnostics.snapshot()
    #expect(
      events.contains {
        $0.event == "session.transform.fallback" && $0.metadata["stepKind"] == "llmRewrite" && $0.metadata["outcome"] == "preserved"
      })
    await transformer.shutdown()
  }
}

enum CleanupFailureMode: CaseIterable, Sendable {
  case invalidResponse, timeout
}

private struct CleanupFallbackRecognizer: SpeechRecognizer {
  let id = "local-speech"
  func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
    .init(rawText: "预算五百元", bestText: "预算五百元")
  }
}

private actor RejectedCleanupClient: OpenAIResponsesServing {
  private(set) var inputs: [String] = []
  func createResponse(request: OpenAIResponsesRequest, apiKey: String) async throws -> OpenAIResponsesResult {
    inputs.append(request.input)
    return .init(status: .completed, outputText: "预算两千元。", containsRefusal: false, httpStatusCode: 200)
  }
}

private actor CleanupFallbackOutput: OutputAction {
  nonisolated let id = "cleanup-test.output"
  private(set) var texts: [String] = []
  func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
    texts.append(try record.requireText(for: id))
    return .copiedToClipboard
  }
}
