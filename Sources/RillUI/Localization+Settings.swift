import Foundation
import RillCore

extension L10n {
  static func settingsText(_ key: SettingsTextKey, language: AppLanguage) -> String {
    catalogString("settings.\(key.rawValue)", language: language)
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
    if section == .contextMemory { return workspace(.contextMemorySummary, language: language) }
    if section == .diagnostics { return workspace(.diagnosticsSummary, language: language) }
    let key: SettingsTextKey =
      switch section {
      case .permissions: .settingsSummaryPermissions
      case .speech: .settingsSummarySpeech
      case .providers: .settingsSummaryProviders
      case .input: .settingsSummaryInput
      case .voiceAssistant: .settingsSummaryVoiceAssistant
      case .recordPanel: .settingsSummaryRecordPanel
      case .vocabulary: .settingsSummaryVocabulary
      case .language: .settingsSummaryLanguage
      case .privacy: .settingsSummaryPrivacy
      case .storage, .diagnostics: .settingsSummaryStorage
      case .contextMemory: .settingsSummaryVocabulary
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

  static func microphoneReadinessDetail(_ state: PermissionState, language: AppLanguage) -> String {
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

  static func llmModelLabel(_ selection: LLMModelSelection, language: AppLanguage) -> String {
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
  case settingsSummaryProviders
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
