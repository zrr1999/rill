import Foundation
import RillCore

extension DeliveryStack {
    public func item(id: UUID) async -> ClipboardHistoryItem? {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        return itemsByID[id]
    }

    /// Returns the content-free exact identity used by preview and
    /// authorization. Clipboard payloads never leave this actor for planning.
    public func clipboardItemDryRunSubject(
        itemID: UUID
    ) async -> ClipboardItemDryRunSubject? {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        guard let item = itemsByID[itemID] else { return nil }
        return dryRunSubject(for: item)
    }

    /// Atomically resolves a payload only when the exact item incarnation and
    /// metadata still match the previously prepared subject.
    public func item(
        matching subject: ClipboardItemDryRunSubject
    ) async -> ClipboardHistoryItem? {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        guard let item = itemsByID[subject.itemID], dryRunSubject(for: item) == subject else {
            return nil
        }
        return item
    }

    public func matchesClipboardItemDryRunSubject(
        _ subject: ClipboardItemDryRunSubject
    ) async -> Bool {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        guard let item = itemsByID[subject.itemID] else { return false }
        return dryRunSubject(for: item) == subject
    }

    func dryRunSubject(
        for item: ClipboardHistoryItem
    ) -> ClipboardItemDryRunSubject {
        ClipboardItemDryRunSubject(
            itemID: item.id,
            itemVersion: item.version,
            groupID: item.groupID,
            contentKind: item.contentKind,
            captureTags: item.captureTags,
            hasTransferableContent: item.supportsDirectPaste
        )
    }

    public func markUsed(itemID: UUID) async {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        guard var item = itemsByID[itemID] else { return }
        let mode = currentMode(forGroup: item.groupID)
        if mode != .list {
            remove(itemID: itemID, fromGroup: item.groupID)
        }
        item.latestError = nil
        item.lastUsedAt = Date()
        item.useCount += 1
        item.advanceVersion()
        itemsByID[itemID] = item
        refreshEncodedItemByteCount(for: item)
        trimHistoryIfNeeded()
        await publishAndSchedulePersistence()
    }

    @discardableResult
    public func updateItemText(
        _ itemID: UUID,
        text: String,
        captureTags: [ClipboardCaptureTag]
    ) async -> ClipboardStorageMutationResult {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        guard var item = itemsByID[itemID] else {
            return .accepted(evictedHistoryItemCount: 0)
        }
        item.text = text
        item.captureTags = captureTags
        item.tags = tags(for: text)
        let result = store(item, inGroup: item.groupID)
        await publishStorageMutationResult(result)
        return result
    }

    @discardableResult
    public func updateItemTags(
        _ itemID: UUID,
        tags: [String]
    ) async -> ClipboardStorageMutationResult {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        guard var item = itemsByID[itemID] else {
            return .accepted(evictedHistoryItemCount: 0)
        }
        var seenTags: Set<String> = []
        item.tags = tags.compactMap { tag in
            let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seenTags.insert(normalized).inserted else { return nil }
            return normalized
        }
        let result = store(item, inGroup: item.groupID)
        await publishStorageMutationResult(result)
        return result
    }

    /// Atomically updates the retention policy for one or more clipboard
    /// items. Pinning is presentation/history policy only: it does not reorder
    /// history or make an item active in a Stack / Queue / List.
    @discardableResult
    public func setItemsPinned(
        _ isPinned: Bool,
        itemIDs: [UUID]
    ) async -> ClipboardStorageMutationResult {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()

        let targetIDs = Set(itemIDs)
        guard !targetIDs.isEmpty else {
            return .accepted(evictedHistoryItemCount: 0)
        }
        guard rawOversizedLegacyItemIDs.isEmpty else {
            return await rejectItemsPinnedMutation(.itemTooLarge)
        }

        var projectedItemsByID: [UUID: ClipboardHistoryItem] = [:]
        var projectedByteCountsByID: [UUID: Int] = [:]
        for itemID in targetIDs {
            guard var item = itemsByID[itemID], item.isPinned != isPinned else {
                continue
            }
            item.isPinned = isPinned
            item.advanceVersion()

            let encodedByteCount: Int
            do {
                encodedByteCount = try accountedEncodedItemByteCount(for: item)
            } catch {
                return await rejectItemsPinnedMutation(.itemEncodingFailed)
            }
            if let rejection = itemStorageRejectionReason(
                for: item,
                encodedItemByteCount: encodedByteCount
            ) {
                return await rejectItemsPinnedMutation(rejection)
            }
            projectedItemsByID[itemID] = item
            projectedByteCountsByID[itemID] = encodedByteCount
        }

        guard !projectedItemsByID.isEmpty else {
            return .accepted(evictedHistoryItemCount: 0)
        }

        var projectedTotalByteCount = 0
        for itemID in historyIDs {
            let byteCount: Int
            if let projectedByteCount = projectedByteCountsByID[itemID] {
                byteCount = projectedByteCount
            } else if let existingByteCount = encodedItemByteCountsByID[itemID] {
                byteCount = existingByteCount
            } else if let item = itemsByID[itemID],
                      let computedByteCount = try? accountedEncodedItemByteCount(for: item) {
                byteCount = computedByteCount
            } else {
                return await rejectItemsPinnedMutation(.itemEncodingFailed)
            }
            let (nextTotal, overflowed) = projectedTotalByteCount.addingReportingOverflow(
                byteCount
            )
            guard !overflowed else {
                return await rejectItemsPinnedMutation(.totalByteLimitReached)
            }
            projectedTotalByteCount = nextTotal
        }
        guard projectedTotalByteCount <= storageLimits.maximumTotalEncodedItemByteCount else {
            return await rejectItemsPinnedMutation(.totalByteLimitReached)
        }

        for (itemID, item) in projectedItemsByID {
            itemsByID[itemID] = item
            encodedItemByteCountsByID[itemID] = projectedByteCountsByID[itemID]
        }
        updateStoragePressureAfterCurrentStateChange()

        let result = ClipboardStorageMutationResult.accepted(evictedHistoryItemCount: 0)
        await publishStorageMutationResult(result)
        return result
    }

