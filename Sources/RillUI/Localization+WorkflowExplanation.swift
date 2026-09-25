import RillCore

enum WorkflowExplanationCopy {
    case button
    case sheetTitle
    case previewNotice
    case savedVersionNotice
    case saveBeforePreview
    case loading
    case refresh
    case close
    case retry
    case trigger
    case inputs
    case transforms
    case outputs
    case destinations
    case privacyConditions
    case issues
    case none
    case providerUnavailable
    case workflowUnavailable
    case invalidReceipt
}

extension L10n {
    static func workflowExplanationCopy(
        _ copy: WorkflowExplanationCopy,
        language: AppLanguage
    ) -> String {
        switch (language, copy) {
        case (.english, .button): "Explain before run"
        case (.simplifiedChinese, .button): "运行前说明"
        case (.english, .sheetTitle): "Current run preview"
        case (.simplifiedChinese, .sheetTitle): "当前运行预览"
        case (.english, .previewNotice):
            "This preview does not authorize a run. Rill checks privacy and routing conditions again at runtime."
        case (.simplifiedChinese, .previewNotice):
            "此预览不代表运行授权。Rill 会在实际运行时重新检查隐私与路由条件。"
        case (.english, .savedVersionNotice): "The preview uses the saved workflow configuration."
        case (.simplifiedChinese, .savedVersionNotice): "预览使用已保存的工作流配置。"
        case (.english, .saveBeforePreview): "Save the visible changes before previewing this workflow."
        case (.simplifiedChinese, .saveBeforePreview): "请先保存当前可见改动，再预览此工作流。"
        case (.english, .loading): "Checking the current privacy and routing conditions…"
        case (.simplifiedChinese, .loading): "正在检查当前隐私与路由条件…"
        case (.english, .refresh): "Refresh preview"
        case (.simplifiedChinese, .refresh): "刷新预览"
        case (.english, .close): "Close"
        case (.simplifiedChinese, .close): "关闭"
        case (.english, .retry): "Try again"
        case (.simplifiedChinese, .retry): "重试"
        case (.english, .trigger): "Trigger"
        case (.simplifiedChinese, .trigger): "触发方式"
        case (.english, .inputs): "Inputs"
        case (.simplifiedChinese, .inputs): "输入"
        case (.english, .transforms): "Transforms"
        case (.simplifiedChinese, .transforms): "处理步骤"
        case (.english, .outputs): "Output effects"
        case (.simplifiedChinese, .outputs): "输出效果"
        case (.english, .destinations): "Processing destinations"
        case (.simplifiedChinese, .destinations): "处理位置"
        case (.english, .privacyConditions): "Privacy conditions"
        case (.simplifiedChinese, .privacyConditions): "隐私条件"
        case (.english, .issues): "Current issues"
        case (.simplifiedChinese, .issues): "当前问题"
        case (.english, .none): "None"
        case (.simplifiedChinese, .none): "无"
        case (.english, .providerUnavailable):
            "The current preview is unavailable. No workflow content was exposed."
        case (.simplifiedChinese, .providerUnavailable):
            "当前预览不可用，且未暴露任何工作流内容。"
        case (.english, .workflowUnavailable): "This workflow is no longer available."
        case (.simplifiedChinese, .workflowUnavailable): "此工作流已不可用。"
        case (.english, .invalidReceipt): "The preview could not be verified and was rejected."
        case (.simplifiedChinese, .invalidReceipt): "无法验证预览结果，已拒绝展示。"
        }
    }

    static func workflowExplanationFailure(
        _ failure: WorkflowExplanationFailure,
        language: AppLanguage
    ) -> String {
        switch failure {
        case .workflowUnavailable:
            workflowExplanationCopy(.workflowUnavailable, language: language)
        case .providerUnavailable:
            workflowExplanationCopy(.providerUnavailable, language: language)
        case .invalidReceipt:
            workflowExplanationCopy(.invalidReceipt, language: language)
        }
    }

