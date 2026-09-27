import Foundation
import Testing

@testable import RillKnowledge

struct TypingVocabularyTests {
  @Test func collectionRequiresBothOptInAndApplicationPermission() {
    var library = TypingVocabularyState()
    library.observe("Rill", application: "editor", now: Date())
    #expect(library.suggestions.isEmpty)
    library.enabled = true
    library.observe("Rill", application: "editor", now: Date())
    #expect(library.suggestions.isEmpty)
    library.allowedApplications = ["editor"]
    library.observe("Rill", application: "editor", now: Date())
    #expect(library.suggestions.map(\.phrase) == ["Rill"])
    #expect(library.suggestions[0].status == .pending)
    #expect(library.suggestions[0].confirmedRuleID == nil)
  }

  @Test func observationsAggregateTermsWithoutRetainingTheTranscript() throws {
    var library = TypingVocabularyState()
    library.enabled = true
    library.allowedApplications = ["editor"]
    let text = "Rill supports SQLite and InputMethodKit."
    library.observe(text, application: "editor", now: Date())
    library.observe("Rill", application: "editor", now: Date())
    #expect(library.suggestions.first { $0.phrase == "Rill" }?.count == 2)
    #expect(library.suggestions.contains { $0.phrase == "InputMethodKit" })
    #expect(!String(decoding: try JSONEncoder().encode(library), as: UTF8.self).contains(text))
  }

  @Test func ignoredSuggestionsDoNotRefreshTheirRetention() throws {
    var library = TypingVocabularyState()
    let start = Date(timeIntervalSince1970: 100)
    library.enabled = true
    library.allowedApplications = ["editor"]
    library.observe("Rill", application: "editor", now: start)
    library.suggestions[0].status = .ignored
    library.observe("Rill", application: "editor", now: start.addingTimeInterval(24 * 60 * 60))
    #expect(library.suggestions[0].lastSeen == start)
    #expect(library.suggestions[0].count == 1)
    library.expire(at: start.addingTimeInterval(31 * 24 * 60 * 60))
    #expect(library.suggestions.isEmpty)
  }

  @Test func confirmedProvenanceSurvivesPendingRetention() throws {
    var library = TypingVocabularyState()
    let start = Date(timeIntervalSince1970: 100)
    library.enabled = true
    library.allowedApplications = ["editor"]
    library.observe("Rill", application: "editor", now: start)
    library.suggestions[0].status = .confirmed
    library.suggestions[0].confirmedRuleID = UUID()
    library.expire(at: start.addingTimeInterval(31 * 24 * 60 * 60))
    let restored = try JSONDecoder().decode(
      TypingVocabularyState.self, from: JSONEncoder().encode(library))
    #expect(restored == library)
    #expect(restored.suggestions.count == 1)
  }
}
