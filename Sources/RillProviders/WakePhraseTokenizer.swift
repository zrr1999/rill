import Foundation
import RillCore

public struct EncodedWakePhrase: Equatable, Sendable {
    /// Short open-vocabulary phrases need a little more contextual bias than
    /// sherpa-onnx's corpus examples, which are generally longer proper names.
    /// Keep the override on each keyword so multiple configured phrases use
    /// the same reviewed operating point regardless of spotter defaults.
    public static let keywordBoostingScore: Float = 1.5
    public static let keywordTriggerThreshold: Float = 0.12

    public let phrase: String
    public let tokens: [String]

    public init(phrase: String, tokens: [String]) {
        self.phrase = phrase
        self.tokens = tokens
    }

    public var keywordDefinition: String {
        let label = phrase.replacingOccurrences(of: " ", with: "_")
        return "\(tokens.joined(separator: " ")) "
            + ":\(Self.keywordBoostingScore) "
            + "#\(Self.keywordTriggerThreshold) "
            + "@\(label)"
    }
}

public enum WakePhraseTokenizerError: Error, LocalizedError, Sendable, Equatable {
    case unreadableTokens
    case unreadableEnglishLexicon
    case invalidPhrase
    case unsupportedCharacter
    case unknownEnglishWord(String)
    case unsupportedPinyin(String)
    case tokenCountOutOfRange

    public var errorDescription: String? {
        switch self {
        case .unreadableTokens:
            return "The wake-word token vocabulary is unavailable."
        case .unreadableEnglishLexicon:
            return "The wake-word English lexicon is unavailable."
        case .invalidPhrase:
            return "The wake phrase is invalid."
        case .unsupportedCharacter:
            return "The wake phrase contains unsupported characters."
        case .unknownEnglishWord(let word):
            return "The wake phrase contains an unsupported English word: \(word)."
        case .unsupportedPinyin(let pinyin):
            return "The wake phrase contains unsupported Mandarin pronunciation: \(pinyin)."
        case .tokenCountOutOfRange:
            return "The wake phrase pronunciation must contain between 4 and 32 tokens."
        }
    }
}

public struct WakePhraseTokenizer: Sendable {
    public static let minimumTokenCount = 4
    public static let maximumTokenCount = 32

    private let tokenVocabulary: Set<String>
    private let pinyinTokensByLength: [String]
    private let englishLexicon: [String: [String]]

    public init(tokensURL: URL, englishLexiconURL: URL) throws {
        guard let tokensText = try? String(contentsOf: tokensURL, encoding: .utf8) else {
            throw WakePhraseTokenizerError.unreadableTokens
        }
        guard let lexiconText = try? String(
            contentsOf: englishLexiconURL,
            encoding: .utf8
        ) else {
            throw WakePhraseTokenizerError.unreadableEnglishLexicon
        }
        self.init(tokensText: tokensText, englishLexiconText: lexiconText)
    }

