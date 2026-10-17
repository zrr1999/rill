import Foundation
import os
import Testing

@testable import RillCore
@testable import RillProviders

@Suite(.serialized)
struct DecisionRecordRankingProviderTests {
  @Test func sendsOnlyReviewedTextAndMapsScoresByCandidateIndex() async throws {
    JevFixtureProtocol.requests.withLock { $0 = [] }
    let provider = makeProvider()
    let result = try await provider.score(
      query: "保留修改", candidates: ["git reset --soft HEAD~1", "git revert HEAD"], authorization: .init(apiKey: "unit-test-key"))
    #expect(result.scores == [1.7, 0.2])
    #expect(result.inputTokens == 123)
    let requests = JevFixtureProtocol.requests.withLock { $0 }
    let request = try #require(requests.first)
    #expect(requests.count == 1)
    #expect(request.url?.absoluteString == "https://api.typesafe.ai/v1/systemone")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer unit-test-key")
    let body = try #require(try JSONSerialization.jsonObject(with: JevFixtureProtocol.body(request)) as? [String: Any])
    #expect(Set(body.keys) == ["state", "model", "questions"])
    let questions = try #require(body["questions"] as? [String: [String: Any]])
    let first = try #require(questions["candidate_0"]?["instructions"] as? [String: String])
    #expect(first["candidate"] == "git reset --soft HEAD~1")
    #expect(body["model"] as? String == "jev-1.13.0")
  }

  @Test(arguments: [DecisionModel.clef, .clefFlash])
  func cloudflareUsesTheSelectedAccountModelAndEnvelope(model: DecisionModel) async throws {
    JevFixtureProtocol.requests.withLock { $0 = [] }
    let account = String(repeating: "a", count: 32)
    let authorization = DecisionModelSettingsSource.Authorization(
      apiKey: "cloudflare-test-token", configuration: .init(model: model, accountID: account))
    let response = try await makeProvider().score(query: "query", candidates: ["one", "two"], authorization: authorization)
    #expect(response.model == model.rawValue)
    #expect(response.scores == [1.7, 0.2])
    let request = try #require(JevFixtureProtocol.requests.withLock { $0.first })
    #expect(request.url?.absoluteString == "https://api.cloudflare.com/client/v4/accounts/\(account)/ai/run/@cf/cloudflare/\(model.rawValue)")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cloudflare-test-token")
    let body = try #require(try JSONSerialization.jsonObject(with: JevFixtureProtocol.body(request)) as? [String: Any])
    #expect(body["model"] as? String == model.rawValue)
    #expect(body["images"] == nil)
    for data in [
      "{\"success\":false,\"errors\":[],\"result\":null}",
      "{\"success\":true,\"errors\":[],\"result\":\(JevFixtureProtocol.response)}",
    ] {
      #expect(throws: DecisionRequestError.self) {
        try DecisionScoreClient.decode(Data(data.utf8), questionIDs: ["candidate_0", "candidate_1"], model: model)
      }
    }
  }

  @Test(arguments: [401, 403, 429, 529, 422, 500, 302])
  func errorsDoNotRetryOrExposeResponseBodies(status: Int) async throws {
    JevFixtureProtocol.requests.withLock { $0 = [] }
    let provider = makeProvider(status: status)
    let expected: RecordRankingError =
      switch status {
      case 401, 403: .unauthorized
      case 429, 529: .rateLimited
      default: .unavailable
      }
    await #expect(throws: expected) {
      try await provider.score(query: "query", candidates: ["text"], authorization: .init(apiKey: "unit-test-key"))
    }
    #expect(JevFixtureProtocol.requests.withLock { $0.count } == 1)
  }

  @Test func malformedScoresAndOversizedInputsFailClosed() async throws {
    let valid = JevFixtureProtocol.response
    for mutation in ["\"score\":1.7", "\"confidence\":0.5", "\"input_tokens\":123", "jev-1.13.0"] {
      let invalid = valid.replacingOccurrences(of: mutation, with: mutation == "jev-1.13.0" ? "other-model" : mutation.components(separatedBy: ":")[0] + ":-10")
      #expect(throws: RecordRankingError.invalidResponse) {
        try DecisionRecordRankingProvider.decode(Data(invalid.utf8), count: 2)
      }
    }
    #expect(throws: RecordRankingError.invalidResponse) {
      try DecisionRecordRankingProvider.decode(Data(valid.utf8), count: 1)
    }
    JevFixtureProtocol.requests.withLock { $0 = [] }
    await #expect(throws: RecordRankingError.invalidInput) {
      try await makeProvider().score(query: "q", candidates: [String(repeating: "中", count: 1_000)], authorization: .init(apiKey: "unit-test-key"))
    }
    await #expect(throws: RecordRankingError.invalidInput) {
      try await makeProvider().score(query: "q", candidates: ["text"], authorization: .init(apiKey: "unit-test-key\r\nX: injected"))
    }
    #expect(JevFixtureProtocol.requests.withLock { $0.isEmpty })
  }

  @Test func cancellationBeforeSendMakesNoRequest() async throws {
    JevFixtureProtocol.requests.withLock { $0 = [] }
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await makeProvider().score(query: "q", candidates: ["text"], authorization: .init(apiKey: "unit-test-key"))
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(JevFixtureProtocol.requests.withLock { $0.isEmpty })
  }

  private func makeProvider(status: Int = 200) -> DecisionRecordRankingProvider {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [JevFixtureProtocol.self]
    configuration.httpAdditionalHeaders = ["X-Test-Status": "\(status)"]
    return DecisionRecordRankingProvider(session: URLSession(configuration: configuration))
  }
}

private final class JevFixtureProtocol: URLProtocol {
  static let requests = OSAllocatedUnfairLock(initialState: [URLRequest]())
  static let response =
    #"{"model":"jev-1.13.0","answers":{"candidate_1":{"type":"score","score":0.2,"confidence":0.5,"probabilities":{"0":0.8,"1":0.2,"2":0}},"candidate_0":{"type":"score","score":1.7,"confidence":0.5,"probabilities":{"0":0.1,"1":0.1,"2":0.8}}},"usage":{"input_tokens":123,"output_tokens":12}}"#
  override class func canInit(with _: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    var captured = request
    captured.httpBody = Self.body(request)
    Self.requests.withLock { [captured] in $0.append(captured) }
    let status = Int(request.value(forHTTPHeaderField: "X-Test-Status") ?? "200") ?? 200
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    var body = Self.response
    if request.url?.host == "api.cloudflare.com", let model = request.url?.lastPathComponent {
      body = "{\"success\":true,\"errors\":[],\"result\":\(body.replacingOccurrences(of: "jev-1.13.0", with: model))}"
    }
    client?.urlProtocol(self, didLoad: Data((status == 200 ? body : "untrusted credential echo").utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {
    // startLoading completes synchronously; this fixture has no pending work to cancel.
  }
  static func body(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }
      result.append(contentsOf: buffer.prefix(count))
    }
    return result
  }
}
