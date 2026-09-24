import RillSpeechContracts
import AppKit
import Dispatch
import Foundation
import RillCore
import RillPersistence
import RillPlatform
import RillProviders
import RillRuntime
import RillUI

@MainActor
struct AppContainer {
  let model: AppModel
  let globalInputOwner: GlobalInputOwner
  let systemClipboardCaptureController: SystemClipboardCaptureController
  let recordingSessionManager: RecordingSessionManager
  let shutdown: @Sendable () async -> Void
  let setLiveAudioEscapeCancellationRunID: @Sendable (UUID?) -> Void
  let removeLiveAudioDurationLimit: @Sendable (UUID) async -> Bool
  let setSystemClipboardCaptureEnabled: @Sendable (Bool, UInt64) -> Void
  let ignoreNextExternalClipboardChange: @Sendable () -> Void
  let updateRecordPanelHotkey: @Sendable (HotkeyBindingDescriptor) -> Void
  let beginRecordPanelShortcutRecording: @Sendable () -> UUID
  let endRecordPanelShortcutRecording: @Sendable (UUID) -> Void
  let commitRecordPanelShortcutRecording: @Sendable (UUID, UInt16) -> Void
}

@MainActor
enum AppBootstrap {
  nonisolated static var ttsModelOptions: [TTSModelOption] {
    SpeechSynthesisModelCatalog.supportedModels.map { descriptor in
      let precision =
        switch descriptor.id {
        case .qwen3TTS06BCustomVoiceInt4: "INT4"
        case .qwen3TTS06BCustomVoiceInt8: "INT8"
        case .qwen3TTS06BCustomVoiceBF16: "BF16"
        }
      return TTSModelOption(
        id: descriptor.id.rawValue,
        precision: precision,
        approximateDownloadByteCount: descriptor.approximateDownloadByteCount,
        isDefault: descriptor.id == SpeechSynthesisModelCatalog.defaultModel.id
      )
    }
  }

  nonisolated static func displayedTTSPreparationProgress(
    _ update: SpeechWorkerProgress
  ) -> Double {
    switch update.phase {
    case .downloading:
      return update.fractionCompleted * 0.95
    case .loading:
      return 0.95 + (update.fractionCompleted * 0.05)
    }
  }

  nonisolated static var distributableLocalSpeechModels: [LocalSpeechModelDescriptor] {
    var models: [LocalSpeechModelDescriptor] = []
    #if arch(arm64)
      models.append(
        LocalSpeechModelDescriptor(
          id: MLXAudioModelID.qwen3ASR06BInt8.rawValue,
          engine: .mlxAudioSwift,
          englishName: "Qwen3-ASR · 0.6B · INT8",
          simplifiedChineseName: "Qwen3-ASR · 0.6B · INT8",
          englishDetail:
            "Lower-memory Qwen final transcription on Apple Silicon (8 GB minimum, 16 GB recommended) · about 1.01 GB model download · native Swift MLX backend",
          simplifiedChineseDetail:
            "面向 Apple Silicon 的轻量千问最终转写模型（最低 8 GB，建议 16 GB）· 模型下载约 1.01 GB · 原生 Swift MLX 后端",
          forcesAutomaticLanguageDetection: true,
          category: .intelligent,
          parameterCountMillions: 600,
          quantization: .int8,
          minimumSystemMemoryGiB: 8,
          recommendedSystemMemoryGiB: 16,
          hardwareRecommendationPriority: 20,
          approximateDownloadByteCount:
            MLXAudioModelCatalog.qwen3ASR06BInt8.approximateDownloadByteCount
        )
      )
      models.append(
        LocalSpeechModelDescriptor(
          id: MLXAudioModelID.qwen3ASR17BInt8.rawValue,
          engine: .mlxAudioSwift,
          englishName: "Qwen3-ASR · 1.7B · INT8",
          simplifiedChineseName: "Qwen3-ASR · 1.7B · INT8",
          englishDetail:
            "Higher-capacity Chinese/English final transcription on Apple Silicon (16 GB minimum, 24 GB recommended) · about 2.46 GB model download · native Swift MLX backend",
          simplifiedChineseDetail:
            "面向 Apple Silicon 的更大容量中英最终转写模型（最低 16 GB，建议 24 GB）· 模型下载约 2.46 GB · 原生 Swift MLX 后端",
          forcesAutomaticLanguageDetection: true,
          category: .intelligent,
          parameterCountMillions: 1_700,
          quantization: .int8,
          minimumSystemMemoryGiB: 16,
          recommendedSystemMemoryGiB: 24,
          hardwareRecommendationPriority: 30,
          approximateDownloadByteCount:
            MLXAudioModelCatalog.qwen3ASR17BInt8.approximateDownloadByteCount
        )
      )
    #endif
    return models
  }

  static func makeContainer() -> AppContainer {
    AppContainerFactory.makeContainer()
  }

  nonisolated static let speechWorkerExecutableName = "RillSpeechWorker"

  /// Resolves only the reviewed nested helper for an app bundle. SwiftPM
  /// executable builds use the adjacent product solely as a development path.
  nonisolated static func speechWorkerExecutableURL(
    bundleURL: URL = Bundle.main.bundleURL,
    mainExecutableURL: URL? = Bundle.main.executableURL
  ) -> URL {
    if bundleURL.pathExtension.lowercased() == "app" {
      return
        bundleURL
        .appendingPathComponent("Contents", isDirectory: true)
        .appendingPathComponent("Helpers", isDirectory: true)
        .appendingPathComponent(speechWorkerExecutableName, isDirectory: false)
    }
    let productDirectory = mainExecutableURL?.deletingLastPathComponent() ?? bundleURL
    return productDirectory.appendingPathComponent(
      speechWorkerExecutableName,
      isDirectory: false
    )
  }

  nonisolated static func speechWorkerExecutableIsAvailable(
    at executableURL: URL,
    fileManager: FileManager = .default
  ) -> Bool {
    guard fileManager.isExecutableFile(atPath: executableURL.path) else { return false }
    guard
      let values = try? executableURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
      )
    else {
      return false
    }
    return values.isRegularFile == true && values.isSymbolicLink != true
  }

  nonisolated static func stopStartupTasks(
    coordinator: ApplicationStartupTaskCoordinator
  ) async {
    await coordinator.stopAndDrain()
  }

  /// Maps provider errors to the only payload-free stages allowed to cross into
  /// AppModel presentation state. Cancellation remains a control-flow outcome.
  nonisolated static func localSpeechPreparationFailure(
    for error: Error
  ) -> LocalSpeechPreparationFailure? {
    if error is CancellationError || Task.isCancelled {
      return nil
    }
    if let urlError = error as? URLError, urlError.code == .cancelled {
      return nil
    }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
      return nil
    }
    if let failure = error as? LocalSpeechPreparationFailure {
      return failure
    }
    if error is LocalSpeechModelSelectionError {
      return LocalSpeechPreparationFailure(stage: .trustRoot)
    }
    if let failure = error as? SpeechWorkerClientError {
      let stage: LocalSpeechPreparationFailure.Stage =
        switch failure {
        case .remoteFailure(.unsupportedModel): .trustRoot
        case .remoteFailure(.modelUnavailable), .workerUnavailable, .workerDisconnected:
          .resolution
        case .protocolViolation, .staleResponse:
          .integrity
        case .requestTimedOut,
          .requestAlreadyActive,
          .remoteFailure,
          .invalidManagedAudio,
          .workerTerminationFailed:
          .runtime
        }
      return LocalSpeechPreparationFailure(stage: stage)
    }
    return LocalSpeechPreparationFailure(stage: .generic)
  }

  nonisolated static func makeExternalOutputActions(
    markdownCleanupCoordinator: MarkdownFileAppendCoordinator
  ) -> [any OutputAction] {
    [
      ShortcutsRunAction() as any OutputAction,
      MarkdownAppendAction(cleanupCoordinator: markdownCleanupCoordinator) as any OutputAction,
    ]
  }

  nonisolated static func makeWorkflowExplanationAction(
    service: WorkflowExplainService,
    privacyRunGate: PrivacyRunGate,
    privacyContextProvider: @escaping @Sendable () async -> ContextSnapshot
  ) -> @Sendable (WorkflowResolvedExecutionPlan) async -> WorkflowExplanationReceipt {
    { plan in
      let privacyContext = await privacyContextProvider()
      let evaluation = await privacyRunGate.evaluate(
        context: privacyContext,
        workflow: plan.executionWorkflow
      )
      return service.explainResolved(plan, privacyEvaluation: evaluation)
    }
  }

  nonisolated static func purgeRetiredCloudSpeechConfiguration(
    credentialStore: any SecureCredentialStore,
    settingsStore: (any SettingsStore)?
  ) async {
    try? await credentialStore.removeCredential(for: .retiredDeepgramAPIKey)
    guard let settingsStore else { return }
    for key in [
      AppSettingKey.retiredDeepgramBaseURL,
      .retiredDeepgramModel,
      .retiredDeepgramLanguage,
    ] {
      try? await settingsStore.removeValue(forKey: key)
    }
  }

  nonisolated static func makeRecognitionRunPreflight(
    trustedLocalModelIdentifiers: Set<String> =
      LocalSpeechModelCatalog.distributableModelIdentifiers,
    defaultLocalModelIdentifier: String = LocalSpeechModelCatalog.defaultModelIdentifier,
    localSpeechSettingsProvider:
      @escaping @Sendable () async throws -> LocalSpeechSettings = { .init() }
  ) -> RecognitionRunPreflight {
    { workflow in
      if let issue = WorkflowExecutionPolicy.issue(for: workflow) {
        throw SessionCoordinator.SessionError.unsupportedWorkflow(issue)
      }
      if ["local-speech", "sherpa-onnx.local", "sherpa-onnx.streaming", "auto"]
        .contains(workflow.plan.setup.speechRoute?.recognizerID ?? "")
      {
        let settings = try await localSpeechSettingsProvider()
        let configuredModelIdentifier = LocalSpeechModelCatalog.effectiveModelIdentifier(
          settings: settings
        )
        let selectedModelIdentifier =
          configuredModelIdentifier.isEmpty
          ? defaultLocalModelIdentifier : configuredModelIdentifier
        guard trustedLocalModelIdentifiers.contains(selectedModelIdentifier) else {
          throw LocalSpeechModelSelectionError.unsupportedModelIdentifier(
            selectedModelIdentifier
          )
        }
        if let modelOverride =
          (workflow.metadata[WorkflowMetadataKey.localSpeechModelOverride]
          ?? workflow.metadata[WorkflowMetadataKey.legacyWhisperKitModelOverride])?
          .trimmingCharacters(
            in: .whitespacesAndNewlines),
          !modelOverride.isEmpty,
          !trustedLocalModelIdentifiers.contains(modelOverride)
        {
          throw LocalSpeechModelSelectionError.unsupportedModelIdentifier(modelOverride)
        }
      }
    }
  }

  /// Prepares only model resources. Microphone frontends stay fully detached
  /// until an explicit capture so launching Rill or preloading a model cannot
  /// affect another application's microphone eligibility.
  nonisolated static func prepareLocalSpeechModel(
    prepareModel: @Sendable () async throws -> String
  ) async throws -> String {
    let preparedModel = try await prepareModel()
    try Task.checkCancellation()
    return preparedModel
  }

  /// Keeps the selected offline model authoritative while treating streaming
  /// hypotheses as a fixed best-effort enhancement. Preview failure must never
  /// make final local transcription unavailable.
  nonisolated static func prepareFinalModelAndStreamingPreview(
    prepareFinalModel: @Sendable () async throws -> String,
    prepareStreamingPreview: @Sendable () async throws -> Void,
    reportStreamingPreviewFailure: @Sendable (Error) async -> Void = { _ in }
  ) async throws -> String {
    let preparedModel = try await prepareFinalModel()
    try Task.checkCancellation()
    do {
      try await prepareStreamingPreview()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      await reportStreamingPreviewFailure(error)
    }
    try Task.checkCancellation()
    return preparedModel
  }

  nonisolated static func makeLocalHistoryMaintenance(
    recordHistory: any RecordHistoryMaintaining,
    historyRepository: any HistoryRepository,
    runReceiptRepository: any WorkflowRunReceiptRepository,
    diagnosticRepository: any DiagnosticHistoryMaintaining,
    settingsStore: (any SettingsStore)?,
    residuePurger: (any StorageResiduePurging)?,
    eventReporter: @escaping LocalHistoryMaintenance.EventReporter = { _ in }
  ) -> (any LocalHistoryMaintaining)? {
    guard let settingsStore, let residuePurger else { return nil }
    return LocalHistoryMaintenance(
      recordHistory: recordHistory,
      runHistory: historyRepository,
      runReceipts: runReceiptRepository,
      diagnosticHistory: diagnosticRepository,
      settingsStore: settingsStore,
      physicalPurger: residuePurger,
      eventReporter: eventReporter
    )
  }

  nonisolated static func makeRecordCollectionWorkflowRegistration(
    for workflow: WorkflowDefinition,
    isEnabled: Bool
  ) -> RecordCollectionWorkflowRegistration? {
    guard let configuration = try? workflow.parseRecordCollectionAutomationConfiguration() else {
      return nil
    }
    return RecordCollectionWorkflowRegistration(
      workflowID: workflow.id,
      triggerRule: configuration.rule,
      isEnabled: isEnabled,
      isExecutionSupported: false
    )
  }

  nonisolated static func localHistoryMaintenanceDiagnostic(
    for event: LocalHistoryMaintenanceEvent
  ) -> DiagnosticEvent {
    let level: DiagnosticLevel
    let message: String
    switch event.outcome {
    case .completed:
      level = .info
      message = "Local history maintenance completed."
    case .pending:
      level = .warning
      message = "Local history maintenance requires a retry."
    case .blocked:
      level = .error
      message = "Local history maintenance is blocked."
    }

    var metadata = [
      "outcome": event.outcome.rawValue,
      "recordRemovedCount": String(event.counts.recordRemovedCount),
      "runRemovedCount": String(event.counts.runRemovedCount),
      "runReceiptRemovedCount": String(event.counts.runReceiptRemovedCount),
      "diagnosticRemovedCount": String(event.counts.diagnosticRemovedCount),
      "preservedActiveRecordCount": String(event.counts.preservedActiveRecordCount),
      "totalRemovedCount": String(event.counts.totalRemovedCount),
    ]
    if let pendingReason = event.pendingReason {
      metadata["pendingReason"] = pendingReason.rawValue
    }
    if let blockReason = event.blockReason {
      metadata["blockReason"] = blockReason.rawValue
    }
    return DiagnosticEvent(
      subsystem: .platform,
      level: level,
      event: "history.maintenance.\(event.outcome.rawValue)",
      message: message,
      metadata: metadata
    )
  }

  nonisolated static func runStartupTemporaryFileCleanup(
    using service: RillTemporaryFileCleanupService
  ) async -> DiagnosticEvent {
    let report = await service.cleanupStartupOrphans()
    return temporaryFileCleanupDiagnostic(for: report)
  }

  nonisolated static func temporaryFileCleanupDiagnostic(
    for report: RillTemporaryFileJanitor.Report
  ) -> DiagnosticEvent {
    let hasFailures = report.failureCount > 0
    var metadata = [
      "source": "startup",
      "temporaryFileRemovedCount": String(report.removedCount),
      "temporaryFileFailureCount": String(report.failureCount),
    ]
    let operations = uniqueSortedCodes(report.failures.map { $0.operation.rawValue })
    if !operations.isEmpty {
      metadata["temporaryFileFailureOperations"] = operations.joined(separator: ",")
    }
    let artifactKinds = uniqueSortedCodes(
      report.failures.compactMap { $0.artifactKind?.rawValue }
    )
    if !artifactKinds.isEmpty {
      metadata["temporaryFileFailureArtifactKinds"] = artifactKinds.joined(separator: ",")
    }
    return DiagnosticEvent(
      subsystem: .platform,
      level: hasFailures ? .warning : .info,
      event: hasFailures
        ? "temporary-files.cleanup.pending"
        : "temporary-files.cleanup.completed",
      message: hasFailures
        ? "Temporary artifact cleanup requires a retry."
        : "Temporary artifact cleanup completed.",
      metadata: metadata
    )
  }

  private nonisolated static func uniqueSortedCodes(_ values: [String]) -> [String] {
    Array(Set(values)).sorted()
  }
}

