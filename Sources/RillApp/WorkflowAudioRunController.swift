import RillWorkflows
import Foundation
import RillCore

actor WorkflowAudioRunController {
  enum RunError: Error, LocalizedError, Equatable {
    case alreadyRecording
    case notRecording
    case shuttingDown

    var errorDescription: String? {
      switch self {
      case .alreadyRecording:
        return "A workflow recording is already in progress."
      case .notRecording:
        return "No workflow recording is currently active."
      case .shuttingDown:
        return "Workflow audio recording is shutting down."
      }
    }
  }

  private enum Lifecycle: Sendable, Equatable {
    case accepting
    case shuttingDown
    case terminated
  }

  private enum State: Sendable {
    case idle
    case preparing(UUID)
    case recording(
      runID: UUID,
      workflow: WorkflowDefinition,
      triggerEvent: WorkflowTriggerEvent,
      liveAudioSession: AuthorizedLiveAudioSession
    )
    /// The controller still owns the process-wide capture slot until the
    /// run-scoped finish or cancel operation crosses the capture boundary.
    case stopping(UUID)
  }

  private struct FinishingRun: Sendable {
    let operationID: UUID
    let liveAudioSession: AuthorizedLiveAudioSession
    var task: Task<Void, Error>?
  }

  private struct CaptureSignalSubscription: Sendable {
    let identity: UUID
    let control: AudioCaptureEndpointControl
    let listenerTask: Task<Void, Never>
    let watchdogTask: Task<Void, Never>
  }

  private let audioCaptureService: any AudioCaptureService
  private let capturedAudioProcessingQueue: CapturedAudioProcessingQueue
  private let diagnostics: DiagnosticsRecorder?
  private let eventBus: EventBus?
  private let privacyContextProvider: @Sendable () async -> ContextSnapshot
  private let authorizedContextProvider: @Sendable (PrivacyPolicyDecision) async -> ContextSnapshot
  private let recognitionOptionsProvider:
    @Sendable (
      WorkflowDefinition,
      ContextSnapshot
    ) async -> SpeechRecognitionRequestOptions
  private let runPreflight: RecognitionRunPreflight
  private let liveAuthorizationMonitorInterval: Duration
  private let recognizerDurationProvider: @Sendable (String) -> Double?
  private let recordingDurationLimitProvider: @Sendable () async -> RecordingDurationLimit
  private let privacyRunGate: PrivacyRunGate?
  private let cleanupOwner: ManagedTemporaryAudioCleanupOwner
  private var state: State = .idle
  private var preparingRunID: UUID?
  private var preparingWorkflow: WorkflowDefinition?
  private var preparingLiveAudioSession: AuthorizedLiveAudioSession?
  private var finishingRuns: [UUID: FinishingRun] = [:]
  private var captureSignalSubscriptions: [UUID: CaptureSignalSubscription] = [:]
  private var captureSignalDrainTasks: [UUID: Task<Void, Never>] = [:]
  private var terminalCancellationTasks: [UUID: Task<Void, Never>] = [:]
  private var lifecycle: Lifecycle = .accepting
  private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
  private var diagnosticTailTask: Task<Void, Never>?
  private var diagnosticQueueSealed = false

  init(
    audioCaptureService: any AudioCaptureService,
    capturedAudioProcessingQueue: CapturedAudioProcessingQueue,
    diagnostics: DiagnosticsRecorder? = nil,
    eventBus: EventBus? = nil,
    contextProvider: @escaping @Sendable () async -> ContextSnapshot = { .empty },
    privacyContextProvider: (@Sendable () async -> ContextSnapshot)? = nil,
    authorizedContextProvider: (@Sendable (PrivacyPolicyDecision) async -> ContextSnapshot)? = nil,
    recognitionOptionsProvider:
      @escaping @Sendable (
        WorkflowDefinition,
        ContextSnapshot
      ) async -> SpeechRecognitionRequestOptions = { _, _ in .empty },
    runPreflight: @escaping RecognitionRunPreflight = { _ in },
    liveAuthorizationMonitorInterval: Duration = .milliseconds(50),
    recognizerDurationProvider: @escaping @Sendable (String) -> Double? = { _ in nil },
    recordingDurationLimitProvider: @escaping @Sendable () async -> RecordingDurationLimit = {
      .fiveMinutes
    },
    privacyRunGate: PrivacyRunGate? = nil,
    cleanupOwner: ManagedTemporaryAudioCleanupOwner = ManagedTemporaryAudioCleanupOwner()
  ) {
    self.audioCaptureService = audioCaptureService
    self.capturedAudioProcessingQueue = capturedAudioProcessingQueue
    self.diagnostics = diagnostics
    self.eventBus = eventBus
    self.privacyContextProvider = privacyContextProvider ?? { .empty }
    self.authorizedContextProvider = authorizedContextProvider ?? { _ in .empty }
    self.recognitionOptionsProvider = recognitionOptionsProvider
    self.runPreflight = runPreflight
    self.liveAuthorizationMonitorInterval = liveAuthorizationMonitorInterval
    self.recognizerDurationProvider = recognizerDurationProvider
    self.recordingDurationLimitProvider = recordingDurationLimitProvider
    self.privacyRunGate = privacyRunGate
    self.cleanupOwner = cleanupOwner
  }

  var isIdle: Bool {
    if case .idle = state { return finishingRuns.isEmpty && preparingRunID == nil }
    return false
  }

  func startRun(workflow: WorkflowDefinition, binding: TriggerBinding) async throws {
    try await startRun(workflow: workflow, binding: binding, triggerEvent: nil)
  }

  func startRun(
    workflow: WorkflowDefinition,
    binding: TriggerBinding,
    triggerEvent suppliedTriggerEvent: WorkflowTriggerEvent?
  ) async throws {
    guard lifecycle == .accepting else {
      throw RunError.shuttingDown
    }
    guard case .idle = state else {
      throw RunError.alreadyRecording
    }
    if let issue = WorkflowExecutionPolicy.issue(for: workflow) {
      throw SessionCoordinator.SessionError.unsupportedWorkflow(issue)
    }

    if let suppliedTriggerEvent {
      guard
        suppliedTriggerEvent.binding == binding,
        suppliedTriggerEvent.workflowID == workflow.id
      else {
        throw SessionCoordinator.SessionError.unsupportedWorkflow(.invalidEventType)
      }
    }
    let runID = suppliedTriggerEvent?.id ?? UUID()
    state = .preparing(runID)
    preparingRunID = runID
    preparingWorkflow = workflow
    var issuedLiveAudioSession: AuthorizedLiveAudioSession?
    do {
      await publishLiveSubtitleSnapshot(
        runID: runID,
        workflow: workflow,
        phase: .preparing
      )
      guard lifecycle == .accepting, isPreparing(runID) else {
        throw CancellationError()
      }
      try await runPreflight(workflow)
      guard lifecycle == .accepting, isPreparing(runID) else {
        throw CancellationError()
      }
      let liveAudioSession: AuthorizedLiveAudioSession
      if let privacyRunGate {
        liveAudioSession = try await privacyRunGate.issueLiveAudioSession(
          runID: runID,
          privacyContextProvider: privacyContextProvider,
          contextProvider: authorizedContextProvider,
          recognitionOptionsProvider: recognitionOptionsProvider,
          workflow: workflow,
          monitorInterval: liveAuthorizationMonitorInterval,
          revocationHandler: { [weak self] revokedRunID, reason in
            await self?.handleLiveAuthorizationRevocation(
              runID: revokedRunID,
              reason: reason
            )
          }
        )
      } else {
        throw SessionCoordinator.SessionError.privacyAuthorizationRequired
      }
      issuedLiveAudioSession = liveAudioSession
      guard lifecycle == .accepting,
        isPreparing(runID),
        preparingRunID == runID
      else {
        await liveAudioSession.cancel()
        throw CancellationError()
      }
      preparingLiveAudioSession = liveAudioSession
      try await liveAudioSession.startMonitoring()
      guard lifecycle == .accepting, isPreparing(runID) else {
        await liveAudioSession.cancel()
        throw CancellationError()
      }
      let recognitionOptions = liveAudioSession.audioCaptureOptions
      let triggerEvent =
        suppliedTriggerEvent
        ?? WorkflowTriggerEvent(
          binding: binding,
          workflowID: workflow.id,
          sourceID: Self.sourceID(for: binding),
          metadata: ["requestedTrigger": workflow.trigger.rawValue]
        )
      let endpointControl: AudioCaptureEndpointControl? =
        switch binding {
        case .manual, .menuBar, .wakeWord:
          AudioCaptureEndpointControl(runID: runID, policy: .shortDictation)
        case .hotkey:
          nil
        }
      let modeMaximumDurationSeconds = await recordingDurationLimitProvider().durationSeconds
      let recognizerMaximumDurationSeconds = recognizerDurationProvider(
        workflow.plan.setup.speechRoute?.recognizerID ?? ""
      )
      let maximumDurationSeconds =
        SpeechRecognizerCapabilities.effectiveMaximumAudioDurationSeconds(
          modeMaximumAudioDurationSeconds: modeMaximumDurationSeconds,
          recognizerMaximumAudioDurationSeconds: recognizerMaximumDurationSeconds
        )
      let request = AudioCaptureRequest(
        runID: runID,
        workflow: workflow,
        triggerEvent: triggerEvent,
        preferredFormat: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
        maxDurationSeconds: maximumDurationSeconds,
        canRemoveMaxDurationLimit:
          modeMaximumDurationSeconds != nil && recognizerMaximumDurationSeconds == nil,
        options: recognitionOptions,
        metadata: [
          "source": triggerEvent.sourceID,
          "binding": binding.rawValue,
        ],
        endpointControl: endpointControl,
        audioLifetime: liveAudioSession.audioLifetime,
        liveSubtitleNetworkUsage:
          WorkflowPrivacyDestinationClassifier.liveSubtitleNetworkUsage(for: workflow)
      )

      try await liveAudioSession.startCapture(request, using: audioCaptureService)
      guard lifecycle == .accepting, isPreparing(runID) else {
        await liveAudioSession.cancel()
        await audioCaptureService.cancelCapture(runID: runID)
        throw CancellationError()
      }
      guard liveAudioSession.audioLifetime.isActive else {
        await audioCaptureService.cancelCapture(runID: runID)
        await liveAudioSession.cancel()
        throw CancellationError()
      }
      state = .recording(
        runID: runID,
        workflow: workflow,
        triggerEvent: triggerEvent,
        liveAudioSession: liveAudioSession
      )
      if let endpointControl {
        startCaptureSignalSubscription(
          control: endpointControl,
          maximumDurationSeconds: maximumDurationSeconds
        )
      }
      if preparingRunID == runID {
        preparingRunID = nil
        preparingWorkflow = nil
        preparingLiveAudioSession = nil
      }
    } catch {
      await issuedLiveAudioSession?.cancel()
      // `cancel()` crosses another actor. A user stop can therefore retire
      // this run while cleanup is suspended; decide presentation only after
      // that boundary so a stale start failure cannot resurrect its panel.
      let terminalPreviewPhase: LiveSubtitlePhase =
        error is CancellationError || !isPreparing(runID) ? .hidden : .failed
      if preparingRunID == runID {
        preparingRunID = nil
        preparingWorkflow = nil
        preparingLiveAudioSession = nil
      }
      await publishLiveSubtitleSnapshot(
        runID: runID,
        workflow: workflow,
        phase: terminalPreviewPhase
      )
      if isPreparing(runID) {
        state = .idle
      }
      throw error
    }
    enqueueDiagnostic(
      level: .info,
      event: "workflow.audio-recording.started",
      message: "Started recording for \(workflow.name).",
      runID: runID
    )
  }

  func finishRun() async throws {
    let task: Task<Void, Error>?
    switch state {
    case .recording:
      task = beginFinishingCurrentRun()
    case .stopping(let runID):
      task = finishingRuns[runID]?.task
    case .idle, .preparing:
      task = nil
    }

    guard let task else { throw RunError.notRecording }
    try await task.value
  }

  func removeMaximumDurationLimit(runID requestedRunID: UUID) async -> Bool {
    guard lifecycle == .accepting,
      case .recording(let runID, _, _, _) = state,
      runID == requestedRunID
    else {
      return false
    }
    guard await audioCaptureService.removeMaximumDurationLimit(runID: runID) else {
      return false
    }
    captureSignalSubscriptions[runID]?.watchdogTask.cancel()
    enqueueDiagnostic(
      level: .info,
      event: "workflow.audio-recording.maximum-duration-removed",
      message: "The user removed Rill's duration limit for the active recording.",
      runID: runID
    )
    return true
  }

  /// Claims the active capture synchronously, before the first suspension,
  /// so manual stop and automatic endpoint signals cannot both finish it.
  private func beginFinishingCurrentRun() -> Task<Void, Error>? {
    guard
      case .recording(
        let runID,
        let workflow,
        let triggerEvent,
        let liveAudioSession
      ) = state
    else {
      return nil
    }

    state = .stopping(runID)
    retireCaptureSignalSubscription(runID: runID)
    let operationID = UUID()
    finishingRuns[runID] = FinishingRun(
      operationID: operationID,
      liveAudioSession: liveAudioSession,
      task: nil
    )
    let task = Task { [weak self] in
      guard let self else { throw CancellationError() }
      try await self.finishRun(
        runID: runID,
        operationID: operationID,
        workflow: workflow,
        triggerEvent: triggerEvent,
        liveAudioSession: liveAudioSession
      )
    }
    finishingRuns[runID]?.task = task
    return task
  }

  private func startCaptureSignalSubscription(
    control: AudioCaptureEndpointControl,
    maximumDurationSeconds: Double?
  ) {
    guard lifecycle == .accepting,
      case .recording(let runID, _, _, _) = state,
      runID == control.runID,
      let stream = control.claimStream()
    else {
      control.finish()
      return
    }

    let identity = UUID()
    let listenerTask = Task { [weak self] in
      for await signal in stream {
        guard !Task.isCancelled else { break }
        await self?.handleCaptureTerminalSignal(
          signal,
          subscriptionIdentity: identity
        )
        break
      }
    }
    let watchdogTask = Task {
      guard let maximumDurationSeconds else { return }
      do {
        try await Task.sleep(for: .seconds(maximumDurationSeconds))
        guard !Task.isCancelled else { return }
        _ = control.send(.maximumDurationReached)
      } catch is CancellationError {
      } catch {
      }
    }
    captureSignalSubscriptions[runID] = CaptureSignalSubscription(
      identity: identity,
      control: control,
      listenerTask: listenerTask,
      watchdogTask: watchdogTask
    )
  }

  private func handleCaptureTerminalSignal(
    _ signal: AudioCaptureTerminalSignal,
    subscriptionIdentity: UUID
  ) {
    guard lifecycle == .accepting,
      let subscription = captureSignalSubscriptions[signal.runID],
      subscription.identity == subscriptionIdentity,
      case .recording(let runID, let workflow, _, let liveAudioSession) = state,
      runID == signal.runID
    else {
      return
    }

    retireCaptureSignalSubscription(runID: runID)
    enqueueDiagnostic(
      level: signal.reason == .inputEndedUnexpectedly ? .error : .info,
      event: "workflow.audio-recording.terminal-signal",
      message: "Audio capture reached a terminal condition.",
      runID: runID,
      metadata: [
        "reason": signal.reason.rawValue,
        "acousticObservedSegmentCount": String(
          signal.acousticSummary.observedSegmentCount
        ),
        "acousticObservedDurationMilliseconds": String(
          signal.acousticSummary.observedDurationMilliseconds
        ),
        "acousticAboveThresholdDurationMilliseconds": String(
          signal.acousticSummary.aboveThresholdDurationMilliseconds
        ),
        "acousticPeakLevelPercentBucket": String(
          signal.acousticSummary.peakLevelPercentBucket
        ),
        "acousticMaximumConsecutiveAboveThresholdDurationMilliseconds": String(
          signal.acousticSummary
            .maximumConsecutiveAboveThresholdDurationMilliseconds
        ),
      ]
    )

    switch signal.reason {
    case .speechEnded, .maximumDurationReached:
      guard let task = beginFinishingCurrentRun() else { return }
      observeAutomaticFinish(task, runID: runID, workflow: workflow.presentation)
    case .initialSilenceTimedOut:
      state = .stopping(runID)
      beginTerminalCancellation(
        runID: runID,
        workflow: workflow.presentation,
        liveAudioSession: liveAudioSession,
        message: HistoryFailureSanitizer.noSpeechMessage
      )
    case .inputEndedUnexpectedly:
      state = .stopping(runID)
      beginTerminalCancellation(
        runID: runID,
        workflow: workflow.presentation,
        liveAudioSession: liveAudioSession,
        message: "The microphone input ended unexpectedly."
      )
    }
  }

  private func beginTerminalCancellation(
    runID: UUID,
    workflow: WorkflowPresentation,
    liveAudioSession: AuthorizedLiveAudioSession,
    message: String
  ) {
    _ = liveAudioSession.audioLifetime.cancel()
    let task = Task { [weak self] in
      guard let self else { return }
      await self.audioCaptureService.cancelCapture(runID: runID)
      await self.releaseCaptureBoundary(runID: runID)
      let cancellationResult = await liveAudioSession.cancel()
      if cancellationResult == .queueOwned {
        await self.capturedAudioProcessingQueue.cancel(runID: runID)
      }
      await self.eventBus?.publish(
        .runFailed(runID: runID, workflow: workflow, message: message)
      )
      await self.retireTerminalCancellationTask(runID: runID)
    }
    terminalCancellationTasks[runID] = task
  }

  private func retireTerminalCancellationTask(runID: UUID) {
    terminalCancellationTasks[runID] = nil
  }

  private func releaseCaptureBoundary(runID: UUID) {
    guard case .stopping(let stoppingRunID) = state,
      stoppingRunID == runID
    else {
      return
    }
    state = .idle
  }

  private func observeAutomaticFinish(
    _ task: Task<Void, Error>,
    runID: UUID,
    workflow: WorkflowPresentation
  ) {
    Task { [weak self] in
      do {
        try await task.value
      } catch is CancellationError {
      } catch {
        await self?.eventBus?.publish(
          .runFailed(
            runID: runID,
            workflow: workflow,
            message: "Captured audio could not be finalized."
          )
        )
      }
    }
  }

  private func retireCaptureSignalSubscription(runID: UUID) {
    guard let subscription = captureSignalSubscriptions.removeValue(forKey: runID) else {
      return
    }
    subscription.control.finish()
    subscription.listenerTask.cancel()
    subscription.watchdogTask.cancel()
    trackCaptureSignalDrainTask(subscription.listenerTask)
    trackCaptureSignalDrainTask(subscription.watchdogTask)
  }

  private func trackCaptureSignalDrainTask(_ task: Task<Void, Never>) {
    let taskID = UUID()
    captureSignalDrainTasks[taskID] = task
    Task { [weak self] in
      await task.value
      await self?.retireCaptureSignalDrainTask(taskID: taskID)
    }
  }

  private func retireCaptureSignalDrainTask(taskID: UUID) {
    captureSignalDrainTasks[taskID] = nil
  }

  private func retireAllCaptureSignalSubscriptions() {
    for runID in Array(captureSignalSubscriptions.keys) {
      retireCaptureSignalSubscription(runID: runID)
    }
  }

  private func drainCaptureSignalTasks() async {
    let tasks = Array(captureSignalDrainTasks.values)
    captureSignalDrainTasks.removeAll()
    for task in tasks {
      await task.value
    }
  }

  func cancelRun(runID requestedRunID: UUID? = nil) async {
    var activeCaptureToCancel:
      (
        runID: UUID,
        session: AuthorizedLiveAudioSession?
      )?
    var postBoundaryRunsToCancel:
      [(
        runID: UUID,
        session: AuthorizedLiveAudioSession
      )] = []
    var activeFinishingTasks: [Task<Void, Error>] = []
    var postBoundaryFinishingTasks: [Task<Void, Error>] = []
    var terminalCancellationTask: Task<Void, Never>?

    switch state {
    case .idle:
      break
    case .preparing(let runID):
      if requestedRunID == nil || requestedRunID == runID {
        activeCaptureToCancel = (runID, preparingLiveAudioSession)
        state = .stopping(runID)
        if preparingRunID == runID {
          preparingRunID = nil
          preparingWorkflow = nil
          preparingLiveAudioSession = nil
        }
      }
    case .recording(let runID, _, _, let liveAudioSession):
      if requestedRunID == nil || requestedRunID == runID {
        activeCaptureToCancel = (runID, liveAudioSession)
        state = .stopping(runID)
        retireCaptureSignalSubscription(runID: runID)
      }
    case .stopping(let runID):
      if requestedRunID == nil || requestedRunID == runID {
        if let task = terminalCancellationTasks[runID] {
          terminalCancellationTask = task
        } else if let finishingRun = finishingRuns.removeValue(forKey: runID) {
          finishingRun.task?.cancel()
          if let task = finishingRun.task {
            activeFinishingTasks.append(task)
          }
          activeCaptureToCancel = (runID, finishingRun.liveAudioSession)
        } else {
          // A revocation or another cancellation operation owns this
          // boundary. A second run-scoped cancel is safe and keeps the
          // capture slot closed until at least one cancel returns.
          activeCaptureToCancel = (runID, nil)
        }
      }
    }

    let finishingRunIDs = finishingRuns.keys.filter { runID in
      requestedRunID == nil || requestedRunID == runID
    }
    for runID in finishingRunIDs {
      if let finishingRun = finishingRuns.removeValue(forKey: runID) {
        finishingRun.task?.cancel()
        if let task = finishingRun.task {
          postBoundaryFinishingTasks.append(task)
        }
        postBoundaryRunsToCancel.append((runID, finishingRun.liveAudioSession))
      }
    }

    if let activeCaptureToCancel {
      _ = activeCaptureToCancel.session?.audioLifetime.cancel()
    }
    for run in postBoundaryRunsToCancel {
      _ = run.session.audioLifetime.cancel()
    }

    if let terminalCancellationTask {
      await terminalCancellationTask.value
    }

    if let activeCaptureToCancel {
      await audioCaptureService.cancelCapture(runID: activeCaptureToCancel.runID)
      // An in-flight, non-run-scoped finish call must also drain before
      // another capture can reuse the service safely.
      for task in activeFinishingTasks {
        _ = await task.result
      }
      releaseCaptureBoundary(runID: activeCaptureToCancel.runID)
      let cancellationResult = await activeCaptureToCancel.session?.cancel()
      if cancellationResult == .queueOwned {
        await capturedAudioProcessingQueue.cancel(runID: activeCaptureToCancel.runID)
      }
    }

    for run in postBoundaryRunsToCancel {
      let cancellationResult = await run.session.cancel()
      if cancellationResult == .queueOwned {
        await capturedAudioProcessingQueue.cancel(runID: run.runID)
      }
    }
    for task in postBoundaryFinishingTasks {
      _ = await task.result
    }
  }

  private func finishRun(
    runID: UUID,
    operationID: UUID,
    workflow: WorkflowDefinition,
    triggerEvent: WorkflowTriggerEvent,
    liveAudioSession: AuthorizedLiveAudioSession
  ) async throws {
    var captureBoundaryCrossed = false
    do {
      let deferredCapture = try await audioCaptureService.finishCaptureDeferred()
      captureBoundaryCrossed = true
      releaseCaptureBoundary(runID: runID)
      guard ownsFinishingRun(runID: runID, operationID: operationID),
        !Task.isCancelled
      else {
        await discard(
          deferredCapture,
          liveAudioSession: liveAudioSession
        )
        return
      }
      do {
        try await liveAudioSession.sealCapture()
      } catch {
        deferredCapture.cancel()
        await discardManagedTemporaryCapture(deferredCapture, runID: runID)
        throw error
      }
      guard ownsFinishingRun(runID: runID, operationID: operationID),
        !Task.isCancelled
      else {
        await discard(
          deferredCapture,
          liveAudioSession: liveAudioSession
        )
        return
      }
      let authorizationLease = try await liveAudioSession.processingLeaseForEnqueue()
      guard ownsFinishingRun(runID: runID, operationID: operationID),
        !Task.isCancelled
      else {
        await discard(
          deferredCapture,
          liveAudioSession: liveAudioSession
        )
        return
      }
      let ownershipTransfer = await capturedAudioProcessingQueue.enqueue(
        authorizationLease: authorizationLease,
        triggerEvent: triggerEvent,
        deferredCapture: deferredCapture
      )
      guard ownershipTransfer == .accepted else {
        await discard(
          deferredCapture,
          liveAudioSession: liveAudioSession
        )
        removeFinishingRun(runID: runID, operationID: operationID)
        return
      }
      guard ownsFinishingRun(runID: runID, operationID: operationID),
        !Task.isCancelled
      else {
        await capturedAudioProcessingQueue.cancel(runID: runID)
        return
      }
      removeFinishingRun(runID: runID, operationID: operationID)
      enqueueDiagnostic(
        level: .info,
        event: "workflow.audio-recording.queued",
        message: "Captured audio for \(workflow.name) and queued background workflow processing.",
        runID: runID
      )
    } catch {
      let wasExplicitlyCancelled =
        !ownsFinishingRun(
          runID: runID,
          operationID: operationID
        ) || Task.isCancelled
      if !captureBoundaryCrossed, !wasExplicitlyCancelled {
        await audioCaptureService.cancelCapture(runID: runID)
        releaseCaptureBoundary(runID: runID)
      }
      removeFinishingRun(runID: runID, operationID: operationID)
      if wasExplicitlyCancelled { return }

      let cancellationResult = await liveAudioSession.cancel()
      if cancellationResult == .queueOwned {
        await capturedAudioProcessingQueue.cancel(runID: runID)
      }
      enqueueDiagnostic(
        level: .error,
        event: "workflow.audio-recording.failed",
        message: "Captured audio could not be queued for workflow processing.",
        runID: runID
      )
      throw error
    }
  }

  private func ownsFinishingRun(runID: UUID, operationID: UUID) -> Bool {
    finishingRuns[runID]?.operationID == operationID
  }

  private func removeFinishingRun(runID: UUID, operationID: UUID) {
    guard ownsFinishingRun(runID: runID, operationID: operationID) else { return }
    finishingRuns[runID] = nil
  }

  private func discard(
    _ deferredCapture: DeferredCapturedAudio,
    liveAudioSession: AuthorizedLiveAudioSession
  ) async {
    _ = await liveAudioSession.cancel()
    deferredCapture.cancel()
    await discardManagedTemporaryCapture(
      deferredCapture,
      runID: liveAudioSession.runID
    )
  }

  private func discardManagedTemporaryCapture(
    _ deferredCapture: DeferredCapturedAudio,
    runID: UUID
  ) async {
    let capturedAudio = await Task.detached {
      try? await deferredCapture.value()
    }.value
    guard let capturedAudio else { return }
    guard await cleanupOwner.transfer(capturedAudio, runID: runID) else { return }
    await cleanupOwner.drain(runID: runID)
  }

  func shutdown() async {
    switch lifecycle {
    case .accepting:
      lifecycle = .shuttingDown
    case .shuttingDown:
      await withCheckedContinuation { continuation in
        shutdownWaiters.append(continuation)
      }
      return
    case .terminated:
      return
    }

    retireAllCaptureSignalSubscriptions()
    let terminalTasks = Array(terminalCancellationTasks.values)
    for task in terminalTasks {
      await task.value
    }
    await cancelRun()
    await drainCaptureSignalTasks()
    await audioCaptureService.shutdown()
    await cleanupOwner.drain()
    diagnosticQueueSealed = true
    let pendingDiagnosticTask = diagnosticTailTask
    diagnosticTailTask = nil
    await pendingDiagnosticTask?.value
    lifecycle = .terminated
    let waiters = shutdownWaiters
    shutdownWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  func handleLiveAuthorizationRevocation(
    runID: UUID,
    reason: LiveAudioAuthorizationRevocationReason
  ) async {
    let workflow: WorkflowDefinition?
    switch state {
    case .recording(let currentRunID, let currentWorkflow, _, _)
    where currentRunID == runID:
      workflow = currentWorkflow
      retireCaptureSignalSubscription(runID: runID)
    case .preparing(let currentRunID) where currentRunID == runID:
      workflow = preparingWorkflow
    default:
      return
    }

    state = .stopping(runID)
    if preparingRunID == runID {
      preparingRunID = nil
      preparingWorkflow = nil
      preparingLiveAudioSession = nil
    }
    let message = LiveAudioSessionError.authorizationInvalidated(reason).localizedDescription
    await audioCaptureService.cancelCapture(runID: runID)
    releaseCaptureBoundary(runID: runID)
    await eventBus?.publish(
      .runFailed(
        runID: runID,
        workflow: workflow?.presentation,
        message: message
      )
    )
    enqueueDiagnostic(
      level: .warning,
      event: "workflow.audio-live-authorization-revoked",
      message: message,
      runID: runID,
      metadata: ["reason": reason.rawValue]
    )
  }

  private func isPreparing(_ runID: UUID) -> Bool {
    guard case .preparing(let currentRunID) = state else { return false }
    return currentRunID == runID
  }

  private func publishLiveSubtitleSnapshot(
    runID: UUID,
    workflow: WorkflowDefinition,
    phase: LiveSubtitlePhase
  ) async {
    await eventBus?.publish(
      .liveSubtitleUpdated(
        LiveSubtitleSnapshot(
          runID: runID,
          workflow: workflow.presentation,
          phase: phase,
          providerID: phase == .hidden
            ? nil
            : workflow.plan.setup.speechRoute?.recognizerID,
          networkUsage:
            WorkflowPrivacyDestinationClassifier.liveSubtitleNetworkUsage(for: workflow),
          livePreviewPlacement: workflow.resolvedLivePreviewPlacement
        )
      )
    )
  }

  private func enqueueDiagnostic(
    level: DiagnosticLevel,
    event: String,
    message: String,
    runID: UUID,
    metadata: [String: String] = [:]
  ) {
    guard !diagnosticQueueSealed, let diagnostics else { return }
    let diagnosticEvent = DiagnosticEvent(
      runID: runID,
      subsystem: .session,
      level: level,
      event: event,
      message: message,
      metadata: metadata
    )
    let previousTask = diagnosticTailTask
    diagnosticTailTask = Task {
      await previousTask?.value
      guard !Task.isCancelled else { return }
      await diagnostics.record(diagnosticEvent)
    }
  }

  private static func sourceID(for binding: TriggerBinding) -> String {
    switch binding {
    case .manual:
      return "dashboard.run"
    case .menuBar:
      return "menu-bar.run"
    case .hotkey:
      return "hotkey.run"
    case .wakeWord:
      return "wake-word.run"
    }
  }
}
