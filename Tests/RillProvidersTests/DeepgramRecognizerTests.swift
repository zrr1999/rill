import XCTest

@testable import RillCore
@testable import RillProviders

final class DeepgramRecognizerTests: XCTestCase {
  func testRecognizerDeclaresKeytermCapability() {
    let recognizer = DeepgramRecognizer()

    XCTAssertTrue(recognizer.capabilities.supports(.keyterm))
    XCTAssertEqual(recognizer.capabilities.supportedHintKinds, [.keyterm])
    XCTAssertNil(recognizer.capabilities.maximumAudioDurationSeconds)
  }

  func testRecognizerRequiresCapturedAudio() async {
    let recognizer = DeepgramRecognizer(configuration: .init(apiKey: unitTestDeepgramToken()))
    let request = RecognitionRequest(
      runID: UUID(),
      workflow: makeDeepgramWorkflow(),
      contextSnapshot: .empty
    )

    do {
      _ = try await recognizer.recognize(request)
      XCTFail("Expected missingCapturedAudio error")
    } catch let error as DeepgramRecognizer.RecognizerError {
      XCTAssertEqual(error, .missingCapturedAudio)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testRecognizerRequiresFileBackedAudio() async throws {
    let recognizer = DeepgramRecognizer(configuration: .init(apiKey: unitTestDeepgramToken()))
    let capturedAudio = try CapturedAudio(
      durationSeconds: 1.0,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
      inlineData: Data([0x00, 0x01])
    )
    let request = RecognitionRequest(
      runID: UUID(),
      workflow: makeDeepgramWorkflow(),
      contextSnapshot: .empty,
      capturedAudio: capturedAudio
    )

    do {
      _ = try await recognizer.recognize(request)
      XCTFail("Expected fileBackedAudioRequired error")
    } catch let error as DeepgramRecognizer.RecognizerError {
      XCTAssertEqual(error, .fileBackedAudioRequired)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testRecognizerRequiresAPIKey() async throws {
    let recognizer = DeepgramRecognizer(configuration: .init(apiKey: nil))
    let temporaryFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-deepgram-test")
      .appendingPathExtension("wav")
    try Data().write(to: temporaryFile)
    defer { try? FileManager.default.removeItem(at: temporaryFile) }

    let capturedAudio = try CapturedAudio(
      durationSeconds: 1.0,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
      fileURL: temporaryFile
    )
    let request = RecognitionRequest(
      runID: UUID(),
      workflow: makeDeepgramWorkflow(),
      contextSnapshot: .empty,
      capturedAudio: capturedAudio
    )

    do {
      _ = try await recognizer.recognize(request)
      XCTFail("Expected missingAPIKey error")
    } catch let error as DeepgramRecognizer.RecognizerError {
      XCTAssertEqual(error, .missingAPIKey)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testRecognizerTreatsWhitespaceOnlyAPIKeyAsMissing() async throws {
    let recognizer = DeepgramRecognizer(configuration: .init(apiKey: " \n\t "))
    let temporaryFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-deepgram-blank-key-test")
      .appendingPathExtension("wav")
    try Data().write(to: temporaryFile)
    defer { try? FileManager.default.removeItem(at: temporaryFile) }
    let capturedAudio = try CapturedAudio(
      durationSeconds: 1,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
      fileURL: temporaryFile
    )

    do {
      _ = try await recognizer.recognize(
        RecognitionRequest(
          runID: UUID(),
          workflow: makeDeepgramWorkflow(),
          contextSnapshot: .empty,
          capturedAudio: capturedAudio
        )
      )
      XCTFail("Expected missingAPIKey error")
    } catch let error as DeepgramRecognizer.RecognizerError {
      XCTAssertEqual(error, .missingAPIKey)
    }
  }

  func testStartupDiagnosticTreatsWhitespaceOnlyAPIKeyAsUnavailable() {
    let diagnostic = DeepgramRecognizer.startupDiagnostic(
      configuration: .init(apiKey: " \n\t ")
    )

    XCTAssertEqual(diagnostic.level, .warning)
    XCTAssertEqual(diagnostic.event, "provider.deepgram.credential_unavailable")
    XCTAssertFalse(diagnostic.message.contains("\n\t"))
    XCTAssertEqual(diagnostic.metadata, ["recognizerID": "deepgram.prerecorded"])
  }

  func testConfigurationValidatorTrimsKeyAndRejectsUnsafeURLWithFixedError() throws {
    let validated = try DeepgramConfigurationValidator.validate(
      .init(apiKey: "  test-key  "),
      environmentAPIKey: nil
    )
    XCTAssertEqual(validated.apiKey, "test-key")

    let unsafeURLCanary = "http://private-endpoint-canary.example"
    XCTAssertThrowsError(
      try DeepgramConfigurationValidator.validate(
        .init(apiKey: "private-key-canary", baseURL: unsafeURLCanary),
        environmentAPIKey: nil
      )
    ) { error in
      XCTAssertEqual(error as? DeepgramRecognizer.RecognizerError, .invalidBaseURL)
      XCTAssertFalse(error.localizedDescription.contains(unsafeURLCanary))
      XCTAssertFalse(error.localizedDescription.contains("private-key-canary"))
    }
  }

  func testRecognizerRejectsPublicPlainHTTPBeforeUploadingCredentialsOrAudio() async throws {
    DeepgramRequestCaptureProtocol.reset(responseData: Data())
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [DeepgramRequestCaptureProtocol.self]
    let recognizer = DeepgramRecognizer(
      configuration: .init(
        apiKey: unitTestDeepgramToken(),
        baseURL: "http://api.example.com"
      ),
      session: URLSession(configuration: sessionConfiguration)
    )
    let temporaryFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-deepgram-insecure-endpoint-test")
      .appendingPathExtension("wav")
    try Data([0x00]).write(to: temporaryFile)
    defer { try? FileManager.default.removeItem(at: temporaryFile) }
    let capturedAudio = try CapturedAudio(
      durationSeconds: 1,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
      fileURL: temporaryFile
    )

    do {
      _ = try await recognizer.recognize(
        RecognitionRequest(
          runID: UUID(),
          workflow: makeDeepgramWorkflow(),
          contextSnapshot: .empty,
          capturedAudio: capturedAudio
        )
      )
      XCTFail("Expected invalidBaseURL error")
    } catch let error as DeepgramRecognizer.RecognizerError {
      XCTAssertEqual(error, .invalidBaseURL)
    }

    XCTAssertNil(DeepgramRequestCaptureProtocol.capturedURL())
  }

  func testRecognizerUsesWorkflowModelAndLanguageOverridesForRequestURL() async throws {
    DeepgramRequestCaptureProtocol.reset(
      responseData: Data(
        #"{"results":{"channels":[{"alternatives":[{"transcript":"hello"}]}]}}"#.utf8)
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DeepgramRequestCaptureProtocol.self]
    let session = URLSession(configuration: configuration)
    let recognizer = DeepgramRecognizer(
      configuration: .init(
        apiKey: unitTestDeepgramToken(), model: "global-model", language: "global-language"),
      session: session
    )
    let temporaryFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-deepgram-routing-test")
      .appendingPathExtension("wav")
    try Data([0x00]).write(to: temporaryFile)
    defer { try? FileManager.default.removeItem(at: temporaryFile) }
    let capturedAudio = try CapturedAudio(
      durationSeconds: 1.0,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
      fileURL: temporaryFile
    )
    var workflow = makeDeepgramWorkflow()
    workflow.metadata[WorkflowMetadataKey.deepgramModelOverride] = "workflow-model"
    workflow.metadata[WorkflowMetadataKey.languageOverride] = "zh-CN"
    let request = RecognitionRequest(
      runID: UUID(),
      workflow: workflow,
      contextSnapshot: .empty,
      capturedAudio: capturedAudio
    )

    _ = try await recognizer.recognize(request)

    let capturedURL = DeepgramRequestCaptureProtocol.capturedURL()
    let url = try XCTUnwrap(capturedURL)
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let query = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    XCTAssertEqual(query["model"], "workflow-model")
    XCTAssertEqual(query["language"], "zh-CN")
  }

  func testRecognizerAppliesOptionsLanguageAndSanitizedRepeatedKeyterms() async throws {
    let keytermCanary = "Rill-private-keyterm-canary"
    let reportProbe = DeepgramHintReportProbe()
    DeepgramRequestCaptureProtocol.reset(
      responseData: Data(
        #"{"results":{"channels":[{"alternatives":[{"transcript":"hello"}]}]}}"#.utf8)
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DeepgramRequestCaptureProtocol.self]
    let recognizer = DeepgramRecognizer(
      configuration: .init(
        apiKey: unitTestDeepgramToken(),
        model: "global-model",
        language: "global-language"
      ),
      session: URLSession(configuration: configuration),
      hintDiagnosticReporter: { report in
        await reportProbe.record(report)
      }
    )
    let temporaryFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-deepgram-keyterm-test")
      .appendingPathExtension("wav")
    try Data([0x00]).write(to: temporaryFile)
    defer { try? FileManager.default.removeItem(at: temporaryFile) }
    let capturedAudio = try CapturedAudio(
      durationSeconds: 1,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
      fileURL: temporaryFile
    )
    var workflow = makeDeepgramWorkflow()
    workflow.metadata[WorkflowMetadataKey.deepgramModelOverride] = "nova-3-general"
    workflow.metadata[WorkflowMetadataKey.languageOverride] = "workflow-language"

    let result = try await recognizer.recognize(
      RecognitionRequest(
        runID: UUID(),
        workflow: workflow,
        contextSnapshot: .empty,
        capturedAudio: capturedAudio,
        options: SpeechRecognitionRequestOptions(
          language: " zh-CN ",
          hints: RecognitionHints(
            keyterms: [
              " \(keytermCanary) ",
              keytermCanary,
              "rill-private-keyterm-canary",
              "drop\nthis",
              "   ",
            ]
          )
        )
      )
    )

    let url = try XCTUnwrap(DeepgramRequestCaptureProtocol.capturedURL())
    let queryItems = try XCTUnwrap(
      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    XCTAssertEqual(queryItems.first(where: { $0.name == "model" })?.value, "nova-3-general")
    XCTAssertEqual(queryItems.first(where: { $0.name == "language" })?.value, "zh-CN")
    XCTAssertEqual(
      queryItems.filter { $0.name == "keyterm" }.compactMap(\.value),
      [keytermCanary, "rill-private-keyterm-canary"]
    )
    XCTAssertNil(queryItems.first(where: { $0.name == "keywords" }))
    XCTAssertFalse(result.metadata.values.contains(where: { $0.contains(keytermCanary) }))

    let latestReport = await reportProbe.lastReport()
    let report = try XCTUnwrap(latestReport)
    XCTAssertEqual(report.source, .prerecorded)
    XCTAssertEqual(report.outcome, .partiallyApplied)
    XCTAssertEqual(report.count, 2)
    XCTAssertEqual(report.omittedCount, 3)
    XCTAssertFalse(String(reflecting: report).contains(keytermCanary))
    XCTAssertFalse(String(reflecting: report).contains("keyterm="))
  }

  func testRequestPlannerCapsKeytermsAndUsesStrictNova3Allowlist() {
    let keyterms = (0..<55).map { "term-\($0)" }
    for model in ["nova-3", "nova-3-general", "nova-3-medical", " NOVA-3 "] {
      var workflow = makeDeepgramWorkflow()
      workflow.metadata[WorkflowMetadataKey.deepgramModelOverride] = model

      let plan = DeepgramRequestPlanner.plan(
        options: SpeechRecognitionRequestOptions(hints: RecognitionHints(keyterms: keyterms)),
        workflow: workflow,
        configuration: .init(),
        source: .prerecorded
      )

      XCTAssertEqual(plan.keyterms, Array(keyterms.prefix(50)))
      XCTAssertEqual(plan.hintDiagnosticReport.outcome, .partiallyApplied)
      XCTAssertEqual(plan.hintDiagnosticReport.count, 50)
      XCTAssertEqual(plan.hintDiagnosticReport.omittedCount, 5)
    }

    for model in ["nova-3-special", "nova-2"] {
      var workflow = makeDeepgramWorkflow()
      workflow.metadata[WorkflowMetadataKey.deepgramModelOverride] = model

      let plan = DeepgramRequestPlanner.plan(
        options: SpeechRecognitionRequestOptions(hints: RecognitionHints(keyterms: ["Rill"])),
        workflow: workflow,
        configuration: .init(),
        source: .prerecorded
      )

      XCTAssertTrue(plan.keyterms.isEmpty)
      XCTAssertEqual(plan.hintDiagnosticReport.outcome, .unsupportedModel)
      XCTAssertEqual(plan.hintDiagnosticReport.count, 0)
      XCTAssertEqual(plan.hintDiagnosticReport.omittedCount, 1)
    }
  }

  func testRequestPlannerEnforcesPerTermAndTotalScalarLimits() {
    let acceptedSizedKeyterms = (0..<5).map { index in
      String(repeating: "a", count: 89) + String(index)
    }
    let totalLimitOverflow = String(repeating: "b", count: 90)
    let perTermLimitOverflow = String(repeating: "c", count: 101)

    let plan = DeepgramRequestPlanner.plan(
      options: SpeechRecognitionRequestOptions(
        hints: RecognitionHints(
          keyterms: acceptedSizedKeyterms + [totalLimitOverflow, perTermLimitOverflow]
        )
      ),
      workflow: makeDeepgramWorkflow(),
      configuration: .init(),
      source: .prerecorded
    )

    XCTAssertEqual(plan.keyterms, acceptedSizedKeyterms)
    XCTAssertEqual(plan.keyterms.reduce(0) { $0 + $1.unicodeScalars.count }, 450)
    XCTAssertEqual(plan.hintDiagnosticReport.outcome, .partiallyApplied)
    XCTAssertEqual(plan.hintDiagnosticReport.count, 5)
    XCTAssertEqual(plan.hintDiagnosticReport.omittedCount, 2)
  }

  func testRecognizerReusesLiveTranscriptMetadataWithoutUploadingAgain() async throws {
    let recognizer = DeepgramRecognizer(configuration: .init(apiKey: nil))
    let capturedAudio = try CapturedAudio(
      durationSeconds: 1.0,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
      inlineData: Data([0x00, 0x01]),
      metadata: [
        DeepgramRecognizer.liveBestTextMetadataKey: "hello world",
        DeepgramRecognizer.liveRawTextMetadataKey: "hello world",
        DeepgramRecognizer.liveRequestIDMetadataKey: "req-123",
        DeepgramRecognizer.liveModelMetadataKey: "nova-3",
      ]
    )
    let request = RecognitionRequest(
      runID: UUID(),
      workflow: makeDeepgramWorkflow(),
      contextSnapshot: .empty,
      capturedAudio: capturedAudio
    )

    let result = try await recognizer.recognize(request)

    XCTAssertEqual(result.bestText, "hello world")
    XCTAssertEqual(result.rawText, "hello world")
    XCTAssertEqual(result.metadata["provider"], DeepgramRecognizer.liveProviderID)
    XCTAssertEqual(result.metadata["provider.kind"], "deepgram.live")
    XCTAssertEqual(result.metadata["provider.model"], "nova-3")
    XCTAssertEqual(result.metadata["provider.request_id"], "req-123")
  }

  func testRequestFailureDoesNotExposeResponseBody() async throws {
    let responseCanary = "response-body-deepgram-canary"
    DeepgramRequestCaptureProtocol.reset(
      responseData: Data(
        #"{"error":"\#(responseCanary)","authorization":"Bearer body-secret"}"#.utf8),
      statusCode: 401
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DeepgramRequestCaptureProtocol.self]
    let recognizer = DeepgramRecognizer(
      configuration: .init(apiKey: unitTestDeepgramToken()),
      session: URLSession(configuration: configuration)
    )
    let temporaryFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-deepgram-error-privacy-test")
      .appendingPathExtension("wav")
    try Data([0x00]).write(to: temporaryFile)
    defer { try? FileManager.default.removeItem(at: temporaryFile) }
    let capturedAudio = try CapturedAudio(
      durationSeconds: 1,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
      fileURL: temporaryFile
    )

    do {
      _ = try await recognizer.recognize(
        RecognitionRequest(
          runID: UUID(),
          workflow: makeDeepgramWorkflow(),
          contextSnapshot: .empty,
          capturedAudio: capturedAudio
        )
      )
      XCTFail("Expected requestFailed error")
    } catch let error as DeepgramRecognizer.RecognizerError {
      XCTAssertEqual(error, .requestFailed(statusCode: 401))
      XCTAssertEqual(error.errorDescription, "Deepgram request failed with status 401.")
      XCTAssertFalse(error.localizedDescription.contains(responseCanary))
      XCTAssertFalse(error.localizedDescription.contains("Bearer"))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testTransportFailureDoesNotExposeRequestURLOrKeyterm() async throws {
    let keytermCanary = "transport-private-keyterm-canary"
    let transportCanary = "transport-error-url-canary"
    DeepgramRequestCaptureProtocol.reset(
      responseData: Data(),
      transportError: NSError(
        domain: "DeepgramTransportTests",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "failed https://api.deepgram.com/v1/listen?keyterm=\(keytermCanary)&canary=\(transportCanary)"
        ]
      )
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DeepgramRequestCaptureProtocol.self]
    let recognizer = DeepgramRecognizer(
      configuration: .init(apiKey: unitTestDeepgramToken()),
      session: URLSession(configuration: configuration)
    )
    let temporaryFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-deepgram-transport-privacy-test")
      .appendingPathExtension("wav")
    try Data([0x00]).write(to: temporaryFile)
    defer { try? FileManager.default.removeItem(at: temporaryFile) }
    let capturedAudio = try CapturedAudio(
      durationSeconds: 1,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
      fileURL: temporaryFile
    )

    do {
      _ = try await recognizer.recognize(
        RecognitionRequest(
          runID: UUID(),
          workflow: makeDeepgramWorkflow(),
          contextSnapshot: .empty,
          capturedAudio: capturedAudio,
          options: SpeechRecognitionRequestOptions(
            hints: RecognitionHints(keyterms: [keytermCanary])
          )
        )
      )
      XCTFail("Expected transportFailed error")
    } catch let error as DeepgramRecognizer.RecognizerError {
      XCTAssertEqual(error, .transportFailed)
      XCTAssertEqual(error.errorDescription, "Deepgram request could not be completed.")
      XCTAssertFalse(error.localizedDescription.contains(keytermCanary))
      XCTAssertFalse(error.localizedDescription.contains(transportCanary))
      XCTAssertFalse(error.localizedDescription.contains("https://"))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }
}

private func unitTestDeepgramToken() -> String {
  ["unit", "test", "token"].joined(separator: "-")
}

private actor DeepgramHintReportProbe {
  private var report: DeepgramHintDiagnosticReport?

  func record(_ report: DeepgramHintDiagnosticReport) {
    self.report = report
  }

  func lastReport() -> DeepgramHintDiagnosticReport? {
    report
  }
}

private final class DeepgramRequestCaptureProtocol: URLProtocol {
  private static let state = DeepgramRequestCaptureState()

  static func reset(
    responseData: Data,
    statusCode: Int = 200,
    transportError: Error? = nil
  ) {
    state.reset(
      responseData: responseData,
      statusCode: statusCode,
      transportError: transportError
    )
  }

  static func capturedURL() -> URL? {
    state.capturedURL()
  }

  override static func canInit(with request: URLRequest) -> Bool { true }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let capturedResponse = Self.state.record(url: request.url)
    if let transportError = capturedResponse.transportError {
      client?.urlProtocol(self, didFailWithError: transportError)
      return
    }
    let response = HTTPURLResponse(
      url: request.url ?? URL(string: "https://api.deepgram.com")!,
      statusCode: capturedResponse.statusCode,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: capturedResponse.data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private final class DeepgramRequestCaptureState: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCapturedURL: URL?
  private var storedResponseData = Data()
  private var storedStatusCode = 200
  private var storedTransportError: Error?

  func reset(responseData: Data, statusCode: Int, transportError: Error?) {
    lock.withLock {
      storedCapturedURL = nil
      storedResponseData = responseData
      storedStatusCode = statusCode
      storedTransportError = transportError
    }
  }

  func record(url: URL?) -> (data: Data, statusCode: Int, transportError: Error?) {
    lock.withLock {
      storedCapturedURL = url
      return (storedResponseData, storedStatusCode, storedTransportError)
    }
  }

  func capturedURL() -> URL? {
    lock.withLock { storedCapturedURL }
  }
}

private func makeDeepgramWorkflow() -> WorkflowDefinition {
  WorkflowDefinition(
    name: "Deepgram Test Workflow",
    pipeline: PipelineDeclaration(
      recognizerID: "deepgram.prerecorded",
      outputActions: []
    ),
    ui: WorkflowUIConfig(symbolName: "icloud", accentColorName: "cyan"),
    metadata: [
      WorkflowMetadataKey.languageOverride: "en-US",
      WorkflowMetadataKey.deepgramModelOverride: "nova-3",
    ]
  )
}
