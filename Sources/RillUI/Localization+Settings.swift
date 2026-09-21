import Foundation
import RillCore

extension L10n {
    static func settingsText(_ key: SettingsTextKey, language: AppLanguage) -> String {
        settingsTextTable[key]?.string(for: language) ?? key.rawValue
    }

    static func settingsResourceRetryTitle(_ resourceName: String, language: AppLanguage) -> String {
        String(format: settingsText(.settingsResourceRetryFormat, language: language), resourceName)
    }

    static func settingsResourceDownloadTitle(
        _ resourceName: String,
        language: AppLanguage
    ) -> String {
        String(
            format: settingsText(.settingsResourceDownloadFormat, language: language),
            resourceName
        )
    }

    static func settingsWorkflowName(_ workflowName: String, language: AppLanguage) -> String {
        String(format: settingsText(.settingsWorkflowNameFormat, language: language), workflowName)
    }

    static func settingsOpenAIModelID(_ modelID: String, language: AppLanguage) -> String {
        String(format: settingsText(.settingsOpenAIModelIDFormat, language: language), modelID)
    }

    static func settingsResidentMemoryBudget(
        estimatedGigabytes: Double,
        estimatedFractionPercent: Double,
        modelList: String,
        language: AppLanguage
    ) -> String {
        String(
            format: settingsText(.settingsResidentMemoryBudgetFormat, language: language),
            estimatedGigabytes,
            estimatedFractionPercent,
            modelList
        )
    }

    static func settingsFailedAudioEncryptedCount(_ count: Int, language: AppLanguage) -> String {
        String(
            format: settingsText(.settingsFailedAudioEncryptedCountFormat, language: language),
            count
        )
    }

    static func settingsSectionSummary(_ section: SettingsSection, language: AppLanguage) -> String {
        let key: SettingsTextKey =
            switch section {
            case .permissions: .settingsSummaryPermissions
            case .speech: .settingsSummarySpeech
            case .input: .settingsSummaryInput
            case .voiceAssistant: .settingsSummaryVoiceAssistant
            case .recordPanel: .settingsSummaryRecordPanel
            case .vocabulary: .settingsSummaryVocabulary
            case .language: .settingsSummaryLanguage
            case .privacy: .settingsSummaryPrivacy
            case .storage: .settingsSummaryStorage
            }
        return settingsText(key, language: language)
    }

    static func wakeWordRuntimeStatus(
        _ state: WakeWordRuntimePresentationState,
        language: AppLanguage
    ) -> String {
        switch state {
        case .disabled:
            settingsText(.settingsWakeStatusDisabled, language: language)
        case .modelMissing:
            settingsText(.settingsWakeStatusModelRequired, language: language)
        case .starting:
            settingsText(.settingsWakeStatusStarting, language: language)
        case .listening:
            settingsText(.settingsWakeStatusListening, language: language)
        case .suspended(let reason):
            String(
                format: settingsText(.settingsWakeStatusPausedFormat, language: language),
                wakeWordSuspensionReason(reason, language: language)
            )
        case .failed:
            settingsText(.settingsWakeStatusUnavailable, language: language)
        }
    }

    static func wakeWordSuspensionReason(_ reason: String, language: AppLanguage) -> String {
        let key: SettingsTextKey? =
            switch reason {
            case "interactiveRecognition": .settingsWakeSuspensionInteractiveRecognition
            case "speechPlayback": .settingsWakeSuspensionSpeechPlayback
            case "microphonePermission": .settingsWakeSuspensionMicrophonePermission
            case "inputDeviceChanged": .settingsWakeSuspensionInputDeviceChanged
            case "busy": .settingsWakeSuspensionBusy
            default: nil
            }
        guard let key else { return reason }
        return settingsText(key, language: language)
    }

    static func microphoneReadinessDetail(_ state: PermissionState, language: AppLanguage) -> String
    {
        switch state {
        case .granted:
            settingsText(.settingsMicrophoneReady, language: language)
        case .unknown:
            settingsText(.settingsMicrophoneUnknown, language: language)
        case .denied:
            settingsText(.settingsMicrophoneDenied, language: language)
        }
    }

