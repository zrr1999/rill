import Foundation
import RillCore

struct ClipboardRoutePresentation {
    let orderedRoutingGroups: [ClipboardGroupSummary]
    let visibleGroupIDs: Set<UUID>

    static func make(
        explicitGroups: [ClipboardGroupSummary],
        defaultGroup: ClipboardGroupSummary,
        appAssignments: [ClipboardAppAssignment],
        previewContext: ClipboardRouteContext?
    ) -> ClipboardRoutePresentation {
        let orderedGroups: [ClipboardGroupSummary]
        if let previewContext {
            orderedGroups = makeOrderedRoutingGroups(
                explicitGroups: explicitGroups,
                defaultGroup: defaultGroup,
                appAssignments: appAssignments,
                previewContext: previewContext
            )
        } else {
            orderedGroups = explicitGroups + [defaultGroup]
        }

        return ClipboardRoutePresentation(
            orderedRoutingGroups: orderedGroups,
            visibleGroupIDs: Set(orderedGroups.map(\.group.id))
        )
    }

    func visibleEntries(
        from entries: [ClipboardHistoryEntry],
        historyVisibility: ClipboardHistoryVisibility = .all,
        remainingItemIDs: Set<UUID> = []
    ) -> [ClipboardHistoryEntry] {
        entries.filter { entry in
            guard visibleGroupIDs.contains(entry.representativeItem.groupID) else {
                return false
            }
            switch historyVisibility {
            case .all:
                return true
            case .remainingOnly:
                return entry.mergedItemIDs.contains { remainingItemIDs.contains($0) }
            }
        }
    }

    private static func makeOrderedRoutingGroups(
        explicitGroups: [ClipboardGroupSummary],
        defaultGroup: ClipboardGroupSummary,
        appAssignments: [ClipboardAppAssignment],
        previewContext: ClipboardRouteContext
    ) -> [ClipboardGroupSummary] {
        let assignedGroupID = assignedGroupID(
            for: previewContext,
            appAssignments: appAssignments
        )
        let fallbackGroups = explicitGroups
            .filter { summary in
                summary.group.id != assignedGroupID && summary.group.usesCrossGroupFallback
            }
            .sorted { lhs, rhs in
                ClipboardFallbackOrdering.precedes(
                    lhsGroup: lhs.group,
                    lhsCandidateCreatedAt: lhs.candidateCreatedAt ?? .distantPast,
                    rhsGroup: rhs.group,
                    rhsCandidateCreatedAt: rhs.candidateCreatedAt ?? .distantPast
                )
            }

        var orderedSummaries: [ClipboardGroupSummary] = []
        if let assignedGroupID,
           let assignedGroup = explicitGroups.first(where: { $0.group.id == assignedGroupID }) {
            orderedSummaries.append(assignedGroup)
            orderedSummaries.append(contentsOf: fallbackGroups)
            orderedSummaries.append(defaultGroup)
        } else {
            orderedSummaries.append(defaultGroup)
            orderedSummaries.append(contentsOf: fallbackGroups)
        }
        return orderedSummaries
    }

    private static func assignedGroupID(
        for previewContext: ClipboardRouteContext,
        appAssignments: [ClipboardAppAssignment]
    ) -> UUID? {
        if let bundleIdentifier = normalized(previewContext.bundleIdentifier),
           let assignment = appAssignments.first(where: { normalized($0.bundleIdentifier) == bundleIdentifier }) {
            return assignment.groupID
        }

        if let applicationName = normalized(previewContext.applicationName),
           let assignment = appAssignments.first(where: { normalized($0.applicationName) == applicationName }) {
            return assignment.groupID
        }

        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return nil
        }
        return trimmedValue.lowercased()
    }
}
