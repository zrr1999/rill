import Foundation
import Observation
import RillCore
import RillRuntime

@MainActor
@Observable
public final class AppModel {
  static let vocabularyRulesSettingKey = AppSettingsCodec.vocabularyRulesSettingKey
  static let vocabularyLibrarySettingKey = AppSettingsCodec.vocabularyLibrarySettingKey
  static let workflowLibrarySettingKey = AppSettingsCodec.workflowLibrarySettingKey

  static let settingsLoadKeys = AppSettingsCodec.settingsLoadKeys

  static let debouncedStringSettingKeys: Set<AppSettingKey> = [
    .localSpeechModel,
    .ttsModel,
    .openAIAPIKey,
    .openAIBaseURL,
    .openAIModel,
  ]

  static let recognizerIDsRequiringCapturedAudio: Set<String> = [
    localSpeechRecognizerID,
    sherpaOnnxRecognizerID,
    sherpaStreamingRecognizerID,
  ]
  static let productionPostProcessStepKinds: Set<PostProcessStepKind> = [
    .llmRewrite,
    .llmAnswer,
    .normalizeWhitespace,
  ]

  public var workflowConfigurationDirectoryURL: URL? {
    workflowFileStore?.configurationDirectoryURL
  }
  public let localPersistenceStatus: LocalPersistenceStatus
  public internal(set) var selectedSidebarSection: SidebarSection = .records
  public let recordWorkspace: RecordWorkspaceModel
  public let jevPolishing: JevPolishingSettingsModel
  public let history: RunHistoryModel
  public internal(set) var settingsNavigationRequest: SettingsNavigationRequest?
  public var selectedSettingsPane: SettingsPane = .general
  public internal(set) var settingsPresentationGeneration = 0
  var handledSettingsPresentationGeneration = 0
  @ObservationIgnored var copyRecordAction:
    @MainActor (RecordReuseSubject) async -> RecordReuseOutcome = { _ in .blocked }
  internal var workflowEditorNavigationRequest: WorkflowEditorNavigationRequest?
  public private(set) var language: AppLanguage

  public private(set) var systemClipboardCaptureEnabled: Bool

  public internal(set) var clipboardCapturePreferenceRevision: UInt64 = 0
  public private(set) var recordPanelHotkeyBinding: HotkeyBindingDescriptor

  public private(set) var preferredSpeechEngine: PreferredSpeechEngine

  public private(set) var builtinPushToTalkOutputMode: BuiltinPushToTalkOutputMode

  public private(set) var longRecordingModeEnabled: Bool

  public private(set) var recordingDurationLimit: RecordingDurationLimit

  public private(set) var localSpeechModel: String

  public private(set) var localSpeechPrewarm: Bool

  public private(set) var enabledSpeechModelIDs: Set<String>

  public private(set) var residentSpeechModelIDs: Set<String>

  public private(set) var residentSpeechBudgetConfirmation: String?

  public let workflowLibrary: WorkflowLibraryModel
  public let settings: SettingsPersistenceModel
  public var settingsSaveState: SettingsSaveState { settings.saveState }
  public private(set) var openAIAPIKey: String

  public private(set) var openAIBaseURL: String

  public private(set) var openAIModel: String

  public var contextMemory: ContextMemoryModel?
  public let voice = VoiceRunModel()
  public let localSpeechAvailability: LocalSpeechAvailability
  public let localSpeechTrustMaterialAvailable: Bool
  public let trustedLocalSpeechModels: [LocalSpeechModelDescriptor]
  public let defaultLocalSpeechModelIdentifier: String?
  public let localSpeechPhysicalMemoryGiB: Int
  public let ttsModelOptions: [TTSModelOption]
  public let defaultTTSModelIdentifier: String
  public private(set) var ttsModelIdentifier: String

