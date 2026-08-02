import RillCore

enum ClipboardItemDryRunCopy {
    case button
    case sheetTitle
    case previewNotice
    case runtimeNotice
    case operation
    case workflow
    case noWorkflow
    case loading
    case refresh
    case close
    case retry
    case reads
    case transforms
    case effects
    case destinations
    case replacement
    case privacyConditions
    case issues
    case none
    case itemUnavailable
    case itemChanged
    case workflowUnavailable
    case providerUnavailable
    case invalidReceipt
}

extension UIStrings {
    static func clipboardItemDryRunCopy(
        _ copy: ClipboardItemDryRunCopy,
        language: AppLanguage
    ) -> String {
        switch (language, copy) {
        case (.english, .button): "Preview effects"
        case (.simplifiedChinese, .button): "预览影响"
        case (.english, .sheetTitle): "Clipboard operation preview"
        case (.simplifiedChinese, .sheetTitle): "剪贴板操作预览"
        case (.english, .previewNotice):
            "Generating this preview does not paste, modify, send, automate, write files, update history, or request confirmation."
        case (.simplifiedChinese, .previewNotice):
            "生成此预演不会粘贴、修改、发送、运行自动化、写入文件、更新历史或请求确认。"
        case (.english, .runtimeNotice):
            "This describes a possible future operation, not permission to run it. Runtime checks the exact item, workflow, privacy, permissions, credentials, and destination again."
        case (.simplifiedChinese, .runtimeNotice):
            "这里描述的是未来可能执行的操作，并非运行许可。实际运行时仍会重新检查精确条目、工作流、隐私、权限、凭据与目标位置。"
        case (.english, .operation): "Operation"
        case (.simplifiedChinese, .operation): "操作"
        case (.english, .workflow): "Saved workflow"
        case (.simplifiedChinese, .workflow): "已保存工作流"
        case (.english, .noWorkflow): "No eligible saved workflow"
        case (.simplifiedChinese, .noWorkflow): "没有可用的已保存工作流"
        case (.english, .loading): "Building a content-free preview for this exact item…"
        case (.simplifiedChinese, .loading): "正在为此精确条目生成无正文预演…"
        case (.english, .refresh): "Refresh preview"
        case (.simplifiedChinese, .refresh): "刷新预览"
        case (.english, .close): "Close"
        case (.simplifiedChinese, .close): "关闭"
        case (.english, .retry): "Try again"
        case (.simplifiedChinese, .retry): "重试"
        case (.english, .reads): "Possible reads"
        case (.simplifiedChinese, .reads): "可能读取"
        case (.english, .transforms): "Processing steps"
        case (.simplifiedChinese, .transforms): "处理步骤"
        case (.english, .effects): "Possible effects"
        case (.simplifiedChinese, .effects): "可能产生的影响"
        case (.english, .destinations): "Processing destinations"
        case (.simplifiedChinese, .destinations): "处理位置"
        case (.english, .replacement): "Source-item replacement"
        case (.simplifiedChinese, .replacement): "来源条目替换"
        case (.english, .privacyConditions): "Privacy conditions"
        case (.simplifiedChinese, .privacyConditions): "隐私条件"
        case (.english, .issues): "Current issues"
        case (.simplifiedChinese, .issues): "当前问题"
        case (.english, .none): "None"
        case (.simplifiedChinese, .none): "无"
        case (.english, .itemUnavailable): "This clipboard item is no longer available."
        case (.simplifiedChinese, .itemUnavailable): "此剪贴板条目已不可用。"
        case (.english, .itemChanged): "The item changed while previewing. Refresh to inspect the new version."
        case (.simplifiedChinese, .itemChanged): "条目在预演期间发生变化，请刷新后检查新版本。"
        case (.english, .workflowUnavailable): "The selected saved workflow is no longer available."
        case (.simplifiedChinese, .workflowUnavailable): "所选已保存工作流已不可用。"
        case (.english, .providerUnavailable):
            "The preview service is unavailable. No clipboard content was included in the result."
        case (.simplifiedChinese, .providerUnavailable):
            "预演服务当前不可用，结果中未包含任何剪贴板内容。"
        case (.english, .invalidReceipt): "The preview could not be correlated and was rejected."
        case (.simplifiedChinese, .invalidReceipt): "无法关联验证预演结果，已拒绝展示。"
        }
    }