    static func localSpeechReadinessDetail(
        _ state: VoiceAssistantResourceState,
        language: AppLanguage
    ) -> String {
        switch state {
        case .ready:
            settingsText(.settingsLocalSpeechReady, language: language)
        case .preparing:
            settingsText(.settingsLocalSpeechPreparing, language: language)
        case .notInstalled:
            settingsText(.settingsLocalSpeechNotInstalled, language: language)
        case .failed:
            settingsText(.settingsLocalSpeechFailed, language: language)
        case .unavailable:
            settingsText(.settingsLocalSpeechUnavailable, language: language)
        }
    }

    static func llmReadinessDetail(
        _ state: VoiceAssistantLLMReadiness,
        language: AppLanguage
    ) -> String {
        switch state {
        case .notRequired:
            settingsText(.settingsReadinessNotUsedByWorkflow, language: language)
        case .loading:
            settingsText(.settingsLLMLoading, language: language)
        case .credentialMissing:
            settingsText(.settingsLLMCredentialMissing, language: language)
        case .credentialInaccessible:
            settingsText(.settingsLLMCredentialInaccessible, language: language)
        case .configurationInvalid:
            settingsText(.settingsLLMConfigurationInvalid, language: language)
        case .configured:
            settingsText(.settingsLLMConfigured, language: language)
        case .verifying:
            settingsText(.settingsLLMVerifying, language: language)
        case .verified:
            settingsText(.settingsLLMVerified, language: language)
        case .verificationFailed:
            settingsText(.settingsLLMVerificationFailed, language: language)
        }
    }

    static func privacyReadinessDetail(
        _ state: VoiceAssistantPrivacyReadiness,
        language: AppLanguage
    ) -> String {
        switch state {
        case .notRequired:
            settingsText(.settingsPrivacyNoCloudStep, language: language)
        case .loading:
            settingsText(.settingsPrivacyLoading, language: language)
        case .unavailable:
            settingsText(.settingsPrivacyPolicyUnavailable, language: language)
        case .ready(cloudConfirmationRequired: true):
            settingsText(.settingsPrivacyConfirmationRequired, language: language)
        case .ready(cloudConfirmationRequired: false):
            settingsText(.settingsPrivacyPolicyReady, language: language)
        }
    }

    static func speechOutputReadinessDetail(
        _ state: VoiceAssistantSpeechOutputReadiness,
        language: AppLanguage
    ) -> String {
        switch state {
        case .notRequired:
            settingsText(.settingsReadinessNotUsedByWorkflow, language: language)
        case .localVoice:
            settingsText(.settingsSpeechOutputLocalVoice, language: language)
        case .preparingLocalVoice:
            settingsText(.settingsSpeechOutputPreparingLocalVoice, language: language)
        case .systemFallback:
            settingsText(.settingsSpeechOutputSystemFallback, language: language)
        }
    }

    static func llmModelLabel(_ selection: LLMModelSelection, language: AppLanguage) -> String
    {
        switch selection {
        case .deepSeek:
            "DeepSeek V4.1 Flash"
        case .luna:
            settingsText(.settingsOpenAIModelLuna, language: language)
        case .terra:
            settingsText(.settingsOpenAIModelTerra, language: language)
        case .sol:
            settingsText(.settingsOpenAIModelSol, language: language)
        case .custom:
            string(.settingsOpenAICustomModel, language: language)
        }
    }

    static func openAIVerificationFailureMessage(
        _ failure: OpenAIVerificationFailure?,
        language: AppLanguage
    ) -> String {
        switch failure {
        case .credentialUnavailable:
            settingsText(.settingsVerificationFailureCredentialUnavailable, language: language)
        case .configurationInvalid:
            settingsText(.settingsVerificationFailureConfigurationInvalid, language: language)
        case .authenticationFailed:
            settingsText(.settingsVerificationFailureAuthenticationFailed, language: language)
        case .rateLimited:
            settingsText(.settingsVerificationFailureRateLimited, language: language)
        case .timedOut:
            settingsText(.settingsVerificationFailureTimedOut, language: language)
        case .networkFailed:
            settingsText(.settingsVerificationFailureNetworkFailed, language: language)
        case .refused:
            settingsText(.settingsVerificationFailureRefused, language: language)
        case .incomplete:
            settingsText(.settingsVerificationFailureIncomplete, language: language)
        case .invalidResponse:
            settingsText(.settingsVerificationFailureInvalidResponse, language: language)
        case .unknown, nil:
            string(.settingsOpenAIVerificationFailed, language: language)
        }
    }

