import Foundation
import RillCore

extension L10n {
  static func runText(_ key: RunStatusTextKey, language: AppLanguage) -> String {
    catalogString("run.\(key.rawValue)", language: language)
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
  case builtInWorkflowOverrideRemoveFailedFormat
  case clearRunHistoryBlockedActiveRun
  case clipboardRetentionDamaged
  case failedRecordingNotRetainedFormat
  case localSpeechHardwareMemoryRecommendedFormat
  case localSpeechHardwareMemoryRequiredFormat
  case localSpeechHardwareRecommendedFormat
  case maintenanceServiceUnavailable
  case privacyLoadBlocked
  case privacyLoadBlockedRetry
  case privacyLoadFailedRepairStorage
  case privacySaveFailedSessionOnly
  case privacySaveStorageUnavailable
  case privacySettingsDamaged
  case recordDeliveryFocusFailure
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
  case speechRoutingSettingsUnavailable
  case wakeDictationDraftName
  case wakeWordSettingsSaveFailedFormat
  case wakeWordWorkflowSaveFailedFormat
  case wakeWorkflowNotFound
  case workflowLibraryLoading
  case workflowLibraryUnavailable
  case workflowMigrationSaveFailed
  case workflowNameRequired
  case workflowRoutingUnresolvable
  case workflowTOMLFileRemoveFailedFormat
  case workflowTOMLFileSaveFailedFormat
  case workflowTOMLIssuesHeading
  case workflowTOMLReloaded
  case workflowTOMLStateSaveFailedFormat
}