private struct PersistenceBackends {
  let localPersistenceStatus: LocalPersistenceStatus
  let diagnosticRepository: any DiagnosticRepository
  let historyRepository: any HistoryRepository
  /// The single snapshot/keyset boundary used by History and global search.
  /// It is unavailable when durable SQLite persistence failed to initialize;
  /// callers must surface that state instead of rebuilding a lossy projection
  /// from independent repository reads.
  let runHistoryBrowser: (any RunHistoryBrowsing)?
  /// `nil` means terminal receipts cannot be durably stored. The app must
  /// not substitute an ephemeral repository and publish it as durable truth.
  let runReceiptRepository: (any WorkflowRunReceiptRepository)?
  let settingsStore: (any SettingsStore)?
  let recordGraphPersistenceStore: (any RecordGraphPersistenceStore)?
  let residuePurger: (any StorageResiduePurging)?
  let temporaryFileCleanupService: RillTemporaryFileCleanupService
  let failedAudioRecoveryStore: (any FailedAudioRecoveryStore)?
  let benchmarkRecordingArchiveStore: (any BenchmarkRecordingArchiveStore)?
  let startupDiagnostic: DiagnosticEvent?
}

private struct UnavailableWorkflowRunReceiptRepository: WorkflowRunReceiptRepository {
  func insertTerminal(_ receipt: WorkflowRunReceipt) async throws { throw RunHistoryGenerationError.unsupported }
  func receipts(matching query: WorkflowRunReceiptQuery) async throws -> [WorkflowRunReceipt] { throw RunHistoryGenerationError.unsupported }
  func deleteReceipts(olderThan cutoff: Date) async throws -> Int { throw RunHistoryGenerationError.unsupported }
  func deleteAllReceipts() async throws -> Int { throw RunHistoryGenerationError.unsupported }
}

private struct UnavailableRunHistoryBrowser: RunHistoryBrowsing {
  private enum UnavailableError: Error {
    case durableStorageUnavailable
  }

  func page(_ request: RunHistoryPageRequest) async throws -> RunHistoryPage {
    throw UnavailableError.durableStorageUnavailable
  }

  func page(
    containing entryID: UUID,
    in session: RunHistoryReadSession,
    limit: Int
  ) async throws -> RunHistoryPage? {
    throw UnavailableError.durableStorageUnavailable
  }

  func page(
    containing entryID: UUID,
    scope: RunHistoryBrowseScope,
    retentionCutoff: Date?,
    contentAccess: RunHistoryContentAccess,
    limit: Int
  ) async throws -> RunHistoryPage? {
    throw UnavailableError.durableStorageUnavailable
  }
}

private struct CoreServices {
  let eventBus: EventBus
  let persistence: PersistenceBackends
  let diagnostics: DiagnosticsRecorder
  let runReceiptRecorder: WorkflowRunReceiptRecorder
  let recordCollectionEventScheduler: RecordCollectionEventScheduler
  let recordStore: RecordStore
  let recordIngestion: RecordIngestionCoordinator
  let recordDelivery: RecordDeliveryCoordinator
  let localHistoryMaintenance: (any LocalHistoryMaintaining)?
  let candidateResolver: CandidateResolver
  let vocabularyRuleSource: VocabularyRuleSource
  let privacySettingsSource: PrivacyPolicySettingsSource
}

private struct PlatformServices {
  let focusTracker: FocusTracker
  let pasteboard: SystemClipboardPort
  let hotkeyTap: HotkeyEventTap
  let injectionEngine: TextInjectionEngine
  let cursorTextPreviewCoordinator: CursorTextPreviewCoordinator
  let permissionGate: PermissionGate
  let contextProvider: BuiltinContextProvider
  let credentialStore: any SecureCredentialStore
  let recordingCuePlayer: RecordingInteractionCuePlayer
}

private struct ProviderServices {
  let textRewriteTransformer: OpenAITextRewriteTransformer
  let jevPolishingSettings: JevPolishingSettingsSource
  let jevPolishingGate: JevTextPolishingGate
  let diagnosticsAudioCaptureService: AVAudioCaptureService
  let managedTemporaryAudioCleanupOwner: ManagedTemporaryAudioCleanupOwner
  let markdownFileAppendCoordinator: MarkdownFileAppendCoordinator
  let localSpeechSettingsSource: LocalSpeechSettingsSource
  let openAISettingsProvider: @Sendable () async throws -> OpenAISettings
  let localSpeechAvailability: LocalSpeechAvailability
  let trustedLocalSpeechModels: [LocalSpeechModelDescriptor]
  let defaultLocalSpeechModelIdentifier: String?
  let localSpeechStartupDiagnostic: DiagnosticEvent
  let speechWorkerSupervisor: SpeechWorkerSupervisor
  let ttsSpeechWorkerSupervisor: SpeechWorkerSupervisor
  let recordEmbedder: RecordWorkerEmbedder
  let mlxAudioSwiftRecognizer: MLXAudioSwiftWorkerRecognizer
  let localSpeechRecognizer: RoutedLocalSpeechRecognizer
  let streamingPreviewService: SpeechWorkerStreamingPreviewService
  let workflowAudioCaptureService: RealtimeAudioCaptureService
  let wakeWordTriggerSource: WakeWordTriggerSource?
  let speechOutputAction: any OutputAction
  let qwen3TTSSynthesizer: Qwen3TTSSpeechSynthesizer
  let ttsModelSelectionSource: SpeechSynthesisModelSelectionSource
  let speechPlaybackService: AVSpeechPlaybackService
  let ttsMemoryPressureSource: DispatchSourceMemoryPressure
  let speechModelPoolPresentationBridge: SpeechModelPoolPresentationBridge
}

private struct Registries {
  let recognizerRegistry: SpeechRecognizerRegistry
  let transformerRegistry: TextTransformerRegistry
  let actionRegistry: OutputActionRegistry
}

private struct RuntimeServices {
  let contextMemoryController: ContextMemoryController?
  let coordinator: SessionCoordinator
  let capturedAudioProcessingQueue: CapturedAudioProcessingQueue
  let assistantAudioProcessingQueue: CapturedAudioProcessingQueue
  let globalInputOwner: GlobalInputOwner
  let systemClipboardCaptureController: SystemClipboardCaptureController
  let recordingSessionManager: RecordingSessionManager
  let workflowAudioRunController: WorkflowAudioRunController
  let wakeWordCoordinator: WakeWordCoordinator?
  let cursorTextPreviewLifecycleCoordinator: CursorTextPreviewLifecycleCoordinator
  let failedAudioRecoveryController: FailedAudioRecoveryController?
  let benchmarkRecordingArchiveController: BenchmarkRecordingArchiveController?
  let privacyRunGate: PrivacyRunGate
  let authorizeWorkflowRunAction:
    @Sendable (
      WorkflowDefinition
    ) async throws -> AuthorizedWorkflowRunContext
  let workflowSelectionBridge: WorkflowSelectionBridge
  let systemClipboardCaptureControlBridge: SystemClipboardCaptureControlBridge
  let globalInputCapabilityBridge: GlobalInputCapabilityBridge
  let workflowManifestStartupDiagnostic: DiagnosticEvent
  let workflows: [WorkflowDefinition]
}

@MainActor
private final class SystemClipboardCaptureControlBridge {
  weak var model: AppModel?
  private var latestRevision: UInt64?

  func update(_ snapshot: SystemClipboardCaptureControlSnapshot) {
    guard let model else { return }
    if let latestRevision, snapshot.revision <= latestRevision { return }
    latestRevision = snapshot.revision
    model.updateSystemClipboardCaptureControlState(snapshot)
  }
}

@MainActor
private final class GlobalInputCapabilityBridge {
  weak var model: AppModel?
  private var latestCapability: GlobalInputCapability = .checking

  func update(_ capability: GlobalInputCapability) {
    latestCapability = capability
    model?.updateGlobalInputCapability(capability)
  }

  func attach(_ model: AppModel) {
    self.model = model
    model.updateGlobalInputCapability(latestCapability)
  }
}

@MainActor
private final class SpeechPlaybackPresentationBridge {
  weak var model: AppModel?
  private var isActive = false

  func update(isActive: Bool) {
    self.isActive = isActive
    model?.updateSpeechPlaybackState(isActive: isActive)
  }

  func attach(_ model: AppModel) {
    self.model = model
    model.updateSpeechPlaybackState(isActive: isActive)
  }
}

@MainActor
private final class SpeechModelPoolPresentationBridge {
  weak var model: AppModel?
  private var isDegraded = false
  private var measuredPeakByteCounts: [String: UInt64] = [:]

  func update(isDegraded: Bool) {
    self.isDegraded = isDegraded
    model?.updateSpeechModelPoolMemoryPressureDegradation(isDegraded)
  }

  func recordMeasuredPeak(modelID: String, peakByteCount: UInt64) {
    guard peakByteCount > (measuredPeakByteCounts[modelID] ?? 0) else { return }
    measuredPeakByteCounts[modelID] = peakByteCount
    model?.recordMeasuredSpeechModelPeak(
      modelID: modelID,
      peakByteCount: peakByteCount
    )
  }

  func attach(_ model: AppModel) {
    self.model = model
    model.updateSpeechModelPoolMemoryPressureDegradation(isDegraded)
    for (modelID, peakByteCount) in measuredPeakByteCounts {
      model.recordMeasuredSpeechModelPeak(
        modelID: modelID,
        peakByteCount: peakByteCount
      )
    }
  }
}

@MainActor
private final class CloudProcessingAuthorizationBridge {
  weak var model: AppModel?

  func attach(_ model: AppModel) {
    self.model = model
  }

  func grant(_ authorization: CloudProcessingAuthorization) -> Bool {
    model?.grantCloudProcessingAuthorization(authorization) ?? false
  }
}

@MainActor
private final class LiveAudioCancellationPresentationBridge {
  weak var model: AppModel?

  func attach(_ model: AppModel) {
    self.model = model
  }

  func markStoppedByUser(runID: UUID) {
    model?.markLiveAudioRunStoppedByUser(runID: runID)
  }
}

@MainActor
private enum AppContainerFactory {
  private typealias RecognitionOptionsProvider =
    @Sendable (
      WorkflowDefinition,
      ContextSnapshot
    ) async -> SpeechRecognitionRequestOptions

  private static let keychainServiceIdentifier = "dev.zrr.Rill.credentials"
  private static let webhookKeychainServiceIdentifier = "dev.zrr.Rill.webhook-configuration"
  private static let localDataKeychainServiceIdentifier = "dev.zrr.Rill.local-data-protection"

