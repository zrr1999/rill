import Foundation

/// A bounded, ephemeral projection of the recording's applicable vocabulary.
public struct CorrectionVocabularyReference: Encodable, Sendable, Equatable {
    public static let maximumEncodedBytes = 12_000
    public let terms: [String]
    public let eligibleCount: Int
    public let encodedByteCount: Int

    private enum CodingKeys: String, CodingKey { case terms }

    public init(terms: [String]) throws {
        let encoder = JSONEncoder()
        let disallowed = CharacterSet.controlCharacters.union(.newlines)
        var selected: [String] = []
        var seen: Set<String> = []
        var eligible = 0
        var bytes = Data(#"{"terms":[]}"#.utf8).count
        for term in terms {
            let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty,
                  !term.unicodeScalars.contains(where: { disallowed.contains($0) }),
                  seen.insert(term).inserted else { continue }
            eligible += 1
            guard term.utf8.count <= Self.maximumEncodedBytes else { continue }
            let addition = try encoder.encode(term).count + (selected.isEmpty ? 0 : 1)
            guard bytes + addition <= Self.maximumEncodedBytes else { continue }
            selected.append(term)
            bytes += addition
        }
        self.terms = selected
        eligibleCount = eligible
        encodedByteCount = bytes
    }

    public var receipt: VocabularyReferenceReceipt {
        .init(status: terms.isEmpty ? .unavailable : .ready, eligibleCount: eligibleCount,
              includedCount: terms.count, omittedCount: eligibleCount - terms.count,
              encodedByteCount: encodedByteCount)
    }
}

/// Content-free history; it never contains the reference terms or an encoded request.
public struct VocabularyReferenceReceipt: Codable, Sendable, Equatable {
    public var status: CorrectionReferenceStatus
    public let eligibleCount: Int
    public let includedCount: Int
    public let omittedCount: Int
    public let encodedByteCount: Int
}
