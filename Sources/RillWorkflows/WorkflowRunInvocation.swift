import Foundation
import RillCore

/// The source semantics bound to one authorized workflow context.
///
/// This type deliberately does not conform to `Codable`. In particular, a
/// Record invocation carries only an exact immutable Record/Membership
/// coordinate, never the stored payload itself.
public enum RecordWorkflowOperation: String, Sendable, Equatable {
    case replay
    case replace
}

public enum WorkflowRunInvocation: Sendable, Equatable {
    case capture
    case record(
        subject: RecordDeliverySubject,
        operation: RecordWorkflowOperation
    )

    var usesWorkflowRecognizer: Bool {
        if case .capture = self { return true }
        return false
    }

    var isSupportedRecordWorkflowOperation: Bool {
        switch self {
        case .capture:
            return false
        case .record:
            return true
        }
    }

    var recordSubject: RecordDeliverySubject? {
        guard case .record(let subject, _) = self else { return nil }
        return subject
    }

    func authorizesRecord(
        _ currentSubject: RecordDeliverySubject,
        requestedOperation: RecordWorkflowOperation
    ) -> Bool {
        guard case .record(let authorizedSubject, let authorizedOperation) = self,
              isSupportedRecordWorkflowOperation else {
            return false
        }
        return authorizedOperation == requestedOperation && authorizedSubject == currentSubject
    }
}
