@testable import RillWorkflows
import XCTest

@testable import RillCore
@testable import RillUI

struct UITestContextProvider: ContextProvider {
  func captureContext() async -> ContextSnapshot { .empty }
}

struct UITestRecognizer: SpeechRecognizer {
  let id = "ui.test.recognizer"
  let result: RecognitionResult
  let delay: Duration

  func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
    try? await Task.sleep(for: delay)
    return result
  }
}

actor ProbeActionLog {
  private(set) var callCount = 0

  func increment() {
    callCount += 1
  }

  func snapshot() -> Int {
    callCount
  }
}

struct UITestAction: OutputAction {
  let id: String
  let log: ProbeActionLog

  init(id: String = "ui.test.action", log: ProbeActionLog) {
    self.id = id
    self.log = log
  }

  func execute(text: String, context: ActionContext) async throws -> ActionResult {
    await log.increment()
    return .copiedToClipboard
  }
}

struct SettingsStoreActivitySnapshot {
  let storage: [AppSettingKey: String]
  let singleReadCount: Int
  let batchReadCount: Int
  let settingsSnapshotRequests: [[AppSettingKey]]
  let setCounts: [AppSettingKey: Int]
  let atomicWriteCount: Int
  let atomicSnapshots: [[AppSettingKey: String]]
  let removeCounts: [AppSettingKey: Int]
}

enum UITestSettingsStoreError: Error {
  case requestedFailure
}

actor UITestSettingsStore: SettingsStore {
  private var storage: [AppSettingKey: String]
  private let failingSetKeys: Set<AppSettingKey>
  private let failBatchReads: Bool
  private var unavailableKeys: Set<AppSettingKey>
  private var shouldSuspendBatchReads: Bool
  private var singleReadCount = 0
  private var batchReadCount = 0
  private var settingsSnapshotRequests: [[AppSettingKey]] = []
  private var setCounts: [AppSettingKey: Int] = [:]
  private var atomicSnapshots: [[AppSettingKey: String]] = []
  private var removeCounts: [AppSettingKey: Int] = [:]
  private var batchReadEntered = false
  private var batchReadEntryWaiters: [CheckedContinuation<Void, Never>] = []
  private var batchReadReleaseWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    storage: [AppSettingKey: String] = [:],
    failingSetKeys: Set<AppSettingKey> = [],
    failBatchReads: Bool = false,
    suspendBatchReads: Bool = false,
    unavailableKeys: Set<AppSettingKey> = []
  ) {
    self.storage = storage
    self.failingSetKeys = failingSetKeys
    self.failBatchReads = failBatchReads
    self.unavailableKeys = unavailableKeys
    shouldSuspendBatchReads = suspendBatchReads
  }

  func string(forKey key: AppSettingKey) async throws -> String? {
    singleReadCount += 1
    return storage[key]
  }

  func strings(forKeys keys: [AppSettingKey]) async throws -> [AppSettingKey: String] {
    batchReadCount += 1
    if failBatchReads {
      throw UITestSettingsStoreError.requestedFailure
    }
    let snapshot = keys.reduce(into: [AppSettingKey: String]()) { partialResult, key in
      if let value = storage[key] {
        partialResult[key] = value
      }
    }
    if shouldSuspendBatchReads {
      shouldSuspendBatchReads = false
      batchReadEntered = true
      let waiters = batchReadEntryWaiters
      batchReadEntryWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      await withCheckedContinuation { continuation in
        batchReadReleaseWaiters.append(continuation)
      }
    }
    return snapshot
  }

  func settingsSnapshot(
    forKeys keys: [AppSettingKey]
  ) async throws -> SettingsStoreReadSnapshot {
    settingsSnapshotRequests.append(keys)
    var values = try await strings(forKeys: keys)
    let requestedUnavailableKeys = unavailableKeys.intersection(Set(keys))
    for key in requestedUnavailableKeys {
      values.removeValue(forKey: key)
    }
    return SettingsStoreReadSnapshot(
      values: values,
      unavailableKeys: requestedUnavailableKeys
    )
  }

  func waitUntilBatchReadIsSuspended() async {
    guard !batchReadEntered else { return }
    await withCheckedContinuation { continuation in
      batchReadEntryWaiters.append(continuation)
    }
  }

  func resumeBatchRead() {
    let waiters = batchReadReleaseWaiters
    batchReadReleaseWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  func suspendNextBatchRead() {
    shouldSuspendBatchReads = true
    batchReadEntered = false
  }

  func setUnavailableKeys(_ keys: Set<AppSettingKey>) {
    unavailableKeys = keys
  }

  func setString(_ value: String, forKey key: AppSettingKey) async throws {
    if failingSetKeys.contains(key) {
      throw UITestSettingsStoreError.requestedFailure
    }
    storage[key] = value
    setCounts[key, default: 0] += 1
  }

  func setStringsAtomically(_ values: [AppSettingKey: String]) async throws {
    storage.merge(values) { _, newValue in newValue }
    atomicSnapshots.append(values)
    for key in values.keys {
      setCounts[key, default: 0] += 1
    }
  }

  func removeValue(forKey key: AppSettingKey) async throws {
    storage.removeValue(forKey: key)
    removeCounts[key, default: 0] += 1
  }

  func activitySnapshot() -> SettingsStoreActivitySnapshot {
    SettingsStoreActivitySnapshot(
      storage: storage,
      singleReadCount: singleReadCount,
      batchReadCount: batchReadCount,
      settingsSnapshotRequests: settingsSnapshotRequests,
      setCounts: setCounts,
      atomicWriteCount: atomicSnapshots.count,
      atomicSnapshots: atomicSnapshots,
      removeCounts: removeCounts
    )
  }
}

