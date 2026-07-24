import Foundation
import RillCore

extension DeliveryStack {
    /// Trusted compatibility mutation used by local storage tests and explicit
    /// non-workflow maintenance. Workflow actions must use the exact-subject
    /// overload below so a missing item is never recreated as a fallback.
    func replace(_ item: DeliveryItem, replacing itemID: UUID) async {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        let routeContext = ClipboardRouteContext(
            applicationName: item.sourceApplicationName,
            bundleIdentifier: item.sourceBundleIdentifier
        )
        let result = replaceWorkflowItem(
            id: itemID,
            workflowID: item.workflowID,
            workflow: item.workflow,
            text: item.text,
            captureTags: item.captureTags,
            alternatives: item.alternatives,
            context: routeContext,
            targetGroupID: item.targetGroupID
        )
        await publishStorageMutationResult(result)
    }

    public func replace(
        _ item: DeliveryItem,
        replacing subject: ClipboardItemDryRunSubject
    ) async -> ClipboardItemReplacementResult {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        let routeContext = ClipboardRouteContext(
            applicationName: item.sourceApplicationName,
            bundleIdentifier: item.sourceBundleIdentifier
        )
        let result = replaceWorkflowItem(
            matching: subject,
            workflowID: item.workflowID,
            workflow: item.workflow,
            text: item.text,
            captureTags: item.captureTags,
            alternatives: item.alternatives,
            context: routeContext,
            targetGroupID: item.targetGroupID
        )
        guard result == .replaced else {
            if case .storageRejected(let reason) = result {
                await publishStorageMutationResult(.rejected(reason))
            }
            return result
        }
        await publishAndSchedulePersistence()
        return result
    }

    public func popNext() async -> DeliveryItem? {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        guard let lease = beginLease(for: ClipboardRouteContext()) else {
            return nil
        }
        compatibilityLeaseIDsByItemID[lease.itemID] = lease.id
        if lease.consumesItem {
            await publishAndSchedulePersistence()
        }
        guard let item = itemsByID[lease.itemID] else {
            compatibilityLeaseIDsByItemID.removeValue(forKey: lease.itemID)
            pendingLeases.removeValue(forKey: lease.id)
            return nil
        }
        return deliveryItem(from: item, state: lease.consumesItem ? .delivering : .pending)
    }

    public func returnToFront(_ item: DeliveryItem, error: String? = nil) async {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        if let leaseID = compatibilityLeaseIDsByItemID.removeValue(forKey: item.id) {
            await failDelivery(leaseID: leaseID, error: error)
            return
        }

        let routeContext = ClipboardRouteContext(
            applicationName: item.sourceApplicationName,
            bundleIdentifier: item.sourceBundleIdentifier
        )
        let targetGroupID = itemsByID[item.id]?.groupID ?? storageGroupID(for: routeContext)
        let restored = ClipboardHistoryItem(
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
            latestError: ClipboardDeliveryFailureCode.sanitizedStoredValue(error),
            tags: tags(for: item.text)
        )
        let result = store(restored, inGroup: targetGroupID)
        await publishStorageMutationResult(result)
    }

    public func snapshot() async -> DeliveryStackSnapshot {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        let summary = summary(for: ClipboardGroup.defaultGroup.id)
        return DeliveryStackSnapshot(count: summary.count, topPreview: summary.previewText)
    }

    public func allItems() async -> [DeliveryItem] {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        return groupEntries[ClipboardGroup.defaultGroup.id, default: []].compactMap { itemID in
            guard let item = itemsByID[itemID] else { return nil }
            return deliveryItem(from: item, state: .pending)
        }
    }

    public func clipboardSnapshot() async -> ClipboardStoreSnapshot {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        return buildClipboardSnapshot()
    }

