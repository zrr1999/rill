import AppKit
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
  let stackPasteController: StackPasteController
  let recordingSessionManager: RecordingSessionManager
  let shutdown: @Sendable () async -> Void
  let cancelLiveAudio: @Sendable (UUID) async -> Void
  let useClipboardItem:
    @Sendable (
      ClipboardHistoryItem,
      ClipboardPasteTargetIdentity
    ) async -> Void
  let setClipboardCaptureEnabled: @Sendable (Bool, UInt64) -> Void
  let ignoreNextExternalClipboardChange: @Sendable () -> Void
  let updateClipboardPanelHotkey: @Sendable (HotkeyBindingDescriptor) -> Void
  let beginClipboardPanelShortcutRecording: @Sendable () -> UUID
  let endClipboardPanelShortcutRecording: @Sendable (UUID) -> Void
  let commitClipboardPanelShortcutRecording: @Sendable (UUID, UInt16) -> Void
}

@MainActor
enum AppBootstrap {
  nonisolated static var distributableLocalSpeechModels: [LocalSpeechModelDescriptor] {
    var models = [
      LocalSpeechModelDescriptor(
        id: SherpaOnnxModelID.qwen3ASR06BInt8.rawValue,
        englishName: "16 GB · Qwen3-ASR 0.6B INT8 — Default",
        simplifiedChineseName: "16 GB · Qwen3-ASR 0.6B INT8（默认）",
        englishDetail:
          "Best default for Simplified Chinese with some English mixing; suitable for 16 GB Macs · about 838 MB final-model download",
        simplifiedChineseDetail:
          "简体中文为主、夹少量英文的默认优选，适合 16 GB Mac · 最终模型下载约 838 MB",
        forcesAutomaticLanguageDetection: true,
        category: .intelligent,
        parameterCountMillions: 600,
        quantization: .int8,
        minimumSystemMemoryGiB: 12,
        recommendedSystemMemoryGiB: 16,
        hardwareRecommendationPriority: 10
      )
    ]
    #if arch(arm64)
      models.append(
        LocalSpeechModelDescriptor(
          id: MLXAudioModelID.qwen3ASR17BInt8.rawValue,
          englishName: "24 GB+ · Qwen3-ASR 1.7B 8bit — MLX GPU",
          simplifiedChineseName: "24 GB+ · Qwen3-ASR 1.7B 8bit（MLX GPU）",
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
          hardwareRecommendationPriority: 20
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

  /// Model acquisition remains in the host, but native offline model creation
  /// is exclusively owned by RillSpeechWorker.
  nonisolated static func modelInstallationConfiguration(
    from configuration: SherpaOnnxRecognizer.Configuration
  ) -> SherpaOnnxRecognizer.Configuration {
    var installationConfiguration = configuration
    installationConfiguration.prewarm = false
    return installationConfiguration
  }

  nonisolated static func deepgramConfiguration(
    from settingsStore: (any SettingsStore)?,
    credentialStore: (any SecureCredentialStore)?
  ) async -> DeepgramRecognizer.Configuration? {
    await AppSettingsLoader.loadDeepgramConfiguration(
      from: settingsStore,
      credentialStore: credentialStore
    )
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
    if let failure = error as? SherpaOnnxModelInstallationError {
      let stage: LocalSpeechPreparationFailure.Stage
      switch failure {
      case .invalidCatalogDescriptor:
        stage = .trustRoot
      case .downloadFailed,
        .archiveInspectionFailed,
        .extractionFailed,
        .publicationFailed:
        stage = .resolution
      case .unsafeDestinationRoot,
        .downloadedArchiveIsNotRegularFile,
        .downloadedArchiveHasMultipleHardLinks,
        .archiveByteCountMismatch,
        .archiveDigestMismatch,
        .unsafeArchiveEntry,
        .requiredEntryMissing,
        .requiredEntryTypeMismatch,
        .extractedTreeInvalid,
        .receiptInvalid:
        stage = .integrity
      }
      return LocalSpeechPreparationFailure(stage: stage)
    }
    if let failure = error as? SherpaOnnxRecognizer.RecognizerError {
      let stage: LocalSpeechPreparationFailure.Stage
      switch failure {
      case .unsupportedModelIdentifier:
        stage = .trustRoot
      case .modelNotInstalled:
        stage = .resolution
      case .missingCapturedAudio,
        .fileBackedAudioRequired,
        .invalidThreadCount,
        .invalidAudioFile,
        .emptyAudio,
        .audioTooLong,
        .nonFiniteAudioSample,
        .audioConversionFailed:
        stage = .runtime
      }
      return LocalSpeechPreparationFailure(stage: stage)
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

  nonisolated static func makeClipboardItemRunAuthorization(
    deliveryStack: DeliveryStack,
    privacyRunGate: PrivacyRunGate,
    privacyContextProvider: @escaping @Sendable () async -> ContextSnapshot,
    authorizedContextProvider:
      @escaping @Sendable (
        PrivacyPolicyDecision
      ) async -> ContextSnapshot
  )
    -> @Sendable (
      UUID,
      ClipboardItemVersion,
      ClipboardItemDryRunOperation,
      WorkflowDefinition
    ) async throws -> AuthorizedWorkflowRunContext
  {
    { itemID, expectedItemVersion, operation, workflow in
      guard let subject = await deliveryStack.clipboardItemDryRunSubject(itemID: itemID) else {
        throw PrivacyRunGate.GateError.clipboardItemUnavailable
      }
      guard subject.itemVersion == expectedItemVersion else {
        throw PrivacyRunGate.GateError.clipboardItemChangedDuringAuthorization
      }
      guard
        let source = await deliveryStack.clipboardItemRunAuthorizationSource(
          itemID: itemID,
          expectedItemVersion: expectedItemVersion
        )
      else {
        throw PrivacyRunGate.GateError.clipboardItemChangedDuringAuthorization
      }
      let authorized = try await privacyRunGate.captureAuthorizedClipboardItemRunContext(
        source: source,
        operation: operation,
        privacyContextProvider: privacyContextProvider,
        contextProvider: authorizedContextProvider,
        workflow: workflow
      )
      guard await deliveryStack.matchesClipboardItemRunAuthorizationSource(source) else {
        throw PrivacyRunGate.GateError.clipboardItemChangedDuringAuthorization
      }
      return authorized
    }
  }

  nonisolated static func makeDeepgramDiagnosticPrivacyAuthorization(
    privacyRunGate: PrivacyRunGate,
    privacyContextProvider: @escaping @Sendable () async -> ContextSnapshot
  ) -> @Sendable (WorkflowDefinition) async throws -> Void {
    { workflow in
      _ = try await privacyRunGate.captureAuthorizedContext(
        privacyContextProvider: privacyContextProvider,
        contextProvider: { _ in await privacyContextProvider() },
        workflow: workflow
      )
    }
  }

  nonisolated static func makeDeepgramDiagnosticPrivacyPreflight(
    privacyRunGate: PrivacyRunGate,
    privacyContextProvider: @escaping @Sendable () async -> ContextSnapshot
  ) -> @Sendable (WorkflowDefinition) async throws -> Void {
    { workflow in
      let evaluation = await privacyRunGate.evaluate(
        context: await privacyContextProvider(),
        workflow: workflow
      )
      guard evaluation.status == .blocked else { return }
      if evaluation.reasons.contains(.privacySettingsUnavailable) {
        throw PrivacyRunGate.GateError.settingsUnavailable
      }
      if evaluation.reasons.contains(.processingDestinationUnavailable) {
        throw PrivacyRunGate.GateError.processingDestinationUnavailable
      }
      throw PrivacyRunGate.GateError.cloudProcessingBlocked
    }
  }

  nonisolated static func makeRecognitionRunPreflight(
    trustedLocalModelIdentifiers: Set<String> =
      LocalSpeechModelCatalog.distributableModelIdentifiers,
    defaultLocalModelIdentifier: String = LocalSpeechModelCatalog.defaultModelIdentifier,
    localSpeechSettingsProvider:
      @escaping @Sendable () async throws -> LocalSpeechSettings = { .init() },
    deepgramConfigurationProvider: @escaping @Sendable () async -> DeepgramRecognizer.Configuration?
  ) -> RecognitionRunPreflight {
    { workflow in
      if let issue = WorkflowExecutionPolicy.issue(for: workflow) {
        throw SessionCoordinator.SessionError.unsupportedWorkflow(issue)
      }
      if workflow.pipeline.recognizerID == "sherpa-onnx.local" {
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
      if workflow.pipeline.recognizerID == SherpaStreamingCaptureRecognizer.recognizerID {
        return
      }
      guard workflow.pipeline.recognizerID == "deepgram.prerecorded" else { return }
      let configuration = await deepgramConfigurationProvider() ?? .init()
      _ = try DeepgramConfigurationValidator.validate(configuration)
    }
  }

  nonisolated static func sherpaOnnxConfiguration(
    settings: LocalSpeechSettings,
    trustedModelIdentifiers: Set<String> =
      SherpaOnnxModelCatalog.distributableModelIdentifiers,
    defaultModelIdentifier: String = SherpaOnnxModelCatalog.defaultModelID.rawValue,
    threadCount: Int = 2
  ) throws -> SherpaOnnxRecognizer.Configuration {
    guard trustedModelIdentifiers.contains(defaultModelIdentifier),
      SherpaOnnxModelID(rawValue: defaultModelIdentifier) != nil
    else {
      throw SherpaOnnxModelInstallationError.invalidCatalogDescriptor
    }
    let requestedModel = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
    let modelIdentifier =
      trustedModelIdentifiers.contains(requestedModel)
        && SherpaOnnxModelID(rawValue: requestedModel) != nil
      ? requestedModel : defaultModelIdentifier
    let language = settings.language.trimmingCharacters(in: .whitespacesAndNewlines)
    return SherpaOnnxRecognizer.Configuration(
      modelIdentifier: modelIdentifier,
      language: language.isEmpty ? nil : language,
      downloadIfNeeded: settings.downloadIfNeeded,
      prewarm: settings.prewarm,
      threadCount: threadCount
    )
  }

  nonisolated static func currentSherpaOnnxConfiguration(
    from source: LocalSpeechSettingsSource,
    trustedModelIdentifiers: Set<String> =
      SherpaOnnxModelCatalog.distributableModelIdentifiers,
    defaultModelIdentifier: String = SherpaOnnxModelCatalog.defaultModelID.rawValue,
    threadCount: Int = 2
  ) throws -> SherpaOnnxRecognizer.Configuration {
    try sherpaOnnxConfiguration(
      settings: source.currentSettings(),
      trustedModelIdentifiers: trustedModelIdentifiers,
      defaultModelIdentifier: defaultModelIdentifier,
      threadCount: threadCount
    )
  }

  /// Keeps model readiness authoritative while opportunistically warming the
  /// already-authorized, stopped audio frontend. Audio preparation is
  /// deliberately best-effort at the service boundary and cannot change the
  /// prepared model result.
  nonisolated static func prepareLocalSpeechModelAndAudioFrontend(
    prewarmAudioFrontend: Bool,
    prepareModel: @Sendable () async throws -> String,
    prepareAudioFrontend: @Sendable () async -> Void
  ) async throws -> String {
    let preparedModel = try await prepareModel()
    try Task.checkCancellation()
    if prewarmAudioFrontend {
      await prepareAudioFrontend()
      try Task.checkCancellation()
    }
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

  nonisolated static func makeClipboardGroupWorkflowRegistration(
    for workflow: WorkflowDefinition,
    isEnabled: Bool
  ) -> ClipboardGroupWorkflowRegistration? {
    guard
      let configuration =
        try? workflow
        .parseClipboardGroupAutomationConfiguration()
    else {
      return nil
    }
    return ClipboardGroupWorkflowRegistration(
      workflowID: workflow.id,
      triggerRule: configuration.rule,
      isEnabled: isEnabled,
      isExecutionSupported: false
    )
  }

  nonisolated static func makeLocalHistoryMaintenance(
    clipboardHistory: any ClipboardHistoryMaintaining,
    historyRepository: any HistoryRepository,
    runReceiptRepository: any WorkflowRunReceiptRepository,
    diagnosticRepository: any DiagnosticHistoryMaintaining,
    settingsStore: (any SettingsStore)?,
    residuePurger: (any StorageResiduePurging)?,
    eventReporter: @escaping LocalHistoryMaintenance.EventReporter = { _ in }
  ) -> (any LocalHistoryMaintaining)? {
    guard let settingsStore, let residuePurger else { return nil }
    return LocalHistoryMaintenance(
      clipboardHistory: clipboardHistory,
      runHistory: historyRepository,
      runReceipts: runReceiptRepository,
      diagnosticHistory: diagnosticRepository,
      settingsStore: settingsStore,
      physicalPurger: residuePurger,
      eventReporter: eventReporter
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
      "clipboardRemovedCount": String(event.counts.clipboardRemovedCount),
      "runRemovedCount": String(event.counts.runRemovedCount),
      "runReceiptRemovedCount": String(event.counts.runReceiptRemovedCount),
      "diagnosticRemovedCount": String(event.counts.diagnosticRemovedCount),
      "preservedActiveClipboardCount": String(event.counts.preservedActiveClipboardCount),
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

  nonisolated static func deepgramHintDiagnostic(
    for report: DeepgramHintDiagnosticReport
  ) -> DiagnosticEvent {
    DiagnosticEvent(
      subsystem: .providers,
      level: report.outcome == .unsupportedModel ? .warning : .info,
      event: "provider.deepgram.keyterms",
      message: "Deepgram recognition hint planning completed.",
      metadata: [
        "count": String(report.count),
        "omittedCount": String(report.omittedCount),
        "outcome": report.outcome.rawValue,
        "source": report.source.rawValue,
      ]
    )
  }

  nonisolated static func useClipboardItem(
    _ item: ClipboardHistoryItem,
    target: ClipboardPasteTargetIdentity,
    capturePrivacyContext: @escaping @Sendable () async -> ContextSnapshot,
    deliverText:
      @escaping @Sendable (
        ClipboardItemDryRunSubject,
        ContextSnapshot
      ) async -> Void,
    claimRichItem:
      @escaping @Sendable (
        ClipboardItemDryRunSubject
      ) async throws -> ClipboardItemUseLease,
    injectClipboardSnapshot:
      @escaping @Sendable (
        ClipboardSnapshot,
        FocusSnapshot
      ) async throws -> Void,
    completeUse: @escaping @Sendable (UUID) async -> Void,
    failUse: @escaping @Sendable (UUID) async -> Void,
    reportFailure: @escaping @Sendable (String) async -> Void
  ) async {
    let subject = ClipboardItemDryRunSubject(
      itemID: item.id,
      itemVersion: item.version,
      groupID: item.groupID,
      contentKind: item.contentKind,
      captureTags: item.captureTags,
      hasTransferableContent: item.supportsDirectPaste
    )
    let privacyContext = await capturePrivacyContext()
    guard target.matches(privacyContext.focus) else {
      await reportFailure(
        "Clipboard paste was blocked because the restored target application changed."
      )
      return
    }

    if item.contentKind == .text {
      await deliverText(subject, privacyContext)
      return
    }

    var lease: ClipboardItemUseLease?
    do {
      let claimedLease = try await claimRichItem(subject)
      lease = claimedLease
      try await injectClipboardSnapshot(
        claimedLease.item.clipboardSnapshot,
        privacyContext.focus
      )
      await completeUse(claimedLease.leaseID)
    } catch {
      if let lease {
        await failUse(lease.leaseID)
      }
      let safeMessage =
        (error as? ClipboardItemUseLeaseError)?.errorDescription
        ?? HistoryFailureSanitizer.genericMessage
      await reportFailure(safeMessage)
    }
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
  /// Dedicated atomic boundary for the protected clipboard metadata/blob graph.
  /// It is intentionally not routed through the generic settings facade.
  let clipboardPersistenceStore: (any ClipboardPersistenceStore)?
  let residuePurger: (any StorageResiduePurging)?
  let temporaryFileCleanupService: RillTemporaryFileCleanupService
  let failedAudioRecoveryStore: (any FailedAudioRecoveryStore)?
  let startupDiagnostic: DiagnosticEvent?
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
  let runReceiptRecorder: WorkflowRunReceiptRecorder?
  let clipboardGroupEventScheduler: ClipboardGroupEventScheduler
  let deliveryStack: DeliveryStack
  let localHistoryMaintenance: (any LocalHistoryMaintaining)?
  let candidateResolver: CandidateResolver
  let vocabularyRuleSource: VocabularyRuleSource
  let privacySettingsSource: PrivacyPolicySettingsSource
}

private struct PlatformServices {
  let focusTracker: FocusTracker
  let pasteboard: PasteboardController
  let hotkeyTap: HotkeyEventTap
  let injectionEngine: TextInjectionEngine
  let permissionGate: PermissionGate
  let contextProvider: BuiltinContextProvider
  let credentialStore: any SecureCredentialStore
}

private struct ProviderServices {
  let diagnosticsAudioCaptureService: AVAudioCaptureService
  let managedTemporaryAudioCleanupOwner: ManagedTemporaryAudioCleanupOwner
  let markdownFileAppendCoordinator: MarkdownFileAppendCoordinator
  let localSpeechSettingsSource: LocalSpeechSettingsSource
  let sherpaOnnxConfigurationProvider:
    @Sendable () async throws -> SherpaOnnxRecognizer.Configuration
  let deepgramConfigurationProvider: @Sendable () async -> DeepgramRecognizer.Configuration?
  let localSpeechAvailability: LocalSpeechAvailability
  let trustedLocalSpeechModels: [LocalSpeechModelDescriptor]
  let defaultLocalSpeechModelIdentifier: String?
  let localSpeechStartupDiagnostic: DiagnosticEvent
  let sherpaOnnxModelPreparer: SherpaOnnxRecognizer
  let speechWorkerSupervisor: SpeechWorkerSupervisor
  let sherpaOnnxRecognizer: SherpaOnnxWorkerRecognizer
  let mlxAudioSwiftRecognizer: MLXAudioSwiftWorkerRecognizer
  let localSpeechRecognizer: RoutedLocalSpeechRecognizer
  let streamingPreviewService: SherpaStreamingPreviewService
  let workflowAudioCaptureService: RealtimeAudioCaptureService
}

private struct Registries {
  let recognizerRegistry: SpeechRecognizerRegistry
  let transformerRegistry: TextTransformerRegistry
  let actionRegistry: OutputActionRegistry
}

private struct RuntimeServices {
  let coordinator: SessionCoordinator
  let capturedAudioProcessingQueue: CapturedAudioProcessingQueue
  let globalInputOwner: GlobalInputOwner
  let stackPasteController: StackPasteController
  let recordingSessionManager: RecordingSessionManager
  let workflowAudioRunController: WorkflowAudioRunController
  let deepgramAudioTestController: DeepgramAudioTestController
  let failedAudioRecoveryController: FailedAudioRecoveryController?
  let clipboardGroupEventScheduler: ClipboardGroupEventScheduler
  let privacyRunGate: PrivacyRunGate
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
  let workflowSelectionBridge: WorkflowSelectionBridge
  let clipboardCaptureControlBridge: ClipboardCaptureControlBridge
  let globalInputCapabilityBridge: GlobalInputCapabilityBridge
  let workflowManifestStartupDiagnostic: DiagnosticEvent
  let workflows: [WorkflowDefinition]
}

@MainActor
private final class ClipboardCaptureControlBridge {
  weak var model: AppModel?
  private var latestRevision: UInt64?

  func update(_ snapshot: ClipboardCaptureControlSnapshot) {
    guard let model else { return }
    if let latestRevision, snapshot.revision <= latestRevision { return }
    latestRevision = snapshot.revision
    model.updateClipboardCaptureControlState(snapshot)
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
    let core = makeCoreServices(
      workflowSelectionBridge: workflowSelectionBridge
    )
    let platform = makePlatformServices(core: core)
    let providers = makeProviderServices(core: core, platform: platform)
    let registries = makeRegistries(
      core: core,
      platform: platform,
      providers: providers
    )
    let runtime = makeRuntimeServices(
      core: core,
      platform: platform,
      providers: providers,
      registries: registries,
      workflowSelectionBridge: workflowSelectionBridge
    )
    let model = AppModelFactory.makeModel(
      core: core,
      platform: platform,
      providers: providers,
      registries: registries,
      runtime: runtime
    )
    runtime.workflowSelectionBridge.model = model
    runtime.clipboardCaptureControlBridge.model = model
    runtime.globalInputCapabilityBridge.attach(model)
    model.installGlobalInputActions(
      request: {
        _ = platform.permissionGate.requestGlobalInputAccess()
        Task {
          await runtime.globalInputOwner.retryInstallation()
        }
      },
      retry: {
        Task {
          await runtime.globalInputOwner.retryInstallation()
        }
      }
    )
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
    let runReceiptRecorder = persistence.runReceiptRepository.map { repository in
      WorkflowRunReceiptRecorder(
        repository: repository,
        eventBus: eventBus,
        diagnostics: diagnostics
      )
    }
    let clipboardGroupEventScheduler = ClipboardGroupEventScheduler(
      receiptRecorder: runReceiptRecorder,
      diagnostics: diagnostics,
      registrationProvider: {
        await MainActor.run {
          workflowSelectionBridge.clipboardGroupWorkflowRegistrations()
        }
      }
    )
    let deliveryStack = DeliveryStack(
      eventBus: eventBus,
      diagnostics: diagnostics,
      clipboardPersistenceStore: persistence.clipboardPersistenceStore,
      clipboardGroupEventSink: clipboardGroupEventScheduler
    )
    let localHistoryMaintenance = persistence.runReceiptRepository.flatMap { repository in
      AppBootstrap.makeLocalHistoryMaintenance(
        clipboardHistory: deliveryStack,
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
      clipboardGroupEventScheduler: clipboardGroupEventScheduler,
      deliveryStack: deliveryStack,
      localHistoryMaintenance: localHistoryMaintenance,
      candidateResolver: CandidateResolver(eventBus: eventBus, diagnostics: diagnostics),
      vocabularyRuleSource: VocabularyRuleSource(),
      privacySettingsSource: PrivacyPolicySettingsSource()
    )
  }

  private static func makePlatformServices(core: CoreServices) -> PlatformServices {
    let focusTracker = FocusTracker()
    let pasteboard = PasteboardController()
    let hotkeyTap = HotkeyEventTap()
    let injectionEngine = TextInjectionEngine(
      pasteboard: pasteboard,
      diagnosticReporter: { event in
        await core.diagnostics.record(event)
      },
      hotkeyTap: hotkeyTap
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
      permissionGate: PermissionGate(),
      contextProvider: BuiltinContextProvider(focusTracker: focusTracker, pasteboard: pasteboard),
      credentialStore: credentialStore
    )
  }

  private static func makeProviderServices(core: CoreServices, platform: PlatformServices)
    -> ProviderServices
  {
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
    let trustedModelIdentifiers = Set(trustedLocalSpeechModels.map(\.id))
    let defaultTrustedModelIdentifier = SherpaOnnxModelCatalog.defaultModelID.rawValue
    let bundledVoiceActivityDetectorIsAvailable: Bool
    do {
      try RealtimeAudioCaptureService.validateBundledVoiceActivityDetector()
      bundledVoiceActivityDetectorIsAvailable = true
    } catch {
      bundledVoiceActivityDetectorIsAvailable = false
    }
    let speechWorkerExecutableURL = AppBootstrap.speechWorkerExecutableURL()
    let speechWorkerIsAvailable = AppBootstrap.speechWorkerExecutableIsAvailable(
      at: speechWorkerExecutableURL
    )
    let localSpeechTrustMaterialIsAvailable =
      bundledVoiceActivityDetectorIsAvailable && speechWorkerIsAvailable
    let localSpeechAvailability: LocalSpeechAvailability =
      localSpeechTrustMaterialIsAvailable ? .available : .trustMaterialUnavailable
    let localSpeechUnavailableReason =
      bundledVoiceActivityDetectorIsAvailable
      ? "speech-worker-unavailable"
      : "trust-material-unavailable"
    let localSpeechStartupDiagnostic = DiagnosticEvent(
      subsystem: .providers,
      level: localSpeechTrustMaterialIsAvailable ? .info : .warning,
      event:
        localSpeechTrustMaterialIsAvailable
        ? "provider.sherpa-onnx.available" : "provider.sherpa-onnx.unavailable",
      message:
        localSpeechTrustMaterialIsAvailable
        ? "Release-pinned sherpa-onnx worker, Silero VAD, and model catalog are available."
        : "Release-pinned local speech runtime material is unavailable.",
      metadata:
        localSpeechTrustMaterialIsAvailable
        ? [
          "recognizerID": "sherpa-onnx.local",
          "modelCount": String(trustedLocalSpeechModels.count),
          "defaultModel": defaultTrustedModelIdentifier,
          "vadModel": "silero-vad-v4",
          "workerIsolation": "subprocess",
        ]
        : [
          "recognizerID": "sherpa-onnx.local",
          "reason": localSpeechUnavailableReason,
          "vadModel": "silero-vad-v4",
        ]
    )
    let localSpeechSettingsSource = LocalSpeechSettingsSource()
    let sherpaOnnxConfigurationProvider:
      @Sendable () async throws -> SherpaOnnxRecognizer.Configuration =
        {
          try AppBootstrap.currentSherpaOnnxConfiguration(
            from: localSpeechSettingsSource,
            trustedModelIdentifiers: trustedModelIdentifiers,
            defaultModelIdentifier: defaultTrustedModelIdentifier
          )
        }
    let deepgramConfigurationProvider: @Sendable () async -> DeepgramRecognizer.Configuration? = {
      await AppSettingsLoader.loadDeepgramConfiguration(
        from: core.persistence.settingsStore,
        credentialStore: platform.credentialStore
      )
    }
    let sherpaOnnxModelPreparer = SherpaOnnxRecognizer(
      configurationProvider: {
        AppBootstrap.modelInstallationConfiguration(
          from: try await sherpaOnnxConfigurationProvider()
        )
      }
    )
    let speechWorkerSupervisor = SpeechWorkerSupervisor(
      configuration: .init(executableURL: speechWorkerExecutableURL)
    )
    let sherpaOnnxRecognizer = SherpaOnnxWorkerRecognizer(
      supervisor: speechWorkerSupervisor,
      configurationProvider: sherpaOnnxConfigurationProvider
    )
    let mlxAudioSwiftRecognizer = MLXAudioSwiftWorkerRecognizer(
      supervisor: speechWorkerSupervisor,
      settingsProvider: {
        try localSpeechSettingsSource.currentSettings()
      }
    )
    let localSpeechRecognizer = RoutedLocalSpeechRecognizer(
      settingsProvider: {
        try localSpeechSettingsSource.currentSettings()
      },
      backends: [
        sherpaOnnxRecognizer,
        mlxAudioSwiftRecognizer,
      ]
    )
    let streamingPreviewService = SherpaStreamingPreviewService()
    let workflowAudioCaptureService = RealtimeAudioCaptureService(
      deepgramConfigurationProvider: deepgramConfigurationProvider,
      deepgramHintDiagnosticReporter: { report in
        guard report.outcome != .noneRequested else { return }
        await core.diagnostics.record(AppBootstrap.deepgramHintDiagnostic(for: report))
      },
      streamingPreviewService: streamingPreviewService,
      liveUpdateHandler: { snapshot in
        await core.eventBus.publish(.liveSubtitleUpdated(snapshot))
      },
      cleanupOwner: managedTemporaryAudioCleanupOwner
    )
    return ProviderServices(
      diagnosticsAudioCaptureService: AVAudioCaptureService(
        cleanupOwner: managedTemporaryAudioCleanupOwner
      ),
      managedTemporaryAudioCleanupOwner: managedTemporaryAudioCleanupOwner,
      markdownFileAppendCoordinator: markdownFileAppendCoordinator,
      localSpeechSettingsSource: localSpeechSettingsSource,
      sherpaOnnxConfigurationProvider: sherpaOnnxConfigurationProvider,
      deepgramConfigurationProvider: deepgramConfigurationProvider,
      localSpeechAvailability: localSpeechAvailability,
      trustedLocalSpeechModels: trustedLocalSpeechModels,
      defaultLocalSpeechModelIdentifier: defaultTrustedModelIdentifier,
      localSpeechStartupDiagnostic: localSpeechStartupDiagnostic,
      sherpaOnnxModelPreparer: sherpaOnnxModelPreparer,
      speechWorkerSupervisor: speechWorkerSupervisor,
      sherpaOnnxRecognizer: sherpaOnnxRecognizer,
      mlxAudioSwiftRecognizer: mlxAudioSwiftRecognizer,
      localSpeechRecognizer: localSpeechRecognizer,
      streamingPreviewService: streamingPreviewService,
      workflowAudioCaptureService: workflowAudioCaptureService
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
          SherpaStreamingCaptureRecognizer(),
          DeepgramRecognizer(
            configurationProvider: providers.deepgramConfigurationProvider,
            hintDiagnosticReporter: { report in
              guard report.outcome != .noneRequested else { return }
              await core.diagnostics.record(
                AppBootstrap.deepgramHintDiagnostic(for: report)
              )
            }
          ),
          SelectionCaptureRecognizer(),
        ]
      ),
      transformerRegistry: TextTransformerRegistry(
        transformers: [WhitespaceNormalizerTransformer()]
      ),
      actionRegistry: OutputActionRegistry(
        actions: [
          PushToStackAction(stack: core.deliveryStack),
          ClipboardCopyAction(
            pasteboard: platform.pasteboard, clipboardCapture: core.deliveryStack),
          InjectTextAction(engine: platform.injectionEngine),
        ]
          + AppBootstrap.makeExternalOutputActions(
            markdownCleanupCoordinator: providers.markdownFileAppendCoordinator
          )
      )
    )
  }

  private static func makeRuntimeServices(
    core: CoreServices,
    platform: PlatformServices,
    providers: ProviderServices,
    registries: Registries,
    workflowSelectionBridge: WorkflowSelectionBridge
  ) -> RuntimeServices {
    let privacyRunGate = makePrivacyRunGate(core: core)
    let recognitionOptionsProvider = makeRecognitionOptionsProvider(
      core: core,
      providers: providers
    )
    let recognitionRunPreflight = AppBootstrap.makeRecognitionRunPreflight(
      trustedLocalModelIdentifiers: Set(providers.trustedLocalSpeechModels.map(\.id)),
      defaultLocalModelIdentifier: providers.defaultLocalSpeechModelIdentifier
        ?? LocalSpeechModelCatalog.defaultModelIdentifier,
      localSpeechSettingsProvider: {
        try providers.localSpeechSettingsSource.currentSettings()
      },
      deepgramConfigurationProvider: providers.deepgramConfigurationProvider
    )
    let coordinator = makeCoordinator(
      core: core,
      platform: platform,
      registries: registries,
      recognitionOptionsProvider: recognitionOptionsProvider,
      recognitionAudioCleanupOwner: providers.managedTemporaryAudioCleanupOwner
    )
    let failedAudioRecoveryController = core.persistence.failedAudioRecoveryStore.map { store in
      FailedAudioRecoveryController(
        store: store,
        sessionCoordinator: coordinator,
        eventBus: core.eventBus,
        diagnostics: core.diagnostics,
        privacyRunGate: privacyRunGate,
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
    let queue = CapturedAudioProcessingQueue(
      sessionCoordinator: coordinator,
      eventBus: core.eventBus,
      diagnostics: core.diagnostics,
      failedAudioRecoveryController: failedAudioRecoveryController
    )
    let manifestResult = WorkflowManifestResource.load(
      recognizerRegistry: registries.recognizerRegistry,
      transformerRegistry: registries.transformerRegistry,
      actionRegistry: registries.actionRegistry
    )
    let bridge = workflowSelectionBridge
    let clipboardCaptureControlBridge = ClipboardCaptureControlBridge()
    let globalInputCapabilityBridge = GlobalInputCapabilityBridge()
    let globalInputOwner = GlobalInputOwner(
      hotkeyTap: platform.hotkeyTap,
      diagnostics: core.diagnostics,
      permissionChecker: {
        PermissionGate.hasGlobalInputAccess()
      },
      capabilityObserver: { capability in
        await globalInputCapabilityBridge.update(capability)
      }
    )
    let authorizeWorkflowRunAction:
      @Sendable (
        WorkflowDefinition
      ) async throws -> AuthorizedWorkflowRunContext = { workflow in
        if let issue = WorkflowExecutionPolicy.issue(for: workflow) {
          throw SessionCoordinator.SessionError.unsupportedWorkflow(issue)
        }
        try await recognitionRunPreflight(workflow)
        return try await privacyRunGate.captureAuthorizedWorkflowRunContext(
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
    let authorizeClipboardItemRunAction = AppBootstrap.makeClipboardItemRunAuthorization(
      deliveryStack: core.deliveryStack,
      privacyRunGate: privacyRunGate,
      privacyContextProvider: {
        await platform.contextProvider.capturePrivacyContext()
      },
      authorizedContextProvider: { decision in
        await platform.contextProvider.captureContext(applying: decision)
      }
    )
    return RuntimeServices(
      coordinator: coordinator,
      capturedAudioProcessingQueue: queue,
      globalInputOwner: globalInputOwner,
      stackPasteController: makeStackPasteController(
        core: core,
        platform: platform,
        coordinator: coordinator,
        captureControlBridge: clipboardCaptureControlBridge
      ),
      recordingSessionManager: makeRecordingManager(
        core: core,
        platform: platform,
        providers: providers,
        queue: queue,
        bridge: bridge,
        privacyRunGate: privacyRunGate,
        recognizerRegistry: registries.recognizerRegistry,
        recognitionOptionsProvider: recognitionOptionsProvider,
        runPreflight: recognitionRunPreflight
      ),
      workflowAudioRunController: WorkflowAudioRunController(
        audioCaptureService: providers.workflowAudioCaptureService,
        capturedAudioProcessingQueue: queue,
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
        privacyRunGate: privacyRunGate,
        cleanupOwner: providers.managedTemporaryAudioCleanupOwner
      ),
      deepgramAudioTestController: DeepgramAudioTestController(
        audioCaptureService: providers.diagnosticsAudioCaptureService,
        diagnostics: core.diagnostics,
        privacyPreflight: AppBootstrap.makeDeepgramDiagnosticPrivacyPreflight(
          privacyRunGate: privacyRunGate,
          privacyContextProvider: {
            await platform.contextProvider.capturePrivacyContext()
          }
        ),
        privacyAuthorization: AppBootstrap.makeDeepgramDiagnosticPrivacyAuthorization(
          privacyRunGate: privacyRunGate,
          privacyContextProvider: {
            await platform.contextProvider.capturePrivacyContext()
          }
        ),
        cleanupOwner: providers.managedTemporaryAudioCleanupOwner
      ),
      failedAudioRecoveryController: failedAudioRecoveryController,
      clipboardGroupEventScheduler: core.clipboardGroupEventScheduler,
      privacyRunGate: privacyRunGate,
      authorizeWorkflowRunAction: authorizeWorkflowRunAction,
      authorizeClipboardItemRunAction: authorizeClipboardItemRunAction,
      workflowSelectionBridge: bridge,
      clipboardCaptureControlBridge: clipboardCaptureControlBridge,
      globalInputCapabilityBridge: globalInputCapabilityBridge,
      workflowManifestStartupDiagnostic: manifestResult.diagnostic,
      workflows: manifestResult.manifest.workflows
    )
  }

  private static func makeCoordinator(
    core: CoreServices,
    platform: PlatformServices,
    registries: Registries,
    recognitionOptionsProvider: @escaping RecognitionOptionsProvider,
    recognitionAudioCleanupOwner: ManagedTemporaryAudioCleanupOwner
  ) -> SessionCoordinator {
    SessionCoordinator(
      contextProvider: platform.contextProvider,
      privacyContextProvider: {
        await platform.contextProvider.capturePrivacyContext()
      },
      recognizerRegistry: registries.recognizerRegistry,
      transformerRegistry: registries.transformerRegistry,
      actionRegistry: registries.actionRegistry,
      candidateResolver: core.candidateResolver,
      deliveryStack: core.deliveryStack,
      eventBus: core.eventBus,
      diagnostics: core.diagnostics,
      runReceiptRecorder: core.runReceiptRecorder,
      vocabularyRuleProvider: {
        try core.vocabularyRuleSource.currentRules()
      },
      recognitionOptionsProvider: recognitionOptionsProvider,
      recognitionAudioCleanupOwner: recognitionAudioCleanupOwner,
      defaultStackDeliveryActionID: "inject.text"
    )
  }

  private static func makeStackPasteController(
    core: CoreServices,
    platform: PlatformServices,
    coordinator: SessionCoordinator,
    captureControlBridge: ClipboardCaptureControlBridge
  ) -> StackPasteController {
    StackPasteController(
      hotkeyTap: platform.hotkeyTap,
      pasteboard: platform.pasteboard,
      contextProvider: platform.contextProvider,
      deliveryStack: core.deliveryStack,
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
      cleanupOwner: providers.managedTemporaryAudioCleanupOwner
    )
  }

  private static func makeRecognitionOptionsProvider(
    core: CoreServices,
    providers: ProviderServices
  ) -> RecognitionOptionsProvider {
    { workflow, context in
      let language = await resolvedRecognitionLanguage(
        for: workflow,
        providers: providers
      )
      let rules: [VocabularyRule]
      do {
        rules = try core.vocabularyRuleSource.currentRules()
      } catch {
        await core.diagnostics.record(
          recognitionHintResolutionDiagnostic(
            outcome: "load-failed",
            count: 0,
            omittedCount: 0,
            rejectedCount: 0,
            recognizerID: workflow.pipeline.recognizerID
          )
        )
        return SpeechRecognitionRequestOptions(language: language)
      }

      let resolution = VocabularyRecognitionHintResolver().resolve(
        rules: rules,
        context: VocabularyRuleContext(
          contextSnapshot: context,
          clipboardGroupID: workflow.targetClipboardGroupID,
          locale: language
        )
      )
      if resolution.validKeytermCount > 0 || resolution.rejectedKeytermCount > 0 {
        let outcome =
          resolution.omittedKeytermCount > 0
          ? "limited"
          : (resolution.rejectedKeytermCount > 0 ? "partial" : "resolved")
        await core.diagnostics.record(
          recognitionHintResolutionDiagnostic(
            outcome: outcome,
            count: resolution.hints.keyterms.count,
            omittedCount: resolution.omittedKeytermCount,
            rejectedCount: resolution.rejectedKeytermCount,
            recognizerID: workflow.pipeline.recognizerID
          )
        )
      }
      return SpeechRecognitionRequestOptions(
        language: language,
        hints: resolution.hints
      )
    }
  }

  private static func resolvedRecognitionLanguage(
    for workflow: WorkflowDefinition,
    providers: ProviderServices
  ) async -> String? {
    switch workflow.pipeline.recognizerID {
    case "deepgram.prerecorded":
      if let override = AppSettingsLoader.trimmedNonEmpty(
        workflow.metadata[WorkflowMetadataKey.languageOverride]
      ) {
        return override
      }
      let configuration = await providers.deepgramConfigurationProvider()
      return AppSettingsLoader.trimmedNonEmpty(configuration?.language)
    case "sherpa-onnx.local", SherpaStreamingCaptureRecognizer.recognizerID:
      // Both shipped local models default to multilingual automatic detection.
      // The recognizer still applies an explicit per-workflow language override
      // for SenseVoice when one exists.
      return nil
    default:
      return AppSettingsLoader.trimmedNonEmpty(
        workflow.metadata[WorkflowMetadataKey.languageOverride]
      )
    }
  }

  private static func recognitionHintResolutionDiagnostic(
    outcome: String,
    count: Int,
    omittedCount: Int,
    rejectedCount: Int,
    recognizerID: String
  ) -> DiagnosticEvent {
    DiagnosticEvent(
      subsystem: .providers,
      level: outcome == "load-failed" ? .warning : .info,
      event: "session.recognition-hints.resolved",
      message: "Recognition hints were resolved for the current run.",
      metadata: [
        "count": String(count),
        "omittedCount": String(omittedCount),
        "outcome": outcome,
        "recognizerID": recognizerID,
        "rejectedCount": String(rejectedCount),
      ]
    )
  }

  private static func makePrivacyRunGate(core: CoreServices) -> PrivacyRunGate {
    PrivacyRunGate(
      settingsProvider: {
        try core.privacySettingsSource.currentSettings()
      },
      cloudConfirmationProvider: { workflow, _, processingDestinations in
        await MainActor.run {
          CloudPrivacyConfirmation.confirm(
            workflow: workflow,
            processingDestinations: processingDestinations
          )
        }
      }
    )
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
          // sherpa-onnx release archives are public and never consume the
          // retired Whisper repository token. Remove both its legacy SQLite
          // value and Keychain item through the serialized migration store so
          // an older credential is not retained after the provider cutover.
          guard !Task.isCancelled else { return }
          try? await platform.credentialStore.removeCredential(
            for: .legacyWhisperKitModelToken
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
          if let startupDiagnostic = core.persistence.startupDiagnostic {
            await core.diagnostics.record(startupDiagnostic)
          }
          guard !Task.isCancelled else { return }
          await core.diagnostics.record(providers.localSpeechStartupDiagnostic)
          guard !Task.isCancelled else { return }
          let deepgramConfiguration = await providers.deepgramConfigurationProvider()
          guard !Task.isCancelled else { return }
          if let deepgramConfiguration {
            await core.diagnostics.record(
              DeepgramRecognizer.startupDiagnostic(configuration: deepgramConfiguration))
          } else {
            await core.diagnostics.record(DeepgramRecognizer.startupDiagnostic())
          }
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
            startClipboardConsumer: { clipboardCaptureEnabled in
              await runtime.stackPasteController.start(
                initialClipboardCaptureEnabled: clipboardCaptureEnabled,
                preferenceRevision: 0
              )
            },
            startSharedInputProducer: {
              await runtime.globalInputOwner.start()
            }
          )
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
      stackPasteController: runtime.stackPasteController,
      recordingSessionManager: runtime.recordingSessionManager,
      shutdown: ApplicationShutdownOperation.make(
        sealMarkdownPostCommitCleanups: {
          await providers.markdownFileAppendCoordinator.seal()
        },
        sealClipboardMutations: {
          await model.sealClipboardMutationsForApplicationShutdown()
        },
        stopStartupTasks: {
          await AppBootstrap.stopStartupTasks(
            coordinator: startupTaskCoordinator
          )
        },
        stopSettingsReads: {
          await model.stopSettingsReadTasksForApplicationShutdown()
        },
        drainClipboardMutations: {
          await model.drainClipboardMutationsForApplicationShutdown()
        },
        cancelRecording: {
          await runtime.recordingSessionManager.stopForApplicationShutdown()
        },
        cancelWorkflowRun: {
          async let audioRunCancellation: Void = runtime.workflowAudioRunController.shutdown()
          async let interactiveRunCancellation: Void =
            model
            .stopInteractiveWorkflowRunsForApplicationShutdown()
          _ = await (audioRunCancellation, interactiveRunCancellation)
        },
        cancelFailedAudioRecoveryRetries: {
          await model.stopFailedAudioRecoveryRetriesForApplicationShutdown()
          await runtime.failedAudioRecoveryController?.stopForApplicationShutdown()
        },
        stopLocalHistoryMaintenance: {
          await model.stopLocalHistoryMaintenanceForApplicationShutdown()
        },
        shutdownAudioQueue: {
          await runtime.capturedAudioProcessingQueue.shutdown()
        },
        cancelDeepgramTest: {
          await runtime.deepgramAudioTestController.shutdown()
        },
        drainTextInjectionClipboardRecovery: {
          await platform.injectionEngine
            .drainPendingClipboardRecoveryForApplicationShutdown()
        },
        stopStackPaste: {
          await runtime.stackPasteController.stop()
        },
        stopGlobalInputOwner: {
          await runtime.globalInputOwner.stop()
        },
        stopClipboardGroupScheduler: {
          await core.deliveryStack.removeClipboardGroupEventSink()
          await runtime.clipboardGroupEventScheduler.shutdown()
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
          await core.deliveryStack.drainPersistenceForApplicationShutdown()
        }
      ),
      cancelLiveAudio: { runID in
        await model.markLiveAudioRunStoppedByUser(runID: runID)
        async let recordingCancellation: Void = runtime.recordingSessionManager
          .cancelCurrentRecording(runID: runID)
        async let workflowCancellation: Void = runtime.workflowAudioRunController
          .cancelRun(runID: runID)
        _ = await (recordingCancellation, workflowCancellation)
      },
      useClipboardItem: { item, target in
        await runtime.stackPasteController.performProgrammaticPaste {
          await useClipboardItem(
            item,
            target: target,
            core: core,
            platform: platform,
            coordinator: runtime.coordinator
          )
        }
      },
      setClipboardCaptureEnabled: { isEnabled, preferenceRevision in
        Task {
          await runtime.stackPasteController.setClipboardCaptureEnabled(
            isEnabled,
            preferenceRevision: preferenceRevision
          )
        }
      },
      ignoreNextExternalClipboardChange: {
        Task {
          await runtime.stackPasteController.ignoreNextExternalClipboardChange()
        }
      },
      updateClipboardPanelHotkey: { binding in
        platform.hotkeyTap.setClipboardPanelHotkeyBinding(binding)
      },
      beginClipboardPanelShortcutRecording: {
        platform.hotkeyTap.beginClipboardPanelShortcutRecording()
      },
      endClipboardPanelShortcutRecording: { suspensionID in
        platform.hotkeyTap.endClipboardPanelShortcutRecording(suspensionID)
      },
      commitClipboardPanelShortcutRecording: { suspensionID, keyCode in
        platform.hotkeyTap.commitClipboardPanelShortcutRecording(
          suspensionID,
          keyCode: keyCode
        )
      }
    )
  }

  private static func useClipboardItem(
    _ item: ClipboardHistoryItem,
    target: ClipboardPasteTargetIdentity,
    core: CoreServices,
    platform: PlatformServices,
    coordinator: SessionCoordinator
  ) async {
    await AppBootstrap.useClipboardItem(
      item,
      target: target,
      capturePrivacyContext: {
        await platform.contextProvider.capturePrivacyContext()
      },
      deliverText: { subject, contextSnapshot in
        await coordinator.deliverClipboardItem(
          subject: subject,
          actionID: "inject.text",
          contextSnapshot: contextSnapshot
        )
      },
      claimRichItem: { subject in
        try await core.deliveryStack.beginClipboardItemUseLease(
          matching: subject
        )
      },
      injectClipboardSnapshot: { snapshot, targetFocus in
        try await platform.injectionEngine.injectClipboardSnapshot(
          snapshot,
          targetFocus: targetFocus
        )
      },
      completeUse: { leaseID in
        await core.deliveryStack.completeDelivery(leaseID: leaseID)
      },
      failUse: { leaseID in
        await core.deliveryStack.failDelivery(leaseID: leaseID, error: nil)
      },
      reportFailure: { message in
        await core.eventBus.publish(
          .runFailed(runID: nil, workflow: nil, message: message)
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
    let clipboardItemDryRunPreparer = ClipboardItemDryRunPreparer(
      deliveryStack: core.deliveryStack,
      privacyRunGate: runtime.privacyRunGate,
      privacyContextProvider: {
        await platform.contextProvider.capturePrivacyContext()
      }
    )
    var model: AppModel?
    model = AppModel(
      workflows: runtime.workflows,
      eventBus: core.eventBus,
      sessionCoordinator: runtime.coordinator,
      outputActionRegistry: registries.actionRegistry,
      deliveryStack: core.deliveryStack,
      candidateResolver: core.candidateResolver,
      historyRepository: core.persistence.historyRepository,
      runHistoryBrowser: core.persistence.runHistoryBrowser,
      runReceiptRepository: core.persistence.runReceiptRepository,
      localHistoryMaintenance: core.localHistoryMaintenance,
      diagnosticRepository: core.persistence.diagnosticRepository,
      settingsStore: core.persistence.settingsStore,
      credentialStore: platform.credentialStore,
      localPersistenceStatus: core.persistence.localPersistenceStatus,
      vocabularyRuleSource: core.vocabularyRuleSource,
      privacySettingsSource: core.privacySettingsSource,
      localSpeechSettingsSource: providers.localSpeechSettingsSource,
      localSpeechAvailability: providers.localSpeechAvailability,
      trustedLocalSpeechModels: providers.trustedLocalSpeechModels,
      defaultLocalSpeechModelIdentifier: providers.defaultLocalSpeechModelIdentifier,
      warmLocalSpeechForCaptureAction: { settings in
        do {
          let modelIdentifier = LocalSpeechModelCatalog.effectiveModelIdentifier(
            settings: settings
          )
          let backend = try LocalSpeechModelCatalog.backend(for: modelIdentifier)
          return try await AppBootstrap.prepareLocalSpeechModelAndAudioFrontend(
            prewarmAudioFrontend: settings.prewarm,
            prepareModel: {
              try await AppBootstrap.prepareFinalModelAndStreamingPreview(
                prepareFinalModel: {
                  try await providers.localSpeechRecognizer.prepareForUse(of: backend)
                  switch backend {
                  case .sherpaOnnx:
                    let configuration = try AppBootstrap.sherpaOnnxConfiguration(
                      settings: settings,
                      trustedModelIdentifiers:
                        SherpaOnnxModelCatalog.distributableModelIdentifiers,
                      defaultModelIdentifier: SherpaOnnxModelCatalog.defaultModelID.rawValue
                    )
                    return try await providers.sherpaOnnxModelPreparer.prepareModel(
                      using: AppBootstrap.modelInstallationConfiguration(from: configuration)
                    )
                  case .mlxAudioSwift:
                    return try await providers.mlxAudioSwiftRecognizer.prepareModel(
                      modelIdentifier: modelIdentifier,
                      downloadIfNeeded: settings.downloadIfNeeded
                    )
                  }
                },
                prepareStreamingPreview: {
                  try await providers.streamingPreviewService.prepare(
                    downloadIfNeeded: settings.downloadIfNeeded
                  )
                },
                reportStreamingPreviewFailure: { _ in
                  await core.diagnostics.record(
                    DiagnosticEvent(
                      subsystem: .providers,
                      level: .warning,
                      event: "provider.sherpa-onnx.streaming-preview-unavailable",
                      message:
                        "Fixed local streaming preview is unavailable; capture continues without subtitle hypotheses.",
                      metadata: [
                        "model": SherpaStreamingPreviewService.modelID
                      ]
                    )
                  )
                }
              )
            },
            prepareAudioFrontend: {
              await providers.workflowAudioCaptureService
                .prepareLocalSpeechAudioFrontendIfAuthorized()
            }
          )
        } catch {
          guard let failure = AppBootstrap.localSpeechPreparationFailure(for: error) else {
            throw CancellationError()
          }
          throw failure
        }
      },
      prepareLocalSpeechAction: { settings, progressCallback in
        do {
          let modelIdentifier = LocalSpeechModelCatalog.effectiveModelIdentifier(
            settings: settings
          )
          let backend = try LocalSpeechModelCatalog.backend(for: modelIdentifier)
          return try await AppBootstrap.prepareLocalSpeechModelAndAudioFrontend(
            prewarmAudioFrontend: settings.prewarm,
            prepareModel: {
              let previewModelByteCount =
                SherpaOnnxModelCatalog.streamingZipformerBilingualPreviewInt8
                .archiveByteCount
              let finalModelByteCount: UInt64
              switch backend {
              case .sherpaOnnx:
                guard let finalModelID = SherpaOnnxModelID(rawValue: modelIdentifier) else {
                  throw SherpaOnnxModelInstallationError.invalidCatalogDescriptor
                }
                finalModelByteCount =
                  SherpaOnnxModelCatalog.descriptor(
                    for: finalModelID
                  ).archiveByteCount
              case .mlxAudioSwift:
                guard let finalModelID = MLXAudioModelID(rawValue: modelIdentifier) else {
                  throw LocalSpeechModelSelectionError.unsupportedModelIdentifier(modelIdentifier)
                }
                finalModelByteCount =
                  MLXAudioModelCatalog.descriptor(
                    for: finalModelID
                  ).approximateDownloadByteCount
              }
              let aggregateByteCount = finalModelByteCount + previewModelByteCount
              let preparedModel =
                try await AppBootstrap
                .prepareFinalModelAndStreamingPreview(
                  prepareFinalModel: {
                    try await providers.localSpeechRecognizer.prepareForUse(of: backend)
                    switch backend {
                    case .sherpaOnnx:
                      let configuration = try AppBootstrap.sherpaOnnxConfiguration(
                        settings: settings,
                        trustedModelIdentifiers:
                          SherpaOnnxModelCatalog.distributableModelIdentifiers,
                        defaultModelIdentifier: SherpaOnnxModelCatalog.defaultModelID.rawValue
                      )
                      return try await providers.sherpaOnnxModelPreparer.prepareModel(
                        using: AppBootstrap.modelInstallationConfiguration(
                          from: configuration
                        ),
                        progress: { update in
                          let progress = Progress(
                            totalUnitCount: Int64(aggregateByteCount)
                          )
                          progress.completedUnitCount = Int64(
                            min(update.completedByteCount, finalModelByteCount)
                          )
                          progressCallback(progress)
                        }
                      )
                    case .mlxAudioSwift:
                      let initial = Progress(totalUnitCount: Int64(aggregateByteCount))
                      progressCallback(initial)
                      let prepared = try await providers.mlxAudioSwiftRecognizer.prepareModel(
                        modelIdentifier: modelIdentifier,
                        downloadIfNeeded: settings.downloadIfNeeded
                      )
                      let loaded = Progress(
                        totalUnitCount: Int64(aggregateByteCount)
                      )
                      loaded.completedUnitCount = Int64(finalModelByteCount)
                      progressCallback(loaded)
                      return prepared
                    }
                  },
                  prepareStreamingPreview: {
                    try await providers.streamingPreviewService.prepare(
                      downloadIfNeeded: settings.downloadIfNeeded,
                      progress: { update in
                        let progress = Progress(
                          totalUnitCount: Int64(aggregateByteCount)
                        )
                        progress.completedUnitCount = Int64(
                          finalModelByteCount
                            + min(update.completedByteCount, previewModelByteCount)
                        )
                        progressCallback(progress)
                      }
                    )
                  },
                  reportStreamingPreviewFailure: { _ in
                    await core.diagnostics.record(
                      DiagnosticEvent(
                        subsystem: .providers,
                        level: .warning,
                        event: "provider.sherpa-onnx.streaming-preview-unavailable",
                        message:
                          "Fixed local streaming preview is unavailable; capture continues without subtitle hypotheses.",
                        metadata: [
                          "model": SherpaStreamingPreviewService.modelID
                        ]
                      )
                    )
                  }
                )
              let completed = Progress(totalUnitCount: Int64(aggregateByteCount))
              completed.completedUnitCount = Int64(aggregateByteCount)
              progressCallback(completed)
              return preparedModel
            },
            prepareAudioFrontend: {
              await providers.workflowAudioCaptureService
                .prepareLocalSpeechAudioFrontendIfAuthorized()
            }
          )
        } catch {
          guard let failure = AppBootstrap.localSpeechPreparationFailure(for: error) else {
            throw CancellationError()
          }
          throw failure
        }
      },
      setLocalSpeechRuntimeEnabledAction: { isEnabled in
        if !isEnabled {
          Task {
            try? await providers.localSpeechRecognizer.releaseLoadedModel()
            await providers.streamingPreviewService.releaseLoadedModel()
          }
        }
      },
      releaseLocalSpeechRuntimeAction: {
        Task {
          try? await providers.localSpeechRecognizer.releaseLoadedModel()
          await providers.streamingPreviewService.releaseLoadedModel()
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
        await providers.streamingPreviewService.releaseLoadedModel()
      },
      startWorkflowAudioRunAction: { workflow, binding in
        try await runtime.workflowAudioRunController.startRun(workflow: workflow, binding: binding)
      },
      finishWorkflowAudioRunAction: {
        try await runtime.workflowAudioRunController.finishRun()
      },
      startDeepgramAudioTestAction: { settings in
        try await runtime.deepgramAudioTestController.startTest(settings: settings)
      },
      finishDeepgramAudioTestAction: { settings in
        try await runtime.deepgramAudioTestController.finishTest(settings: settings)
      },
      cancelDeepgramAudioTestAction: {
        await runtime.deepgramAudioTestController.cancelTest()
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
      authorizeWorkflowRunAction: runtime.authorizeWorkflowRunAction,
      authorizeClipboardItemRunAction: runtime.authorizeClipboardItemRunAction,
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
      previewClipboardItemAction: { itemID, operation, workflow in
        try await clipboardItemDryRunPreparer.preview(
          itemID: itemID,
          operation: operation,
          workflow: workflow
        )
      },
      writeClipboardTextAction: { text in
        _ = platform.pasteboard.writePlainText(text)
      },
      pasteTopOfStackAction: {
        Task { await runtime.stackPasteController.pasteTopOfStack() }
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
      }
    )
    guard let resolvedModel = model else {
      preconditionFailure("AppModel was not initialized")
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
      let databaseRequiresExistingKey =
        try SQLitePersistenceStore
        .requiresExistingDataProtectionKey(databaseURL: databaseURL)
      let recoveryRequiresExistingKey =
        EncryptedFailedAudioRecoveryStore
        .requiresExistingDataProtectionKey(directoryURL: recoveryDirectoryURL)
      let keyStore = KeychainLocalDataKeyStore(
        service: localDataKeychainServiceIdentifier
      )
      let keyDecision = try LocalDataKeyResolver.resolve(
        candidates: keyStore.loadCandidates(),
        databaseRequiresExistingKey: databaseRequiresExistingKey,
        recoveryRequiresExistingKey: recoveryRequiresExistingKey,
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
        recoveryDirectoryURL: recoveryDirectoryURL
      )
      let failedAudioRecoveryStore = try EncryptedFailedAudioRecoveryStore(
        directoryURL: recoveryDirectoryURL,
        localDataProtector: localDataProtector
      )
      let keyFinalization = try keyStore.finalizeValidatedKey(selectedKey)
      // Do not publish durable storage as ready if a recovery binding appeared
      // during finalization. The distinct legacy key remains available for it.
      try revalidateCurrentBindings(
        candidate: selectedKey,
        databaseURL: databaseURL,
        recoveryDirectoryURL: recoveryDirectoryURL
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
        clipboardPersistenceStore: store,
        residuePurger: RillStorageResiduePurger(
          rawStoragePurger: store,
          temporaryFileCleanupService: temporaryFileCleanupService
        ),
        temporaryFileCleanupService: temporaryFileCleanupService,
        failedAudioRecoveryStore: failedAudioRecoveryStore,
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
      clipboardPersistenceStore: nil,
      residuePurger: nil,
      temporaryFileCleanupService: temporaryFileCleanupService,
      failedAudioRecoveryStore: nil,
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
    recoveryDirectoryURL: URL
  ) throws {
    try LocalDataKeyResolver.revalidate(
      candidate: candidate,
      databaseRequiresExistingKey:
        try SQLitePersistenceStore
        .requiresExistingDataProtectionKey(databaseURL: databaseURL),
      recoveryRequiresExistingKey:
        EncryptedFailedAudioRecoveryStore
        .requiresExistingDataProtectionKey(directoryURL: recoveryDirectoryURL),
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
  static func confirm(
    workflow: WorkflowDefinition,
    processingDestinations: [PrivacyProcessingDestination]
  ) -> Bool {
    let usesChinese = Locale.current.identifier.lowercased().hasPrefix("zh")
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = usesChinese ? "允许云端处理？" : "Allow cloud processing?"
    alert.informativeText = CloudPrivacyConfirmationCopy.informativeText(
      workflowName: workflow.name,
      processingDestinations: processingDestinations,
      usesChinese: usesChinese
    )
    alert.addButton(withTitle: usesChinese ? "继续" : "Continue")
    alert.addButton(withTitle: usesChinese ? "取消" : "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
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
    return switch (usesChinese, sendsSpeech, sendsText) {
    case (false, true, false):
      "The workflow “\(workflowName)” will stream microphone audio and any matching cloud-recognition terms to its cloud speech service while recording. Rill continuously checks the current focus and privacy settings and stops the run if they become restricted. Nothing from this run has left this Mac yet."
    case (true, true, false):
      "工作流“\(workflowName)”会在录音期间，将麦克风音频以及范围匹配的云端识别术语流式发送到云端语音服务。Rill 会持续检查当前焦点与隐私设置；一旦变为受限状态，就会停止本次运行。本次内容尚未离开本机。"
    case (false, false, true):
      "The workflow “\(workflowName)” will send its final text to the configured HTTPS webhook. Nothing from this run has left this Mac yet."
    case (true, false, true):
      "工作流“\(workflowName)”会将最终文本发送到配置的 HTTPS Webhook。本次内容尚未离开本机。"
    case (false, true, true):
      "The workflow “\(workflowName)” will stream microphone audio and matching cloud-recognition terms while recording, then send final text to the configured HTTPS webhook. Rill continuously checks the current focus and privacy settings and stops the run if they become restricted. Nothing from this run has left this Mac yet."
    case (true, true, true):
      "工作流“\(workflowName)”会在录音期间流式发送麦克风音频和范围匹配的云端识别术语，并将最终文本发送到配置的 HTTPS Webhook。Rill 会持续检查当前焦点与隐私设置；一旦变为受限状态，就会停止本次运行。本次内容尚未离开本机。"
    case (false, false, false):
      "The workflow “\(workflowName)” requested cloud processing, but its cloud destination could not be classified. Cancel unless this is expected. Nothing from this run has left this Mac yet."
    case (true, false, false):
      "工作流“\(workflowName)”请求了云端处理，但无法对云端目的地进行分类。如非预期，请取消。本次内容尚未离开本机。"
    }
  }
}

private enum AppSettingsLoader {
  static func loadDeepgramConfiguration(
    from settingsStore: (any SettingsStore)?,
    credentialStore: (any SecureCredentialStore)?
  ) async -> DeepgramRecognizer.Configuration? {
    do {
      let settingKeys: [AppSettingKey] = [
        .deepgramBaseURL,
        .deepgramModel,
        .deepgramLanguage,
      ]
      let storedSnapshot =
        try await settingsStore?.settingsSnapshot(
          forKeys: settingKeys
        ) ?? .empty
      guard storedSnapshot.unavailableKeys.isDisjoint(with: Set(settingKeys)) else {
        return nil
      }
      let storedSettings = storedSnapshot.values
      let storedAPIKey = try await credentialStore?.credential(for: .deepgramAPIKey)
      return DeepgramRecognizer.Configuration(
        apiKey: trimmedNonEmpty(storedAPIKey),
        baseURL: trimmedNonEmpty(storedSettings[.deepgramBaseURL]) ?? DeepgramSettings().baseURL,
        model: trimmedNonEmpty(storedSettings[.deepgramModel]) ?? DeepgramSettings().model,
        language: trimmedNonEmpty(storedSettings[.deepgramLanguage])
      )
    } catch {
      return nil
    }
  }

  static func trimmedNonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

}

@MainActor
private final class WorkflowSelectionBridge {
  weak var model: AppModel?

  func enabledWorkflows(for trigger: TriggerBinding) -> [WorkflowDefinition] {
    model?.enabledWorkflows(for: trigger) ?? []
  }

  func longRecordingModeEnabled() -> Bool {
    model?.longRecordingModeEnabled ?? false
  }

  func clipboardGroupWorkflowRegistrations() -> [ClipboardGroupWorkflowRegistration] {
    guard let model else { return [] }
    return model.workflows.compactMap { workflow in
      AppBootstrap.makeClipboardGroupWorkflowRegistration(
        for: workflow,
        isEnabled: model.isWorkflowEnabled(workflow)
      )
    }
  }
}
