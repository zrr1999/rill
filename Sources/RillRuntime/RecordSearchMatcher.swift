import Foundation
import RillCore

struct RecordSearchMatcher: Sendable {
  let keywords: [String]
  let words: [String]
  let canApproximate: Bool

  init(_ query: RecordQuery) {
    let text = Self.fold(query.text).trimmingCharacters(in: .whitespacesAndNewlines)
    keywords = text.split(whereSeparator: \.isWhitespace).map(String.init)
    words = Self.words(text)
    let isIdentifier = text.contains("://") || text.hasPrefix("/")
      || (!text.contains(" ") && text.range(of: "[0-9]{3,}", options: .regularExpression) != nil)
    canApproximate = query.matching == .approximate && !isIdentifier
      && !words.isEmpty && words.count <= 8 && text.utf8.count <= 160
      && text.unicodeScalars.allSatisfy(\.isASCII)
  }

  func matchesLiteral(_ text: String, metadata: String) -> Bool {
    keywords.allSatisfy { text.contains($0) || metadata.contains($0) }
  }

  func matches(_ content: RecordSearchDocument, metadata: RecordSearchDocument) -> Bool {
    if matchesLiteral(content.text, metadata: metadata.text) { return true }
    guard canApproximate else { return false }
    return words.allSatisfy { word in
      if word.contains(where: \.isNumber) {
        return [content.approximation, metadata.approximation].compactMap { $0 }
          .contains { $0.words.contains(word) }
      }
      if content.text.contains(word) || metadata.text.contains(word) { return true }
      return [content.approximation, metadata.approximation].compactMap { $0 }.contains { text in
        text.words.contains { Self.isNear(word, $0) }
          || (3...40).contains(word.count) && text.pinyin.contains { $0.matches(word) }
      }
    }
  }

  static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }

  static func words(_ text: String) -> [String] {
    Array(Set(text.split { character in
      guard let byte = character.asciiValue else { return true }
      return !(97...122).contains(byte) && !(48...57).contains(byte)
    }.map(String.init)))
  }

  static func isNear(_ query: String, _ word: String) -> Bool {
    if word.hasPrefix(query) { return true }
    let needle = Array(query.utf8), haystack = Array(word.utf8)
    if needle.count >= 2, needle.first == haystack.first,
      (needle.count...(needle.count * 3)).contains(haystack.count)
    {
      var index = 0
      for byte in haystack where index < needle.count {
        if byte == needle[index] { index += 1 }
      }
      if index == needle.count { return true }
    }
    guard needle.count >= 4, !word.contains(where: \.isNumber) else { return false }
    let maximum = min(2, needle.count / 4)
    guard abs(needle.count - haystack.count) <= maximum else { return false }
    var previous = Array(0...haystack.count), beforePrevious = previous
    for i in 1...needle.count {
      var row = [i] + Array(repeating: 0, count: haystack.count)
      for j in 1...haystack.count {
        row[j] = min(row[j - 1] + 1, previous[j] + 1,
          previous[j - 1] + (needle[i - 1] == haystack[j - 1] ? 0 : 1))
        if i > 1, j > 1, needle[i - 1] == haystack[j - 2], needle[i - 2] == haystack[j - 1] {
          row[j] = min(row[j], beforePrevious[j - 2] + 1)
        }
      }
      beforePrevious = previous
      previous = row
    }
    return previous[haystack.count] <= maximum
  }
}

struct RecordSearchDocument: Sendable {
  let text: String
  var approximation: RecordSearchApproximation?

  init(_ text: String) { self.text = RecordSearchMatcher.fold(text) }

  var byteCount: Int { text.utf8.count + (approximation?.byteCount ?? 0) }

  @concurrent
  func preparingApproximation() async throws -> Self {
    guard approximation == nil else { return self }
    var prepared = self
    prepared.approximation = try RecordSearchApproximation(text)
    return prepared
  }
}

struct RecordSearchApproximation: Sendable {
  let words: [String]
  let pinyin: [RomanizedSearchRun]
  var byteCount: Int {
    words.reduce(0) { $0 + $1.utf8.count }
      + pinyin.reduce(0) { $0 + $1.byteCount }
  }

  init(_ text: String) throws {
    try Task.checkCancellation()
    words = RecordSearchMatcher.words(text)
    var runs: [RomanizedSearchRun] = []
    var buffer = ""
    func appendRun() throws {
      try Task.checkCancellation()
      if !buffer.isEmpty { runs.append(RomanizedSearchRun(buffer)) }
    }
    for scalar in text.unicodeScalars {
      if (0x3400...0x9FFF).contains(scalar.value) {
        buffer.unicodeScalars.append(scalar)
        if buffer.unicodeScalars.count == 512 {
          try appendRun()
          // Query pinyin is capped at 40 letters; retain overlap across chunks.
          buffer = String(buffer.suffix(40))
        }
      } else if !buffer.isEmpty {
        try appendRun()
        buffer = ""
      }
    }
    try appendRun()
    pinyin = runs
  }
}

struct RomanizedSearchRun: Sendable {
  let full: String
  let initials: String
  let boundaries: Set<Int>
  var byteCount: Int { full.utf8.count + initials.utf8.count + boundaries.count * MemoryLayout<Int>.size }

  init(_ text: String) {
    let latin = RecordSearchMatcher.fold(text.applyingTransform(.toLatin, reverse: false) ?? text)
    let syllables = latin.split(whereSeparator: \.isWhitespace)
    full = syllables.joined()
    initials = String(syllables.compactMap(\.first))
    var offsets: Set<Int> = [0], offset = 0
    for syllable in syllables {
      offset += syllable.utf8.count
      offsets.insert(offset)
    }
    boundaries = offsets
  }

  func matches(_ query: String) -> Bool {
    if initials.contains(query) { return true }
    var start = full.startIndex
    while start < full.endIndex, let range = full.range(of: query, range: start..<full.endIndex) {
      let lower = full.utf8.distance(from: full.startIndex, to: range.lowerBound)
      let upper = lower + query.utf8.count
      if boundaries.contains(lower), boundaries.contains(upper) { return true }
      start = full.index(after: range.lowerBound)
    }
    return false
  }
}
