import Foundation
import RillCore

extension L10n {
    static func runText(_ key: RunStatusTextKey, language: AppLanguage) -> String {
        runTextTable[key]?.string(for: language) ?? key.rawValue
    }

    static func runHistoryRetentionReadFailed(
        isRecordSetting: Bool,
        language: AppLanguage
    ) -> String {
        String(
            format: runText(.historyRetentionReadFailedFormat, language: language),
            runHistoryRetentionDomain(isRecordSetting: isRecordSetting, language: language)
        )
    }

    static func runHistoryRetentionInvalid(
        isRecordSetting: Bool,
        language: AppLanguage
    ) -> String {
        String(
            format: runText(.historyRetentionInvalidFormat, language: language),
            runHistoryRetentionDomain(isRecordSetting: isRecordSetting, language: language)
        )
    }

    static func runWakeWordWorkflowSaveFailed(
        detail: String,
        language: AppLanguage
    ) -> String {
        String(format: runText(.wakeWordWorkflowSaveFailedFormat, language: language), detail)
    }

    static func runWakeWordSettingsSaveFailed(
        detail: String,
        language: AppLanguage
    ) -> String {
        String(format: runText(.wakeWordSettingsSaveFailedFormat, language: language), detail)
    }

    private static func runHistoryRetentionDomain(
        isRecordSetting: Bool,
        language: AppLanguage
    ) -> String {
        runText(
            isRecordSetting ? .historyRetentionDomainClipboard : .historyRetentionDomainRunAndDiagnostic,
            language: language
        )
    }

