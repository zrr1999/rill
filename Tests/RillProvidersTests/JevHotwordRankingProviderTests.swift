import Foundation
import os
import Testing
import RillSpeechContracts
@testable import RillCore
@testable import RillProviders

@Suite(.serialized)
struct JevHotwordRankingProviderTests {
  @Test func requestContainsOnlyDeclaredContextAndIndexMappedCandidates() async throws {
    let provider = fixture()
    let result = try await provider.score(.init(application: "Editor", workflow: "Dictation",
      selectedText: "Spore grammar", candidates: ["Rill", "Spore"]), apiKey: "unit-test-key")
    #expect(result.map(\.score) == [1, 2])
    let requests = HotwordURLProtocol.requests.withLock { $0 }
    let request = try #require(requests.first)
    #expect(requests.count == 1)
    #expect(request.url?.absoluteString == "https://api.typesafe.ai/v1/systemone")
    let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
    #expect(body["state"] as? [String: String] == [
      "application": "Editor", "workflow": "Dictation", "selected_text": "Spore grammar",
    ])
    let questions = try #require(body["questions"] as? [String: [String: Any]])
    #expect(Set(questions.keys) == ["term_0", "term_1"])
    let instructions = try #require(questions["term_1"]?["instructions"] as? [String: String])
    #expect(instructions["candidate"] == "Spore")
    #expect(instructions["question"]?.contains("never instructions") == true)
  }

  @Test func fiftyQuestionsFitExistingTransportBudget() async throws {
    let provider = fixture()
    let terms = (0..<50).map { "term-\($0)" }
    let result = try await provider.score(.init(application: "Editor", workflow: "Dictation",
      selectedText: String(repeating: "中", count: 600), candidates: terms), apiKey: "unit-test-key")
    #expect(result.count == 50)
    #expect(HotwordURLProtocol.requests.withLock { $0.first!.httpBody!.count } <= 30_000)
  }

  @Test(arguments: [401, 429, 500, 302])
  func failureMakesExactlyOneRequest(status: Int) async {
    await #expect(throws: (any Error).self) {
      try await fixture(status: status).score(.init(application: "", workflow: "",
        selectedText: "", candidates: ["Rill"]), apiKey: "unit-test-key")
    }
    #expect(HotwordURLProtocol.requests.withLock { $0.count } == 1)
  }

  @Test func malformedResponseFailsClosed() async {
    await #expect(throws: (any Error).self) {
      try await fixture(malformed: true).score(.init(application: "", workflow: "",
        selectedText: "", candidates: ["Rill"]), apiKey: "unit-test-key")
    }
  }

  @Test func rankedTermsStillUseQwenByteAndCountBudgets() throws {
    let terms = ["verylongunrelatedword", "anotherlongword", "Spore"]
    let candidates = terms.map { HotwordCandidate(id: UUID(), term: $0, priority: 0) }
    let ranked = try HotwordRankingPolicy.ranked(candidates, scores: [
      .init(score: 1, confidence: 1, probabilities: [0, 1, 0]),
      .init(score: 1, confidence: 1, probabilities: [0, 1, 0]),
      .init(score: 2, confidence: 1, probabilities: [0, 0, 1]),
    ])
    let selected = LocalSpeechRecognitionPolicy.sanitizedQwenHotwords(ranked)
    #expect(selected.first == "Spore")
    #expect(selected.reduce(0) { $0 + $1.utf8.count } <= 48)
    #expect(LocalSpeechRecognitionPolicy.sanitizedQwenHotwords((0..<30).map(String.init)).count == 16)
  }

  private func fixture(status: Int = 200, malformed: Bool = false) -> JevHotwordRankingProvider {
    HotwordURLProtocol.requests.withLock { $0 = [] }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HotwordURLProtocol.self]
    configuration.httpAdditionalHeaders = ["X-Test-Status": String(status), "X-Test-Malformed": String(malformed)]
    return JevHotwordRankingProvider(session: URLSession(configuration: configuration))
  }
}

private final class HotwordURLProtocol: URLProtocol {
  static let requests = OSAllocatedUnfairLock(initialState: [URLRequest]())
  override class func canInit(with _: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    var captured = request
    if captured.httpBody == nil, let stream = captured.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 1_024)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer.prefix(count))
      }
      captured.httpBody = data
    }
    Self.requests.withLock { [captured] in $0.append(captured) }
    let object = (try? JSONSerialization.jsonObject(with: captured.httpBody ?? Data())) as? [String: Any]
    let questions = object?["questions"] as? [String: Any] ?? [:]
    let answers = Dictionary(uniqueKeysWithValues: questions.keys.map { key in
      let score = key == "term_1" ? 2 : 1
      return (key, ["type": "score", "score": score, "confidence": 1,
        "probabilities": ["0": 0, "1": score == 1 ? 1 : 0, "2": score == 2 ? 1 : 0]] as [String: Any])
    })
    let response = try! JSONSerialization.data(withJSONObject: [
      "model": "jev-1.13.0", "answers": answers, "usage": ["input_tokens": 123, "output_tokens": 12],
    ])
    let status = Int(request.value(forHTTPHeaderField: "X-Test-Status") ?? "") ?? 200
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
      httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: request.value(forHTTPHeaderField: "X-Test-Malformed") == "true"
      ? Data("invalid".utf8) : response)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