  static func makeContainer() -> AppContainer {
    let workflowSelectionBridge = WorkflowSelectionBridge()
    let speechPlaybackPresentationBridge = SpeechPlaybackPresentationBridge()
    let speechModelPoolPresentationBridge = SpeechModelPoolPresentationBridge()
    let cloudProcessingAuthorizationBridge = CloudProcessingAuthorizationBridge()
    let liveAudioCancellationPresentationBridge = LiveAudioCancellationPresentationBridge()
    let core = makeCoreServices(
      workflowSelectionBridge: workflowSelectionBridge
    )
    let platform = makePlatformServices(core: core)
    let providers = makeProviderServices(
      core: core,
      platform: platform,
      speechPlaybackPresentationBridge: speechPlaybackPresentationBridge,
      speechModelPoolPresentationBridge: speechModelPoolPresentationBridge
    )
    let registries = makeRegistries(
      core: core,
      platform: platform,
      providers: providers
    )
    let contextMemoryController: ContextMemoryController?
    if let repository = core.persistence.historyRepository as? any ContextMemoryRepository,
       let settingsStore = core.persistence.settingsStore {
      contextMemoryController = ContextMemoryController(
        repository: repository, history: core.persistence.historyRepository, settingsStore: settingsStore,
        providerSettings: providers.openAISettingsProvider, privacySettings: core.privacySettingsSource
      )
    } else { contextMemoryController = nil }
    let runtime = makeRuntimeServices(
      contextMemoryController: contextMemoryController,
      core: core,
      platform: platform,
      providers: providers,
      registries: registries,
      workflowSelectionBridge: workflowSelectionBridge,
      cloudProcessingAuthorizationBridge: cloudProcessingAuthorizationBridge,
      liveAudioCancellationPresentationBridge: liveAudioCancellationPresentationBridge
    )
    let model = AppModelFactory.makeModel(
      core: core,
      platform: platform,
      providers: providers,
      registries: registries,
      runtime: runtime
    )
    contextMemoryController?.installRuntimeIdleCheck {
      [weak coordinator = runtime.coordinator, weak recording = runtime.recordingSessionManager,
       weak workflowRecording = runtime.workflowAudioRunController,
       weak interactive = runtime.capturedAudioProcessingQueue, weak assistant = runtime.assistantAudioProcessingQueue] in
      guard let coordinator, let recording, let workflowRecording, let interactive, let assistant else { return false }
      guard await coordinator.currentState() == .idle, await recording.currentState() == .idle,
            await workflowRecording.isIdle, await interactive.pendingCount == 0,
            await assistant.pendingCount == 0 else { return false }
      return true
    }
    contextMemoryController?.attach(model)
    runtime.workflowSelectionBridge.model = model
    runtime.systemClipboardCaptureControlBridge.model = model
    runtime.globalInputCapabilityBridge.attach(model)
    speechPlaybackPresentationBridge.attach(model)
    speechModelPoolPresentationBridge.attach(model)
    cloudProcessingAuthorizationBridge.attach(model)
    liveAudioCancellationPresentationBridge.attach(model)
    model.updatePermissionSnapshot(platform.permissionGate.snapshot)
    let startupTaskCoordinator = startBackgroundServices(
      model: model,
      core: core,
      platform: platform,
      providers: providers,
      runtime: runtime
    )
    return makeContainer(
      model: model,
      core: core,
      platform: platform,
      providers: providers,
      runtime: runtime,
      startupTaskCoordinator: startupTaskCoordinator
    )
  }

  private static func makeCoreServices(
    workflowSelectionBridge: WorkflowSelectionBridge
  ) -> CoreServices {
    let eventBus = EventBus()
    let persistence = AppPersistence.makeBackends(
      webhookKeychainServiceIdentifier: webhookKeychainServiceIdentifier,
      localDataKeychainServiceIdentifier: localDataKeychainServiceIdentifier
    )
    let diagnostics = DiagnosticsRecorder(
      eventBus: eventBus,
      repository: persistence.diagnosticRepository
    )
    let runReceiptRecorder = WorkflowRunReceiptRecorder(
      repository: persistence.runReceiptRepository ?? UnavailableWorkflowRunReceiptRepository(),
      eventBus: eventBus,
      diagnostics: diagnostics
    )
    let recordCollectionEventScheduler = RecordCollectionEventScheduler(
      receiptRecorder: runReceiptRecorder,
      diagnostics: diagnostics,
      registrationProvider: {
        await MainActor.run {
          workflowSelectionBridge.recordCollectionWorkflowRegistrations()
        }
      }
    )
    let recordStore = RecordStore(
      persistence: persistence.recordGraphPersistenceStore,
      collectionEventSink: recordCollectionEventScheduler
    )
    let recordIngestion = RecordIngestionCoordinator(store: recordStore)
    let recordDelivery = RecordDeliveryCoordinator(store: recordStore)
    let localHistoryMaintenance = persistence.runReceiptRepository.flatMap { repository in
      AppBootstrap.makeLocalHistoryMaintenance(
        recordHistory: recordStore,
        historyRepository: persistence.historyRepository,
        runReceiptRepository: repository,
        diagnosticRepository: diagnostics,
        settingsStore: persistence.settingsStore,
        residuePurger: persistence.residuePurger,
        eventReporter: { event in
          await diagnostics.record(
            AppBootstrap.localHistoryMaintenanceDiagnostic(for: event)
          )
        }
      )
    }
    return CoreServices(
      eventBus: eventBus,
      persistence: persistence,
      diagnostics: diagnostics,
      runReceiptRecorder: runReceiptRecorder,
      recordCollectionEventScheduler: recordCollectionEventScheduler,
      recordStore: recordStore,
      recordIngestion: recordIngestion,
      recordDelivery: recordDelivery,
      localHistoryMaintenance: localHistoryMaintenance,
      candidateResolver: CandidateResolver(eventBus: eventBus, diagnostics: diagnostics),
      vocabularyRuleSource: VocabularyRuleSource(),
      privacySettingsSource: PrivacyPolicySettingsSource()
    )
  }

  private static func makePlatformServices(core: CoreServices) -> PlatformServices {
    let focusTracker = FocusTracker()
    let pasteboard = SystemClipboardPort()
    let hotkeyTap = HotkeyEventTap()
    let injectionEngine = TextInjectionEngine(
      pasteboard: pasteboard,
      diagnosticReporter: { event in
        await core.diagnostics.record(event)
      }
    )
    let cursorTextPreviewCoordinator = CursorTextPreviewCoordinator(
      diagnosticReporter: { diagnostic in
        let textLengthBucket = switch diagnostic.textLength {
        case 0: "empty"
        case 1...16: "1-16"
        case 17...64: "17-64"
        case 65...256: "65-256"
        default: "257+"
        }
        var metadata = [
          "resultCode": diagnostic.resultCode,
          "textLengthBucket": textLengthBucket,
        ]
        if let reason = diagnostic.reason {
          metadata["reason"] = reason
        }
        await core.diagnostics.record(
          DiagnosticEvent(
            runID: diagnostic.runID,
            subsystem: .platform,
            level: diagnostic.resultCode == "blocked" ? .warning : .debug,
            event: "accessibility.cursor-preview",
            message: "Updated the run-scoped cursor preview transaction.",
            metadata: metadata
          )
        )
      }
    )
    let keychainStore = KeychainCredentialStore(service: keychainServiceIdentifier)
    let credentialStore = MigratingSecureCredentialStore(
      secureStore: keychainStore,
      legacySettingsStore: core.persistence.settingsStore,
      eventReporter: { event in
        await core.diagnostics.record(event.diagnosticEvent)
      }
    )
    return PlatformServices(
      focusTracker: focusTracker,
      pasteboard: pasteboard,
      hotkeyTap: hotkeyTap,
      injectionEngine: injectionEngine,
      cursorTextPreviewCoordinator: cursorTextPreviewCoordinator,
      permissionGate: PermissionGate(),
      contextProvider: BuiltinContextProvider(focusTracker: focusTracker, pasteboard: pasteboard),
      credentialStore: credentialStore,
      recordingCuePlayer: RecordingInteractionCuePlayer()
    )
  }

