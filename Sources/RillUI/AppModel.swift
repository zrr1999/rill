import Foundation
import Observation
import RillCore
import RillRuntime

public enum OpenAICredentialAvailability: Sendable, Equatable {
  case loading
  case missing
  case saving
  case available
  case inaccessible
}

public enum OpenAIConfigurationVerificationState: Sendable, Equatable {
  case idle
  case verifying
  case verified
  case failed
}

public enum LocalSpeechPreparationState: Sendable, Equatable {
  case idle
  case preparing
  case ready
}

public enum WorkflowExplanationFailure: Sendable, Equatable {
  case workflowUnavailable
  case providerUnavailable
  case invalidReceipt
}

public enum WorkflowExplanationLoadState: Sendable, Equatable {
  case idle
  case loading(workflowID: UUID)
  case loaded(WorkflowExplanationReceipt)
  case failed(workflowID: UUID, reason: WorkflowExplanationFailure)
}

enum WorkflowAudioRunState: Sendable, Equatable {
  case idle
  case preparing(workflowID: UUID)
  case recording(workflowID: UUID)
  case transcribing(workflowID: UUID)
}

public enum ClipboardHistoryVisibility: String, CaseIterable, Identifiable, Sendable, Equatable {
  case remainingOnly = "remaining-only"
  case all = "all"

  public var id: String { rawValue }
}

actor LocalSpeechPreparationProgressRelay {
  weak var model: AppModel?
  let operationID: UUID

  init(model: AppModel, operationID: UUID) {
    self.model = model
    self.operationID = operationID
  }

  func update(progress: Progress) async {
    await MainActor.run { [weak model, operationID] in
      model?.updateLocalSpeechPreparationProgress(
        progress,
        operationID: operationID
      )
    }
  }
}

actor DiagnosticEventRelay {
  let flushInterval: Duration
  let deliver: @Sendable ([DiagnosticEvent]) async -> Void

  var bufferedEvents: [DiagnosticEvent] = []
  var flushTask: Task<Void, Never>?

  init(
    flushInterval: Duration = .milliseconds(40),
    deliver: @escaping @Sendable ([DiagnosticEvent]) async -> Void
  ) {
    self.flushInterval = flushInterval
    self.deliver = deliver
  }

  func enqueue(_ event: DiagnosticEvent) {
    bufferedEvents.append(event)
    guard flushTask == nil else { return }
    let flushInterval = self.flushInterval
    flushTask = Task { [weak self] in
      try? await Task.sleep(for: flushInterval)
      guard !Task.isCancelled else { return }
      await self?.flush()
    }
  }

  func cancel() {
    flushTask?.cancel()
    flushTask = nil
    bufferedEvents = []
  }

  func drain() async {
    flushTask?.cancel()
    flushTask = nil
    let batch = bufferedEvents
    bufferedEvents = []
    guard !batch.isEmpty else { return }
    await deliver(batch)
  }

  private func flush() async {
    flushTask = nil
    let batch = bufferedEvents
    bufferedEvents = []
    guard !batch.isEmpty else { return }
    await deliver(batch)
  }
}

final class WorkflowExplanationTaskOwner {
  private var task: Task<Void, Never>?

  func replace(with task: Task<Void, Never>) {
    self.task?.cancel()
    self.task = task
  }

  func clear() {
    task = nil
  }

  func cancel() {
    task?.cancel()
    task = nil
  }

  deinit {
    task?.cancel()
  }
}

public struct WorkflowTriggerConflict: Identifiable, Equatable, Sendable {
  public let trigger: TriggerBinding
  public let workflowIDs: [UUID]

  public var id: String { trigger.rawValue }

  public init(trigger: TriggerBinding, workflowIDs: [UUID]) {
    self.trigger = trigger
    self.workflowIDs = workflowIDs
  }
}

public enum VoiceAssistantResourceState: Sendable, Equatable {
  case notInstalled
  case preparing(progress: Double?)
  case ready
  case failed(String)
  case unavailable(VoiceAssistantResourceUnavailableReason)

  public var isPreparing: Bool {
    if case .preparing = self { return true }
    return false
  }
}

public enum VoiceAssistantResourceUnavailableReason: Error, Sendable, Equatable {
  case distributionLicenseUnverified
}

public struct TTSModelOption: Identifiable, Equatable, Sendable {
  public let id: String
  public let precision: String
  public let approximateDownloadByteCount: UInt64
  public let isDefault: Bool

  public init(
    id: String,
    precision: String,
    approximateDownloadByteCount: UInt64,
    isDefault: Bool
  ) {
    self.id = id
    self.precision = precision
    self.approximateDownloadByteCount = approximateDownloadByteCount
    self.isDefault = isDefault
  }
}

public enum WakeWordRuntimePresentationState: Sendable, Equatable {
  case disabled
  case modelMissing
  case starting
  case listening
  case suspended(String)
  case failed(String)
}

public struct WakeWordSettingsSnapshot: Sendable, Equatable {
  public let phrases: [String]
  public let isEnabled: Bool
  public let workflowName: String?

  public init(
    phrases: [String],
    isEnabled: Bool,
    workflowName: String?
  ) {
    self.phrases = phrases
    self.isEnabled = isEnabled
    self.workflowName = workflowName
  }
}

public enum WakeWordSettingsUpdateResult: Sendable, Equatable {
  case saved
  case failed(String)
}

@MainActor
@Observable
public final class AppModel {
  static let vocabularyRulesSettingKey = AppSettingKey(rawValue: "vocabulary.rules")!
  static let vocabularyLibrarySettingKey = AppSettingKey.vocabularyLibrary
  static let workflowLibrarySettingKey = AppSettingKey.workflowLibrary

