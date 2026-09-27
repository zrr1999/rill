import Foundation
import Observation
import RillCore
import RillWorkflows
import RillRecords
import RillKnowledge
import RillSpeech

@MainActor
@Observable
public final class AppModel {
  public var inputMethod: InputMethodFeatureModel?
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
  public internal(set) var comparisonReturn: RecordComparisonReturn?
  @ObservationIgnored var resumeComparisonAction: (@MainActor (RecordComparisonReturn) -> Void)?
  public let history: RunHistoryModel
  public internal(set) var settingsNavigationRequest: SettingsNavigationRequest?
  public var selectedSettingsPane: SettingsPane = .general
  public internal(set) var settingsPresentationGeneration = 0
  var handledSettingsPresentationGeneration = 0
  let recordInteractions: RecordInteractionServices
  internal var workflowEditorNavigationRequest: WorkflowEditorNavigationRequest?

  public internal(set) var clipboardCapturePreferenceRevision: UInt64 = 0

  public let workflowLibrary: WorkflowLibraryModel
  public let settings: SettingsPersistenceModel
  public var settingsSaveState: SettingsSaveState { settings.saveState }

  public var contextMemory: ContextMemoryModel?
  public let voice: VoiceRunModel
  public let localSpeechAvailability: LocalSpeechAvailability
  public let localSpeechTrustMaterialAvailable: Bool
  public let trustedLocalSpeechModels: [LocalSpeechModelDescriptor]
  public let defaultLocalSpeechModelIdentifier: String?
  public let localSpeechPhysicalMemoryGiB: Int
  public let ttsModelOptions: [TTSModelOption]
  public let defaultTTSModelIdentifier: String

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
  public internal(set) var recordRetentionPeriod: HistoryRetentionPeriod = .defaultPeriod

