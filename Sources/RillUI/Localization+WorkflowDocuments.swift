import RillCore

extension L10n {
    enum WorkflowDocumentKey: String, CaseIterable {
        case labelWorkflows
        case labelEditExternally
        case labelRunClipboardText
        case labelRun
        case labelImportTOML
        case labelShowConfigurationFolder
        case labelReloadFiles
        case labelNewFrom
        case labelMoreActions
        case labelNewWorkflow
        case labelSearchWorkflows
        case labelEnabled
        case labelDuplicate
        case labelRestoreDefault
        case labelDelete
        case labelWorkflowActions
        case labelOpenFile
        case labelRemoveThisCustomization
        case labelRemove
        case labelInvalidFileNewRunsAreBlocked
        case labelPreset
        case labelSteps
        case labelOutputs
    }

    static func workflowDocument(_ key: WorkflowDocumentKey, language: AppLanguage) -> String {
        let title: LocalizedText = switch key {
        case .labelWorkflows: .init(english: "Workflows", simplifiedChinese: "工作流")
        case .labelEditExternally: .init(english: "Edit TOML and prompts in your text editor. Saved changes apply to the next run.", simplifiedChinese: "在外部文本编辑器中修改 TOML 和提示词，保存后对下次运行生效。")
        case .labelRunClipboardText: .init(english: "Run clipboard text", simplifiedChinese: "运行剪贴板文本")
        case .labelRun: .init(english: "Run", simplifiedChinese: "运行")
        case .labelImportTOML: .init(english: "Import TOML…", simplifiedChinese: "导入 TOML…")
        case .labelShowConfigurationFolder: .init(english: "Show configuration folder", simplifiedChinese: "打开配置目录")
        case .labelReloadFiles: .init(english: "Reload files", simplifiedChinese: "重新加载文件")
        case .labelNewFrom: .init(english: "New from ", simplifiedChinese: "从模板新建：")
        case .labelMoreActions: .init(english: "More actions", simplifiedChinese: "更多操作")
        case .labelNewWorkflow: .init(english: "New workflow", simplifiedChinese: "新建工作流")
        case .labelSearchWorkflows: .init(english: "Search workflows", simplifiedChinese: "搜索工作流")
        case .labelEnabled: .init(english: "Enabled", simplifiedChinese: "启用")
        case .labelDuplicate: .init(english: "Duplicate", simplifiedChinese: "创建副本")
        case .labelRestoreDefault: .init(english: "Restore default", simplifiedChinese: "恢复默认")
        case .labelDelete: .init(english: "Delete", simplifiedChinese: "删除")
        case .labelWorkflowActions: .init(english: "Workflow actions", simplifiedChinese: "工作流操作")
        case .labelOpenFile: .init(english: "Open file", simplifiedChinese: "打开文件")
        case .labelRemoveThisCustomization: .init(english: "Remove this customization?", simplifiedChinese: "移除此自定义配置？")
        case .labelRemove: .init(english: "Remove", simplifiedChinese: "移除")
        case .labelInvalidFileNewRunsAreBlocked: .init(english: "Invalid TOML; new runs are blocked", simplifiedChinese: "TOML 无效，已阻止新运行")
        case .labelPreset: .init(english: "Preset", simplifiedChinese: "预设")
        case .labelSteps: .init(english: "steps", simplifiedChinese: "个步骤")
        case .labelOutputs: .init(english: "outputs", simplifiedChinese: "个输出")
        }
        return title.string(for: language)
    }
}
