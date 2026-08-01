import Foundation
import OpenAI
import XCTest

@testable import RillCore
@testable import RillProviders

final class OpenAITextRewriteTransformerTests: XCTestCase {
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
      settingsProvider: {
        OpenAISettings(
          apiKey: " test-key ",
          baseURL: "https://gateway.example.com/openai/v1",
          model: "vendor/custom-model"
        )
      },
      clientFactory: { client }
    )
    let contextCanary = "private-selected-text-canary"

    let output = try await transformer.transform(
      text: "呃 这是 原始正文",
      step: PostProcessStep(kind: .llmRewrite, prompt: "Make this concise."),
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
    XCTAssertEqual(invocation.request.baseURL, "https://gateway.example.com/openai/v1")
    XCTAssertEqual(invocation.request.model, "vendor/custom-model")
    XCTAssertFalse(invocation.request.store)
    XCTAssertFalse(invocation.request.stream)
    XCTAssertEqual(
      invocation.request.maxOutputTokens,
      OpenAITextRewriteTransformer.maximumOutputTokens
    )
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
        settingsProvider: { settings },
        clientFactory: { client }
      )
      await assertRewriteError(expectedError) {
        _ = try await transformer.transform(
          text: "text",
          step: PostProcessStep(kind: .llmRewrite, prompt: "Polish."),
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
        settingsProvider: { OpenAISettings(apiKey: "test-key") },
        clientFactory: { client }
      )
      await assertRewriteError(expectedError) {
        _ = try await transformer.transform(
          text: "text",
          step: PostProcessStep(kind: .llmRewrite, prompt: "Polish."),
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
      settingsProvider: { OpenAISettings(apiKey: "test-key") },
      clientFactory: { client }
    )
    let task = Task {
      try await transformer.transform(
        text: "text",
        step: PostProcessStep(kind: .llmRewrite, prompt: "Polish."),
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
        baseURL: "https://gateway.example.com/v1"
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
    XCTAssertEqual(invocation.request.baseURL, "https://gateway.example.com/v1")
    XCTAssertEqual(invocation.request.model, "gpt-5.6-luna")
    XCTAssertNil(invocation.request.maxOutputTokens)
  }

  func testMacPawAdapterUsesCustomEndpointPathAndRequiredBodyFields() async throws {
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
        baseURL: "https://gateway.example.com/openai/v1",
        model: "vendor/custom-model",
        store: false,
        stream: false,
        maxOutputTokens: 4_096
      ),
      apiKey: "secret-token-canary"
    )

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.outputText, "polished")
    let request = try XCTUnwrap(requestRecorder.capturedRequest())
    XCTAssertEqual(request.url?.path, "/openai/v1/responses")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token-canary")
    let body = try XCTUnwrap(request.httpBody)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["input"] as? String, "transcript-canary")
    XCTAssertEqual(json["instructions"] as? String, "instruction-canary")
    XCTAssertEqual(json["model"] as? String, "vendor/custom-model")
    XCTAssertEqual(json["store"] as? Bool, false)
    XCTAssertEqual(json["stream"] as? Bool, false)
    XCTAssertEqual(json["max_output_tokens"] as? Int, 4_096)
    XCTAssertNil(json["reasoning"])
    XCTAssertNil(json["metadata"])
    XCTAssertNil(json["user"])
    XCTAssertNil(json["previous_response_id"])
  }

  func testMacPawAdapterCollectsTypedOutputWhenConvenienceFieldIsAbsent() async throws {
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
    XCTAssertFalse(result.containsRefusal)
  }

  func testCompatibleResponseFallbackIgnoresUnknownItemsAndCollectsText() throws {
    let data = Data(
      """
      {
        "id": "resp-compatible",
        "object": "response",
        "status": "completed",
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
  }

  func testCompatibleResponseFallbackAcceptsGatewayChoiceShape() throws {
    let data = Data(
      """
      {
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
        baseURL: "https://gateway.example.com/v1",
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

  func testMacPawAdapterAllowsPlainHTTPForLoopbackEndpoint() async throws {
    OpenAIRequestCaptureProtocol.reset(responseData: completedResponseData)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenAIRequestCaptureProtocol.self]
    let requestRecorder = OpenAIRequestRecorder()
    let client = MacPawOpenAIResponsesClient(
      session: URLSession(configuration: configuration),
      additionalMiddlewares: [requestRecorder]
    )

    _ = try await client.createResponse(
      request: .init(
        input: "text",
        instructions: "instruction",
        baseURL: "http://127.0.0.1:11434/v1",
        model: "local-model",
        store: false,
        stream: false,
        maxOutputTokens: 8
      ),
      apiKey: "local-key"
    )

    let request = try XCTUnwrap(requestRecorder.capturedRequest())
    XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/v1/responses")
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

  init(result: Result<OpenAIResponsesResult, Error>, delay: Duration? = nil) {
    self.result = result
    self.delay = delay
  }

  func createResponse(
    request: OpenAIResponsesRequest,
    apiKey: String
  ) async throws -> OpenAIResponsesResult {
    invocation = Invocation(request: request, apiKey: apiKey)
    let waiters = invocationWaiters
    invocationWaiters.removeAll()
    waiters.forEach { $0.resume() }
    if let delay {
      try await Task.sleep(for: delay)
    }
    return try result.get()
  }

  func lastInvocation() -> Invocation? { invocation }

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
  TransformContext(
    runID: UUID(),
    workflow: WorkflowDefinition(
      name: "Rewrite",
      pipeline: PipelineDeclaration(
        recognizerID: "sherpa-onnx.local",
        outputActions: [OutputActionReference(id: "inject.text")]
      ),
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
      clipboard: ClipboardSnapshot(
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
