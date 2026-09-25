import Foundation

public struct HotwordCandidate: Codable, Sendable, Equatable {
  public let id: UUID
  public let term: String
  public let priority: Int

  public init(id: UUID, term: String, priority: Int) {
    self.id = id
    self.term = term
    self.priority = priority
  }
}

/// Only these fields may cross the optional hotword-ranking network boundary.
public struct HotwordRankingRequest: Codable, Sendable, Equatable {
  public let application: String
  public let workflow: String
  public let selectedText: String
  public let candidates: [String]

  public init(application: String, workflow: String, selectedText: String, candidates: [String]) {
    self.application = application
    self.workflow = workflow
    self.selectedText = selectedText.utf8.count <= 1_800 ? selectedText : ""
    self.candidates = candidates
  }
}

public struct HotwordRankingScore: Sendable, Equatable {
  public let score: Double
  public let confidence: Double
  public let probabilities: [Double]

  public init(score: Double, confidence: Double, probabilities: [Double]) {
    self.score = score
    self.confidence = confidence
    self.probabilities = probabilities
  }

  public var isValid: Bool {
    score.isFinite && (0...2).contains(score)
      && confidence.isFinite && (0...1).contains(confidence)
      && probabilities.count == 3
      && probabilities.allSatisfy { $0.isFinite && (0...1).contains($0) }
      && abs(probabilities.reduce(0, +) - 1) <= 0.01
      && abs(score - probabilities[1] - 2 * probabilities[2]) <= 0.02
  }

  public var isClearlyRelevant: Bool {
    isValid && confidence >= 0.9 && probabilities[2] >= 0.9
  }
}

public protocol HotwordRankingProvider: Sendable {
  func score(_ request: HotwordRankingRequest, apiKey: String) async throws -> [HotwordRankingScore]
}

public enum HotwordRankingError: Error, Sendable, Equatable {
  case invalidInput, invalidResponse
}

public enum HotwordRankingPolicy {
  public static let version = 1

  /// Manual priorities are authoritative. Uncertain candidates retain their original order.
  public static func ranked(
    _ candidates: [HotwordCandidate], scores: [HotwordRankingScore]
  ) throws -> [String] {
    guard candidates.count == scores.count, scores.allSatisfy(\.isValid) else {
      throw HotwordRankingError.invalidResponse
    }
    return candidates.indices.sorted { left, right in
      if candidates[left].priority != candidates[right].priority {
        return candidates[left].priority > candidates[right].priority
      }
      let lhs = scores[left], rhs = scores[right]
      if lhs.isClearlyRelevant != rhs.isClearlyRelevant { return lhs.isClearlyRelevant }
      if lhs.isClearlyRelevant, lhs.score != rhs.score { return lhs.score > rhs.score }
      return left < right
    }.map { candidates[$0].term }
  }
}
