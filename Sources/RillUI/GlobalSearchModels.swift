import Foundation
import RillCore

enum GlobalSearchDestination: Hashable, Sendable {
    case record(RecordID)
    case collection(RecordCollectionID)
    case sidebar(SidebarSection)
    case workflow(UUID)
    case history(UUID)
    case settings(SettingsSection)

    var stableID: String {
        switch self {
        case .record(let id): "record.\(id)"
        case .collection(let id): "collection.\(id)"
        case .sidebar(let section):
            "page.\(section.rawValue)"
        case .workflow(let id):
            "workflow.\(id.uuidString)"
        case .history(let id):
            "history.\(id.uuidString)"
        case .settings(let section):
            "settings.\(section.rawValue)"
        }
    }
}

enum GlobalSearchResultCategory: Int, CaseIterable, Sendable {
    case records
    case collections
    case history
    case workflows
    case settings
    case pages

    func title(language: AppLanguage) -> String {
        switch self {
        case .records: L10n.workspace(.records, language: language)
        case .collections: L10n.workspace(.collections, language: language)
        case .pages:
            L10n.overlayText(.searchCategoryPages, language: language)
        case .workflows:
            L10n.text(.sidebarWorkflows, language: language)
        case .history:
            L10n.overlayText(.searchCategoryRunHistory, language: language)
        case .settings:
            L10n.text(.settingsTitle, language: language)
        }
    }
}

struct GlobalSearchResult: Identifiable, Equatable, Sendable {
    let destination: GlobalSearchDestination
    let category: GlobalSearchResultCategory
    let title: String
    let detail: String?
    let preview: String?
    let symbolName: String
    let searchableText: String
    let timestamp: Date?

    var id: String { destination.stableID }
}

enum GlobalSearchSelection {
    static func reconcile(
        currentID: String?,
        results: [GlobalSearchResult]
    ) -> String? {
        guard !results.isEmpty else { return nil }
        if let currentID, results.contains(where: { $0.id == currentID }) {
            return currentID
        }
        return results.first?.id
    }

    static func move(
        currentID: String?,
        offset: Int,
        results: [GlobalSearchResult]
    ) -> String? {
        guard !results.isEmpty else { return nil }
        guard let currentID,
              let currentIndex = results.firstIndex(where: { $0.id == currentID }) else {
            return offset < 0 ? results.last?.id : results.first?.id
        }
        let nextIndex = min(max(currentIndex + offset, results.startIndex), results.index(before: results.endIndex))
        return results[nextIndex].id
    }
}

enum GlobalHistorySearchState: Equatable, Sendable {
    case idle
    case searching
    case loaded
    case failed
}

enum GlobalSearchText {
    static func searchCommand(language: AppLanguage) -> String {
        L10n.overlayText(.searchCommand, language: language)
    }

    static func searchPrompt(language: AppLanguage) -> String {
        L10n.workspace(.searchEverywhere, language: language)
    }

    static func quickDestinations(language: AppLanguage) -> String {
        L10n.overlayText(.searchQuickDestinations, language: language)
    }

    static func noResultsTitle(language: AppLanguage) -> String {
        L10n.overlayText(.searchNoResultsTitle, language: language)
    }

    static func noResultsDescription(language: AppLanguage) -> String {
        L10n.overlayText(.searchNoResultsDescription, language: language)
    }

    static func cancel(language: AppLanguage) -> String {
        L10n.recordText(.cancel, language: language)
    }

    static func cancelHelp(language: AppLanguage) -> String {
        L10n.text(.searchCancelShortcutHint, language: language)
    }

    static func workflowDetail(language: AppLanguage) -> String {
        L10n.overlayText(.searchOpenInWorkflows, language: language)
    }

    static func settingsDetail(language: AppLanguage) -> String {
        L10n.overlayText(.searchOpenSettingsSection, language: language)
    }