  static let settingsLoadKeys: [AppSettingKey] = [
    .interfaceLanguage,
    .customWorkflows,
    workflowLibrarySettingKey,
    .workflowEnabledStates,
    .clipboardCaptureEnabled,
    .clipboardMergeSimilarItems,
    .clipboardHistoryVisibility,
    .clipboardPanelHotkey,
    .preferredSpeechEngine,
    .localSpeechModel,
    .localSpeechDownloadedModels,
    .localSpeechPrewarm,
    .ttsModel,
    .legacyWhisperKitModel,
    .legacyWhisperKitDownloadedModels,
    .legacyWhisperKitCustomModel,
    .legacyWhisperKitModelRepo,
    .legacyWhisperKitModelFolder,
    .legacyWhisperKitLanguage,
    .legacyWhisperKitDownloadIfNeeded,
    .legacyWhisperKitPrewarm,
    .openAIBaseURL,
    .openAIModel,
    vocabularyRulesSettingKey,
    vocabularyLibrarySettingKey,
    .privacySensitiveAppRules,
    .privacyCloudConfirmationRequired,
    .privacyCloudProcessingAuthorizations,
    .privacyHistoryPreviewMode,
    .privacySecureInputConservativeMode,
    .clipboardHistoryRetentionPeriod,
    .runHistoryRetentionPeriod,
    .failedAudioRecoveryEnabled,
    .builtinPushToTalkOutputMode,
    .longRecordingModeEnabled,
    .recordingDurationLimit,
  ]

  static let debouncedStringSettingKeys: Set<AppSettingKey> = [
    .localSpeechModel,
    .ttsModel,
    .openAIAPIKey,
    .openAIBaseURL,
    .openAIModel,
  ]

  static let recognizerIDsRequiringCapturedAudio: Set<String> = [
    sherpaOnnxRecognizerID
  ]
  static let productionPostProcessStepKinds: Set<PostProcessStepKind> = [
    .llmRewrite,
    .normalizeWhitespace
  ]