  public var permissionSnapshot: PermissionSnapshot
  public internal(set) var globalInputCapability: GlobalInputCapability = .checking
  public var recordCount: Int {
    recordWorkspace.snapshot.records.count
  }
  public var recordPreview: String? {
    guard let projection = recordWorkspace.snapshot.records.first else { return nil }
    return projection.header.kind == .text ? projection.header.preview : nil
  }
  public internal(set) var systemClipboardCaptureControlSnapshot =
    SystemClipboardCaptureControlSnapshot(
      revision: 0,
      state: .paused
    )
  public var isClipboardCapturePaused: Bool {
    systemClipboardCaptureControlSnapshot.state.isPaused
  }
  public var isIgnoringNextExternalClipboardChange: Bool {
    systemClipboardCaptureControlSnapshot.state.isIgnoringNextExternalChange
  }
  public var isSystemClipboardCaptureControlTransitioning: Bool {
    systemClipboardCaptureControlSnapshot.state.isTransitioning
  }
  public var lastFailure: String?
  public let vocabulary: VocabularyLibraryModel
  public internal(set) var vocabularyRules: [VocabularyRule] {
    get { vocabulary.vocabularyRules }
    set {
      let changed = newValue != vocabulary.vocabularyRules
      vocabulary.setLegacyRules(newValue)
      guard !self.vocabulary.isApplying else { return }
      rebuildWorkflowLibrary()
      if changed { persistVocabularyLibrary() }
    }
  }
  public private(set) var privacyPolicySettings: PrivacyPolicySettings = .defaults

  public internal(set) var isLoadingPrivacySettings = false
  public internal(set) var isSavingPrivacySettings = false
  public internal(set) var privacySettingsLoadError: String?
  public internal(set) var privacySettingsSaveError: String?
  public internal(set) var recordRetentionPeriod: HistoryRetentionPeriod = .defaultPeriod
  public private(set) var runHistoryRetentionPeriod: HistoryRetentionPeriod = .defaultPeriod

  public internal(set) var benchmarkRecordingArchiveEnabled = false
  public internal(set) var isUpdatingBenchmarkRecordingArchive = false
  public var benchmarkRecordingArchiveError: String?
  // The floating panel is driven through `updateLiveSubtitlePanelAction`, not
  // through a SwiftUI view observing AppModel. Keeping its 25 Hz meter state
  // outside Observation prevents every audio frame from invalidating the main
  // application view graph.
  @ObservationIgnored public internal(set) var liveSubtitleSnapshot: LiveSubtitleSnapshot?
  @ObservationIgnored private(set) var currentCaptureLiveSubtitleSnapshot: LiveSubtitleSnapshot?

  var workflowAudioCaptureRunID: UUID?
  var audioProcessingQueueSnapshot: AudioProcessingQueueSnapshot?
  @ObservationIgnored var lastLiveSubtitleMeterRefreshAt: ContinuousClock.Instant?
  @ObservationIgnored var pendingLiveSubtitleMeterSnapshot: LiveSubtitleSnapshot?
  public private(set) var recordHistoryVisibility: RecordHistoryVisibility

