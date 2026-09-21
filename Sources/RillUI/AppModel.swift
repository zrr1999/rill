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

public enum RecordHistoryVisibility: String, CaseIterable, Identifiable, Sendable, Equatable {
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

@MainActor
final class WorkflowExplanationTaskOwner {
  private var currentTaskID: UUID?
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []

  func replace(id: UUID, with task: Task<Void, Never>) {
    if let currentTaskID {
      tasks[currentTaskID]?.cancel()
    }
    tasks[id] = task
    currentTaskID = id
  }

  func finish(id: UUID) {
    tasks.removeValue(forKey: id)
    if currentTaskID == id {
      currentTaskID = nil
    }
    guard tasks.isEmpty else { return }
    let waiters = idleWaiters
    idleWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  func cancel() {
    guard let currentTaskID else { return }
    tasks[currentTaskID]?.cancel()
    self.currentTaskID = nil
  }

  func waitUntilIdle() async {
    guard !tasks.isEmpty else { return }
    await withCheckedContinuation { continuation in
      idleWaiters.append(continuation)
    }
  }

  deinit {
    for task in tasks.values {
      task.cancel()
    }
    for waiter in idleWaiters {
      waiter.resume()
    }
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
    .normalizeWhitespace
  ]

  public internal(set) var builtInWorkflows: [WorkflowDefinition] {
    get { workflowLibrary.builtInWorkflows }
    set { workflowLibrary.builtInWorkflows = newValue }
  }
  public internal(set) var customWorkflows: [WorkflowDefinition] {
    get { workflowLibrary.customWorkflows }
    set { workflowLibrary.customWorkflows = newValue }
  }
  public internal(set) var workflows: [WorkflowDefinition] {
    get { workflowLibrary.workflows }
    set { workflowLibrary.workflows = newValue }
  }
  public internal(set) var workflowLibraryAvailability: StoredSettingsDomainAvailability {
    get { workflowLibrary.workflowLibraryAvailability }
    set { workflowLibrary.workflowLibraryAvailability = newValue }
  }
  public internal(set) var workflowTriggerConflicts: [WorkflowTriggerConflict] {
    get { workflowLibrary.workflowTriggerConflicts }
    set { workflowLibrary.workflowTriggerConflicts = newValue }
  }
  public internal(set) var workflowConflictIDsByWorkflowID: [UUID: [UUID]] {
    get { workflowLibrary.workflowConflictIDsByWorkflowID }
    set { workflowLibrary.workflowConflictIDsByWorkflowID = newValue }
  }
  public var workflowConfigurationDirectoryURL: URL? {
    workflowFileStore?.configurationDirectoryURL
  }
  public let localPersistenceStatus: LocalPersistenceStatus
  public internal(set) var selectedSidebarSection: SidebarSection = .records
  public let recordWorkspace: RecordWorkspaceModel
  public let history: RunHistoryModel
  public var runHistoryScope: RunHistoryScope {
    get { history.runHistoryScope }
    set { history.runHistoryScope = newValue }
  }
  public internal(set) var settingsNavigationRequest: SettingsNavigationRequest?
  public var selectedSettingsPane: SettingsPane = .general
  public internal(set) var settingsPresentationGeneration = 0
  var handledSettingsPresentationGeneration = 0
  @ObservationIgnored var copyRecordAction: @MainActor (RecordReuseSubject) async -> RecordReuseOutcome = { _ in .blocked }
  internal var historyNavigationRequest: HistoryNavigationRequest? {
    get { history.historyNavigationRequest }
    set { history.historyNavigationRequest = newValue }
  }
  internal var workflowEditorNavigationRequest: WorkflowEditorNavigationRequest?
  public var language: AppLanguage { didSet { handleLanguageChange(from: oldValue) } }
  public var systemClipboardCaptureEnabled: Bool {
    didSet { handleClipboardCaptureEnabledChange(from: oldValue) }
  }
  public internal(set) var clipboardCapturePreferenceRevision: UInt64 = 0
  public var recordPanelHotkeyBinding: HotkeyBindingDescriptor {
    didSet { handleRecordPanelHotkeyChange(from: oldValue) }
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
  public var localSpeechModel: String { didSet { handleLocalSpeechModelChange(from: oldValue) } }
  public var localSpeechPrewarm: Bool { didSet { handleLocalSpeechPrewarmChange(from: oldValue) } }
  public var enabledSpeechModelIDs: Set<String> {
    didSet { handleEnabledSpeechModelIDsChange(from: oldValue) }
  }
  public var residentSpeechModelIDs: Set<String> {
    didSet { handleResidentSpeechModelIDsChange(from: oldValue) }
  }
  public var residentSpeechBudgetConfirmation: String? {
    didSet { handleResidentSpeechBudgetConfirmationChange(from: oldValue) }
  }
  public internal(set) var measuredSpeechModelPeakByteCounts: [String: UInt64] = [:]
  public internal(set) var pendingResidentSpeechModelIDs: Set<String>?
  public internal(set) var speechModelPoolDegradedByMemoryPressure = false
  public let workflowLibrary: WorkflowLibraryModel
  public let settings: SettingsPersistenceModel
  public var settingsSaveState: SettingsSaveState { settings.saveState }
  public internal(set) var unavailableScalarSettingKeys: Set<AppSettingKey> = []
  public internal(set) var retryingUnavailableScalarSettingsDomains: Set<ScalarSettingsDomain> = []
  public var openAIAPIKey: String { didSet {
      if !isLoadingSettings, oldValue != openAIAPIKey { contextMemory?.invalidateAuthorization() }
      handleOpenAIAPIKeyChange(from: oldValue)
    } }
  public var openAIBaseURL: String {
    didSet {
      if !isLoadingSettings, oldValue != openAIBaseURL { contextMemory?.invalidateAuthorization() }
      handleOpenAIBaseURLChange(from: oldValue)
    }
  }
  public var openAIModel: String {
    didSet {
      if !isLoadingSettings, oldValue != openAIModel { contextMemory?.invalidateAuthorization() }
      handleOpenAIModelChange(from: oldValue)
    }
  }
  public internal(set) var openAICredentialAvailability: OpenAICredentialAvailability = .loading
  public internal(set) var openAIConfigurationVerificationState:
    OpenAIConfigurationVerificationState = .idle
  public internal(set) var openAIVerificationFailure: OpenAIVerificationFailure?
  public var contextMemory: ContextMemoryModel?
  public let voice = VoiceRunModel()
  public var isRunning: Bool {
    get { voice.isRunning }
    set { voice.isRunning = newValue }
  }
  public internal(set) var isLoadingSettings: Bool {
    get { settings.isLoading }
    set { settings.isLoading = newValue }
  }
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
  public var workflowLibraryError: String? {
    get { workflowLibrary.workflowLibraryError }
    set { workflowLibrary.workflowLibraryError = newValue }
  }
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
  public var recordCount: Int {
    recordWorkspace.snapshot.records.count
  }
  public var recordPreview: String? {
    guard let projection = recordWorkspace.snapshot.records.first else { return nil }
    return projection.header.kind == .text ? projection.header.preview : nil
  }
  public internal(set) var systemClipboardCaptureControlSnapshot = SystemClipboardCaptureControlSnapshot(
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
  public var lastCompletedText: String? {
    get { voice.lastCompletedText }
    set { voice.lastCompletedText = newValue }
  }
  public var lastFailure: String?
  public var eventFeed: [EventFeedEntry] = []
  public internal(set) var diagnosticEvents: [DiagnosticEvent] = []
  public internal(set) var diagnosticsLoadState: DiagnosticsLoadState = .loading
  public let vocabulary: VocabularyLibraryModel
  public internal(set) var vocabularyRules: [VocabularyRule] {
    get { vocabulary.vocabularyRules }
    set {
      let changed = newValue != vocabulary.vocabularyRules
      vocabulary.setLegacyRules(newValue)
      guard !vocabulary.isApplying else { return }
      rebuildWorkflowLibrary()
      if changed { persistVocabularyLibrary() }
    }
  }
  public internal(set) var vocabularyCollections: [VocabularyCollection] {
    get { vocabulary.vocabularyCollections }
    set { vocabulary.vocabularyCollections = newValue }
  }
  public internal(set) var vocabularyCollectionBindings: [VocabularyCollectionBinding] {
    get { vocabulary.vocabularyCollectionBindings }
    set { vocabulary.vocabularyCollectionBindings = newValue }
  }
  public internal(set) var workflowCustomizations: [WorkflowCustomization] {
    get { workflowLibrary.workflowCustomizations }
    set { workflowLibrary.workflowCustomizations = newValue }
  }
  public internal(set) var vocabularyRulesAvailability: StoredSettingsDomainAvailability {
    get { vocabulary.availability }
    set { vocabulary.availability = newValue }
  }
  public internal(set) var vocabularyRulesError: String? {
    get { vocabulary.error }
    set { vocabulary.error = newValue }
  }
  public internal(set) var privacyPolicySettings: PrivacyPolicySettings = .defaults {
    didSet {
      guard oldValue != privacyPolicySettings else { return }
      if !isLoadingPrivacySettings { contextMemory?.invalidateAuthorization() }
      invalidateWorkflowExplanation()
      history.previewMode = privacyPolicySettings.historyPreviewMode
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
  public internal(set) var recordRetentionPeriod: HistoryRetentionPeriod = .defaultPeriod
  public internal(set) var runHistoryRetentionPeriod: HistoryRetentionPeriod = .defaultPeriod {
    didSet {
      history.runHistoryRetentionPeriod = runHistoryRetentionPeriod
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
  public internal(set) var lastPreservedActiveRecordCount = 0
  public internal(set) var historyLoadState: HistoryLoadState {
    get { history.historyLoadState }
    set { history.historyLoadState = newValue }
  }
  public internal(set) var historyRecords: [WorkflowResultRecord] {
    get { history.historyRecords }
    set { history.historyRecords = newValue }
  }
  public internal(set) var runHistoryBrowseLoadState: HistoryLoadState {
    get { history.runHistoryBrowseLoadState }
    set { history.runHistoryBrowseLoadState = newValue }
  }
  public internal(set) var runHistoryPage: RunHistoryPage? {
    get { history.runHistoryPage }
    set { history.runHistoryPage = newValue }
  }
  public internal(set) var isRunHistoryPageTransitioning: Bool {
    get { history.isRunHistoryPageTransitioning }
    set { history.isRunHistoryPageTransitioning = newValue }
  }
  public internal(set) var runHistoryPaginationFailed: Bool {
    get { history.runHistoryPaginationFailed }
    set { history.runHistoryPaginationFailed = newValue }
  }
  public internal(set) var runHistoryHasNewerEntries: Bool {
    get { history.runHistoryHasNewerEntries }
    set { history.runHistoryHasNewerEntries = newValue }
  }
  public internal(set) var runHistoryDeepLinkState: RunHistoryDeepLinkState {
    get { history.runHistoryDeepLinkState }
    set { history.runHistoryDeepLinkState = newValue }
  }
  public internal(set) var workflowRunReceiptsByRunID: [UUID: WorkflowRunReceipt] {
    get { history.workflowRunReceiptsByRunID }
    set { history.workflowRunReceiptsByRunID = newValue }
  }
  public internal(set) var failedAudioRecoveryReceipts: [FailedAudioRecoveryReceipt] = []
  public internal(set) var failedAudioRecoveryEnabled = false
  public internal(set) var isUpdatingFailedAudioRecovery = false
  public internal(set) var retryingFailedAudioRecoveryIDs: Set<UUID> = []
  public internal(set) var failedAudioRecoveryUnavailableReasonsByRunID:
    [UUID: FailedAudioRecoveryError] = [:]
  public var failedAudioRecoveryError: String?
  public internal(set) var benchmarkRecordingArchiveEnabled = false
  public internal(set) var isUpdatingBenchmarkRecordingArchive = false
  public var benchmarkRecordingArchiveError: String?
  // The floating panel is driven through `updateLiveSubtitlePanelAction`, not
  // through a SwiftUI view observing AppModel. Keeping its 25 Hz meter state
  // outside Observation prevents every audio frame from invalidating the main
  // application view graph.
  @ObservationIgnored public internal(set) var liveSubtitleSnapshot: LiveSubtitleSnapshot?
  @ObservationIgnored var currentCaptureLiveSubtitleSnapshot: LiveSubtitleSnapshot? {
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
  @ObservationIgnored var lastLiveSubtitleMeterRefreshAt: ContinuousClock.Instant?
  @ObservationIgnored var pendingLiveSubtitleMeterSnapshot: LiveSubtitleSnapshot?
  public var recordHistoryVisibility: RecordHistoryVisibility {
    didSet {
      guard oldValue != recordHistoryVisibility else { return }
      persistRecordHistoryVisibilityPreference()
    }
  }
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
    workflows.filter { workflow in
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
    isRunning || (audioProcessingQueueSnapshot?.isVisible ?? false)
  }
  public var isLocalHistoryMaintenanceAvailable: Bool {
    localHistoryMaintenance != nil
  }
  public var canClearRunHistory: Bool {
    !hasActiveOrQueuedVoiceRun && !isLocalHistoryMaintenanceRunning
      && !isUpdatingHistoryRetentionSettings
  }
  public var recentVoiceHistoryRecords: [WorkflowResultRecord] {
    historyRecords.filter(isVoiceHistoryRecord)
  }
  public var recentVoiceResultRecords: [WorkflowResultRecord] {
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
  var pendingRuns: [UUID: RunSnapshot] { voice.runs }
  var pendingInteractiveWorkflowTask: Task<Void, Never>?
  var interactiveWorkflowTaskGeneration = 0
  var workflowAudioActionTasks: [UUID: Task<Void, Never>] = [:]
  var listenerTask: Task<Void, Never>?
  var eventListenerBarrierContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
  var eventListenerShutdownTask: Task<Void, Never>?
  var hasStoppedEventListener = false
  var activeRunID: UUID? {
    get { voice.activeRunID }
    set { voice.activeRunID = newValue }
  }
  var workflowEnabledStates: [UUID: Bool] {
    get { workflowLibrary.workflowEnabledStates }
    set { workflowLibrary.workflowEnabledStates = newValue }
  }
  public internal(set) var isUpdatingWorkflowEnabledStates = false
  var workflowFileURLsByID: [UUID: URL] {
    get { workflowLibrary.workflowFileURLsByID }
    set { workflowLibrary.workflowFileURLsByID = newValue }
  }
  var workflowFileSourcesByID: [UUID: String] {
    get { workflowLibrary.workflowFileSourcesByID }
    set { workflowLibrary.workflowFileSourcesByID = newValue }
  }
  public internal(set) var workflowFileIssues: [WorkflowFileIssue] {
    get { workflowLibrary.workflowFileIssues }
    set { workflowLibrary.workflowFileIssues = newValue }
  }
  var invalidWorkflowFileIDs: Set<UUID> {
    get { workflowLibrary.invalidWorkflowFileIDs }
    set { workflowLibrary.invalidWorkflowFileIDs = newValue }
  }
  @ObservationIgnored var workflowFileMonitorTask: Task<Void, Never>?
  var workflowFileLoadGeneration: Int {
    get { workflowLibrary.workflowFileLoadGeneration }
    set { workflowLibrary.workflowFileLoadGeneration = newValue }
  }
  var usesWorkflowFilesAsSource: Bool {
    get { workflowLibrary.usesWorkflowFilesAsSource }
    set { workflowLibrary.usesWorkflowFilesAsSource = newValue }
  }
  var hasModifiedWorkflowLibrary: Bool {
    get { workflowLibrary.hasModifiedWorkflowLibrary }
    set { workflowLibrary.hasModifiedWorkflowLibrary = newValue }
  }
  var isRestoringSettings = false
  /// Keys changed by the user after the initial snapshot read started but
  /// before it was applied. The older snapshot must not overwrite them.
  var settingsKeysModifiedDuringInitialLoad: Set<AppSettingKey> = []
  var persistenceWrites: PersistenceWriteCoordinator { settings.writes }
  var settingsLoadGeneration = 0
  var unavailableSettingsDomainRetryGeneration = 0
  var scalarSettingsRetryGenerations: [ScalarSettingsDomain: Int] = [:]
  var localSpeechModelMutationGeneration = 0
  let settingsReadTaskOwner = AppModelSettingsReadTaskOwner()
  var pendingPrivacySettingsWriteTask: Task<Void, Never>?
  var privacySettingsWriteGeneration = 0
  var pendingLiveSubtitleHideTask: Task<Void, Never>?
  @ObservationIgnored var pendingLiveSubtitleMeterRefreshTask: Task<Void, Never>?
  @ObservationIgnored var liveSubtitleMeterRefreshGeneration = 0
  var clipboardUpdateDebounceTask: Task<Void, Never>?
  var historyLoadGeneration = 0
  var runReceiptLoadGeneration = 0
  var historyProjectionLoadTasks: [UUID: Task<Void, Never>] = [:]
  var runHistoryBrowseTask: Task<Void, Never>? {
    get { history.runHistoryBrowseTask }
    set { history.runHistoryBrowseTask = newValue }
  }
  var runHistoryBrowseGeneration: Int {
    get { history.runHistoryBrowseGeneration }
    set { history.runHistoryBrowseGeneration = newValue }
  }
  var runHistoryCurrentPageLocator: RunHistoryPageLocator? {
    get { history.runHistoryCurrentPageLocator }
    set { history.runHistoryCurrentPageLocator = newValue }
  }
  var runHistoryNewerPageLocators: [RunHistoryPageLocator] {
    get { history.runHistoryNewerPageLocators }
    set { history.runHistoryNewerPageLocators = newValue }
  }
  var historyRetentionRerunRequested = false
  var historyRetentionSettingsLoadError: String?
  var historyRetentionSettingsWriteError: String?
  var clipboardHistoryRetentionSettingIsInvalid = false
  var runHistoryRetentionSettingIsInvalid = false
  var shouldStartPeriodicHistoryRetentionMaintenance = false
  var localHistoryMaintenanceTasks: [UUID: Task<Void, Never>] = [:]
  var periodicHistoryRetentionMaintenanceTask: Task<Void, Never>?
  var diagnosticsLoadGeneration = 0
  var localSpeechPreparationGeneration = 0
  let localSpeechPreparationTaskOwner = LocalSpeechPreparationTaskOwner()
  var residentSpeechModelSynchronizationTask: Task<Void, Never>?
  var residentSpeechModelSynchronizationTasks: [UUID: Task<Void, Never>] = [:]
  var enabledSpeechModelPreparationTasks: [String: Task<Void, Never>] = [:]
  var shouldPrepareLocalSpeechModelAfterInitialSettingsLoad = false
  var openAICredentialLoadGeneration = 0
  var openAIVerificationGeneration = 0
  var openAIVerificationTask: Task<Void, Never>?
  var failedAudioRecoveryRetryTasks: [UUID: Task<Void, Never>] = [:]
  var failedAudioRecoveryLoadTask: Task<Void, Never>?
  var failedAudioRecoveryLoadGeneration = 0
  var hasBegunApplicationShutdown = false {
    didSet {
      guard hasBegunApplicationShutdown, !oldValue else { return }
      history.hasBegunApplicationShutdown = true
      cancelPendingLiveSubtitleMeterRefresh()
    }
  }
  let workflowExplanationTaskOwner = WorkflowExplanationTaskOwner()
  var workflowExplanationGeneration = 0
  var isApplyingVocabularyLibrary: Bool {
    get { vocabulary.isApplying }
    set { vocabulary.isApplying = newValue }
  }
  let liveSubtitlePreparingHideDelay: Duration

  public init(
    workflows: [WorkflowDefinition],
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
    let declaredLocalSpeechAvailability =
      localSpeechAvailability
      ?? (localSpeechTrustMaterialAvailable ? .available : .trustMaterialUnavailable)
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
    self.workflowLibrary = WorkflowLibraryModel(workflows: workflows)
    self.language = language
    // Capture remains closed until durable settings prove it is enabled.
    // Test and preview compositions that explicitly skip loading retain the
    // historical enabled behavior when they still provide a settings store.
    self.systemClipboardCaptureEnabled = settingsStore != nil && !loadsPersistentSettingsOnInitialization
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
    let resolvedEnabledSpeechModelIDs = defaultEnabledSpeechModelIDs.isEmpty
      ? Set([resolvedDefaultTTSModelIdentifier].filter { !$0.isEmpty })
      : defaultEnabledSpeechModelIDs
    self.enabledSpeechModelIDs = resolvedEnabledSpeechModelIDs
    self.residentSpeechModelIDs = LocalSpeechSettings().residentModelIDs
      .intersection(resolvedEnabledSpeechModelIDs)
    self.residentSpeechBudgetConfirmation = nil
    self.pendingResidentSpeechModelIDs = nil
    self.openAIAPIKey = ""
    self.openAIBaseURL = OpenAISettings().baseURL
    self.openAIModel = OpenAISettings().model
    self.permissionSnapshot = permissionSnapshot
    self.eventBus = eventBus
    self.sessionCoordinator = sessionCoordinator
    self.outputActionRegistry = outputActionRegistry
    self.recordWorkspace = recordWorkspace ?? RecordWorkspaceModel(store: RecordStore())
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
      isLoadingSettings = false
      openAICredentialAvailability = .inaccessible
      if settingsStore == nil {
        unavailableScalarSettingKeys.formUnion(
          ScalarSettingsDomain.systemClipboard.settingKeys
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


extension AppModel {
  nonisolated static let localSpeechRecognizerID = AppSettingsCodec.localSpeechRecognizerID
  nonisolated static let sherpaOnnxRecognizerID = AppSettingsCodec.sherpaOnnxRecognizerID
  nonisolated static let sherpaStreamingRecognizerID = AppSettingsCodec.sherpaStreamingRecognizerID
  nonisolated static let workflowOriginMetadataKey = AppSettingsCodec.workflowOriginMetadataKey
  nonisolated static let userWorkflowOriginMetadataValue = AppSettingsCodec.userWorkflowOriginMetadataValue
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
