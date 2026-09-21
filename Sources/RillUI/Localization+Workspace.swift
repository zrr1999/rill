import Foundation

enum WorkspaceText: CaseIterable {
    case allRecords
    case collectionSettings
    case recordRules
    case general
    case input
    case voiceModels
    case vocabularyMemory
    case privacy
    case data
    case contextMemory
    case contextMemorySummary
    case diagnosticsSummary
    case recordsSearching
    case recordsUnavailable
    case recordUnavailable
    case loadMore
    case searchRill
    case done
    case copy
    case collections
    case records
    case selectWorkflow
    case searchEverywhere
    case showDetails
    case allTypes
    case source
    case allSources
}

extension L10n {
    static func workspace(_ key: WorkspaceText, language: AppLanguage) -> String {
        switch (language, key) {
        case (.english, .allRecords): "All Records"
        case (.simplifiedChinese, .allRecords): "全部记录"
        case (.english, .collectionSettings): "Collection Settings"
        case (.simplifiedChinese, .collectionSettings): "集合设置"
        case (.english, .recordRules): "Capture & Delivery Rules"
        case (.simplifiedChinese, .recordRules): "采集与投递规则"
        case (.english, .general): "General"
        case (.simplifiedChinese, .general): "常规"
        case (.english, .input): "Input"
        case (.simplifiedChinese, .input): "输入"
        case (.english, .voiceModels): "Voice & Models"
        case (.simplifiedChinese, .voiceModels): "语音与模型"
        case (.english, .vocabularyMemory): "Vocabulary & Memory"
        case (.simplifiedChinese, .vocabularyMemory): "词汇与记忆"
        case (.english, .privacy): "Privacy"
        case (.simplifiedChinese, .privacy): "隐私"
        case (.english, .data): "Data"
        case (.simplifiedChinese, .data): "数据"
        case (.english, .contextMemory): "Context Correction & Memory"
        case (.simplifiedChinese, .contextMemory): "上下文纠错与记忆"
        case (.english, .contextMemorySummary): "Correct recognition with optional context and manage long-term memories."
        case (.simplifiedChinese, .contextMemorySummary): "使用可选上下文纠正识别错误，并管理长期记忆。"
        case (.english, .diagnosticsSummary): "Inspect runtime status, storage issues and diagnostics."
        case (.simplifiedChinese, .diagnosticsSummary): "查看运行状态、存储问题和诊断信息。"
        case (.english, .recordsSearching): "Searching records…"
        case (.simplifiedChinese, .recordsSearching): "正在搜索记录…"
        case (.english, .recordsUnavailable): "Records could not be searched. Other results are still available."
        case (.simplifiedChinese, .recordsUnavailable): "无法搜索记录，其他结果仍可使用。"
        case (.english, .recordUnavailable): "This record is no longer available."
        case (.simplifiedChinese, .recordUnavailable): "这条记录已不可用。"
        case (.english, .loadMore): "Show more results"
        case (.simplifiedChinese, .loadMore): "显示更多结果"
        case (.english, .searchRill): "Search Rill"
        case (.simplifiedChinese, .searchRill): "搜索 Rill"
        case (.english, .done): "Done"
        case (.simplifiedChinese, .done): "完成"
        case (.english, .copy): "Copy"
        case (.simplifiedChinese, .copy): "复制"
        case (.english, .collections): "Collections"
        case (.simplifiedChinese, .collections): "记录集"
        case (.english, .records): "Records"
        case (.simplifiedChinese, .records): "记录"
        case (.english, .selectWorkflow): "Select a workflow"
        case (.simplifiedChinese, .selectWorkflow): "选择工作流"
        case (.english, .searchEverywhere): "Search records, runs, workflows and settings"
        case (.simplifiedChinese, .searchEverywhere): "搜索记录、运行、工作流和设置"
        case (.english, .showDetails): "Show details"
        case (.simplifiedChinese, .showDetails): "查看详情"
        case (.english, .allTypes): "All types"
        case (.simplifiedChinese, .allTypes): "所有类型"
        case (.english, .source): "Source"
        case (.simplifiedChinese, .source): "来源"
        case (.english, .allSources): "All sources"
        case (.simplifiedChinese, .allSources): "所有来源"
        }
    }
}