    private static let runTextTable: [RunStatusTextKey: LocalizedText] = [
        .benchmarkClearFailed: .init(
            english: "Encrypted benchmark recordings could not be cleared.",
            simplifiedChinese: "无法清除加密的 Benchmark 录音。"
        ),
        .benchmarkSettingInvalid: .init(
            english: "Invalid benchmark recording setting was ignored; recording retention remains off.",
            simplifiedChinese: "已忽略无效的 Benchmark 录音设置；录音保留功能保持关闭。"
        ),
        .benchmarkStorageUnavailable: .init(
            english: "Encrypted benchmark recording storage is unavailable because persistent settings storage is unavailable.",
            simplifiedChinese: "持久化设置存储不可用，因此无法使用加密的 Benchmark 录音归档。"
        ),
        .benchmarkRetentionUpdateFailed: .init(
            english: "Benchmark recording retention could not be updated.",
            simplifiedChinese: "无法更新 Benchmark 录音保留设置。"
        ),
        .builtInWakeWorkflowUpdatedFormat: .init(
            english: "Built-in wake workflow updated: %@",
            simplifiedChinese: "内置唤醒工作流已更新：%@"
        ),
        .builtInWorkflowOverrideRemoveFailedFormat: .init(
            english: "The built-in workflow override could not be removed: %@",
            simplifiedChinese: "无法删除内置工作流覆盖文件：%@"
        ),
        .builtInWorkflowRestoredFormat: .init(
            english: "Built-in workflow restored: %@",
            simplifiedChinese: "内置工作流已恢复默认：%@"
        ),
        .clearRunHistoryBlockedActiveRun: .init(
            english: "Finish the active or queued voice run before clearing run and diagnostic history.",
            simplifiedChinese: "请先完成当前或排队中的语音运行，再清除运行与诊断历史。"
        ),
        .clipboardRetentionDamaged: .init(
            english: "Stored clipboard history retention is damaged; clipboard cleanup is paused until you save a valid period.",
            simplifiedChinese: "已保存的剪贴板历史留存设置损坏；保存有效时长前，剪贴板清理保持暂停。"
        ),
        .configurationStorageUnavailable: .init(
            english: "Configuration storage is unavailable. Settings and privacy controls could not be loaded.",
            simplifiedChinese: "配置存储不可用，无法加载设置与隐私控制。"
        ),
        .credentialSaveFailed: .init(
            english: "A speech-provider credential could not be saved. Review credential access in Settings.",
            simplifiedChinese: "语音服务凭据无法保存，请在设置页面检查凭据访问状态。"
        ),
        .diagnosticsRepositoryUnavailable: .init(
            english: "Diagnostics repository is unavailable.",
            simplifiedChinese: "诊断仓库不可用。"
        ),
        .failedRecordingNotRetainedFormat: .init(
            english: "The failed recording could not be retained. %@",
            simplifiedChinese: "无法保留失败录音。%@"
        ),
        .failedRecoverySettingInvalid: .init(
            english: "Invalid failed recording recovery setting was ignored; recovery remains off.",
            simplifiedChinese: "已忽略无效的失败录音恢复设置；恢复功能保持关闭。"
        ),
        .historyRetentionDomainClipboard: .init(
            english: "clipboard",
            simplifiedChinese: "剪贴板"
        ),
        .historyRetentionDomainRunAndDiagnostic: .init(
            english: "run and diagnostic",
            simplifiedChinese: "运行与诊断"
        ),
        .historyRetentionInvalidFormat: .init(
            english: "Invalid %@ history retention setting was ignored; cleanup for that domain is paused.",
            simplifiedChinese: "%@历史留存设置无效；该域清理已暂停。"
        ),
        .historyRetentionReadFailedFormat: .init(
            english: "A stored %@ history retention setting could not be read; cleanup for that domain is paused.",
            simplifiedChinese: "无法读取已保存的%@历史留存设置；该域清理已暂停。"
        ),
        .localHistoryUpdatedFormat: .init(
            english: "Local history updated: removed %d, preserved %d active clipboard item(s).",
            simplifiedChinese: "本地历史已更新：移除 %d 条，保留 %d 条仍在使用的剪贴板内容。"
        ),
        .localSpeechHardwareMemoryRecommendedFormat: .init(
            english: "%@ · %d GB memory recommended",
            simplifiedChinese: "%@ · 建议 %d GB 内存"
        ),
        .localSpeechHardwareMemoryRequiredFormat: .init(
            english: "%@ · At least %d GB memory required",
            simplifiedChinese: "%@ · 至少需要 %d GB 内存"
        ),
        .localSpeechHardwareRecommendedFormat: .init(
            english: "Recommended for this Mac (%d GB memory) · %@",
            simplifiedChinese: "推荐用于本机（%d GB 内存）· %@"
        ),
        .localSpeechModelMemoryReleased: .init(
            english: "Released the local speech model from memory. It will load again on the next local recognition.",
            simplifiedChinese: "已释放本地语音模型内存；下次本地识别时会重新加载。"
        ),
        .localSpeechModelReadyFormat: .init(
            english: "Local speech model is ready: %@",
            simplifiedChinese: "本地语音模型已准备就绪：%@"
        ),
        .maintenanceServiceUnavailable: .init(
            english: "Local history maintenance is unavailable. No history was removed.",
            simplifiedChinese: "本地历史维护服务不可用，没有移除任何历史记录。"
        ),
        .openAISettingsAvailableAgain: .init(
            english: "OpenAI settings and credential access are available again.",
            simplifiedChinese: "OpenAI 设置与凭据访问已恢复。"
        ),
        .openAISettingsStillUnavailable: .init(
            english: "OpenAI settings or credential access are still unavailable.",
            simplifiedChinese: "OpenAI 设置或凭据访问仍不可用。"
        ),
        .privacyLoadBlocked: .init(
            english: "Privacy settings could not be loaded. Privacy-related capture and cloud processing remain blocked.",
            simplifiedChinese: "隐私设置无法加载；隐私相关捕获与云端处理保持阻断。"
        ),
        .privacyLoadBlockedRetry: .init(
            english: "Privacy settings could not be loaded. Privacy-related capture and cloud processing remain blocked. Fix storage, then retry.",
            simplifiedChinese: "隐私设置无法加载；隐私相关捕获与云端处理保持阻断。修复存储后请重试。"
        ),
        .privacyLoadFailedRepairStorage: .init(
            english: "Privacy settings could not be loaded. Runtime privacy gates remain closed. Repair configuration storage, then retry.",
            simplifiedChinese: "隐私设置无法加载，运行时隐私闸门保持关闭。请修复配置存储后重试。"
        ),
        .privacySaveFailedRetry: .init(
            english: "Privacy settings could not be saved. Retry from the Privacy section in Settings.",
            simplifiedChinese: "隐私设置无法保存，请在设置页面的隐私区域重试。"
        ),
        .privacySaveFailedSessionOnly: .init(
            english: "Privacy settings could not be saved. Your changes remain active for this session but will be lost after restart. Retry from the Privacy section.",
            simplifiedChinese: "隐私设置无法保存；更改在本次会话中仍然有效，但重启后会丢失。请在隐私设置中重试。"
        ),
        .privacySaveStorageUnavailable: .init(
            english: "Privacy settings could not be saved because configuration storage is unavailable. Your changes remain active for this session only.",
            simplifiedChinese: "配置存储不可用，隐私设置无法保存；更改仅在本次会话中有效。"
        ),
        .privacySettingsDamaged: .init(
            english: "Privacy settings are damaged. Privacy-related capture and cloud processing remain blocked. Reset to safe defaults or repair storage, then retry.",
            simplifiedChinese: "隐私设置已损坏；隐私相关捕获与云端处理保持阻断。请恢复安全默认值或修复存储后重试。"
        ),
        .protectedSettingsReloaded: .init(
            english: "Protected settings were loaded again without overwriting stored data.",
            simplifiedChinese: "已重新加载受保护设置，且未覆盖已保存数据。"
        ),
        .protectedSettingsStillUnavailable: .init(
            english: "Protected settings are still unavailable. No workflow, model, or vocabulary data was changed.",
            simplifiedChinese: "受保护设置仍不可用；工作流、模型与词汇数据均未更改。"
        ),
        .recordDeliveryFocusFailure: .init(
            english: "Record delivery was aborted because Rill could not return focus to the target app.",
            simplifiedChinese: "记录投递已中止，因为 Rill 未能把焦点切回目标 App。"
        ),
        .recordingStartedAutoStop: .init(
            english: "Recording started. It will finish after you stop speaking; click again to stop now.",
            simplifiedChinese: "已开始录音。停止说话后会自动结束；再次点击可立即停止。"
        ),
        .recoveryCleanupPending: .init(
            english: "Transcription completed, but recovery cleanup is pending; this can include an unencrypted temporary recording. Rill will keep retrying cleanup and will not repeat the provider request.",
            simplifiedChinese: "转写已完成，但恢复清理仍待完成，其中可能包含未加密的临时录音。Rill 会继续重试清理，也不会重复请求语音服务。"
        ),
        .recoveryClearFailedFormat: .init(
            english: "Failed recordings could not be cleared. %@",
            simplifiedChinese: "无法清除失败录音。%@"
        ),
        .recoveryDeleteFailedFormat: .init(
            english: "The failed recording could not be deleted. %@",
            simplifiedChinese: "无法删除失败录音。%@"
        ),
        .recoveryEnabledStorageUnavailable: .init(
            english: "Recovery is saved as enabled, but protected storage is unavailable in this session. No new failed audio will be retained until storage recovers.",
            simplifiedChinese: "恢复设置已保存为开启，但本次会话的受保护存储不可用。在存储恢复前，不会保留新的失败录音。"
        ),
        .recoveryLoadFailedFormat: .init(
            english: "Failed recordings could not be loaded. %@",
            simplifiedChinese: "无法加载失败录音。%@"
        ),
        .recoveryRetryDuplicateWarning: .init(
            english: "A previous retry may have reached the speech provider. Delete this recording to avoid a duplicate request.",
            simplifiedChinese: "上一次重试可能已到达语音服务。为避免重复请求，请删除这条录音。"
        ),
        .recoveryRetryFailedFormat: .init(
            english: "The failed recording could not be retried. %@",
            simplifiedChinese: "无法重试失败录音。%@"
        ),
        .recoveryStorageUnavailable: .init(
            english: "Encrypted failed recording recovery is unavailable because persistent settings storage is unavailable.",
            simplifiedChinese: "持久化设置存储不可用，因此无法使用加密的失败录音恢复。"
        ),
        .recoveryTemporarilyUnavailable: .init(
            english: "Failed recording recovery is temporarily unavailable. Retry the operation.",
            simplifiedChinese: "失败录音恢复暂时不可用。请重试此操作。"
        ),
        .recoveryUpdateFailedFormat: .init(
            english: "Failed recording recovery could not be updated. %@",
            simplifiedChinese: "无法更新失败录音恢复。%@"
        ),
        .recoveryWorkflowUnavailable: .init(
            english: "The original workflow is no longer available. Delete this failed recording or restore the workflow first.",
            simplifiedChinese: "原工作流已不可用。请删除此失败录音，或先恢复该工作流。"
        ),
        .retentionCleanupPausedLoadFailed: .init(
            english: "Automatic history cleanup is paused because saved retention settings could not be loaded.",
            simplifiedChinese: "无法加载已保存的留存设置，自动历史清理保持暂停。"
        ),
        .retentionCleanupServiceUnavailable: .init(
            english: "The retention setting was saved, but cleanup is unavailable. Cleanup will be retried after the maintenance service is restored or Rill restarts.",
            simplifiedChinese: "留存设置已保存，但清理服务不可用；维护服务恢复或 Rill 重启后将再次尝试。"
        ),
        .retentionLoadFailedPaused: .init(
            english: "Retention settings could not be loaded. Automatic history cleanup is paused; the displayed periods are not confirmed saved choices.",
            simplifiedChinese: "无法加载留存设置，自动历史清理已暂停；当前显示值并非已确认保存的选择。"
        ),
        .retentionSaveFailedNotice: .init(
            english: "History retention settings could not be saved. Cleanup was not started.",
            simplifiedChinese: "历史留存设置无法保存，未启动清理。"
        ),
        .retentionSaveFailedRepair: .init(
            english: "Retention setting was not saved; no history was removed. Repair configuration storage, then retry.",
            simplifiedChinese: "留存设置未能保存，因此没有移除任何历史记录。请修复配置存储后重试。"
        ),
        .retentionSaveStorageUnavailable: .init(
            english: "Retention settings cannot be saved because settings storage is unavailable.",
            simplifiedChinese: "设置存储不可用，无法保存留存设置。"
        ),
        .retentionStorageUnavailableDefaults: .init(
            english: "Retention settings storage is unavailable. Automatic history cleanup is paused; the displayed periods are defaults, not confirmed saved choices.",
            simplifiedChinese: "留存设置存储不可用，自动历史清理已暂停；当前显示的是默认值，并非已确认保存的选择。"
        ),
        .runActionCopiedToClipboard: .init(
            english: "copied to clipboard",
            simplifiedChinese: "已复制到剪贴板"
        ),
        .runActionExternalOutputFormat: .init(
            english: "external output completed (%@)",
            simplifiedChinese: "外部输出已完成（%@）"
        ),
        .runActionFailedFormat: .init(
            english: "failed (%@)",
            simplifiedChinese: "失败（%@）"
        ),
        .runActionInjected: .init(english: "injected", simplifiedChinese: "已注入"),
        .runActionSkippedFormat: .init(
            english: "skipped (%@)",
            simplifiedChinese: "已跳过（%@）"
        ),
        .runActionStoredRecord: .init(
            english: "stored as a record",
            simplifiedChinese: "已存为记录"
        ),
        .runRetentionDamaged: .init(
            english: "Stored run and diagnostic history retention is damaged; run and diagnostic cleanup is paused until you save a valid period.",
            simplifiedChinese: "已保存的运行与诊断历史留存设置损坏；保存有效时长前，运行与诊断清理保持暂停。"
        ),
        .runWorkflowDisabledNotice: .init(
            english: "Enable the workflow before running it.",
            simplifiedChinese: "请先启用这个工作流再运行。"
        ),
        .savedSettingsAvailableAgain: .init(
            english: "Saved settings are available again.",
            simplifiedChinese: "已保存的设置现已恢复可用。"
        ),
        .savedSettingsStillUnavailable: .init(
            english: "Saved settings are still unavailable.",
            simplifiedChinese: "已保存的设置仍不可用。"
        ),
        .settingsSaveFailedRetry: .init(
            english: "Some settings could not be saved. Retry from Settings.",
            simplifiedChinese: "部分设置无法保存，请在设置页面重试。"
        ),
        .speechRoutingSettingsUnavailable: .init(
            english: "Saved speech-routing settings are unavailable.",
            simplifiedChinese: "已保存的语音路由设置不可用。"
        ),
        .wakeDictationDraftName: .init(
            english: "Wake Dictation",
            simplifiedChinese: "唤醒听写"
        ),
        .wakePhrasesUpdatedFormat: .init(
            english: "Wake phrases updated: %@",
            simplifiedChinese: "唤醒短语已更新：%@"
        ),
        .wakeWordSettingsSaveFailedFormat: .init(
            english: "%@",
            simplifiedChinese: "无法保存唤醒词设置：%@"
        ),
        .wakeWordWorkflowSaveFailedFormat: .init(
            english: "%@",
            simplifiedChinese: "无法保存唤醒词工作流：%@"
        ),
        .wakeWorkflowNotFound: .init(
            english: "Rill could not locate the saved wake-word workflow.",
            simplifiedChinese: "Rill 无法找到刚保存的唤醒词工作流。"
        ),
        .workflowLibraryLoading: .init(
            english: "Workflows are still loading. Wait a moment and try again.",
            simplifiedChinese: "工作流仍在加载，请稍候再试。"
        ),
        .workflowLibraryUnavailable: .init(
            english: "The saved workflow library is unavailable. Repair storage, then retry.",
            simplifiedChinese: "已保存的工作流库不可用。请修复存储后重试。"
        ),
        .workflowMigrationSaveFailed: .init(
            english: "Workflow composition migration could not be saved; legacy data was preserved.",
            simplifiedChinese: "工作流组合迁移无法保存；旧数据已保留。"
        ),
        .workflowNameRequired: .init(
            english: "Enter a workflow name before saving.",
            simplifiedChinese: "请先填写工作流名称。"
        ),
        .workflowRemovedFormat: .init(
            english: "Workflow removed: %@",
            simplifiedChinese: "工作流已删除：%@"
        ),
        .workflowRoutingUnresolvable: .init(
            english: "Workflow routing could not be resolved safely.",
            simplifiedChinese: "无法安全解析工作流路由。"
        ),
        .workflowSavedFormat: .init(
            english: "Workflow saved: %@",
            simplifiedChinese: "工作流已保存：%@"
        ),
        .workflowTOMLFileRemoveFailedFormat: .init(
            english: "The workflow TOML file could not be removed: %@",
            simplifiedChinese: "无法删除工作流 TOML 文件：%@"
        ),
        .workflowTOMLFileSaveFailedFormat: .init(
            english: "The workflow TOML file could not be saved: %@",
            simplifiedChinese: "无法保存工作流 TOML 文件：%@"
        ),
        .workflowTOMLIssuesHeading: .init(
            english: "Some workflow TOML files need attention:",
            simplifiedChinese: "部分工作流 TOML 文件需要处理："
        ),
        .workflowTOMLReloaded: .init(
            english: "Workflow TOML files reloaded.",
            simplifiedChinese: "已重新加载工作流 TOML 文件。"
        ),
        .workflowTOMLStateSaveFailedFormat: .init(
            english: "The workflow TOML state could not be saved: %@",
            simplifiedChinese: "无法保存工作流 TOML 状态：%@"
        ),
    ]
}