  private static func makeProviderServices(
    core: CoreServices,
    platform: PlatformServices,
    speechPlaybackPresentationBridge: SpeechPlaybackPresentationBridge,
    speechModelPoolPresentationBridge: SpeechModelPoolPresentationBridge
  ) -> ProviderServices
  {
    let jevPolishingSettings = JevPolishingSettingsSource()
    let jevPolishingGate = JevTextPolishingGate(
      settings: jevPolishingSettings, privacy: core.privacySettingsSource,
      currentFocus: {
        await MainActor.run { platform.focusTracker.capturePrivacyIdentitySample().focus }
      })
    let managedTemporaryAudioCleanupOwner = ManagedTemporaryAudioCleanupOwner(
      diagnosticReporter: { diagnostic in
        await core.diagnostics.record(
          DiagnosticEvent(
            runID: diagnostic.runID,
            subsystem: .session,
            level: diagnostic.outcome == .completedAfterRetry ? .info : .warning,
            event: diagnostic.event,
            message: diagnostic.message
          )
        )
      }
    )
    let markdownFileAppendCoordinator = MarkdownFileAppendCoordinator(
      cleanupDiagnosticReporter: { diagnostic in
        await core.diagnostics.record(
          DiagnosticEvent(
            subsystem: .providers,
            level: diagnostic.outcome == .completedAfterRetry ? .info : .warning,
            event: diagnostic.event,
            message: diagnostic.message
          )
        )
      }
    )
    let trustedLocalSpeechModels = AppBootstrap.distributableLocalSpeechModels
    let defaultTrustedModelIdentifier = LocalSpeechModelCatalog.defaultModelIdentifier
    let speechWorkerExecutableURL = AppBootstrap.speechWorkerExecutableURL()
    let speechWorkerIsAvailable = AppBootstrap.speechWorkerExecutableIsAvailable(
      at: speechWorkerExecutableURL
    )
    let localSpeechTrustMaterialIsAvailable = speechWorkerIsAvailable
    let localSpeechAvailability: LocalSpeechAvailability =
      localSpeechTrustMaterialIsAvailable ? .available : .trustMaterialUnavailable
    let localSpeechUnavailableReason = "speech-worker-unavailable"
    let localSpeechStartupDiagnostic = DiagnosticEvent(
      subsystem: .providers,
      level: localSpeechTrustMaterialIsAvailable ? .info : .warning,
      event:
        localSpeechTrustMaterialIsAvailable
        ? "provider.local-speech.available" : "provider.local-speech.unavailable",
      message:
        localSpeechTrustMaterialIsAvailable
        ? "Release-pinned MLX speech worker, Silero VAD, and model catalog are available."
        : "Release-pinned local speech runtime material is unavailable.",
      metadata:
        localSpeechTrustMaterialIsAvailable
        ? [
          "recognizerID": "local-speech",
          "modelCount": String(trustedLocalSpeechModels.count),
          "defaultModel": defaultTrustedModelIdentifier,
          "vadModel": "mlx-community/silero-vad-v6",
          "workerIsolation": "subprocess",
        ]
        : [
          "recognizerID": "local-speech",
          "reason": localSpeechUnavailableReason,
          "vadModel": "mlx-community/silero-vad-v6",
        ]
    )
    let localSpeechSettingsSource = LocalSpeechSettingsSource()
    let openAISettingsProvider: @Sendable () async throws -> OpenAISettings = {
      try await AppSettingsLoader.loadOpenAISettings(
        from: core.persistence.settingsStore,
        credentialStore: platform.credentialStore
      )
    }
    let speechWorkerSupervisor = SpeechWorkerSupervisor(
      configuration: .init(executableURL: speechWorkerExecutableURL)
    )
    let ttsSpeechWorkerSupervisor = SpeechWorkerSupervisor(
      configuration: .init(executableURL: speechWorkerExecutableURL)
    )
    let recordEmbedder = RecordWorkerEmbedder(supervisor: SpeechWorkerSupervisor(
      configuration: .init(executableURL: speechWorkerExecutableURL)))
    let mlxAudioSwiftRecognizer = MLXAudioSwiftWorkerRecognizer(
      supervisor: speechWorkerSupervisor,
      settingsProvider: {
        try localSpeechSettingsSource.currentSettings()
      },
      diagnosticReporter: { event in
        await core.diagnostics.record(event)
      }
    )
    let localSpeechRecognizer = RoutedLocalSpeechRecognizer(
      settingsProvider: {
        try localSpeechSettingsSource.currentSettings()
      },
      backends: [
        mlxAudioSwiftRecognizer,
      ]
    )
    let streamingPreviewService = SpeechWorkerStreamingPreviewService(
      supervisor: speechWorkerSupervisor,
      settingsProvider: {
        try localSpeechSettingsSource.currentSettings()
      },
      measuredPeakObserver: { modelID, peakByteCount in
        await speechModelPoolPresentationBridge.recordMeasuredPeak(
          modelID: modelID,
          peakByteCount: peakByteCount
        )
      }
    )
    let workflowAudioCaptureService = RealtimeAudioCaptureService(
      legacyCaptureService: AVAudioCaptureService(cleanupOwner: managedTemporaryAudioCleanupOwner),
      streamingPreviewService: streamingPreviewService,
      liveUpdateHandler: { snapshot in
        let projected = await platform.cursorTextPreviewCoordinator.project(snapshot)
        await core.eventBus.publish(.liveSubtitleUpdated(projected))
      },
      cleanupOwner: managedTemporaryAudioCleanupOwner,
      wakeWordSpeechStartedHandler: {
        Task { @MainActor in
          platform.recordingCuePlayer.stop()
        }
      }
    )
    let ttsModelSelectionSource = SpeechSynthesisModelSelectionSource()
    let qwen3TTSSynthesizer = Qwen3TTSSpeechSynthesizer(
      supervisor: ttsSpeechWorkerSupervisor,
      selectionSource: ttsModelSelectionSource,
      enabledModelIDsProvider: {
        try localSpeechSettingsSource.currentSettings().enabledModelIDs
      },
      residentModelIDsProvider: {
        try localSpeechSettingsSource.currentSettings().residentModelIDs
      }
    )
    let ttsMemoryPressureSource = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical],
      queue: .global(qos: .utility)
    )
    ttsMemoryPressureSource.setEventHandler {
      let pressure = ttsMemoryPressureSource.data
      Task {
        await qwen3TTSSynthesizer.releaseResources()
        guard pressure.contains(.critical) else { return }
        try? await localSpeechRecognizer.releaseLoadedModel()
        try? await streamingPreviewService.releaseLoadedModels()
        speechModelPoolPresentationBridge.update(isDegraded: true)
      }
    }
    ttsMemoryPressureSource.resume()
    let speechPlaybackService = AVSpeechPlaybackService()
    let wakeWordTriggerSource: WakeWordTriggerSource?
    if let sharedVoiceInputHub = workflowAudioCaptureService.sharedVoiceInputHub {
      wakeWordTriggerSource = WakeWordTriggerSource(
        hub: sharedVoiceInputHub,
        recognizer: localSpeechRecognizer,
        vadSessionFactory: {
          await streamingPreviewService.makeVADSession()
        }
      )
    } else {
      wakeWordTriggerSource = nil
    }
    let speechOutputAction = SpeakTextAction(
      synthesizer: AutomaticSpeechSynthesizer(
        preferred: qwen3TTSSynthesizer,
        fallback: SystemSpeechSynthesizer()
      ),
      playback: speechPlaybackService,
      playbackStateChanged: { isPlaying in
        await speechPlaybackPresentationBridge.update(isActive: isPlaying)
        guard let wakeWordTriggerSource else { return }
        if isPlaying {
          await wakeWordTriggerSource.suspend(for: .speechPlayback)
        } else {
          await wakeWordTriggerSource.resume(from: .speechPlayback)
        }
      }
    )
    return ProviderServices(
      textRewriteTransformer: OpenAITextRewriteTransformer(
        settingsProvider: openAISettingsProvider,
        diagnosticReporter: { event in await core.diagnostics.record(event) }),
      jevPolishingSettings: jevPolishingSettings,
      jevPolishingGate: jevPolishingGate,
      diagnosticsAudioCaptureService: AVAudioCaptureService(
        cleanupOwner: managedTemporaryAudioCleanupOwner
      ),
      managedTemporaryAudioCleanupOwner: managedTemporaryAudioCleanupOwner,
      markdownFileAppendCoordinator: markdownFileAppendCoordinator,
      localSpeechSettingsSource: localSpeechSettingsSource,
      openAISettingsProvider: openAISettingsProvider,
      localSpeechAvailability: localSpeechAvailability,
      trustedLocalSpeechModels: trustedLocalSpeechModels,
      defaultLocalSpeechModelIdentifier: defaultTrustedModelIdentifier,
      localSpeechStartupDiagnostic: localSpeechStartupDiagnostic,
      speechWorkerSupervisor: speechWorkerSupervisor,
      ttsSpeechWorkerSupervisor: ttsSpeechWorkerSupervisor,
      recordEmbedder: recordEmbedder,
      mlxAudioSwiftRecognizer: mlxAudioSwiftRecognizer,
      localSpeechRecognizer: localSpeechRecognizer,
      streamingPreviewService: streamingPreviewService,
      workflowAudioCaptureService: workflowAudioCaptureService,
      wakeWordTriggerSource: wakeWordTriggerSource,
      speechOutputAction: speechOutputAction,
      qwen3TTSSynthesizer: qwen3TTSSynthesizer,
      ttsModelSelectionSource: ttsModelSelectionSource,
      speechPlaybackService: speechPlaybackService,
      ttsMemoryPressureSource: ttsMemoryPressureSource,
      speechModelPoolPresentationBridge: speechModelPoolPresentationBridge
    )
  }

  private static func makeRegistries(
    core: CoreServices,
    platform: PlatformServices,
    providers: ProviderServices
  ) -> Registries {
    return Registries(
      recognizerRegistry: SpeechRecognizerRegistry(
        recognizers: [
          providers.localSpeechRecognizer,
          SelectionCaptureRecognizer(),
        ]
      ),
      transformerRegistry: TextTransformerRegistry(
        transformers: [
          WhitespaceNormalizerTransformer(),
          providers.textRewriteTransformer,
        ]
      ),
      actionRegistry: OutputActionRegistry(
        actions: [
          RecordStoreAction(ingestion: core.recordIngestion),
          SystemClipboardCopyAction(pasteboard: platform.pasteboard),
          FocusedApplicationInsertAction(
            engine: platform.injectionEngine,
            cursorPreviewCoordinator: platform.cursorTextPreviewCoordinator
          ),
          providers.speechOutputAction,
        ]
          + AppBootstrap.makeExternalOutputActions(
            markdownCleanupCoordinator: providers.markdownFileAppendCoordinator
          )
      )
    )
  }

  private static func makeRuntimeServices(
    contextMemoryController: ContextMemoryController?,
    core: CoreServices,
    platform: PlatformServices,
    providers: ProviderServices,
    registries: Registries,
    workflowSelectionBridge: WorkflowSelectionBridge,
    cloudProcessingAuthorizationBridge: CloudProcessingAuthorizationBridge,
    liveAudioCancellationPresentationBridge: LiveAudioCancellationPresentationBridge
  ) -> RuntimeServices {
    var privacyRunGate = makePrivacyRunGate(
      core: core,
      providers: providers,
      authorizationBridge: cloudProcessingAuthorizationBridge
    )
    privacyRunGate.prepareCorrectionContext = { runID, workflow, context, options, lifetime in
      try await contextMemoryController?.prepare(runID: runID, workflow: workflow, context: context, recognitionOptions: options, audioLifetime: lifetime)
    }
    let preparedPrivacyRunGate = privacyRunGate
    let recognitionOptionsProvider: RecognitionOptionsProvider = { workflow, _ in
      let language: String?
      switch workflow.plan.setup.speechRoute?.recognizerID {
      case "local-speech", "sherpa-onnx.local", "sherpa-onnx.streaming", "auto":
        // Local workers resolve workflow overrides and otherwise detect the language.
        language = nil
      default:
        language = AppSettingsLoader.trimmedNonEmpty(
          workflow.metadata[WorkflowMetadataKey.languageOverride]
        )
      }
      return SpeechRecognitionRequestOptions(language: language)
    }
    let recognitionRunPreflight = AppBootstrap.makeRecognitionRunPreflight(
      trustedLocalModelIdentifiers: Set(providers.trustedLocalSpeechModels.map(\.id)),
      defaultLocalModelIdentifier: providers.defaultLocalSpeechModelIdentifier
        ?? LocalSpeechModelCatalog.defaultModelIdentifier,
      localSpeechSettingsProvider: {
        try providers.localSpeechSettingsSource.currentSettings()
      }
    )
    let coordinator = makeCoordinator(
      core: core,
      platform: platform,
      registries: registries,
      textPolishingGate: providers.jevPolishingGate,
      recognitionOptionsProvider: recognitionOptionsProvider,
      recognitionAudioCleanupOwner: providers.managedTemporaryAudioCleanupOwner
    )
    let assistantCoordinator = makeCoordinator(
      lane: .assistant,
      core: core,
      platform: platform,
      registries: registries,
      textPolishingGate: providers.jevPolishingGate,
      recognitionOptionsProvider: recognitionOptionsProvider,
      recognitionAudioCleanupOwner: providers.managedTemporaryAudioCleanupOwner
    )
    let failedAudioRecoveryController = core.persistence.failedAudioRecoveryStore.map { store in
      FailedAudioRecoveryController(
        store: store,
        sessionCoordinator: coordinator,
        eventBus: core.eventBus,
        diagnostics: core.diagnostics,
        privacyRunGate: preparedPrivacyRunGate,
        contextProvider: {
          await platform.contextProvider.captureContext()
        },
        privacyContextProvider: {
          await platform.contextProvider.capturePrivacyContext()
        },
        authorizedContextProvider: { decision in
          await platform.contextProvider.captureContext(applying: decision)
        },
        recognitionOptionsProvider: recognitionOptionsProvider,
        runPreflight: recognitionRunPreflight,
        cleanupRecoveryTemporaryFiles: {
          let report = await core.persistence.temporaryFileCleanupService
            .cleanupRecoveryArtifacts()
          return report.failureCount == 0
        }
      )
    }
    let benchmarkRecordingArchiveController =
      core.persistence.benchmarkRecordingArchiveStore.map { store in
        BenchmarkRecordingArchiveController(
          store: store,
          diagnostics: core.diagnostics
        )
      }
    let queue = CapturedAudioProcessingQueue(
      sessionCoordinator: coordinator,
      eventBus: core.eventBus,
      diagnostics: core.diagnostics,
      failedAudioRecoveryController: failedAudioRecoveryController,
      benchmarkRecordingArchiveController: benchmarkRecordingArchiveController
    )
    let assistantQueue = CapturedAudioProcessingQueue(
      sessionCoordinator: assistantCoordinator,
      eventBus: core.eventBus,
      diagnostics: core.diagnostics,
      benchmarkRecordingArchiveController: benchmarkRecordingArchiveController,
      lane: .assistant,
      publishesSnapshots: false
    )
    let manifestResult = WorkflowManifestResource.load(
      recognizerRegistry: registries.recognizerRegistry,
      transformerRegistry: registries.transformerRegistry,
      actionRegistry: registries.actionRegistry
    )
    let bridge = workflowSelectionBridge
    let systemClipboardCaptureControlBridge = SystemClipboardCaptureControlBridge()
    let globalInputCapabilityBridge = GlobalInputCapabilityBridge()
    let authorizeWorkflowRunAction:
      @Sendable (
        WorkflowDefinition
      ) async throws -> AuthorizedWorkflowRunContext = { workflow in
        if let issue = WorkflowExecutionPolicy.issue(for: workflow) {
          throw SessionCoordinator.SessionError.unsupportedWorkflow(issue)
        }
        try await recognitionRunPreflight(workflow)
        return try await preparedPrivacyRunGate.captureAuthorizedWorkflowRunContext(
          privacyContextProvider: {
            await platform.contextProvider.capturePrivacyContext()
          },
          contextProvider: { decision in
            await platform.contextProvider.captureContext(applying: decision)
          },
          recognitionOptionsProvider: recognitionOptionsProvider,
          workflow: workflow
        )
      }
    let workflowAudioRunController = WorkflowAudioRunController(
      audioCaptureService: providers.workflowAudioCaptureService,
      capturedAudioProcessingQueue: assistantQueue,
      diagnostics: core.diagnostics,
      eventBus: core.eventBus,
      contextProvider: {
        await platform.contextProvider.captureContext()
      },
      privacyContextProvider: {
        await platform.contextProvider.capturePrivacyContext()
      },
      authorizedContextProvider: { decision in
        await platform.contextProvider.captureContext(applying: decision)
      },
      recognitionOptionsProvider: recognitionOptionsProvider,
      runPreflight: recognitionRunPreflight,
      recognizerDurationProvider: { recognizerID in
        registries.recognizerRegistry.recognizer(for: recognizerID)?
          .capabilities.maximumAudioDurationSeconds
      },
      privacyRunGate: preparedPrivacyRunGate,
      cleanupOwner: providers.managedTemporaryAudioCleanupOwner
    )
    let wakeWordCoordinator = providers.wakeWordTriggerSource.map {
      WakeWordCoordinator(
        source: $0,
        workflowSelectionBridge: bridge,
        audioRunController: workflowAudioRunController,
        cuePlayer: platform.recordingCuePlayer,
        eventBus: core.eventBus,
        diagnostics: core.diagnostics,
        runPrefilledCommand: { workflow, event, command in
          let authorizedContext = try await authorizeWorkflowRunAction(workflow)
          await assistantCoordinator.runRecognizedText(
            command,
            runID: event.id,
            triggerEvent: event,
            authorizedContext: authorizedContext
          )
        }
      )
    }
    let cursorTextPreviewLifecycleCoordinator = CursorTextPreviewLifecycleCoordinator(
      eventBus: core.eventBus,
      coordinator: platform.cursorTextPreviewCoordinator
    )
    let recordingSessionManager = makeRecordingManager(
      core: core,
      platform: platform,
      providers: providers,
      queue: queue,
      bridge: bridge,
      privacyRunGate: preparedPrivacyRunGate,
      recognizerRegistry: registries.recognizerRegistry,
      recognitionOptionsProvider: recognitionOptionsProvider,
      runPreflight: recognitionRunPreflight
    )
    let cancelLiveAudio: @Sendable (UUID) async -> Void = { runID in
      await platform.cursorTextPreviewCoordinator.finish(runID: runID)
      await liveAudioCancellationPresentationBridge.markStoppedByUser(runID: runID)
      async let recordingCancellation: Void = recordingSessionManager
        .cancelCurrentRecording(runID: runID)
      async let workflowCancellation: Void = workflowAudioRunController
        .cancelRun(runID: runID)
      _ = await (recordingCancellation, workflowCancellation)
    }
    let globalInputOwner = GlobalInputOwner(
      hotkeyTap: platform.hotkeyTap,
      diagnostics: core.diagnostics,
      permissionChecker: {
        PermissionGate.hasGlobalInputAccess()
      },
      capabilityObserver: { capability in
        await globalInputCapabilityBridge.update(capability)
      },
      liveAudioCancellationHandler: cancelLiveAudio
    )
    return RuntimeServices(
      contextMemoryController: contextMemoryController,
      coordinator: coordinator,
      capturedAudioProcessingQueue: queue,
      assistantAudioProcessingQueue: assistantQueue,
      globalInputOwner: globalInputOwner,
      systemClipboardCaptureController: makeSystemClipboardCaptureController(
        core: core,
        platform: platform,
        coordinator: coordinator,
        captureControlBridge: systemClipboardCaptureControlBridge
      ),
      recordingSessionManager: recordingSessionManager,
      workflowAudioRunController: workflowAudioRunController,
      wakeWordCoordinator: wakeWordCoordinator,
      cursorTextPreviewLifecycleCoordinator: cursorTextPreviewLifecycleCoordinator,
      failedAudioRecoveryController: failedAudioRecoveryController,
      benchmarkRecordingArchiveController: benchmarkRecordingArchiveController,
      privacyRunGate: preparedPrivacyRunGate,
      authorizeWorkflowRunAction: authorizeWorkflowRunAction,
      workflowSelectionBridge: bridge,
      systemClipboardCaptureControlBridge: systemClipboardCaptureControlBridge,
      globalInputCapabilityBridge: globalInputCapabilityBridge,
      workflowManifestStartupDiagnostic: manifestResult.diagnostic,
      workflows: manifestResult.manifest.workflows
    )
  }

  private static func makeCoordinator(
    lane: WorkflowRunLane = .primary,
    core: CoreServices,
    platform: PlatformServices,
    registries: Registries,
    textPolishingGate: any TextPolishingGate,
    recognitionOptionsProvider: @escaping RecognitionOptionsProvider,
    recognitionAudioCleanupOwner: ManagedTemporaryAudioCleanupOwner
  ) -> SessionCoordinator {
    SessionCoordinator(
      contextProvider: platform.contextProvider,
      lane: lane,
      privacyContextProvider: {
        await platform.contextProvider.capturePrivacyContext()
      },
      recognizerRegistry: registries.recognizerRegistry,
      transformerRegistry: registries.transformerRegistry,
      textPolishingGate: textPolishingGate,
      actionRegistry: registries.actionRegistry,
      candidateResolver: core.candidateResolver,
      recordStore: core.recordStore,
      recordDeliveryCoordinator: core.recordDelivery,
      eventBus: core.eventBus,
      diagnostics: core.diagnostics,
      runReceiptRecorder: core.runReceiptRecorder,
      vocabularyRuleProvider: {
        try core.vocabularyRuleSource.currentRules()
      },
      vocabularyCollectionProvider: {
        try core.vocabularyRuleSource.currentCollections()
      },
      recognitionOptionsProvider: recognitionOptionsProvider,
      recognitionAudioCleanupOwner: recognitionAudioCleanupOwner,
      defaultRecordDeliveryActionID: "focused-application.insert"
    )
  }

  private static func makeSystemClipboardCaptureController(
    core: CoreServices,
    platform: PlatformServices,
    coordinator: SessionCoordinator,
    captureControlBridge: SystemClipboardCaptureControlBridge
  ) -> SystemClipboardCaptureController {
    SystemClipboardCaptureController(
      hotkeyTap: platform.hotkeyTap,
      pasteboard: platform.pasteboard,
      recordStore: core.recordStore,
      sessionCoordinator: coordinator,
      eventBus: core.eventBus,
      diagnostics: core.diagnostics,
      privacySettingsProvider: {
        try core.privacySettingsSource.currentSettings()
      },
      focusIdentitySampleProvider: {
        await MainActor.run {
          platform.focusTracker.capturePrivacyIdentitySample()
        }
      },
      captureControlStateObserver: { snapshot in
        await captureControlBridge.update(snapshot)
      }
    )
  }

  private static func makeRecordingManager(
    core: CoreServices,
    platform: PlatformServices,
    providers: ProviderServices,
    queue: CapturedAudioProcessingQueue,
    bridge: WorkflowSelectionBridge,
    privacyRunGate: PrivacyRunGate,
    recognizerRegistry: SpeechRecognizerRegistry,
    recognitionOptionsProvider: @escaping RecognitionOptionsProvider,
    runPreflight: @escaping RecognitionRunPreflight
  ) -> RecordingSessionManager {
    RecordingSessionManager(
      audioCaptureService: providers.workflowAudioCaptureService,
      hotkeyTap: platform.hotkeyTap,
      capturedAudioProcessingQueue: queue,
      eventBus: core.eventBus,
      diagnostics: core.diagnostics,
      privacyRunGate: privacyRunGate,
      workflowProvider: {
        await MainActor.run {
          bridge.enabledWorkflows(for: .hotkey)
        }
      },
      contextProvider: {
        await platform.contextProvider.captureContext()
      },
      privacyContextProvider: {
        await platform.contextProvider.capturePrivacyContext()
      },
      focusIdentitySampleProvider: {
        await MainActor.run {
          platform.focusTracker.capturePrivacyIdentitySample()
        }
      },
      targetBoundAuthorizedContextProvider: { decision, expectedFocus in
        await platform.contextProvider.captureContext(
          applying: decision,
          ifFocusMatches: expectedFocus
        )
      },
      recognitionOptionsProvider: recognitionOptionsProvider,
      runPreflight: runPreflight,
      longRecordingModeProvider: {
        await MainActor.run {
          bridge.longRecordingModeEnabled()
        }
      },
      recognizerDurationProvider: { recognizerID in
        recognizerRegistry.recognizer(for: recognizerID)?
          .capabilities.maximumAudioDurationSeconds
      },
      cleanupOwner: providers.managedTemporaryAudioCleanupOwner,
      recordingCueAction: { cue, token in
        await MainActor.run {
          token.performIfValid {
            NSHapticFeedbackManager.defaultPerformer.perform(
              cue == .started ? .alignment : .generic,
              performanceTime: .now
            )
          }
        }
      }
    )
  }

  private static func makePrivacyRunGate(
    core: CoreServices,
    providers: ProviderServices,
    authorizationBridge: CloudProcessingAuthorizationBridge
  ) -> PrivacyRunGate {
    PrivacyRunGate(
      settingsProvider: {
        try core.privacySettingsSource.currentSettings()
      },
      cloudConfirmationProvider: { workflow, _, processingDestinations in
        var providerIdentities: [String] = []
        if processingDestinations.contains(.cloudText) {
          do {
            let settings = try await providers.openAISettingsProvider()
            providerIdentities.append(
              cloudAuthorizationScopeIdentity([
                LLMTextProcessing.providerID,
                settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                settings.model.trimmingCharacters(in: .whitespacesAndNewlines),
                settings.apiKey,
              ])
            )
          } catch {
            // Keep this failure state in the scope. Once provider settings are
            // available, its fingerprint changes and Rill asks again.
            providerIdentities.append("cloud-text.configuration-unavailable")
          }
        }
        if processingDestinations.contains(.cloudSpeech) {
          let route = workflow.plan.setup.speechRoute
          providerIdentities.append(
            cloudAuthorizationScopeIdentity([
              "cloud-speech",
              route?.recognizerID ?? "unavailable",
              route?.providerModel ?? "",
            ])
          )
        }

        let authorization = try? CloudProcessingAuthorization(
          workflow: workflow,
          processingDestinations: processingDestinations,
          providerIdentities: providerIdentities
        )
        if let settings = try? core.privacySettingsSource.currentSettings(),
          settings.cloudProcessingAuthorizations.contains(where: {
            $0.authorizes(
              workflow: workflow,
              processingDestinations: processingDestinations,
              providerIdentities: providerIdentities
            )
          })
        {
          return true
        }

        let response = await MainActor.run {
          CloudPrivacyConfirmation.confirm(
            workflow: workflow,
            processingDestinations: processingDestinations
          )
        }
        switch response {
        case .cancel:
          return false
        case .allowOnce:
          return true
        case .alwaysAllow:
          guard let authorization else { return true }
          _ = await MainActor.run {
            authorizationBridge.grant(authorization)
          }
          return true
        }
      }
    )
  }

  nonisolated private static func cloudAuthorizationScopeIdentity(
    _ components: [String]
  ) -> String {
    components
      .map { "\($0.utf8.count):\($0)" }
      .joined(separator: "|")
  }

  private static func startBackgroundServices(
    model: AppModel,
    core: CoreServices,
    platform: PlatformServices,
    providers: ProviderServices,
    runtime: RuntimeServices
  ) -> ApplicationStartupTaskCoordinator {
    let temporaryFileCleanupService = core.persistence.temporaryFileCleanupService
    let diagnostics = core.diagnostics
    return ApplicationStartupTaskCoordinator(
      operations: [
        {
          await runtime.cursorTextPreviewLifecycleCoordinator.start()
        },
        {
          // Remove credentials and settings retained only for one-way cleanup
          // after the local-speech and cloud-ASR provider cutovers.
          guard !Task.isCancelled else { return }
          try? await platform.credentialStore.removeCredential(
            for: .legacyWhisperKitModelToken
          )
          await AppBootstrap.purgeRetiredCloudSpeechConfiguration(
            credentialStore: platform.credentialStore,
            settingsStore: core.persistence.settingsStore
          )
        },
        {
          guard !Task.isCancelled else { return }
          await diagnostics.record(runtime.workflowManifestStartupDiagnostic)
        },
        {
          let event = await AppBootstrap.runStartupTemporaryFileCleanup(
            using: temporaryFileCleanupService
          )
          guard !Task.isCancelled else { return }
          await diagnostics.record(event)
        },
        {
          let isEnabled: Bool
          do {
            isEnabled =
              try await core.persistence.settingsStore?.string(
                forKey: .failedAudioRecoveryEnabled
              ) == "true"
          } catch {
            // The opt-in cannot be proven, so encrypted recovery artifacts
            // are cleared and no recognition is started.
            isEnabled = false
          }
          guard !Task.isCancelled else { return }
          guard let controller = runtime.failedAudioRecoveryController else {
            if isEnabled {
              await diagnostics.record(
                DiagnosticEvent(
                  subsystem: .platform,
                  level: .error,
                  event: "audio-recovery.storage-unavailable",
                  message:
                    "Failed recording recovery is enabled, but protected storage is unavailable.",
                  metadata: ["runtime": "disabled"]
                )
              )
            } else {
              do {
                let directoryURL =
                  try EncryptedFailedAudioRecoveryStore
                  .defaultDirectoryURL()
                try EncryptedFailedAudioRecoveryStore
                  .deleteOwnedArtifactsWithoutOpening(directoryURL: directoryURL)
              } catch {
                guard !Task.isCancelled else { return }
                await diagnostics.record(
                  DiagnosticEvent(
                    subsystem: .platform,
                    level: .warning,
                    event: "audio-recovery.opt-out-cleanup-failed",
                    message: "Disabled failed recording recovery artifacts could not be removed.",
                    metadata: ["reason": "storage-unavailable"]
                  )
                )
              }
            }
            return
          }
          do {
            try await controller.refresh(isEnabled: isEnabled)
          } catch {
            guard !Task.isCancelled else { return }
            await diagnostics.record(
              DiagnosticEvent(
                subsystem: .platform,
                level: .warning,
                event: "audio-recovery.startup-failed",
                message: "Failed recording recovery maintenance could not complete.",
                metadata: ["reason": "storage-unavailable"]
              )
            )
          }
        },
        {
          let isEnabled: Bool
          do {
            isEnabled =
              try await core.persistence.settingsStore?.string(
                forKey: .benchmarkRecordingArchiveEnabled
              ) == "true"
          } catch {
            // Retention is opt-in. A setting that cannot be read must not start
            // preserving new recordings, but existing encrypted artifacts stay
            // untouched until the user explicitly clears them.
            isEnabled = false
          }
          guard !Task.isCancelled else { return }
          guard let controller = runtime.benchmarkRecordingArchiveController else {
            if isEnabled {
              await diagnostics.record(
                DiagnosticEvent(
                  subsystem: .platform,
                  level: .error,
                  event: "benchmark-recording.storage-unavailable",
                  message:
                    "Benchmark recording retention is enabled, but protected storage is unavailable.",
                  metadata: ["runtime": "disabled"]
                )
              )
            }
            return
          }
          await controller.refresh(isEnabled: isEnabled)
        },
        {
          if let startupDiagnostic = core.persistence.startupDiagnostic {
            await core.diagnostics.record(startupDiagnostic)
          }
          guard !Task.isCancelled else { return }
          await core.diagnostics.record(providers.localSpeechStartupDiagnostic)
        },
        {
          // Subscribe every shared-hotkey consumer before the event tap is
          // installed. AsyncStream has no replay for an event emitted before a
          // continuation exists, so concurrent startup could otherwise drop
          // the first Fn press while already reporting global input as ready.
          await GlobalInputStartupSequence.run(
            startRecordingConsumer: {
              await runtime.recordingSessionManager.start()
            },
            waitForVoiceConfiguration: {
              await model.waitForInitialVoiceConfiguration()
            },
            startClipboardConsumer: { systemClipboardCaptureEnabled in
              await runtime.systemClipboardCaptureController.start(
                initialClipboardCaptureEnabled: systemClipboardCaptureEnabled,
                preferenceRevision: 0
              )
            },
            startSharedInputProducer: {
              await runtime.globalInputOwner.start()
            }
          )
        },
        {
          await model.waitForInitialVoiceConfiguration()
          guard !Task.isCancelled else { return }
          await runtime.wakeWordCoordinator?.start()
        },
      ]
    )
  }

  private static func makeContainer(
    model: AppModel,
    core: CoreServices,
    platform: PlatformServices,
    providers: ProviderServices,
    runtime: RuntimeServices,
    startupTaskCoordinator: ApplicationStartupTaskCoordinator
  ) -> AppContainer {
    AppContainer(
      model: model,
      globalInputOwner: runtime.globalInputOwner,
      systemClipboardCaptureController: runtime.systemClipboardCaptureController,
      recordingSessionManager: runtime.recordingSessionManager,
      shutdown: ApplicationShutdownOperation.make(
        sealMarkdownPostCommitCleanups: {
          await providers.markdownFileAppendCoordinator.seal()
        },
        sealRecordMutations: {
          await model.sealRecordMutationsForApplicationShutdown()
        },
        stopStartupTasks: {
          await AppBootstrap.stopStartupTasks(
            coordinator: startupTaskCoordinator
          )
        },
        stopSettingsReads: {
          await runtime.contextMemoryController?.shutdown()
          await model.stopSettingsReadTasksForApplicationShutdown()
        },
        drainRecordMutations: {
          await model.drainRecordMutationsForApplicationShutdown()
        },
        cancelRecording: {
          await runtime.recordingSessionManager.stopForApplicationShutdown()
        },
        cancelWorkflowRun: {
          await runtime.wakeWordCoordinator?.shutdown()
          async let audioRunCancellation: Void = runtime.workflowAudioRunController.shutdown()
          async let interactiveRunCancellation: Void =
            model
            .stopInteractiveWorkflowRunsForApplicationShutdown()
          _ = await (audioRunCancellation, interactiveRunCancellation)
          await runtime.cursorTextPreviewLifecycleCoordinator.shutdown()
        },
        cancelFailedAudioRecoveryRetries: {
          await model.stopFailedAudioRecoveryRetriesForApplicationShutdown()
          await runtime.failedAudioRecoveryController?.stopForApplicationShutdown()
        },
        stopLocalHistoryMaintenance: {
          await model.stopLocalHistoryMaintenanceForApplicationShutdown()
        },
        shutdownAudioQueue: {
          async let interactiveQueueShutdown: Void =
            runtime.capturedAudioProcessingQueue.shutdown()
          async let assistantQueueShutdown: Void =
            runtime.assistantAudioProcessingQueue.shutdown()
          _ = await (interactiveQueueShutdown, assistantQueueShutdown)
          await providers.jevPolishingGate.shutdown()
          await providers.textRewriteTransformer.shutdown()
        },
        shutdownSpeechPlayback: {
          providers.ttsMemoryPressureSource.cancel()
          await providers.speechPlaybackService.shutdown()
          await providers.qwen3TTSSynthesizer.releaseResources()
          try? await providers.ttsSpeechWorkerSupervisor.shutdown()
        },
        drainTextInjectionSystemClipboardRecovery: {
          await platform.injectionEngine
            .drainPendingClipboardRecoveryForApplicationShutdown()
        },
        stopSystemClipboardCapture: {
          await runtime.systemClipboardCaptureController.stop()
          await runtime.coordinator.shutdownRecordDeliverySettlements()
        },
        stopGlobalInputOwner: {
          await runtime.globalInputOwner.stop()
        },
        stopRecordCollectionScheduler: {
          await core.recordStore.setRecordCollectionEventSink(nil)
          await core.recordCollectionEventScheduler.shutdown()
        },
        drainMarkdownPostCommitCleanups: {
          await providers.markdownFileAppendCoordinator.sealAndDrain()
        },
        stopLocalSpeechPreparation: {
          await model.stopLocalSpeechPreparationForApplicationShutdown()
        },
        stopEventListener: {
          await model.drainAndStopEventListenerForApplicationShutdown()
        },
        flushPersistence: {
          await model.drainPendingSettingsWritesForApplicationShutdown()
        }
      ),
      setLiveAudioEscapeCancellationRunID: { runID in
        platform.hotkeyTap.setLiveAudioEscapeCancellationRunID(runID)
      },
      removeLiveAudioDurationLimit: { runID in
        async let recordingRemoval = runtime.recordingSessionManager
          .removeMaximumDurationLimit(runID: runID)
        async let workflowRemoval = runtime.workflowAudioRunController
          .removeMaximumDurationLimit(runID: runID)
        let results = await (recordingRemoval, workflowRemoval)
        return results.0 || results.1
      },
      setSystemClipboardCaptureEnabled: { isEnabled, preferenceRevision in
        Task {
          await runtime.systemClipboardCaptureController.setSystemClipboardCaptureEnabled(
            isEnabled,
            preferenceRevision: preferenceRevision
          )
        }
      },
      ignoreNextExternalClipboardChange: {
        Task {
          await runtime.systemClipboardCaptureController.ignoreNextExternalClipboardChange()
        }
      },
      updateRecordPanelHotkey: { binding in
        platform.hotkeyTap.setRecordPanelHotkeyBinding(binding)
      },
      beginRecordPanelShortcutRecording: {
        platform.hotkeyTap.beginRecordPanelShortcutRecording()
      },
      endRecordPanelShortcutRecording: { suspensionID in
        platform.hotkeyTap.endRecordPanelShortcutRecording(suspensionID)
      },
      commitRecordPanelShortcutRecording: { suspensionID, keyCode in
        platform.hotkeyTap.commitRecordPanelShortcutRecording(
          suspensionID,
          keyCode: keyCode
        )
      }
    )
  }
}

