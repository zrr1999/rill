import Foundation
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
        case (.english, .storedRecord): "Saved to Records"
        case (.simplifiedChinese, .storedRecord): "已存入记录"
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
        case (.english, .sourceCollectionMismatch): "Source collection did not match"
        case (.simplifiedChinese, .sourceCollectionMismatch): "来源记录集不匹配"
        case (.english, .excludedByCaptureTag): "Excluded by capture tag"
        case (.simplifiedChinese, .excludedByCaptureTag): "已被捕获标签排除"
        case (.english, .conditionFailed): "Trigger condition did not match"
        case (.simplifiedChinese, .conditionFailed): "触发条件不匹配"
        case (.english, .recordMissing): "Record is no longer available"
        case (.simplifiedChinese, .recordMissing): "记录已不可用"
        case (.english, .recordChanged): "Record changed before it could run"
        case (.simplifiedChinese, .recordChanged): "记录在运行前已发生变化"
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

    static func historyRunTrigger(
        _ trigger: WorkflowRunTriggerKind,
        language: AppLanguage
    ) -> String {
        switch (language, trigger) {
        case (.english, .manual): "Manual"
        case (.simplifiedChinese, .manual): "手动"
        case (.english, .menuBar): "Menu bar"
        case (.simplifiedChinese, .menuBar): "菜单栏"
        case (.english, .hotkey): "Hotkey"
        case (.simplifiedChinese, .hotkey): "快捷键"
        case (.english, .wakeWord): "Wake word"
        case (.simplifiedChinese, .wakeWord): "唤醒词"
        case (.english, .recordCollectionEvent): "Collection event"
        case (.simplifiedChinese, .recordCollectionEvent): "记录集事件"
        case (.english, .recordDelivery): "Record delivery"
        case (.simplifiedChinese, .recordDelivery): "记录投递"
        case (.english, .recordUse): "Record use"
        case (.simplifiedChinese, .recordUse): "记录使用"
        case (.english, .recordReplay): "Record replay"
        case (.simplifiedChinese, .recordReplay): "记录重放"
        case (.english, .failedAudioRecovery): "Audio recovery"
        case (.simplifiedChinese, .failedAudioRecovery): "录音恢复"
        }
    }

    static func historyRunDurationBucket(
        _ bucket: WorkflowRunDurationBucket,
        language: AppLanguage
    ) -> String {
        switch (language, bucket) {
        case (.english, .under250ms): "under 250 ms"
        case (.simplifiedChinese, .under250ms): "少于 250 毫秒"
        case (.english, .ms250To999): "250–999 ms"
        case (.simplifiedChinese, .ms250To999): "250–999 毫秒"
        case (.english, .s1To4): "1–4 s"
        case (.simplifiedChinese, .s1To4): "1–4 秒"
        case (.english, .s5To14): "5–14 s"
        case (.simplifiedChinese, .s5To14): "5–14 秒"
        case (.english, .s15To59): "15–59 s"
        case (.simplifiedChinese, .s15To59): "15–59 秒"
        case (.english, .m1Plus): "1 min or more"
        case (.simplifiedChinese, .m1Plus): "1 分钟以上"
        case (.english, .unavailable): "duration unavailable"
        case (.simplifiedChinese, .unavailable): "耗时不可用"
        }
    }

    static func historyProcessingDuration(_ milliseconds: UInt64, language: AppLanguage) -> String {
        if milliseconds < 1_000 {
            return language == .english ? "\(milliseconds) ms" : "\(milliseconds) 毫秒"
        }
        let fraction = String(format: "%03d", Int(milliseconds % 1_000))
        let seconds = "\(milliseconds / 1_000).\(fraction)"
        return language == .english ? "\(seconds) s" : "\(seconds) 秒"
    }

    /// Timeline status is a reason-free rollup of `WorkflowRunTermination`;
    /// the skipped case cannot carry the receipt's skip reason here, so the
    /// labels stay plain instead of routing through `workflowRunTermination`.
    static func historyRunStatus(
        _ status: HistoryTimelineStatus,
        language: AppLanguage
    ) -> String {
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

    static func historyTimelineText(
        _ key: HistoryTimelineTextKey,
        language: AppLanguage
    ) -> String {
        historyTimelineTextTable[key]?.string(for: language) ?? key.rawValue
    }

    static func historyTimelineAction(_ number: Int, language: AppLanguage) -> String {
        String(format: historyTimelineText(.actionFormat, language: language), number)
    }

    static func historyTimelineLLMRequestStep(_ step: Int, language: AppLanguage) -> String {
        String(format: historyTimelineText(.llmRequestStepFormat, language: language), step)
    }

    static func historyTimelineSentMessage(
        role: String,
        number: Int,
        language: AppLanguage
    ) -> String {
        String(
            format: historyTimelineText(.sentMessageFormat, language: language),
            role,
            number
        )
    }

    static func historyTimelineMessageRole(
        _ role: LanguageModelTraceMessage.Role,
        language: AppLanguage
    ) -> String {
        switch (language, role) {
        case (.english, .user): "User"
        case (.simplifiedChinese, .user): "用户"
        case (.english, .assistant): "Assistant"
        case (.simplifiedChinese, .assistant): "助手"
        }
    }

    static func historyTimelineSentToLLMStep(_ step: Int, language: AppLanguage) -> String {
        String(format: historyTimelineText(.sentToLLMStepFormat, language: language), step)
    }

    private static let historyTimelineTextTable: [HistoryTimelineTextKey: LocalizedText] = [
        .actionDetailsTruncated: .init(
            english: "Additional action details were omitted.",
            simplifiedChinese: "其余动作详情已省略。"
        ),
        .actionFormat: .init(english: "Action %d", simplifiedChinese: "动作 %d"),
        .copyFailureDetails: .init(
            english: "Copy failure details",
            simplifiedChinese: "复制失败详情"
        ),
        .executionDetailsUnavailable: .init(
            english: "Execution details are unavailable for this older run.",
            simplifiedChinese: "这条较早的运行没有可用的执行详情。"
        ),
        .llmAnswer: .init(english: "LLM answer", simplifiedChinese: "LLM 回答"),
        .llmRequest: .init(english: "LLM request", simplifiedChinese: "LLM 请求"),
        .llmRequestStepFormat: .init(
            english: "LLM request · Step %d",
            simplifiedChinese: "LLM 请求 · 第 %d 步"
        ),
        .model: .init(english: "Model", simplifiedChinese: "模型"),
        .provider: .init(english: "Provider", simplifiedChinese: "提供商"),
        .recognizedInputLegacy: .init(
            english: "Recognized input (older record)",
            simplifiedChinese: "识别输入（旧记录）"
        ),
        .returnedText: .init(english: "Returned text", simplifiedChinese: "返回文本"),
        .sentMessageFormat: .init(
            english: "Sent message · %@ %d",
            simplifiedChinese: "发送消息 · %@ %d"
        ),
        .sentToLLM: .init(english: "Sent to LLM", simplifiedChinese: "发送给 LLM"),
        .sentToLLMStepFormat: .init(
            english: "Sent to LLM · Step %d",
            simplifiedChinese: "发送给 LLM · 第 %d 步"
        ),
        .systemPrompt: .init(english: "System prompt", simplifiedChinese: "系统提示词"),
        .workflowPrompt: .init(english: "Workflow prompt", simplifiedChinese: "工作流提示词"),
        .workflowRunFallback: .init(english: "Workflow run", simplifiedChinese: "工作流运行"),
    ]
}

enum HistoryTimelineTextKey: String, CaseIterable, Sendable {
    case actionDetailsTruncated
    case actionFormat
    case copyFailureDetails
    case executionDetailsUnavailable
    case llmAnswer
    case llmRequest
    case llmRequestStepFormat
    case model
    case provider
    case recognizedInputLegacy
    case returnedText
    case sentMessageFormat
    case sentToLLM
    case sentToLLMStepFormat
    case systemPrompt
    case workflowPrompt
    case workflowRunFallback
}