  public internal(set) var builtInWorkflows: [WorkflowDefinition]
  public internal(set) var customWorkflows: [WorkflowDefinition] = []
  public internal(set) var workflows: [WorkflowDefinition]
  public internal(set) var workflowLibraryAvailability: StoredSettingsDomainAvailability =
    .available
  public internal(set) var workflowTriggerConflicts: [WorkflowTriggerConflict] = []
  public internal(set) var workflowConflictIDsByWorkflowID: [UUID: [UUID]] = [:]
  public var workflowConfigurationDirectoryURL: URL? {
    workflowFileStore?.configurationDirectoryURL
  }
  public let localPersistenceStatus: LocalPersistenceStatus
  public internal(set) var selectedSidebarSection: SidebarSection = .dashboard
  public internal(set) var selectedClipboardSidebarGroupID: UUID?
  public var runHistoryScope: RunHistoryScope = .recentRuns {
    didSet {
      guard oldValue != runHistoryScope else { return }
      resetRunHistoryBrowsing()
    }
  }
  internal var settingsNavigationRequest: SettingsNavigationRequest?
  internal var historyNavigationRequest: HistoryNavigationRequest?
  internal var workflowEditorNavigationRequest: WorkflowEditorNavigationRequest?
  public var language: AppLanguage { didSet { handleLanguageChange(from: oldValue) } }
  public var clipboardCaptureEnabled: Bool {
    didSet { handleClipboardCaptureEnabledChange(from: oldValue) }
  }
  public internal(set) var clipboardCapturePreferenceRevision: UInt64 = 0
  public var clipboardPanelHotkeyBinding: HotkeyBindingDescriptor {
    didSet { handleClipboardPanelHotkeyChange(from: oldValue) }
  }
  public var preferredSpeechEngine: PreferredSpeechEngine {
    didSet { handlePreferredSpeechEngineChange(from: oldValue) }
  }
  public var builtinPushToTalkOutputMode: BuiltinPushToTalkOutputMode {
    didSet { handleBuiltinPushToTalkOutputModeChange(from: oldValue) }
  }
  public var longRecordingModeEnabled: Bool {
    didSet { handleLongRecordingModeChange(from: oldValue) }
  }
  public var recordingDurationLimit: RecordingDurationLimit {
    didSet { handleRecordingDurationLimitChange(from: oldValue) }
  }
  public var localSpeechModelOption: LegacyWhisperModelOption {
    didSet { handleLegacyWhisperModelOptionChange(from: oldValue) }
  }
  public var legacyWhisperKitCustomModel: String {
    didSet { handleLegacyWhisperCustomModelChange(from: oldValue) }
  }
  public var localSpeechModel: String { didSet { handleLocalSpeechModelChange(from: oldValue) } }
  public var legacyWhisperKitModelRepo: String {
    didSet { handleLegacyWhisperModelRepoChange(from: oldValue) }
  }
  public var legacyWhisperKitModelToken: String {
    didSet { handleLegacyWhisperModelTokenChange(from: oldValue) }
  }
  public var legacyWhisperKitModelFolder: String {
    didSet { handleLegacyWhisperModelFolderChange(from: oldValue) }
  }
  public var legacyWhisperKitLanguage: String {
    didSet { handleLegacyWhisperLanguageChange(from: oldValue) }
  }
  public var legacyWhisperKitDownloadIfNeeded: Bool {
    didSet { handleLegacyWhisperDownloadIfNeededChange(from: oldValue) }
  }
  public var localSpeechPrewarm: Bool { didSet { handleLocalSpeechPrewarmChange(from: oldValue) } }
  public internal(set) var settingsSaveState: SettingsSaveState = .saved
  public internal(set) var unavailableScalarSettingKeys: Set<AppSettingKey> = []
  public internal(set) var retryingUnavailableScalarSettingsDomains: Set<ScalarSettingsDomain> = []
  public var openAIAPIKey: String { didSet { handleOpenAIAPIKeyChange(from: oldValue) } }
  public var openAIBaseURL: String {
    didSet { handleOpenAIBaseURLChange(from: oldValue) }
  }
  public var openAIModel: String {
    didSet { handleOpenAIModelChange(from: oldValue) }
  }
  public internal(set) var openAICredentialAvailability: OpenAICredentialAvailability = .loading
  public internal(set) var openAIConfigurationVerificationState:
    OpenAIConfigurationVerificationState = .idle
  public internal(set) var openAIVerificationFailure: OpenAIVerificationFailure?
  public var isRunning = false
  public internal(set) var isLoadingSettings = true
  public internal(set) var isRetryingUnavailableSettingsDomains = false
  var workflowAudioRunState: WorkflowAudioRunState = .idle
  public internal(set) var localSpeechPreparationState: LocalSpeechPreparationState = .idle
  public internal(set) var localSpeechPreparationProgress: Double = 0
  public internal(set) var localSpeechPreparationCompletedUnitCount: Int64 = 0
  public internal(set) var localSpeechPreparationTotalUnitCount: Int64 = 0
  public internal(set) var localSpeechPreparedModelIdentifier: String?
  public internal(set) var downloadedLocalSpeechModels: [String] = []
  public internal(set) var downloadedLocalSpeechModelsAvailability:
    StoredSettingsDomainAvailability = .available
  public internal(set) var downloadedLocalSpeechModelsError: String?
  public var localSpeechPreparationError: String?
  public let localSpeechAvailability: LocalSpeechAvailability
  public let localSpeechTrustMaterialAvailable: Bool
  public let trustedLocalSpeechModels: [LocalSpeechModelDescriptor]
  public let defaultLocalSpeechModelIdentifier: String?
  public let localSpeechPhysicalMemoryGiB: Int
  public var workflowEditorError: String?
  public var workflowLibraryError: String?
  public internal(set) var wakeWordResourceState: VoiceAssistantResourceState = .notInstalled
  public internal(set) var wakeWordRuntimeState: WakeWordRuntimePresentationState = .disabled
  public let ttsModelOptions: [TTSModelOption]
  public let defaultTTSModelIdentifier: String
  public var ttsModelIdentifier: String {
    didSet { handleTTSModelIdentifierChange(from: oldValue) }
  }
  public internal(set) var downloadedTTSModelIdentifiers: Set<String> = []
  public internal(set) var ttsResourceState: VoiceAssistantResourceState = .notInstalled
  public internal(set) var isSpeechPlaybackActive = false
  public internal(set) var workflowExplanationState: WorkflowExplanationLoadState = .idle
  public var pendingResolution: CandidateResolutionCase?
  public var permissionSnapshot: PermissionSnapshot
  public internal(set) var globalInputCapability: GlobalInputCapability = .checking
  public var stackCount = 0
  public var stackPreview: String?
  public internal(set) var clipboardCaptureControlSnapshot = ClipboardCaptureControlSnapshot(
    revision: 0,
    state: .paused
  )
  public var isClipboardCapturePaused: Bool {
    clipboardCaptureControlSnapshot.state.isPaused
  }
  public var isIgnoringNextExternalClipboardChange: Bool {
    clipboardCaptureControlSnapshot.state.isIgnoringNextExternalChange
  }
  public var isClipboardCaptureControlTransitioning: Bool {
    clipboardCaptureControlSnapshot.state.isTransitioning
  }
  public var lastCompletedText: String?
  public var lastFailure: String?
  public var eventFeed: [EventFeedEntry] = []
  public internal(set) var diagnosticEvents: [DiagnosticEvent] = []
  public internal(set) var diagnosticsLoadState: DiagnosticsLoadState = .loading
  public internal(set) var vocabularyRules: [VocabularyRule] = [] {
    didSet {
      if !isApplyingVocabularyLibrary {
        let migration = VocabularyLegacyMigrator.migrate(vocabularyRules)
        vocabularyCollections = migration.collections
        vocabularyCollectionBindings = migration.bindings
        vocabularyRuleSource.updateCollections(vocabularyCollections)
        rebuildWorkflowLibrary()
      }
      guard oldValue != vocabularyRules else { return }
      guard !isApplyingVocabularyLibrary else { return }
      persistVocabularyLibrary()
    }
  }
  public internal(set) var vocabularyCollections: [VocabularyCollection] = [.personal()]
  public internal(set) var vocabularyCollectionBindings: [VocabularyCollectionBinding] = [
    VocabularyCollectionBinding(collectionID: VocabularyCollection.personalID),
  ]
  public internal(set) var workflowCustomizations: [WorkflowCustomization] = []
  public internal(set) var vocabularyRulesAvailability: StoredSettingsDomainAvailability =
    .available
  public internal(set) var vocabularyRulesError: String?
  public internal(set) var privacyPolicySettings: PrivacyPolicySettings = .defaults {
    didSet {
      guard oldValue != privacyPolicySettings else { return }
      invalidateWorkflowExplanation()
      if oldValue.historyPreviewMode != privacyPolicySettings.historyPreviewMode {
        resetRunHistoryBrowsingForPrivacyChange()
      }
      if !isLoadingPrivacySettings, privacySettingsLoadError == nil {
        privacySettingsSource.update(privacyPolicySettings)
      }
      persistPrivacyPolicySettings()
    }
  }
  public internal(set) var isLoadingPrivacySettings = false
  public internal(set) var isSavingPrivacySettings = false
  public internal(set) var privacySettingsLoadError: String?
  public internal(set) var privacySettingsSaveError: String?
  public internal(set) var clipboardHistoryRetentionPeriod: HistoryRetentionPeriod = .defaultPeriod
  public internal(set) var runHistoryRetentionPeriod: HistoryRetentionPeriod = .defaultPeriod {
    didSet {
      guard oldValue != runHistoryRetentionPeriod else { return }
      resetRunHistoryBrowsing()
    }
  }
  public internal(set) var isUpdatingHistoryRetentionSettings = false
  public internal(set) var isLocalHistoryMaintenanceRunning = false
  public internal(set) var historyRetentionSettingsError: String?
  public internal(set) var areHistoryRetentionSettingsAvailable = true
  public internal(set) var localHistoryMaintenancePendingReason: String?
  public internal(set) var localHistoryMaintenanceBlockedReason: String?
  public internal(set) var lastLocalHistoryRemovedCount = 0
  public internal(set) var lastPreservedActiveClipboardCount = 0
  public internal(set) var historyLoadState: HistoryLoadState = .loaded
  public internal(set) var historyRecords: [HistoryRecord] = []
  public internal(set) var runHistoryBrowseLoadState: HistoryLoadState = .loaded
  public internal(set) var runHistoryPage: RunHistoryPage?
  public internal(set) var isRunHistoryPageTransitioning = false
  public internal(set) var runHistoryPaginationFailed = false
  public internal(set) var runHistoryHasNewerEntries = false
  public internal(set) var runHistoryDeepLinkState: RunHistoryDeepLinkState = .idle
  public internal(set) var workflowRunReceiptsByRunID: [UUID: WorkflowRunReceipt] = [:]
  public internal(set) var failedAudioRecoveryReceipts: [FailedAudioRecoveryReceipt] = []
  public internal(set) var failedAudioRecoveryEnabled = false
  public internal(set) var isUpdatingFailedAudioRecovery = false
  public internal(set) var retryingFailedAudioRecoveryIDs: Set<UUID> = []
  public internal(set) var failedAudioRecoveryUnavailableReasonsByRunID:
    [UUID: FailedAudioRecoveryError] = [:]
  public var failedAudioRecoveryError: String?
  public internal(set) var clipboardItems: [ClipboardHistoryItem] = []
  public internal(set) var clipboardGroups: [ClipboardGroupSummary] = []
  public internal(set) var clipboardDefaultGroup = ClipboardGroupSummary(
    group: .defaultGroup,
    count: 0,
    previewText: nil
  )
  public internal(set) var clipboardAppAssignments: [ClipboardAppAssignment] = []
  public internal(set) var clipboardRemainingItemIDs: Set<UUID> = []
  public internal(set) var clipboardPersistenceAvailability: ClipboardPersistenceAvailability =
    .available
  public internal(set) var clipboardStorageLimits: ClipboardStorageLimits = .productDefault
  public internal(set) var clipboardStorageRejection: ClipboardStorageRejectionReason?
  public internal(set) var clipboardStoragePressureContext: ClipboardStoragePressureContext?
  public internal(set) var isRetryingClipboardPersistence = false
  public internal(set) var isResettingClipboardPersistence = false
  public internal(set) var clipboardPersistenceResetFailed = false
  public internal(set) var liveSubtitleSnapshot: LiveSubtitleSnapshot?
  var currentCaptureLiveSubtitleSnapshot: LiveSubtitleSnapshot? {
    didSet {
      guard
        hasLiveSubtitleSemanticChange(
          from: oldValue,
          to: currentCaptureLiveSubtitleSnapshot
        )
      else { return }
      cancelPendingLiveSubtitleMeterRefresh()
    }
  }
  var workflowAudioCaptureRunID: UUID?
  var audioProcessingQueueSnapshot: AudioProcessingQueueSnapshot?
  var lastLiveSubtitleMeterRefreshAt: ContinuousClock.Instant?
  var pendingLiveSubtitleMeterSnapshot: LiveSubtitleSnapshot?
  var clipboardHistoryEntries: [ClipboardHistoryEntry] = []
  public var clipboardHistoryVisibility: ClipboardHistoryVisibility {
    didSet {
      guard oldValue != clipboardHistoryVisibility else { return }
      persistClipboardHistoryVisibilityPreference()
    }
  }
  public internal(set) var mergeSimilarClipboardItems = false
  public var enabledManualWorkflows: [WorkflowDefinition] {
    enabledWorkflows(for: .manual)
  }
  public var enabledLongRecordingWorkflows: [WorkflowDefinition] {
    enabledManualWorkflows.filter { requiresCapturedAudioForInteractiveRun($0) }
  }
  public var localSpeechTestWorkflow: WorkflowDefinition? {
    guard
      var workflow = workflows.first(where: { workflow in
        workflow.trigger == .hotkey
          && workflow.metadata[WorkflowMetadataKey.catalog]
            == BuiltinWorkflowRoutingValue.catalog
          && workflow.metadata[WorkflowMetadataKey.builtinKind]
            == Self.builtinPushToTalkKindValue
      })
    else {
      return nil
    }
    workflow.id = Self.localSpeechTestWorkflowID
    workflow.name = "Local Speech Test"
    workflow.titleKey = nil
    workflow.trigger = .manual
    workflow.plan.setup.speechRoute = WorkflowSpeechRoute(
      selection: .fixed,
      recognizerID: Self.sherpaOnnxRecognizerID
    )
    workflow.plan.output = WorkflowOutputPhase(
      actions: [OutputActionReference(id: "stack.push")],
      deliveryPolicy: DeliveryPolicy(strategy: .stackFirst)
    )
    workflow.metadata.removeValue(forKey: WorkflowMetadataKey.catalog)
    workflow.metadata.removeValue(forKey: WorkflowMetadataKey.triggerGesture)
    workflow.metadata.removeValue(forKey: WorkflowMetadataKey.builtinKind)
    workflow.metadata.removeValue(forKey: WorkflowMetadataKey.exclusiveGroup)
    workflow.metadata.removeValue(forKey: WorkflowMetadataKey.recognizerSelectionMode)
    workflow.metadata[WorkflowMetadataKey.targetClipboardGroupID] =
      ClipboardGroup.voiceGroupID.uuidString
    return workflow
  }
  public var enabledTextStyleWorkflows: [WorkflowDefinition] {
    workflows.filter { workflow in
      isWorkflowEnabled(workflow) && requiresCapturedAudioForInteractiveRun(workflow)
        && VoiceTextStyle.infer(from: workflow) != .custom
    }
  }
  public var canRunAnyManualWorkflow: Bool {
    enabledManualWorkflows.contains(where: canTriggerWorkflow)
  }
  public var canDeliverTopOfStack: Bool {
    stackCount > 0 && permissionSnapshot.accessibility == .granted
  }
  public var hasActiveOrQueuedVoiceRun: Bool {
    isRunning || (audioProcessingQueueSnapshot?.isVisible ?? false)
  }
  public var isLocalHistoryMaintenanceAvailable: Bool {
    localHistoryMaintenance != nil
  }
  public var canClearRunHistory: Bool {
    !hasActiveOrQueuedVoiceRun && !isLocalHistoryMaintenanceRunning
      && !isUpdatingHistoryRetentionSettings
  }
  public var recentVoiceHistoryRecords: [HistoryRecord] {
    historyRecords.filter(isVoiceHistoryRecord)
  }
  public var recentVoiceResultRecords: [HistoryRecord] {
    recentVoiceHistoryRecords.filter { record in
      record.outcome == .completed
        && !(record.finalText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
  }
  public var localizedWindowTitle: String {
    UIStrings.text(.appTitle, language: language)
  }
  public var isApplicationShuttingDown: Bool {
    hasBegunApplicationShutdown
  }
  public var localizedMenuBarTitle: String {
    UIStrings.text(.menuBarLabel, language: language)
  }
  public var localizedWorkflowWindowTitle: String {
    UIStrings.text(.workflowsTitle, language: language)
  }

  let eventBus: EventBus
  let sessionCoordinator: SessionCoordinator
  let outputActionRegistry: OutputActionRegistry
  let deliveryStack: DeliveryStack?
  let candidateResolver: CandidateResolver
  let historyRepository: (any HistoryRepository)?
  let runHistoryBrowser: (any RunHistoryBrowsing)?
  let runReceiptRepository: (any WorkflowRunReceiptRepository)?
  let localHistoryMaintenance: (any LocalHistoryMaintaining)?
  let diagnosticRepository: (any DiagnosticRepository)?
  let settingsStore: (any SettingsStore)?
  let workflowFileStore: (any WorkflowFileStore)?
  let credentialStore: (any SecureCredentialStore)?
  let vocabularyRuleSource: VocabularyRuleSource
  let privacySettingsSource: PrivacyPolicySettingsSource
  let localSpeechSettingsSource: LocalSpeechSettingsSource
  let settingsWriteDebounceDuration: Duration
  let historyRetentionMaintenanceInterval: Duration?
  let liveSubtitleMeterRefreshInterval: Duration = .milliseconds(180)
  var waitForLiveSubtitleMeterRefresh: @Sendable (Duration) async throws -> Void = { duration in
    try await Task.sleep(for: duration)
  }
  let warmLocalSpeechForCaptureAction:
    @Sendable (
      LocalSpeechSettings,
      @escaping @Sendable (Progress) -> Void
    ) async throws -> String
  let prepareLocalSpeechAction:
    @Sendable (
      LocalSpeechSettings,
      @escaping @Sendable (Progress) -> Void
    ) async throws -> String
  let setLocalSpeechRuntimeEnabledAction: @Sendable (Bool) -> Void
  let releaseLocalSpeechRuntimeAction: @Sendable () -> Void
  let stopLocalSpeechRuntimeAction: @Sendable () async -> Void
  let startWorkflowAudioRunAction:
    @Sendable (WorkflowDefinition, TriggerBinding) async throws -> Void
  let finishWorkflowAudioRunAction: @Sendable () async throws -> Void
  let verifyOpenAIConfigurationAction: @Sendable (OpenAISettings) async throws -> Void
  let retryFailedAudioRecoveryAction:
    @Sendable (
      UUID,
      WorkflowDefinition
    ) async throws -> FailedAudioRecoveryController.RetryResult
  let deleteFailedAudioRecoveryAction: @Sendable (UUID) async throws -> Void
  let clearFailedAudioRecoveryAction: @Sendable () async throws -> Void
  let refreshFailedAudioRecoveryAction: @Sendable (Bool) async throws -> Void
  let loadFailedAudioRecoveryReceiptsAction:
    @Sendable () async throws -> [FailedAudioRecoveryReceipt]
  let authorizeWorkflowRunAction:
    @Sendable (
      WorkflowDefinition
    ) async throws -> AuthorizedWorkflowRunContext
  let authorizeClipboardItemRunAction:
    @Sendable (
      UUID,
      ClipboardItemVersion,
      ClipboardItemDryRunOperation,
      WorkflowDefinition
    ) async throws -> AuthorizedWorkflowRunContext
  let explainResolvedWorkflowAction:
    @Sendable (
      WorkflowResolvedExecutionPlan
    ) async throws -> WorkflowExplanationReceipt
  let previewClipboardItemAction:
    @Sendable (
      UUID,
      ClipboardItemDryRunOperation,
      WorkflowDefinition?
    ) async throws -> PreparedClipboardItemDryRun
  let writeClipboardTextAction: @MainActor (String) -> Void
  let pasteTopOfStackAction: () -> Void
  let refreshPermissionsAction: () -> Void
  let requestAccessibilityAction: () -> Void
  let requestMicrophoneAction: () -> Void
  let openAccessibilitySettingsAction: () -> Void
  let openMicrophoneSettingsAction: () -> Void
  var requestGlobalInputAction: () -> Void = {}
  var retryGlobalInputAction: () -> Void = {}
  var beginClipboardPanelShortcutRecordingAction: () -> UUID = { UUID() }
  var endClipboardPanelShortcutRecordingAction: (UUID) -> Void = { _ in }
  var commitClipboardPanelShortcutRecordingAction: (UUID, UInt16) -> Void = { _, _ in }
  var showClipboardPanelAction: () -> Void = {}
  var setClipboardCaptureEnabledAction: (Bool, UInt64) -> Void = { _, _ in }
  var ignoreNextExternalClipboardChangeAction: () -> Void = {}
  var openWorkflowEditorAction: () -> Void = {}
  var workflowLibraryChangedAction: @MainActor () -> Void = {}
  var prepareWakeWordModelAction:
    @Sendable (@escaping @Sendable (Double) -> Void) async throws -> String = { _ in
      throw NSError(
        domain: "Rill.WakeWord",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Local speech preparation for wake-word listening is unavailable."
        ]
      )
    }
  var prepareTTSModelAction:
    @Sendable (String, @escaping @Sendable (Double) -> Void) async throws -> Void = { _, _ in
      throw NSError(
        domain: "Rill.TTS",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "TTS model preparation is unavailable."]
      )
    }
  var selectTTSModelAction: @Sendable (String) -> Void = { _ in }
  var validateWakeWordConfigurationAction:
    @Sendable (WakeWordConfiguration) async throws -> Void = { _ in
      throw NSError(
        domain: "Rill.WakeWord",
        code: 2,
          userInfo: [
            NSLocalizedDescriptionKey:
            "Prepare the selected local speech model before saving a wake-word workflow."
          ]
      )
    }
  var stopSpeechPlaybackAction: @MainActor () -> Bool = { false }
  var updateClipboardPanelHotkeyAction: (HotkeyBindingDescriptor) -> Void = { _ in }
  var useClipboardItemAction: (ClipboardHistoryItem) -> Void = { _ in }
  var updateLiveSubtitlePanelAction: @MainActor (LiveSubtitleSnapshot?, AppLanguage) -> Void = {
    _, _ in
  }

