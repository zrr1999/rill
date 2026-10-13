import Foundation
import RillCore

extension L10n {
  static func runText(_ key: RunStatusTextKey, language: AppLanguage) -> String {
    catalogString("run.\(key.rawValue)", language: language)
  }

  static func runHistoryRetentionReadFailed(isRecordSetting: Bool) -> LocalizedStringResource {
    resource(isRecordSetting ? "run.historyRetentionReadFailed.clipboard" : "run.historyRetentionReadFailed.runs")
  }

  static func runHistoryRetentionInvalid(isRecordSetting: Bool) -> LocalizedStringResource {
    resource(isRecordSetting ? "run.historyRetentionInvalid.clipboard" : "run.historyRetentionInvalid.runs")
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

}

enum RunStatusTextKey: String, CaseIterable, Sendable {
  case corpusReadFailed
  case corpusExportFailed
  case corpusClearFailed
  case corpusSettingInvalid
  case corpusStorageUnavailable
  case corpusEnabledStorageUnavailable
  case corpusRetentionUpdateFailed
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
