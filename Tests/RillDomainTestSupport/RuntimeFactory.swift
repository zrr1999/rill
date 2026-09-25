import Foundation
import RillCore
import RillPlatform
import RillWorkflows
import RillRecords
import RillKnowledge
import RillSpeech

public func makeTestSessionCoordinator(
        lane: WorkflowRunLane = .primary,
        privacyContextProvider: @escaping @Sendable () async -> ContextSnapshot = { .empty },
        recognizerRegistry: SpeechRecognizerRegistry,
        transformerRegistry: TextTransformerRegistry,
        textPolishingGate: (any TextPolishingGate)? = nil,
        actionRegistry: OutputActionRegistry,
        candidateResolver: CandidateResolver,
        recordStore: RecordStore = RecordStore(),
        recordDeliveryCoordinator: RecordDeliveryCoordinator? = nil,
        eventBus: EventBus,
        diagnostics: DiagnosticsRecorder? = nil,
        runReceiptRecorder: WorkflowRunReceiptRecorder? = nil,
        vocabularyRuleProvider: @escaping @Sendable () async throws -> [VocabularyRule] = { [] },
        vocabularyCollectionProvider:
            (@Sendable () async throws -> [VocabularyCollection])? = nil,
        recognitionOptionsProvider: @escaping @Sendable (
            WorkflowDefinition,
            ContextSnapshot
        ) async throws -> SpeechRecognitionRequestOptions = { _, _ in .empty },
        recognitionTimeoutPolicy: RecognitionTimeoutPolicy = .standard,
        recognitionAudioCleanupOwner: ManagedTemporaryAudioCleanupOwner =
            ManagedTemporaryAudioCleanupOwner(),
        defaultRecordDeliveryActionID: String = "system-clipboard.copy",
        processingClock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
) -> SessionCoordinator {
  SessionCoordinator(
    lane: lane,
    privacyContextProvider: privacyContextProvider,
    recognizerRegistry: recognizerRegistry,
    transformerRegistry: transformerRegistry,
    textPolishingGate: textPolishingGate,
    actionRegistry: actionRegistry,
    candidateResolver: candidateResolver,
    recordStore: recordStore,
    recordDeliveryCoordinator: recordDeliveryCoordinator,
    eventBus: eventBus,
    diagnostics: diagnostics,
    runReceiptRecorder: runReceiptRecorder,
    vocabularyRuleProvider: vocabularyRuleProvider,
    vocabularyCollectionProvider: vocabularyCollectionProvider,
    recognitionOptionsProvider: recognitionOptionsProvider,
    recognitionTimeoutPolicy: recognitionTimeoutPolicy,
    recognitionAudioCleanupOwner: recognitionAudioCleanupOwner,
    defaultRecordDeliveryActionID: defaultRecordDeliveryActionID,
    processingClock: processingClock,
    recognitionAudioIsolator: TemporaryAudioFiles.isolate
  )
}