@MainActor
private enum AppModelFactory {
  static func makeModel(
    core: CoreServices,
    platform: PlatformServices,
    providers: ProviderServices,
    registries: Registries,
    runtime: RuntimeServices
  ) -> AppModel {
    var model: AppModel?
    model = AppModel(
      workflows: runtime.workflows,
      eventBus: core.eventBus,
      sessionCoordinator: runtime.coordinator,
      outputActionRegistry: registries.actionRegistry,
      recordWorkspace: RecordWorkspaceModel(store: core.recordStore,
        semanticSearch: RecordSemanticSearch(store: core.recordStore, embedder: providers.recordEmbedder),
        cloudRanking: RecordCloudRanking(store: core.recordStore, provider: JevRecordRankingProvider(),
          privacy: core.privacySettingsSource, currentFocus: {
            await MainActor.run { platform.focusTracker.capturePrivacyIdentitySample().focus }
          })),
      jevPolishingSettingsSource: providers.jevPolishingSettings,
      candidateResolver: core.candidateResolver,
      historyRepository: core.persistence.historyRepository,
      runHistoryBrowser: core.persistence.runHistoryBrowser,
      runReceiptRepository: core.persistence.runReceiptRepository,
      localHistoryMaintenance: core.localHistoryMaintenance,
      diagnosticRepository: core.persistence.diagnosticRepository,
      settingsStore: core.persistence.settingsStore,
      workflowFileStore: XDGWorkflowFileStore(),
      credentialStore: platform.credentialStore,
      localPersistenceStatus: core.persistence.localPersistenceStatus,
      vocabularyRuleSource: core.vocabularyRuleSource,
      privacySettingsSource: core.privacySettingsSource,
      localSpeechSettingsSource: providers.localSpeechSettingsSource,
      localSpeechAvailability: providers.localSpeechAvailability,
      trustedLocalSpeechModels: providers.trustedLocalSpeechModels,
      defaultLocalSpeechModelIdentifier: providers.defaultLocalSpeechModelIdentifier,
      ttsModelOptions: AppBootstrap.ttsModelOptions,
      defaultTTSModelIdentifier: SpeechSynthesisModelCatalog.defaultModel.id.rawValue,
      prepareLocalSpeechAction: { settings, progressCallback in
        do {
          let modelIdentifier = LocalSpeechModelCatalog.effectiveModelIdentifier(
            settings: settings
          )
          let backend = try LocalSpeechModelCatalog.backend(for: modelIdentifier)
          return try await AppBootstrap.prepareLocalSpeechModel(
            prepareModel: {
              try await providers.localSpeechRecognizer.prepareForUse(of: backend)
              let preparedModel = try await providers.mlxAudioSwiftRecognizer.prepareModel(
                modelIdentifier: modelIdentifier,
                downloadIfNeeded: settings.downloadIfNeeded,
                progress: { update in
                  progressCallback(AppBootstrap.localSpeechPreparationProgress(update))
                }
              )
              return preparedModel
            }
          )
        } catch {
          guard let failure = AppBootstrap.localSpeechPreparationFailure(for: error) else {
            throw CancellationError()
          }
          throw failure
        }
      },
      synchronizeResidentSpeechModelsAction: { addedModelIDs, removedModelIDs in
        var hadFailure = false
        for modelID in removedModelIDs.sorted() {
          if MLXAudioModelCatalog.distributableModelIdentifiers.contains(modelID) {
            try? await providers.speechWorkerSupervisor.releaseModel(modelID: modelID)
          } else if SpeechSynthesisModelCatalog.supportedModelIdentifiers.contains(modelID) {
            try? await providers.ttsSpeechWorkerSupervisor.releaseTTSModel(modelID: modelID)
          }
        }

        for modelID in addedModelIDs.sorted() {
          do {
            if MLXAudioModelCatalog.distributableModelIdentifiers.contains(modelID) {
              _ = try await providers.mlxAudioSwiftRecognizer.prepareModel(
                modelIdentifier: modelID,
                downloadIfNeeded: true
              )
            } else if SpeechSynthesisModelCatalog.supportedModelIdentifiers.contains(modelID) {
              try await providers.qwen3TTSSynthesizer.prepare(
                modelIdentifier: modelID,
                downloadIfNeeded: true
              )
            }
          } catch is CancellationError {
            return
          } catch {
            hadFailure = true
            await core.diagnostics.record(
              DiagnosticEvent(
                subsystem: .providers,
                level: .warning,
                event: "provider.speech-model.resident-load-failed",
                message: "A resident speech model could not be loaded.",
                metadata: ["modelID": modelID]
              )
            )
          }
        }
        if !addedModelIDs.isEmpty, !hadFailure {
          await providers.speechModelPoolPresentationBridge.update(isDegraded: false)
        }
      },
      prepareEnabledSpeechModelAction: { modelID in
        do {
          if MLXAudioModelCatalog.distributableModelIdentifiers.contains(modelID) {
            _ = try await providers.mlxAudioSwiftRecognizer.prepareModel(
              modelIdentifier: modelID,
              downloadIfNeeded: true
            )
            let remainsResident =
              (try? providers.localSpeechSettingsSource.currentSettings())?
              .residentModelIDs.contains(modelID) == true
            if !remainsResident {
              try? await providers.speechWorkerSupervisor.releaseModel(modelID: modelID)
            }
          } else if SpeechSynthesisModelCatalog.supportedModelIdentifiers.contains(modelID) {
            try await providers.qwen3TTSSynthesizer.prepare(
              modelIdentifier: modelID,
              downloadIfNeeded: true
            )
            let residentModelIDs =
              (try? providers.localSpeechSettingsSource.currentSettings())?
              .residentModelIDs ?? []
            let remainsResident = residentModelIDs.contains(modelID)
            if !remainsResident {
              try? await providers.ttsSpeechWorkerSupervisor.releaseTTSModel(modelID: modelID)
              let residentTTSModelIDs = residentModelIDs.intersection(
                SpeechSynthesisModelCatalog.supportedModelIdentifiers
              )
              if residentTTSModelIDs.isEmpty {
                try? await providers.ttsSpeechWorkerSupervisor.releaseLoadedModel()
              }
            }
          }
        } catch is CancellationError {
          return
        } catch {
          await core.diagnostics.record(
            DiagnosticEvent(
              subsystem: .providers,
              level: .warning,
              event: "provider.speech-model.download-failed",
              message: "An enabled speech model could not be downloaded.",
              metadata: ["modelID": modelID]
            )
          )
        }
      },
      setLocalSpeechRuntimeEnabledAction: { isEnabled in
        if !isEnabled {
          Task {
            try? await providers.localSpeechRecognizer.releaseLoadedModel()
            try? await providers.streamingPreviewService.releaseLoadedModels()
          }
        }
      },
      releaseLocalSpeechRuntimeAction: {
        Task {
          try? await providers.localSpeechRecognizer.releaseLoadedModel()
          try? await providers.streamingPreviewService.releaseLoadedModels()
        }
      },
      stopLocalSpeechRuntimeAction: {
        do {
          try await providers.localSpeechRecognizer.stopRuntime()
        } catch {
          await core.diagnostics.record(
            DiagnosticEvent(
              subsystem: .providers,
              level: .error,
              event: "provider.local-speech.worker-shutdown-failed",
              message: "A local speech worker could not be confirmed stopped.",
              metadata: ["workerIsolation": "subprocess"]
            )
          )
        }
        try? await providers.streamingPreviewService.releaseLoadedModels()
      },
      startWorkflowAudioRunAction: { workflow, binding in
        try await runtime.workflowAudioRunController.startRun(workflow: workflow, binding: binding)
      },
      finishWorkflowAudioRunAction: {
        try await runtime.workflowAudioRunController.finishRun()
      },
      verifyOpenAIConfigurationAction: { settings in
        try await OpenAIConfigurationVerifier.verify(
          settings: settings,
          diagnosticReporter: { event in
            await core.diagnostics.record(event)
          }
        )
      },
      retryFailedAudioRecoveryAction: { receiptID, workflow in
        guard let controller = runtime.failedAudioRecoveryController else {
          throw FailedAudioRecoveryError.storageUnavailable
        }
        return try await controller.retry(id: receiptID, workflow: workflow)
      },
      deleteFailedAudioRecoveryAction: { receiptID in
        guard let controller = runtime.failedAudioRecoveryController else {
          throw FailedAudioRecoveryError.storageUnavailable
        }
        try await controller.delete(id: receiptID)
      },
      clearFailedAudioRecoveryAction: {
        guard let controller = runtime.failedAudioRecoveryController else {
          throw FailedAudioRecoveryError.storageUnavailable
        }
        try await controller.deleteAll()
      },
      refreshFailedAudioRecoveryAction: { isEnabled in
        guard let controller = runtime.failedAudioRecoveryController else {
          throw FailedAudioRecoveryError.storageUnavailable
        }
        try await controller.refresh(isEnabled: isEnabled)
      },
      loadFailedAudioRecoveryReceiptsAction: {
        guard let controller = runtime.failedAudioRecoveryController else {
          throw FailedAudioRecoveryError.storageUnavailable
        }
        return try await controller.currentReceipts()
      },
      clearBenchmarkRecordingArchiveAction: {
        guard let controller = runtime.benchmarkRecordingArchiveController else {
          throw BenchmarkRecordingArchiveError.storageUnavailable
        }
        try await controller.deleteAll()
      },
      refreshBenchmarkRecordingArchiveAction: { isEnabled in
        guard let controller = runtime.benchmarkRecordingArchiveController else {
          throw BenchmarkRecordingArchiveError.storageUnavailable
        }
        await controller.refresh(isEnabled: isEnabled)
      },
      authorizeWorkflowRunAction: runtime.authorizeWorkflowRunAction,
      explainResolvedWorkflowAction: AppBootstrap.makeWorkflowExplanationAction(
        service: WorkflowExplainService(
          recognizerRegistry: registries.recognizerRegistry,
          transformerRegistry: registries.transformerRegistry,
          actionRegistry: registries.actionRegistry
        ),
        privacyRunGate: runtime.privacyRunGate,
        privacyContextProvider: {
          await platform.contextProvider.capturePrivacyContext()
        }
      ),
      writeClipboardTextAction: { text in
        _ = platform.pasteboard.writePlainText(text)
      },
      deliverNextRecordAction: {
        Task { await runtime.systemClipboardCaptureController.deliverNextRecord() }
      },
      permissionSnapshot: platform.permissionGate.snapshot,
      refreshPermissionsAction: {
        platform.permissionGate.refresh()
        model?.updatePermissionSnapshot(platform.permissionGate.snapshot)
        Task {
          await runtime.globalInputOwner.retryInstallation()
        }
      },
      requestAccessibilityAction: {
        platform.permissionGate.requestAccessibilityAccess()
        model?.updatePermissionSnapshot(platform.permissionGate.snapshot)
      },
      requestMicrophoneAction: {
        platform.permissionGate.requestMicrophoneAccess { snapshot in
          model?.updatePermissionSnapshot(snapshot)
        }
      },
      openAccessibilitySettingsAction: {
        platform.permissionGate.openAccessibilitySettings()
      },
      openMicrophoneSettingsAction: {
        platform.permissionGate.openMicrophoneSettings()
      },
      requestGlobalInputAction: {
        _ = platform.permissionGate.requestGlobalInputAccess()
        Task { await runtime.globalInputOwner.retryInstallation() }
      },
      retryGlobalInputAction: {
        Task { await runtime.globalInputOwner.retryInstallation() }
      },
      workflowLibraryChangedAction: {
        Task { await runtime.wakeWordCoordinator?.reconcile() }
      }
    )
    guard let resolvedModel = model else {
      preconditionFailure("AppModel was not initialized")
    }
    resolvedModel.installVoiceAssistantResourceActions(
      prepareWakeWordModel: { progressCallback in
        guard providers.wakeWordTriggerSource != nil else {
          throw WakeWordTriggerSourceError.modelNotInstalled
        }
        let settings = try providers.localSpeechSettingsSource.currentSettings()
        let modelIdentifier = LocalSpeechModelCatalog.effectiveModelIdentifier(
          settings: settings
        )
        let backend = try LocalSpeechModelCatalog.backend(for: modelIdentifier)
        try await providers.localSpeechRecognizer.prepareForUse(of: backend)
        let prepared = try await providers.mlxAudioSwiftRecognizer.prepareModel(
          modelIdentifier: modelIdentifier,
          downloadIfNeeded: true,
          progress: { update in
            progressCallback(update.fractionCompleted)
          }
        )
        progressCallback(1)
        return prepared
      },
      prepareTTSModel: { modelIdentifier, progressCallback in
        try await providers.qwen3TTSSynthesizer.prepare(
          modelIdentifier: modelIdentifier,
          downloadIfNeeded: true,
          progress: { update in
            progressCallback(AppBootstrap.displayedTTSPreparationProgress(update))
          }
        )
      },
      selectTTSModel: { modelIdentifier in
        _ = providers.ttsModelSelectionSource.selectModel(modelIdentifier)
      },
      downloadedTTSModelIdentifiers:
        SpeechSynthesisModelInventory.installedModelIdentifiers(),
      validateWakeWordConfiguration: { configuration in
        guard let source = providers.wakeWordTriggerSource else {
          throw WakeWordTriggerSourceError.modelNotInstalled
        }
        try await source.validate(configuration: configuration)
      },
      stopSpeechPlayback: {
        guard providers.speechPlaybackService.isPlaying else { return false }
        Task { @MainActor in
          await providers.speechPlaybackService.shutdown()
        }
        return true
      }
    )
    if let wakeWordTriggerSource = providers.wakeWordTriggerSource {
      Task { @MainActor [weak resolvedModel] in
        for await status in wakeWordTriggerSource.statusStream() {
          guard !Task.isCancelled, let resolvedModel else { return }
          let presentation: WakeWordRuntimePresentationState
          switch status {
          case .disabled:
            presentation = .disabled
          case .modelMissing:
            presentation = .modelMissing
          case .starting:
            presentation = .starting
          case .listening:
            presentation = .listening
          case .suspended(let reason):
            presentation = .suspended(reason.rawValue)
          case .failed(let message):
            presentation = .failed(message)
          }
          resolvedModel.updateWakeWordRuntimeState(presentation)
        }
      }
    }
    return resolvedModel
  }
}