  public var enabledManualWorkflows: [WorkflowDefinition] {
    enabledWorkflows(for: .manual)
  }
  public var enabledLongRecordingWorkflows: [WorkflowDefinition] {
    enabledManualWorkflows.filter { requiresCapturedAudioForInteractiveRun($0) }
  }
  public var localSpeechTestWorkflow: WorkflowDefinition? {
    guard
      var workflow = self.workflowLibrary.workflows.first(where: { workflow in
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
      recognizerID: Self.localSpeechRecognizerID
    )
    workflow.plan.output = WorkflowOutputPhase(
      actions: [OutputActionReference(id: "record.store")],
      deliveryPolicy: DeliveryPolicy(strategy: .collectionFirst)
    )
    workflow.metadata.removeValue(forKey: WorkflowMetadataKey.catalog)
    workflow.metadata.removeValue(forKey: WorkflowMetadataKey.triggerGesture)
    workflow.metadata.removeValue(forKey: WorkflowMetadataKey.builtinKind)
    workflow.metadata.removeValue(forKey: WorkflowMetadataKey.exclusiveGroup)
    workflow.metadata.removeValue(forKey: WorkflowMetadataKey.recognizerSelectionMode)
    workflow.metadata[WorkflowMetadataKey.targetRecordCollectionIDs] =
      RecordCollection.voiceInputID.rawValue.uuidString
    workflow.metadata.removeValue(forKey: WorkflowMetadataKey.legacyTargetRecordCollectionID)
    return workflow
  }
  public var enabledTextStyleWorkflows: [WorkflowDefinition] {
    self.workflowLibrary.workflows.filter { workflow in
      isWorkflowEnabled(workflow) && requiresCapturedAudioForInteractiveRun(workflow)
        && VoiceTextStyle.infer(from: workflow) != .custom
    }
  }
  public var canRunAnyManualWorkflow: Bool {
    enabledManualWorkflows.contains(where: canTriggerWorkflow)
  }
  public var canDeliverNextRecord: Bool {
    recordCount > 0 && permissionSnapshot.accessibility == .granted
  }
  public var hasActiveOrQueuedVoiceRun: Bool {
    self.voice.isRunning || (audioProcessingQueueSnapshot?.isVisible ?? false)
  }
  public var isLocalHistoryMaintenanceAvailable: Bool {
    localHistoryMaintenance != nil
  }
  public var canClearRunHistory: Bool {
    !hasActiveOrQueuedVoiceRun && !self.history.isLocalHistoryMaintenanceRunning
      && !self.history.isUpdatingHistoryRetentionSettings
  }
  public var recentVoiceHistoryRecords: [WorkflowResultRecord] {
    self.history.historyRecords.filter(isVoiceHistoryRecord)
  }
  public var recentVoiceResultRecords: [WorkflowResultRecord] {
    recentVoiceHistoryRecords.filter { record in
      record.outcome == .completed
        && !(record.finalText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
  }
  public var localizedWindowTitle: String {
    L10n.text(.appTitle, language: language)
  }
  public var isApplicationShuttingDown: Bool {
    hasBegunApplicationShutdown
  }
  public var localizedMenuBarTitle: String {
    L10n.text(.menuBarLabel, language: language)
  }

  let eventBus: EventBus
  let sessionCoordinator: SessionCoordinator
  let outputActionRegistry: OutputActionRegistry
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
  let liveSubtitleMeterRefreshInterval: Duration = .milliseconds(40)
  var waitForLiveSubtitleMeterRefresh: @Sendable (Duration) async throws -> Void = { duration in
    try await Task.sleep(for: duration)
  }
  let prepareLocalSpeechAction:
    @Sendable (
      LocalSpeechSettings,
      @escaping @Sendable (Progress) -> Void
    ) async throws -> String
  let synchronizeResidentSpeechModelsAction:
    @Sendable (_ added: Set<String>, _ removed: Set<String>) async -> Void
  let prepareEnabledSpeechModelAction: @Sendable (_ modelID: String) async -> Void
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
  let clearBenchmarkRecordingArchiveAction: @Sendable () async throws -> Void
  let refreshBenchmarkRecordingArchiveAction: @Sendable (Bool) async throws -> Void
  let authorizeWorkflowRunAction:
    @Sendable (
      WorkflowDefinition
    ) async throws -> AuthorizedWorkflowRunContext
  let explainResolvedWorkflowAction:
    @Sendable (
      WorkflowResolvedExecutionPlan
    ) async throws -> WorkflowExplanationReceipt
  let writeClipboardTextAction: @MainActor (String) -> Void
  let deliverNextRecordAction: () -> Void
  let refreshPermissionsAction: () -> Void
  let requestAccessibilityAction: () -> Void
  let requestMicrophoneAction: () -> Void
  let openAccessibilitySettingsAction: () -> Void
  let openMicrophoneSettingsAction: () -> Void
  let requestGlobalInputAction: () -> Void
  let retryGlobalInputAction: () -> Void
  var beginRecordPanelShortcutRecordingAction: () -> UUID = { UUID() }
  var endRecordPanelShortcutRecordingAction: (UUID) -> Void = { _ in }
  var commitRecordPanelShortcutRecordingAction: (UUID, UInt16) -> Void = { _, _ in }
  var showRecordPanelAction: () -> Void = {}
  var setSystemClipboardCaptureEnabledAction: (Bool, UInt64) -> Void = { _, _ in }
  var ignoreNextExternalClipboardChangeAction: () -> Void = {}
  let workflowLibraryChangedAction: @MainActor () -> Void
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
  var validateWakeWordConfigurationAction: @Sendable (WakeWordConfiguration) async throws -> Void =
    { _ in
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
  var updateRecordPanelHotkeyAction: (HotkeyBindingDescriptor) -> Void = { _ in }
  var updateLiveSubtitlePanelAction: @MainActor (LiveSubtitleSnapshot?, AppLanguage) -> Void = {
    _, _ in
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
    self.voice.downloadedTTSModelIdentifiers = downloadedTTSModelIdentifiers.intersection(
      Set(ttsModelOptions.map(\.id))
    )
    selectTTSModelAction(ttsModelIdentifier)
    self.voice.ttsResourceState =
      self.voice.downloadedTTSModelIdentifiers.contains(ttsModelIdentifier)
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
    self.voice.wakeWordRuntimeState = state
    if state == .listening {
      self.voice.wakeWordResourceState = .ready
    } else if state == .modelMissing, self.voice.wakeWordResourceState == .ready {
      self.voice.wakeWordResourceState = .notInstalled
    }
  }

  public func updateWakeWordResourceState(_ state: VoiceAssistantResourceState) {
    self.voice.wakeWordResourceState = state
  }

  public func updateSpeechPlaybackState(isActive: Bool) {
    self.voice.isSpeechPlaybackActive = isActive
  }
  var pendingRuns: [UUID: RunSnapshot] { voice.runs }
  var listenerTask: Task<Void, Never>?
  var eventListenerBarrierContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
  var eventListenerShutdownTask: Task<Void, Never>?
  var hasStoppedEventListener = false
  /// Keys changed by the user after the initial snapshot read started but
  /// before it was applied. The older snapshot must not overwrite them.
  var persistenceWrites: PersistenceWriteCoordinator { settings.writes }
  var pendingPrivacySettingsWriteTask: Task<Void, Never>?
  var privacySettingsWriteGeneration = 0
  var pendingLiveSubtitleHideTask: Task<Void, Never>?
  @ObservationIgnored var pendingLiveSubtitleMeterRefreshTask: Task<Void, Never>?
  @ObservationIgnored var liveSubtitleMeterRefreshGeneration = 0
  var clipboardUpdateDebounceTask: Task<Void, Never>?
  private(set) var hasBegunApplicationShutdown = false

  let liveSubtitlePreparingHideDelay: Duration

  public init(
    workflows initialWorkflows: [WorkflowDefinition],
    eventBus: EventBus,
    sessionCoordinator: SessionCoordinator,
    outputActionRegistry: OutputActionRegistry,
    recordWorkspace: RecordWorkspaceModel,
    jevPolishingSettingsSource: JevPolishingSettingsSource,
    candidateResolver: CandidateResolver,
    historyRepository: (any HistoryRepository)?,
    runHistoryBrowser: (any RunHistoryBrowsing)?,
    runReceiptRepository: (any WorkflowRunReceiptRepository)?,
    localHistoryMaintenance: (any LocalHistoryMaintaining)?,
    diagnosticRepository: (any DiagnosticRepository)?,
    settingsStore: (any SettingsStore)?,
    workflowFileStore: (any WorkflowFileStore)?,
    credentialStore: (any SecureCredentialStore)?,
    localPersistenceStatus: LocalPersistenceStatus,
    vocabularyRuleSource: VocabularyRuleSource,
    privacySettingsSource: PrivacyPolicySettingsSource,
    localSpeechSettingsSource: LocalSpeechSettingsSource,
    loadsPersistentSettingsOnInitialization: Bool,
    settingsWriteDebounceDuration: Duration,
    historyRetentionMaintenanceInterval: Duration?,
    liveSubtitlePreparingHideDelay: Duration,
    localSpeechAvailability: LocalSpeechAvailability,
    trustedLocalSpeechModels: [LocalSpeechModelDescriptor],
    defaultLocalSpeechModelIdentifier: String?,
    ttsModelOptions: [TTSModelOption],
    defaultTTSModelIdentifier: String,
    localSpeechPhysicalMemoryGiB: Int,
    prepareLocalSpeechAction:
      @escaping @Sendable (
        LocalSpeechSettings,
        @escaping @Sendable (Progress) -> Void
      ) async throws -> String,
    synchronizeResidentSpeechModelsAction:
      @escaping @Sendable (_ added: Set<String>, _ removed: Set<String>) async -> Void,
    prepareEnabledSpeechModelAction:
      @escaping @Sendable (_ modelID: String) async -> Void,
    setLocalSpeechRuntimeEnabledAction: @escaping @Sendable (Bool) -> Void,
    releaseLocalSpeechRuntimeAction: @escaping @Sendable () -> Void,
    stopLocalSpeechRuntimeAction: @escaping @Sendable () async -> Void,
    startWorkflowAudioRunAction:
      @escaping @Sendable (WorkflowDefinition, TriggerBinding) async throws -> Void,
    finishWorkflowAudioRunAction: @escaping @Sendable () async throws -> Void,
    verifyOpenAIConfigurationAction:
      @escaping @Sendable (OpenAISettings) async throws -> Void,
    retryFailedAudioRecoveryAction:
      @escaping @Sendable (
        UUID,
        WorkflowDefinition
      ) async throws -> FailedAudioRecoveryController.RetryResult,
    deleteFailedAudioRecoveryAction: @escaping @Sendable (UUID) async throws -> Void,
    clearFailedAudioRecoveryAction: @escaping @Sendable () async throws -> Void,
    refreshFailedAudioRecoveryAction: @escaping @Sendable (Bool) async throws -> Void,
    loadFailedAudioRecoveryReceiptsAction:
      @escaping @Sendable () async throws -> [FailedAudioRecoveryReceipt],
    clearBenchmarkRecordingArchiveAction: @escaping @Sendable () async throws -> Void,
    refreshBenchmarkRecordingArchiveAction: @escaping @Sendable (Bool) async throws -> Void,
    authorizeWorkflowRunAction:
      @escaping @Sendable (
        WorkflowDefinition
      ) async throws -> AuthorizedWorkflowRunContext,
    explainResolvedWorkflowAction:
      @escaping @Sendable (
        WorkflowResolvedExecutionPlan
      ) async throws -> WorkflowExplanationReceipt,
    writeClipboardTextAction: @escaping @MainActor (String) -> Void,
    deliverNextRecordAction: @escaping () -> Void,
    permissionSnapshot: PermissionSnapshot,
    language: AppLanguage,
    refreshPermissionsAction: @escaping () -> Void,
    requestAccessibilityAction: @escaping () -> Void,
    requestMicrophoneAction: @escaping () -> Void,
    openAccessibilitySettingsAction: @escaping () -> Void,
    openMicrophoneSettingsAction: @escaping () -> Void,
    requestGlobalInputAction: @escaping () -> Void,
    retryGlobalInputAction: @escaping () -> Void,
    workflowLibraryChangedAction: @escaping @MainActor () -> Void
  ) {
    self.requestGlobalInputAction = requestGlobalInputAction
    self.retryGlobalInputAction = retryGlobalInputAction
    self.workflowLibraryChangedAction = workflowLibraryChangedAction
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
    let declaredLocalSpeechAvailability = localSpeechAvailability
    let effectiveLocalSpeechAvailability: LocalSpeechAvailability
    if declaredLocalSpeechAvailability.isAvailable {
      effectiveLocalSpeechAvailability =
        catalogIsValid
        ? .available
        : .trustMaterialUnavailable
    } else {
      effectiveLocalSpeechAvailability = declaredLocalSpeechAvailability
    }
    let exposesTrustedCatalog = effectiveLocalSpeechAvailability.isAvailable && catalogIsValid
    self.workflowLibrary = WorkflowLibraryModel(workflows: initialWorkflows)
    self.language = language
    // Capture remains closed until durable settings prove it is enabled.
    // Test and preview compositions that explicitly skip loading retain the
    // historical enabled behavior when they still provide a settings store.
    self.systemClipboardCaptureEnabled =
      settingsStore != nil && !loadsPersistentSettingsOnInitialization
    self.recordHistoryVisibility = .remainingOnly
    self.recordPanelHotkeyBinding = .doubleCommand
    self.preferredSpeechEngine = .local
    self.builtinPushToTalkOutputMode = .pasteIntoApp
    self.longRecordingModeEnabled = false
    self.recordingDurationLimit = .fiveMinutes
    self.localSpeechModel = defaultLocalSpeechModelIdentifier ?? LocalSpeechSettings().model
    let resolvedDefaultTTSModelIdentifier =
      ttsModelOptions.contains(where: { $0.id == defaultTTSModelIdentifier })
      ? defaultTTSModelIdentifier
      : (ttsModelOptions.first(where: \.isDefault)?.id ?? ttsModelOptions.first?.id ?? "")
    self.ttsModelOptions = ttsModelOptions
    self.defaultTTSModelIdentifier = resolvedDefaultTTSModelIdentifier
    self.ttsModelIdentifier = resolvedDefaultTTSModelIdentifier
    self.localSpeechPrewarm = LocalSpeechSettings().prewarm
    let availableSpeechModelIDs = Set(trustedLocalSpeechModels.map(\.id))
      .union(ttsModelOptions.map(\.id))
    let defaultEnabledSpeechModelIDs = LocalSpeechSettings().enabledModelIDs
      .intersection(availableSpeechModelIDs)
    let resolvedEnabledSpeechModelIDs =
      defaultEnabledSpeechModelIDs.isEmpty
      ? Set([resolvedDefaultTTSModelIdentifier].filter { !$0.isEmpty })
      : defaultEnabledSpeechModelIDs
    self.enabledSpeechModelIDs = resolvedEnabledSpeechModelIDs
    self.residentSpeechModelIDs = LocalSpeechSettings().residentModelIDs
      .intersection(resolvedEnabledSpeechModelIDs)
    self.residentSpeechBudgetConfirmation = nil
    self.openAIAPIKey = ""
    self.openAIBaseURL = OpenAISettings().baseURL
    self.openAIModel = OpenAISettings().model
    self.permissionSnapshot = permissionSnapshot
    self.eventBus = eventBus
    self.sessionCoordinator = sessionCoordinator
    self.outputActionRegistry = outputActionRegistry
    self.recordWorkspace = recordWorkspace
    self.jevPolishing = JevPolishingSettingsModel(source: jevPolishingSettingsSource)
    self.candidateResolver = candidateResolver
    self.historyRepository = historyRepository
    self.runHistoryBrowser = runHistoryBrowser
    self.history = RunHistoryModel(browser: runHistoryBrowser, workflows: self.workflowLibrary)
    self.runReceiptRepository = runReceiptRepository
    self.localHistoryMaintenance = localHistoryMaintenance
    self.diagnosticRepository = diagnosticRepository
    self.settingsStore = settingsStore
    let settings = SettingsPersistenceModel(store: settingsStore)
    self.settings = settings
    self.vocabulary = VocabularyLibraryModel(settings: settings, source: vocabularyRuleSource)
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
    self.prepareLocalSpeechAction = prepareLocalSpeechAction
    self.synchronizeResidentSpeechModelsAction = synchronizeResidentSpeechModelsAction
    self.prepareEnabledSpeechModelAction = prepareEnabledSpeechModelAction
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
    self.clearBenchmarkRecordingArchiveAction = clearBenchmarkRecordingArchiveAction
    self.refreshBenchmarkRecordingArchiveAction = refreshBenchmarkRecordingArchiveAction
    self.authorizeWorkflowRunAction = authorizeWorkflowRunAction
    self.explainResolvedWorkflowAction = explainResolvedWorkflowAction
    self.writeClipboardTextAction = writeClipboardTextAction
    self.deliverNextRecordAction = deliverNextRecordAction
    self.refreshPermissionsAction = refreshPermissionsAction
    self.requestAccessibilityAction = requestAccessibilityAction
    self.requestMicrophoneAction = requestMicrophoneAction
    self.openAccessibilitySettingsAction = openAccessibilitySettingsAction
    self.openMicrophoneSettingsAction = openMicrophoneSettingsAction
    synchronizeWorkflowEnabledStates()
    if loadsPersistentSettingsOnInitialization {
      loadSettings()
    } else {
      self.settings.isLoading = false
      self.settings.openAICredentialAvailability = .inaccessible
      if settingsStore == nil {
        self.settings.unavailableScalarSettingKeys.formUnion(
          ScalarSettingsDomain.systemClipboard.settingKeys
        )
        applyResolvedClipboardCapturePreference(enabled: false)
      }
      localSpeechSettingsSource.update(currentLocalSpeechSettings())
    }
    loadHistory()
    history.resetRunHistoryBrowsing()
    loadDiagnostics()
    startListening()
  }

}

extension AppModel {
  nonisolated static let localSpeechRecognizerID = AppSettingsCodec.localSpeechRecognizerID
  nonisolated static let sherpaOnnxRecognizerID = AppSettingsCodec.sherpaOnnxRecognizerID
  nonisolated static let sherpaStreamingRecognizerID = AppSettingsCodec.sherpaStreamingRecognizerID
  nonisolated static let workflowOriginMetadataKey = AppSettingsCodec.workflowOriginMetadataKey
  nonisolated static let userWorkflowOriginMetadataValue = AppSettingsCodec
    .userWorkflowOriginMetadataValue
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
      return L10n.runText(.runActionInjected, language: language)
    case .copiedToClipboard:
      return L10n.runText(.runActionCopiedToClipboard, language: language)
    case .storedRecord:
      return L10n.runText(.runActionStoredRecord, language: language)
    case .externalOutput(let destination):
      return String(
        format: L10n.runText(.runActionExternalOutputFormat, language: language),
        destination
      )
    case .skipped(let reason):
      return String(format: L10n.runText(.runActionSkippedFormat, language: language), reason)
    case .failed(let reason):
      return String(format: L10n.runText(.runActionFailedFormat, language: language), reason)
    }
  }
}

extension AppModel {
  func applyLanguage(_ newValue: AppLanguage) {
    let oldValue = language
    language = newValue
    handleLanguageChange(from: oldValue)
  }

  func applySystemClipboardCaptureEnabled(_ newValue: Bool) {
    let oldValue = systemClipboardCaptureEnabled
    systemClipboardCaptureEnabled = newValue
    handleClipboardCaptureEnabledChange(from: oldValue)
  }

  func applyRecordPanelHotkeyBinding(_ newValue: HotkeyBindingDescriptor) {
    let oldValue = recordPanelHotkeyBinding
    recordPanelHotkeyBinding = newValue
    handleRecordPanelHotkeyChange(from: oldValue)
  }

  func applyPreferredSpeechEngine(_ newValue: PreferredSpeechEngine) {
    let oldValue = preferredSpeechEngine
    preferredSpeechEngine = newValue
    handlePreferredSpeechEngineChange(from: oldValue)
  }

  func applyBuiltinPushToTalkOutputMode(_ newValue: BuiltinPushToTalkOutputMode) {
    let oldValue = builtinPushToTalkOutputMode
    builtinPushToTalkOutputMode = newValue
    handleBuiltinPushToTalkOutputModeChange(from: oldValue)
  }

  func applyLongRecordingModeEnabled(_ newValue: Bool) {
    let oldValue = longRecordingModeEnabled
    longRecordingModeEnabled = newValue
    handleLongRecordingModeChange(from: oldValue)
  }

  func applyRecordingDurationLimit(_ newValue: RecordingDurationLimit) {
    let oldValue = recordingDurationLimit
    recordingDurationLimit = newValue
    handleRecordingDurationLimitChange(from: oldValue)
  }

  func applyLocalSpeechModel(_ newValue: String) {
    let oldValue = localSpeechModel
    localSpeechModel = newValue
    handleLocalSpeechModelChange(from: oldValue)
  }

  func applyLocalSpeechPrewarm(_ newValue: Bool) {
    let oldValue = localSpeechPrewarm
    localSpeechPrewarm = newValue
    handleLocalSpeechPrewarmChange(from: oldValue)
  }

  func applyEnabledSpeechModelIDs(_ newValue: Set<String>) {
    let oldValue = enabledSpeechModelIDs
    enabledSpeechModelIDs = newValue
    handleEnabledSpeechModelIDsChange(from: oldValue)
  }

  func applyResidentSpeechModelIDs(_ newValue: Set<String>) {
    let oldValue = residentSpeechModelIDs
    residentSpeechModelIDs = newValue
    handleResidentSpeechModelIDsChange(from: oldValue)
  }

  func applyResidentSpeechBudgetConfirmation(_ newValue: String?) {
    let oldValue = residentSpeechBudgetConfirmation
    residentSpeechBudgetConfirmation = newValue
    handleResidentSpeechBudgetConfirmationChange(from: oldValue)
  }

  func applyOpenAIAPIKey(_ newValue: String) {
    let oldValue = openAIAPIKey
    openAIAPIKey = newValue
    if !self.settings.isLoading, oldValue != openAIAPIKey {
      contextMemory?.invalidateAuthorization()
    }
    handleOpenAIAPIKeyChange(from: oldValue)
  }

  func applyOpenAIBaseURL(_ newValue: String) {
    let oldValue = openAIBaseURL
    openAIBaseURL = newValue
    if !self.settings.isLoading, oldValue != openAIBaseURL {
      contextMemory?.invalidateAuthorization()
    }
    handleOpenAIBaseURLChange(from: oldValue)
  }

  func applyOpenAIModel(_ newValue: String) {
    let oldValue = openAIModel
    openAIModel = newValue
    if !self.settings.isLoading, oldValue != openAIModel {
      contextMemory?.invalidateAuthorization()
    }
    handleOpenAIModelChange(from: oldValue)
  }

  func applyTTSModelIdentifier(_ newValue: String) {
    let oldValue = ttsModelIdentifier
    ttsModelIdentifier = newValue
    handleTTSModelIdentifierChange(from: oldValue)
  }

  func applyPrivacyPolicySettings(_ newValue: PrivacyPolicySettings) {
    let oldValue = privacyPolicySettings
    privacyPolicySettings = newValue
    guard oldValue != privacyPolicySettings else { return }
    if !isLoadingPrivacySettings { contextMemory?.invalidateAuthorization() }
    invalidateWorkflowExplanation()
    history.previewMode = privacyPolicySettings.historyPreviewMode
    if oldValue.historyPreviewMode != privacyPolicySettings.historyPreviewMode {
      history.resetRunHistoryBrowsingForPrivacyChange()
    }
    if !isLoadingPrivacySettings, privacySettingsLoadError == nil {
      privacySettingsSource.update(privacyPolicySettings)
    }
    persistPrivacyPolicySettings()
  }

  func applyRunHistoryRetentionPeriod(_ newValue: HistoryRetentionPeriod) {
    let oldValue = runHistoryRetentionPeriod
    runHistoryRetentionPeriod = newValue
    history.runHistoryRetentionPeriod = runHistoryRetentionPeriod
    guard oldValue != runHistoryRetentionPeriod else { return }
    history.resetRunHistoryBrowsing()
  }

  func applyCurrentCaptureLiveSubtitleSnapshot(_ newValue: LiveSubtitleSnapshot?) {
    let oldValue = currentCaptureLiveSubtitleSnapshot
    currentCaptureLiveSubtitleSnapshot = newValue
    guard
      hasLiveSubtitleSemanticChange(
        from: oldValue,
        to: currentCaptureLiveSubtitleSnapshot
      )
    else { return }
    cancelPendingLiveSubtitleMeterRefresh()
  }

  func applyRecordHistoryVisibility(_ newValue: RecordHistoryVisibility) {
    let oldValue = recordHistoryVisibility
    recordHistoryVisibility = newValue
    guard oldValue != recordHistoryVisibility else { return }
    persistRecordHistoryVisibilityPreference()
  }

  func beginApplicationShutdown() {
    let oldValue = hasBegunApplicationShutdown
    hasBegunApplicationShutdown = true
    guard hasBegunApplicationShutdown, !oldValue else { return }
    history.hasBegunApplicationShutdown = true
    cancelPendingLiveSubtitleMeterRefresh()
  }
}
