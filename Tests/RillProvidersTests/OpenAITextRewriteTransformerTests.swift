import Foundation
import OpenAI
import XCTest

@testable import RillCore
@testable import RillProviders

final class OpenAITextRewriteTransformerTests: XCTestCase {
  func testCredentialRevokedDuringRequestRejectsReturnedText() async throws {
    let source = LanguageModelSettingsSource()
    source.update(OpenAISettings(apiKey: "test-key"))
    let client = OpenAIResponsesClientStub(
      result: .success(.init(status: .completed, outputText: "must not deliver", containsRefusal: false, httpStatusCode: 200)),
      suspendResponse: true
    )
    let transformer = OpenAITextRewriteTransformer(settingsSource: source, clientFactory: { client })
    var context = makeTransformContext()
    context.workflow.plan.process.steps.append(.init(kind: .llmRewrite, prompt: "Edit", reasoning: .some(.none)))
    context.modelSnapshot = try source.snapshot(for: context.workflow)
    let capturedContext = context
    let task = Task {
      try await transformer.transform(
        text: "input", step: PostProcessStep(kind: .llmRewrite, prompt: "Edit", reasoning: .some(.none)), context: capturedContext)
    }
    await client.waitUntilInvoked()
    source.update(nil)
    await client.resumeResponse()
    do {
      _ = try await task.value
      XCTFail("Revoked credentials must reject a response already in flight")
    } catch { XCTAssertEqual(error as? OpenAITextRewriteError, .credentialUnavailable) }
  }

  func testProductionResolverUsesFrozenServiceAndHonorsCredentialRevocation() async throws {
    let source = LanguageModelSettingsSource()
    let original = OpenAISettings(apiKey: "smart-key", baseURL: "https://api.deepseek.com", model: "deepseek-flash")
    source.update(original)
    let client = OpenAIResponsesClientStub(
      result: .success(
        .init(
          status: .completed, outputText: "result", containsRefusal: false, httpStatusCode: 200)))
    let transformer = OpenAITextRewriteTransformer(settingsSource: source, clientFactory: { client })
    var context = makeTransformContext()
    context.workflow.plan.process.steps.append(.init(kind: .llmRewrite, prompt: "Edit", reasoning: .high))
    context.modelSnapshot = try source.snapshot(for: context.workflow)
    source.update(.init(apiKey: "smart-key", model: "next-run-model"))
    let step = PostProcessStep(kind: .llmRewrite, prompt: "Edit", reasoning: .high)
    _ = try await transformer.transform(text: "input", step: step, context: context)
    let invocation = await client.lastInvocation()
    XCTAssertEqual(invocation?.request.model, "deepseek-flash")
    XCTAssertEqual(invocation?.request.baseURL, "https://api.deepseek.com")
    XCTAssertEqual(invocation?.request.reasoning, .high)
    XCTAssertNil(invocation?.request.temperature)
    source.update(nil)
    do {
      _ = try await transformer.transform(text: "input", step: step, context: context)
      XCTFail("Revoked credentials must block the next request")
    } catch { XCTAssertEqual(error as? OpenAITextRewriteError, .credentialUnavailable) }
  }

  func testOnlyRecoverableProviderFailuresPermitSpeechTextFallback() {
    for error in [
      OpenAITextRewriteError.rateLimited,
      .timedOut,
      .networkFailed,
      .incomplete,
      .invalidResponse,
    ] {
      XCTAssertTrue(error.allowsSpeechTextFallback)
    }

    for error in [
      OpenAITextRewriteError.credentialUnavailable,
      .configurationInvalid,
      .authenticationFailed,
      .refused,
    ] {
      XCTAssertFalse(error.allowsSpeechTextFallback)
    }
  }