private enum AppPersistence {
  static func makeBackends(
    webhookKeychainServiceIdentifier: String,
    localDataKeychainServiceIdentifier: String
  ) -> PersistenceBackends {
    let temporaryFileCleanupService = RillTemporaryFileCleanupService()
    do {
      let databaseURL = try SQLitePersistenceStore.defaultDatabaseURL()
      try SQLitePersistenceStore.preparePrivateStorage(at: databaseURL)
      let recoveryDirectoryURL =
        try EncryptedFailedAudioRecoveryStore
        .defaultDirectoryURL()
      let benchmarkArchiveDirectoryURL =
        try EncryptedBenchmarkRecordingArchiveStore
        .defaultDirectoryURL()
      let databaseRequiresExistingKey =
        try SQLitePersistenceStore
        .requiresExistingDataProtectionKey(databaseURL: databaseURL)
      let recoveryRequiresExistingKey =
        EncryptedFailedAudioRecoveryStore
        .requiresExistingDataProtectionKey(directoryURL: recoveryDirectoryURL)
      let archiveRequiresExistingKey =
        EncryptedBenchmarkRecordingArchiveStore
        .requiresExistingDataProtectionKey(directoryURL: benchmarkArchiveDirectoryURL)
      let keyStore = KeychainLocalDataKeyStore(
        service: localDataKeychainServiceIdentifier
      )
      let keyDecision = try LocalDataKeyResolver.resolve(
        candidates: keyStore.loadCandidates(),
        databaseRequiresExistingKey: databaseRequiresExistingKey,
        recoveryRequiresExistingKey: recoveryRequiresExistingKey,
        archiveRequiresExistingKey: archiveRequiresExistingKey,
        databaseAccepts: { key in
          try databaseAccepts(
            key: key,
            databaseURL: databaseURL
          )
        },
        recoveryAccepts: { key in
          try recoveryAccepts(
            key: key,
            directoryURL: recoveryDirectoryURL
          )
        },
        archiveAccepts: { key in
          try archiveAccepts(
            key: key,
            directoryURL: benchmarkArchiveDirectoryURL
          )
        }
      )
      let selectedKey =
        switch keyDecision {
        case .existing(let candidate):
          candidate
        case .generateFresh:
          try keyStore.generateFreshKey()
        }
      let localDataProtector = try AESGCMDataProtector(key: selectedKey.key)
      let store = try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: localDataProtector
      )
      try SQLitePersistenceStore.preparePrivateStorage(at: databaseURL)
      // Candidate selection used an earlier filesystem snapshot. Recheck before
      // finalization so a binding that appeared concurrently cannot invalidate
      // the selected root key. Root keys are never deleted automatically.
      try revalidateCurrentBindings(
        candidate: selectedKey,
        databaseURL: databaseURL,
        recoveryDirectoryURL: recoveryDirectoryURL,
        benchmarkArchiveDirectoryURL: benchmarkArchiveDirectoryURL
      )
      let failedAudioRecoveryStore = try EncryptedFailedAudioRecoveryStore(
        directoryURL: recoveryDirectoryURL,
        localDataProtector: localDataProtector
      )
      let benchmarkRecordingArchiveStore = try EncryptedBenchmarkRecordingArchiveStore(
        directoryURL: benchmarkArchiveDirectoryURL,
        localDataProtector: localDataProtector
      )
      let keyFinalization = try keyStore.finalizeValidatedKey(selectedKey)
      // Do not publish durable storage as ready if a recovery binding appeared
      // during finalization. The distinct legacy key remains available for it.
      try revalidateCurrentBindings(
        candidate: selectedKey,
        databaseURL: databaseURL,
        recoveryDirectoryURL: recoveryDirectoryURL,
        benchmarkArchiveDirectoryURL: benchmarkArchiveDirectoryURL
      )
      let localPersistenceStatus: LocalPersistenceStatus
      let keychainKeyState: String
      let startupDiagnosticLevel: DiagnosticLevel
      let startupDiagnosticMessage: String
      switch keyFinalization.additionalKeyStatus {
      case .none:
        localPersistenceStatus = .ready
        keychainKeyState = "single-key"
        startupDiagnosticLevel = .info
        startupDiagnosticMessage = "SQLite persistence is active."
      case .matchingLegacyKeyRetained:
        localPersistenceStatus = .ready
        keychainKeyState = "matching-key-retained"
        startupDiagnosticLevel = .info
        startupDiagnosticMessage =
          "SQLite persistence is active with a matching legacy key retained for safety."
      case .alternateKeyRetained:
        localPersistenceStatus = .readyWithNotice(
          .alternateDataProtectionKeyRetained
        )
        keychainKeyState = "alternate-key-retained"
        startupDiagnosticLevel = .warning
        startupDiagnosticMessage =
          "SQLite persistence is active with an alternate protection key retained for safety."
      }
      let protectedSettingsStore = WebhookProtectingSettingsStore(
        settingsStore: store,
        secureStore: KeychainWebhookConfigurationStore(
          service: webhookKeychainServiceIdentifier
        ),
        eventReporter: { event in
          try? await store.save(DiagnosticEventSanitizer.sanitize(event.diagnosticEvent))
        }
      )
      return PersistenceBackends(
        localPersistenceStatus: localPersistenceStatus,
        diagnosticRepository: store,
        historyRepository: store,
        runHistoryBrowser: store,
        runReceiptRepository: store,
        settingsStore: protectedSettingsStore,
        recordGraphPersistenceStore: store,
        residuePurger: RillStorageResiduePurger(
          rawStoragePurger: store,
          temporaryFileCleanupService: temporaryFileCleanupService
        ),
        temporaryFileCleanupService: temporaryFileCleanupService,
        failedAudioRecoveryStore: failedAudioRecoveryStore,
        benchmarkRecordingArchiveStore: benchmarkRecordingArchiveStore,
        startupDiagnostic: DiagnosticEvent(
          subsystem: .session,
          level: startupDiagnosticLevel,
          event: "persistence.sqlite.ready",
          message: startupDiagnosticMessage,
          metadata: ["keychainKeyState": keychainKeyState]
        )
      )
    } catch KeychainLocalDataKeyStore.StoreError.temporarilyUnavailable {
      return makeSessionOnlyBackends(
        reason: .keychainTemporarilyUnavailable,
        temporaryFileCleanupService: temporaryFileCleanupService,
        diagnosticEvent: "persistence.keychain.temporarily-unavailable",
        diagnosticMessage:
          "The local data protection key is temporarily unavailable. "
          + "Using in-memory storage until the next launch."
      )
    } catch {
      return makeSessionOnlyBackends(
        reason: .persistentStorageUnavailable,
        temporaryFileCleanupService: temporaryFileCleanupService,
        diagnosticEvent: "persistence.sqlite.fallback",
        diagnosticMessage:
          "SQLite persistence could not be initialized. Falling back to in-memory storage."
      )
    }
  }

  private static func makeSessionOnlyBackends(
    reason: LocalPersistenceStatus.SessionOnlyReason,
    temporaryFileCleanupService: RillTemporaryFileCleanupService,
    diagnosticEvent: String,
    diagnosticMessage: String
  ) -> PersistenceBackends {
    PersistenceBackends(
      localPersistenceStatus: .sessionOnly(reason: reason),
      diagnosticRepository: InMemoryDiagnosticRepository(),
      historyRepository: InMemoryHistoryRepository(),
      // A durable-history failure is an explicit product state. Supplying a
      // throwing boundary keeps History and global search from silently
      // presenting the in-memory compatibility cache as saved history.
      runHistoryBrowser: UnavailableRunHistoryBrowser(),
      runReceiptRepository: nil,
      settingsStore: nil,
      recordGraphPersistenceStore: nil,
      residuePurger: nil,
      temporaryFileCleanupService: temporaryFileCleanupService,
      failedAudioRecoveryStore: nil,
      benchmarkRecordingArchiveStore: nil,
      startupDiagnostic: DiagnosticEvent(
        subsystem: .session,
        level: .warning,
        event: diagnosticEvent,
        message: diagnosticMessage
      )
    )
  }

  private static func databaseAccepts(
    key: Data,
    databaseURL: URL
  ) throws -> Bool {
    let protector = try AESGCMDataProtector(key: key)
    do {
      return try SQLiteLocalDataKeyProbe.probe(
        databaseURL: databaseURL,
        localDataProtector: protector
      ) == .boundAndValid
    } catch SQLiteLocalDataKeyProbeError.validationFailed {
      return false
    }
  }

  private static func revalidateCurrentBindings(
    candidate: KeychainLocalDataKeyStore.Candidate,
    databaseURL: URL,
    recoveryDirectoryURL: URL,
    benchmarkArchiveDirectoryURL: URL
  ) throws {
    try LocalDataKeyResolver.revalidate(
      candidate: candidate,
      databaseRequiresExistingKey:
        try SQLitePersistenceStore
        .requiresExistingDataProtectionKey(databaseURL: databaseURL),
      recoveryRequiresExistingKey:
        EncryptedFailedAudioRecoveryStore
        .requiresExistingDataProtectionKey(directoryURL: recoveryDirectoryURL),
      archiveRequiresExistingKey:
        EncryptedBenchmarkRecordingArchiveStore
        .requiresExistingDataProtectionKey(directoryURL: benchmarkArchiveDirectoryURL),
      databaseAccepts: { key in
        try databaseAccepts(
          key: key,
          databaseURL: databaseURL
        )
      },
      recoveryAccepts: { key in
        try recoveryAccepts(
          key: key,
          directoryURL: recoveryDirectoryURL
        )
      },
      archiveAccepts: { key in
        try archiveAccepts(
          key: key,
          directoryURL: benchmarkArchiveDirectoryURL
        )
      }
    )
  }

  private static func recoveryAccepts(
    key: Data,
    directoryURL: URL
  ) throws -> Bool {
    let protector = try AESGCMDataProtector(key: key)
    do {
      return try EncryptedFailedAudioRecoveryStore
        .probeExistingDataProtectionKey(
          directoryURL: directoryURL,
          localDataProtector: protector
        ) == .boundAndValid
    } catch FailedAudioRecoveryError.invalidEntry {
      return false
    }
  }

  private static func archiveAccepts(
    key: Data,
    directoryURL: URL
  ) throws -> Bool {
    let protector = try AESGCMDataProtector(key: key)
    do {
      return try EncryptedBenchmarkRecordingArchiveStore
        .probeExistingDataProtectionKey(
          directoryURL: directoryURL,
          localDataProtector: protector
        ) == .boundAndValid
    } catch BenchmarkRecordingArchiveError.invalidEntry {
      return false
    }
  }
}