  public let benchmarkArchive: BenchmarkRecordingArchiveModel
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
    self.voice.isRunning || (voice.audioProcessingQueueSnapshot?.isVisible ?? false)
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
    L10n.text(.appTitle, language: self.settings.language)
  }
  public var isApplicationShuttingDown: Bool {
    hasBegunApplicationShutdown
  }
  public var localizedMenuBarTitle: String {
    L10n.text(.menuBarLabel, language: self.settings.language)
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
  let synchronizeResidentSpeechModelsAction:
    @Sendable (_ added: Set<String>, _ removed: Set<String>) async -> Void
  let prepareEnabledSpeechModelAction: @Sendable (_ modelID: String) async -> Void
  let setLocalSpeechRuntimeEnabledAction: @Sendable (Bool) -> Void
  let startWorkflowAudioRunAction:
    @Sendable (WorkflowDefinition, TriggerBinding) async throws -> Void
  let finishWorkflowAudioRunAction: @Sendable () async throws -> Void
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
  let writeClipboardTextAction: @MainActor (String) -> Void
  let deliverNextRecordAction: () -> Void
  let refreshPermissionsAction: () -> Void
  let requestAccessibilityAction: () -> Void
  let requestMicrophoneAction: () -> Void
  let openAccessibilitySettingsAction: () -> Void
  let openMicrophoneSettingsAction: () -> Void
  let requestGlobalInputAction: () -> Void
  let retryGlobalInputAction: () -> Void
  var showRecordPanelAction: (() -> Void)?
  let workflowLibraryChangedAction: @MainActor () -> Void

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
  var persistenceWrites: PersistenceWriteCoordinator { settings.writes }
  var clipboardUpdateDebounceTask: Task<Void, Never>?
  private(set) var hasBegunApplicationShutdown = false


  public init(
    workflows initialWorkflows: [WorkflowDefinition],
    eventBus: EventBus,
    sessionCoordinator: SessionCoordinator,
    outputActionRegistry: OutputActionRegistry,
    recordWorkspace: RecordWorkspaceModel,
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
    historyMaintenanceSleep: @escaping @Sendable (Duration) async throws -> Void,
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
    benchmarkArchiveReader: (any BenchmarkRecordingArchiveReading)?,
    benchmarkCorpusExporter: (any BenchmarkCorpusExporting)?,
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
    workflowLibraryChangedAction: @escaping @MainActor () -> Void,
    voiceResourceServices: VoiceResourceServices,
    recordInteractionServices: RecordInteractionServices
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
    let settings = SettingsPersistenceModel(store: settingsStore, language: language,
      verifyOpenAIConfiguration: verifyOpenAIConfigurationAction,
      configurationChanged: workflowLibraryChangedAction)
    self.settings = settings
    self.workflowLibrary = WorkflowLibraryModel(workflows: initialWorkflows,
      settings: settings, explain: explainResolvedWorkflowAction)
    // Capture remains closed until durable settings prove it is enabled.
    // Test and preview compositions that explicitly skip loading retain the
    // historical enabled behavior when they still provide a settings store.
    settings.systemClipboardCaptureEnabled =
      settingsStore != nil && !loadsPersistentSettingsOnInitialization
    settings.localSpeechModel = defaultLocalSpeechModelIdentifier ?? LocalSpeechSettings().model
    let resolvedDefaultTTSModelIdentifier =
      ttsModelOptions.contains(where: { $0.id == defaultTTSModelIdentifier })
      ? defaultTTSModelIdentifier
      : (ttsModelOptions.first(where: \.isDefault)?.id ?? ttsModelOptions.first?.id ?? "")
    self.ttsModelOptions = ttsModelOptions
    self.defaultTTSModelIdentifier = resolvedDefaultTTSModelIdentifier
    settings.ttsModelIdentifier = resolvedDefaultTTSModelIdentifier
    let availableSpeechModelIDs = Set(trustedLocalSpeechModels.map(\.id))
      .union(ttsModelOptions.map(\.id))
    let defaultEnabledSpeechModelIDs = LocalSpeechSettings().enabledModelIDs
      .intersection(availableSpeechModelIDs)
    let resolvedEnabledSpeechModelIDs =
      defaultEnabledSpeechModelIDs.isEmpty
      ? Set([resolvedDefaultTTSModelIdentifier].filter { !$0.isEmpty })
      : defaultEnabledSpeechModelIDs
    settings.enabledSpeechModelIDs = resolvedEnabledSpeechModelIDs
    settings.residentSpeechModelIDs = LocalSpeechSettings().residentModelIDs
      .intersection(resolvedEnabledSpeechModelIDs)
    self.permissionSnapshot = permissionSnapshot
    self.eventBus = eventBus
    self.sessionCoordinator = sessionCoordinator
    self.outputActionRegistry = outputActionRegistry
    self.recordWorkspace = recordWorkspace
    self.recordInteractions = recordInteractionServices
    self.candidateResolver = candidateResolver
    self.historyRepository = historyRepository
    self.runHistoryBrowser = runHistoryBrowser
    self.history = RunHistoryModel(browser: runHistoryBrowser, workflows: self.workflowLibrary, maintenanceSleep: historyMaintenanceSleep)
    self.voice = VoiceRunModel(settings: settings, resources: voiceResourceServices,
      supportedTTSModelIDs: Set(ttsModelOptions.map(\.id)),
      liveSubtitlePreparingHideDelay: liveSubtitlePreparingHideDelay,
      resourceAvailabilityChanged: workflowLibraryChangedAction,
      prepareLocalSpeech: prepareLocalSpeechAction,
      releaseLocalSpeech: releaseLocalSpeechRuntimeAction,
      stopLocalSpeech: stopLocalSpeechRuntimeAction,
      appendEvent: { [history] in history.append($0) })
    self.runReceiptRepository = runReceiptRepository
    self.localHistoryMaintenance = localHistoryMaintenance
    self.diagnosticRepository = diagnosticRepository
    self.settingsStore = settingsStore
    self.vocabulary = VocabularyLibraryModel(settings: settings, source: vocabularyRuleSource,
      didChange: { [workflowLibrary] bindings in
        workflowLibrary.cancelWorkflowExplanation()
        workflowLibrary.rebuild(defaultVocabularyBindings: bindings)
        workflowLibraryChangedAction()
      }, saveFailed: { [history] in
        history.append(EventFeedEntry(
          english: L10n.runText(.settingsSaveFailedRetry, language: .english),
          simplifiedChinese: L10n.runText(.settingsSaveFailedRetry, language: .simplifiedChinese)))
      })
    self.workflowFileStore = workflowFileStore
    self.credentialStore = credentialStore
    self.localPersistenceStatus = localPersistenceStatus
    self.vocabularyRuleSource = vocabularyRuleSource
    self.privacySettingsSource = privacySettingsSource
    self.localSpeechSettingsSource = localSpeechSettingsSource
    self.settings.isLoadingPrivacySettings = !privacySettingsSource.hasAvailableSettings
    self.settingsWriteDebounceDuration = settingsWriteDebounceDuration
    self.historyRetentionMaintenanceInterval = historyRetentionMaintenanceInterval
    self.localSpeechAvailability = effectiveLocalSpeechAvailability
    self.localSpeechTrustMaterialAvailable = effectiveLocalSpeechAvailability.isAvailable
    self.trustedLocalSpeechModels = exposesTrustedCatalog ? trustedLocalSpeechModels : []
    self.defaultLocalSpeechModelIdentifier =
      exposesTrustedCatalog
      ? defaultLocalSpeechModelIdentifier
      : nil
    self.localSpeechPhysicalMemoryGiB = max(1, localSpeechPhysicalMemoryGiB)
    self.synchronizeResidentSpeechModelsAction = synchronizeResidentSpeechModelsAction
    self.prepareEnabledSpeechModelAction = prepareEnabledSpeechModelAction
    self.setLocalSpeechRuntimeEnabledAction = setLocalSpeechRuntimeEnabledAction
    self.startWorkflowAudioRunAction = startWorkflowAudioRunAction
    self.finishWorkflowAudioRunAction = finishWorkflowAudioRunAction
    self.retryFailedAudioRecoveryAction = retryFailedAudioRecoveryAction
    self.deleteFailedAudioRecoveryAction = deleteFailedAudioRecoveryAction
    self.clearFailedAudioRecoveryAction = clearFailedAudioRecoveryAction
    self.refreshFailedAudioRecoveryAction = refreshFailedAudioRecoveryAction
    self.loadFailedAudioRecoveryReceiptsAction = loadFailedAudioRecoveryReceiptsAction
    self.benchmarkArchive = BenchmarkRecordingArchiveModel(settings: settings, store: settingsStore,
      reader: benchmarkArchiveReader, exporter: benchmarkCorpusExporter,
      refresh: refreshBenchmarkRecordingArchiveAction, clear: clearBenchmarkRecordingArchiveAction)
    self.authorizeWorkflowRunAction = authorizeWorkflowRunAction
    self.writeClipboardTextAction = writeClipboardTextAction
    self.deliverNextRecordAction = deliverNextRecordAction
    self.refreshPermissionsAction = refreshPermissionsAction
    self.requestAccessibilityAction = requestAccessibilityAction
    self.requestMicrophoneAction = requestMicrophoneAction
    self.openAccessibilitySettingsAction = openAccessibilitySettingsAction
    self.openMicrophoneSettingsAction = openMicrophoneSettingsAction
    recordInteractions.setCaptureEnabled(settings.systemClipboardCaptureEnabled, clipboardCapturePreferenceRevision)
    recordInteractions.updateHotkey(settings.recordPanelHotkeyBinding)
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
    let oldValue = self.settings.language
    self.settings.language = newValue
    handleLanguageChange(from: oldValue)
  }

  func applySystemClipboardCaptureEnabled(_ newValue: Bool) {
    let oldValue = self.settings.systemClipboardCaptureEnabled
    self.settings.systemClipboardCaptureEnabled = newValue
    handleClipboardCaptureEnabledChange(from: oldValue)
  }

  func applyRecordPanelHotkeyBinding(_ newValue: HotkeyBindingDescriptor) {
    let oldValue = self.settings.recordPanelHotkeyBinding
    self.settings.recordPanelHotkeyBinding = newValue
    handleRecordPanelHotkeyChange(from: oldValue)
  }

  func applyPreferredSpeechEngine(_ newValue: PreferredSpeechEngine) {
    let oldValue = self.settings.preferredSpeechEngine
    self.settings.preferredSpeechEngine = newValue
    handlePreferredSpeechEngineChange(from: oldValue)
  }

  func applyBuiltinPushToTalkOutputMode(_ newValue: BuiltinPushToTalkOutputMode) {
    let oldValue = self.settings.builtinPushToTalkOutputMode
    self.settings.builtinPushToTalkOutputMode = newValue
    handleBuiltinPushToTalkOutputModeChange(from: oldValue)
  }

  func applyLongRecordingModeEnabled(_ newValue: Bool) {
    let oldValue = self.settings.longRecordingModeEnabled
    self.settings.longRecordingModeEnabled = newValue
    handleLongRecordingModeChange(from: oldValue)
  }

  func applyRecordingDurationLimit(_ newValue: RecordingDurationLimit) {
    let oldValue = self.settings.recordingDurationLimit
    self.settings.recordingDurationLimit = newValue
    handleRecordingDurationLimitChange(from: oldValue)
  }

  func applyLocalSpeechModel(_ newValue: String) {
    let oldValue = self.settings.localSpeechModel
    self.settings.localSpeechModel = newValue
    handleLocalSpeechModelChange(from: oldValue)
  }

  func applyLocalSpeechPrewarm(_ newValue: Bool) {
    let oldValue = self.settings.localSpeechPrewarm
    self.settings.localSpeechPrewarm = newValue
    handleLocalSpeechPrewarmChange(from: oldValue)
  }

  func applyEnabledSpeechModelIDs(_ newValue: Set<String>) {
    let oldValue = self.settings.enabledSpeechModelIDs
    self.settings.enabledSpeechModelIDs = newValue
    handleEnabledSpeechModelIDsChange(from: oldValue)
  }

  func applyResidentSpeechModelIDs(_ newValue: Set<String>) {
    let oldValue = self.settings.residentSpeechModelIDs
    self.settings.residentSpeechModelIDs = newValue
    handleResidentSpeechModelIDsChange(from: oldValue)
  }

  func applyResidentSpeechBudgetConfirmation(_ newValue: String?) {
    let oldValue = self.settings.residentSpeechBudgetConfirmation
    self.settings.residentSpeechBudgetConfirmation = newValue
    handleResidentSpeechBudgetConfirmationChange(from: oldValue)
  }

  func applyOpenAIAPIKey(_ newValue: String) {
    let oldValue = self.settings.openAIAPIKey
    self.settings.openAIAPIKey = newValue
    if !self.settings.isLoading, oldValue != self.settings.openAIAPIKey {
      contextMemory?.invalidateAuthorization()
    }
    handleOpenAIAPIKeyChange(from: oldValue)
  }

  func applyOpenAIBaseURL(_ newValue: String) {
    let oldValue = self.settings.openAIBaseURL
    self.settings.openAIBaseURL = newValue
    if !self.settings.isLoading, oldValue != self.settings.openAIBaseURL {
      contextMemory?.invalidateAuthorization()
    }
    handleOpenAIBaseURLChange(from: oldValue)
  }

  func applyOpenAIModel(_ newValue: String) {
    let oldValue = self.settings.openAIModel
    self.settings.openAIModel = newValue
    if !self.settings.isLoading, oldValue != self.settings.openAIModel {
      contextMemory?.invalidateAuthorization()
    }
    handleOpenAIModelChange(from: oldValue)
  }

  func applyTTSModelIdentifier(_ newValue: String) {
    let oldValue = self.settings.ttsModelIdentifier
    self.settings.ttsModelIdentifier = newValue
    handleTTSModelIdentifierChange(from: oldValue)
  }

  func applyPrivacyPolicySettings(_ newValue: PrivacyPolicySettings) {
    let oldValue = self.settings.privacyPolicySettings
    self.settings.privacyPolicySettings = newValue
    guard oldValue != self.settings.privacyPolicySettings else { return }
    if !self.settings.isLoadingPrivacySettings { contextMemory?.invalidateAuthorization() }
    workflowLibrary.cancelWorkflowExplanation()
    history.previewMode = self.settings.privacyPolicySettings.historyPreviewMode
    if oldValue.historyPreviewMode != self.settings.privacyPolicySettings.historyPreviewMode {
      history.resetRunHistoryBrowsingForPrivacyChange()
    }
    if !self.settings.isLoadingPrivacySettings, self.settings.privacySettingsLoadError == nil {
      privacySettingsSource.update(self.settings.privacyPolicySettings)
    }
    persistPrivacyPolicySettings()
  }

  func applyRecordHistoryVisibility(_ newValue: RecordHistoryVisibility) {
    let oldValue = self.settings.recordHistoryVisibility
    self.settings.recordHistoryVisibility = newValue
    guard oldValue != self.settings.recordHistoryVisibility else { return }
    persistRecordHistoryVisibilityPreference()
  }

  func beginApplicationShutdown() {
    let oldValue = hasBegunApplicationShutdown
    hasBegunApplicationShutdown = true
    guard hasBegunApplicationShutdown, !oldValue else { return }
    history.hasBegunApplicationShutdown = true
    benchmarkArchive.beginShutdown()
    settings.beginShutdown()
    voice.stopResourcePreparationForApplicationShutdown()
    workflowLibrary.cancelWorkflowExplanation()
    voice.stopPresentationForApplicationShutdown()
  }
}