    public init(tokensText: String, englishLexiconText: String) {
        let vocabulary = Set(
            tokensText.split(whereSeparator: \.isNewline).compactMap { line in
                line.split(whereSeparator: \.isWhitespace).first.map(String.init)
            }
        )
        tokenVocabulary = vocabulary
        pinyinTokensByLength = vocabulary
            .filter {
                !$0.isEmpty
                    && $0.unicodeScalars.allSatisfy {
                        CharacterSet.alphanumerics.contains($0) || $0 == "v"
                    }
            }
            .sorted {
                if $0.count == $1.count {
                    return $0 < $1
                }
                return $0.count > $1.count
            }
        var lexicon: [String: [String]] = [:]
        for line in englishLexiconText.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2 else { continue }
            let rawWord = fields[0]
            let word = rawWord
                .replacingOccurrences(
                    of: #"\(\d+\)$"#,
                    with: "",
                    options: .regularExpression
                )
                .uppercased()
            if lexicon[word] == nil {
                lexicon[word] = Array(fields.dropFirst())
            }
        }
        englishLexicon = lexicon
    }

    public func encode(_ phrase: String) throws -> EncodedWakePhrase {
        let normalized = WakeWordConfiguration.normalizedPhrase(phrase)
        guard !normalized.isEmpty else {
            throw WakePhraseTokenizerError.invalidPhrase
        }
        let runs = try lexicalRuns(in: normalized)
        var tokens: [String] = []
        for run in runs {
            switch run.kind {
            case .mandarin:
                tokens.append(contentsOf: try encodeMandarin(run.text))
            case .english:
                let word = run.text.uppercased()
                guard let phonemes = englishLexicon[word],
                    phonemes.allSatisfy(tokenVocabulary.contains)
                else {
                    throw WakePhraseTokenizerError.unknownEnglishWord(run.text)
                }
                tokens.append(contentsOf: phonemes)
            }
        }
        guard
            (Self.minimumTokenCount...Self.maximumTokenCount).contains(tokens.count)
        else {
            throw WakePhraseTokenizerError.tokenCountOutOfRange
        }
        return EncodedWakePhrase(phrase: normalized, tokens: tokens)
    }

    public func encode(_ configuration: WakeWordConfiguration) throws -> [EncodedWakePhrase] {
        try configuration.validatedPhrases().flatMap { phrase in
            let encoded = try encode(phrase)
            return [encoded] + curatedPronunciationVariants(for: encoded)
        }
    }

    /// The bilingual 3M KWS model often decodes Mandarin-accented
    /// `Hey Rill` as `HH IY1 R IY1 L` even when a larger ASR model transcribes
    /// the utterance exactly. Keep that observed model-space pronunciation
    /// alongside the CMU lexicon form. This is deliberately limited to Rill's
    /// reviewed default phrase; arbitrary English phrases never receive a
    /// guessed approximation.
    private func curatedPronunciationVariants(
        for encoded: EncodedWakePhrase
    ) -> [EncodedWakePhrase] {
        guard encoded.phrase.caseInsensitiveCompare("Hey Rill") == .orderedSame else {
            return []
        }
        let mandarinAccentedTokens = ["HH", "IY1", "R", "IY1", "L"]
        guard mandarinAccentedTokens.allSatisfy(tokenVocabulary.contains) else {
            return []
        }
        return [
            EncodedWakePhrase(
                phrase: encoded.phrase,
                tokens: mandarinAccentedTokens
            )
        ]
    }

    private enum RunKind {
        case mandarin
        case english
    }

    private struct LexicalRun {
        let kind: RunKind
        let text: String
    }

    private func lexicalRuns(in phrase: String) throws -> [LexicalRun] {
        var runs: [LexicalRun] = []
        var activeKind: RunKind?
        var activeText = ""

        func flush() {
            guard let activeKind, !activeText.isEmpty else { return }
            runs.append(LexicalRun(kind: activeKind, text: activeText))
            activeText = ""
        }

        for scalar in phrase.unicodeScalars {
            let kind: RunKind?
            if Self.isHan(scalar) {
                kind = .mandarin
            } else if CharacterSet.letters.contains(scalar), scalar.isASCII {
                kind = .english
            } else if scalar == "'" {
                kind = activeKind == .english ? .english : nil
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
            {
                flush()
                activeKind = nil
                continue
            } else {
                throw WakePhraseTokenizerError.unsupportedCharacter
            }

            guard let kind else {
                throw WakePhraseTokenizerError.unsupportedCharacter
            }
            if let current = activeKind, current != kind {
                flush()
            }
            activeKind = kind
            activeText.unicodeScalars.append(scalar)
        }
        flush()
        guard !runs.isEmpty else {
            throw WakePhraseTokenizerError.invalidPhrase
        }
        return runs
    }

    private func encodeMandarin(_ text: String) throws -> [String] {
        guard let transformed = text.applyingTransform(.mandarinToLatin, reverse: false) else {
            throw WakePhraseTokenizerError.unsupportedPinyin(text)
        }
        let syllables = transformed
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .map(String.init)
        guard !syllables.isEmpty else {
            throw WakePhraseTokenizerError.unsupportedPinyin(text)
        }
        return try syllables.flatMap(splitPinyinSyllable)
    }

    private func splitPinyinSyllable(_ syllable: String) throws -> [String] {
        // Foundation already returns tone-mark pinyin (`nǐ hǎo`). The
        // bilingual phone+ppinyin model uses those marked finals directly
        // (`n ǐ h ǎo`), not numbered syllables (`ni3 hao3`).
        let normalized = syllable
            .precomposedStringWithCanonicalMapping
            .lowercased()
        var remainder = normalized[...]
        var result: [String] = []
        while !remainder.isEmpty {
            guard
                let token = pinyinTokensByLength.first(where: {
                    remainder.hasPrefix($0)
                })
            else {
                throw WakePhraseTokenizerError.unsupportedPinyin(syllable)
            }
            result.append(token)
            remainder.removeFirst(token.count)
        }
        return result
    }

    private static func isHan(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}

private extension UnicodeScalar {
    var isASCII: Bool { value <= 0x7F }
}
