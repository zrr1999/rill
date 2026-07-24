import Foundation
import RillCore

extension DeliveryStack {
    @discardableResult
    public func push(_ item: DeliveryItem) async -> ClipboardStorageMutationResult {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        let routeContext = ClipboardRouteContext(
            applicationName: item.sourceApplicationName,
            bundleIdentifier: item.sourceBundleIdentifier
        )
        let targetGroupID = item.targetGroupID ?? storageGroupID(for: routeContext)
        let clipboardItem = ClipboardHistoryItem(
            id: item.id,
            groupID: targetGroupID,
            workflowID: item.workflowID,
            workflow: item.workflow,
            contentKind: .text,
            text: item.text,
            captureTags: item.captureTags,
            alternatives: item.alternatives,
            createdAt: item.createdAt,
            sourceKind: .rillWorkflow,
            sourceApplicationName: item.sourceApplicationName,
            sourceBundleIdentifier: item.sourceBundleIdentifier,
            latestError: item.latestError,
            tags: tags(for: item.text)
        )
        let result = store(clipboardItem, inGroup: targetGroupID)
        await publishStorageMutationResult(result)
        return result
    }

    @discardableResult
    public func captureSystemClipboard(
        snapshot: ClipboardSnapshot,
        context: ClipboardRouteContext,
        alternatives: [String] = [],
        disposition: ClipboardCaptureDisposition
    ) async -> ClipboardStorageMutationResult {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        if let reason = snapshot.captureStorageRejection {
            lastStorageRejection = reason
            if !hasLegacyOverCapacityState && !hasPersistedStateCapacityRejection {
                storagePressureContext = .mutationRejected
            }
            let result = ClipboardStorageMutationResult.rejected(reason)
            await publishStorageMutationResult(result)
            return result
        }
        guard snapshot.hasTransferableContent else {
            return .accepted(evictedHistoryItemCount: 0)
        }
        let targetGroupID = storageGroupID(for: context)
        let clipboardItem = systemClipboardItem(
            from: snapshot,
            groupID: targetGroupID,
            context: context,
            alternatives: alternatives
        )
        let result = store(
            clipboardItem,
            inGroup: targetGroupID,
            emitsGroupEvent: disposition == .historyAndWorkflows
        )
        await publishStorageMutationResult(result)
        return result
    }

    @discardableResult
    public func captureWorkflowClipboardCopy(
        text: String,
        workflowID: UUID,
        workflow: WorkflowPresentation,
        context: ClipboardRouteContext,
        alternatives: [String],
        captureTags: [ClipboardCaptureTag]
    ) async -> ClipboardStorageMutationResult {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        let targetGroupID = storageGroupID(for: context)
        let clipboardItem = ClipboardHistoryItem(
            groupID: targetGroupID,
            workflowID: workflowID,
            workflow: workflow,
            contentKind: .text,
            text: text,
            captureTags: captureTags,
            alternatives: alternatives,
            sourceKind: .rillWorkflow,
            sourceApplicationName: context.applicationName,
            sourceBundleIdentifier: context.bundleIdentifier,
            tags: tags(for: text)
        )
        let result = store(clipboardItem, inGroup: targetGroupID)
        await publishStorageMutationResult(result)
        return result
    }

    public func replaceWorkflowClipboardCopy(
        text: String,
        workflowID: UUID,
        workflow: WorkflowPresentation,
        context: ClipboardRouteContext,
        alternatives: [String],
        captureTags: [ClipboardCaptureTag],
        replacing subject: ClipboardItemDryRunSubject
    ) async -> ClipboardItemReplacementResult {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        let result = replaceWorkflowItem(
            matching: subject,
            workflowID: workflowID,
            workflow: workflow,
            text: text,
            captureTags: captureTags,
            alternatives: alternatives,
            context: context
        )
        guard result == .replaced else { return result }
        await publishAndSchedulePersistence()
        return result
    }

    func publishStorageMutationResult(_ result: ClipboardStorageMutationResult) async {
        switch result {
        case .accepted:
            await publishAndSchedulePersistence()
        case .rejected:
            await publishSnapshot()
            if let diagnostics {
                await diagnostics.record(
                    DiagnosticEvent(
                        subsystem: .clipboard,
                        level: .warning,
                        event: "clipboard.storage.rejected",
                        message: "Clipboard content was not retained because of the local storage budget."
                    )
                )
            }
        }
    }

}