    static func workflowExplanationStatusTitle(
        _ status: WorkflowExplanationStatus,
        language: AppLanguage
    ) -> String {
        switch (language, status) {
        case (.english, .ready): "Current privacy preview passed"
        case (.simplifiedChinese, .ready): "当前隐私预检已通过"
        case (.english, .requiresConfirmation): "Will ask at runtime"
        case (.simplifiedChinese, .requiresConfirmation): "运行时将询问"
        case (.english, .blocked): "Blocked in this preview"
        case (.simplifiedChinese, .blocked): "当前预览已阻止"
        }
    }

    static func workflowExplanationStatusDetail(
        _ status: WorkflowExplanationStatus,
        language: AppLanguage
    ) -> String {
        switch (language, status) {
        case (.english, .ready):
            "This is not a full readiness check. Runtime rechecks privacy, permissions, credentials, and destinations before execution."
        case (.simplifiedChinese, .ready):
            "这不是完整的可运行性检查；实际执行前仍会重新检查隐私、权限、凭据与输出位置。"
        case (.english, .requiresConfirmation):
            "No prompt is shown while previewing. Rill will ask immediately before the run if still required."
        case (.simplifiedChinese, .requiresConfirmation):
            "预览时不会弹窗；若运行时仍需确认，Rill 会在执行前询问。"
        case (.english, .blocked):
            "The workflow cannot run under the current preview conditions. Review every issue below."
        case (.simplifiedChinese, .blocked):
            "当前预览条件下无法运行此工作流，请查看下方全部问题。"
        }
    }

    static func workflowExplanationTrigger(
        _ trigger: WorkflowExplanationTriggerCategory,
        language: AppLanguage
    ) -> String {
        switch (language, trigger) {
        case (.english, .manual): "Manual"
        case (.simplifiedChinese, .manual): "手动"
        case (.english, .hotkey): "Hotkey"
        case (.simplifiedChinese, .hotkey): "快捷键"
        case (.english, .menuBar): "Menu bar"
        case (.simplifiedChinese, .menuBar): "菜单栏"
        case (.english, .wakeWord): "Wake word"
        case (.simplifiedChinese, .wakeWord): "唤醒词"
        }
    }

    static func workflowExplanationInput(
        _ category: WorkflowExplanationInputCategory,
        language: AppLanguage
    ) -> String {
        switch (language, category) {
        case (.english, .microphoneAudio): "Microphone audio"
        case (.simplifiedChinese, .microphoneAudio): "麦克风音频"
        case (.english, .recognitionHints): "Recognition hints"
        case (.simplifiedChinese, .recognitionHints): "识别提示词"
        case (.english, .focusedSelection): "Focused selection"
        case (.simplifiedChinese, .focusedSelection): "当前选区"
        case (.english, .clipboardText): "Clipboard text"
        case (.simplifiedChinese, .clipboardText): "剪贴板文本"
        case (.english, .unclassified): "Unclassified input"
        case (.simplifiedChinese, .unclassified): "未分类输入"
        }
    }

    static func workflowExplanationTransform(
        _ kind: WorkflowExplanationTransformKind,
        language: AppLanguage
    ) -> String {
        switch (language, kind) {
        case (.english, .vocabularyMapping): "Vocabulary mapping"
        case (.simplifiedChinese, .vocabularyMapping): "词汇映射"
        case (.english, .snippetReplacement): "Snippet replacement"
        case (.simplifiedChinese, .snippetReplacement): "片段替换"
        case (.english, .languageModelRewrite): "Language-model rewrite"
        case (.simplifiedChinese, .languageModelRewrite): "语言模型改写"
        case (.english, .languageModelAnswer): "Language-model answer"
        case (.simplifiedChinese, .languageModelAnswer): "语言模型回答"
        case (.english, .whitespaceNormalization): "Whitespace normalization"
        case (.simplifiedChinese, .whitespaceNormalization): "空白规范化"
        }
    }

