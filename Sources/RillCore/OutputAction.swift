import Foundation

public protocol OutputAction: Sendable {
    var id: String { get }
    func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult
}

public enum OutputActionPayloadError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedPayload(actionID: String, payloadKind: RecordPayloadKind)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPayload(let actionID, let payloadKind):
            "Action \(actionID) does not support \(payloadKind.rawValue) records."
        }
    }
}

public extension OutputAction {
    func execute(text: String, context: ActionContext) async throws -> ActionResult {
        let draft = RecordDraft(
            payload: .text(text),
            provenance: RecordProvenance(
                source: RecordSourceIdentity(kind: .workflow),
                sourceApplicationName: context.contextSnapshot.focus.applicationName,
                sourceBundleIdentifier: context.contextSnapshot.focus.bundleIdentifier,
                workflowID: context.workflow.id,
                workflowRunID: context.runID,
                workflow: context.workflow.presentation
            )
        )
        return try await execute(record: draft, context: context)
    }
}

public extension RecordDraft {
    func requireText(for actionID: String) throws -> String {
        guard case .text(let text) = payload else {
            throw OutputActionPayloadError.unsupportedPayload(
                actionID: actionID, payloadKind: payload.kind
            )
        }
        return text
    }
}

/// A failure is retry-safe only when the adapter proves no output was applied.
/// Absence of this evidence (including old receipts) means the outcome is unknown.
public enum OutputFailureDisposition: String, Codable, Sendable, Equatable {
    case notApplied
    case unknown
}

public protocol OutputFailureDescribing: Error {
    var outputFailureDisposition: OutputFailureDisposition { get }
}

extension OutputActionPayloadError: OutputFailureDescribing {
    public var outputFailureDisposition: OutputFailureDisposition { .notApplied }
}

extension WorkflowActionConfigurationError: OutputFailureDescribing {
    public var outputFailureDisposition: OutputFailureDisposition { .notApplied }
}