  func testTransformerBuildsContentMinimalRequestAndReturnsCompletedText() async throws {
    let client = OpenAIResponsesClientStub(
      result: .success(
        .init(
          status: .completed,
          outputText: "润色后的正文",
          containsRefusal: false,
          httpStatusCode: 200
        )
      )
    )
    let transformer = OpenAITextRewriteTransformer(
      settingsProvider: { _ in
        OpenAISettings(
          apiKey: " test-key ",
          baseURL: "https://api.openai.com/v1",
          model: "gpt-5.6-luna"
        )
      },
      clientFactory: { client }
    )
    let contextCanary = "private-selected-text-canary"

    let output = try await transformer.transform(
      text: "呃 这是 原始正文",
      step: PostProcessStep(kind: .llmRewrite, prompt: "Make this concise.", reasoning: .some(.none)),
      context: makeTransformContext(selectedText: contextCanary)
    )

    XCTAssertEqual(output, "润色后的正文")
    let capturedInvocation = await client.lastInvocation()
    let invocation = try XCTUnwrap(capturedInvocation)
    XCTAssertEqual(invocation.apiKey, "test-key")
    XCTAssertEqual(invocation.request.input, "呃 这是 原始正文")
    XCTAssertTrue(invocation.request.instructions.contains("Make this concise."))
    XCTAssertTrue(invocation.request.instructions.contains("Preserve its meaning"))
    XCTAssertFalse(invocation.request.instructions.contains(contextCanary))
    XCTAssertEqual(invocation.request.baseURL, "https://api.openai.com/v1")
    XCTAssertEqual(invocation.request.model, "gpt-5.6-luna")
    XCTAssertFalse(invocation.request.store)
    XCTAssertFalse(invocation.request.stream)
    XCTAssertEqual(
      invocation.request.maxOutputTokens,
      OpenAITextRewriteTransformer.maximumOutputTokens
    )
  }

  func testAnswerStepUsesAssistantContractInsteadOfRewriteContract() async throws {
    let client = OpenAIResponsesClientStub(
      result: .success(
        .init(
          status: .completed,
          outputText: "直接回答",
          containsRefusal: false,
          httpStatusCode: 200
        )
      )
    )
    let transformer = OpenAITextRewriteTransformer(
      settingsProvider: { _ in OpenAISettings(apiKey: "test-key") },
      clientFactory: { client }
    )

    _ = try await transformer.transform(
      text: "为什么天空是蓝色？",
      step: PostProcessStep(kind: .llmAnswer, prompt: "Answer briefly.", reasoning: .some(.high)),
      context: makeTransformContext()
    )

    let capturedInvocation = await client.lastInvocation()
    let invocation = try XCTUnwrap(capturedInvocation)
    XCTAssertTrue(invocation.request.instructions.contains("Answer the supplied user request"))
    XCTAssertTrue(invocation.request.instructions.contains("Answer briefly."))
    XCTAssertFalse(invocation.request.instructions.contains("Transform only the supplied transcript"))
  }

  func testTraceContainsExactCredentialFreeRequestAndResponse() async throws {
    let client = OpenAIResponsesClientStub(
      result: .success(
        .init(
          status: .completed,
          outputText: "actual answer",
          containsRefusal: false,
          httpStatusCode: 200,
          tokenUsage: .init(inputTokens: 120, outputTokens: 24, totalTokens: 144)
        )
      )
    )
    let transformer = OpenAITextRewriteTransformer(
      settingsProvider: { _ in
        OpenAISettings(
          apiKey: "secret-key-canary",
          baseURL: "https://api.openai.com/v1",
          model: "gpt-5.6-luna"
        )
      },
      clientFactory: { client }
    )

    let result = try await transformer.transformWithTrace(
      text: "actual question",
      step: PostProcessStep(kind: .llmAnswer, prompt: "Answer in one sentence.", reasoning: .some(.high)),
      context: makeTransformContext(selectedText: "unrelated-context-canary")
    )

    XCTAssertEqual(result.text, "actual answer")
    XCTAssertEqual(result.trace.providerID, "llm.responses")
    XCTAssertEqual(result.trace.modelID, "gpt-5.6-luna")
    XCTAssertEqual(result.trace.workflowPrompt, "Answer in one sentence.")
    XCTAssertTrue(result.trace.systemPrompt.contains("Answer the supplied user request"))
    XCTAssertTrue(result.trace.systemPrompt.contains("Answer in one sentence."))
    XCTAssertEqual(
      result.trace.messages,
      [.init(role: .user, content: "actual question")]
    )
    XCTAssertEqual(result.trace.responseText, "actual answer")
    XCTAssertEqual(result.trace.tokenUsage, .init(inputTokens: 120, outputTokens: 24, totalTokens: 144))

    let encodedTrace = String(decoding: try JSONEncoder().encode(result.trace), as: UTF8.self)
    XCTAssertFalse(encodedTrace.contains("secret-key-canary"))
    XCTAssertFalse(encodedTrace.contains("private-gateway"))
    XCTAssertFalse(encodedTrace.contains("unrelated-context-canary"))
  }