    static func workflowExplanationOutput(
        _ effect: WorkflowExplanationOutputEffect,
        language: AppLanguage
    ) -> String {
        switch (language, effect) {
        case (.english, .clipboardWrite): "Write system clipboard"
        case (.simplifiedChinese, .clipboardWrite): "写入系统剪贴板"
        case (.english, .focusedApplicationWrite): "Write focused application"
        case (.simplifiedChinese, .focusedApplicationWrite): "写入当前应用"
        case (.english, .recordStoreWrite): "Save record"
        case (.simplifiedChinese, .recordStoreWrite): "保存记录"
        case (.english, .webhookRequest): "Send webhook request"
        case (.simplifiedChinese, .webhookRequest): "发送 Webhook 请求"
        case (.english, .shortcutInvocation): "Run Shortcut"
        case (.simplifiedChinese, .shortcutInvocation): "运行快捷指令"
        case (.english, .fileAppend): "Append local file"
        case (.simplifiedChinese, .fileAppend): "追加本地文件"
        case (.english, .speechPlayback): "Play speech"
        case (.simplifiedChinese, .speechPlayback): "播放语音"
        case (.english, .unclassified): "Unclassified output"
        case (.simplifiedChinese, .unclassified): "未分类输出"
        }
    }

    static func workflowExplanationDestination(
        _ destination: WorkflowExplanationProcessingDestination,
        language: AppLanguage
    ) -> String {
        switch (language, destination) {
        case (.english, .onDevice): "Processed by Rill on this Mac"
        case (.simplifiedChinese, .onDevice): "由 Rill 在本机处理"
        case (.english, .cloudService): "Cloud speech service"
        case (.simplifiedChinese, .cloudService): "云端语音服务"
        case (.english, .clipboard):
            "Handed to the system clipboard; it may sync under system settings"
        case (.simplifiedChinese, .clipboard):
            "交给系统剪贴板；它可能按系统设置同步"
        case (.english, .focusedApplication):
            "Handed to the focused application; later behavior follows that application"
        case (.simplifiedChinese, .focusedApplication):
            "交给当前应用；后续行为取决于该应用"
        case (.english, .localStorage): "Stored in Rill application storage"
        case (.simplifiedChinese, .localStorage): "保存到 Rill 应用存储"
        case (.english, .localAutomation):
            "Handed to macOS automation; it may access the network, and this preview cannot prove it stays on this Mac"
        case (.simplifiedChinese, .localAutomation):
            "交给 macOS 自动化；它可能访问网络，此预览无法证明数据仍留在本机"
        case (.english, .localFile):
            "Handed to the configured file; it may sync, and this preview cannot prove it stays on this Mac"
        case (.simplifiedChinese, .localFile):
            "交给已配置文件；它可能被同步，此预览无法证明数据仍留在本机"
        case (.english, .remoteEndpoint): "Remote endpoint"
        case (.simplifiedChinese, .remoteEndpoint): "远程端点"
        case (.english, .unclassified): "Unclassified destination"
        case (.simplifiedChinese, .unclassified): "未分类位置"
        }
    }

    static func workflowExplanationInputDetail(
        _ input: WorkflowExplanationInput,
        privacyRedacted: Bool,
        language: AppLanguage
    ) -> String {
        [
            workflowExplanationUsage(input.usage, language: language),
            workflowExplanationInputAvailability(
                input.availability,
                privacyRedacted: privacyRedacted,
                language: language
            ),
            workflowExplanationDestination(input.processingDestination, language: language),
        ].joined(separator: " • ")
    }

    static func workflowExplanationTransformDetail(
        _ transform: WorkflowExplanationTransform,
        language: AppLanguage
    ) -> String {
        [
            workflowExplanationUsage(transform.usage, language: language),
            workflowExplanationAvailability(transform.availability, language: language),
            workflowExplanationDestination(transform.processingDestination, language: language),
        ].joined(separator: " • ")
    }

    static func workflowExplanationOutputDetail(
        _ output: WorkflowExplanationOutput,
        language: AppLanguage
    ) -> String {
        [
            workflowExplanationAvailability(output.availability, language: language),
            workflowExplanationConfiguration(output.configurationState, language: language),
            workflowExplanationDestination(output.processingDestination, language: language),
        ].joined(separator: " • ")
    }

    static func workflowExplanationIssue(
        _ issue: WorkflowExplanationIssue,
        language: AppLanguage
    ) -> String {
        let component = workflowExplanationComponent(issue.component, language: language)
        let location: String
        if let index = issue.componentIndex {
            location = language == .english
                ? "\(component), step \(index + 1)"
                : "\(component)，第 \(index + 1) 步"
        } else {
            location = component
        }
        return "\(location): \(workflowExplanationIssueKind(issue.kind, language: language))"
    }

