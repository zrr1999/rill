import Foundation
import RillCore

public struct SelectionCaptureRecognizer: SpeechRecognizer {
    public enum RecognizerError: Error, LocalizedError, Equatable {
        case missingSelection
        case clipboardExcludedFromWorkflowCapture

        public var errorDescription: String? {
            switch self {
            case .missingSelection:
                return "Copy something or select text before running this workflow."
            case .clipboardExcludedFromWorkflowCapture:
                return "The current clipboard item is managed by Rill and excluded from workflow capture. Select text or copy fresh content first."
            }
        }
    }

    public let id = "context.selection"

    public init() {}

    public func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        try Task.checkCancellation()
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
