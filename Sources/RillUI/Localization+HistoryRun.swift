import RillCore

extension L10n {
    static func workflowActionResult(
        _ result: WorkflowActionResultCode,
        language: AppLanguage
    ) -> String {
        switch (language, result) {
        case (.english, .injected): "Inserted"
        case (.simplifiedChinese, .injected): "已输入"
        case (.english, .copiedToClipboard): "Copied"
        case (.simplifiedChinese, .copiedToClipboard): "已复制"
        case (.english, .pushedToStack): "Saved to stack"
        case (.simplifiedChinese, .pushedToStack): "已存入堆栈"
        case (.english, .externalOutput): "External output completed"
        case (.simplifiedChinese, .externalOutput): "外部输出已完成"
        case (.english, .skipped): "Skipped"
        case (.simplifiedChinese, .skipped): "已跳过"
        case (.english, .cancelled): "Cancelled"
        case (.simplifiedChinese, .cancelled): "已取消"
        case (.english, .failed): "Failed"
        case (.simplifiedChinese, .failed): "失败"
        }
    }

    static func workflowRunTermination(
        _ termination: WorkflowRunTermination,
        language: AppLanguage
    ) -> String {
        switch termination {
        case .completed:
            return language == .english ? "Completed" : "已完成"
        case .partiallyCompleted:
            return language == .english ? "Partially completed" : "部分完成"
        case .failed:
            return language == .english ? "Failed" : "失败"
        case .cancelled:
            return language == .english ? "Cancelled" : "已取消"
        case let .skipped(reason):
            let outcome = language == .english ? "Skipped" : "已跳过"
            return "\(outcome) — \(workflowRunSkipReason(reason, language: language))"
        }
    }

    static func workflowRunSkipReason(
        _ reason: WorkflowRunSkipCode,
        language: AppLanguage
    ) -> String {
        switch (language, reason) {
        case (.english, .workflowDisabled): "Workflow is disabled"
        case (.simplifiedChinese, .workflowDisabled): "工作流已停用"
        case (.english, .busy): "Rill is busy"
        case (.simplifiedChinese, .busy): "Rill 正忙"
        case (.english, .unsupported): "Workflow is not supported"
        case (.simplifiedChinese, .unsupported): "当前不支持此工作流"
        case (.english, .privacyBlocked): "Blocked by privacy settings"
        case (.simplifiedChinese, .privacyBlocked): "已被隐私设置阻止"
        case (.english, .eventKindMismatch): "Event type did not match"
        case (.simplifiedChinese, .eventKindMismatch): "事件类型不匹配"
        case (.english, .sourceGroupMismatch): "Source group did not match"
        case (.simplifiedChinese, .sourceGroupMismatch): "来源分组不匹配"
        case (.english, .excludedByCaptureTag): "Excluded by capture tag"
        case (.simplifiedChinese, .excludedByCaptureTag): "已被捕获标签排除"
        case (.english, .conditionFailed): "Trigger condition did not match"
        case (.simplifiedChinese, .conditionFailed): "触发条件不匹配"
        case (.english, .itemMissing): "Clipboard item is no longer available"
        case (.simplifiedChinese, .itemMissing): "剪贴板条目已不可用"
        case (.english, .itemChanged): "Clipboard item changed before it could run"
        case (.simplifiedChinese, .itemChanged): "剪贴板条目在运行前已发生变化"
        case (.english, .loopPrevented): "Automation loop prevented"
        case (.simplifiedChinese, .loopPrevented): "已阻止自动化循环"
        case (.english, .allActionsSkipped): "All actions were skipped"
        case (.simplifiedChinese, .allActionsSkipped): "所有动作均已跳过"
        case (.english, .unclassified): "Skip reason is unavailable"
        case (.simplifiedChinese, .unclassified): "跳过原因不可用"
        }
    }

    static func historyRunAccessibilityLabel(
        status: String,
        title: String,
        termination: WorkflowRunTermination?,
        language: AppLanguage
    ) -> String {
        let summary = "\(status): \(title)"
        guard case let .skipped(reason)? = termination else {
            return summary
        }
        return "\(summary), \(workflowRunSkipReason(reason, language: language))"
    }
}