  public func installWorkflowLibraryChangedAction(
    _ action: @escaping @MainActor () -> Void
  ) {
    workflowLibraryChangedAction = action
  }

  public func installVoiceAssistantResourceActions(
    prepareWakeWordModel:
      @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> String,
    prepareTTSModel:
      @escaping @Sendable (
        String,
        @escaping @Sendable (Double) -> Void
      ) async throws -> Void,
    selectTTSModel: @escaping @Sendable (String) -> Void,
    downloadedTTSModelIdentifiers: Set<String>,
    validateWakeWordConfiguration:
      @escaping @Sendable (WakeWordConfiguration) async throws -> Void,
    stopSpeechPlayback: @escaping @MainActor () -> Bool
  ) {
    prepareWakeWordModelAction = prepareWakeWordModel
    prepareTTSModelAction = prepareTTSModel
    selectTTSModelAction = selectTTSModel
    self.downloadedTTSModelIdentifiers = downloadedTTSModelIdentifiers.intersection(
      Set(ttsModelOptions.map(\.id))
    )
    selectTTSModelAction(ttsModelIdentifier)
    ttsResourceState =
      self.downloadedTTSModelIdentifiers.contains(ttsModelIdentifier)
      ? .ready
      : .notInstalled
    validateWakeWordConfigurationAction = validateWakeWordConfiguration
    stopSpeechPlaybackAction = stopSpeechPlayback
    synchronizeWakeWordResourceWithLocalSpeechModel()
  }

