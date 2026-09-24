import Foundation
import os
import Testing

@testable import RillCore
@testable import RillProviders

@Suite(.serialized)
struct JevTextPolishingGateTests {
  @Test func cleanTextSkipsAndOnlyTranscriptAndInstructionsAreSent() async throws {
    let fixture = fixture()
    #expect(try await fixture.gate.shouldSkip(text: "请明天 10:30 开会。", step: step, context: context()))
    let requests = PolishingURLProtocol.state.withLock { $0.requests }
    let request = try #require(requests.first)
    #expect(requests.count == 1)
    #expect(request.url?.absoluteString == "https://api.typesafe.ai/v1/systemone")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer unit-test-key")
    let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
    #expect(Set(body.keys) == ["model", "state", "questions"])
    #expect(body["state"] as? [String: String] == ["transcript": "请明天 10:30 开会。"])
    let encoded = String(decoding: request.httpBody!, as: UTF8.self)
    #expect(encoded.contains("workflow_instruction"))
    #expect(!encoded.contains("private-selected-text"))
    #expect(!encoded.contains("private-clipboard"))
    await fixture.gate.shutdown()
    #expect(fixture.settings.currentAuthorization() == nil)
  }

  @Test(arguments: [
    (0.98, 0.01, 0.01, 0.99), (0.05, 0.9, 0.05, 0.99),
    (0.05, 0.06, 0.89, 0.99), (0.01, 0.01, 0.98, 0.89),
  ])
  func neededUncertainAndLowConfidenceContinuePolishing(probabilities: (Double, Double, Double, Double)) async throws {
    let fixture = fixture(response: Self.response(probabilities))
    #expect(try await !fixture.gate.shouldSkip(text: "text", step: step, context: context()))
    #expect(PolishingURLProtocol.state.withLock { $0.requests.count } == 1)
    await fixture.gate.shutdown()
  }

  @Test(arguments: [401, 403, 429, 529, 500, 302])
  func serviceFailuresFallBackWithoutRetry(status: Int) async throws {
    let fixture = fixture(status: status)
    #expect(try await !fixture.gate.shouldSkip(text: "text", step: step, context: context()))
    #expect(PolishingURLProtocol.state.withLock { $0.requests.count } == 1)
    await fixture.gate.shutdown()
  }

  @Test(arguments: [
    "not JSON",
    response((0.01, 0.01, 0.98, 0.99)).replacingOccurrences(of: "jev-1.13.0", with: "other-model"),
    response((0.01, 0.01, 0.98, 0.99)).replacingOccurrences(of: "polishing", with: "unexpected"),
    response((0.01, 0.01, 0.98, 0.99)).replacingOccurrences(of: "\"2\":0.98", with: "\"2\":1.98"),
  ])
  func invalidPredictionsNeverSkip(response: String) async throws {
    let fixture = fixture(response: response)
    #expect(try await !fixture.gate.shouldSkip(text: "text", step: step, context: context()))
    await fixture.gate.shutdown()
  }

  @Test func disabledMissingKeysAndOversizedTextMakeNoRequest() async throws {
    let fixture = fixture()
    fixture.settings.setPolishingEnabled(false)
    #expect(try await !fixture.gate.shouldSkip(text: "text", step: step, context: context()))
    fixture.settings.clear()
    #expect(try await !fixture.gate.shouldSkip(text: "text", step: step, context: context()))
    try fixture.settings.setKey("unit-test-key")
    fixture.settings.setPolishingEnabled(true)
    #expect(try await !fixture.gate.shouldSkip(text: String(repeating: "中", count: 601), step: step, context: context()))
    #expect(try await !fixture.gate.shouldSkip(text: "  ", step: step, context: context()))
    #expect(PolishingURLProtocol.state.withLock { $0.requests.isEmpty })
    await fixture.gate.shutdown()
  }

  @Test func unrelatedWorkflowsAnswersAndContextualReferencesAreNotPredicted() async throws {
    let fixture = fixture()
    var custom = context()
    custom.workflow.metadata = [:]
    #expect(try await !fixture.gate.shouldSkip(text: "text", step: step, context: custom))
    #expect(try await !fixture.gate.shouldSkip(text: "text", step: .init(kind: .llmAnswer, prompt: "Answer"), context: context()))
    var referenced = context()
    referenced.correctionRequest = .init(transcript: "text", imageSummary: .init(terms: ["term"], observations: []))
    #expect(try await !fixture.gate.shouldSkip(text: "text", step: step, context: referenced))
    #expect(PolishingURLProtocol.state.withLock { $0.requests.isEmpty })
    custom.workflow.metadata["text.polishing-gate"] = "jev"
    #expect(try await fixture.gate.shouldSkip(text: "text", step: step, context: custom))
    await fixture.gate.shutdown()
  }

