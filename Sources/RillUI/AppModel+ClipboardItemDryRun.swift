import Foundation
import RillCore
import RillRuntime

extension AppModel {
    /// Requests a content-free advisory preview without retaining shared UI
    /// state. Each window or sheet owns its own task and result lifetime.
    public func previewClipboardItem(
        itemID: UUID,
        operation: ClipboardItemDryRunOperation,
        workflow: WorkflowDefinition?
    ) async throws -> PreparedClipboardItemDryRun {
        try await previewClipboardItemAction(itemID, operation, workflow)
    }
}