    static func clipboardItemDryRunOperation(
        _ operation: ClipboardItemDryRunOperation,
        language: AppLanguage
    ) -> String {
        switch (language, operation) {
        case (.english, .use): "Paste item"
        case (.simplifiedChinese, .use): "粘贴条目"
        case (.english, .replay): "Replay through workflow"
        case (.simplifiedChinese, .replay): "通过工作流重放"
        case (.english, .replace): "Process and replace source"
        case (.simplifiedChinese, .replace): "处理并替换来源"
        }
    }

    static func clipboardItemDryRunStatusTitle(
        _ status: ClipboardItemDryRunStatus,
        language: AppLanguage
    ) -> String {
        switch (language, status) {
        case (.english, .ready): "Preview checks passed"
        case (.simplifiedChinese, .ready): "预演检查已通过"
        case (.english, .requiresConfirmation): "Would ask at runtime"
        case (.simplifiedChinese, .requiresConfirmation): "运行时需要询问"
        case (.english, .blocked): "Blocked in this preview"
        case (.simplifiedChinese, .blocked): "当前预演已阻止"
        case (.english, .skipped): "Operation would be skipped"
        case (.simplifiedChinese, .skipped): "操作将被跳过"
        }
    }

    static func clipboardItemDryRunStatusDetail(
        _ receipt: ClipboardItemDryRunReceipt,
        language: AppLanguage
    ) -> String {
        if let reason = receipt.reason {
            return clipboardItemDryRunReason(reason, language: language)
        }
        return switch (language, receipt.status) {
        case (.english, .ready):
            "The advisory plan is internally consistent. It has not been authorized or executed."
        case (.simplifiedChinese, .ready):
            "建议性计划内部一致，但尚未获得授权，也未执行。"
        case (.english, .requiresConfirmation):
            "No confirmation is shown during preview. A future run would ask if the condition still applies."
        case (.simplifiedChinese, .requiresConfirmation):
            "预演期间不会请求确认；未来运行时若条件仍成立，才会询问。"
        case (.english, .blocked): "Review the issues below before considering a future run."
        case (.simplifiedChinese, .blocked): "考虑未来运行前，请先查看下方问题。"
        case (.english, .skipped): "The selected operation has no valid plan for this item."
        case (.simplifiedChinese, .skipped): "所选操作无法为此条目生成有效计划。"
        }
    }

    static func clipboardItemDryRunReason(
        _ reason: ClipboardItemDryRunReason,
        language: AppLanguage
    ) -> String {
        switch (language, reason) {
        case (.english, .sourceContentUnavailable): "The source has no transferable content."
        case (.simplifiedChinese, .sourceContentUnavailable): "来源条目没有可传输内容。"
        case (.english, .workflowRequired): "Select a saved workflow for this operation."
        case (.simplifiedChinese, .workflowRequired): "此操作需要选择已保存工作流。"
        case (.english, .unsupportedContentKind): "Workflow processing currently supports stored text only."
        case (.simplifiedChinese, .unsupportedContentKind): "工作流处理目前仅支持已存文本。"
        case (.english, .sourceExcludedFromWorkflowCapture): "The source is excluded from workflow processing."
        case (.simplifiedChinese, .sourceExcludedFromWorkflowCapture): "来源条目已排除在工作流处理之外。"
        case (.english, .legacyWorkflowUnsupported): "This workflow uses an unsupported legacy execution model."
        case (.simplifiedChinese, .legacyWorkflowUnsupported): "此工作流使用了不受支持的旧执行模型。"
        case (.english, .componentUnclassified): "A pipeline component could not be classified."
        case (.simplifiedChinese, .componentUnclassified): "无法对某个流水线组件进行分类。"
        case (.english, .configurationMissing): "A required output configuration is missing."
        case (.simplifiedChinese, .configurationMissing): "缺少必需的输出配置。"
        case (.english, .configurationInvalid): "An output configuration is invalid."
        case (.simplifiedChinese, .configurationInvalid): "某项输出配置无效。"
        case (.english, .privacyEvaluationUnavailable): "Current privacy conditions could not be evaluated."
        case (.simplifiedChinese, .privacyEvaluationUnavailable): "无法评估当前隐私条件。"
        case (.english, .privacyProcessingBlocked): "Current privacy policy blocks this processing plan."
        case (.simplifiedChinese, .privacyProcessingBlocked): "当前隐私策略阻止此处理计划。"
        case (.english, .noSourceReplacementEffect): "The workflow has no source-item replacement output."
        case (.simplifiedChinese, .noSourceReplacementEffect): "此工作流没有替换来源条目的输出。"
        case (.english, .ambiguousSourceReplacement): "More than one output could replace the source item."
        case (.simplifiedChinese, .ambiguousSourceReplacement): "有多个输出可能替换来源条目。"
        }
    }

