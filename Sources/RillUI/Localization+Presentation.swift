import Foundation

extension L10n {
    enum PresentationKey: String, CaseIterable {
        case details, more, less, copied, editText, moreActions, metadata, builtinReadOnly
        case insertInto, saving, saved, unsavedTitle, unsavedDetail, discard, back
        case configuration, clearSearch, ready, noMatchingRecords, noMatchingRecordsDetail, clearFilters, nameRequired, invalidWorkflowID
    }

    static func presentation(_ key: PresentationKey, language: AppLanguage) -> String {
        let value: LocalizedText = switch key {
        case .details: .init(english: "Execution details", simplifiedChinese: "执行详情")
        case .builtinReadOnly: .init(english: "Built-in workflow · Read only", simplifiedChinese: "内置工作流 · 只读")
        case .more: .init(english: "Show more", simplifiedChinese: "展开全文")
        case .less: .init(english: "Show less", simplifiedChinese: "收起全文")
        case .copied: .init(english: "Copied", simplifiedChinese: "已复制")
        case .editText: .init(english: "Edit text…", simplifiedChinese: "编辑文本…")
        case .moreActions: .init(english: "More actions", simplifiedChinese: "更多操作")
        case .metadata: .init(english: "Details", simplifiedChinese: "详细信息")
        case .insertInto: .init(english: "Insert into %@", simplifiedChinese: "插入到 %@")
        case .saving: .init(english: "Saving…", simplifiedChinese: "正在保存…")
        case .saved: .init(english: "Saved", simplifiedChinese: "已保存")
        case .unsavedTitle: .init(english: "Save your changes?", simplifiedChinese: "保存修改？")
        case .unsavedDetail: .init(english: "This workflow has unsaved changes.", simplifiedChinese: "此工作流有尚未保存的修改。")
        case .discard: .init(english: "Discard changes", simplifiedChinese: "放弃修改")
        case .back: .init(english: "Back to workflows", simplifiedChinese: "返回工作流列表")
        case .configuration: .init(english: "Configuration files", simplifiedChinese: "配置文件")
        case .ready: .init(english: "Ready", simplifiedChinese: "已就绪")
        case .noMatchingRecords: .init(english: "No matching records", simplifiedChinese: "没有匹配的记录")
        case .noMatchingRecordsDetail: .init(english: "Try another search or clear your filters.", simplifiedChinese: "尝试其他搜索内容，或清除筛选条件。")
        case .clearFilters: .init(english: "Clear filters", simplifiedChinese: "清除筛选")
        case .nameRequired: .init(english: "Enter a workflow name.", simplifiedChinese: "请输入工作流名称。")
        case .invalidWorkflowID: .init(english: "Enter a valid workflow UUID or leave this field empty.", simplifiedChinese: "请输入有效的工作流 UUID，或留空表示任意工作流。")
        case .clearSearch: .init(english: "Clear search", simplifiedChinese: "清除搜索")
        }
        return value.string(for: language)
    }
}
