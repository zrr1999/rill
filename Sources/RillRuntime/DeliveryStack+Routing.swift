import Foundation
import RillCore

extension DeliveryStack {
    func beginLease(for context: ClipboardRouteContext) -> DeliveryLease? {
        let groupID = deliveryGroup(for: context)
        let ids = groupEntries[groupID, default: []]
        let mode = currentMode(forGroup: groupID)
        guard let nextItemID = candidateItemID(in: ids, mode: mode) else { return nil }
        guard !pendingLeases.values.contains(where: { $0.itemID == nextItemID }) else {
            return nil
        }

        let consumesItem = mode != .list
        let lease = DeliveryLease(
            id: UUID(),
            itemID: nextItemID,
            groupID: groupID,
            consumesItem: consumesItem
        )
        pendingLeases[lease.id] = lease
        if consumesItem {
            remove(itemID: nextItemID, fromGroup: groupID)
        }
        return lease
    }

    func candidateItemID(in ids: [UUID], mode: ClipboardPasteMode) -> UUID? {
        switch mode {
        case .stack, .list:
            return ids.first
        case .queue:
            return ids.last
        }
    }

    func assignedGroupID(for context: ClipboardRouteContext) -> UUID? {
        guard let bundleIdentifier = context.bundleIdentifier else {
            return nil
        }

        if let applicationName = context.applicationName {
            if let existing = appAssignments[bundleIdentifier] {
                if existing.applicationName != applicationName,
                   applicationName.utf8.count
                       <= storageLimits.maximumAssignmentApplicationNameUTF8ByteCount {
                    appAssignments[bundleIdentifier]?.applicationName = applicationName
                    notePersistedStateMutation()
                }
                return existing.groupID
            }
            let assignment = ClipboardAppAssignment(
                bundleIdentifier: bundleIdentifier,
                applicationName: applicationName,
                groupID: nil
            )
            let projectedAssignments = Array(appAssignments.values) + [assignment]
            guard metadataStorageRejectionReason(
                groups: groupOrder.compactMap { currentGroupID in
                    guard !ClipboardGroup.reservedGroupIDs.contains(currentGroupID) else {
                        return nil
                    }
                    return groupsByID[currentGroupID]
                },
                appAssignments: projectedAssignments
            ) == nil else {
                return nil
            }
            appAssignments[bundleIdentifier] = assignment
            notePersistedStateMutation()
        }

        return appAssignments[bundleIdentifier]?.groupID
    }

    func storageGroupID(for context: ClipboardRouteContext) -> UUID {
        assignedGroupID(for: context) ?? ClipboardGroup.defaultGroup.id
    }

    func deliveryGroup(for context: ClipboardRouteContext) -> UUID {
        let primaryGroupID = assignedGroupID(for: context) ?? ClipboardGroup.defaultGroup.id
        let primaryIDs = groupEntries[primaryGroupID, default: []]
        let primaryMode = currentMode(forGroup: primaryGroupID)
        if candidateItemID(in: primaryIDs, mode: primaryMode) != nil {
            return primaryGroupID
        }

        if let fallbackGroupID = crossGroupFallback(excluding: primaryGroupID) {
            return fallbackGroupID
        }

        return primaryGroupID
    }

    func crossGroupFallback(excluding excludedGroupID: UUID?) -> UUID? {
        let fallbackGroups = groupsByID.values
            .compactMap { group -> (
                group: ClipboardGroup,
                candidateCreatedAt: Date
            )? in
                guard
                    group.id != ClipboardGroup.defaultGroup.id,
                    group.id != excludedGroupID,
                    group.usesCrossGroupFallback
                else {
                    return nil
                }
                let ids = groupEntries[group.id, default: []]
                let mode = currentMode(forGroup: group.id)
                guard
                    let candidateID = candidateItemID(in: ids, mode: mode),
                    let candidateItem = itemsByID[candidateID]
                else {
                    return nil
                }
                return (
                    group,
                    candidateItem.createdAt
                )
            }
            .sorted { lhs, rhs in
                ClipboardFallbackOrdering.precedes(
                    lhsGroup: lhs.group,
                    lhsCandidateCreatedAt: lhs.candidateCreatedAt,
                    rhsGroup: rhs.group,
                    rhsCandidateCreatedAt: rhs.candidateCreatedAt
                )
            }

        return fallbackGroups.first?.group.id
    }

    func currentMode(forGroup groupID: UUID) -> ClipboardPasteMode {
        groupsByID[groupID]?.mode ?? ClipboardGroup.defaultGroup.mode
    }

    func summary(for groupID: UUID) -> ClipboardGroupSummary {
        ensureGroupExists(id: groupID)
        let ids = groupEntries[groupID, default: []]
        let mode = currentMode(forGroup: groupID)
        let previewID = candidateItemID(in: ids, mode: mode)
        let previewItemIDs = groupPreviewItemIDs(in: ids, mode: mode)
        return ClipboardGroupSummary(
            group: groupsByID[groupID] ?? .defaultGroup,
            count: ids.count,
            previewText: previewID.flatMap { itemsByID[$0].map { ClipboardTextFormatting.previewText($0.text) } },
            previewItemIDs: previewItemIDs,
            candidateCreatedAt: previewID.flatMap { itemsByID[$0]?.createdAt }
        )
    }

    func groupSummaries() -> [ClipboardGroupSummary] {
        groupOrder.compactMap { groupID in
            guard groupID != ClipboardGroup.defaultGroup.id else { return nil }
            return groupsByID[groupID].map { _ in summary(for: groupID) }
        }
    }

    func sortedAppAssignments() -> [ClipboardAppAssignment] {
        appAssignments.values.sorted {
            $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending
        }
    }

}
