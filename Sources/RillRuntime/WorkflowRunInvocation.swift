import Foundation
import RillCore

/// The source semantics bound to one authorized workflow context.
///
/// This type deliberately does not conform to `Codable`. In particular, a
/// clipboard invocation carries only `ClipboardItemDryRunSubject`, never the
/// stored payload itself.
public enum WorkflowRunInvocation: Sendable, Equatable {
    case capture
    case clipboardItem(
        subject: ClipboardItemDryRunSubject,
        operation: ClipboardItemDryRunOperation
    )

    var usesWorkflowRecognizer: Bool {
        if case .capture = self { return true }
        return false
    }

    var isSupportedClipboardWorkflowOperation: Bool {
        switch self {
        case .capture:
            return false
        case .clipboardItem(_, let operation):
            return operation == .replay || operation == .replace
        }
    }

    var clipboardItemSubject: ClipboardItemDryRunSubject? {
        guard case .clipboardItem(let subject, _) = self else { return nil }
        return subject
    }

    func authorizesClipboardItem(
        _ item: ClipboardHistoryItem,
        requestedItemID: UUID,
        replacingSourceItem: Bool
    ) -> Bool {
        guard case .clipboardItem(let authorizedSubject, let authorizedOperation) = self,
              isSupportedClipboardWorkflowOperation,
              authorizedSubject.contentKind == .text,
              authorizedSubject.hasTransferableContent,
              !authorizedSubject.excludesWorkflowCapture else {
            return false
        }
        let requestedOperation: ClipboardItemDryRunOperation = replacingSourceItem
            ? .replace
            : .replay
        let currentSubject = ClipboardItemDryRunSubject(
            itemID: item.id,
            itemVersion: item.version,
            groupID: item.groupID,
            contentKind: item.contentKind,
            captureTags: item.captureTags,
            hasTransferableContent: item.supportsDirectPaste
        )
        return item.id == requestedItemID
            && authorizedOperation == requestedOperation
            && authorizedSubject == currentSubject
    }
}
