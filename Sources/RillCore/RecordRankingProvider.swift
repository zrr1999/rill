import Foundation

public enum RecordRankingError: Error, Sendable, Equatable {
  case invalidInput, missingKey, unauthorized, rateLimited, unavailable, invalidResponse
  case privacyBlocked, changed, busy
}

public struct RecordRankingResponse: Sendable, Equatable {
  public let scores: [Double]
  public let model: String
  public let inputTokens: Int
  public let outputTokens: Int

  public init(scores: [Double], model: String, inputTokens: Int, outputTokens: Int) {
    self.scores = scores
    self.model = model
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
  }
}

/// Scores are in candidate order, on a 0...2 relevance rubric, not correctness probabilities.
public protocol RecordRankingProvider: Sendable {
  func score(query: String, candidates: [String], apiKey: String) async throws -> RecordRankingResponse
}