enum WorkflowManifestResource {
  struct LoadResult: Sendable, Equatable {
    let manifest: WorkflowManifest
    let diagnostic: DiagnosticEvent
  }

  static func load(
    recognizerRegistry: SpeechRecognizerRegistry,
    transformerRegistry: TextTransformerRegistry,
    actionRegistry: OutputActionRegistry
  ) -> LoadResult {
    load(
      manifestURL: url(),
      recognizerRegistry: recognizerRegistry,
      transformerRegistry: transformerRegistry,
      actionRegistry: actionRegistry
    )
  }

  static func load(
    manifestURL: URL?,
    recognizerRegistry: SpeechRecognizerRegistry,
    transformerRegistry: TextTransformerRegistry,
    actionRegistry: OutputActionRegistry
  ) -> LoadResult {
    let fallback = BuiltinWorkflowCatalog().manifest()
    guard let manifestURL else {
      return LoadResult(
        manifest: fallback,
        diagnostic: manifestDiagnostic(
          event: "workflow-manifest.bundle.missing",
          metadata: [
            "reason": "resource-unavailable",
            "source": "packaged-resource",
          ]
        )
      )
    }
    do {
      let manifest = try JSONWorkflowManifestLoader(url: manifestURL).loadManifest()
      try WorkflowManifestValidator(
        recognizerRegistry: recognizerRegistry,
        transformerRegistry: transformerRegistry,
        actionRegistry: actionRegistry
      ).validate(manifest)
      return LoadResult(
        manifest: manifest,
        diagnostic: manifestDiagnostic(
          event: "workflow-manifest.loaded",
          level: .info,
          metadata: ["source": "packaged-resource"]
        )
      )
    } catch {
      return LoadResult(
        manifest: fallback,
        diagnostic: manifestDiagnostic(
          event: "workflow-manifest.fallback",
          metadata: [
            "reason": "load-or-validation-failed",
            "source": "packaged-resource",
          ]
        )
      )
    }
  }

