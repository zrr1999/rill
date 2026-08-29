import Foundation
import RillCore

extension L10n {
    static func overlayText(_ key: OverlayTextKey, language: AppLanguage) -> String {
        overlayTextTable[key]?.string(for: language) ?? key.rawValue
    }

    static func liveSubtitleRemaining(_ remaining: String, language: AppLanguage) -> String {
        String(format: overlayText(.liveSubtitleRemainingFormat, language: language), remaining)
    }

    static func liveSubtitleRecorded(_ elapsed: String, language: AppLanguage) -> String {
        String(format: overlayText(.liveSubtitleRecordedFormat, language: language), elapsed)
    }

    private static let overlayTextTable: [OverlayTextKey: LocalizedText] = [
        .correctionCreateScopedCollection: .init(
            english: "Create matching scoped collection",
            simplifiedChinese: "创建匹配条件的词库"
        ),
        .correctionSaveToCollection: .init(
            english: "Save to collection",
            simplifiedChinese: "保存到词库"
        ),
        .correctionSettingsLoading: .init(
            english: "Vocabulary settings are still loading. Wait a moment and try again.",
            simplifiedChinese: "词汇设置仍在加载，请稍候再试。"
        ),
        .liveSubtitleContinueNoTimeLimit: .init(
            english: "Continue with no time limit",
            simplifiedChinese: "继续且不限时"
        ),
        .liveSubtitleContinueWithoutLimitHelp: .init(
            english: "Continue without the automatic recording limit",
            simplifiedChinese: "继续录音并解除自动时限"
        ),
        .liveSubtitleEscapeHint: .init(
            english: "Press Escape to cancel and discard",
            simplifiedChinese: "按 Escape 取消并丢弃"
        ),
        .liveSubtitleRecordedFormat: .init(
            english: "Recorded %@.",
            simplifiedChinese: "已录制 %@。"
        ),
        .liveSubtitleRecordingJustStarted: .init(
            english: "Recording just started.",
            simplifiedChinese: "录音刚刚开始。"
        ),
        .liveSubtitleRemainingFormat: .init(
            english: "%@ remaining.",
            simplifiedChinese: "剩余 %@。"
        ),
        .searchCategoryPages: .init(english: "Pages", simplifiedChinese: "页面"),
        .searchCategoryRunHistory: .init(english: "Run History", simplifiedChinese: "运行历史"),
        .searchCommand: .init(english: "Search Rill", simplifiedChinese: "搜索 Rill"),
        .searchHistorySearching: .init(
            english: "Searching run history…",
            simplifiedChinese: "正在搜索运行历史…"
        ),
        .searchHistoryUnavailable: .init(
            english: "Saved run history couldn't be searched. Page, workflow, and settings results are still available.",
            simplifiedChinese: "无法搜索已保存的运行历史；页面、工作流和设置结果仍然可用。"
        ),
        .searchNoResultsDescription: .init(
            english: "Try a page, workflow, run status, or settings term.",
            simplifiedChinese: "请尝试页面、工作流、运行状态或设置关键词。"
        ),
        .searchNoResultsTitle: .init(english: "No Results", simplifiedChinese: "没有结果"),
        .searchOpenInWorkflows: .init(
            english: "Open in Workflows",
            simplifiedChinese: "在工作流中打开"
        ),
        .searchOpenSettingsSection: .init(
            english: "Open settings section",
            simplifiedChinese: "打开设置分区"
        ),
        .searchPrompt: .init(
            english: "Search pages, workflows, run history, and settings",
            simplifiedChinese: "搜索页面、工作流、运行历史和设置"
        ),
        .searchQuickDestinations: .init(
            english: "Quick Destinations",
            simplifiedChinese: "快速前往"
        ),
        .settingsVoiceAssistantTitle: .init(
            english: "Voice Assistant",
            simplifiedChinese: "语音助手"
        ),
    ]
}

enum OverlayTextKey: String, CaseIterable, Sendable {
    case correctionCreateScopedCollection
    case correctionSaveToCollection
    case correctionSettingsLoading
    case liveSubtitleContinueNoTimeLimit
    case liveSubtitleContinueWithoutLimitHelp
    case liveSubtitleEscapeHint
    case liveSubtitleRecordedFormat
    case liveSubtitleRecordingJustStarted
    case liveSubtitleRemainingFormat
    case searchCategoryPages
    case searchCategoryRunHistory
    case searchCommand
    case searchHistorySearching
    case searchHistoryUnavailable
    case searchNoResultsDescription
    case searchNoResultsTitle
    case searchOpenInWorkflows
    case searchOpenSettingsSection
    case searchPrompt
    case searchQuickDestinations
    case settingsVoiceAssistantTitle
}
