import Foundation
import Testing
@testable import RillCore

struct HotwordRankingTests {
  private let uncertain = HotwordRankingScore(score: 1, confidence: 1, probabilities: [0, 1, 0])
  private let relevant = HotwordRankingScore(score: 2, confidence: 1, probabilities: [0, 0, 1])

  @Test func promotionRespectsManualPriorityAndStableFallbackOrder() throws {
    let candidates = [
      HotwordCandidate(id: UUID(), term: "Manual", priority: 10),
      HotwordCandidate(id: UUID(), term: "Rill", priority: 0),
      HotwordCandidate(id: UUID(), term: "MLX", priority: 0),
      HotwordCandidate(id: UUID(), term: "Spore", priority: 0),
    ]
    #expect(try HotwordRankingPolicy.ranked(candidates, scores: [uncertain, uncertain, uncertain, relevant])
      == ["Manual", "Spore", "Rill", "MLX"])
  }

  @Test func lowConfidenceAndAmbiguousRelevanceNeverPromote() throws {
    let candidates = ["Rill", "Spore"].map { HotwordCandidate(id: UUID(), term: $0, priority: 0) }
    for score in [
      HotwordRankingScore(score: 2, confidence: 0.89, probabilities: [0, 0, 1]),
      HotwordRankingScore(score: 1.89, confidence: 1, probabilities: [0, 0.11, 0.89]),
    ] {
      #expect(try HotwordRankingPolicy.ranked(candidates, scores: [uncertain, score]) == ["Rill", "Spore"])
    }
    #expect(throws: HotwordRankingError.invalidResponse) {
      try HotwordRankingPolicy.ranked(candidates, scores: [relevant])
    }
    #expect(throws: HotwordRankingError.invalidResponse) {
      try HotwordRankingPolicy.ranked(candidates, scores: [
        .init(score: .nan, confidence: 1, probabilities: [0, 0, 1]), relevant,
      ])
    }
  }

  @Test func candidatesShareValidationDeduplicationAndFiftyTermCapWithHints() {
    var rules = (0..<60).map { index in
      VocabularyRule(kind: .hotword, pattern: "term-\(index)", replacement: "", priority: 100 - index)
    }
    rules += [
      .init(kind: .hotword, pattern: "term-0", replacement: "", priority: -1),
      .init(kind: .hotword, enabled: false, pattern: "disabled", replacement: ""),
      .init(kind: .hotword, pattern: "wrong-app", replacement: "", scope: .init(bundleIdentifier: "other")),
      .init(kind: .hotword, pattern: "bad\nterm", replacement: ""),
      .init(kind: .mapping, pattern: "mapping", replacement: "not-a-hotword"),
    ]
    let result = VocabularyRecognitionHintResolver().resolve(rules: rules)
    #expect(result.candidates.count == 50)
    #expect(result.candidates.map(\.term) == result.hints.keyterms)
    #expect(result.candidates.first?.id == rules.first?.id)
    #expect(result.candidates.first?.priority == 100)
    #expect(result.validKeytermCount == 60)
    #expect(result.omittedKeytermCount == 10)
    #expect(result.rejectedKeytermCount == 1)
  }

  @Test func oversizedSelectionIsOmittedWithoutTruncatingMeaning() {
    let allowed = String(repeating: "中", count: 600)
    #expect(HotwordRankingRequest(application: "", workflow: "", selectedText: allowed,
      candidates: []).selectedText == allowed)
    #expect(HotwordRankingRequest(application: "", workflow: "", selectedText: allowed + "文",
      candidates: []).selectedText.isEmpty)
  }
}
