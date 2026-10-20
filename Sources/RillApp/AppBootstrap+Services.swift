import RillSpeechContracts
import AppKit
import Dispatch
import Foundation
import RillClipboard
import RillCore
import RillPersistence
import RillPlatform
import RillProviders
import RillRecords
import RillSpeech
import RillUI
import RillWorkflows

struct PersistenceBackends {
  let localPersistenceStatus: LocalPersistenceStatus
  let diagnosticRepository: any DiagnosticRepository & DiagnosticHistoryMaintaining
  let historyRepository: any HistoryRepository & HistoryMaintaining
  /// The single snapshot/keyset boundary used by History and global search.
  /// It is unavailable when durable SQLite persistence failed to initialize;
  /// callers must surface that state instead of rebuilding a lossy projection
  /// from independent repository reads.
  let runHistoryBrowser: (any RunHistoryBrowsing)?
  /// `nil` means terminal receipts cannot be durably stored. The app must
  /// not substitute an ephemeral repository and publish it as durable truth.
  let runReceiptRepository: (any WorkflowRunReceiptRepository & WorkflowRunReceiptMaintaining)?
  let settingsStore: (any SettingsStore)?
  let recordGraphPersistenceStore: (any RecordGraphPersistenceStore)?
  let residuePurger: (any StorageResiduePurging)?
  let temporaryFileCleanupService: RillTemporaryFileCleanupService
  let failedAudioRecoveryStore: (any FailedAudioRecoveryStore)?
  let corpusRecordingArchiveStore: (any CorpusRecordingArchiveStore & CorpusRecordingArchiveReading)?
  let startupDiagnostic: DiagnosticEvent?
}

struct UnavailableWorkflowRunReceiptRepository: WorkflowRunReceiptRepository {
  func insertTerminal(_ receipt: WorkflowRunReceipt) async throws { throw RunHistoryGenerationError.unsupported }
  func receipts(matching query: WorkflowRunReceiptQuery) async throws -> [WorkflowRunReceipt] { throw RunHistoryGenerationError.unsupported }
  func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration { throw RunHistoryGenerationError.unsupported }
  func insertTerminal(_ receipt: WorkflowRunReceipt, generation: RunHistoryWriteGeneration) async throws { throw RunHistoryGenerationError.unsupported }
}

struct UnavailableRunHistoryBrowser: RunHistoryBrowsing {
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

struct CoreServices {
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

struct PlatformServices {
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

struct ProviderServices {
  let textRewriteTransformer: OpenAITextRewriteTransformer
  let jevSessionSettings: DecisionModelSettingsSource
  let jevPolishingGate: DecisionTextPolishingGate
  let hotwordSelection: HotwordSelection
  let diagnosticsAudioCaptureService: AVAudioCaptureService
  let managedTemporaryAudioCleanupOwner: ManagedTemporaryAudioCleanupOwner
  let markdownFileAppendCoordinator: MarkdownFileAppendCoordinator
  let languageModelSettingsSource: LanguageModelSettingsSource
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

struct Registries {
  let recognizerRegistry: SpeechRecognizerRegistry
  let transformerRegistry: TextTransformerRegistry
  let actionRegistry: OutputActionRegistry
}

struct RuntimeServices {
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
  let corpusRecordingArchiveController: CorpusRecordingArchiveController?
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
final class SystemClipboardCaptureControlBridge {
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
final class GlobalInputCapabilityBridge {
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
final class SpeechPlaybackPresentationBridge {
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
final class SpeechModelPoolPresentationBridge {
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
final class CloudProcessingAuthorizationBridge {
  weak var model: AppModel?

  func attach(_ model: AppModel) {
    self.model = model
  }

  func grant(_ authorization: CloudProcessingAuthorization) -> Bool {
    model?.grantCloudProcessingAuthorization(authorization) ?? false
  }
}

@MainActor
final class LiveAudioCancellationPresentationBridge {
  weak var model: AppModel?

  func attach(_ model: AppModel) {
    self.model = model
  }

  func markStoppedByUser(runID: UUID) {
    model?.markLiveAudioRunStoppedByUser(runID: runID)
  }
}
