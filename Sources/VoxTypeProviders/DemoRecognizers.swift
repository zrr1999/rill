import Foundation
import VoxTypeCore

public struct DemoDirectRecognizer: SpeechRecognizer {
    public let id = "demo.direct"
    public init() {}

    public func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        try await Task.sleep(for: .milliseconds(120))
        return RecognitionResult(
            rawText: "hello from the new workflow runtime",
            bestText: "hello from the new workflow runtime"
        )
    }
}

public struct DemoAmbiguousRecognizer: SpeechRecognizer {
    public let id = "demo.ambiguous"
    public init() {}

    public func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        try await Task.sleep(for: .milliseconds(180))

        let baseText = "Send it to Jon tomorrow"
        guard let jonRange = baseText.range(of: "Jon") else {
            return RecognitionResult(rawText: baseText, bestText: baseText, metadata: ["provider": id])
        }
        let lower = baseText.distance(from: baseText.startIndex, to: jonRange.lowerBound)
        let upper = lower + "Jon".count

        let candidateSet = CandidateSet(
            surfaceText: "Jon",
            range: TextRange(lowerBound: lower, upperBound: upper),
            candidates: [
                Candidate(text: "Jon", confidence: 0.45, source: .asr),
                Candidate(text: "John", confidence: 0.43, source: .asr),
                Candidate(text: "Joan", confidence: 0.12, source: .heuristic),
            ]
        )

        return RecognitionResult(
            rawText: baseText,
            bestText: baseText,
            spans: [
                TextSpan(text: "Jon", range: candidateSet.range, confidence: 0.45),
            ],
            candidateSets: [candidateSet],
            metadata: ["provider": id]
        )
    }
}

public struct SelectionCaptureRecognizer: SpeechRecognizer {
    public enum RecognizerError: Error, LocalizedError, Equatable {
        case missingSelection
        case clipboardExcludedFromWorkflowCapture

        public var errorDescription: String? {
            switch self {
            case .missingSelection:
                return "Copy something or select text before running this workflow."
            case .clipboardExcludedFromWorkflowCapture:
                return "The current clipboard item is managed by VoxType and excluded from workflow capture. Select text or copy fresh content first."
            }
        }
    }

    public let id = "context.selection"

    public init() {}

    public func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        let selectedText = request.contextSnapshot.focus.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selectedText.isEmpty {
            return RecognitionResult(rawText: selectedText, bestText: selectedText)
        }

        let clipboard = request.contextSnapshot.clipboard
        let clipboardText = clipboard.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clipboardText.isEmpty else {
            throw RecognizerError.missingSelection
        }
        guard !clipboard.excludesWorkflowCapture else {
            throw RecognizerError.clipboardExcludedFromWorkflowCapture
        }
        return RecognitionResult(rawText: clipboardText, bestText: clipboardText)
    }
}