  public func installWakeWordConfigurationValidationAction(
    _ action: @escaping @Sendable (WakeWordConfiguration) async throws -> Void
  ) {
    validateWakeWordConfigurationAction = action
  }

  public func updateWakeWordRuntimeState(_ state: WakeWordRuntimePresentationState) {
    wakeWordRuntimeState = state
    if state == .listening {
      wakeWordResourceState = .ready
    } else if state == .modelMissing, wakeWordResourceState == .ready {
      wakeWordResourceState = .notInstalled
    }
  }

  public func updateWakeWordResourceState(_ state: VoiceAssistantResourceState) {
    wakeWordResourceState = state
  }

  public func updateSpeechPlaybackState(isActive: Bool) {
    isSpeechPlaybackActive = isActive
  }
  var pendingRuns: [UUID: PendingRunInfo] = [:]
  var pendingInteractiveWorkflowTask: Task<Void, Never>?
  var interactiveWorkflowTaskGeneration = 0
  var listenerTask: Task<Void, Never>?
  var eventListenerBarrierContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
  var eventListenerShutdownTask: Task<Void, Never>?
  var hasStoppedEventListener = false
  var activeRunID: UUID?
  var workflowEnabledStates: [UUID: Bool] = [:]
  var workflowFileURLsByID: [UUID: URL] = [:]
  var usesWorkflowFilesAsSource = false
  var hasModifiedWorkflowLibrary = false
  var isRestoringSettings = false
  /// Keys changed by the user after the initial snapshot read started but
  /// before it was applied. The older snapshot must not overwrite them.
  var settingsKeysModifiedDuringInitialLoad: Set<AppSettingKey> = []
  var pendingSettingWriteTasks: [AppSettingKey: Task<Void, Never>] = [:]
  var pendingSettingWriteGenerations: [AppSettingKey: Int] = [:]
  var failedSettingsStoreWrites: [AppSettingKey: RetryableSettingsStoreWrite] = [:]
  var retryingSettingsStoreWriteKeys: Set<AppSettingKey> = []
  var pendingPersistenceWriteBarrierTask: Task<Void, Never>?
  var persistenceWriteBarrierGeneration = 0
  var settingsLoadGeneration = 0
  var unavailableSettingsDomainRetryGeneration = 0
  var scalarSettingsRetryGenerations: [ScalarSettingsDomain: Int] = [:]
  var localSpeechModelMutationGeneration = 0
  let settingsReadTaskOwner = AppModelSettingsReadTaskOwner()
  var pendingPrivacySettingsWriteTask: Task<Void, Never>?
  var privacySettingsWriteGeneration = 0
  var pendingLiveSubtitleHideTask: Task<Void, Never>?
  var pendingLiveSubtitleMeterRefreshTask: Task<Void, Never>?
  var liveSubtitleMeterRefreshGeneration = 0
  var clipboardUpdateDebounceTask: Task<Void, Never>?
  var historyLoadGeneration = 0
  var runReceiptLoadGeneration = 0
  var historyProjectionLoadTasks: [UUID: Task<Void, Never>] = [:]
  var runHistoryBrowseTask: Task<Void, Never>?
  var runHistoryBrowseGeneration = 0
  var runHistoryCurrentPageLocator: RunHistoryPageLocator?
  var runHistoryNewerPageLocators: [RunHistoryPageLocator] = []
  var terminalReceiptTimestampByRunID: [UUID: Date] = [:]
  var terminalReceiptWriteGenerationByRunID: [UUID: RunHistoryWriteGeneration] = [:]
  var terminalReceiptTimestampOrder: [UUID] = []
  var historyRetentionRerunRequested = false
  var historyRetentionSettingsLoadError: String?
  var historyRetentionSettingsWriteError: String?
  var clipboardHistoryRetentionSettingIsInvalid = false
  var runHistoryRetentionSettingIsInvalid = false
  var shouldStartPeriodicHistoryRetentionMaintenance = false
  var localHistoryMaintenanceTasks: [UUID: Task<Void, Never>] = [:]
  var periodicHistoryRetentionMaintenanceTask: Task<Void, Never>?
  var diagnosticsLoadGeneration = 0
  var localSpeechReadinessGeneration = 0
  var localSpeechPreparationGeneration = 0
  let localSpeechPreparationTaskOwner = LocalSpeechPreparationTaskOwner()
  var shouldPrepareLocalSpeechModelAfterInitialSettingsLoad = false
  var openAICredentialLoadGeneration = 0
  var openAIVerificationGeneration = 0
  var openAIVerificationTask: Task<Void, Never>?
  var failedAudioRecoveryRetryTasks: [UUID: Task<Void, Never>] = [:]
  var hasBegunApplicationShutdown = false {
    didSet {
      guard hasBegunApplicationShutdown, !oldValue else { return }
      cancelPendingLiveSubtitleMeterRefresh()
    }
  }
  let clipboardMutationTaskOwner = AppModelClipboardMutationTaskOwner()
  let workflowExplanationTaskOwner = WorkflowExplanationTaskOwner()
  var workflowExplanationGeneration = 0
  var isApplyingVocabularyLibrary = false
  var hasReceivedClipboardSnapshot = false
  let liveSubtitlePreparingHideDelay: Duration