    static func clipboardItemDryRunRead(
        _ category: ClipboardItemDryRunReadCategory,
        language: AppLanguage
    ) -> String {
        switch (language, category) {
        case (.english, .sourceItemText): "Stored source text"
        case (.simplifiedChinese, .sourceItemText): "已存来源文本"
        case (.english, .sourceItemImage): "Stored source image"
        case (.simplifiedChinese, .sourceItemImage): "已存来源图片"
        case (.english, .sourceItemFiles): "Stored source files"
        case (.simplifiedChinese, .sourceItemFiles): "已存来源文件"
        case (.english, .focusedApplicationIdentity): "Focused application identity"
        case (.simplifiedChinese, .focusedApplicationIdentity): "当前应用身份"
        case (.english, .currentClipboardDescriptor): "Current clipboard type and tags"
        case (.simplifiedChinese, .currentClipboardDescriptor): "当前剪贴板类型与标签"
        case (.english, .currentClipboardContents): "Current clipboard contents"
        case (.simplifiedChinese, .currentClipboardContents): "当前剪贴板内容"
        case (.english, .privacySettings): "Privacy settings"
        case (.simplifiedChinese, .privacySettings): "隐私设置"
        case (.english, .workflowConfiguration): "Saved workflow configuration"
        case (.simplifiedChinese, .workflowConfiguration): "已保存工作流配置"
        case (.english, .vocabularyRules): "Vocabulary rules"
        case (.simplifiedChinese, .vocabularyRules): "词汇规则"
        case (.english, .vocabularyScope): "Vocabulary scope metadata"
        case (.simplifiedChinese, .vocabularyScope): "词汇作用域元数据"
        }
    }

    static func clipboardItemDryRunEffect(
        _ effect: ClipboardItemDryRunEffect,
        language: AppLanguage
    ) -> String {
        switch (language, effect) {
        case (.english, .temporaryClipboardWrite): "Temporarily write the system clipboard"
        case (.simplifiedChinese, .temporaryClipboardWrite): "临时写入系统剪贴板"
        case (.english, .focusedApplicationWrite): "Write the focused application"
        case (.simplifiedChinese, .focusedApplicationWrite): "写入当前应用"
        case (.english, .clipboardHistoryUsageWrite): "Update item usage metadata"
        case (.simplifiedChinese, .clipboardHistoryUsageWrite): "更新条目使用元数据"
        case (.english, .clipboardWrite): "Write the system clipboard"
        case (.simplifiedChinese, .clipboardWrite): "写入系统剪贴板"
        case (.english, .clipboardHistoryWrite): "Create clipboard history"
        case (.simplifiedChinese, .clipboardHistoryWrite): "创建剪贴板历史"
        case (.english, .deliveryStackWrite): "Write the delivery stack"
        case (.simplifiedChinese, .deliveryStackWrite): "写入投递栈"
        case (.english, .sourceItemReplacement): "Replace the exact source item"
        case (.simplifiedChinese, .sourceItemReplacement): "替换精确来源条目"
        case (.english, .webhookRequest): "Send a webhook request"
        case (.simplifiedChinese, .webhookRequest): "发送 Webhook 请求"
        case (.english, .shortcutInvocation): "Run a Shortcut"
        case (.simplifiedChinese, .shortcutInvocation): "运行快捷指令"
        case (.english, .temporaryFileWrite): "Create a temporary file"
        case (.simplifiedChinese, .temporaryFileWrite): "创建临时文件"
        case (.english, .fileAppend): "Append a configured file"
        case (.simplifiedChinese, .fileAppend): "追加已配置文件"
        case (.english, .speechPlayback): "Play speech"
        case (.simplifiedChinese, .speechPlayback): "播放语音"
        case (.english, .unclassified): "Unclassified effect"
        case (.simplifiedChinese, .unclassified): "未分类影响"
        }
    }