    func buildClipboardSnapshot() -> ClipboardStoreSnapshot {
        let remainingItemIDs = remainingClipboardItemIDs()
        return ClipboardStoreSnapshot(
            items: historyIDs.compactMap { itemsByID[$0] },
            groups: groupSummaries(),
            defaultGroup: summary(for: ClipboardGroup.defaultGroup.id),
            appAssignments: sortedAppAssignments(),
            remainingItemIDs: remainingItemIDs,
            persistenceAvailability: persistenceAvailability,
            storageLimits: storageLimits,
            lastStorageRejection: lastStorageRejection,
            storagePressureContext: storagePressureContext
        )
    }

    func remainingClipboardItemIDs() -> [UUID] {
        let remainingItemIDSet = Set(groupEntries.values.flatMap { $0 })
        return historyIDs.filter { remainingItemIDSet.contains($0) }
    }

    public func routeSnapshot(for context: ClipboardRouteContext) async -> ClipboardRouteSnapshot {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        let groupID = deliveryGroup(for: context)
        let summary = summary(for: groupID)
        let ids = groupEntries[groupID, default: []]
        let previewID = candidateItemID(in: ids, mode: currentMode(forGroup: groupID))
        let previewItem = previewID.flatMap { itemsByID[$0] }
        return ClipboardRouteSnapshot(
            activeGroup: summary,
            count: summary.count,
            previewText: summary.previewText,
            previewCaptureTags: previewItem?.captureTags ?? [],
            previewContentKind: previewItem?.contentKind,
            previewSnapshot: previewItem?.clipboardSnapshot,
            previewSubject: previewItem.map { dryRunSubject(for: $0) }
        )
    }

    public func beginDeliveryLease(for context: ClipboardRouteContext) async -> (leaseID: UUID, item: ClipboardHistoryItem)? {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        guard let lease = beginLease(for: context), let item = itemsByID[lease.itemID] else {
            return nil
        }
        if lease.consumesItem {
            await publishAndSchedulePersistence()
        }
        return (lease.id, item)
    }

    public func beginClipboardItemUseLease(
        matching subject: ClipboardItemDryRunSubject
    ) async throws -> ClipboardItemUseLease {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        guard let item = itemsByID[subject.itemID] else {
            throw ClipboardItemUseLeaseError.sourceUnavailable
        }
        guard dryRunSubject(for: item) == subject else {
            throw ClipboardItemUseLeaseError.sourceChanged
        }
        guard !pendingLeases.values.contains(where: { $0.itemID == item.id }) else {
            throw ClipboardItemUseLeaseError.alreadyInUse
        }

        let mode = currentMode(forGroup: item.groupID)
        let lease = DeliveryLease(
            id: UUID(),
            itemID: item.id,
            groupID: item.groupID,
            consumesItem: mode != .list
        )
        pendingLeases[lease.id] = lease
        if lease.consumesItem {
            remove(itemID: item.id, fromGroup: item.groupID)
            await publishAndSchedulePersistence()
        }
        return ClipboardItemUseLease(leaseID: lease.id, item: item)
    }

    public func completeDelivery(leaseID: UUID) async {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        guard let lease = pendingLeases.removeValue(forKey: leaseID), var item = itemsByID[lease.itemID] else {
            return
        }

        item.latestError = nil
        item.lastUsedAt = Date()
        item.useCount += 1
        item.advanceVersion()
        itemsByID[item.id] = item
        refreshEncodedItemByteCount(for: item)
        compatibilityLeaseIDsByItemID.removeValue(forKey: item.id)
        trimHistoryIfNeeded()
        await publishAndSchedulePersistence()
    }

    public func failDelivery(leaseID: UUID, error: String?) async {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        guard let lease = pendingLeases.removeValue(forKey: leaseID), var item = itemsByID[lease.itemID] else {
            return
        }

        if lease.consumesItem {
            place(itemID: item.id, intoGroup: lease.groupID)
        }

        item.latestError = ClipboardDeliveryFailureCode.sanitizedStoredValue(error)
        item.advanceVersion()
        itemsByID[item.id] = item
        refreshEncodedItemByteCount(for: item)
        compatibilityLeaseIDsByItemID.removeValue(forKey: item.id)
        trimHistoryIfNeeded()
        await publishAndSchedulePersistence()
    }

}
