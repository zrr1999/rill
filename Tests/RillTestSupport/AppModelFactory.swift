import Foundation
import RillCore
import RillWorkflows
import RillRecords
import RillKnowledge
import RillSpeech
import RillUI

/// Test-only compositions may omit adapters. Production initialization requires
/// every dependency explicitly, including the one RecordStore-backed workspace.
@MainActor
public func makeAppModelForTesting(
    workflows initialWorkflows: [WorkflowDefinition],
    eventBus: EventBus,
    sessionCoordinator: SessionCoordinator,
    outputActionRegistry: OutputActionRegistry,
    recordWorkspace: RecordWorkspaceModel? = nil,
    candidateResolver: CandidateResolver,
    historyRepository: (any HistoryRepository)? = nil,
    runHistoryBrowser: (any RunHistoryBrowsing)? = nil,
    runReceiptRepository: (any WorkflowRunReceiptRepository)? = nil,
    localHistoryMaintenance: (any LocalHistoryMaintaining)? = nil,
    diagnosticRepository: (any DiagnosticRepository)? = nil,
    settingsStore: (any SettingsStore)? = nil,
    workflowFileStore: (any WorkflowFileStore)? = nil,
    credentialStore: (any SecureCredentialStore)? = nil,
    localPersistenceStatus: LocalPersistenceStatus = .ready,
    vocabularyRuleSource: VocabularyRuleSource = VocabularyRuleSource(initialRules: []),
    privacySettingsSource: PrivacyPolicySettingsSource = PrivacyPolicySettingsSource(
      initialSettings: .defaults
    ),
    localSpeechSettingsSource: LocalSpeechSettingsSource = LocalSpeechSettingsSource(),
    loadsPersistentSettingsOnInitialization: Bool = true,
    settingsWriteDebounceDuration: Duration = .milliseconds(300),
    historyRetentionMaintenanceInterval: Duration? = .seconds(86_400),
    liveSubtitlePreparingHideDelay: Duration = .seconds(15),
    localSpeechTrustMaterialAvailable: Bool = false,
    localSpeechAvailability: LocalSpeechAvailability? = nil,
    trustedLocalSpeechModels: [LocalSpeechModelDescriptor] = [],
    defaultLocalSpeechModelIdentifier: String? = nil,
    ttsModelOptions: [TTSModelOption] = [],
    defaultTTSModelIdentifier: String = "",
    localSpeechPhysicalMemoryGiB: Int = Int(
      ProcessInfo.processInfo.physicalMemory / 1_073_741_824
    ),
    prepareLocalSpeechAction:
      @escaping @Sendable (
        LocalSpeechSettings,
        @escaping @Sendable (Progress) -> Void
      ) async throws -> String = { _, _ in
        throw NSError(
          domain: "Rill.AppModel",
          code: 2,
          userInfo: [NSLocalizedDescriptionKey: "Local speech preparation is not configured."]
        )
      },
    synchronizeResidentSpeechModelsAction:
      @escaping @Sendable (_ added: Set<String>, _ removed: Set<String>) async -> Void = {
        _, _ in
      },
    prepareEnabledSpeechModelAction:
      @escaping @Sendable (_ modelID: String) async -> Void = { _ in },
    setLocalSpeechRuntimeEnabledAction: @escaping @Sendable (Bool) -> Void = { _ in },
    releaseLocalSpeechRuntimeAction: @escaping @Sendable () -> Void = {},
    stopLocalSpeechRuntimeAction: @escaping @Sendable () async -> Void = {},
    startWorkflowAudioRunAction:
      @escaping @Sendable (WorkflowDefinition, TriggerBinding) async throws -> Void = { _, _ in
        throw NSError(
          domain: "Rill.AppModel",
          code: 3,
          userInfo: [NSLocalizedDescriptionKey: "Workflow audio capture is not configured."]
        )
      },
    finishWorkflowAudioRunAction: @escaping @Sendable () async throws -> Void = {
      throw NSError(
        domain: "Rill.AppModel",
        code: 4,
        userInfo: [NSLocalizedDescriptionKey: "Workflow audio completion is not configured."]
      )
    },
    verifyOpenAIConfigurationAction:
      @escaping @Sendable (OpenAISettings) async throws -> Void = { _ in
        throw NSError(
          domain: "Rill.AppModel.OpenAI",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "LLM Provider verification is not configured."]
        )
      },
    retryFailedAudioRecoveryAction:
      @escaping @Sendable (
        UUID,
        WorkflowDefinition
      ) async throws -> FailedAudioRecoveryController.RetryResult = { _, _ in
        throw FailedAudioRecoveryError.storageUnavailable
      },
    deleteFailedAudioRecoveryAction: @escaping @Sendable (UUID) async throws -> Void = { _ in
      throw FailedAudioRecoveryError.storageUnavailable
    },
    clearFailedAudioRecoveryAction: @escaping @Sendable () async throws -> Void = {
      throw FailedAudioRecoveryError.storageUnavailable
    },
    refreshFailedAudioRecoveryAction: @escaping @Sendable (Bool) async throws -> Void = { _ in
      throw FailedAudioRecoveryError.storageUnavailable
    },
    loadFailedAudioRecoveryReceiptsAction:
      @escaping @Sendable () async throws -> [FailedAudioRecoveryReceipt] = {
        throw FailedAudioRecoveryError.storageUnavailable
      },
    clearBenchmarkRecordingArchiveAction: @escaping @Sendable () async throws -> Void = {
      throw BenchmarkRecordingArchiveError.storageUnavailable
    },
    refreshBenchmarkRecordingArchiveAction: @escaping @Sendable (Bool) async throws -> Void = { _ in
      throw BenchmarkRecordingArchiveError.storageUnavailable
    },
    authorizeWorkflowRunAction:
      @escaping @Sendable (
        WorkflowDefinition
      ) async throws -> AuthorizedWorkflowRunContext = { _ in
        throw SessionCoordinator.SessionError.privacyAuthorizationRequired
      },
    explainResolvedWorkflowAction:
      @escaping @Sendable (
        WorkflowResolvedExecutionPlan
      ) async throws -> WorkflowExplanationReceipt = { plan in
        WorkflowExplanationReceipt(
          workflowID: plan.executionWorkflow.id,
          trigger: .manual,
          inputs: [],
          transforms: [],
          outputs: [],
          processingDestinations: [],
          status: .blocked,
          issues: [
            WorkflowExplanationIssue(
              kind: .privacyEvaluationUnavailable,
              component: .privacyPolicy
            )
          ]
        )
      },
    writeClipboardTextAction: @escaping @MainActor (String) -> Void,
    deliverNextRecordAction: @escaping () -> Void,
    permissionSnapshot: PermissionSnapshot,
    language: AppLanguage = .preferred,
    refreshPermissionsAction: @escaping () -> Void,
    requestAccessibilityAction: @escaping () -> Void,
    requestMicrophoneAction: @escaping () -> Void,
    openAccessibilitySettingsAction: @escaping () -> Void,
    openMicrophoneSettingsAction: @escaping () -> Void,
    requestGlobalInputAction: @escaping () -> Void,
    retryGlobalInputAction: @escaping () -> Void,
    workflowLibraryChangedAction: @escaping @MainActor () -> Void
) -> AppModel {
  AppModel(
    workflows: initialWorkflows,
    eventBus: eventBus,
    sessionCoordinator: sessionCoordinator,
    outputActionRegistry: outputActionRegistry,
    recordWorkspace: recordWorkspace ?? RecordWorkspaceModel(store: RecordStore()),
    candidateResolver: candidateResolver,
    historyRepository: historyRepository,
    runHistoryBrowser: runHistoryBrowser,
    runReceiptRepository: runReceiptRepository,
    localHistoryMaintenance: localHistoryMaintenance,
    diagnosticRepository: diagnosticRepository,
    settingsStore: settingsStore,
    workflowFileStore: workflowFileStore,
    credentialStore: credentialStore,
    localPersistenceStatus: localPersistenceStatus,
    vocabularyRuleSource: vocabularyRuleSource,
    privacySettingsSource: privacySettingsSource,
    localSpeechSettingsSource: localSpeechSettingsSource,
    loadsPersistentSettingsOnInitialization: loadsPersistentSettingsOnInitialization,
    settingsWriteDebounceDuration: settingsWriteDebounceDuration,
    historyRetentionMaintenanceInterval: historyRetentionMaintenanceInterval,
    liveSubtitlePreparingHideDelay: liveSubtitlePreparingHideDelay,
    localSpeechAvailability: localSpeechAvailability ?? (localSpeechTrustMaterialAvailable ? .available : .trustMaterialUnavailable),
    trustedLocalSpeechModels: trustedLocalSpeechModels,
    defaultLocalSpeechModelIdentifier: defaultLocalSpeechModelIdentifier,
    ttsModelOptions: ttsModelOptions,
    defaultTTSModelIdentifier: defaultTTSModelIdentifier,
    localSpeechPhysicalMemoryGiB: localSpeechPhysicalMemoryGiB,
    prepareLocalSpeechAction: prepareLocalSpeechAction,
    synchronizeResidentSpeechModelsAction: synchronizeResidentSpeechModelsAction,
    prepareEnabledSpeechModelAction: prepareEnabledSpeechModelAction,
    setLocalSpeechRuntimeEnabledAction: setLocalSpeechRuntimeEnabledAction,
    releaseLocalSpeechRuntimeAction: releaseLocalSpeechRuntimeAction,
    stopLocalSpeechRuntimeAction: stopLocalSpeechRuntimeAction,
    startWorkflowAudioRunAction: startWorkflowAudioRunAction,
    finishWorkflowAudioRunAction: finishWorkflowAudioRunAction,
    verifyOpenAIConfigurationAction: verifyOpenAIConfigurationAction,
    retryFailedAudioRecoveryAction: retryFailedAudioRecoveryAction,
    deleteFailedAudioRecoveryAction: deleteFailedAudioRecoveryAction,
    clearFailedAudioRecoveryAction: clearFailedAudioRecoveryAction,
    refreshFailedAudioRecoveryAction: refreshFailedAudioRecoveryAction,
    loadFailedAudioRecoveryReceiptsAction: loadFailedAudioRecoveryReceiptsAction,
    clearBenchmarkRecordingArchiveAction: clearBenchmarkRecordingArchiveAction,
    refreshBenchmarkRecordingArchiveAction: refreshBenchmarkRecordingArchiveAction,
    authorizeWorkflowRunAction: authorizeWorkflowRunAction,
    explainResolvedWorkflowAction: explainResolvedWorkflowAction,
    writeClipboardTextAction: writeClipboardTextAction,
    deliverNextRecordAction: deliverNextRecordAction,
    permissionSnapshot: permissionSnapshot,
    language: language,
    refreshPermissionsAction: refreshPermissionsAction,
    requestAccessibilityAction: requestAccessibilityAction,
    requestMicrophoneAction: requestMicrophoneAction,
    openAccessibilitySettingsAction: openAccessibilitySettingsAction,
    openMicrophoneSettingsAction: openMicrophoneSettingsAction,
    requestGlobalInputAction: requestGlobalInputAction,
    retryGlobalInputAction: retryGlobalInputAction,
    workflowLibraryChangedAction: workflowLibraryChangedAction
  )
}
