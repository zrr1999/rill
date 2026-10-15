import Foundation
import RillCore

enum DecisionRequestError: Error {
  case invalidInput, invalidResponse, unauthorized, rateLimited, unavailable
}

/// Shared transport to the selected classification service. No retries, redirects, cookies or content diagnostics.
struct DecisionScoreClient: Sendable {
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
    var model = DecisionModel.jev.modelID
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

  func score(_ value: Request, authorization: DecisionModelSettingsSource.Authorization) async throws -> Response {
    let apiKey = authorization.apiKey
    guard JevAPIKey.isValid(apiKey), let endpoint = authorization.configuration.endpoint else {
      throw DecisionRequestError.invalidInput
    }
    var value = value
    value.model = authorization.configuration.model.modelID
    let body = try JSONEncoder().encode(value)
    guard body.count <= 30_000 else { throw DecisionRequestError.invalidInput }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    try Task.checkCancellation()
    do {
      let (bytes, response) = try await session.bytes(for: request, delegate: NoDecisionRedirects())
      defer { bytes.task.cancel() }
      guard let http = response as? HTTPURLResponse else { throw DecisionRequestError.invalidResponse }
      switch http.statusCode {
      case 200: break
      case 401, 403: throw DecisionRequestError.unauthorized
      case 429, 529: throw DecisionRequestError.rateLimited
      default: throw DecisionRequestError.unavailable
      }
      var data = Data()
      for try await byte in bytes {
        guard data.count < 256 * 1_024 else { throw DecisionRequestError.invalidResponse }
        data.append(byte)
      }
      try Task.checkCancellation()
      return try Self.decode(data, questionIDs: Set(value.questions.keys), model: authorization.configuration.model)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as DecisionRequestError {
      throw error
    } catch {
      try Task.checkCancellation()
      throw DecisionRequestError.unavailable
    }
  }

  private struct CloudflareResponse: Decodable {
    let success: Bool
    let result: Response?
    let errors: [CloudflareError]
    struct CloudflareError: Decodable { let code: Int }
  }

  static func decode(_ data: Data, questionIDs: Set<String>, model: DecisionModel = .jev) throws -> Response {
    let value: Response
    do {
      if model == .jev {
        value = try JSONDecoder().decode(Response.self, from: data)
      } else {
        let envelope = try JSONDecoder().decode(CloudflareResponse.self, from: data)
        guard envelope.success, envelope.errors.isEmpty, let result = envelope.result else {
          throw DecisionRequestError.invalidResponse
        }
        value = result
      }
    } catch { throw DecisionRequestError.invalidResponse }
    guard value.model == model.modelID,
      Set(value.answers.keys) == questionIDs,
      (0...1_000_000).contains(value.usage.inputTokens), (0...1_000_000).contains(value.usage.outputTokens)
    else { throw DecisionRequestError.invalidResponse }
    for answer in value.answers.values {
      guard answer.type == "score", answer.score.isFinite, (0...2).contains(answer.score),
        answer.confidence.isFinite, (0...1).contains(answer.confidence),
        Set(answer.probabilities.keys) == ["0", "1", "2"],
        answer.probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
        abs(answer.probabilities.values.reduce(0, +) - 1) <= 0.01,
        let middle = answer.probabilities["1"], let high = answer.probabilities["2"],
        abs(answer.score - middle - 2 * high) <= 0.02
      else { throw DecisionRequestError.invalidResponse }
    }
    return value
  }
}

private final class NoDecisionRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _: URLSession, task _: URLSessionTask,
    willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