    static func workflowExplanationPrivacyReasons(
        _ reasons: [PrivacyRunEvaluationReason],
        language: AppLanguage
    ) -> [String] {
        var unique: [PrivacyRunEvaluationReason] = []
        for reason in reasons where !unique.contains(reason) {
            unique.append(reason)
        }
        if unique.contains(.cloudProcessingBlocked) || unique.contains(.cloudConfirmationRequired) {
            unique.removeAll { $0 == .cloudProviderSelected }
        }
        return unique.map { workflowExplanationPrivacyReason($0, language: language) }
    }

    private static func workflowExplanationPrivacyReason(
        _ reason: PrivacyRunEvaluationReason,
        language: AppLanguage
    ) -> String {
        switch (language, reason) {
        case (.english, .sensitiveApplication): "The focused application is covered by a sensitive-app rule."
        case (.simplifiedChinese, .sensitiveApplication): "当前应用命中了敏感应用规则。"
        case (.english, .secureInput): "Secure Input limits context access."
        case (.simplifiedChinese, .secureInput): "安全输入模式限制了上下文访问。"
        case (.english, .userDisabledClipboardHistory): "Clipboard history is disabled by the user."
        case (.simplifiedChinese, .userDisabledClipboardHistory): "用户已关闭剪贴板历史。"
        case (.english, .cloudProviderSelected): "This plan includes cloud processing."
        case (.simplifiedChinese, .cloudProviderSelected): "此计划包含云端处理。"
        case (.english, .itemTaggedExcludeFromWorkflowCapture):
            "The source item is marked to stay out of workflow capture."
        case (.simplifiedChinese, .itemTaggedExcludeFromWorkflowCapture):
            "来源条目被标记为不参与工作流捕获。"
        case (.english, .unknownFocusContext): "The focused application could not be classified."
        case (.simplifiedChinese, .unknownFocusContext): "无法对当前应用进行分类。"
        case (.english, .concealedClipboard): "The clipboard content is concealed."
        case (.simplifiedChinese, .concealedClipboard): "剪贴板内容处于隐藏状态。"
        case (.english, .transientClipboard): "The clipboard content is transient."
        case (.simplifiedChinese, .transientClipboard): "剪贴板内容是临时内容。"
        case (.english, .autoGeneratedClipboard): "The clipboard content was generated automatically."
        case (.simplifiedChinese, .autoGeneratedClipboard): "剪贴板内容由系统自动生成。"
        case (.english, .cloudProcessingBlocked): "Current privacy policy blocks cloud processing."
        case (.simplifiedChinese, .cloudProcessingBlocked): "当前隐私策略阻止云端处理。"
        case (.english, .cloudConfirmationRequired): "Rill will ask before cloud processing at runtime."
        case (.simplifiedChinese, .cloudConfirmationRequired): "Rill 会在运行时进行云端处理前询问。"
        case (.english, .privacySettingsUnavailable): "Privacy settings are currently unavailable."
        case (.simplifiedChinese, .privacySettingsUnavailable): "隐私设置当前不可用。"
        case (.english, .processingDestinationUnavailable):
            "A processing destination could not be classified."
        case (.simplifiedChinese, .processingDestinationUnavailable):
            "无法对某个处理位置进行分类。"
        }
    }

