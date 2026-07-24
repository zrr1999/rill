import Foundation

/// A fixed, content-free failure reported only after an output side effect is
/// known to have committed. These failures must never be generalized into a
/// retry prompt because repeating the action can duplicate user-visible output.
public enum CommittedOutputFailure: String, Error, LocalizedError, Sendable, Equatable, CaseIterable {
    case clipboardRestorationFailedAfterInjection

    public var message: String {
        switch self {
        case .clipboardRestorationFailedAfterInjection:
            return "The content was inserted, but the previous clipboard contents could not be restored. Do not repeat the injection; copy the clipboard content you need again."
        }
    }

    public var errorDescription: String? { message }
}

/// Converts untrusted runtime failures into a small, content-free set of
/// messages that are safe to retain in local run history.
public enum HistoryFailureSanitizer {
    public static let genericMessage =
        "The workflow failed. Open Diagnostics for a safe summary, then retry."
    public static let noSpeechMessage = "No speech was detected. Please try again."
    public static let globalInputUnavailableMessage =
        "Voice recording stopped because global keyboard input became unavailable."
    public static let microphoneInputUnavailableMessage =
        "Voice recording stopped because microphone input became unavailable. Please try again."
    public static let recognitionTimeoutMessage =
        "Speech recognition took too long. This run was stopped; please try again."
    public static let recognitionRecoveryPendingMessage =
        "The previous recognition operation is still finishing. Please wait a moment or switch recognition engines."

    public static func sanitize(_ message: String?) -> String? {
        guard let message else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return genericMessage }

        for failure in CommittedOutputFailure.allCases
        where trimmed == failure.message {
            return failure.message
        }

        if trimmed == noSpeechMessage {
            return noSpeechMessage
        }
        if trimmed == globalInputUnavailableMessage {
            return globalInputUnavailableMessage
        }
        if trimmed == microphoneInputUnavailableMessage {
            return microphoneInputUnavailableMessage
        }
        if trimmed == recognitionTimeoutMessage {
            return recognitionTimeoutMessage
        }
        if trimmed == recognitionRecoveryPendingMessage {
            return recognitionRecoveryPendingMessage
        }

        let normalized = trimmed.lowercased()

        if normalized.contains("deepgram") &&
            (normalized.contains("api key") || normalized.contains("api_key")) {
            return "The Deepgram API key is unavailable. Open Settings, save a key, and retry."
        }
        if normalized.contains("deepgram") &&
            (normalized.contains("url") || normalized.contains("endpoint") || normalized.contains("https")) {
            return "The Deepgram endpoint configuration is invalid. Open Settings and retry."
        }
        if normalized.contains("microphone") &&
            (normalized.contains("permission") || normalized.contains("access") || normalized.contains("denied")) {
            return "Microphone access is required. Grant access in System Settings and retry."
        }
        if normalized.contains("accessibility") &&
            (normalized.contains("permission") || normalized.contains("access") || normalized.contains("denied")) {
            return "Accessibility access is required for direct text insertion. Grant access and retry."
        }
        if normalized.contains("privacy") &&
            (normalized.contains("block") || normalized.contains("declin") || normalized.contains("approval")) {
            return "The run was blocked by the current privacy policy. Review Privacy settings and retry."
        }

        return genericMessage
    }
}

public enum HistoryRecordSanitizer {
    public static func sanitize(_ record: HistoryRecord) -> HistoryRecord {
        HistoryRecord(
            id: record.id,
            runID: record.runID,
            workflowID: record.workflowID,
            workflow: record.workflow,
            finalText: record.finalText,
            failureMessage: HistoryFailureSanitizer.sanitize(record.failureMessage),
            timestamp: record.timestamp,
            isStackRelated: record.isStackRelated,
            outcome: record.outcome,
            correctionSource: record.correctionSource,
            trigger: record.trigger
        )
    }
}