    private func rejectItemsPinnedMutation(
        _ reason: ClipboardStorageRejectionReason
    ) async -> ClipboardStorageMutationResult {
        recordStorageMutationRejection(reason)
        let result = ClipboardStorageMutationResult.rejected(reason)
        await publishStorageMutationResult(result)
        return result
    }

    public func deleteItem(id itemID: UUID) async {
        await ensureInitialized()
        await deleteItems(ids: [itemID])
    }

    public func deleteItems(ids itemIDs: [UUID]) async {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        let uniqueIDs = Set(itemIDs)
        guard !uniqueIDs.isEmpty else { return }

        var didDeleteAnyItem = false
        for itemID in uniqueIDs {
            guard let item = itemsByID.removeValue(forKey: itemID) else { continue }
            encodedItemByteCountsByID.removeValue(forKey: itemID)
            rawOversizedLegacyItemIDs.remove(itemID)
            blobReferencesByItemID.removeValue(forKey: itemID)
            didDeleteAnyItem = true
            remove(itemID: itemID, fromGroup: item.groupID)
            compatibilityLeaseIDsByItemID.removeValue(forKey: itemID)
            queueGroupEvent(kind: .itemRemoved, item: item)
        }

        guard didDeleteAnyItem else { return }

        historyIDs.removeAll { uniqueIDs.contains($0) }
        pendingLeases = pendingLeases.filter { !uniqueIDs.contains($0.value.itemID) }
        trimHistoryIfNeeded()
        await publishAndSchedulePersistence()
    }