  func testRewriteTaskUsesRewriteContract() async throws {
    let client = OpenAIResponsesClientStub(
      result: .success(
        .init(status: .completed, outputText: "回答", containsRefusal: false, httpStatusCode: 200)
      )
    )
    let transformer = OpenAITextRewriteTransformer(
      settingsProvider: { _ in OpenAISettings(apiKey: "test-key") },
      clientFactory: { client }
    )

    _ = try await transformer.transform(
      text: "问题",
      step: PostProcessStep(kind: .llmRewrite, prompt: "Answer.", reasoning: .some(.none)),
      context: makeTransformContext()
    )

    let capturedInvocation = await client.lastInvocation()
    let invocation = try XCTUnwrap(capturedInvocation)
    XCTAssertFalse(invocation.request.instructions.contains("Answer the supplied user request"))
    XCTAssertTrue(invocation.request.instructions.contains("Transform only the supplied transcript"))
  }

  func testTransformerRejectsMissingCredentialAndInvalidConfigurationBeforeTransport() async {
    for (settings, expectedError) in [
      (OpenAISettings(), OpenAITextRewriteError.credentialUnavailable),
      (
        OpenAISettings(apiKey: "key", baseURL: "http://example.com/v1", model: "model"),
        OpenAITextRewriteError.configurationInvalid
      ),
      (
        OpenAISettings(apiKey: "key", baseURL: OpenAISettings.defaultBaseURL, model: "\n"),
        OpenAITextRewriteError.configurationInvalid
      ),
    ] {
      let client = OpenAIResponsesClientStub(result: .failure(expectedError))
      let transformer = OpenAITextRewriteTransformer(
        settingsProvider: { _ in settings },
        clientFactory: { client }
      )
      await assertRewriteError(expectedError) {
        _ = try await transformer.transform(
          text: "text",
          step: PostProcessStep(kind: .llmRewrite, prompt: "Polish.", reasoning: .some(.none)),
          context: makeTransformContext()
        )
      }
      let capturedInvocation = await client.lastInvocation()
      XCTAssertNil(capturedInvocation)
    }
  }

  func testTransformerRejectsRefusalIncompleteAndEmptyOutput() async {
    let cases: [(OpenAIResponsesResult, OpenAITextRewriteError)] = [
      (
        .init(status: .completed, outputText: nil, containsRefusal: true, httpStatusCode: 200),
        .refused
      ),
      (
        .init(
          status: .incomplete,
          outputText: "partial",
          containsRefusal: false,
          httpStatusCode: 200
        ),
        .incomplete
      ),
      (
        .init(status: .completed, outputText: " \n ", containsRefusal: false, httpStatusCode: 200),
        .invalidResponse
      ),
    ]

    for (response, expectedError) in cases {
      let client = OpenAIResponsesClientStub(result: .success(response))
      let transformer = OpenAITextRewriteTransformer(
        settingsProvider: { _ in OpenAISettings(apiKey: "test-key") },
        clientFactory: { client }
      )
      await assertRewriteError(expectedError) {
        _ = try await transformer.transform(
          text: "text",
          step: PostProcessStep(kind: .llmRewrite, prompt: "Polish.", reasoning: .some(.none)),
          context: makeTransformContext()
        )
      }
    }
  }