enum RunStatusTextKey: String, CaseIterable, Sendable {
    case benchmarkClearFailed
    case benchmarkSettingInvalid
    case benchmarkStorageUnavailable
    case benchmarkRetentionUpdateFailed
    case builtInWakeWorkflowUpdatedFormat
    case builtInWorkflowOverrideRemoveFailedFormat
    case builtInWorkflowRestoredFormat
    case clearRunHistoryBlockedActiveRun
    case clipboardRetentionDamaged
    case configurationStorageUnavailable
    case credentialSaveFailed
    case diagnosticsRepositoryUnavailable
    case failedRecordingNotRetainedFormat
    case failedRecoverySettingInvalid
    case historyRetentionDomainClipboard
    case historyRetentionDomainRunAndDiagnostic
    case historyRetentionInvalidFormat
    case historyRetentionReadFailedFormat
    case localHistoryUpdatedFormat
    case localSpeechHardwareMemoryRecommendedFormat
    case localSpeechHardwareMemoryRequiredFormat
    case localSpeechHardwareRecommendedFormat
    case localSpeechModelMemoryReleased
    case localSpeechModelReadyFormat
    case maintenanceServiceUnavailable
    case openAISettingsAvailableAgain
    case openAISettingsStillUnavailable
    case privacyLoadBlocked
    case privacyLoadBlockedRetry
    case privacyLoadFailedRepairStorage
    case privacySaveFailedRetry
    case privacySaveFailedSessionOnly
    case privacySaveStorageUnavailable
    case privacySettingsDamaged
    case protectedSettingsReloaded
    case protectedSettingsStillUnavailable
    case recordDeliveryFocusFailure
    case recordingStartedAutoStop
    case recoveryCleanupPending
    case recoveryClearFailedFormat
    case recoveryDeleteFailedFormat
    case recoveryEnabledStorageUnavailable
    case recoveryLoadFailedFormat
    case recoveryRetryDuplicateWarning
    case recoveryRetryFailedFormat
    case recoveryStorageUnavailable
    case recoveryTemporarilyUnavailable
    case recoveryUpdateFailedFormat
    case recoveryWorkflowUnavailable
    case retentionCleanupPausedLoadFailed
    case retentionCleanupServiceUnavailable
    case retentionLoadFailedPaused
    case retentionSaveFailedNotice
    case retentionSaveFailedRepair
    case retentionSaveStorageUnavailable
    case retentionStorageUnavailableDefaults
    case runActionCopiedToClipboard
    case runActionExternalOutputFormat
    case runActionFailedFormat
    case runActionInjected
    case runActionSkippedFormat
    case runActionStoredRecord
    case runRetentionDamaged
    case runWorkflowDisabledNotice
    case savedSettingsAvailableAgain
    case savedSettingsStillUnavailable
    case settingsSaveFailedRetry
    case speechRoutingSettingsUnavailable
    case wakeDictationDraftName
    case wakePhrasesUpdatedFormat
    case wakeWordSettingsSaveFailedFormat
    case wakeWordWorkflowSaveFailedFormat
    case wakeWorkflowNotFound
    case workflowLibraryLoading
    case workflowLibraryUnavailable
    case workflowMigrationSaveFailed
    case workflowNameRequired
    case workflowRemovedFormat
    case workflowRoutingUnresolvable
    case workflowSavedFormat
    case workflowTOMLFileRemoveFailedFormat
    case workflowTOMLFileSaveFailedFormat
    case workflowTOMLIssuesHeading
    case workflowTOMLReloaded
    case workflowTOMLStateSaveFailedFormat
}