    static func status(_ status: HistoryTimelineStatus, language: AppLanguage) -> String {
        L10n.historyRunStatus(status, language: language)
    }

    static func genericRun(language: AppLanguage) -> String {
        L10n.historyTimelineText(.workflowRunFallback, language: language)
    }

    static func historySearching(language: AppLanguage) -> String {
        L10n.overlayText(.searchHistorySearching, language: language)
    }

    static func historyUnavailable(language: AppLanguage) -> String {
        L10n.overlayText(.searchHistoryUnavailable, language: language)
    }

    static func historyRetry(language: AppLanguage) -> String {
        L10n.text(.retryGlobalInput, language: language)
    }
}

enum GlobalSearchIndex {
    static let maximumHistoryResultCount = 20

    @MainActor
    static func makeResults(
        language: AppLanguage,
        workflows: [WorkflowDefinition],
        historyRecords: [WorkflowResultRecord],
        receipts: [WorkflowRunReceipt],
        historyPreviewMode: PrivacyHistoryPreviewMode
    ) -> [GlobalSearchResult] {
        makeStaticResults(language: language, workflows: workflows)
            + makeHistoryResults(
                language: language,
                workflows: workflows,
                entries: HistoryTimelineBuilder.allRuns(
                    records: historyRecords,
                    receipts: receipts
                ),
                previewMode: historyPreviewMode
            )
    }

    /// Results that are always available without touching history storage.
    /// Keeping this index separate ensures a repository failure cannot make
    /// navigation and settings search disappear.
    @MainActor
    static func makeStaticResults(
        language: AppLanguage,
        workflows: [WorkflowDefinition]
    ) -> [GlobalSearchResult] {
        pageResults(language: language)
            + workflowResults(language: language, workflows: workflows)
            + settingsResults(language: language)
    }

    static func makeHistoryResults(
        language: AppLanguage,
        workflows: [WorkflowDefinition],
        entries: [HistoryTimelineEntry],
        previewMode: PrivacyHistoryPreviewMode
    ) -> [GlobalSearchResult] {
        historyResults(
            language: language,
            workflows: workflows,
            entries: entries,
            previewMode: previewMode
        )
    }

    static func filter(
        _ results: [GlobalSearchResult],
        query: String
    ) -> [GlobalSearchResult] {
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        let filtered: [GlobalSearchResult]
        if terms.isEmpty {
            filtered = results.filter { $0.category == .pages || $0.category == .settings }
        } else {
            filtered = results.filter { result in
                result.category == .records || terms.allSatisfy { term in
                    result.searchableText.localizedStandardContains(term)
                }
            }
        }
        return filtered.sorted(by: resultSort)
    }

    static func recordResults(_ records: [RecordSummary], language: AppLanguage) -> [GlobalSearchResult] {
        records.map { record in
            let title = record.header.kind == .image
                ? L10n.recordText(.imagePayload, language: language)
                : record.header.preview
            let symbol: RillSystemSymbol = switch record.header.kind {
            case .text: .textAlignLeft
            case .image: .photo
            case .files: .docOnDoc
            }
            return GlobalSearchResult(
                destination: .record(record.id), category: .records,
                title: title, detail: record.header.provenance.sourceApplicationName,
                preview: nil, symbolName: symbol.rawValue, searchableText: title,
                timestamp: record.header.createdAt
            )
        }
    }

    static func collectionResults(_ collections: [RecordCollection], language: AppLanguage) -> [GlobalSearchResult] {
        collections.map { collection in
            GlobalSearchResult(
                destination: .collection(collection.id), category: .collections,
                title: collection.name, detail: nil, preview: nil,
                symbolName: RillSystemSymbol.squareStack3dUp.rawValue,
                searchableText: collection.name, timestamp: nil
            )
        }
    }

