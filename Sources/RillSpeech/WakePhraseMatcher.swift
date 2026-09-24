import RillSpeechContracts
import Foundation

struct WakePhraseMatch: Sendable, Equatable {
  let phrase: String
  let command: String?
}

/// Matches a configured wake phrase only at the beginning of a local ASR
/// transcript. Matching ignores punctuation, symbols, whitespace, case, width,
/// and diacritics, but deliberately does not use fuzzy or phonetic guessing.
enum WakePhraseMatcher {
  private struct ComparableText {
    var scalars: [Unicode.Scalar]
    var sourceEnds: [String.Index]
  }

  static func match(
    transcript: String,
    phrases: [String]
  ) -> WakePhraseMatch? {
    let comparableTranscript = comparableText(transcript)
    guard !comparableTranscript.scalars.isEmpty else { return nil }

    for phrase in phrases {
      let comparablePhrase = comparableText(phrase)
      guard !comparablePhrase.scalars.isEmpty,
        comparableTranscript.scalars.starts(with: comparablePhrase.scalars)
      else {
        continue
      }

      let matchedCount = comparablePhrase.scalars.count
      if matchedCount < comparableTranscript.scalars.count,
        let phraseLast = comparablePhrase.scalars.last,
        isLatinWordScalar(phraseLast),
        isLatinWordScalar(comparableTranscript.scalars[matchedCount]),
        !hasSourceBoundary(
          in: transcript,
          after: comparableTranscript.sourceEnds[matchedCount - 1]
        )
      {
        continue
      }

      let sourceEnd = comparableTranscript.sourceEnds[matchedCount - 1]
      let remainder = commandRemainder(
        in: transcript,
        after: sourceEnd
      )
      return WakePhraseMatch(
        phrase: phrase,
        command: remainder.isEmpty ? nil : remainder
      )
    }
    return nil
  }

  private static func comparableText(_ value: String) -> ComparableText {
    var result = ComparableText(scalars: [], sourceEnds: [])
    var index = value.startIndex
    while index < value.endIndex {
      let next = value.index(after: index)
      let normalized = String(value[index..<next])
        .precomposedStringWithCompatibilityMapping
        .folding(
          options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
          locale: Locale(identifier: "en_US_POSIX")
        )
      for scalar in normalized.unicodeScalars where !isIgnored(scalar) {
        result.scalars.append(scalar)
        result.sourceEnds.append(next)
      }
      index = next
    }
    return result
  }

  private static func isIgnored(_ scalar: Unicode.Scalar) -> Bool {
    ignoredBoundaryCharacters.contains(scalar)
  }

  private static func isLatinWordScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 48...57, 65...90, 97...122:
      true
    default:
      false
    }
  }

  private static func hasSourceBoundary(
    in value: String,
    after start: String.Index
  ) -> Bool {
    guard start < value.endIndex else { return true }
    let next = value.index(after: start)
    let scalars = String(value[start..<next])
      .precomposedStringWithCompatibilityMapping
      .unicodeScalars
    return scalars.allSatisfy(isIgnored)
  }

  private static func commandRemainder(
    in value: String,
    after start: String.Index
  ) -> String {
    var commandStart = start
    while commandStart < value.endIndex {
      let next = value.index(after: commandStart)
      let scalars = String(value[commandStart..<next])
        .precomposedStringWithCompatibilityMapping
        .unicodeScalars
      guard scalars.allSatisfy(isIgnored) else { break }
      commandStart = next
    }
    return String(value[commandStart...])
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static let ignoredBoundaryCharacters =
    CharacterSet.whitespacesAndNewlines
    .union(.punctuationCharacters)
    .union(.symbols)
}