  @Test func privacyBlocksOriginalAndCurrentSourcesBeforeSend() async throws {
    for bundle in ["example.source", "example.target"] {
      let fixture = fixture()
      fixture.privacy.update(.init(sensitiveAppRules: [.init(bundleIdentifier: bundle, blocksCloudProcessing: true)]))
      await #expect(throws: CancellationError.self) {
        try await fixture.gate.shouldSkip(text: "text", step: step, context: context())
      }
      #expect(PolishingURLProtocol.state.withLock { $0.requests.isEmpty })
      await fixture.gate.shutdown()
    }
  }

  @Test func consentRevocationDiscardsPrediction() async throws {
    let fixture = fixture()
    PolishingURLProtocol.state.withLock {
      $0.onRequest = { fixture.settings.clear() }
    }
    #expect(try await !fixture.gate.shouldSkip(text: "text", step: step, context: context()))
    await fixture.gate.shutdown()
  }

  @Test func privacyRevocationDuringPredictionCancelsInsteadOfRewriting() async throws {
    let fixture = fixture()
    PolishingURLProtocol.state.withLock {
      $0.onRequest = { fixture.privacy.update(.init(sensitiveAppRules: [
        .init(bundleIdentifier: "example.source", blocksCloudProcessing: true)
      ])) }
    }
    await #expect(throws: CancellationError.self) {
      try await fixture.gate.shouldSkip(text: "text", step: step, context: context())
    }
    await fixture.gate.shutdown()
  }

  @Test func timeoutFallsBackAndCancellationDoesNot() async throws {
    let fixture = fixture(timeout: .milliseconds(100), stalls: true)
    #expect(try await !fixture.gate.shouldSkip(text: "text", step: step, context: context()))
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await fixture.gate.shouldSkip(text: "text", step: step, context: context())
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    await fixture.gate.shutdown()
  }

  @Test func cancellationDuringRequestDrainsTheRequestWithoutReturningASkip() async throws {
    let fixture = fixture(stalls: true)
    let started = AsyncStream<Void>.makeStream()
    PolishingURLProtocol.state.withLock { $0.onRequest = { started.continuation.yield() } }
    let task = Task { try await fixture.gate.shouldSkip(text: "text", step: step, context: context()) }
    for await _ in started.stream { break }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    await fixture.gate.shutdown()
    started.continuation.finish()
    #expect(PolishingURLProtocol.state.withLock { $0.requests.count } == 1)
  }

  @Test func unavailablePrivacyAndSecureInputMakeNoRequest() async throws {
    let fixture = fixture()
    var secure = context()
    secure.contextSnapshot.focus.secureInput = true
    await #expect(throws: CancellationError.self) {
      try await fixture.gate.shouldSkip(text: "text", step: step, context: secure)
    }
    fixture.privacy.markUnavailable(reason: "test unavailable")
    await #expect(throws: CancellationError.self) {
      try await fixture.gate.shouldSkip(text: "text", step: step, context: context())
    }
    #expect(PolishingURLProtocol.state.withLock { $0.requests.isEmpty })
    await fixture.gate.shutdown()
  }

  private var step: PostProcessStep { .init(kind: .llmRewrite, prompt: "Correct clear errors; preserve meaning and language.") }

  private func context() -> TransformContext {
    let workflow = WorkflowDefinition(name: "Cleanup",
      pipeline: .init(recognizerID: "local-speech", postProcessSteps: [step], outputActions: [.init(id: "record.store")]),
      ui: .init(symbolName: "sparkles", accentColorName: "purple"),
      metadata: [WorkflowMetadataKey.builtinKind: "push-to-talk.polish"])
    return .init(runID: UUID(), workflow: workflow,
      contextSnapshot: .init(focus: Self.focus("example.source"),
        clipboard: .init(plainText: "private-clipboard", changeCount: 0)),
      recognitionResult: .init(rawText: "text", bestText: "text"))
  }

  private static func focus(_ bundle: String) -> FocusSnapshot {
    .init(applicationName: "Editor", bundleIdentifier: bundle, processIdentifier: 123,
      focusedRole: nil, selectedText: "private-selected-text", secureInput: false)
  }

  private func fixture(response: String = response((0.01, 0.01, 0.98, 0.99)), status: Int = 200,
    timeout: Duration = .seconds(2), stalls: Bool = false
  ) -> (gate: JevTextPolishingGate, settings: JevSessionSettingsSource, privacy: PrivacyPolicySettingsSource) {
    PolishingURLProtocol.state.withLock { $0 = .init(response: response, status: status, stalls: stalls) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PolishingURLProtocol.self]
    let settings = JevSessionSettingsSource()
    try! settings.setKey("unit-test-key")
    settings.setPolishingEnabled(true)
    let privacy = PrivacyPolicySettingsSource(initialSettings: .defaults)
    let gate = JevTextPolishingGate(settings: settings, privacy: privacy,
      currentFocus: { Self.focus("example.target") }, client: .init(session: URLSession(configuration: configuration)),
      timeout: timeout)
    return (gate, settings, privacy)
  }

  private static func response(_ values: (Double, Double, Double, Double)) -> String {
    """
    {"model":"jev-1.13.0","answers":{"polishing":{"type":"score","score":\(values.1 + 2 * values.2),"confidence":\(values.3),"probabilities":{"0":\(values.0),"1":\(values.1),"2":\(values.2)}}},"usage":{"input_tokens":40,"output_tokens":10}}
    """
  }
}

private final class PolishingURLProtocol: URLProtocol {
  struct State {
    var response: String
    var status = 200
    var stalls = false
    var requests: [URLRequest] = []
    var onRequest: (@Sendable () -> Void)?
  }
  static let state = OSAllocatedUnfairLock(initialState: State(response: ""))
  override class func canInit(with _: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    var captured = request
    if let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var body = Data()
      var buffer = [UInt8](repeating: 0, count: 1_024)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        body.append(contentsOf: buffer.prefix(count))
      }
      captured.httpBody = body
    }
    let fixture = Self.state.withLock { [captured] in
      $0.requests.append(captured)
      return $0
    }
    fixture.onRequest?()
    guard !fixture.stalls else { return }
    let response = HTTPURLResponse(url: request.url!, statusCode: fixture.status, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(fixture.response.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
