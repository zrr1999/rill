import Foundation
import RillCore

public enum ClipboardItemDryRunPreparationError: Error, Sendable, Equatable {
    case itemUnavailable
    case itemChanged
}

/// A short-lived, content-free preview correlated with the exact stored item.
///
/// This value is advisory. It is neither Codable nor an execution capability.
public struct PreparedClipboardItemDryRun: Sendable, Equatable {
    public let subject: ClipboardItemDryRunSubject
    public let receipt: ClipboardItemDryRunReceipt

    public init(
        subject: ClipboardItemDryRunSubject,
        receipt: ClipboardItemDryRunReceipt
    ) {
        self.subject = subject
        self.receipt = receipt
    }
}

/// Runtime-owned orchestration for clipboard preview.
///
/// DeliveryStack resolves the exact subject, PrivacyRunGate performs the same
/// invocation-aware classification as live authorization without confirming or
/// granting authority, and ClipboardItemDryRunService remains the pure planner.
public struct ClipboardItemDryRunPreparer: Sendable {
    private let deliveryStack: DeliveryStack
    private let planner: ClipboardItemDryRunService
    private let privacyRunGate: PrivacyRunGate
    private let privacyContextProvider: @Sendable () async -> ContextSnapshot

    public init(
        deliveryStack: DeliveryStack,
        planner: ClipboardItemDryRunService = ClipboardItemDryRunService(),
        privacyRunGate: PrivacyRunGate,
        privacyContextProvider: @escaping @Sendable () async -> ContextSnapshot
    ) {
        self.deliveryStack = deliveryStack
        self.planner = planner
        self.privacyRunGate = privacyRunGate
        self.privacyContextProvider = privacyContextProvider
    }

    public func preview(
        itemID: UUID,
        operation: ClipboardItemDryRunOperation,
        workflow: WorkflowDefinition?
    ) async throws -> PreparedClipboardItemDryRun {
        guard let subject = await deliveryStack.clipboardItemDryRunSubject(itemID: itemID) else {
            throw ClipboardItemDryRunPreparationError.itemUnavailable
        }

        let receipt: ClipboardItemDryRunReceipt
        switch operation {
        case .use:
            receipt = planner.preview(subject: subject, operation: operation)
        case .replay, .replace:
            let privacyEvaluation: PrivacyRunEvaluation?
            if let workflow,
               subject.contentKind == .text,
               subject.hasTransferableContent,
               !subject.excludesWorkflowCapture {
                let context = await privacyContextProvider()
                privacyEvaluation = await privacyRunGate.evaluate(
                    context: context,
                    workflow: workflow,
                    invocation: .clipboardItem(subject: subject, operation: operation)
                )
            } else {
                privacyEvaluation = nil
            }
            receipt = planner.preview(
                subject: subject,
                operation: operation,
                workflow: workflow,
                privacyEvaluation: privacyEvaluation
            )
        }

        guard await deliveryStack.matchesClipboardItemDryRunSubject(subject) else {
            throw ClipboardItemDryRunPreparationError.itemChanged
        }
        return PreparedClipboardItemDryRun(subject: subject, receipt: receipt)
    }
}