struct SecureCredentialStoreActivitySnapshot {
  let storage: [SecureCredentialKey: String]
  let readCounts: [SecureCredentialKey: Int]
  let setCounts: [SecureCredentialKey: Int]
  let removeCounts: [SecureCredentialKey: Int]
}

actor UITestSecureCredentialStore: SecureCredentialStore {
  private var storage: [SecureCredentialKey: String]
  private var readCounts: [SecureCredentialKey: Int] = [:]
  private var setCounts: [SecureCredentialKey: Int] = [:]
  private var removeCounts: [SecureCredentialKey: Int] = [:]

  init(storage: [SecureCredentialKey: String] = [:]) {
    self.storage = storage
  }

  func credential(for key: SecureCredentialKey) async throws -> String? {
    readCounts[key, default: 0] += 1
    return storage[key]
  }

  func setCredential(_ value: String, for key: SecureCredentialKey) async throws {
    storage[key] = value
    setCounts[key, default: 0] += 1
  }

  func removeCredential(for key: SecureCredentialKey) async throws {
    storage.removeValue(forKey: key)
    removeCounts[key, default: 0] += 1
  }

  func activitySnapshot() -> SecureCredentialStoreActivitySnapshot {
    SecureCredentialStoreActivitySnapshot(
      storage: storage,
      readCounts: readCounts,
      setCounts: setCounts,
      removeCounts: removeCounts
    )
  }
}

actor SpeechPreparationProbe {
  private(set) var prepareCount = 0
  private(set) var lastSettings: LocalSpeechSettings?
  private(set) var reportedProgress: [Double] = []

  func recordPreparation(settings: LocalSpeechSettings) {
    prepareCount += 1
    lastSettings = settings
  }

  func recordProgress(_ progress: Progress) {
    reportedProgress.append(progress.fractionCompleted)
  }

  func snapshot() -> (
    prepareCount: Int, lastSettings: LocalSpeechSettings?, reportedProgress: [Double]
  ) {
    (prepareCount, lastSettings, reportedProgress)
  }
}

actor WorkflowAudioRunProbe {
  private(set) var startCalls: [(workflowID: UUID, binding: TriggerBinding)] = []
  private(set) var finishCount = 0

  func recordStart(workflowID: UUID, binding: TriggerBinding) {
    startCalls.append((workflowID, binding))
  }

  func recordFinish() {
    finishCount += 1
  }

  func snapshot() -> (startCalls: [(workflowID: UUID, binding: TriggerBinding)], finishCount: Int) {
    (startCalls, finishCount)
  }
}

