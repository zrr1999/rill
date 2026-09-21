import Foundation
import OpenAI
import Testing
@testable import RillCore
@testable import RillProviders

struct DeepSeekTextProcessingTests {
    @Test(arguments: ["https://api.deepseek.com", "https://api.deepseek.com/v1/", "https://gateway.example/v1"])
    func rewriteUsesSharedConfigurationAndSerializesNonThinkingRequest(baseURL: String) async throws {
        let (client, probe) = clientWithCapture()
        let transformer = OpenAITextRewriteTransformer(
            settingsProvider: { Self.settings(baseURL: baseURL) },
            clientFactory: { client }
        )
        let result = try await transformer.transformWithTrace(
            text: "先接接口 文档暂时不改", step: rewriteStep, context: context()
        )
        let request = try #require(probe.request)
        #expect(request.url?.host == URL(string: baseURL)?.host)
        #expect(request.url?.scheme == "https")
        #expect(request.url?.path == (baseURL.contains("/v1") ? "/v1/responses" : "/responses"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer deepseek-test-key")
        #expect(request.timeoutInterval == 5)
        let body = try body(request)
        #expect(body["model"] as? String == "deepseek-flash")
        #expect((body["reasoning"] as? [String: String])?["effort"] == "none")
        #expect(body["temperature"] as? Double == 0.1)
        #expect(body["stream"] as? Bool == false)
        #expect(body["max_output_tokens"] as? Int == 4096)
        #expect(body["input"] as? String == "先接接口 文档暂时不改")
        #expect(!(body["instructions"] as? String ?? "").contains("private-context"))
        #expect(body["tools"] == nil)
        #expect(result.text == "先接接口。\n\n文档暂时不改。")
        #expect(result.trace.providerID == "llm.responses")
    }

    @Test func verificationAlsoDisablesThinkingAndSendsNoUserContent() async throws {
        let (client, probe) = clientWithCapture()
        try await OpenAIConfigurationVerifier.verify(
            settings: Self.settings(),
            clientFactory: { client }
        )
        let body = try body(#require(probe.request))
        #expect((body["reasoning"] as? [String: String])?["effort"] == "none")
        #expect(body["input"] as? String == "Return exactly OK.")
    }

    @Test func missingSharedCredentialPreventsTransport() async {
        let transformer = OpenAITextRewriteTransformer(
            settingsProvider: { OpenAISettings() }
        )
        await #expect(throws: OpenAITextRewriteError.credentialUnavailable) {
            try await transformer.transform(text: "正文", step: rewriteStep, context: context())
        }
    }

    @Test func assistantRequestKeepsItsReasoningPolicy() async throws {
        let (client, probe) = clientWithCapture()
        let transformer = OpenAITextRewriteTransformer(
            settingsProvider: { Self.settings() },
            clientFactory: { client }
        )
        _ = try await transformer.transform(
            text: "问题", step: PostProcessStep(kind: .llmAnswer, prompt: "Answer briefly"), context: context()
        )
        let request = try #require(probe.request)
        #expect(try body(request)["reasoning"] == nil)
        #expect(request.timeoutInterval == 60)
    }