  func testTransformerPropagatesTaskCancellation() async {
    let client = OpenAIResponsesClientStub(
      result: .success(
        .init(
          status: .completed,
          outputText: "late output",
          containsRefusal: false,
          httpStatusCode: 200
        )
      ),
      delay: .seconds(30)
    )
    let transformer = OpenAITextRewriteTransformer(
      settingsProvider: { _ in OpenAISettings(apiKey: "test-key") },
      clientFactory: { client }
    )
    let task = Task {
      try await transformer.transform(
        text: "text",
        step: PostProcessStep(kind: .llmRewrite, prompt: "Polish.", reasoning: .some(.none)),
        context: makeTransformContext()
      )
    }

    await client.waitUntilInvoked()
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }

  func testConfigurationVerificationUsesOnlyFixedNonUserContent() async throws {
    XCTAssertEqual(OpenAISettings.defaultModel, OpenAIModelOption.luna.rawValue)
    let client = OpenAIResponsesClientStub(
      result: .success(
        .init(status: .completed, outputText: "OK", containsRefusal: false, httpStatusCode: 200)
      )
    )

    try await OpenAIConfigurationVerifier.verify(
      settings: OpenAISettings(
        apiKey: "verification-key",
        baseURL: "https://api.openai.com/v1"
      ),
      clientFactory: { client }
    )

    let capturedInvocation = await client.lastInvocation()
    let invocation = try XCTUnwrap(capturedInvocation)
    XCTAssertEqual(invocation.request.input, "Return exactly OK.")
    XCTAssertEqual(
      invocation.request.instructions,
      "This is a provider configuration check. Return only OK."
    )
    XCTAssertEqual(invocation.request.baseURL, "https://api.openai.com/v1")
    XCTAssertEqual(invocation.request.model, "gpt-5.6-luna")
    XCTAssertNil(invocation.request.maxOutputTokens)
  }

  func testMacPawAdapterUsesVerifiedEndpointAndRequiredBodyFields() async throws {
    OpenAIRequestCaptureProtocol.reset(responseData: completedResponseData)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenAIRequestCaptureProtocol.self]
    let requestRecorder = OpenAIRequestRecorder()
    let client = MacPawOpenAIResponsesClient(
      session: URLSession(configuration: configuration),
      additionalMiddlewares: [requestRecorder]
    )

