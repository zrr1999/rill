import Foundation
import RillCore

enum GlobalSearchDestination: Hashable, Sendable {
    case sidebar(SidebarSection)
    case workflow(UUID)
    case history(UUID)
    case settings(SettingsSection)

    var stableID: String {
        switch self {
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
    case pages
    case workflows
    case history
    case settings

    func title(language: AppLanguage) -> String {
        switch (language, self) {
        case (.english, .pages): "Pages"
        case (.simplifiedChinese, .pages): "页面"
        case (.english, .workflows): "Workflows"
        case (.simplifiedChinese, .workflows): "工作流"
        case (.english, .history): "Run History"
        case (.simplifiedChinese, .history): "运行历史"
        case (.english, .settings): "Settings"
        case (.simplifiedChinese, .settings): "设置"
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
        language == .english ? "Search Rill" : "搜索 Rill"
    }

    static func searchPrompt(language: AppLanguage) -> String {
        language == .english
            ? "Search pages, workflows, run history, and settings"
            : "搜索页面、工作流、运行历史和设置"
    }

    static func quickDestinations(language: AppLanguage) -> String {
        language == .english ? "Quick Destinations" : "快速前往"
    }

    static func noResultsTitle(language: AppLanguage) -> String {
        language == .english ? "No Results" : "没有结果"
    }

    static func noResultsDescription(language: AppLanguage) -> String {
        language == .english
            ? "Try a page, workflow, run status, or settings term."
            : "请尝试页面、工作流、运行状态或设置关键词。"
    }

    static func cancel(language: AppLanguage) -> String {
        language == .english ? "Cancel" : "取消"
    }

    static func workflowDetail(language: AppLanguage) -> String {
        language == .english ? "Open in Workflows" : "在工作流中打开"
    }

    static func settingsDetail(language: AppLanguage) -> String {
        language == .english ? "Open settings section" : "打开设置分区"
    }

    static func status(_ status: HistoryTimelineStatus, language: AppLanguage) -> String {
        switch (language, status) {
        case (.english, .completed): "Completed"
        case (.simplifiedChinese, .completed): "已完成"
        case (.english, .partiallyCompleted): "Partially completed"
        case (.simplifiedChinese, .partiallyCompleted): "部分完成"
        case (.english, .failed): "Failed"
        case (.simplifiedChinese, .failed): "失败"
        case (.english, .cancelled): "Cancelled"
        case (.simplifiedChinese, .cancelled): "已取消"
        case (.english, .skipped): "Skipped"
        case (.simplifiedChinese, .skipped): "已跳过"
        }
    }

    static func genericRun(language: AppLanguage) -> String {
        language == .english ? "Workflow run" : "工作流运行"
    }

    static func historySearching(language: AppLanguage) -> String {
        language == .english ? "Searching run history…" : "正在搜索运行历史…"
    }

    static func historyUnavailable(language: AppLanguage) -> String {
        language == .english
            ? "Saved run history couldn't be searched. Page, workflow, and settings results are still available."
            : "无法搜索已保存的运行历史；页面、工作流和设置结果仍然可用。"
    }

    static func historyRetry(language: AppLanguage) -> String {
        language == .english ? "Retry" : "重试"
    }
}

enum GlobalSearchIndex {
    static let maximumHistoryResultCount = 20

    @MainActor
    static func makeResults(
        language: AppLanguage,
        workflows: [WorkflowDefinition],
        historyRecords: [HistoryRecord],
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
                terms.allSatisfy { term in
                    result.searchableText.localizedStandardContains(term)
                }
            }
        }
        return filtered.sorted(by: resultSort)
    }

    private static func pageResults(language: AppLanguage) -> [GlobalSearchResult] {
        SidebarSection.allCases.map { section in
            let title = UIStrings.text(section.titleKey, language: language)
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
            let title = UIStrings.workflowName(workflow.presentation, language: language)
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
                title = UIStrings.workflowName(record.workflow, language: language)
            } else if let workflowID = entry.workflowID,
                      let presentation = presentationsByWorkflowID[workflowID] {
                title = UIStrings.workflowName(presentation, language: language)
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
            let detail = GlobalSearchText.settingsDetail(language: language)
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
        if lhs.category == .history, lhs.timestamp != rhs.timestamp {
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