    static func clipboardItemDryRunReplacement(
        _ plan: ClipboardItemDryRunSourceReplacementPlan,
        language: AppLanguage
    ) -> String {
        switch (language, plan) {
        case (.english, .notRequested): "The selected operation does not request replacement."
        case (.simplifiedChinese, .notRequested): "所选操作不要求替换来源。"
        case (.english, .unavailable): "No output can replace the source item."
        case (.simplifiedChinese, .unavailable): "没有输出能够替换来源条目。"
        case (.english, .exactlyOne): "Exactly one output would replace the exact source item."
        case (.simplifiedChinese, .exactlyOne): "恰有一个输出会替换精确来源条目。"
        case (.english, .ambiguous): "Multiple outputs could replace the source item."
        case (.simplifiedChinese, .ambiguous): "多个输出可能替换来源条目。"
        }
    }

    static func clipboardItemDryRunIssue(
        _ issue: ClipboardItemDryRunIssue,
        language: AppLanguage
    ) -> String {
        let detail: String = switch (language, issue.kind) {
        case (.english, .sourceContentUnavailable): "Source content is unavailable"
        case (.simplifiedChinese, .sourceContentUnavailable): "来源内容不可用"
        case (.english, .workflowRequired): "A saved workflow is required"
        case (.simplifiedChinese, .workflowRequired): "需要已保存工作流"
        case (.english, .unsupportedContentKind): "Content kind is unsupported"
        case (.simplifiedChinese, .unsupportedContentKind): "内容类型不受支持"
        case (.english, .sourceExcludedFromWorkflowCapture): "Source excludes workflow processing"
        case (.simplifiedChinese, .sourceExcludedFromWorkflowCapture): "来源排除了工作流处理"
        case (.english, .legacyWorkflowUnsupported): "Legacy workflow execution is unsupported"
        case (.simplifiedChinese, .legacyWorkflowUnsupported): "不支持旧工作流执行"
        case (.english, .componentUnclassified): "Component is unclassified"
        case (.simplifiedChinese, .componentUnclassified): "组件未分类"
        case (.english, .configurationMissing): "Configuration is missing"
        case (.simplifiedChinese, .configurationMissing): "缺少配置"
        case (.english, .configurationInvalid): "Configuration is invalid"
        case (.simplifiedChinese, .configurationInvalid): "配置无效"
        case (.english, .privacyEvaluationUnavailable): "Privacy evaluation is unavailable"
        case (.simplifiedChinese, .privacyEvaluationUnavailable): "隐私评估不可用"
        case (.english, .privacyConfirmationRequired): "Runtime confirmation would be required"
        case (.simplifiedChinese, .privacyConfirmationRequired): "运行时需要确认"
        case (.english, .privacyProcessingBlocked): "Privacy policy blocks processing"
        case (.simplifiedChinese, .privacyProcessingBlocked): "隐私策略阻止处理"
        case (.english, .sourceReplacementUnavailable): "Source replacement is unavailable"
        case (.simplifiedChinese, .sourceReplacementUnavailable): "来源替换不可用"
        case (.english, .sourceReplacementAmbiguous): "Source replacement is ambiguous"
        case (.simplifiedChinese, .sourceReplacementAmbiguous): "来源替换不明确"
        }
        guard let index = issue.componentIndex else { return detail }
        return language == .english
            ? "Step \(index + 1): \(detail)"
            : "第 \(index + 1) 步：\(detail)"
    }

    static func clipboardItemDryRunUsage(
        _ usage: WorkflowExplanationUsage,
        language: AppLanguage
    ) -> String {
        switch (language, usage) {
        case (.english, .required): "Required"
        case (.simplifiedChinese, .required): "必需"
        case (.english, .conditional): "Conditional"
        case (.simplifiedChinese, .conditional): "按条件使用"
        case (.english, .unclassified): "Usage unclassified"
        case (.simplifiedChinese, .unclassified): "用途未分类"
        }
    }

    static func clipboardItemDryRunConfiguration(
        _ state: WorkflowExplanationConfigurationState,
        language: AppLanguage
    ) -> String {
        switch (language, state) {
        case (.english, .notRequired): "No configuration required"
        case (.simplifiedChinese, .notRequired): "无需配置"
        case (.english, .configured): "Configured"
        case (.simplifiedChinese, .configured): "已配置"
        case (.english, .missing): "Configuration missing"
        case (.simplifiedChinese, .missing): "缺少配置"
        case (.english, .invalid): "Configuration invalid"
        case (.simplifiedChinese, .invalid): "配置无效"
        case (.english, .unclassified): "Configuration unclassified"
        case (.simplifiedChinese, .unclassified): "配置未分类"
        }
    }
}