  public init(
    workflows: [WorkflowDefinition],
    eventBus: EventBus,
    sessionCoordinator: SessionCoordinator,
    outputActionRegistry: OutputActionRegistry,
    deliveryStack: DeliveryStack? = nil,
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
    warmLocalSpeechForCaptureAction:
      @escaping @Sendable (
        LocalSpeechSettings,
        @escaping @Sendable (Progress) -> Void
      ) async throws -> String = { settings, _ in
        settings.model
      },
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
          userInfo: [NSLocalizedDescriptionKey: "OpenAI verification is not configured."]
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
    authorizeWorkflowRunAction:
      @escaping @Sendable (
        WorkflowDefinition
      ) async throws -> AuthorizedWorkflowRunContext = { _ in
        throw SessionCoordinator.SessionError.privacyAuthorizationRequired
      },
    authorizeClipboardItemRunAction:
      @escaping @Sendable (
        UUID,
        ClipboardItemVersion,
        ClipboardItemDryRunOperation,
        WorkflowDefinition
      ) async throws -> AuthorizedWorkflowRunContext = { _, _, _, _ in
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
    previewClipboardItemAction:
      @escaping @Sendable (
        UUID,
        ClipboardItemDryRunOperation,
        WorkflowDefinition?
      ) async throws -> PreparedClipboardItemDryRun = { _, _, _ in
        throw ClipboardItemDryRunPreparationError.itemUnavailable
      },
    writeClipboardTextAction: @escaping @MainActor (String) -> Void,
    pasteTopOfStackAction: @escaping () -> Void,
    permissionSnapshot: PermissionSnapshot,
    language: AppLanguage = .preferred,
    refreshPermissionsAction: @escaping () -> Void,
    requestAccessibilityAction: @escaping () -> Void,
    requestMicrophoneAction: @escaping () -> Void,
    openAccessibilitySettingsAction: @escaping () -> Void,
    openMicrophoneSettingsAction: @escaping () -> Void
  ) {
    let catalogModelIdentifiers = Set(trustedLocalSpeechModels.map(\.id))
    let catalogIsValid =
      catalogModelIdentifiers.count == trustedLocalSpeechModels.count
      && !trustedLocalSpeechModels.isEmpty
      && defaultLocalSpeechModelIdentifier.map(catalogModelIdentifiers.contains) == true
      && trustedLocalSpeechModels.allSatisfy {
        $0.parameterCountMillions >= 0
          && $0.minimumSystemMemoryGiB > 0
          && $0.recommendedSystemMemoryGiB >= $0.minimumSystemMemoryGiB
          && $0.hardwareRecommendationPriority >= 0
      }
    let declaredLocalSpeechAvailability =
      localSpeechAvailability
      ?? (localSpeechTrustMaterialAvailable ? .available : .trustMaterialUnavailable)
    let usesLegacyInjectedTrust =
      declaredLocalSpeechAvailability.isAvailable
      && trustedLocalSpeechModels.isEmpty
      && defaultLocalSpeechModelIdentifier == nil
    let effectiveLocalSpeechAvailability: LocalSpeechAvailability
    if declaredLocalSpeechAvailability.isAvailable {
      effectiveLocalSpeechAvailability =
        catalogIsValid || usesLegacyInjectedTrust
        ? .available
        : .trustMaterialUnavailable
    } else {
      effectiveLocalSpeechAvailability = declaredLocalSpeechAvailability
    }
    let exposesTrustedCatalog = effectiveLocalSpeechAvailability.isAvailable && catalogIsValid
    self.builtInWorkflows = workflows
    self.workflows = workflows
    self.language = language
    // Capture remains closed until durable settings prove it is enabled.
    // Test and preview compositions that explicitly skip loading retain the
    // historical enabled behavior when they still provide a settings store.
    self.clipboardCaptureEnabled = settingsStore != nil && !loadsPersistentSettingsOnInitialization
    self.clipboardHistoryVisibility = .remainingOnly
    self.clipboardPanelHotkeyBinding = .doubleCommand
    self.preferredSpeechEngine = .local
    self.builtinPushToTalkOutputMode = .pasteIntoApp
    self.longRecordingModeEnabled = false
    self.recordingDurationLimit = .fiveMinutes
    self.localSpeechModelOption = .automatic
    self.legacyWhisperKitCustomModel = ""
    self.localSpeechModel = defaultLocalSpeechModelIdentifier ?? LocalSpeechSettings().model
    let resolvedDefaultTTSModelIdentifier =
      ttsModelOptions.contains(where: { $0.id == defaultTTSModelIdentifier })
      ? defaultTTSModelIdentifier
      : (ttsModelOptions.first(where: \.isDefault)?.id ?? ttsModelOptions.first?.id ?? "")
    self.ttsModelOptions = ttsModelOptions
    self.defaultTTSModelIdentifier = resolvedDefaultTTSModelIdentifier
    self.ttsModelIdentifier = resolvedDefaultTTSModelIdentifier
    self.legacyWhisperKitModelRepo = LocalSpeechSettings().modelRepo
    self.legacyWhisperKitModelToken = LocalSpeechSettings().modelToken
    self.legacyWhisperKitModelFolder = LocalSpeechSettings().modelFolder
    self.legacyWhisperKitLanguage = LocalSpeechSettings().language
    self.legacyWhisperKitDownloadIfNeeded = LocalSpeechSettings().downloadIfNeeded
    self.localSpeechPrewarm = LocalSpeechSettings().prewarm
    self.openAIAPIKey = ""
    self.openAIBaseURL = OpenAISettings().baseURL
    self.openAIModel = OpenAISettings().model
    self.permissionSnapshot = permissionSnapshot
    self.eventBus = eventBus
    self.sessionCoordinator = sessionCoordinator
    self.outputActionRegistry = outputActionRegistry
    self.deliveryStack = deliveryStack
    self.candidateResolver = candidateResolver
    self.historyRepository = historyRepository
    self.runHistoryBrowser = runHistoryBrowser
    self.runReceiptRepository = runReceiptRepository
    self.localHistoryMaintenance = localHistoryMaintenance
    self.diagnosticRepository = diagnosticRepository
    self.settingsStore = settingsStore
    self.workflowFileStore = workflowFileStore
    self.credentialStore = credentialStore
    self.localPersistenceStatus = localPersistenceStatus
    self.vocabularyRuleSource = vocabularyRuleSource
    self.privacySettingsSource = privacySettingsSource
    self.localSpeechSettingsSource = localSpeechSettingsSource
    self.isLoadingPrivacySettings = !privacySettingsSource.hasAvailableSettings
    self.settingsWriteDebounceDuration = settingsWriteDebounceDuration
    self.historyRetentionMaintenanceInterval = historyRetentionMaintenanceInterval
    self.liveSubtitlePreparingHideDelay = liveSubtitlePreparingHideDelay
    self.localSpeechAvailability = effectiveLocalSpeechAvailability
    self.localSpeechTrustMaterialAvailable = effectiveLocalSpeechAvailability.isAvailable
    self.trustedLocalSpeechModels = exposesTrustedCatalog ? trustedLocalSpeechModels : []
    self.defaultLocalSpeechModelIdentifier =
      exposesTrustedCatalog
      ? defaultLocalSpeechModelIdentifier
      : nil
    self.localSpeechPhysicalMemoryGiB = max(1, localSpeechPhysicalMemoryGiB)
    self.warmLocalSpeechForCaptureAction = warmLocalSpeechForCaptureAction
    self.prepareLocalSpeechAction = prepareLocalSpeechAction
    self.setLocalSpeechRuntimeEnabledAction = setLocalSpeechRuntimeEnabledAction
    self.releaseLocalSpeechRuntimeAction = releaseLocalSpeechRuntimeAction
    self.stopLocalSpeechRuntimeAction = stopLocalSpeechRuntimeAction
    self.startWorkflowAudioRunAction = startWorkflowAudioRunAction
    self.finishWorkflowAudioRunAction = finishWorkflowAudioRunAction
    self.verifyOpenAIConfigurationAction = verifyOpenAIConfigurationAction
    self.retryFailedAudioRecoveryAction = retryFailedAudioRecoveryAction
    self.deleteFailedAudioRecoveryAction = deleteFailedAudioRecoveryAction
    self.clearFailedAudioRecoveryAction = clearFailedAudioRecoveryAction
    self.refreshFailedAudioRecoveryAction = refreshFailedAudioRecoveryAction
    self.loadFailedAudioRecoveryReceiptsAction = loadFailedAudioRecoveryReceiptsAction
    self.authorizeWorkflowRunAction = authorizeWorkflowRunAction
    self.authorizeClipboardItemRunAction = authorizeClipboardItemRunAction
    self.explainResolvedWorkflowAction = explainResolvedWorkflowAction
    self.previewClipboardItemAction = previewClipboardItemAction
    self.writeClipboardTextAction = writeClipboardTextAction
    self.pasteTopOfStackAction = pasteTopOfStackAction
    self.refreshPermissionsAction = refreshPermissionsAction
    self.requestAccessibilityAction = requestAccessibilityAction
    self.requestMicrophoneAction = requestMicrophoneAction
    self.openAccessibilitySettingsAction = openAccessibilitySettingsAction
    self.openMicrophoneSettingsAction = openMicrophoneSettingsAction
    synchronizeWorkflowEnabledStates()
    if let deliveryStack {
      Task { [weak self] in
        let snapshot = await deliveryStack.clipboardSnapshot()
        await MainActor.run {
          guard let self, !self.hasReceivedClipboardSnapshot else { return }
          self.applyClipboardStoreSnapshot(snapshot)
        }
      }
    }
    if loadsPersistentSettingsOnInitialization {
      loadSettings()
    } else {
      isLoadingSettings = false
      openAICredentialAvailability = .inaccessible
      if settingsStore == nil {
        unavailableScalarSettingKeys.formUnion(
          ScalarSettingsDomain.clipboard.settingKeys
        )
        applyResolvedClipboardCapturePreference(enabled: false)
      }
      localSpeechSettingsSource.update(currentLocalSpeechSettings())
    }
    loadHistory()
    resetRunHistoryBrowsing()
    loadDiagnostics()
    startListening()
  }

}

struct PendingRunInfo {
  let workflowID: UUID
  let workflow: WorkflowPresentation
  let trigger: WorkflowRunTriggerKind
  let isStackRelated: Bool
}

extension AppModel {
  nonisolated static let sherpaOnnxRecognizerID = "sherpa-onnx.local"
  nonisolated static let sherpaStreamingRecognizerID = "sherpa-onnx.streaming"
  nonisolated static let workflowOriginMetadataKey = "workflow.origin"
  nonisolated static let userWorkflowOriginMetadataValue = "user"
  nonisolated static let workflowCatalogMetadataKey = WorkflowMetadataKey.catalog
  nonisolated static let builtinWorkflowCatalogValue = BuiltinWorkflowRoutingValue.catalog
  nonisolated static let triggerGestureMetadataKey = WorkflowMetadataKey.triggerGesture
  nonisolated static let fnHoldGestureValue = BuiltinWorkflowRoutingValue.pushToTalkGesture
  nonisolated static let defaultHotkeyGesture = "control-option-shift-space"
  nonisolated static let builtinPushToTalkOutputModeMetadataKey = WorkflowMetadataKey
    .settingsExposeOutputMode
  nonisolated static let builtinPushToTalkKindValue = "push-to-talk.dictation"
  nonisolated static let builtinPushToTalkPolishKindValue = "push-to-talk.polish"
  nonisolated static let localSpeechTestWorkflowID = UUID(
    uuidString: "95DA4DD0-38BF-4AE6-AF6E-493FA77E748B"
  )!
}

extension ActionResult {
  func localizedDescription(language: AppLanguage) -> String {
    switch self {
    case .injected:
      return language == .english ? "injected" : "已注入"
    case .copiedToClipboard:
      return language == .english ? "copied to clipboard" : "已复制到剪贴板"
    case .pushedToStack:
      return language == .english ? "pushed to stack" : "已压入栈"
    case .externalOutput(let destination):
      return language == .english
        ? "external output completed (\(destination))" : "外部输出已完成（\(destination)）"
    case .skipped(let reason):
      return language == .english ? "skipped (\(reason))" : "已跳过（\(reason)）"
    case .failed(let reason):
      return language == .english ? "failed (\(reason))" : "失败（\(reason)）"
    }
  }
}