    private static func pageResults(language: AppLanguage) -> [GlobalSearchResult] {
        SidebarSection.allCases.filter { $0 != .settings && $0 != .diagnostics }.map { section in
            let title = section == .records ? L10n.workspace(.allRecords, language: language) : L10n.text(section.titleKey, language: language)
            return GlobalSearchResult(
                destination: .sidebar(section),
                category: .pages,
                title: title,
                detail: nil,
                preview: nil,
                symbolName: section.symbolName,
                searchableText: "\(title) \(section.rawValue) page 页面",
                timestamp: nil
            )
        }
    }

    @MainActor
    private static func workflowResults(
        language: AppLanguage,
        workflows: [WorkflowDefinition]
    ) -> [GlobalSearchResult] {
        workflows.filter { $0.availability == .active }.map { workflow in
            let title = L10n.workflowName(workflow.presentation, language: language)
            let detail = GlobalSearchText.workflowDetail(language: language)
            return GlobalSearchResult(
                destination: .workflow(workflow.id),
                category: .workflows,
                title: title,
                detail: detail,
                preview: nil,
                symbolName: RillSystemSymbol.resolvedName(workflow.ui.symbolName),
                searchableText: "\(title) \(detail) workflow 工作流",
                timestamp: nil
            )
        }
    }

    private static func historyResults(
        language: AppLanguage,
        workflows: [WorkflowDefinition],
        entries: [HistoryTimelineEntry],
        previewMode: PrivacyHistoryPreviewMode
    ) -> [GlobalSearchResult] {
        let presentationsByWorkflowID = Dictionary(
            workflows.map { ($0.id, $0.presentation) },
            uniquingKeysWith: { first, _ in first }
        )
        return entries.map { entry in
            let title: String
            if let record = entry.record {
                title = L10n.workflowName(record.workflow, language: language)
            } else if let workflowID = entry.workflowID,
                      let presentation = presentationsByWorkflowID[workflowID] {
                title = L10n.workflowName(presentation, language: language)
            } else {
                title = GlobalSearchText.genericRun(language: language)
            }

            let status = GlobalSearchText.status(entry.status, language: language)
            let detail = "\(status) · \(formattedDate(entry.timestamp, language: language))"
            let preview: String?
            let presentation = HistoryPreviewPresentation(
                text: entry.record?.finalText,
                mode: previewMode,
                language: language
            )
            if case .visible(let text, _) = presentation {
                preview = text
            } else {
                preview = nil
            }
            let searchText = [title, status, detail, preview]
                .compactMap { $0 }
                .joined(separator: " ")
            return GlobalSearchResult(
                destination: .history(entry.id),
                category: .history,
                title: title,
                detail: detail,
                preview: preview,
                symbolName: entry.status.systemSymbol.rawValue,
                searchableText: searchText,
                timestamp: entry.timestamp
            )
        }
    }

    private static func settingsResults(language: AppLanguage) -> [GlobalSearchResult] {
        SettingsSection.allCases.map { section in
            let title = section.title(language: language)
            let detail = GlobalSearchText.settingsDetail(language: language) + " · " + section.pane.title(language: language)
            return GlobalSearchResult(
                destination: .settings(section),
                category: .settings,
                title: title,
                detail: detail,
                preview: nil,
                symbolName: section.symbolName,
                searchableText: "\(title) \(detail) \(section.searchKeywords)",
                timestamp: nil
            )
        }
    }

    private static func resultSort(
        _ lhs: GlobalSearchResult,
        _ rhs: GlobalSearchResult
    ) -> Bool {
        if lhs.category.rawValue != rhs.category.rawValue {
            return lhs.category.rawValue < rhs.category.rawValue
        }
        if (lhs.category == .history || lhs.category == .records), lhs.timestamp != rhs.timestamp {
            return (lhs.timestamp ?? .distantPast) > (rhs.timestamp ?? .distantPast)
        }
        let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    private static func formattedDate(_ date: Date, language: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .english ? "en_US" : "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

}