    let result = try await client.createResponse(
      request: OpenAIResponsesRequest(
        input: "transcript-canary",
        instructions: "instruction-canary",
        baseURL: OpenAISettings.defaultBaseURL,
        model: OpenAIModelOption.luna.rawValue,
        store: false,
        stream: false,
        maxOutputTokens: 4_096
      ),
      apiKey: "secret-token-canary"
    )

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.outputText, "polished")
    let request = try XCTUnwrap(requestRecorder.capturedRequest())
    XCTAssertEqual(request.url?.path, "/v1/responses")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token-canary")
    let body = try XCTUnwrap(request.httpBody)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["input"] as? String, "transcript-canary")
    XCTAssertEqual(json["instructions"] as? String, "instruction-canary")
    XCTAssertEqual(json["model"] as? String, OpenAIModelOption.luna.rawValue)
    XCTAssertEqual(json["store"] as? Bool, false)
    XCTAssertEqual(json["stream"] as? Bool, false)
    XCTAssertEqual(json["max_output_tokens"] as? Int, 4_096)
    XCTAssertEqual((json["reasoning"] as? [String: String])?["effort"], "none")
    XCTAssertNil(json["metadata"])
    XCTAssertNil(json["user"])
    XCTAssertNil(json["previous_response_id"])
  }

  func testMacPawAdapterRejectsUnverifiedEndpointBeforeTransport() async throws {
    let recorder = OpenAIRequestRecorder()
    let client = MacPawOpenAIResponsesClient(additionalMiddlewares: [recorder])
    do {
      _ = try await client.createResponse(
        request: .init(
          input: "private", instructions: "test", baseURL: "https://gateway.example/v1",
          model: OpenAIModelOption.luna.rawValue, store: false, stream: false, maxOutputTokens: nil), apiKey: "test-key")
      XCTFail("An unverified service must be rejected before transport.")
    } catch let error as LanguageModelConfigurationError {
      XCTAssertEqual(error, .unsupportedReasoning(.none))
    }
    XCTAssertNil(recorder.capturedRequest())
  }

  func testMacPawAdapterMapsEveryPortableReasoningLevel() async throws {
    for level in ReasoningLevel.allCases {
      OpenAIRequestCaptureProtocol.reset(responseData: completedResponseData)
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [OpenAIRequestCaptureProtocol.self]
      let recorder = OpenAIRequestRecorder()
      let client = MacPawOpenAIResponsesClient(session: URLSession(configuration: configuration), additionalMiddlewares: [recorder])
      _ = try await client.createResponse(
        request: .init(
          input: "test", instructions: "test", baseURL: OpenAISettings.defaultBaseURL,
          model: "gpt-5.6-luna", store: false, stream: false, maxOutputTokens: nil, reasoning: level), apiKey: "synthetic-key")
      let body = try XCTUnwrap(recorder.capturedRequest()?.httpBody)
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
      XCTAssertEqual((json["reasoning"] as? [String: String])?["effort"], level.rawValue)
    }
  }

  func testMacPawAdapterCollectsTypedOutputWhenConvenienceFieldIsAbsent() async throws {
    let decoded = try JSONDecoder().decode(ResponseObject.self, from: typedOutputResponseData)
    XCTAssertEqual(decoded.usage?.totalTokens, 144)
    OpenAIRequestCaptureProtocol.reset(responseData: typedOutputResponseData)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenAIRequestCaptureProtocol.self]
    let client = MacPawOpenAIResponsesClient(
      session: URLSession(configuration: configuration)
    )

    let result = try await client.createResponse(
      request: OpenAIResponsesRequest(
        input: "text",
        instructions: "instruction",
        baseURL: OpenAISettings.defaultBaseURL,
        model: OpenAISettings.defaultModel,
        store: false,
        stream: false,
        maxOutputTokens: 4_096
      ),
      apiKey: "test-key"
    )

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.outputText, "typed polished")
    XCTAssertEqual(result.tokenUsage, .init(inputTokens: 120, outputTokens: 24, totalTokens: 144))
    XCTAssertFalse(result.containsRefusal)
  }

  func testCompatibleResponseFallbackIgnoresUnknownItemsAndCollectsText() throws {
    let data = Data(
      """
      {
        "id": "resp-compatible",
        "object": "response",
        "status": "completed",
        "usage": {"input_tokens": 32, "output_tokens": 8, "total_tokens": 40},
        "output": [
          {
            "id": "reasoning-compatible",
            "type": "future_reasoning_item",
            "future_field": {"ignored": true}
          },
          {
            "id": "msg-compatible",
            "type": "message",
            "content": [
              {"type": "output_text", "text": "兼容后的回答"}
            ]
          }
        ]
      }
      """.utf8
    )

    let result = try XCTUnwrap(
      MacPawOpenAIResponsesClient.decodeCompatibleResponse(
        from: data,
        httpStatusCode: 200
      )
    )

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.outputText, "兼容后的回答")
    XCTAssertFalse(result.containsRefusal)
    XCTAssertEqual(result.httpStatusCode, 200)
    XCTAssertEqual(result.tokenUsage, .init(inputTokens: 32, outputTokens: 8, totalTokens: 40))
  }

  func testCompatibleResponseFallbackAcceptsGatewayChoiceShape() throws {
    let data = Data(
      """
      {
        "usage": {"prompt_tokens": 40, "completion_tokens": 10, "total_tokens": 50},
        "choices": [
          {"message": {"role": "assistant", "content": "gateway answer"}}
        ]
      }
      """.utf8
    )

    let result = try XCTUnwrap(
      MacPawOpenAIResponsesClient.decodeCompatibleResponse(
        from: data,
        httpStatusCode: 200
      )
    )

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.outputText, "gateway answer")
    XCTAssertEqual(result.tokenUsage, .init(inputTokens: 40, outputTokens: 10, totalTokens: 50))
  }

  func testCompatibleResponseFallbackPreservesIncompleteAndRefusal() throws {
    let data = Data(
      """
      {
        "object": "response",
        "status": "incomplete",
        "output": [
          {"type": "message", "content": [{"type": "refusal", "refusal": "no"}]}
        ]
      }
      """.utf8
    )

    let result = try XCTUnwrap(
      MacPawOpenAIResponsesClient.decodeCompatibleResponse(
        from: data,
        httpStatusCode: 200
      )
    )

    XCTAssertEqual(result.status, .incomplete)
    XCTAssertTrue(result.containsRefusal)
  }

  func testCompatibleUsagePreservesPartialAndZeroCountsWithoutEstimatingMissingCounts() throws {
    let fixtures: [(String, LanguageModelTokenUsage?)] = [
      ("null", nil),
      ("{}", nil),
      (
        #"{"input_tokens": 0, "output_tokens": 0, "total_tokens": 0}"#,
        .init(inputTokens: 0, outputTokens: 0, totalTokens: 0)
      ),
      (#"{"input_tokens": 12, "output_tokens": 3}"#, .init(inputTokens: 12, outputTokens: 3)),
      (#"{"total_tokens": 15}"#, .init(totalTokens: 15)),
      (#"{"input_tokens": -1, "output_tokens": 3}"#, .init(outputTokens: 3)),
      (#"{"input_tokens": true}"#, nil),
      (#"{"input_tokens": "12"}"#, nil),
      (#"{"input_tokens": 1.5}"#, nil),
    ]
    for (usage, expected) in fixtures {
      let data = Data("{\"output_text\":\"answer\",\"usage\":\(usage)}".utf8)
      let result = try XCTUnwrap(
        MacPawOpenAIResponsesClient.decodeCompatibleResponse(
          from: data, httpStatusCode: 200
        ))
      XCTAssertEqual(result.outputText, "answer", usage)
      XCTAssertEqual(result.tokenUsage, expected, usage)
    }
    let withoutUsage = try XCTUnwrap(
      MacPawOpenAIResponsesClient.decodeCompatibleResponse(
        from: Data(#"{"output_text":"answer"}"#.utf8), httpStatusCode: 200
      ))
    XCTAssertNil(withoutUsage.tokenUsage)
  }

  func testMacPawAdapterOmitsVerificationOutputLimit() async throws {
    OpenAIRequestCaptureProtocol.reset(responseData: completedResponseData)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenAIRequestCaptureProtocol.self]
    let requestRecorder = OpenAIRequestRecorder()
    let client = MacPawOpenAIResponsesClient(
      session: URLSession(configuration: configuration),
      additionalMiddlewares: [requestRecorder]
    )

    _ = try await client.createResponse(
      request: OpenAIResponsesRequest(
        input: "Return exactly OK.",
        instructions: "This is a provider configuration check. Return only OK.",
        baseURL: OpenAISettings.defaultBaseURL,
        model: OpenAIModelOption.luna.rawValue,
        store: false,
        stream: false,
        maxOutputTokens: nil
      ),
      apiKey: "verification-key"
    )

    let request = try XCTUnwrap(requestRecorder.capturedRequest())
    let body = try XCTUnwrap(request.httpBody)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["model"] as? String, "gpt-5.6-luna")
    XCTAssertNil(json["max_output_tokens"])
  }

  func testMacPawAdapterRejectsUnsafeOrMalformedEndpointBeforeTransport() async {
    let client = MacPawOpenAIResponsesClient()
    for baseURL in [
      "http://api.example.com/v1",
      "https://user:password@example.com/v1",
      "https://example.com/v1?key=secret",
      "not a url",
    ] {
      await assertRewriteError(.configurationInvalid) {
        _ = try await client.createResponse(
          request: .init(
            input: "text",
            instructions: "instruction",
            baseURL: baseURL,
            model: "custom-model",
            store: false,
            stream: false,
            maxOutputTokens: 8
          ),
          apiKey: "test-key"
        )
      }
    }
  }

  func testMacPawAdapterRejectsUnverifiedLoopbackCapabilities() async throws {
    let client = MacPawOpenAIResponsesClient()
    do {
      _ = try await client.createResponse(
        request: .init(
          input: "text", instructions: "test", baseURL: "http://127.0.0.1:11434/v1",
          model: "local-model", store: false, stream: false, maxOutputTokens: 8), apiKey: "local-key")
      XCTFail("Loopback transport permission does not establish model capabilities.")
    } catch let error as LanguageModelConfigurationError {
      XCTAssertEqual(error, .unsupportedReasoning(.none))
    }
  }

  func testMacPawAdapterMapsAuthenticationAndRateLimitWithoutLeakingBody() async {
    for (statusCode, expectedError) in [
      (400, OpenAITextRewriteError.configurationInvalid),
      (402, OpenAITextRewriteError.rateLimited),
      (404, OpenAITextRewriteError.configurationInvalid),
      (422, OpenAITextRewriteError.configurationInvalid),
      (401, OpenAITextRewriteError.authenticationFailed),
      (429, OpenAITextRewriteError.rateLimited),
    ] {
      let bodyCanary = "private-provider-error-body-canary"
      OpenAIRequestCaptureProtocol.reset(
        responseData: Data(
          """
          {"error":{"message":"\(bodyCanary)","type":"api_error","param":null,"code":null}}
          """.utf8
        ),
        statusCode: statusCode
      )
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [OpenAIRequestCaptureProtocol.self]
      let client = MacPawOpenAIResponsesClient(
        session: URLSession(configuration: configuration)
      )

      await assertRewriteError(expectedError) {
        _ = try await client.createResponse(
          request: .init(
            input: "text",
            instructions: "instruction",
            baseURL: OpenAISettings.defaultBaseURL,
            model: OpenAISettings.defaultModel,
            store: false,
            stream: false,
            maxOutputTokens: 8
          ),
          apiKey: "test-key"
        )
      }
      XCTAssertFalse(expectedError.localizedDescription.contains(bodyCanary))
    }
  }

  private var completedResponseData: Data {
    Data(
      """
      {
        "id": "resp-test",
        "object": "response",
        "model": "vendor/custom-model",
        "created_at": 1717459200,
        "output": [],
        "output_text": "polished",
        "tools": [],
        "metadata": {},
        "parallel_tool_calls": false,
        "tool_choice": "auto",
        "status": "completed"
      }
      """.utf8
    )
  }

  private var typedOutputResponseData: Data {
    Data(
      """
      {
        "id": "resp-typed-output",
        "object": "response",
        "usage": {
          "input_tokens": 120,
          "output_tokens": 24,
          "total_tokens": 144,
          "input_tokens_details": {"cached_tokens": 0, "cache_write_tokens": 0},
          "output_tokens_details": {"reasoning_tokens": 0}
        },
        "model": "gpt-5.6-luna",
        "created_at": 1717459200,
        "output": [
          {
            "id": "msg-typed-output",
            "type": "message",
            "role": "assistant",
            "content": [
              {
                "type": "output_text",
                "text": "typed ",
                "annotations": [],
                "logprobs": []
              },
              {
                "type": "output_text",
                "text": "polished",
                "annotations": [],
                "logprobs": []
              }
            ],
            "status": "completed"
          }
        ],
        "tools": [],
        "metadata": {},
        "parallel_tool_calls": false,
        "tool_choice": "auto",
        "status": "completed"
      }
      """.utf8
    )
  }
}

private actor OpenAIResponsesClientStub: OpenAIResponsesServing {
  struct Invocation: Sendable {
    let request: OpenAIResponsesRequest
    let apiKey: String
  }

  private let result: Result<OpenAIResponsesResult, Error>
  private let delay: Duration?
  private var invocation: Invocation?
  private var invocationWaiters: [CheckedContinuation<Void, Never>] = []
  private var suspendResponse: Bool
  private var responseWaiter: CheckedContinuation<Void, Never>?

  init(result: Result<OpenAIResponsesResult, Error>, delay: Duration? = nil, suspendResponse: Bool = false) {
    self.result = result
    self.delay = delay
    self.suspendResponse = suspendResponse
  }

  func createResponse(
    request: OpenAIResponsesRequest,
    apiKey: String
  ) async throws -> OpenAIResponsesResult {
    invocation = Invocation(request: request, apiKey: apiKey)
    let waiters = invocationWaiters
    invocationWaiters.removeAll()
    waiters.forEach { $0.resume() }
    if suspendResponse {
      await withCheckedContinuation { responseWaiter = $0 }
    }
    if let delay {
      try await Task.sleep(for: delay)
    }
    return try result.get()
  }

  func lastInvocation() -> Invocation? { invocation }

  func resumeResponse() {
    suspendResponse = false
    responseWaiter?.resume()
    responseWaiter = nil
  }

  func waitUntilInvoked() async {
    guard invocation == nil else { return }
    await withCheckedContinuation { invocationWaiters.append($0) }
  }
}

private final class OpenAIRequestRecorder: OpenAIMiddleware, @unchecked Sendable {
  private let lock = NSLock()
  private var request: URLRequest?

  func intercept(request: URLRequest) -> URLRequest {
    lock.withLock { self.request = request }
    return request
  }

  func capturedRequest() -> URLRequest? {
    lock.withLock { request }
  }
}

private final class OpenAIRequestCaptureProtocol: URLProtocol {
  private static let state = OpenAIRequestCaptureState()

  static func reset(responseData: Data, statusCode: Int = 200) {
    state.reset(responseData: responseData, statusCode: statusCode)
  }

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let captured = Self.state.record(request: request)
    let response = HTTPURLResponse(
      url: request.url ?? URL(string: "https://api.openai.com/v1/responses")!,
      statusCode: captured.statusCode,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: captured.data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private final class OpenAIRequestCaptureState: @unchecked Sendable {
  private let lock = NSLock()
  private var storedData = Data()
  private var storedStatusCode = 200

  func reset(responseData: Data, statusCode: Int) {
    lock.withLock {
      storedData = responseData
      storedStatusCode = statusCode
    }
  }

  func record(request: URLRequest) -> (data: Data, statusCode: Int) {
    lock.withLock { (storedData, storedStatusCode) }
  }
}

private func makeTransformContext(selectedText: String = "") -> TransformContext {
  return TransformContext(
    runID: UUID(),
    workflow: WorkflowDefinition(
      name: "Rewrite",
      plan: WorkflowPlan(
        setup: WorkflowSetupPhase(speechRoute: WorkflowSpeechRoute(recognizerID: "sherpa-onnx.local")),
        process: WorkflowProcessPhase(steps: [
          WorkflowProcessStep(kind: .recognizeSpeech), WorkflowProcessStep(kind: .resolveUncertainty, uncertaintyPolicy: .init()),
          WorkflowProcessStep(kind: .applyVocabulary),
        ]), output: WorkflowOutputPhase(actions: [OutputActionReference(id: "focused-application.insert")], deliveryPolicy: .init(strategy: .immediate))),
      ui: WorkflowUIConfig(symbolName: "wand.and.stars", accentColorName: "purple")
    ),
    contextSnapshot: ContextSnapshot(
      focus: FocusSnapshot(
        applicationName: "Private App",
        bundleIdentifier: "example.private",
        processIdentifier: 42,
        focusedRole: "AXTextArea",
        selectedText: selectedText,
        secureInput: false
      ),
      clipboard: SystemClipboardSnapshot(
        plainText: "private-clipboard-canary",
        changeCount: 1
      )
    ),
    recognitionResult: RecognitionResult(rawText: "text", bestText: "text")
  )
}

private func assertRewriteError(
  _ expected: OpenAITextRewriteError,
  operation: () async throws -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    try await operation()
    XCTFail("Expected \(expected)", file: file, line: line)
  } catch let error as OpenAITextRewriteError {
    XCTAssertEqual(error, expected, file: file, line: line)
  } catch let error as OpenAIResponsesRequestError {
    XCTAssertEqual(error.rewriteError, expected, file: file, line: line)
  } catch {
    XCTFail("Expected \(expected), got \(error)", file: file, line: line)
  }
}
