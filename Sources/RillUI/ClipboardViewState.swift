import AppKit
import SwiftUI
import RillCore

enum ClipboardViewFocusTarget: Hashable {
    case search
    case sectionPicker
    case persistenceRetry
    case entry(UUID)
}

struct ClipboardViewFocusResolution: Equatable {
    let selectedEntryID: UUID?
    let focusTarget: ClipboardViewFocusTarget?
}

enum ClipboardViewFocusPolicy {
    static func showsSearch(in section: ClipboardViewSection) -> Bool {
        section.showsClipboardItems
    }

    static func targetAfterSectionChange(
        current: ClipboardViewFocusTarget?,
        section: ClipboardViewSection
    ) -> ClipboardViewFocusTarget? {
        guard !section.showsClipboardItems else {
            return current
        }
        switch current {
        case .search, .entry:
            return .sectionPicker
        case .sectionPicker, .persistenceRetry, nil:
            return current
        }
    }

    /// Rehomes focus only when the user actively invoked the transient
    /// persistence Retry control. Ordinary page entry (including sidebar
    /// navigation) keeps its existing responder ownership.
    static func targetBeforePersistenceRetry(
        current: ClipboardViewFocusTarget?,
        section: ClipboardViewSection
    ) -> ClipboardViewFocusTarget? {
        guard current == .persistenceRetry else { return current }
        return showsSearch(in: section) ? .search : .sectionPicker
    }

    static func resolveEntriesChange(
        selectedEntryID: UUID?,
        focusTarget: ClipboardViewFocusTarget?,
        previousEntryIDs: [UUID],
        visibleEntryIDs: [UUID],
        section: ClipboardViewSection
    ) -> ClipboardViewFocusResolution {
        let focusedEntryID: UUID? = switch focusTarget {
        case .entry(let entryID): entryID
        case .search, .sectionPicker, .persistenceRetry, nil: nil
        }
        let anchorID = focusedEntryID ?? selectedEntryID
        let resolvedEntryID = replacementEntryID(
            for: anchorID,
            previousEntryIDs: previousEntryIDs,
            visibleEntryIDs: visibleEntryIDs
        )

        let resolvedFocusTarget: ClipboardViewFocusTarget?
        if focusedEntryID != nil {
            resolvedFocusTarget = resolvedEntryID.map(ClipboardViewFocusTarget.entry)
                ?? fallbackTargetForEmptyEntries(in: section)
        } else {
            resolvedFocusTarget = focusTarget
        }
        return ClipboardViewFocusResolution(
            selectedEntryID: resolvedEntryID,
            focusTarget: resolvedFocusTarget
        )
    }

    static func entryIDByMovingFocus(
        from focusTarget: ClipboardViewFocusTarget?,
        direction: Int,
        visibleEntryIDs: [UUID]
    ) -> UUID? {
        guard direction != 0,
              case .entry(let focusedEntryID) = focusTarget,
              let currentIndex = visibleEntryIDs.firstIndex(of: focusedEntryID),
              !visibleEntryIDs.isEmpty else {
            return nil
        }
        let targetIndex = min(
            max(currentIndex + direction, visibleEntryIDs.startIndex),
            visibleEntryIDs.index(before: visibleEntryIDs.endIndex)
        )
        return visibleEntryIDs[targetIndex]
    }

    private static func replacementEntryID(
        for anchorID: UUID?,
        previousEntryIDs: [UUID],
        visibleEntryIDs: [UUID]
    ) -> UUID? {
        guard !visibleEntryIDs.isEmpty else { return nil }
        if let anchorID, visibleEntryIDs.contains(anchorID) {
            return anchorID
        }
        let previousIndex = anchorID.flatMap { previousEntryIDs.firstIndex(of: $0) }
            ?? previousEntryIDs.startIndex
        return visibleEntryIDs[min(previousIndex, visibleEntryIDs.index(before: visibleEntryIDs.endIndex))]
    }

    private static func fallbackTargetForEmptyEntries(
        in section: ClipboardViewSection
    ) -> ClipboardViewFocusTarget {
        showsSearch(in: section) ? .search : .sectionPicker
    }
}

enum ClipboardViewModalPolicy {
    static func allowsParentKeyboardAction(
        hasPresentedSheet: Bool,
        hasPendingDeletion: Bool
    ) -> Bool {
        !hasPresentedSheet && !hasPendingDeletion
    }

    static func allowsDeletionRequest(
        hasPresentedSheet: Bool,
        hasPendingDeletion: Bool
    ) -> Bool {
        allowsParentKeyboardAction(
            hasPresentedSheet: hasPresentedSheet,
            hasPendingDeletion: hasPendingDeletion
        )
    }
}

