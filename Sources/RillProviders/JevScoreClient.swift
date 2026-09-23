import Foundation
import RillCore

enum JevRequestError: Error {
  case invalidInput, invalidResponse, unauthorized, rateLimited, unavailable
}

/// Shared fixed-destination Jev transport. No retries, redirects, cookies or content diagnostics.
struct JevScoreClient: Sendable {
  static let model = "jev-1.13.0"
  private let session: URLSession

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 45
    session = URLSession(configuration: configuration)
  }

  init(session: URLSession) { self.session = session }

  struct Question: Encodable, Sendable {
    let type = "score"
    let instructions: [String: String]
    let criteria: [String]
  }

  struct Request: Encodable, Sendable {
    let model = JevScoreClient.model
    let state: [String: String]
    let questions: [String: Question]
  }

  struct Response: Decodable, Sendable {
    let model: String
    let answers: [String: Answer]
    let usage: Usage

    struct Answer: Decodable, Sendable {
      let type: String
      let score: Double
      let confidence: Double
      let probabilities: [String: Double]
    }

    struct Usage: Decodable, Sendable {
      let inputTokens: Int
      let outputTokens: Int
      enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
      }
    }
  }

  func score(_ value: Request, apiKey: String) async throws -> Response {
    guard JevAPIKey.isValid(apiKey) else { throw JevRequestError.invalidInput }
    let body = try JSONEncoder().encode(value)
    guard body.count <= 30_000 else { throw JevRequestError.invalidInput }
    var request = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    try Task.checkCancellation()
    do {
      let (bytes, response) = try await session.bytes(for: request, delegate: NoJevRedirects())
      defer { bytes.task.cancel() }
      guard let http = response as? HTTPURLResponse else { throw JevRequestError.invalidResponse }
      switch http.statusCode {
      case 200: break
      case 401, 403: throw JevRequestError.unauthorized
      case 429, 529: throw JevRequestError.rateLimited
      default: throw JevRequestError.unavailable
      }
      var data = Data()
      for try await byte in bytes {
        guard data.count < 256 * 1_024 else { throw JevRequestError.invalidResponse }
        data.append(byte)
      }
      try Task.checkCancellation()
      return try Self.decode(data, questionIDs: Set(value.questions.keys))
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as JevRequestError {
      throw error
    } catch {
      try Task.checkCancellation()
      throw JevRequestError.unavailable
    }
  }

  static func decode(_ data: Data, questionIDs: Set<String>) throws -> Response {
    guard let value = try? JSONDecoder().decode(Response.self, from: data), value.model == model,
      Set(value.answers.keys) == questionIDs,
      (0...1_000_000).contains(value.usage.inputTokens), (0...1_000_000).contains(value.usage.outputTokens)
    else { throw JevRequestError.invalidResponse }
    for answer in value.answers.values {
      guard answer.type == "score", answer.score.isFinite, (0...2).contains(answer.score),
        answer.confidence.isFinite, (0...1).contains(answer.confidence),
        Set(answer.probabilities.keys) == ["0", "1", "2"],
        answer.probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
        abs(answer.probabilities.values.reduce(0, +) - 1) <= 0.01,
        let middle = answer.probabilities["1"], let high = answer.probabilities["2"],
        abs(answer.score - middle - 2 * high) <= 0.02
      else { throw JevRequestError.invalidResponse }
    }
    return value
  }
}

private final class NoJevRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(_: URLSession, task _: URLSessionTask,
    willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}