    private static let settingsTextTable: [SettingsTextKey: LocalizedText] = [
        .settingsAssistantSetupIncomplete: .init(
            english: "Complete assistant setup",
            simplifiedChinese: "请完成语音助手设置"
        ),
        .settingsAssistantSetupReady: .init(
            english: "Assistant setup is ready",
            simplifiedChinese: "语音助手已准备就绪"
        ),
        .settingsConfigureVerifyLLM: .init(
            english: "Configure & verify LLM",
            simplifiedChinese: "配置并验证 LLM"
        ),
        .settingsEnableAnyway: .init(
            english: "Enable anyway",
            simplifiedChinese: "仍然启用"
        ),
        .settingsEnableWakeWordListening: .init(
            english: "Enable wake-word listening",
            simplifiedChinese: "启用唤醒词监听"
        ),
        .settingsFailedAudioEncryptedCountFormat: .init(
            english: "%d encrypted",
            simplifiedChinese: "已加密 %d 条"
        ),
        .settingsGroupAdvanced: .init(
            english: "Advanced",
            simplifiedChinese: "高级"
        ),
        .settingsGroupFeaturesAndPersonalization: .init(
            english: "Features & Personalization",
            simplifiedChinese: "功能与个性化"
        ),
        .settingsGroupPrivacyAndData: .init(
            english: "Privacy & Data",
            simplifiedChinese: "隐私与数据"
        ),
        .settingsGroupVoiceAndModels: .init(
            english: "Voice & Models",
            simplifiedChinese: "语音与模型"
        ),
        .settingsHotkeyKeyClear: .init(
            english: "Clear",
            simplifiedChinese: "清除"
        ),
        .settingsHotkeyKeyDelete: .init(
            english: "Delete",
            simplifiedChinese: "删除"
        ),
        .settingsHotkeyKeyDown: .init(
            english: "↓",
            simplifiedChinese: "下"
        ),
        .settingsHotkeyKeyEnd: .init(
            english: "End",
            simplifiedChinese: "行尾"
        ),
        .settingsHotkeyKeyEnter: .init(
            english: "Enter",
            simplifiedChinese: "小键盘回车"
        ),
        .settingsHotkeyKeyEsc: .init(
            english: "Esc",
            simplifiedChinese: "退出"
        ),
        .settingsHotkeyKeyForwardDelete: .init(
            english: "Forward Delete",
            simplifiedChinese: "向前删除"
        ),
        .settingsHotkeyKeyHelp: .init(
            english: "Help",
            simplifiedChinese: "帮助"
        ),
        .settingsHotkeyKeyHome: .init(
            english: "Home",
            simplifiedChinese: "行首"
        ),
        .settingsHotkeyKeyLeft: .init(
            english: "←",
            simplifiedChinese: "左"
        ),
        .settingsHotkeyKeyPageDown: .init(
            english: "Page Down",
            simplifiedChinese: "下翻页"
        ),
        .settingsHotkeyKeyPageUp: .init(
            english: "Page Up",
            simplifiedChinese: "上翻页"
        ),
        .settingsHotkeyKeyReturn: .init(
            english: "Return",
            simplifiedChinese: "回车"
        ),
        .settingsHotkeyKeyRight: .init(
            english: "→",
            simplifiedChinese: "右"
        ),
        .settingsHotkeyKeySpace: .init(
            english: "Space",
            simplifiedChinese: "空格"
        ),
        .settingsHotkeyKeyTab: .init(
            english: "Tab",
            simplifiedChinese: "制表"
        ),
        .settingsHotkeyKeyUnknownFormat: .init(
            english: "Key %d",
            simplifiedChinese: "按键 %d"
        ),
        .settingsHotkeyKeyUp: .init(
            english: "↑",
            simplifiedChinese: "上"
        ),
        .settingsHotkeyResetHelp: .init(
            english: "Clears the bound shortcut and restores the default.",
            simplifiedChinese: "清除已绑定的快捷键并恢复默认。"
        ),
        .settingsKeepResident: .init(
            english: "Keep resident",
            simplifiedChinese: "保持常驻"
        ),
        .settingsLLMCredentialInaccessible: .init(
            english: "Keychain unavailable",
            simplifiedChinese: "无法访问钥匙串"
        ),
        .settingsLLMCredentialMissing: .init(
            english: "API key required",
            simplifiedChinese: "需要 API Key"
        ),
        .settingsLLMConfigurationInvalid: .init(
            english: "Endpoint or model ID is invalid",
            simplifiedChinese: "地址或模型 ID 无效"
        ),
        .settingsLLMConfigured: .init(
            english: "Configured; verification recommended",
            simplifiedChinese: "已配置；建议验证"
        ),
        .settingsLLMLoading: .init(
            english: "Loading secure settings",
            simplifiedChinese: "正在读取安全设置"
        ),
        .settingsLLMVerificationFailed: .init(
            english: "Verification failed",
            simplifiedChinese: "验证失败"
        ),
        .settingsLLMVerified: .init(
            english: "Verified",
            simplifiedChinese: "验证通过"
        ),
        .settingsLLMVerifying: .init(
            english: "Verifying",
            simplifiedChinese: "正在验证"
        ),
        .settingsLocalASRResourceName: .init(
            english: "local ASR",
            simplifiedChinese: "本地语音模型"
        ),
        .settingsLocalSpeechFailed: .init(
            english: "Preparation failed",
            simplifiedChinese: "模型准备失败"
        ),
        .settingsLocalSpeechNotInstalled: .init(
            english: "Model required",
            simplifiedChinese: "需要准备模型"
        ),
        .settingsLocalSpeechPreparing: .init(
            english: "Preparing model",
            simplifiedChinese: "正在准备模型"
        ),
        .settingsLocalSpeechReady: .init(
            english: "Selected Qwen ASR is ready",
            simplifiedChinese: "当前 Qwen ASR 已就绪"
        ),
        .settingsLocalSpeechUnavailable: .init(
            english: "Unavailable in this build",
            simplifiedChinese: "当前版本不可用"
        ),
        .settingsManageVocabularyCollections: .init(
            english: "Manage Collections and Workflow Bindings",
            simplifiedChinese: "管理词库与工作流绑定"
        ),
        .settingsMicrophoneDenied: .init(
            english: "Permission required",
            simplifiedChinese: "需要授权"
        ),
        .settingsMicrophoneReady: .init(
            english: "Ready",
            simplifiedChinese: "已就绪"
        ),
        .settingsMicrophoneUnknown: .init(
            english: "Permission not checked",
            simplifiedChinese: "尚未检查权限"
        ),
        .settingsModelPoolDegraded: .init(
            english: "Memory pressure unloaded resident models; they will reload on demand.",
            simplifiedChinese: "因系统内存压力，常驻模型已临时卸载；下次使用时会按需重载。"
        ),
        .settingsModelPoolDescription: .init(
            english:
                "Workflows choose models and voices. Enable models here, then optionally keep frequently used models resident.",
            simplifiedChinese: "模型和音色由各 workflow 选择。这里仅启用可用模型，并可选择让常用模型常驻。"
        ),
        .settingsModelPoolTitle: .init(
            english: "Available model pool",
            simplifiedChinese: "可用模型池"
        ),
        .settingsOpenAIModelIDFormat: .init(
            english: "Model ID: %@",
            simplifiedChinese: "模型 ID：%@"
        ),
        .settingsOpenAIModelLuna: .init(
            english: "Luna — high volume (gpt-5.6-luna)",
            simplifiedChinese: "Luna — 高吞吐 (gpt-5.6-luna)"
        ),
        .settingsOpenAIModelSol: .init(
            english: "Sol — highest capability (gpt-5.6-sol)",
            simplifiedChinese: "Sol — 最高能力 (gpt-5.6-sol)"
        ),
        .settingsOpenAIModelTerra: .init(
            english: "Terra — balanced (gpt-5.6-terra)",
            simplifiedChinese: "Terra — 均衡 (gpt-5.6-terra)"
        ),
        .settingsPrivacyConfirmationRequired: .init(
            english: "Confirmation required per run",
            simplifiedChinese: "每次运行需要确认"
        ),
        .settingsPrivacyLoading: .init(
            english: "Loading policy",
            simplifiedChinese: "正在读取策略"
        ),
        .settingsPrivacyNoCloudStep: .init(
            english: "No cloud step",
            simplifiedChinese: "没有云端步骤"
        ),
        .settingsPrivacyPolicyReady: .init(
            english: "Policy ready",
            simplifiedChinese: "策略已就绪"
        ),
        .settingsPrivacyPolicyUnavailable: .init(
            english: "Policy unavailable",
            simplifiedChinese: "策略不可用"
        ),
        .settingsPrivacyRuleUpdateFailed: .init(
            english: "The privacy rule could not be updated. Review the rule and retry.",
            simplifiedChinese: "无法更新隐私规则。请检查规则后重试。"
        ),
        .settingsReadinessCloudPrivacy: .init(
            english: "Cloud privacy",
            simplifiedChinese: "云端隐私"
        ),
        .settingsReadinessLLMAnswer: .init(
            english: "LLM answer",
            simplifiedChinese: "LLM 回答"
        ),
        .settingsReadinessLocalRecognition: .init(
            english: "Local recognition",
            simplifiedChinese: "本地识别"
        ),
        .settingsReadinessNotUsedByWorkflow: .init(
            english: "Not used by this workflow",
            simplifiedChinese: "当前工作流不使用"
        ),
        .settingsReadinessSpeechOutput: .init(
            english: "Speech output",
            simplifiedChinese: "语音输出"
        ),
        .settingsRepairPrivacySettings: .init(
            english: "Repair privacy settings",
            simplifiedChinese: "修复隐私设置"
        ),
        .settingsResidentMemoryBudgetFormat: .init(
            english: "Estimated %.2f GB (%.1f%%): %@",
            simplifiedChinese: "预计 %.2f GB（%.1f%%）：%@"
        ),
        .settingsResidentMemoryWarning: .init(
            english: "Estimated resident memory exceeds 20%",
            simplifiedChinese: "预计常驻内存超过整机内存的 20%"
        ),
        .settingsResourceDownloadFormat: .init(
            english: "Download %@",
            simplifiedChinese: "下载%@"
        ),
        .settingsResourceNotInstalled: .init(
            english: "Not installed",
            simplifiedChinese: "尚未安装"
        ),
        .settingsResourcePreparingDownload: .init(
            english: "Preparing download…",
            simplifiedChinese: "正在准备下载…"
        ),
        .settingsResourceRetryFormat: .init(
            english: "Retry %@",
            simplifiedChinese: "重试%@"
        ),
        .settingsRetryLoading: .init(
            english: "Retry Loading",
            simplifiedChinese: "重试加载"
        ),
        .settingsReviewPermissions: .init(
            english: "Review permissions",
            simplifiedChinese: "检查权限"
        ),
        .settingsSavePhrases: .init(
            english: "Save phrases",
            simplifiedChinese: "保存短语"
        ),
        .settingsSensitiveAppRuleDeleteConfirmation: .init(
            english: "Delete this sensitive-app rule?",
            simplifiedChinese: "删除这条敏感应用规则？"
        ),
        .settingsSensitiveAppRuleDeleteConfirmationDetail: .init(
            english: "The app will no longer be treated as privacy-sensitive.",
            simplifiedChinese: "该应用将不再按敏感应用处理。"
        ),
        .settingsSensitiveAppRulesEmpty: .init(
            english: "No sensitive-app rules yet.",
            simplifiedChinese: "还没有敏感应用规则。"
        ),
        .settingsSpeechModelCapabilitySTT: .init(
            english: "STT",
            simplifiedChinese: "语音识别"
        ),
        .settingsSpeechModelCapabilityTTS: .init(
            english: "TTS",
            simplifiedChinese: "语音合成"
        ),
        .settingsSpeechModelEnablementDetail: .init(
            english:
                "Models are enabled here; each workflow chooses its STT model, TTS model, voice, language, prompt, and streaming style.",
            simplifiedChinese: "在这里启用模型；每个 workflow 独立选择 STT 模型、TTS 模型、音色、语言、提示词和流式风格。"
        ),
        .settingsSpeechOutputLocalVoice: .init(
            english: "Local Qwen voice",
            simplifiedChinese: "本地 Qwen 音色"
        ),
        .settingsSpeechOutputPreparingLocalVoice: .init(
            english: "System voice until ready",
            simplifiedChinese: "准备期间使用系统语音"
        ),
        .settingsSpeechOutputSystemFallback: .init(
            english: "System voice fallback ready",
            simplifiedChinese: "系统语音回退已就绪"
        ),
        .settingsStreamingPreviewModelDetail: .init(
            english:
                "Live preview uses the workflow's Qwen model; the sealed WAV is always recognized offline for the authoritative final text.",
            simplifiedChinese: "实时预览使用 workflow 选择的 Qwen 模型；录音封口后始终以 WAV 离线识别生成唯一正式文本。"
        ),
        .settingsSummaryInput: .init(
            english: "Recording behavior, duration, and output",
            simplifiedChinese: "录音方式、时长与输出"
        ),
        .settingsSummaryLanguage: .init(
            english: "Display language",
            simplifiedChinese: "界面显示语言"
        ),
        .settingsSummaryPermissions: .init(
            english: "Microphone, global shortcuts, and system access",
            simplifiedChinese: "麦克风、全局快捷键与系统访问"
        ),
        .settingsSummaryPrivacy: .init(
            english: "Cloud confirmation and sensitive-app safeguards",
            simplifiedChinese: "云端确认与敏感应用保护"
        ),
        .settingsSummaryRecordPanel: .init(
            english: "Clipboard capture and panel shortcut",
            simplifiedChinese: "剪贴板捕获与面板快捷键"
        ),
        .settingsSummarySpeech: .init(
            english: "Provider configuration and available model pool",
            simplifiedChinese: "提供商配置与可用模型池"
        ),
        .settingsSummaryStorage: .init(
            english: "Retention, recovery, and local cleanup",
            simplifiedChinese: "保留期限、恢复与本地清理"
        ),
        .settingsSummaryVocabulary: .init(
            english: "Hotwords, replacements, and scoped corrections",
            simplifiedChinese: "热词、替换与限定范围的纠正"
        ),
        .settingsSummaryVoiceAssistant: .init(
            english: "Readiness, wake listening, LLM answers, and speech output",
            simplifiedChinese: "就绪检查、唤醒监听、LLM 回答与语音输出"
        ),
        .settingsThirdPartyOpenAIHint: .init(
            english:
                "Verification uses the configured endpoint, key and exact model ID shown above. Choose a model offered by that provider.",
            simplifiedChinese: "验证使用当前地址、API Key 和上方显示的准确模型 ID。请选择该服务实际提供的模型。"
        ),
        .settingsUseHardwareRecommendation: .init(
            english: "Use hardware recommendation",
            simplifiedChinese: "使用硬件推荐"
        ),
        .settingsVerificationFailureAuthenticationFailed: .init(
            english: "Authentication failed. Check whether the API key belongs to this endpoint.",
            simplifiedChinese: "身份验证失败。请确认 API Key 属于当前服务地址。"
        ),
        .settingsVerificationFailureConfigurationInvalid: .init(
            english:
                "The endpoint rejected this request or model ID. Check the exact model available from the provider.",
            simplifiedChinese: "该地址拒绝了当前请求或模型 ID。请核对服务商实际开放的模型 ID。"
        ),
        .settingsVerificationFailureCredentialUnavailable: .init(
            english: "The saved API key could not be loaded.",
            simplifiedChinese: "无法读取已保存的 API Key。"
        ),
        .settingsVerificationFailureIncomplete: .init(
            english: "The endpoint returned an incomplete response.",
            simplifiedChinese: "服务返回了不完整响应。"
        ),
        .settingsVerificationFailureInvalidResponse: .init(
            english:
                "The endpoint returned empty content or an unrecognized Responses API payload.",
            simplifiedChinese: "服务返回了空内容或无法识别的 Responses API 响应。"
        ),
        .settingsVerificationFailureNetworkFailed: .init(
            english: "The endpoint could not be reached. Check the network and Base URL.",
            simplifiedChinese: "无法连接该地址。请检查网络和 Base URL。"
        ),
        .settingsVerificationFailureRateLimited: .init(
            english:
                "The account is rate limited or has insufficient quota. Check the provider account and retry.",
            simplifiedChinese: "账号受到限流或额度不足。请检查服务商账号后重试。"
        ),
        .settingsVerificationFailureRefused: .init(
            english: "The model refused the verification request.",
            simplifiedChinese: "模型拒绝了验证请求。"
        ),
        .settingsVerificationFailureTimedOut: .init(
            english: "The verification request timed out.",
            simplifiedChinese: "验证请求超时。"
        ),
        .settingsVocabularyMovedNotice: .init(
            english:
                "Hotwords and replacements now live in reusable collections attached to workflow Setup.",
            simplifiedChinese: "热词与替换词现在位于可复用词库中，并在工作流 Setup 阶段绑定。"
        ),
        .settingsVoiceResourceUnavailable: .init(
            english: "This local speech model is unavailable in the current distribution.",
            simplifiedChinese: "当前发行版本不提供此本地语音模型。"
        ),
        .settingsWakePhrasesPlaceholder: .init(
            english: "One phrase per line (1–4)",
            simplifiedChinese: "每行一个短语（1–4 个）"
        ),
        .settingsWakePhrasesTitle: .init(
            english: "Wake phrases",
            simplifiedChinese: "唤醒短语"
        ),
        .settingsWakeStatusDisabled: .init(
            english: "Disabled",
            simplifiedChinese: "已停用"
        ),
        .settingsWakeStatusListening: .init(
            english: "Listening locally",
            simplifiedChinese: "正在本地监听"
        ),
        .settingsWakeStatusModelRequired: .init(
            english: "Model required",
            simplifiedChinese: "需要模型"
        ),
        .settingsWakeStatusPausedFormat: .init(
            english: "Paused: %@",
            simplifiedChinese: "已暂停：%@"
        ),
        .settingsWakeStatusStarting: .init(
            english: "Starting",
            simplifiedChinese: "正在启动"
        ),
        .settingsWakeStatusUnavailable: .init(
            english: "Unavailable",
            simplifiedChinese: "不可用"
        ),
        .settingsWakeSuspensionBusy: .init(
            english: "assistant workflow is running",
            simplifiedChinese: "助手工作流正在运行"
        ),
        .settingsWakeSuspensionInputDeviceChanged: .init(
            english: "input device changed",
            simplifiedChinese: "输入设备已变化"
        ),
        .settingsWakeSuspensionInteractiveRecognition: .init(
            english: "interactive recognition has priority",
            simplifiedChinese: "交互识别优先"
        ),
        .settingsWakeSuspensionMicrophonePermission: .init(
            english: "microphone permission",
            simplifiedChinese: "麦克风权限"
        ),
        .settingsWakeSuspensionSpeechPlayback: .init(
            english: "speech playback",
            simplifiedChinese: "正在播放语音"
        ),
        .settingsWakeWordASRReady: .init(
            english: "Selected local ASR is ready",
            simplifiedChinese: "当前本地语音模型已就绪"
        ),
        .settingsWakeWordListener: .init(
            english: "Wake-word listener",
            simplifiedChinese: "唤醒词监听"
        ),
        .settingsWakeWordPrivacyDetail: .init(
            english:
                "Idle listening runs only local VAD. Complete candidates are checked locally and discarded unless they begin with a configured wake phrase.",
            simplifiedChinese: "空闲监听只运行本地 VAD；完整候选会在本地检查，不以已配置唤醒短语开头时立即丢弃。"
        ),
        .settingsWakeWordScopeDetail: .init(
            english:
                "This edits the ambient wake trigger only. Fn and other interactive recognition take microphone priority immediately; LLM and speech output continue on the assistant lane without blocking the next recognition.",
            simplifiedChinese: "这里仅编辑环境唤醒触发。Fn 和其他交互识别会立即取得麦克风优先级；LLM 与语音输出在独立助手通道继续处理，不阻塞下一次识别。"
        ),
        .settingsWorkflowNameFormat: .init(
            english: "Workflow: %@",
            simplifiedChinese: "工作流：%@"
        ),
    ]
}