public func makeTestRecordingSessionManager(
    audioCaptureService: any AudioCaptureService,
    hotkeyTap: any GlobalInputSource,
    capturedAudioProcessingQueue: CapturedAudioProcessingQueue,
    eventBus: EventBus,
    diagnostics: DiagnosticsRecorder? = nil,
    privacyRunGate: PrivacyRunGate? = nil,
    workflowProvider: @escaping @Sendable () async -> [WorkflowDefinition],
    contextProvider: @escaping @Sendable () async -> ContextSnapshot = { .empty },
    privacyContextProvider: (@Sendable () async -> ContextSnapshot)? = nil,
    authorizedContextProvider: (@Sendable (PrivacyPolicyDecision) async -> ContextSnapshot)? = nil,
    focusIdentitySampleProvider: @escaping @Sendable () async -> FocusPrivacyIdentitySample = {
      FocusPrivacyIdentitySample(
        focus: ContextSnapshot.empty.focus,
        applicationActivationRevision: 0
      )
    },
    targetBoundAuthorizedContextProvider: (
      @Sendable (
        PrivacyPolicyDecision,
        FocusPrivacyIdentitySample
      ) async -> ContextSnapshot?
    )? = nil,
    recognitionOptionsProvider:
      @escaping @Sendable (
        WorkflowDefinition,
        ContextSnapshot
      ) async throws -> SpeechRecognitionRequestOptions = { _, _ in .empty },
    runPreflight: @escaping RecognitionRunPreflight = { _ in },
    liveAuthorizationMonitorInterval: Duration = .milliseconds(50),
    longRecordingModeProvider: @escaping @Sendable () async -> Bool = { false },
    recordingDurationLimitProvider: @escaping @Sendable () async -> RecordingDurationLimit = {
      .fiveMinutes
    },
    recognizerDurationProvider: @escaping @Sendable (String) -> Double? = { _ in nil },
    pushToTalkGestureStateProvider: (@Sendable (PushToTalkGesture) -> Bool)? = nil,
    cleanupOwner: ManagedTemporaryAudioCleanupOwner = ManagedTemporaryAudioCleanupOwner(),
    recordingCueAction:
      @escaping @Sendable (RecordingInteractionCue, RecordingCueToken) async -> Void = { _, _ in }
) -> RecordingSessionManager {
  RecordingSessionManager(
    audioCaptureService: audioCaptureService,
    hotkeyTap: hotkeyTap,
    capturedAudioProcessingQueue: capturedAudioProcessingQueue,
    eventBus: eventBus,
    diagnostics: diagnostics,
    privacyRunGate: privacyRunGate,
    workflowProvider: workflowProvider,
    contextProvider: contextProvider,
    privacyContextProvider: privacyContextProvider,
    authorizedContextProvider: authorizedContextProvider,
    focusIdentitySampleProvider: focusIdentitySampleProvider,
    targetBoundAuthorizedContextProvider: targetBoundAuthorizedContextProvider,
    recognitionOptionsProvider: recognitionOptionsProvider,
    runPreflight: runPreflight,
    liveAuthorizationMonitorInterval: liveAuthorizationMonitorInterval,
    longRecordingModeProvider: longRecordingModeProvider,
    recordingDurationLimitProvider: recordingDurationLimitProvider,
    recognizerDurationProvider: recognizerDurationProvider,
    pushToTalkGestureStateProvider: pushToTalkGestureStateProvider,
    cleanupOwner: cleanupOwner,
    recordingCueAction: recordingCueAction
  )
}

public func makeTestWorkflowAudioRunController(
    audioCaptureService: any AudioCaptureService,
    capturedAudioProcessingQueue: CapturedAudioProcessingQueue,
    diagnostics: DiagnosticsRecorder? = nil,
    eventBus: EventBus? = nil,
    privacyContextProvider: (@Sendable () async -> ContextSnapshot)? = nil,
    authorizedContextProvider: (@Sendable (PrivacyPolicyDecision) async -> ContextSnapshot)? = nil,
    recognitionOptionsProvider:
      @escaping @Sendable (
        WorkflowDefinition,
        ContextSnapshot
      ) async throws -> SpeechRecognitionRequestOptions = { _, _ in .empty },
    runPreflight: @escaping RecognitionRunPreflight = { _ in },
    liveAuthorizationMonitorInterval: Duration = .milliseconds(50),
    recognizerDurationProvider: @escaping @Sendable (String) -> Double? = { _ in nil },
    recordingDurationLimitProvider: @escaping @Sendable () async -> RecordingDurationLimit = {
      .fiveMinutes
    },
    privacyRunGate: PrivacyRunGate? = nil,
    cleanupOwner: ManagedTemporaryAudioCleanupOwner = ManagedTemporaryAudioCleanupOwner(),
    recordingCueAction: @escaping @Sendable (RecordingInteractionCue, RecordingCueToken) async -> Void = { _, _ in }
) -> WorkflowAudioRunController {
  WorkflowAudioRunController(
    audioCaptureService: audioCaptureService,
    capturedAudioProcessingQueue: capturedAudioProcessingQueue,
    diagnostics: diagnostics,
    eventBus: eventBus,
    privacyContextProvider: privacyContextProvider,
    authorizedContextProvider: authorizedContextProvider,
    recognitionOptionsProvider: recognitionOptionsProvider,
    runPreflight: runPreflight,
    liveAuthorizationMonitorInterval: liveAuthorizationMonitorInterval,
    recognizerDurationProvider: recognizerDurationProvider,
    recordingDurationLimitProvider: recordingDurationLimitProvider,
    privacyRunGate: privacyRunGate,
    cleanupOwner: cleanupOwner,
    recordingCueAction: recordingCueAction
  )
}

