import Foundation

public struct TextRange: Codable, Sendable, Equatable {
    public var lowerBound: Int
    public var upperBound: Int

    public init(lowerBound: Int, upperBound: Int) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public func range(in text: String) -> Range<String.Index>? {
        guard lowerBound >= 0, upperBound >= lowerBound else { return nil }
        guard let start = text.index(text.startIndex, offsetBy: lowerBound, limitedBy: text.endIndex),
              let end = text.index(text.startIndex, offsetBy: upperBound, limitedBy: text.endIndex),
              start <= end else {
            return nil
        }
        return start..<end
    }
}

public enum CandidateSource: String, Codable, Sendable, Equatable {
    case asr
    case llm
    case heuristic
    case user
}

public struct Candidate: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var text: String
    public var confidence: Double
    public var source: CandidateSource

    public init(
        id: UUID = UUID(),
        text: String,
        confidence: Double,
        source: CandidateSource
    ) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.source = source
    }
}

public struct CandidateSet: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var surfaceText: String
    public var range: TextRange
    public var candidates: [Candidate]

    public init(
        id: UUID = UUID(),
        surfaceText: String,
        range: TextRange,
        candidates: [Candidate]
    ) {
        self.id = id
        self.surfaceText = surfaceText
        self.range = range
        self.candidates = candidates.sorted { $0.confidence > $1.confidence }
    }

    public var defaultCandidate: Candidate? {
        candidates.max { $0.confidence < $1.confidence }
    }
}

public struct TextSpan: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var text: String
    public var range: TextRange
    public var confidence: Double

    public init(id: UUID = UUID(), text: String, range: TextRange, confidence: Double) {
        self.id = id
        self.text = text
        self.range = range
        self.confidence = confidence
    }
}

public struct RecognitionResult: Codable, Sendable, Equatable {
    public var rawText: String
    public var bestText: String
    public var spans: [TextSpan]
    public var candidateSets: [CandidateSet]
    public var metadata: [String: String]
    public var audioDigest: String?
    public var processingDurationMillis: Int?
    public var isFinal: Bool

    public init(
        rawText: String,
        bestText: String,
        spans: [TextSpan] = [],
        candidateSets: [CandidateSet] = [],
        metadata: [String: String] = [:],
        audioDigest: String? = nil,
        processingDurationMillis: Int? = nil,
        isFinal: Bool = true
    ) {
        self.rawText = rawText
        self.bestText = bestText
        self.spans = spans
        self.candidateSets = candidateSets
        self.metadata = metadata
        self.audioDigest = audioDigest
        self.processingDurationMillis = processingDurationMillis
        self.isFinal = isFinal
    }

    public var requiresResolution: Bool {
        !candidateSets.isEmpty
    }

    public func applyingSelections(_ selections: [UUID: UUID]) -> RecognitionResult {
        guard requiresResolution else { return self }
        var updatedText = bestText
        let orderedSets = candidateSets.sorted { $0.range.lowerBound > $1.range.lowerBound }

        for set in orderedSets {
            let chosen = set.candidates.first(where: { $0.id == selections[set.id] })
                ?? set.defaultCandidate
            guard let chosen else { continue }
            guard let range = set.range.range(in: updatedText) else { continue }
            updatedText.replaceSubrange(range, with: chosen.text)
        }

        var copy = self
        copy.bestText = updatedText
        copy.candidateSets = []
        return copy
    }
}

public struct CandidateResolutionCase: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var runID: UUID
    public var recognitionResult: RecognitionResult
    public var policy: UncertaintyPolicy
    public var requestedAt: Date

    public init(
        id: UUID = UUID(),
        runID: UUID,
        recognitionResult: RecognitionResult,
        policy: UncertaintyPolicy,
        requestedAt: Date = Date()
    ) {
        self.id = id
        self.runID = runID
        self.recognitionResult = recognitionResult
        self.policy = policy
        self.requestedAt = requestedAt
    }

    public func defaultSelections() -> [UUID: UUID] {
        var selections: [UUID: UUID] = [:]
        for set in recognitionResult.candidateSets {
            if let candidate = set.defaultCandidate {
                selections[set.id] = candidate.id
            }
        }
        return selections
    }
}