    private static func workflowExplanationUsage(
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

    private static func workflowExplanationAvailability(
        _ availability: WorkflowExplanationAvailability,
        language: AppLanguage
    ) -> String {
        switch (language, availability) {
        case (.english, .available): "Pipeline component available"
        case (.simplifiedChinese, .available): "管线组件可用"
        case (.english, .unavailable): "Pipeline component unavailable"
        case (.simplifiedChinese, .unavailable): "管线组件不可用"
        case (.english, .unclassified): "Component availability unclassified"
        case (.simplifiedChinese, .unclassified): "组件可用性未分类"
        }
    }

    private static func workflowExplanationInputAvailability(
        _ availability: WorkflowExplanationAvailability,
        privacyRedacted: Bool,
        language: AppLanguage
    ) -> String {
        switch (language, availability, privacyRedacted) {
        case (.english, .available, _):
            "Pipeline component available; current content and permission are not checked"
        case (.simplifiedChinese, .available, _):
            "管线组件可用；未检查当前内容与系统权限"
        case (.english, .unavailable, true): "Omitted by the current privacy preview"
        case (.simplifiedChinese, .unavailable, true): "已被当前隐私预检省略"
        case (.english, .unavailable, false): "Pipeline component unavailable"
        case (.simplifiedChinese, .unavailable, false): "管线组件不可用"
        case (.english, .unclassified, _): "Input availability unclassified"
        case (.simplifiedChinese, .unclassified, _): "输入可用性未分类"
        }
    }

    private static func workflowExplanationConfiguration(
        _ state: WorkflowExplanationConfigurationState,
        language: AppLanguage
    ) -> String {
        switch (language, state) {
        case (.english, .notRequired): "No setup required"
        case (.simplifiedChinese, .notRequired): "无需配置"
        case (.english, .configured): "Configured"
        case (.simplifiedChinese, .configured): "已配置"
        case (.english, .missing): "Setup missing"
        case (.simplifiedChinese, .missing): "缺少配置"
        case (.english, .invalid): "Setup invalid"
        case (.simplifiedChinese, .invalid): "配置无效"
        case (.english, .unclassified): "Setup unclassified"
        case (.simplifiedChinese, .unclassified): "配置未分类"
        }
    }

    private static func workflowExplanationComponent(
        _ component: WorkflowExplanationComponentKind,
        language: AppLanguage
    ) -> String {
        switch (language, component) {
        case (.english, .workflow): "Workflow"
        case (.simplifiedChinese, .workflow): "工作流"
        case (.english, .privacyPolicy): "Privacy policy"
        case (.simplifiedChinese, .privacyPolicy): "隐私策略"
        case (.english, .recognizer): "Speech recognition"
        case (.simplifiedChinese, .recognizer): "语音识别"
        case (.english, .transformer): "Transform"
        case (.simplifiedChinese, .transformer): "处理步骤"
        case (.english, .outputAction): "Output"
        case (.simplifiedChinese, .outputAction): "输出"
        }
    }

    private static func workflowExplanationIssueKind(
        _ kind: WorkflowExplanationIssueKind,
        language: AppLanguage
    ) -> String {
        switch (language, kind) {
        case (.english, .executionPlanUnresolved): "The execution plan is unresolved."
        case (.simplifiedChinese, .executionPlanUnresolved): "执行计划尚未解析。"
        case (.english, .legacyWorkflowUnsupported): "This legacy workflow is unsupported."
        case (.simplifiedChinese, .legacyWorkflowUnsupported): "不支持此旧版工作流。"
        case (.english, .privacyEvaluationUnavailable): "The privacy preview is unavailable."
        case (.simplifiedChinese, .privacyEvaluationUnavailable): "隐私预览不可用。"
        case (.english, .privacyConfirmationRequired): "Runtime privacy confirmation is required."
        case (.simplifiedChinese, .privacyConfirmationRequired): "运行时需要隐私确认。"
        case (.english, .privacyProcessingBlocked): "Current privacy policy blocks processing."
        case (.simplifiedChinese, .privacyProcessingBlocked): "当前隐私策略阻止处理。"
        case (.english, .privacyInputRedacted): "Sensitive input will be omitted."
        case (.simplifiedChinese, .privacyInputRedacted): "敏感输入将被省略。"
        case (.english, .componentUnavailable): "A required pipeline component is unavailable."
        case (.simplifiedChinese, .componentUnavailable): "所需管线组件不可用。"
        case (.english, .componentUnclassified): "A pipeline component is unclassified."
        case (.simplifiedChinese, .componentUnclassified): "管线组件尚未分类。"
        case (.english, .configurationMissing): "Required setup is missing."
        case (.simplifiedChinese, .configurationMissing): "缺少必需配置。"
        case (.english, .configurationInvalid): "The setup is invalid."
        case (.simplifiedChinese, .configurationInvalid): "配置无效。"
        }
    }
}