actor WorkflowAudioStartGate {
  private var didStart = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var startContinuation: CheckedContinuation<Void, Error>?

  func suspendStart() async throws {
    didStart = true
    let waiters = startWaiters
    startWaiters.removeAll()
    waiters.forEach { $0.resume() }

    try await withCheckedThrowingContinuation { continuation in
      startContinuation = continuation
    }
  }

  func waitUntilStarted() async {
    guard !didStart else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func succeed() {
    startContinuation?.resume()
    startContinuation = nil
  }

  func fail(message: String) {
    startContinuation?.resume(
      throwing: NSError(
        domain: "UITest",
        code: 7,
        userInfo: [NSLocalizedDescriptionKey: message]
      ))
    startContinuation = nil
  }
}

actor WorkflowStartProbe {
  private(set) var calls: [(workflow: WorkflowDefinition, binding: TriggerBinding)] = []

  func record(workflow: WorkflowDefinition, binding: TriggerBinding) {
    calls.append((workflow, binding))
  }

  func snapshot() -> [(workflow: WorkflowDefinition, binding: TriggerBinding)] {
    calls
  }
}

actor EventBusHolder {
  private var eventBus: EventBus?

  func set(_ eventBus: EventBus) {
    self.eventBus = eventBus
  }

  func get() -> EventBus? {
    eventBus
  }
}

actor RecordPanelProbe {
  private(set) var showCount = 0

  func recordShow() {
    showCount += 1
  }

  func snapshot() -> Int {
    showCount
  }
}

actor ClipboardUseProbe {
  private(set) var usedItemIDs: [UUID] = []

  func record(itemID: UUID) {
    usedItemIDs.append(itemID)
  }

  func snapshot() -> [UUID] {
    usedItemIDs
  }
}

actor LiveSubtitlePanelProbe {
  private(set) var updates: [(snapshot: LiveSubtitleSnapshot?, language: AppLanguage)] = []

  func record(snapshot: LiveSubtitleSnapshot?, language: AppLanguage) {
    updates.append((snapshot, language))
  }

  func snapshot() -> [(snapshot: LiveSubtitleSnapshot?, language: AppLanguage)] {
    updates
  }
}

enum UITestLocalHistoryMaintenanceCall: Equatable {
  case performRetention(HistoryRetentionPeriod, HistoryRetentionPeriod)
  case clearClipboard
  case clearRun
  case retryPending
}

actor UITestLocalHistoryMaintenance: LocalHistoryMaintaining {
  private var calls: [UITestLocalHistoryMaintenanceCall] = []
  private var results: [LocalHistoryMaintenanceResult]
  private let fallbackResult: LocalHistoryMaintenanceResult
  private let delay: Duration
  private let onRetention: (@Sendable () -> Void)?

  init(
    results: [LocalHistoryMaintenanceResult] = [],
    delay: Duration = .zero,
    onRetention: (@Sendable () -> Void)? = nil,
    fallbackResult: LocalHistoryMaintenanceResult = .completed(
      LocalHistoryMaintenanceCounts()
    )
  ) {
    self.results = results
    self.delay = delay
    self.onRetention = onRetention
    self.fallbackResult = fallbackResult
  }

  func performRetention(
    recordRetention: HistoryRetentionPeriod,
    runRetention: HistoryRetentionPeriod,
    now: Date
  ) async -> LocalHistoryMaintenanceResult {
    calls.append(.performRetention(recordRetention, runRetention))
    onRetention?()
    try? await Task.sleep(for: delay)
    return nextResult()
  }

  func clearRecordHistory() async -> LocalHistoryMaintenanceResult {
    calls.append(.clearClipboard)
    try? await Task.sleep(for: delay)
    return nextResult()
  }

  func clearRunHistory() async -> LocalHistoryMaintenanceResult {
    calls.append(.clearRun)
    try? await Task.sleep(for: delay)
    return nextResult()
  }

  func retryPendingMaintenance() async -> LocalHistoryMaintenanceResult {
    calls.append(.retryPending)
    try? await Task.sleep(for: delay)
    return nextResult()
  }

  func enqueue(_ result: LocalHistoryMaintenanceResult) {
    results.append(result)
  }

  func resetCalls() {
    calls.removeAll()
  }

  func callSnapshot() -> [UITestLocalHistoryMaintenanceCall] {
    calls
  }

  private func nextResult() -> LocalHistoryMaintenanceResult {
    guard !results.isEmpty else { return fallbackResult }
    return results.removeFirst()
  }
}

struct AppModelTestHarness {
  let model: AppModel
  let workflow: WorkflowDefinition
  let eventBus: EventBus
  let actionLog: ProbeActionLog
}

private enum UITestWorkflowFileStoreError: Error {
  case rejectedSave
}

actor UITestWorkflowFileStore: WorkflowFileStore {
  nonisolated let configurationDirectoryURL = URL(
    fileURLWithPath: "/tmp/rill-ui-test-workflows",
    isDirectory: true
  )

  private var recordsByID: [UUID: WorkflowFileRecord]
  private let rejectsSaves: Bool

  init(records: [WorkflowFileRecord] = [], rejectsSaves: Bool = false) {
    recordsByID = Dictionary(uniqueKeysWithValues: records.map {
      ($0.workflow.id, $0)
    })
    self.rejectsSaves = rejectsSaves
  }

  func load() async -> WorkflowFileLoadResult {
    let records = recordsByID.values.sorted {
      $0.fileURL.lastPathComponent < $1.fileURL.lastPathComponent
    }
    return WorkflowFileLoadResult(
      discoveredFileCount: records.count,
      records: records
    )
  }

  func save(
    workflow: WorkflowDefinition,
    isEnabled: Bool,
    replacing fileURL: URL?
  ) async throws -> URL {
    let destination = fileURL
      ?? configurationDirectoryURL.appendingPathComponent(
        "\(workflow.id.uuidString.lowercased()).toml"
      )
    recordsByID[workflow.id] = WorkflowFileRecord(
      workflow: workflow,
      isEnabled: isEnabled,
      fileURL: destination,
      source: String(decoding: try JSONEncoder().encode(workflow), as: UTF8.self)
    )
    guard !rejectsSaves else {
      // Simulate an atomic write that succeeded before a later metadata step failed.
      throw UITestWorkflowFileStoreError.rejectedSave
    }
    return destination
  }

  func saveDocument(_ document: WorkflowDocument, replacing fileURL: URL?, expected: WorkflowFileExpectation) async throws -> WorkflowFileRecord {
    let previous = recordsByID[document.workflow.id]
    switch expected {
    case .missing: guard previous == nil else { throw WorkflowFileConflict.changed }
    case .source(let source): guard previous?.source == source else { throw WorkflowFileConflict.changed }
    case .overwrite: break
    }
    let url = try await save(workflow: document.workflow, isEnabled: document.isEnabled, replacing: fileURL)
    let source = String(decoding: try JSONEncoder().encode(document.workflow), as: UTF8.self)
    let record = WorkflowFileRecord(workflow: document.workflow, isEnabled: document.isEnabled, fileURL: url, source: source)
    recordsByID[document.workflow.id] = record
    return record
  }

  func delete(fileURL: URL, expected: WorkflowFileExpectation) async throws {
    guard let record = recordsByID.values.first(where: { $0.fileURL == fileURL }) else { throw WorkflowFileConflict.changed }
    if case .source(let source) = expected, record.source != source { throw WorkflowFileConflict.changed }
    if case .missing = expected { throw WorkflowFileConflict.changed }
    recordsByID.removeValue(forKey: record.workflow.id)
  }

  func delete(fileURL: URL) async throws {
    recordsByID = recordsByID.filter { $0.value.fileURL != fileURL }
  }

  func records() -> [WorkflowFileRecord] {
    recordsByID.values.sorted { $0.workflow.id.uuidString < $1.workflow.id.uuidString }
  }
}

@MainActor
func makeHarness(
  workflow: WorkflowDefinition? = nil,
  workflows: [WorkflowDefinition]? = nil,
  delay: Duration = .zero,
  settingsStore: (any SettingsStore)? = nil,
  workflowFileStore: (any WorkflowFileStore)? = nil,
  usesEphemeralSettingsStoreWhenNil: Bool = true,
  credentialStore: (any SecureCredentialStore)? = nil,
  usesEphemeralCredentialStoreWhenNil: Bool = true,
  localPersistenceStatus: LocalPersistenceStatus = .ready,
  vocabularyRuleSource: VocabularyRuleSource = VocabularyRuleSource(initialRules: []),
  privacySettingsSource: PrivacyPolicySettingsSource = PrivacyPolicySettingsSource(
    initialSettings: .defaults
  ),
  localSpeechSettingsSource: LocalSpeechSettingsSource = LocalSpeechSettingsSource(),
  settingsWriteDebounceDuration: Duration = .milliseconds(300),
  historyRetentionMaintenanceInterval: Duration? = nil,
  liveSubtitlePreparingHideDelay: Duration = .seconds(15),
  localSpeechTrustMaterialAvailable: Bool = true,
  localSpeechAvailability: LocalSpeechAvailability? = nil,
  trustedLocalSpeechModels: [LocalSpeechModelDescriptor] = appModelTestTrustedLocalSpeechModels(),
  defaultLocalSpeechModelIdentifier: String? = "qwen3-asr-0.6b-mlx-8bit",
  ttsModelOptions: [TTSModelOption] = [],
  defaultTTSModelIdentifier: String = "",
  localSpeechPhysicalMemoryGiB: Int = 16,
  historyRepository: (any HistoryRepository)? = nil,
  runHistoryBrowser: (any RunHistoryBrowsing)? = nil,
  runReceiptRepository: (any WorkflowRunReceiptRepository)? = nil,
  localHistoryMaintenance: (any LocalHistoryMaintaining)? = nil,
  diagnosticRepository: (any DiagnosticRepository)? = nil,
  recordWorkspace: RecordWorkspaceModel? = nil,
  permissionSnapshot: PermissionSnapshot = PermissionSnapshot(
    accessibility: .granted, microphone: .unknown),
  globalInputCapability: GlobalInputCapability = .available,
  prepareLocalSpeechAction:
    @escaping @Sendable (
      LocalSpeechSettings,
      @escaping @Sendable (Progress) -> Void
    ) async throws -> String = { settings, _ in
      settings.model
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
    @escaping @Sendable (WorkflowDefinition, TriggerBinding) async throws -> Void = { _, _ in },
  finishWorkflowAudioRunAction: @escaping @Sendable () async throws -> Void = {},
  verifyOpenAIConfigurationAction:
    @escaping @Sendable (OpenAISettings) async throws -> Void = { _ in },
  retryFailedAudioRecoveryAction:
    @escaping @Sendable (
      UUID,
      WorkflowDefinition
    ) async throws -> FailedAudioRecoveryController.RetryResult = { _, _ in .completed },
  deleteFailedAudioRecoveryAction: @escaping @Sendable (UUID) async throws -> Void = { _ in },
  clearFailedAudioRecoveryAction: @escaping @Sendable () async throws -> Void = {},
  refreshFailedAudioRecoveryAction: @escaping @Sendable (Bool) async throws -> Void = { _ in },
  loadFailedAudioRecoveryReceiptsAction:
    @escaping @Sendable () async throws -> [FailedAudioRecoveryReceipt] = { [] },
  clearBenchmarkRecordingArchiveAction: @escaping @Sendable () async throws -> Void = {},
  refreshBenchmarkRecordingArchiveAction:
    @escaping @Sendable (Bool) async throws -> Void = { _ in },
  authorizeWorkflowRunAction:
    @escaping @Sendable (
      WorkflowDefinition
    ) async throws -> AuthorizedWorkflowRunContext = { workflow in
      return AuthorizedWorkflowRunContext(
        workflow: workflow,
        contextSnapshot: .empty,
        recognitionOptions: .empty
      )
    },
  explainResolvedWorkflowAction:
    @escaping @Sendable (
      WorkflowResolvedExecutionPlan
    ) async throws -> WorkflowExplanationReceipt = { plan in
      AppModel.unavailableWorkflowExplanation(for: plan)
    },
  writeClipboardTextAction: @escaping @MainActor (String) -> Void = { _ in },
  showRecordPanelAction: @escaping @Sendable () async -> Void = {}
) -> AppModelTestHarness {
  let eventBus = EventBus()
  let actionLog = ProbeActionLog()
  let resolver = CandidateResolver(eventBus: eventBus)
  let defaultWorkflow = workflow ?? makeDefaultWorkflow()
  let resolvedWorkflows = workflows ?? [defaultWorkflow]
  let primaryWorkflow = resolvedWorkflows.first ?? defaultWorkflow

  let outputActionRegistry = OutputActionRegistry(
    actions: [
      UITestAction(log: actionLog),
      UITestAction(id: "focused-application.insert", log: actionLog),
      UITestAction(id: "system-clipboard.copy", log: actionLog),
      UITestAction(id: "record.store", log: actionLog),
      UITestAction(id: SpeechOutputActionID.speak, log: actionLog),
      UITestAction(id: ExternalOutputActionID.shortcutsRun, log: actionLog),
      UITestAction(id: ExternalOutputActionID.markdownAppend, log: actionLog),
    ]
  )
  let coordinator = SessionCoordinator(
    contextProvider: UITestContextProvider(),
    recognizerRegistry: SpeechRecognizerRegistry(
      recognizers: [
        UITestRecognizer(
          result: RecognitionResult(rawText: "hello", bestText: "hello"),
          delay: delay
        )
      ]
    ),
    transformerRegistry: TextTransformerRegistry(transformers: []),
    actionRegistry: outputActionRegistry,
    candidateResolver: resolver,
    eventBus: eventBus
  )

  let resolvedSettingsStore =
    settingsStore
    ?? (usesEphemeralSettingsStoreWhenNil ? UITestSettingsStore() : nil)
  let resolvedCredentialStore =
    credentialStore
    ?? (usesEphemeralCredentialStoreWhenNil ? UITestSecureCredentialStore() : nil)
  let loadsPersistentSettingsOnInitialization =
    settingsStore != nil
    || credentialStore != nil
    || !usesEphemeralSettingsStoreWhenNil
  let model = AppModel(
    workflows: resolvedWorkflows,
    eventBus: eventBus,
    sessionCoordinator: coordinator,
    outputActionRegistry: outputActionRegistry,
    recordWorkspace: recordWorkspace,
    candidateResolver: resolver,
    historyRepository: historyRepository,
    runHistoryBrowser: runHistoryBrowser,
    runReceiptRepository: runReceiptRepository,
    localHistoryMaintenance: localHistoryMaintenance,
    diagnosticRepository: diagnosticRepository,
    settingsStore: resolvedSettingsStore,
    workflowFileStore: workflowFileStore,
    credentialStore: resolvedCredentialStore,
    localPersistenceStatus: localPersistenceStatus,
    vocabularyRuleSource: vocabularyRuleSource,
    privacySettingsSource: privacySettingsSource,
    localSpeechSettingsSource: localSpeechSettingsSource,
    loadsPersistentSettingsOnInitialization: loadsPersistentSettingsOnInitialization,
    settingsWriteDebounceDuration: settingsWriteDebounceDuration,
    historyRetentionMaintenanceInterval: historyRetentionMaintenanceInterval,
    liveSubtitlePreparingHideDelay: liveSubtitlePreparingHideDelay,
    localSpeechTrustMaterialAvailable: localSpeechTrustMaterialAvailable,
    localSpeechAvailability: localSpeechAvailability,
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
    deliverNextRecordAction: {},
    permissionSnapshot: permissionSnapshot,
    refreshPermissionsAction: {},
    requestAccessibilityAction: {},
    requestMicrophoneAction: {},
    openAccessibilitySettingsAction: {},
    openMicrophoneSettingsAction: {}, requestGlobalInputAction: {}, retryGlobalInputAction: {}, workflowLibraryChangedAction: {}
  )
  model.installRecordPanelAction {
    Task {
      await showRecordPanelAction()
    }
  }
  model.updateGlobalInputCapability(globalInputCapability)

  return AppModelTestHarness(
    model: model,
    workflow: primaryWorkflow,
    eventBus: eventBus,
    actionLog: actionLog
  )
}

func makeDefaultWorkflow() -> WorkflowDefinition {
  WorkflowDefinition(
    name: "UI Test Workflow",
    titleKey: .directDemoClipboard,
    pipeline: PipelineDeclaration(
      recognizerID: "ui.test.recognizer",
      outputActions: [OutputActionReference(id: "ui.test.action")]
    ),
    ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
  )
}

func makeBuiltinPushToTalkWorkflow() -> WorkflowDefinition {
  WorkflowDefinition(
    id: UUID(uuidString: "B9E19A88-F9FB-4AB3-8444-CDBF7E215A88") ?? UUID(),
    name: "Speech to Text",
    titleKey: .pushToTalkCapture,
    trigger: .hotkey,
    pipeline: PipelineDeclaration(
      recognizerID: AppModel.localSpeechRecognizerID,
      postProcessSteps: [PostProcessStep(kind: .normalizeWhitespace)],
      outputActions: [OutputActionReference(id: "focused-application.insert")]
    ),
    ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "red"),
    metadata: [
      AppModel.workflowCatalogMetadataKey: AppModel.builtinWorkflowCatalogValue,
      AppModel.triggerGestureMetadataKey: AppModel.fnHoldGestureValue,
      WorkflowMetadataKey.builtinKind: AppModel.builtinPushToTalkKindValue,
      WorkflowMetadataKey.recognizerSelectionMode: "auto",
      WorkflowMetadataKey.settingsExposeOutputMode: "true",
    ]
  )
}

func makeBuiltinPushToTalkPolishWorkflow() -> WorkflowDefinition {
  WorkflowDefinition(
    id: UUID(uuidString: "BAE19A88-F9FB-4AB3-8444-CDBF7E215A88") ?? UUID(),
    name: "Polish",
    titleKey: .pushToTalkPolish,
    trigger: .manual,
    pipeline: PipelineDeclaration(
      recognizerID: AppModel.localSpeechRecognizerID,
      postProcessSteps: [
        PostProcessStep(kind: .normalizeWhitespace),
        PostProcessStep(
          kind: .llmRewrite,
          prompt: "Polish into a concise final message while preserving meaning and language."),
      ],
      outputActions: [OutputActionReference(id: "record.store")],
      deliveryPolicy: .init(strategy: .collectionFirst)
    ),
    ui: WorkflowUIConfig(symbolName: "wand.and.stars", accentColorName: "purple"),
    metadata: [
      AppModel.workflowCatalogMetadataKey: AppModel.builtinWorkflowCatalogValue,
      WorkflowMetadataKey.builtinKind: AppModel.builtinPushToTalkPolishKindValue,
      "eventType": WorkflowEditorDraft.EventType.groupItemCreated.rawValue,
      "sourceGroupID": RecordCollection.voiceInputID.rawValue.uuidString,
      "excludePolishTag": "true",
      "groupActionKind": RecordCollectionActionKind.editRecord.rawValue,
      "actionPrompt": "Polish into a concise final message while preserving meaning and language.",
    ]
  )
}

func waitForListenerSetup(_ harness: AppModelTestHarness) async {
  await harness.model.synchronizeEventListener()
}

func waitForEventProcessing(_ harness: AppModelTestHarness) async {
  await harness.model.synchronizeEventListener()
}

func waitForHistoryMaintenance(_ harness: AppModelTestHarness) async {
  await harness.model.waitForInitialVoiceConfiguration()
  await harness.model.flushPendingPersistenceWrites()
  await harness.model.waitForLocalHistoryMaintenance()
  await harness.model.synchronizeEventListener()
}

func waitForFailedAudioRecovery(_ harness: AppModelTestHarness) async {
  await harness.model.waitForInitialVoiceConfiguration()
  await harness.model.waitForFailedAudioRecoveryLoad()
  await harness.model.flushPendingPersistenceWrites()
  await harness.model.waitForFailedAudioRecoveryRetries()
  await harness.model.synchronizeEventListener()
}

func appModelTestTrustedLocalSpeechModels() -> [LocalSpeechModelDescriptor] {
    [
        LocalSpeechModelDescriptor(
            id: "qwen3-asr-0.6b-mlx-8bit",
            engine: .mlxAudioSwift,
            englishName: "Qwen3-ASR 0.6B INT8",
            simplifiedChineseName: "Qwen3-ASR 0.6B INT8"
        ),
        LocalSpeechModelDescriptor(
            id: "qwen3-asr-1.7b-mlx-8bit",
            engine: .mlxAudioSwift,
            englishName: "Qwen3-ASR 1.7B INT8",
            simplifiedChineseName: "Qwen3-ASR 1.7B INT8"
        ),
    ]
}
