import Foundation
import NaturalLanguage

public struct TypingVocabularySuggestion: Codable, Identifiable, Sendable, Equatable {
  public enum Status: String, Codable, Sendable { case pending, ignored, confirmed }
  public var id: UUID = UUID()
  public var phrase: String
  public var count: Int = 1
  public var applications: Set<String>
  public var lastSeen: Date
  public var status: Status = .pending
  public var confirmedRuleID: UUID?
  public var ownsConfirmedRule: Bool = false
}

public struct TypingVocabularyState: Codable, Sendable, Equatable {
  public var version = 1
  public var enabled = false
  public var allowedApplications: Set<String> = []
  public var suggestions: [TypingVocabularySuggestion] = []
  public init() {
    // Stored-property defaults define the fresh state for clients in other modules.
  }

  public mutating func expire(at now: Date) {
    let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
    suggestions.removeAll {
      $0.status != .confirmed && !$0.ownsConfirmedRule && $0.lastSeen < cutoff
    }
  }

  public mutating func observe(_ text: String, application: String, now: Date) {
    guard enabled, allowedApplications.contains(application), text.utf8.count <= 2_048 else {
      return
    }
    expire(at: now)
    for phrase in Self.terms(in: text) {
      if let index = suggestions.firstIndex(where: { $0.phrase == phrase }) {
        if suggestions[index].status == .pending {
          suggestions[index].count = min(suggestions[index].count + 1, 1_000_000)
          suggestions[index].applications.insert(application)
          suggestions[index].lastSeen = now
        }
      } else if suggestions.count < 1_000 {
        suggestions.append(
          TypingVocabularySuggestion(phrase: phrase, applications: [application], lastSeen: now))
      }
    }
  }

  public static func terms(in text: String) -> [String] {
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    var terms: Set<String> = []
    let stopwords: Set<String> = [
      "这个", "那个", "我们", "你们", "他们", "可以", "但是", "因为", "所以", "就是", "the", "and", "that", "with",
      "this",
    ]
    func insert(_ phrase: String) {
      guard (2...24).contains(phrase.count), phrase.utf8.count <= 96,
        phrase.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || $0 == "-" }),
        !stopwords.contains(phrase.lowercased())
      else { return }
      terms.insert(phrase.precomposedStringWithCanonicalMapping)
    }
    // Preserve short committed names that the system tokenizer may split incorrectly.
    if text.count <= 6 { insert(text) }
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
      insert(String(text[range]))
      return terms.count < 32
    }
    return terms.sorted()
  }
}