enum SettingsTextKey: String, CaseIterable, Sendable {
    case settingsAssistantSetupIncomplete
    case settingsAssistantSetupReady
    case settingsConfigureVerifyLLM
    case settingsEnableAnyway
    case settingsEnableWakeWordListening
    case settingsFailedAudioEncryptedCountFormat
    case settingsGroupAdvanced
    case settingsGroupFeaturesAndPersonalization
    case settingsGroupPrivacyAndData
    case settingsGroupVoiceAndModels
    case settingsHotkeyKeyClear
    case settingsHotkeyKeyDelete
    case settingsHotkeyKeyDown
    case settingsHotkeyKeyEnd
    case settingsHotkeyKeyEnter
    case settingsHotkeyKeyEsc
    case settingsHotkeyKeyForwardDelete
    case settingsHotkeyKeyHelp
    case settingsHotkeyKeyHome
    case settingsHotkeyKeyLeft
    case settingsHotkeyKeyPageDown
    case settingsHotkeyKeyPageUp
    case settingsHotkeyKeyReturn
    case settingsHotkeyKeyRight
    case settingsHotkeyKeySpace
    case settingsHotkeyKeyTab
    case settingsHotkeyKeyUnknownFormat
    case settingsHotkeyKeyUp
    case settingsHotkeyResetHelp
    case settingsKeepResident
    case settingsLLMCredentialInaccessible
    case settingsLLMCredentialMissing
    case settingsLLMConfigurationInvalid
    case settingsLLMConfigured
    case settingsLLMLoading
    case settingsLLMVerificationFailed
    case settingsLLMVerified
    case settingsLLMVerifying
    case settingsLocalASRResourceName
    case settingsLocalSpeechFailed
    case settingsLocalSpeechNotInstalled
    case settingsLocalSpeechPreparing
    case settingsLocalSpeechReady
    case settingsLocalSpeechUnavailable
    case settingsManageVocabularyCollections
    case settingsMicrophoneDenied
    case settingsMicrophoneReady
    case settingsMicrophoneUnknown
    case settingsModelPoolDegraded
    case settingsModelPoolDescription
    case settingsModelPoolTitle
    case settingsOpenAIModelIDFormat
    case settingsOpenAIModelLuna
    case settingsOpenAIModelSol
    case settingsOpenAIModelTerra
    case settingsPrivacyConfirmationRequired
    case settingsPrivacyLoading
    case settingsPrivacyNoCloudStep
    case settingsPrivacyPolicyReady
    case settingsPrivacyPolicyUnavailable
    case settingsPrivacyRuleUpdateFailed
    case settingsReadinessCloudPrivacy
    case settingsReadinessLLMAnswer
    case settingsReadinessLocalRecognition
    case settingsReadinessNotUsedByWorkflow
    case settingsReadinessSpeechOutput
    case settingsRepairPrivacySettings
    case settingsResidentMemoryBudgetFormat
    case settingsResidentMemoryWarning
    case settingsResourceDownloadFormat
    case settingsResourceNotInstalled
    case settingsResourcePreparingDownload
    case settingsResourceRetryFormat
    case settingsRetryLoading
    case settingsReviewPermissions
    case settingsSavePhrases
    case settingsSensitiveAppRuleDeleteConfirmation
    case settingsSensitiveAppRuleDeleteConfirmationDetail
    case settingsSensitiveAppRulesEmpty
    case settingsSpeechModelCapabilitySTT
    case settingsSpeechModelCapabilityTTS
    case settingsSpeechModelEnablementDetail
    case settingsSpeechOutputLocalVoice
    case settingsSpeechOutputPreparingLocalVoice
    case settingsSpeechOutputSystemFallback
    case settingsStreamingPreviewModelDetail
    case settingsSummaryInput
    case settingsSummaryLanguage
    case settingsSummaryPermissions
    case settingsSummaryPrivacy
    case settingsSummaryRecordPanel
    case settingsSummarySpeech
    case settingsSummaryStorage
    case settingsSummaryVocabulary
    case settingsSummaryVoiceAssistant
    case settingsThirdPartyOpenAIHint
    case settingsUseHardwareRecommendation
    case settingsVerificationFailureAuthenticationFailed
    case settingsVerificationFailureConfigurationInvalid
    case settingsVerificationFailureCredentialUnavailable
    case settingsVerificationFailureIncomplete
    case settingsVerificationFailureInvalidResponse
    case settingsVerificationFailureNetworkFailed
    case settingsVerificationFailureRateLimited
    case settingsVerificationFailureRefused
    case settingsVerificationFailureTimedOut
    case settingsVocabularyMovedNotice
    case settingsVoiceResourceUnavailable
    case settingsWakePhrasesPlaceholder
    case settingsWakePhrasesTitle
    case settingsWakeStatusDisabled
    case settingsWakeStatusListening
    case settingsWakeStatusModelRequired
    case settingsWakeStatusPausedFormat
    case settingsWakeStatusStarting
    case settingsWakeStatusUnavailable
    case settingsWakeSuspensionBusy
    case settingsWakeSuspensionInputDeviceChanged
    case settingsWakeSuspensionInteractiveRecognition
    case settingsWakeSuspensionMicrophonePermission
    case settingsWakeSuspensionSpeechPlayback
    case settingsWakeWordASRReady
    case settingsWakeWordListener
    case settingsWakeWordPrivacyDetail
    case settingsWakeWordScopeDetail
    case settingsWorkflowNameFormat
}