public func makeTestFailedAudioRecoveryController(
        store: any FailedAudioRecoveryStore,
        sessionCoordinator: SessionCoordinator,
        eventBus: EventBus,
        diagnostics: DiagnosticsRecorder? = nil,
        privacyRunGate: PrivacyRunGate? = nil,
        privacyContextProvider: (@Sendable () async -> ContextSnapshot)? = nil,
        authorizedContextProvider: (@Sendable (PrivacyPolicyDecision) async -> ContextSnapshot)? = nil,
        recognitionOptionsProvider: @escaping @Sendable (
            WorkflowDefinition,
            ContextSnapshot
        ) async throws -> SpeechRecognitionRequestOptions = { _, _ in .empty },
        runPreflight: @escaping RecognitionRunPreflight = { _ in },
        currentDate: @escaping @Sendable () -> Date = { Date() },
        removeManagedRecoveryTemporaryFile: @escaping @Sendable (CapturedAudio) throws -> Void = {
            _ = try $0.removeManagedTemporaryFile()
        },
        cleanupRecoveryTemporaryFiles: @escaping @Sendable () async -> Bool = { true },
        initialMaintenanceRetryInterval: TimeInterval = 5,
        maximumMaintenanceRetryInterval: TimeInterval = 5 * 60
) -> FailedAudioRecoveryController {
  FailedAudioRecoveryController(
    store: store,
    sessionCoordinator: sessionCoordinator,
    eventBus: eventBus,
    diagnostics: diagnostics,
    privacyRunGate: privacyRunGate,
    privacyContextProvider: privacyContextProvider,
    authorizedContextProvider: authorizedContextProvider,
    recognitionOptionsProvider: recognitionOptionsProvider,
    runPreflight: runPreflight,
    currentDate: currentDate,
    removeManagedRecoveryTemporaryFile: removeManagedRecoveryTemporaryFile,
    cleanupRecoveryTemporaryFiles: cleanupRecoveryTemporaryFiles,
    initialMaintenanceRetryInterval: initialMaintenanceRetryInterval,
    maximumMaintenanceRetryInterval: maximumMaintenanceRetryInterval
  )
}

public func makeTestCapturedAudioProcessingQueue(
        sessionCoordinator: SessionCoordinator,
        eventBus: EventBus,
        diagnostics: DiagnosticsRecorder? = nil,
        failedAudioRecoveryController: FailedAudioRecoveryController? = nil,
        benchmarkRecordingArchiveController: BenchmarkRecordingArchiveController? = nil,
        lane: CapturedAudioProcessingQueue.Lane = .interactive,
        publishesSnapshots: Bool = true,
        rejectedCapturedAudioRemoval: @escaping @Sendable (CapturedAudio) async throws -> Void = { _ = try $0.removeManagedTemporaryFile() },
        rejectedCleanupInitialRetryDelay: Duration = .milliseconds(100),
        rejectedCleanupMaximumRetryDelay: Duration = .seconds(5),
        rejectedCleanupSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        ownershipTransferObserver: @escaping @Sendable (UUID) async -> Void = { _ in }
) -> CapturedAudioProcessingQueue {
  CapturedAudioProcessingQueue(
    sessionCoordinator: sessionCoordinator,
    eventBus: eventBus,
    diagnostics: diagnostics,
    failedAudioRecoveryController: failedAudioRecoveryController,
    benchmarkRecordingArchiveController: benchmarkRecordingArchiveController,
    lane: lane,
    publishesSnapshots: publishesSnapshots,
    rejectedCapturedAudioRemoval: rejectedCapturedAudioRemoval,
    rejectedCleanupInitialRetryDelay: rejectedCleanupInitialRetryDelay,
    rejectedCleanupMaximumRetryDelay: rejectedCleanupMaximumRetryDelay,
    rejectedCleanupSleep: rejectedCleanupSleep,
    ownershipTransferObserver: ownershipTransferObserver
  )
}