    @discardableResult
    public func createGroup(named name: String) async -> ClipboardGroupCreationResult {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        guard name.utf8.count <= storageLimits.maximumGroupNameUTF8ByteCount else {
            recordStorageMutationRejection(.metadataLimitReached)
            await publishStorageMutationResult(.rejected(.metadataLimitReached))
            return .rejected(.metadataLimitReached)
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = ClipboardGroup(name: trimmedName.isEmpty ? "New Group" : trimmedName)
        let projectedGroups = groupOrder.compactMap { groupID in
            guard !ClipboardGroup.reservedGroupIDs.contains(groupID) else { return nil }
            return groupsByID[groupID]
        } + [group]
        if let rejection = metadataStorageRejectionReason(
            groups: projectedGroups,
            appAssignments: Array(appAssignments.values)
        ) {
            recordStorageMutationRejection(rejection)
            await publishStorageMutationResult(.rejected(rejection))
            return .rejected(rejection)
        }
        groupsByID[group.id] = group
        groupOrder.append(group.id)
        groupEntries[group.id] = []
        await publishAndSchedulePersistence()
        return .created(group)
    }

    @discardableResult
    public func createGroup(
        named name: String,
        assigning assignment: ClipboardAppAssignment
    ) async -> ClipboardGroupCreationResult {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        guard name.utf8.count <= storageLimits.maximumGroupNameUTF8ByteCount else {
            recordStorageMutationRejection(.metadataLimitReached)
            await publishStorageMutationResult(.rejected(.metadataLimitReached))
            return .rejected(.metadataLimitReached)
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = ClipboardGroup(name: trimmedName.isEmpty ? "New Group" : trimmedName)
        let projectedGroups = groupOrder.compactMap { groupID in
            guard !ClipboardGroup.reservedGroupIDs.contains(groupID) else { return nil }
            return groupsByID[groupID]
        } + [group]
        let projectedAssignment = ClipboardAppAssignment(
            bundleIdentifier: assignment.bundleIdentifier,
            applicationName: assignment.applicationName,
            groupID: group.id
        )
        let projectedAssignments = appAssignments.values.filter {
            $0.bundleIdentifier != assignment.bundleIdentifier
        } + [projectedAssignment]
        if let rejection = metadataStorageRejectionReason(
            groups: projectedGroups,
            appAssignments: projectedAssignments
        ) {
            recordStorageMutationRejection(rejection)
            await publishStorageMutationResult(.rejected(rejection))
            return .rejected(rejection)
        }
        let movePlan: ApplicationAssignmentMovePlan
        switch applicationAssignmentMovePlan(
            forBundleIdentifier: assignment.bundleIdentifier,
            toGroup: group.id
        ) {
        case .success(let plan):
            movePlan = plan
        case .failure(let reason):
            recordStorageMutationRejection(reason)
            await publishStorageMutationResult(.rejected(reason))
            return .rejected(reason)
        }

        groupsByID[group.id] = group
        groupOrder.append(group.id)
        groupEntries[group.id] = []
        appAssignments[assignment.bundleIdentifier] = ClipboardAppAssignment(
            bundleIdentifier: assignment.bundleIdentifier,
            applicationName: assignment.applicationName,
            groupID: group.id
        )
        applyApplicationAssignmentMovePlan(movePlan)

        await publishAndSchedulePersistence()
        return .created(group)
    }

    public func setMode(_ mode: ClipboardPasteMode, forGroup groupID: UUID) async {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        ensureGroupExists(id: groupID)
        groupsByID[groupID]?.mode = mode
        await publishAndSchedulePersistence()
    }

    public func setAllowsCrossGroupPaste(_ allowsCrossGroupPaste: Bool, forGroup groupID: UUID) async {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        ensureGroupExists(id: groupID)
        let existingPriority = groupsByID[groupID]?.fallbackPriority
        let fallbackPriority = allowsCrossGroupPaste
            ? (existingPriority ?? nextAvailableFallbackPriority())
            : nil
        groupsByID[groupID]?.allowsCrossGroupPaste = allowsCrossGroupPaste
        if allowsCrossGroupPaste {
            groupsByID[groupID]?.fallbackPriority = fallbackPriority
        } else {
            groupsByID[groupID]?.fallbackPriority = nil
        }
        await publishAndSchedulePersistence()
    }

    @discardableResult
    public func setFallbackPriority(_ fallbackPriority: Int, forGroup groupID: UUID) async -> Bool {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        ensureGroupExists(id: groupID)
        guard fallbackPriority > 0,
              isFallbackPriorityAvailable(fallbackPriority, excluding: groupID) else {
            return false
        }
        groupsByID[groupID]?.allowsCrossGroupPaste = true
        groupsByID[groupID]?.fallbackPriority = fallbackPriority
        await publishAndSchedulePersistence()
        return true
    }

    @discardableResult
    public func assignApplication(
        bundleIdentifier: String,
        applicationName: String,
        toGroup groupID: UUID?
    ) async -> ClipboardStorageMutationResult {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        let projectedAssignment = ClipboardAppAssignment(
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            groupID: groupID
        )
        let projectedAssignments = appAssignments.values.filter {
            $0.bundleIdentifier != bundleIdentifier
        } + [projectedAssignment]
        if let rejection = metadataStorageRejectionReason(
            groups: groupOrder.compactMap { currentGroupID in
                guard !ClipboardGroup.reservedGroupIDs.contains(currentGroupID) else { return nil }
                return groupsByID[currentGroupID]
            },
            appAssignments: projectedAssignments
        ) {
            recordStorageMutationRejection(rejection)
            let result = ClipboardStorageMutationResult.rejected(rejection)
            await publishStorageMutationResult(result)
            return result
        }
        let movePlan: ApplicationAssignmentMovePlan
        switch applicationAssignmentMovePlan(
            forBundleIdentifier: bundleIdentifier,
            toGroup: groupID
        ) {
        case .success(let plan):
            movePlan = plan
        case .failure(let reason):
            recordStorageMutationRejection(reason)
            let result = ClipboardStorageMutationResult.rejected(reason)
            await publishStorageMutationResult(result)
            return result
        }
        if let groupID {
            ensureGroupExists(id: groupID)
        }
        appAssignments[bundleIdentifier] = ClipboardAppAssignment(
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            groupID: groupID
        )
        applyApplicationAssignmentMovePlan(movePlan)
        await publishAndSchedulePersistence()
        return .accepted(evictedHistoryItemCount: 0)
    }

    private func recordStorageMutationRejection(
        _ reason: ClipboardStorageRejectionReason
    ) {
        lastStorageRejection = reason
        if !hasLegacyOverCapacityState && !hasPersistedStateCapacityRejection {
            storagePressureContext = .mutationRejected
        }
    }

}