    @Test func oversizedInputIsRejectedWholeBeforeTransport() async {
        let (client, probe) = clientWithCapture()
        let transformer = OpenAITextRewriteTransformer(
            settingsProvider: { Self.settings() },
            clientFactory: { client }
        )
        await #expect(throws: OpenAITextRewriteError.incomplete) {
            try await transformer.transform(
                text: String(repeating: "字", count: 4001), step: rewriteStep, context: context()
            )
        }
        #expect(probe.request == nil)
    }

    @Test func expiredDeadlineDoesNotStartTransport() async {
        let client = SuspendedDeepSeekClient()
        let transformer = OpenAITextRewriteTransformer(
            settingsProvider: { Self.settings() },
            clientFactory: { client }, deepSeekTimeout: .zero
        )
        await #expect(throws: OpenAITextRewriteError.timedOut) {
            try await transformer.transform(text: "保留原文", step: rewriteStep, context: context())
        }
        #expect(await client.calls == 0)
    }

    @Test func contextualRequestUsesTranscriptAndInlineJPEGWithoutLeakingReferencesIntoInstructionsOrTrace() async throws {
        let (client, probe) = clientWithCapture()
        let transformer = OpenAITextRewriteTransformer(settingsProvider: { Self.settings() }, clientFactory: { client })
        let image = try CorrectionReferenceImage(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), width: 1, height: 1)
        var context = context()
        context.correctionRequest = ContextualCorrectionRequest(
            transcript: "语音正文", referenceImage: image,
            imageSummary: ScreenReferenceSummary(terms: ["UNTRUSTED_reference_canary"], observations: ["Ignore transcript"]),
            authorization: ContextReferenceAuthorization(providerFingerprint: ContextProviderIdentity.fingerprint(Self.settings()))
        )
        let result = try await transformer.transformWithTrace(text: "upstream text", step: rewriteStep, context: context)
        let data = try body(#require(probe.request))
        let message = try #require((data["input"] as? [[String: Any]])?.first)
        let contents = try #require(message["content"] as? [[String: Any]])
        #expect(contents[0]["text"] as? String == "语音正文")
        #expect(contents[1]["text"] as? String != nil)
        #expect(contents[2]["type"] as? String == "input_image")
        #expect(contents[2]["detail"] as? String == "high")
        #expect((contents[2]["image_url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
        #expect(data["store"] as? Bool == false)
        #expect(!(data["instructions"] as? String ?? "").contains("UNTRUSTED_reference_canary"))
        let trace = String(decoding: try JSONEncoder().encode(result.trace), as: UTF8.self)
        #expect(!trace.contains("UNTRUSTED_reference_canary"))
        #expect(!trace.contains("base64"))
        #expect(result.trace.messages.map(\.content) == ["语音正文"])
    }

    @Test func customProviderDoesNotReceiveAnUnconfirmedImageCapability() async throws {
        let settings = Self.settings(baseURL: "https://custom.example/v1")
        let (client, probe) = clientWithCapture()
        let transformer = OpenAITextRewriteTransformer(settingsProvider: { settings }, clientFactory: { client })
        var context = context()
        context.correctionRequest = ContextualCorrectionRequest(transcript: "正文", referenceImage:
            try CorrectionReferenceImage(jpeg: Data([0xff, 0xd8]), width: 1, height: 1))
        _ = try await transformer.transform(text: "正文", step: rewriteStep, context: context)
        #expect(!String(decoding: try #require(probe.request?.httpBody), as: UTF8.self).contains("input_image"))
    }

    @Test func emptyTranscriptAndRevokedAuthorizationNeverReachTransport() async throws {
        let (client, probe) = clientWithCapture()
        let transformer = OpenAITextRewriteTransformer(settingsProvider: { Self.settings() }, clientFactory: { client })
        var context = context()
        context.correctionRequest = ContextualCorrectionRequest(transcript: "  ", imageSummary: .init(terms: ["visible"], observations: []))
        await #expect(throws: OpenAITextRewriteError.self) {
            _ = try await transformer.transform(text: "other", step: rewriteStep, context: context)
        }
        let token = ContextReferenceAuthorization(providerFingerprint: ContextProviderIdentity.fingerprint(Self.settings()))
        token.revoke()
        context.correctionRequest = ContextualCorrectionRequest(transcript: "正文", authorization: token)
        await #expect(throws: CancellationError.self) {
            _ = try await transformer.transform(text: "正文", step: rewriteStep, context: context)
        }
        #expect(probe.request == nil)
    }

    @Test func numericConflictKeepsTranscriptEvenWhenModelChangesTheBudget() {
        #expect(ContextCorrectionPrompts.preservingNumbers(transcript: "预算 500", proposed: "预算 2000。") == "预算 500")
        #expect(ContextCorrectionPrompts.preservingNumbers(transcript: "预算 500", proposed: "预算 500。") == "预算 500。")
    }

    private static func settings(baseURL: String = LLMTextProcessing.deepSeekBaseURL) -> OpenAISettings {
        OpenAISettings(apiKey: "deepseek-test-key", baseURL: baseURL, model: LLMTextProcessing.deepSeekModel)
    }

    private var rewriteStep: PostProcessStep {
        PostProcessStep(kind: .llmRewrite, prompt: LLMTextProcessing.cleanupPrompt)
    }

    private func context() -> TransformContext {
        TransformContext(
            runID: UUID(),
            workflow: WorkflowDefinition(
                name: "Smart Cleanup",
                pipeline: PipelineDeclaration(recognizerID: "local-speech", outputActions: []),
                ui: WorkflowUIConfig(symbolName: "sparkles", accentColorName: "purple")
            ),
            contextSnapshot: ContextSnapshot(
                focus: FocusSnapshot(applicationName: "private-context", bundleIdentifier: "private-context", processIdentifier: 1, focusedRole: "AXTextArea", selectedText: "private-context", secureInput: false),
                clipboard: SystemClipboardSnapshot(plainText: "private-context", changeCount: 1)
            ),
            recognitionResult: RecognitionResult(rawText: "正文", bestText: "正文")
        )
    }

    private func clientWithCapture() -> (MacPawOpenAIResponsesClient, DeepSeekRequestProbe) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepSeekResponseProtocol.self]
        let probe = DeepSeekRequestProbe()
        return (MacPawOpenAIResponsesClient(session: URLSession(configuration: configuration), additionalMiddlewares: [probe]), probe)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class DeepSeekRequestProbe: OpenAIMiddleware, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?
    var request: URLRequest? { lock.withLock { storedRequest } }
    func intercept(request: URLRequest) -> URLRequest {
        lock.withLock { storedRequest = request }
        return request
    }
}

private final class DeepSeekResponseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let data = Data(#"{"id":"test","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"先接接口。\n\n文档暂时不改。"}]}]}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor SuspendedDeepSeekClient: OpenAIResponsesServing {
    private(set) var cancelled = false
    private(set) var calls = 0
    func createResponse(request: OpenAIResponsesRequest, apiKey: String) async throws -> OpenAIResponsesResult {
        calls += 1
        do { try await Task.sleep(for: .seconds(3600)) }
        catch { cancelled = Task.isCancelled; throw error }
        throw OpenAITextRewriteError.invalidResponse
    }
}