extension ClipboardView {
    var clipboardGroupNamesByID: [UUID: String] {
        Dictionary(uniqueKeysWithValues: model.clipboardGroups.map { ($0.group.id, $0.group.name) })
    }

    var routePresentation: ClipboardRoutePresentation {
        ClipboardRoutePresentation.make(
            explicitGroups: model.clipboardGroups,
            defaultGroup: model.clipboardDefaultGroup,
            appAssignments: model.clipboardAppAssignments,
            previewContext: previewContext
        )
    }

    var routingGroupSummaries: [ClipboardGroupSummary] {
        routePresentation.orderedRoutingGroups
    }

    var routingManagementGroupSummaries: [ClipboardGroupSummary] {
        model.clipboardGroups + [model.clipboardDefaultGroup]
    }

    var displayedRoutingGroupSummaries: [ClipboardGroupSummary] {
        if let focusedGroupID {
            return routingManagementGroupSummaries.filter { $0.group.id == focusedGroupID }
        }
        return previewContext == nil ? routingManagementGroupSummaries : routingGroupSummaries
    }

    var filteredHistoryGroupSummaries: [ClipboardGroupSummary] {
        let source: [ClipboardGroupSummary]
        switch selectedSection {
        case .current:
            source = previewContext == nil ? routingManagementGroupSummaries : routingGroupSummaries
        case .history:
            source = routingManagementGroupSummaries
        case .routing:
            source = []
        }

        if let focusedGroupID {
            return source.filter { $0.group.id == focusedGroupID }
        }
        return source
    }

    func recomputeFilteredSections() {
        let query = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleEntries = clipboardEntriesForSelectedSection().filter { entry in
            if let focusedGroupID, entry.representativeItem.groupID != focusedGroupID {
                return false
            }
            if showsPinnedOnly, !entry.isPinned {
                return false
            }
            guard !query.isEmpty else { return true }
            return entry.matchesSearchQuery(query, groupName: groupName(for: entry.representativeItem.groupID))
        }

        let entriesByGroup = Dictionary(grouping: visibleEntries, by: { $0.representativeItem.groupID })
        cachedFilteredSections = filteredHistoryGroupSummaries.compactMap { summary in
            guard let entries = entriesByGroup[summary.group.id], !entries.isEmpty else {
                return nil
            }
            return ClipboardHistorySectionModel(
                groupID: summary.group.id,
                title: groupName(for: summary.group.id),
                entries: entries
            )
        }
    }

    func clipboardEntriesForSelectedSection() -> [ClipboardHistoryEntry] {
        switch selectedSection {
        case .current:
            let currentEntries = ClipboardHistoryEntryBuilder.buildCurrent(
                from: model.clipboardItems,
                remainingItemIDs: model.clipboardRemainingItemIDs,
                mergeSimilarText: model.mergeSimilarClipboardItems
            )
            return routePresentation.visibleEntries(from: currentEntries)
        case .history:
            return model.clipboardHistoryEntries
        case .routing:
            return []
        }
    }

    var filteredClipboardSections: [ClipboardHistorySectionModel] {
        cachedFilteredSections
    }

    var filteredClipboardEntries: [ClipboardHistoryEntry] {
        cachedFilteredSections.flatMap(\.entries)
    }

    var filteredClipboardEntryIDs: [UUID] {
        filteredClipboardEntries.map(\.id)
    }

    var selectedEntry: ClipboardHistoryEntry? {
        guard let selectedEntryID else { return nil }
        return filteredClipboardEntries.first(where: { $0.id == selectedEntryID })
    }

    func scheduleSearchDebounce(for query: String) {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(120))
                try Task.checkCancellation()
                await MainActor.run {
                    debouncedSearchText = query
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    debouncedSearchText = query
                }
            }
        }
    }

    func syncSelectedEntry(previousVisibleEntryIDs: [UUID] = []) {
        guard selectedSection.showsClipboardItems else { return }
        let resolution = ClipboardViewFocusPolicy.resolveEntriesChange(
            selectedEntryID: selectedEntryID,
            focusTarget: focusedControl,
            previousEntryIDs: previousVisibleEntryIDs,
            visibleEntryIDs: filteredClipboardEntryIDs,
            section: selectedSection
        )
        selectedEntryID = resolution.selectedEntryID
        focusedControl = resolution.focusTarget
    }

    func shouldHandleReturnAction() -> Bool {
        ClipboardInputMethodGuard.shouldHandleReturn(for: activeTextInputResponder)
    }

    var activeTextInputResponder: NSResponder? {
        NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder
    }

}