  private nonisolated static func url(fileManager: FileManager = .default) -> URL? {
    let resourceName = "BuiltinWorkflowManifest"
    let fileName = "\(resourceName).json"
    let bundleName = "RillMacOS_RillApp"
    if let url = Bundle.main.url(forResource: resourceName, withExtension: "json") {
      return url
    }
    if let url = resourceBundleURL(bundleName: bundleName, resourceName: resourceName) {
      return url
    }
    return candidateDirectories().lazy.compactMap { directory in
      resourceURL(
        in: directory, fileName: fileName, bundleName: bundleName, fileManager: fileManager)
    }.first
  }

  private nonisolated static func resourceBundleURL(bundleName: String, resourceName: String)
    -> URL?
  {
    guard let bundleURL = Bundle.main.url(forResource: bundleName, withExtension: "bundle"),
      let bundle = Bundle(url: bundleURL)
    else { return nil }
    return bundle.url(forResource: resourceName, withExtension: "json")
  }

  private nonisolated static func candidateDirectories() -> [URL] {
    [
      Bundle.main.resourceURL,
      Bundle.main.bundleURL.deletingLastPathComponent(),
      Bundle.main.executableURL?.deletingLastPathComponent(),
      URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
        "Resources"),
    ].compactMap { $0 }
  }

  private nonisolated static func resourceURL(
    in directory: URL,
    fileName: String,
    bundleName: String,
    fileManager: FileManager
  ) -> URL? {
    let directURL = directory.appendingPathComponent(fileName)
    if fileManager.fileExists(atPath: directURL.path) {
      return directURL
    }
    let bundledURL =
      directory
      .appendingPathComponent("\(bundleName).bundle", isDirectory: true)
      .appendingPathComponent(fileName)
    return fileManager.fileExists(atPath: bundledURL.path) ? bundledURL : nil
  }

  private static func manifestDiagnostic(
    event: String,
    level: DiagnosticLevel = .warning,
    metadata: [String: String] = [:]
  ) -> DiagnosticEvent {
    DiagnosticEvent(
      subsystem: .providers,
      level: level,
      event: event,
      message: manifestDiagnosticMessage(for: event),
      metadata: metadata
    )
  }

  private static func manifestDiagnosticMessage(for event: String) -> String {
    switch event {
    case "workflow-manifest.loaded":
      return "Loaded workflow manifest from the app bundle."
    case "workflow-manifest.fallback":
      return "Failed to load the workflow manifest. Falling back to the built-in catalog."
    default:
      return "Workflow manifest resource was not found. Falling back to the built-in catalog."
    }
  }
}

extension WebhookConfigurationMigrationEvent {
  fileprivate var diagnosticEvent: DiagnosticEvent {
    switch self {
    case .completed(let protectedActionCount):
      return DiagnosticEvent(
        subsystem: .platform,
        level: .info,
        event: "security.webhook-configuration.protected",
        message: "Legacy Webhook configuration protection is ready.",
        metadata: ["protectedActionCount": String(protectedActionCount)]
      )
    case .purgePending(let protectedActionCount):
      return DiagnosticEvent(
        subsystem: .platform,
        level: .warning,
        event: "security.webhook-configuration.purge-pending",
        message:
          "Webhook values are protected, but physical SQLite cleanup is still pending and workflow library writes remain locked.",
        metadata: ["protectedActionCount": String(protectedActionCount)]
      )
    case .blocked(let reason):
      return DiagnosticEvent(
        subsystem: .platform,
        level: .error,
        event: "security.webhook-configuration.blocked",
        message:
          "Legacy Webhook configuration could not be protected, so custom workflows were quarantined.",
        metadata: ["reason": reason.diagnosticDescription]
      )
    }
  }
}

extension WebhookConfigurationMigrationBlockReason {
  fileprivate var diagnosticDescription: String {
    switch self {
    case .settingsReadFailed:
      return "settings-read-failed"
    case .invalidWorkflowLibrary:
      return "invalid-workflow-library"
    case .duplicateWorkflowID(let workflowID):
      return "duplicate-workflow-id:\(workflowID.uuidString)"
    case .invalidWorkflowEnabledStates:
      return "invalid-workflow-enabled-states"
    case .invalidSecureReference(let workflowID, let actionIndex):
      return "invalid-secure-reference:\(workflowID.uuidString):\(actionIndex)"
    case .secureReadFailed(let reference):
      return "secure-read-failed:\(reference.rawValue)"
    case .secureWriteFailed(let reference):
      return "secure-write-failed:\(reference.rawValue)"
    case .secureVerificationFailed(let reference):
      return "secure-verification-failed:\(reference.rawValue)"
    case .secureValueConflict(let reference):
      return "secure-value-conflict:\(reference.rawValue)"
    case .settingsWriteFailed:
      return "settings-write-failed"
    }
  }
}

extension SecureCredentialStoreEvent {
  fileprivate var diagnosticEvent: DiagnosticEvent {
    let level: DiagnosticLevel
    let message: String
    switch kind {
    case .migrationSucceeded:
      level = .info
      message = "A legacy credential was migrated to macOS Keychain."
    case .legacyCleanupFailed:
      level = .warning
      message =
        "A credential is available in Keychain, but its legacy settings value could not be removed."
    case .migrationFailed:
      level = .error
      message =
        "A legacy credential could not be migrated to macOS Keychain; the legacy value was preserved."
    case .secureReadFailed:
      level = .error
      message = "macOS Keychain could not read a credential. Plaintext fallback was not used."
    case .secureWriteFailed:
      level = .error
      message = "macOS Keychain could not save a credential."
    case .secureRemovalFailed:
      level = .error
      message = "macOS Keychain could not remove a credential."
    case .legacyReadFailed:
      level = .error
      message = "Legacy credential storage could not be checked."
    }

    var metadata = ["credentialKey": key.rawValue]
    if let errorDescription {
      metadata["error"] = errorDescription
    }
    return DiagnosticEvent(
      subsystem: .platform,
      level: level,
      event: "credentials.\(kind.rawValue)",
      message: message,
      metadata: metadata
    )
  }
}

@MainActor
private enum CloudPrivacyConfirmation {
  enum Response: Sendable, Equatable {
    case cancel
    case allowOnce
    case alwaysAllow
  }

  static func confirm(
    workflow: WorkflowDefinition,
    processingDestinations: [PrivacyProcessingDestination]
  ) -> Response {
    let usesChinese = Locale.current.identifier.lowercased().hasPrefix("zh")
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = usesChinese ? "允许云端处理？" : "Allow cloud processing?"
    alert.informativeText = CloudPrivacyConfirmationCopy.informativeText(
      workflowName: workflow.name,
      processingDestinations: processingDestinations,
      usesChinese: usesChinese
    )
    alert.addButton(withTitle: usesChinese ? "允许并记住" : "Allow and Remember")
    alert.addButton(withTitle: usesChinese ? "仅这一次" : "Allow Once")
    alert.addButton(withTitle: usesChinese ? "取消" : "Cancel")
    return switch alert.runModal() {
    case .alertFirstButtonReturn: .alwaysAllow
    case .alertSecondButtonReturn: .allowOnce
    default: .cancel
    }
  }
}

enum CloudPrivacyConfirmationCopy {
  static func informativeText(
    workflowName: String,
    processingDestinations: [PrivacyProcessingDestination],
    usesChinese: Bool
  ) -> String {
    let sendsSpeech = processingDestinations.contains(.cloudSpeech)
    let sendsText = processingDestinations.contains(.cloudText)
    let processingCopy = switch (usesChinese, sendsSpeech, sendsText) {
    case (false, true, false):
      "The workflow “\(workflowName)” will stream microphone audio and any matching cloud-recognition terms to its cloud speech service while recording. Rill continuously checks the current focus and privacy settings and stops the run if they become restricted. Nothing from this run has left this Mac yet."
    case (true, true, false):
      "工作流“\(workflowName)”会在录音期间，将麦克风音频以及范围匹配的云端识别术语流式发送到云端语音服务。Rill 会持续检查当前焦点与隐私设置；一旦变为受限状态，就会停止本次运行。本次内容尚未离开本机。"
    case (false, false, true):
      "The workflow “\(workflowName)” will send its final transcript to the configured cloud text service for rewriting. Nothing from this run has left this Mac yet."
    case (true, false, true):
      "工作流“\(workflowName)”会将最终转写发送到已配置的云端文本服务进行润色。本次内容尚未离开本机。"
    case (false, true, true):
      "The workflow “\(workflowName)” will stream microphone audio and matching cloud-recognition terms while recording, then send its final transcript to the configured cloud text service for rewriting. Rill continuously checks the current focus and privacy settings and stops the run if they become restricted. Nothing from this run has left this Mac yet."
    case (true, true, true):
      "工作流“\(workflowName)”会在录音期间流式发送麦克风音频和范围匹配的云端识别术语，随后将最终转写发送到已配置的云端文本服务进行润色。Rill 会持续检查当前焦点与隐私设置；一旦变为受限状态，就会停止本次运行。本次内容尚未离开本机。"
    case (false, false, false):
      "The workflow “\(workflowName)” requested cloud processing, but its cloud destination could not be classified. Cancel unless this is expected. Nothing from this run has left this Mac yet."
    case (true, false, false):
      "工作流“\(workflowName)”请求了云端处理，但无法对云端目的地进行分类。如非预期，请取消。本次内容尚未离开本机。"
    }
    let authorizationCopy = usesChinese
      ? "选择“允许并记住”后，此工作流及云端服务配置不变时不再询问，重启 Rill 后仍然有效。可随时在“设置 > 隐私”中撤销，或选择“仅这一次”。"
      : "Choose “Allow and Remember” to skip this prompt for this workflow and cloud-service configuration, including after restarting Rill. Revoke it anytime in Settings > Privacy, or choose “Allow Once”."
    return processingCopy + "\n\n" + authorizationCopy
  }
}

private enum AppSettingsLoader {
  private enum LoadError: Error {
    case unavailable
  }

  static func loadOpenAISettings(
    from settingsStore: (any SettingsStore)?,
    credentialStore: (any SecureCredentialStore)?
  ) async throws -> OpenAISettings {
    let settingKeys: [AppSettingKey] = [.openAIBaseURL, .openAIModel]
    let storedSnapshot =
      try await settingsStore?.settingsSnapshot(
        forKeys: settingKeys
      ) ?? .empty
    guard storedSnapshot.unavailableKeys.isDisjoint(with: Set(settingKeys)) else {
      throw LoadError.unavailable
    }
    let baseURL =
      trimmedNonEmpty(storedSnapshot.values[.openAIBaseURL])
      ?? OpenAISettings.defaultBaseURL
    let model =
      trimmedNonEmpty(storedSnapshot.values[.openAIModel])
      ?? OpenAISettings.defaultModel
    guard
      OpenAISettings.isValidBaseURL(baseURL),
      OpenAISettings.isValidModelIdentifier(model)
    else {
      throw LoadError.unavailable
    }
    let apiKey = try await credentialStore?.credential(for: .openAIAPIKey) ?? ""
    return OpenAISettings(apiKey: apiKey, baseURL: baseURL, model: model)
  }

  static func trimmedNonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

}

@MainActor
final class WorkflowSelectionBridge {
  weak var model: AppModel?

  func enabledWorkflows(for trigger: TriggerBinding) -> [WorkflowDefinition] {
    model?.enabledWorkflows(for: trigger) ?? []
  }

  func longRecordingModeEnabled() -> Bool {
    model?.longRecordingModeEnabled ?? false
  }

  func recordCollectionWorkflowRegistrations() -> [RecordCollectionWorkflowRegistration] {
    guard let model else { return [] }
    return model.workflows.compactMap { workflow in
      AppBootstrap.makeRecordCollectionWorkflowRegistration(
        for: workflow,
        isEnabled: model.isWorkflowEnabled(workflow)
      )
    }
  }

}
