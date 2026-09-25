import Foundation
import RillCore

public final class RecordingCueToken: @unchecked Sendable {
  private let lock = NSLock()
  private var isValid = true

  func invalidate() {
    lock.withLock {
      isValid = false
    }
  }

  /// Keeps validation and the short synchronous effect in one critical
  /// section. A finish/cancel that wins before this boundary suppresses the
  /// cue; one that arrives after it waits for the already-started effect.
  public func performIfValid(_ effect: () -> Void) {
    lock.withLock {
      guard isValid else { return }
      effect()
    }
  }
}

public actor RecordingSessionManager {
  private static let preparingReleaseDebounce = Duration.milliseconds(140)
  /// The warm Fn path reaches microphone readiness in under the product's
  /// 250 ms target. Publishing a separate preparing surface before that point
  /// produces two WindowServer presentation commits for one physical press.
  /// Keep the fast path single-shot, while still surfacing genuinely cold or
  /// blocked audio startup.
  private static let preparingPresentationDelay = Duration.milliseconds(300)
  public enum State: Sendable, Equatable {
    case idle
    case preparing(UUID)
    case recording(UUID)
    case cancelling(UUID)
    case transcribing(UUID)
    case delivering(UUID)
  }

  private enum RecordingControlMode: String, Sendable, Equatable {
    case holdToTalk
    case toggle
  }

  private struct PendingPushToTalkStart: Sendable {
    let runID: UUID
    let workflow: WorkflowDefinition
    let gesture: PushToTalkGesture
    let controlMode: RecordingControlMode
    let request: AudioCaptureRequest
    let startCueToken: RecordingCueToken
  }

  /// Captures the ordered physical intent while the stream-owned press is
  /// still resolving settings and workflow selection. Those dependencies may
  /// suspend, but later release/press events must remain able to update the
  /// desired state without starting a second operation.
  private struct PendingStreamHotkeyStart: Sendable {
    let taskID: UUID
    let gesture: PushToTalkGesture
    let expectedFocus: FocusPrivacyIdentitySample
    var pressCount = 1
    var isGesturePressed = true
    var controlMode: RecordingControlMode?
    var deferredReleaseMatured = false
  }

  private enum DeferredPushToTalkReleaseTarget: Sendable {
    case run(UUID)
    case startTask(UUID)
  }

  private struct FinishingRecording: Sendable {
    let operationID: UUID
    let liveAudioSession: AuthorizedLiveAudioSession
    let stopCueToken: RecordingCueToken
    var task: Task<Void, Never>?
  }

  private struct CancellationWork: Sendable {
    let runID: UUID
    let liveAudioSession: AuthorizedLiveAudioSession?
    let finishingTask: Task<Void, Never>?
  }

  private struct CancellationFailure: Sendable {
    let workflow: WorkflowPresentation?
    let message: String
  }

  private struct ManagedCancellation: Sendable {
    let operationID: UUID
    let task: Task<Void, Never>
  }

  private struct AudioCaptureLifetimeMonitor: Sendable {
    let identity: UUID
    let lifetime: AudioCaptureLifetime
    let task: Task<Void, Never>
  }

  private let audioCaptureService: any AudioCaptureService
  private let hotkeyTap: any GlobalInputSource
  private let capturedAudioProcessingQueue: CapturedAudioProcessingQueue
  private let eventBus: EventBus
  private let diagnostics: DiagnosticsRecorder?
  private let privacyRunGate: PrivacyRunGate?
  private let workflowProvider: @Sendable () async -> [WorkflowDefinition]
  private let privacyContextProvider: @Sendable () async -> ContextSnapshot
  private let focusIdentitySampleProvider: @Sendable () async -> FocusPrivacyIdentitySample
  private let targetBoundAuthorizedContextProvider:
    @Sendable (
      PrivacyPolicyDecision,
      FocusPrivacyIdentitySample
    ) async -> ContextSnapshot?
  private let recognitionOptionsProvider:
    @Sendable (
      WorkflowDefinition,
      ContextSnapshot
    ) async throws -> SpeechRecognitionRequestOptions
  private let runPreflight: RecognitionRunPreflight
  private let liveAuthorizationMonitorInterval: Duration
  private let longRecordingModeProvider: @Sendable () async -> Bool
  private let recordingDurationLimitProvider: @Sendable () async -> RecordingDurationLimit
  private let recognizerDurationProvider: @Sendable (String) -> Double?
  private let pushToTalkGestureStateProvider: @Sendable (PushToTalkGesture) -> Bool
  private let cleanupOwner: any ManagedTemporaryAudioCleaning
  private let recordingCueAction: @Sendable (RecordingInteractionCue, RecordingCueToken) async -> Void

  private var state: State = .idle
  private var started = false
  private var listenerTask: Task<Void, Never>?
  private var hasBegunApplicationShutdown = false
  private var hasCompletedApplicationShutdown = false
  private var applicationShutdownWaiters: [CheckedContinuation<Void, Never>] = []
  private var activeStartOperationCount = 0
  private var startOperationDrainWaiters: [CheckedContinuation<Void, Never>] = []
  /// Retains every hotkey-owned start task until that exact task exits. A
  /// cancelled task can remain suspended in a non-cooperative dependency, so
  /// replacing a single "current" handle would let shutdown return while an
  /// older start operation was still alive.
  private var livePushToTalkStartTasks: [UUID: Task<Void, Never>] = [:]
  private var activePushToTalkStartTaskID: UUID?
  private var pendingStreamHotkeyStart: PendingStreamHotkeyStart?
  private var livePushToTalkReleaseTasks: [UUID: Task<Void, Never>] = [:]
  private var activePushToTalkReleaseTaskID: UUID?
  private var activeDeferredReleaseTarget: DeferredPushToTalkReleaseTarget?
  private var activeRunID: UUID?
  private var activeWorkflow: WorkflowDefinition?
  private var activeTriggerEvent: WorkflowTriggerEvent?
  private var activeLiveAudioSession: AuthorizedLiveAudioSession?
  private var activeControlMode: RecordingControlMode?
  private var activeStartCueToken: RecordingCueToken?
  private var finishingRecordings: [UUID: FinishingRecording] = [:]
  private var managedCancellations: [UUID: ManagedCancellation] = [:]
  private var audioCaptureLifetimeMonitors: [UUID: AudioCaptureLifetimeMonitor] = [:]
  private var audioCaptureLifetimeMonitorDrainTasks: [UUID: Task<Void, Never>] = [:]
  private var maximumDurationTask: Task<Void, Never>?
  private var maximumDurationTaskID: UUID?
  private var maximumDurationRunID: UUID?
  private var maximumDurationDrainTasks: [UUID: Task<Void, Never>] = [:]
  private var completedStartCueCount = 0
  private var diagnosticTailTask: Task<Void, Never>?
  private var diagnosticQueueSealed = false

  public init(
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
    cleanupOwner: any ManagedTemporaryAudioCleaning,
    recordingCueAction:
      @escaping @Sendable (RecordingInteractionCue, RecordingCueToken) async -> Void = { _, _ in }
  ) {
    self.audioCaptureService = audioCaptureService
    self.hotkeyTap = hotkeyTap
    self.capturedAudioProcessingQueue = capturedAudioProcessingQueue
    self.eventBus = eventBus
    self.diagnostics = diagnostics
    self.privacyRunGate = privacyRunGate
    self.workflowProvider = workflowProvider
    self.privacyContextProvider = privacyContextProvider ?? { .empty }
    let resolvedAuthorizedContextProvider = authorizedContextProvider ?? { _ in .empty }
    self.focusIdentitySampleProvider = focusIdentitySampleProvider
    self.targetBoundAuthorizedContextProvider =
      targetBoundAuthorizedContextProvider
      ?? { decision, _ in
        await resolvedAuthorizedContextProvider(decision)
      }
    self.recognitionOptionsProvider = recognitionOptionsProvider
    self.runPreflight = runPreflight
    self.liveAuthorizationMonitorInterval = liveAuthorizationMonitorInterval
    self.longRecordingModeProvider = longRecordingModeProvider
    self.recordingDurationLimitProvider = recordingDurationLimitProvider
    self.recognizerDurationProvider = recognizerDurationProvider
    self.cleanupOwner = cleanupOwner
    self.recordingCueAction = recordingCueAction
    self.pushToTalkGestureStateProvider =
      pushToTalkGestureStateProvider
      ?? { [hotkeyTap] gesture in
        hotkeyTap.isPushToTalkGestureActive(gesture)
      }
  }

  public func currentState() -> State {
    state
  }

  var isStartedForTesting: Bool {
    started
  }

  var completedStartCueCountForTesting: Int {
    completedStartCueCount
  }

  var hasPendingStreamHotkeyStartForTesting: Bool {
    pendingStreamHotkeyStart != nil
  }

  func waitForStartOperationsToDrainForTesting() async {
    await waitForStartOperationsToDrain()
  }

  func waitForHotkeyLifecycleTasksToDrainForTesting() async {
    while true {
      let tasks = Array(livePushToTalkStartTasks.values)
        + Array(livePushToTalkReleaseTasks.values)
        + finishingRecordings.values.compactMap(\.task)
      guard !tasks.isEmpty else { return }
      for task in tasks {
        await task.value
      }
    }
  }

  public func start() async {
    guard !started, !hasBegunApplicationShutdown else { return }
    started = true

    let stream = hotkeyTap.stream()
    listenerTask = Task {
      for await event in stream {
        guard !Task.isCancelled else { break }
        await self.processStreamHotkeyEvent(event)
      }
    }
  }

  public func beginPushToTalk(
    triggeredBy gesture: PushToTalkGesture = .fnHold
  ) async {
    guard beginStartOperation() else { return }
    defer { finishStartOperation() }
    let expectedFocus = await focusIdentitySampleProvider()
    guard !hasBegunApplicationShutdown else { return }
    guard
      let pendingStart = await preparePushToTalkStart(
        triggeredBy: gesture,
        controlMode: .holdToTalk,
        expectedFocus: expectedFocus
      )
    else {
      return
    }
    await completePushToTalkStart(pendingStart)
  }

  func processHotkeyEvent(_ event: GlobalInputEvent) async {
    await processHotkeyEvent(event, waitsForFinishingCompletion: true)
  }

  private func processHotkeyEvent(
    _ event: GlobalInputEvent,
    waitsForFinishingCompletion: Bool
  ) async {
    guard !hasBegunApplicationShutdown else { return }
    switch event {
    case .pushToTalkPressed(let gesture):
      cancelActiveDeferredRelease()
      enqueueDiagnostic(
        level: .debug,
        event: "recording.hotkey.pressed",
        message: "Received push-to-talk press for \(gesture.rawValue).",
        runID: activeRunID
      )
      // Busy stream events are decisions about the state in which they
      // arrived. Do not suspend for settings and then reinterpret the
      // same press as a fresh idle start after finalization completes.
      switch state {
      case .cancelling, .transcribing, .delivering:
        return
      case .idle, .preparing, .recording:
        break
      }
      let expectedFocus: FocusPrivacyIdentitySample?
      if case .idle = state {
        let acceptedFocus = await focusIdentitySampleProvider()
        guard !hasBegunApplicationShutdown, case .idle = state else {
          return
        }
        expectedFocus = acceptedFocus
      } else {
        expectedFocus = nil
      }
      let shouldUseToggleMode: Bool
      if activeControlMode == .toggle {
        shouldUseToggleMode = true
      } else {
        shouldUseToggleMode = await longRecordingModeProvider()
      }
      if shouldUseToggleMode {
        await toggleLongRecording(
          triggeredBy: gesture,
          waitsForFinishingCompletion: waitsForFinishingCompletion,
          expectedFocus: expectedFocus
        )
      } else {
        await beginPushToTalkFromHotkeyEvent(
          triggeredBy: gesture,
          expectedFocus: expectedFocus
        )
      }
    case .pushToTalkReleased(let gesture):
      enqueueDiagnostic(
        level: .debug,
        event: "recording.hotkey.released",
        message: "Received push-to-talk release for \(gesture.rawValue).",
        runID: activeRunID
      )
      await endPushToTalk(
        triggeredBy: gesture,
        waitsForFinishingCompletion: waitsForFinishingCompletion
      )
    case .globalInputUnavailable:
      await handleGlobalInputUnavailable(
        waitsForCancellationCompletion: waitsForFinishingCompletion
      )
    case .recordPanelRequested,
      .liveAudioCancellationRequested, .customHotkey(_):
      break
    }
  }

  /// Accepts shared-tap events in source order while keeping the first press's
  /// settings/privacy preparation off the listener. The pending intent is
  /// mutated synchronously before this method returns, so a following release
  /// can never overtake an unregistered press.
  private func processStreamHotkeyEvent(_ event: GlobalInputEvent) async {
    guard !hasBegunApplicationShutdown else { return }
    switch event {
    case .pushToTalkPressed(let gesture):
      if var pending = pendingStreamHotkeyStart, case .idle = state {
        guard pending.gesture == gesture else {
          enqueueDiagnostic(
            level: .debug,
            event: "recording.hotkey.cross-gesture-ignored",
            message:
              "Ignored \(gesture.rawValue) while \(pending.gesture.rawValue) was still preparing.",
            runID: nil
          )
          return
        }
        cancelActiveDeferredRelease()
        pending.pressCount += 1
        pending.isGesturePressed = true
        pending.deferredReleaseMatured = false
        pendingStreamHotkeyStart = pending
        enqueueDiagnostic(
          level: .debug,
          event: "recording.hotkey.pressed",
          message: "Received push-to-talk press for \(gesture.rawValue).",
          runID: nil
        )
        return
      }

      guard case .idle = state else {
        // The listener must not wait for capture finalization or
        // cancellation. Claiming a busy state synchronously lets later
        // physical events be consumed against that state in source order,
        // instead of buffering them until resetState() and mistakenly
        // treating a stop retry as a new recording.
        await processHotkeyEvent(event, waitsForFinishingCompletion: false)
        return
      }

      let expectedFocus = await focusIdentitySampleProvider()
      guard !hasBegunApplicationShutdown,
        case .idle = state,
        pendingStreamHotkeyStart == nil
      else {
        return
      }
      cancelActiveDeferredRelease()
      enqueueDiagnostic(
        level: .debug,
        event: "recording.hotkey.pressed",
        message: "Received push-to-talk press for \(gesture.rawValue).",
        runID: nil
      )
      beginTrackedStreamHotkeyStart(
        triggeredBy: gesture,
        expectedFocus: expectedFocus
      )

    case .pushToTalkReleased(let gesture):
      if var pending = pendingStreamHotkeyStart, case .idle = state {
        guard pending.gesture == gesture else { return }
        pending.isGesturePressed = false
        pendingStreamHotkeyStart = pending
        enqueueDiagnostic(
          level: .debug,
          event: "recording.hotkey.released",
          message: "Received push-to-talk release for \(gesture.rawValue).",
          runID: nil
        )
        scheduleDeferredRelease(
          target: .startTask(pending.taskID),
          gesture: gesture
        )
        return
      }
      await processHotkeyEvent(event, waitsForFinishingCompletion: false)

    case .globalInputUnavailable:
      await handleGlobalInputUnavailable(waitsForCancellationCompletion: false)

    case .recordPanelRequested,
      .liveAudioCancellationRequested, .customHotkey:
      break
    }
  }

  private func beginTrackedStreamHotkeyStart(
    triggeredBy gesture: PushToTalkGesture,
    expectedFocus: FocusPrivacyIdentitySample
  ) {
    let taskID = UUID()
    pendingStreamHotkeyStart = PendingStreamHotkeyStart(
      taskID: taskID,
      gesture: gesture,
      expectedFocus: expectedFocus
    )
    activePushToTalkStartTaskID = taskID
    let task = Task { [weak self] in
      guard let self else { return }
      await self.runTrackedStreamHotkeyStart(taskID: taskID)
    }
    livePushToTalkStartTasks[taskID] = task
  }

  private func handleGlobalInputUnavailable(
    waitsForCancellationCompletion: Bool
  ) async {
    enqueueDiagnostic(
      level: .warning,
      event: "recording.global-input-unavailable",
      message: "Global input became unavailable, so the active recording gesture was cancelled.",
      runID: activeRunID
    )
    switch state {
    case .idle:
      resetState()
    case .preparing(let runID), .recording(let runID):
      let task = beginManagedCancellation(
        runID: runID,
        failure: CancellationFailure(
          workflow: activeWorkflow?.presentation,
          message: HistoryFailureSanitizer.globalInputUnavailableMessage
        )
      )
      if waitsForCancellationCompletion {
        await task?.value
      }
    case .cancelling, .transcribing, .delivering:
      break
    }
  }

  public func toggleLongRecording(
    triggeredBy gesture: PushToTalkGesture = .fnHold
  ) async {
    let expectedFocus: FocusPrivacyIdentitySample?
    if case .idle = state {
      expectedFocus = await focusIdentitySampleProvider()
    } else {
      expectedFocus = nil
    }
    await toggleLongRecording(
      triggeredBy: gesture,
      waitsForFinishingCompletion: true,
      expectedFocus: expectedFocus
    )
  }

  private func toggleLongRecording(
    triggeredBy gesture: PushToTalkGesture,
    waitsForFinishingCompletion: Bool,
    expectedFocus: FocusPrivacyIdentitySample?
  ) async {
    switch state {
    case .idle:
      guard let expectedFocus else { return }
      guard beginStartOperation() else { return }
      defer { finishStartOperation() }
      guard
        let pendingStart = await preparePushToTalkStart(
          triggeredBy: gesture,
          controlMode: .toggle,
          expectedFocus: expectedFocus
        )
      else { return }
      await completePushToTalkStart(pendingStart)
    case .recording(let runID):
      guard activeControlMode == .toggle, let workflow = activeWorkflow else { return }
      guard
        let task = beginFinishingPushToTalkRecording(
          runID: runID,
          workflow: workflow,
          gesture: gesture
        )
      else {
        return
      }
      if waitsForFinishingCompletion {
        await task.value
      }
    case .preparing(let runID):
      guard activeControlMode == .toggle else { return }
      cancelActivePushToTalkStartTask()
      enqueueDiagnostic(
        level: .debug,
        event: "recording.toggle.cancelled-before-start",
        message:
          "Long recording toggle was pressed again while capture was still preparing, so startup was cancelled.",
        runID: runID
      )
      let task = beginManagedCancellation(runID: runID)
      if waitsForFinishingCompletion {
        await task?.value
      }
    case .cancelling, .transcribing, .delivering:
      return
    }
  }

  private func beginPushToTalkFromHotkeyEvent(
    triggeredBy gesture: PushToTalkGesture,
    expectedFocus: FocusPrivacyIdentitySample?
  ) async {
    guard let expectedFocus else { return }
    guard beginStartOperation() else { return }
    defer { finishStartOperation() }
    guard
      let pendingStart = await preparePushToTalkStart(
        triggeredBy: gesture,
        controlMode: .holdToTalk,
        expectedFocus: expectedFocus
      )
    else {
      return
    }
    guard !hasBegunApplicationShutdown else {
      _ = pendingStart.request.audioLifetime?.cancel()
      return
    }
    let taskID = UUID()
    let startTask = Task { [weak self] in
      guard let self else { return }
      await self.runTrackedPushToTalkStart(pendingStart, taskID: taskID)
    }
    activePushToTalkStartTaskID = taskID
    livePushToTalkStartTasks[taskID] = startTask
  }

  private func preparePushToTalkStart(
    triggeredBy gesture: PushToTalkGesture,
    controlMode: RecordingControlMode,
    expectedFocus: FocusPrivacyIdentitySample,
    streamStartTaskID: UUID? = nil
  ) async -> PendingPushToTalkStart? {
    guard !hasBegunApplicationShutdown, case .idle = state else { return nil }
    let availableWorkflows = await workflowProvider()
    guard !hasBegunApplicationShutdown else { return nil }
    if let streamStartTaskID {
      guard
        shouldCommitPendingStreamHotkeyStart(
          taskID: streamStartTaskID,
          controlMode: controlMode
        )
      else {
        return nil
      }
    }
    guard let workflow = availableWorkflows.first else { return nil }
    guard availableWorkflows.count == 1 else {
      let conflictingNames = availableWorkflows.map(\.name).joined(separator: ", ")
      let message = "Multiple enabled workflows share the hotkey trigger: \(conflictingNames)"
      await publishFailure(runID: nil, workflow: nil, message: message)
      return nil
    }
    guard workflow.trigger == .hotkey else { return nil }
    if let issue = WorkflowExecutionPolicy.issue(for: workflow) {
      await publishFailure(
        runID: nil,
        workflow: workflow.presentation,
        message: SessionCoordinator.SessionError.unsupportedWorkflow(issue).localizedDescription
      )
      return nil
    }

    let runID = UUID()
    let startCueToken = RecordingCueToken()
    state = .preparing(runID)
    activeRunID = runID
    activeWorkflow = workflow
    activeControlMode = controlMode
    activeStartCueToken = startCueToken
    if let streamStartTaskID {
      retargetDeferredRelease(
        fromStartTask: streamStartTaskID,
        toRun: runID
      )
      pendingStreamHotkeyStart = nil
      activePushToTalkStartTaskID = streamStartTaskID
    }
    do {
      try await runPreflight(workflow)
    } catch {
      guard activeRunID == runID,
        case .preparing(let expectedRunID) = state,
        expectedRunID == runID
      else {
        return nil
      }
      await publishFailure(
        runID: runID,
        workflow: workflow.presentation,
        message: error.localizedDescription
      )
      resetState()
      return nil
    }
    guard case .preparing(let expectedRunID) = state, expectedRunID == runID else {
      return nil
    }
    let verifiedFocus = await focusIdentitySampleProvider()
    guard activeRunID == runID,
      case .preparing(let expectedRunID) = state,
      expectedRunID == runID
    else {
      return nil
    }
    guard verifiedFocus.hasSamePrivacyIdentity(as: expectedFocus) else {
      await publishFailure(
        runID: runID,
        workflow: workflow.presentation,
        message: PrivacyRunGate.GateError.contextChangedDuringAuthorization.localizedDescription
      )
      guard activeRunID == runID,
        case .preparing(let expectedRunID) = state,
        expectedRunID == runID
      else {
        return nil
      }
      resetState()
      return nil
    }

    let focusIdentitySampleProvider = self.focusIdentitySampleProvider
    let privacyContextProvider = self.privacyContextProvider
    let targetBoundAuthorizedContextProvider = self.targetBoundAuthorizedContextProvider
    var rejectedPrivacyFocus = expectedFocus.focus
    rejectedPrivacyFocus.applicationName = nil
    rejectedPrivacyFocus.bundleIdentifier = nil
    rejectedPrivacyFocus.processIdentifier =
      expectedFocus.focus.processIdentifier == Int32.min
      ? Int32.max
      : Int32.min
    rejectedPrivacyFocus.focusedRole = nil
    rejectedPrivacyFocus.selectedText = ""
    rejectedPrivacyFocus.secureInput = true
    let rejectedPrivacyContext = ContextSnapshot(
      // A non-throwing PrivacyRunGate provider needs a content-free value
      // that cannot compare as the authorized source. Removing the prior
      // application identity and marking Secure Input keeps live cloud
      // authorization fail-closed after target drift.
      focus: rejectedPrivacyFocus,
      clipboard: ContextSnapshot.empty.clipboard
    )
    let boundPrivacyContextProvider: @Sendable () async -> ContextSnapshot = {
      let currentFocus = await focusIdentitySampleProvider()
      guard currentFocus.hasSamePrivacyIdentity(as: expectedFocus) else {
        return rejectedPrivacyContext
      }
      let context = await privacyContextProvider()
      let capturedFocus = FocusPrivacyIdentitySample(
        focus: context.focus,
        applicationActivationRevision: expectedFocus.applicationActivationRevision
      )
      let confirmedFocus = await focusIdentitySampleProvider()
      guard capturedFocus.hasSamePrivacyIdentity(as: expectedFocus),
        confirmedFocus.hasSamePrivacyIdentity(as: expectedFocus)
      else {
        return rejectedPrivacyContext
      }
      return context
    }
    let boundAuthorizedContextProvider:
      @Sendable (
        PrivacyPolicyDecision
      ) async -> ContextSnapshot = { decision in
        let currentFocus = await focusIdentitySampleProvider()
        guard currentFocus.hasSamePrivacyIdentity(as: expectedFocus) else {
          return .empty
        }
        guard let context = await targetBoundAuthorizedContextProvider(
          decision,
          expectedFocus
        ) else {
          return .empty
        }
        let capturedFocus = FocusPrivacyIdentitySample(
          focus: context.focus,
          applicationActivationRevision: expectedFocus.applicationActivationRevision
        )
        let confirmedFocus = await focusIdentitySampleProvider()
        guard capturedFocus.hasSamePrivacyIdentity(as: expectedFocus),
          confirmedFocus.hasSamePrivacyIdentity(as: expectedFocus)
        else {
          return .empty
        }
        return context
      }
    let liveAudioSession: AuthorizedLiveAudioSession
    if let privacyRunGate {
      var issuedLiveAudioSession: AuthorizedLiveAudioSession?
      do {
        let issuedSession = try await privacyRunGate.issueLiveAudioSession(
          runID: runID,
          privacyContextProvider: boundPrivacyContextProvider,
          contextProvider: boundAuthorizedContextProvider,
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
        issuedLiveAudioSession = issuedSession
        guard activeRunID == runID,
          case .preparing(let expectedRunID) = state,
          expectedRunID == runID
        else {
          await issuedSession.cancel()
          return nil
        }
        activeLiveAudioSession = issuedSession
        try await issuedSession.startMonitoring()
        liveAudioSession = issuedSession
      } catch {
        guard activeRunID == runID,
          case .preparing(let expectedRunID) = state,
          expectedRunID == runID
        else {
          await issuedLiveAudioSession?.cancel()
          return nil
        }
        await publishFailure(
          runID: runID,
          workflow: workflow.presentation,
          message: error.localizedDescription
        )
        await issuedLiveAudioSession?.cancel()
        resetState()
        return nil
      }
    } else {
      let error = SessionCoordinator.SessionError.privacyAuthorizationRequired
      await publishFailure(
        runID: runID,
        workflow: workflow.presentation,
        message: error.localizedDescription
      )
      resetState()
      return nil
    }
    guard case .preparing(let expectedRunID) = state, expectedRunID == runID else {
      await liveAudioSession.cancel()
      return nil
    }
    let recognitionOptions = liveAudioSession.audioCaptureOptions
    let sourceID = controlMode == .toggle ? "long-recording" : "push-to-talk"
    let modeMaximumDurationSeconds = await recordingDurationLimitProvider().durationSeconds
    let recognizerMaximumDurationSeconds = recognizerDurationProvider(
      workflow.plan.setup.speechRoute?.recognizerID ?? ""
    )
    let maximumDurationSeconds =
      SpeechRecognizerCapabilities.effectiveMaximumAudioDurationSeconds(
        modeMaximumAudioDurationSeconds: modeMaximumDurationSeconds,
        recognizerMaximumAudioDurationSeconds: recognizerMaximumDurationSeconds
      )
    let triggerEvent = WorkflowTriggerEvent(
      binding: .hotkey,
      workflowID: workflow.id,
      sourceID: sourceID,
      metadata: [
        "gesture": gesture.rawValue,
        "controlMode": controlMode.rawValue,
      ]
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
        "source": sourceID,
        "gesture": gesture.rawValue,
        "controlMode": controlMode.rawValue,
      ],
      audioLifetime: liveAudioSession.audioLifetime,
      liveSubtitleNetworkUsage:
        WorkflowPrivacyDestinationClassifier.liveSubtitleNetworkUsage(for: workflow)
    )

    activeTriggerEvent = triggerEvent
    activeLiveAudioSession = liveAudioSession
    enqueueDiagnostic(
      level: .debug,
      event: "recording.prepare.begin",
      message:
        "Push-to-talk preparing with \(gesture.rawValue) using workflow \(workflow.name) and recognizer \(workflow.plan.setup.speechRoute?.recognizerID ?? "unconfigured").",
      runID: runID
    )

    guard !hasBegunApplicationShutdown,
      activeRunID == runID,
      case .preparing(let expectedRunID) = state,
      expectedRunID == runID
    else {
      await liveAudioSession.cancel()
      return nil
    }

    return PendingPushToTalkStart(
      runID: runID,
      workflow: workflow,
      gesture: gesture,
      controlMode: controlMode,
      request: request,
      startCueToken: startCueToken
    )
  }

  private func completePushToTalkStart(_ pendingStart: PendingPushToTalkStart) async {
    guard !hasBegunApplicationShutdown,
      activeRunID == pendingStart.runID,
      case .preparing(let expectedRunID) = state,
      expectedRunID == pendingStart.runID
    else {
      _ = pendingStart.request.audioLifetime?.cancel()
      return
    }
    // Avoid presenting two separate surfaces on the normal warm path. The
    // capture runtime publishes `.recording` once PCM is ready; only publish a
    // waiting state if startup is actually cold or blocked beyond the target.
    let preparingPresentationTask = Task { [weak self] in
      do {
        try await Task.sleep(for: Self.preparingPresentationDelay)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await self?.publishPreparingPresentationIfCurrent(pendingStart)
    }
    defer { preparingPresentationTask.cancel() }
    guard !hasBegunApplicationShutdown,
      !Task.isCancelled,
      activeRunID == pendingStart.runID,
      case .preparing(let expectedRunID) = state,
      expectedRunID == pendingStart.runID
    else {
      _ = pendingStart.request.audioLifetime?.cancel()
      await eventBus.publish(
        .liveSubtitleUpdated(
          LiveSubtitleSnapshot(
            runID: pendingStart.runID,
            workflow: pendingStart.workflow.presentation,
            phase: .hidden,
            livePreviewPlacement: pendingStart.workflow.resolvedLivePreviewPlacement
          )
        )
      )
      return
    }
    let liveAudioSession = activeLiveAudioSession
    do {
      guard let liveAudioSession else { throw SessionCoordinator.SessionError.privacyAuthorizationRequired }
      try await liveAudioSession.startCapture(pendingStart.request, using: audioCaptureService)
      guard case .preparing(let expectedRunID) = state, expectedRunID == pendingStart.runID else {
        _ = pendingStart.request.audioLifetime?.cancel()
        if isCancellationInProgress(runID: pendingStart.runID) {
          return
        }
        await audioCaptureService.cancelCapture(runID: pendingStart.runID)
        if activeRunID == pendingStart.runID { resetState() }
        return
      }
      if let lifetime = pendingStart.request.audioLifetime, !lifetime.isActive {
        if lifetime.state == .revoked(.serviceFailure) {
          let task = beginManagedCancellation(
            runID: pendingStart.runID,
            failure: CancellationFailure(
              workflow: pendingStart.workflow.presentation,
              message: HistoryFailureSanitizer.microphoneInputUnavailableMessage
            )
          )
          await task?.value
        } else {
          await cancelActiveCapture(runID: pendingStart.runID)
        }
        return
      }
      guard installAudioCaptureLifetimeMonitor(for: pendingStart.request) else {
        let task = beginManagedCancellation(
          runID: pendingStart.runID,
          failure: CancellationFailure(
            workflow: pendingStart.workflow.presentation,
            message: HistoryFailureSanitizer.microphoneInputUnavailableMessage
          )
        )
        await task?.value
        return
      }
      state = .recording(pendingStart.runID)
      scheduleMaximumDuration(
        runID: pendingStart.runID,
        workflow: pendingStart.workflow,
        gesture: pendingStart.gesture,
        seconds: pendingStart.request.maxDurationSeconds
      )
      enqueueDiagnostic(
        level: .info,
        event: "recording.started",
        message: "Push-to-talk recording started with \(pendingStart.gesture.rawValue).",
        runID: pendingStart.runID
      )
      guard !hasBegunApplicationShutdown,
        !Task.isCancelled,
        activeRunID == pendingStart.runID,
        case .recording(let currentRunID) = state,
        currentRunID == pendingStart.runID,
        pendingStart.request.audioLifetime?.isActive ?? true,
        activeStartCueToken === pendingStart.startCueToken
      else {
        return
      }
      await recordingCueAction(.started, pendingStart.startCueToken)
      completedStartCueCount += 1
    } catch is CancellationError {
      _ = pendingStart.request.audioLifetime?.cancel()
      if isCancellationInProgress(runID: pendingStart.runID) {
        return
      }
      if activeRunID == pendingStart.runID {
        await cancelActiveCapture(runID: pendingStart.runID)
      } else {
        await audioCaptureService.cancelCapture(runID: pendingStart.runID)
      }
    } catch {
      _ = pendingStart.request.audioLifetime?.revoke(.serviceFailure)
      if isCancellationInProgress(runID: pendingStart.runID) {
        return
      }
      if activeRunID == pendingStart.runID {
        let task = beginManagedCancellation(
          runID: pendingStart.runID,
          failure: CancellationFailure(
            workflow: pendingStart.workflow.presentation,
            message: error.localizedDescription
          )
        )
        await task?.value
      } else {
        await audioCaptureService.cancelCapture(runID: pendingStart.runID)
      }
    }
  }

  private func publishPreparingPresentationIfCurrent(
    _ pendingStart: PendingPushToTalkStart
  ) async {
    guard !hasBegunApplicationShutdown,
      activeRunID == pendingStart.runID,
      case .preparing(let expectedRunID) = state,
      expectedRunID == pendingStart.runID
    else {
      return
    }
    await eventBus.publish(
      .liveSubtitleUpdated(
        LiveSubtitleSnapshot(
          runID: pendingStart.runID,
          workflow: pendingStart.workflow.presentation,
          phase: .preparing,
          providerID: pendingStart.workflow.plan.setup.speechRoute?.recognizerID,
          networkUsage: WorkflowPrivacyDestinationClassifier.liveSubtitleNetworkUsage(
            for: pendingStart.workflow
          ),
          livePreviewPlacement: pendingStart.workflow.resolvedLivePreviewPlacement
        )
      )
    )
  }

  public func endPushToTalk(
    triggeredBy gesture: PushToTalkGesture = .fnHold
  ) async {
    await endPushToTalk(
      triggeredBy: gesture,
      waitsForFinishingCompletion: true
    )
  }

  private func endPushToTalk(
    triggeredBy gesture: PushToTalkGesture,
    waitsForFinishingCompletion: Bool
  ) async {
    guard let workflow = activeWorkflow else { return }
    if activeControlMode == .toggle {
      enqueueDiagnostic(
        level: .debug,
        event: "recording.toggle.release-ignored",
        message: "Ignored release because long recording mode stops on the next press.",
        runID: activeRunID
      )
      return
    }

    switch state {
    case .preparing(let runID):
      enqueueDiagnostic(
        level: .debug,
        event: "recording.release.deferred",
        message:
          "Push-to-talk was released while audio capture was still preparing, so cancellation will wait briefly to absorb transient Fn jitter.",
        runID: runID
      )
      guard !hasBegunApplicationShutdown,
        case .preparing(let expectedRunID) = state,
        expectedRunID == runID
      else {
        return
      }
      scheduleDeferredRelease(target: .run(runID), gesture: gesture)
    case .recording(let runID):
      guard
        let task = beginFinishingPushToTalkRecording(
          runID: runID,
          workflow: workflow,
          gesture: gesture
        )
      else {
        return
      }
      if waitsForFinishingCompletion {
        await task.value
      }
    case .idle, .cancelling, .transcribing, .delivering:
      return
    }
  }

  public func cancelCurrentRecording(runID requestedRunID: UUID? = nil) async {
    await cancelCaptures(runID: requestedRunID)
  }

  public func removeMaximumDurationLimit(runID requestedRunID: UUID) async -> Bool {
    guard !hasBegunApplicationShutdown,
      case .recording(let runID) = state,
      runID == requestedRunID,
      activeRunID == runID
    else {
      return false
    }
    guard await audioCaptureService.removeMaximumDurationLimit(runID: runID) else {
      return false
    }
    cancelMaximumDurationTask(runID: runID)
    enqueueDiagnostic(
      level: .info,
      event: "recording.maximum-duration-removed",
      message: "The user removed Rill's duration limit for the active recording.",
      runID: runID
    )
    return true
  }

  public func stopForApplicationShutdown() async {
    if hasBegunApplicationShutdown {
      guard !hasCompletedApplicationShutdown else { return }
      await withCheckedContinuation { continuation in
        applicationShutdownWaiters.append(continuation)
      }
      return
    }

    hasBegunApplicationShutdown = true
    started = false
    cancelMaximumDurationTask(runID: nil)
    let listenerTask = listenerTask
    let startTasksToDrain = Array(livePushToTalkStartTasks.values)
    let releaseTasksToDrain = Array(livePushToTalkReleaseTasks.values)
    let lifetimeMonitorTasksToDrain = Array(audioCaptureLifetimeMonitorDrainTasks.values)
    self.listenerTask = nil
    audioCaptureLifetimeMonitors.removeAll()
    listenerTask?.cancel()
    for task in startTasksToDrain {
      task.cancel()
    }
    for task in releaseTasksToDrain {
      task.cancel()
    }
    for task in lifetimeMonitorTasksToDrain {
      task.cancel()
    }

    await cancelCaptures(runID: nil)
    await listenerTask?.value
    for task in startTasksToDrain {
      await task.value
    }
    for task in releaseTasksToDrain {
      await task.value
    }
    for task in lifetimeMonitorTasksToDrain {
      await task.value
    }
    audioCaptureLifetimeMonitorDrainTasks.removeAll()
    let maximumDurationTasks = Array(maximumDurationDrainTasks.values)
    maximumDurationDrainTasks.removeAll()
    for task in maximumDurationTasks {
      await task.value
    }
    await waitForStartOperationsToDrain()
    await audioCaptureService.shutdown()
    await cleanupOwner.drain()
    diagnosticQueueSealed = true
    let pendingDiagnosticTask = diagnosticTailTask
    self.diagnosticTailTask = nil
    await pendingDiagnosticTask?.value

    hasCompletedApplicationShutdown = true
    let waiters = applicationShutdownWaiters
    applicationShutdownWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

}

extension RecordingSessionManager {
  private func runTrackedPushToTalkStart(
    _ pendingStart: PendingPushToTalkStart,
    taskID: UUID
  ) async {
    defer { retirePushToTalkStartTask(taskID) }
    await completePushToTalkStart(pendingStart)
  }

  private func runTrackedStreamHotkeyStart(taskID: UUID) async {
    defer { retirePushToTalkStartTask(taskID) }
    guard beginStartOperation() else { return }
    defer { finishStartOperation() }
    guard let intent = pendingStreamHotkeyStart, intent.taskID == taskID else { return }

    let controlMode: RecordingControlMode =
      await longRecordingModeProvider()
      ? .toggle
      : .holdToTalk
    guard resolvePendingStreamHotkeyMode(taskID: taskID, controlMode: controlMode) else {
      return
    }
    guard
      let pendingStart = await preparePushToTalkStart(
        triggeredBy: intent.gesture,
        controlMode: controlMode,
        expectedFocus: intent.expectedFocus,
        streamStartTaskID: taskID
      )
    else {
      return
    }
    guard !hasBegunApplicationShutdown else {
      _ = pendingStart.request.audioLifetime?.cancel()
      return
    }
    await completePushToTalkStart(pendingStart)
  }

  private func resolvePendingStreamHotkeyMode(
    taskID: UUID,
    controlMode: RecordingControlMode
  ) -> Bool {
    guard !Task.isCancelled,
      var pending = pendingStreamHotkeyStart,
      pending.taskID == taskID
    else {
      return false
    }
    pending.controlMode = controlMode
    pendingStreamHotkeyStart = pending
    return shouldCommitPendingStreamHotkeyStart(
      taskID: taskID,
      controlMode: controlMode
    )
  }

  private func shouldCommitPendingStreamHotkeyStart(
    taskID: UUID,
    controlMode: RecordingControlMode
  ) -> Bool {
    guard !Task.isCancelled,
      let pending = pendingStreamHotkeyStart,
      pending.taskID == taskID
    else {
      return false
    }
    switch controlMode {
    case .toggle:
      return pending.pressCount.isMultiple(of: 2) == false
    case .holdToTalk:
      return !pending.deferredReleaseMatured || pending.isGesturePressed
    }
  }

  private func retirePushToTalkStartTask(_ taskID: UUID) {
    livePushToTalkStartTasks[taskID] = nil
    if activePushToTalkStartTaskID == taskID {
      activePushToTalkStartTaskID = nil
    }
    if pendingStreamHotkeyStart?.taskID == taskID {
      pendingStreamHotkeyStart = nil
    }
  }

  private func cancelActivePushToTalkStartTask() {
    guard let activePushToTalkStartTaskID else { return }
    livePushToTalkStartTasks[activePushToTalkStartTaskID]?.cancel()
  }

  fileprivate func beginStartOperation() -> Bool {
    guard !hasBegunApplicationShutdown else { return false }
    activeStartOperationCount += 1
    return true
  }

  fileprivate func finishStartOperation() {
    activeStartOperationCount -= 1
    guard activeStartOperationCount == 0 else { return }
    let waiters = startOperationDrainWaiters
    startOperationDrainWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  fileprivate func waitForStartOperationsToDrain() async {
    guard activeStartOperationCount > 0 else { return }
    await withCheckedContinuation { continuation in
      startOperationDrainWaiters.append(continuation)
    }
  }

  fileprivate func publishFailure(runID: UUID?, workflow: WorkflowPresentation?, message: String)
    async
  {
    enqueueDiagnostic(
      level: .error,
      event: "recording.failure",
      message: message,
      runID: runID
    )
    await eventBus.publish(.runFailed(runID: runID, workflow: workflow, message: message))
  }

  /// Hotkey capture deliberately has no acoustic endpoint control because the
  /// physical release owns normal completion. It still needs a separate,
  /// content-free terminal signal when the capture service loses its stream
  /// after startup.
  private func installAudioCaptureLifetimeMonitor(for request: AudioCaptureRequest) -> Bool {
    guard request.endpointControl == nil else { return true }
    guard let lifetime = request.audioLifetime,
      lifetime.runID == request.runID,
      let terminalStates = lifetime.claimTerminalStateStream()
    else {
      return false
    }

    retireAudioCaptureLifetimeMonitor(runID: request.runID)
    let identity = UUID()
    let task = Task { [weak self] in
      for await terminalState in terminalStates {
        guard !Task.isCancelled else { break }
        await self?.handleAudioCaptureLifetimeTerminalState(
          terminalState,
          runID: request.runID,
          lifetime: lifetime,
          monitorIdentity: identity
        )
        break
      }
      await self?.completeAudioCaptureLifetimeMonitor(identity: identity)
    }
    audioCaptureLifetimeMonitors[request.runID] = AudioCaptureLifetimeMonitor(
      identity: identity,
      lifetime: lifetime,
      task: task
    )
    audioCaptureLifetimeMonitorDrainTasks[identity] = task
    return true
  }

  private func handleAudioCaptureLifetimeTerminalState(
    _ terminalState: AudioCaptureLifetime.State,
    runID: UUID,
    lifetime: AudioCaptureLifetime,
    monitorIdentity: UUID
  ) async {
    guard let monitor = audioCaptureLifetimeMonitors[runID],
      monitor.identity == monitorIdentity,
      monitor.lifetime === lifetime
    else {
      return
    }
    audioCaptureLifetimeMonitors[runID] = nil
    guard terminalState == .revoked(.serviceFailure),
      activeRunID == runID || finishingRecordings[runID] != nil
    else {
      return
    }

    enqueueDiagnostic(
      level: .error,
      event: "recording.capture-service-failed",
      message:
        "The active microphone stream ended unexpectedly, so the exact recording run was cancelled.",
      runID: runID
    )
    let task = beginManagedCancellation(
      runID: runID,
      failure: CancellationFailure(
        workflow: activeWorkflow?.presentation,
        message: HistoryFailureSanitizer.microphoneInputUnavailableMessage
      )
    )
    await task?.value
  }

  private func retireAudioCaptureLifetimeMonitor(runID: UUID) {
    guard let monitor = audioCaptureLifetimeMonitors.removeValue(forKey: runID) else {
      return
    }
    monitor.task.cancel()
  }

  private func completeAudioCaptureLifetimeMonitor(identity: UUID) {
    audioCaptureLifetimeMonitorDrainTasks[identity] = nil
    if let runID = audioCaptureLifetimeMonitors.first(where: {
      $0.value.identity == identity
    })?.key {
      audioCaptureLifetimeMonitors[runID] = nil
    }
  }

  fileprivate func enqueueDiagnostic(
    level: DiagnosticLevel,
    event: String,
    message: String,
    runID: UUID?,
    metadata: [String: String] = [:]
  ) {
    guard !diagnosticQueueSealed, let diagnostics else { return }
    let diagnosticEvent = DiagnosticEvent(
      runID: runID,
      subsystem: .platform,
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

  private func scheduleMaximumDuration(
    runID: UUID,
    workflow: WorkflowDefinition,
    gesture: PushToTalkGesture,
    seconds: Double?
  ) {
    cancelMaximumDurationTask(runID: nil)
    guard let seconds else { return }
    let shouldFinishImmediately = !seconds.isFinite || seconds <= 0
    let taskID = UUID()
    maximumDurationTaskID = taskID
    maximumDurationRunID = runID
    maximumDurationTask = Task { [weak self] in
      do {
        if !shouldFinishImmediately {
          try await Task.sleep(for: .seconds(seconds))
        }
        if !Task.isCancelled {
          await self?.handleMaximumDuration(
            runID: runID,
            workflow: workflow,
            gesture: gesture
          )
        }
      } catch is CancellationError {
      } catch {
      }
      await self?.retireMaximumDurationTask(taskID: taskID)
    }
  }

  private func handleMaximumDuration(
    runID: UUID,
    workflow: WorkflowDefinition,
    gesture: PushToTalkGesture
  ) {
    guard !hasBegunApplicationShutdown,
      activeRunID == runID,
      case .recording(let currentRunID) = state,
      currentRunID == runID
    else {
      return
    }
    enqueueDiagnostic(
      level: .warning,
      event: "recording.maximum-duration-reached",
      message: "Recording reached its safety duration limit and is being finalized.",
      runID: runID
    )
    _ = beginFinishingPushToTalkRecording(
      runID: runID,
      workflow: workflow,
      gesture: gesture
    )
  }

  private func cancelMaximumDurationTask(runID: UUID?) {
    guard runID == nil || maximumDurationRunID == runID else { return }
    guard let task = maximumDurationTask else {
      maximumDurationTaskID = nil
      maximumDurationRunID = nil
      return
    }
    let taskID = maximumDurationTaskID
    maximumDurationTask = nil
    maximumDurationTaskID = nil
    maximumDurationRunID = nil
    task.cancel()
    if let taskID {
      maximumDurationDrainTasks[taskID] = task
    }
  }

  private func retireMaximumDurationTask(taskID: UUID) {
    if maximumDurationTaskID == taskID {
      maximumDurationTask = nil
      maximumDurationTaskID = nil
      maximumDurationRunID = nil
    }
    maximumDurationDrainTasks[taskID] = nil
  }

  /// Claims the stop synchronously and installs the exact task that owns the
  /// remaining finalization work before returning. Stream callers can then
  /// resume event ingestion immediately, while direct callers may await the
  /// returned task for their historical completion semantics.
  fileprivate func beginFinishingPushToTalkRecording(
    runID: UUID,
    workflow: WorkflowDefinition,
    gesture: PushToTalkGesture
  ) -> Task<Void, Never>? {
    guard activeRunID == runID,
      let liveAudioSession = activeLiveAudioSession
    else {
      return nil
    }
    activeStartCueToken?.invalidate()
    activeStartCueToken = nil
    cancelMaximumDurationTask(runID: runID)
    state = .transcribing(runID)
    let operationID = UUID()
    let stopCueToken = RecordingCueToken()
    let triggerEvent = activeTriggerEvent
    let task = Task { [weak self] in
      guard let self else { return }
      await self.runFinishingPushToTalkRecording(
        runID: runID,
        operationID: operationID,
        workflow: workflow,
        gesture: gesture,
        triggerEvent: triggerEvent,
        liveAudioSession: liveAudioSession,
        stopCueToken: stopCueToken
      )
    }
    finishingRecordings[runID] = FinishingRecording(
      operationID: operationID,
      liveAudioSession: liveAudioSession,
      stopCueToken: stopCueToken,
      task: task
    )
    return task
  }

  fileprivate func runFinishingPushToTalkRecording(
    runID: UUID,
    operationID: UUID,
    workflow: WorkflowDefinition,
    gesture: PushToTalkGesture,
    triggerEvent: WorkflowTriggerEvent?,
    liveAudioSession: AuthorizedLiveAudioSession,
    stopCueToken: RecordingCueToken
  ) async {
    do {
      try await finishPushToTalkRecording(
        runID: runID,
        operationID: operationID,
        workflow: workflow,
        gesture: gesture,
        triggerEvent: triggerEvent,
        liveAudioSession: liveAudioSession,
        stopCueToken: stopCueToken
      )
      removeFinishingRecording(runID: runID, operationID: operationID)
    } catch {
      let wasExplicitlyCancelled =
        !ownsFinishingRecording(
          runID: runID,
          operationID: operationID
        ) || Task.isCancelled
      removeFinishingRecording(runID: runID, operationID: operationID)
      if wasExplicitlyCancelled { return }
      let task = beginManagedCancellation(
        runID: runID,
        failure: CancellationFailure(
          workflow: workflow.presentation,
          message: error.localizedDescription
        )
      )
      await task?.value
    }
  }

  fileprivate func finishPushToTalkRecording(
    runID: UUID,
    operationID: UUID,
    workflow: WorkflowDefinition,
    gesture: PushToTalkGesture,
    triggerEvent: WorkflowTriggerEvent?,
    liveAudioSession: AuthorizedLiveAudioSession,
    stopCueToken: RecordingCueToken
  ) async throws {
    // Stopping the privacy-sensitive input is the first suspension point
    // after the release/stop gesture. Diagnostics and feedback must never
    // extend the microphone boundary.
    let captureFinishStart = ContinuousClock.now
    let deferredCapture = try await audioCaptureService.finishCaptureDeferred()
    let captureFinishMillis = DiagnosticTiming.milliseconds(since: captureFinishStart)
    guard ownsFinishingRecording(runID: runID, operationID: operationID),
      !Task.isCancelled
    else {
      await discard(deferredCapture, runID: runID)
      return
    }
    let captureSealStart = ContinuousClock.now
    do {
      try await liveAudioSession.sealCapture()
    } catch {
      deferredCapture.cancel()
      await discard(deferredCapture, runID: runID)
      throw error
    }
    guard ownsFinishingRecording(runID: runID, operationID: operationID),
      !Task.isCancelled
    else {
      await discard(deferredCapture, runID: runID)
      return
    }
    let captureSealMillis = DiagnosticTiming.milliseconds(since: captureSealStart)
    let captureCueStart = ContinuousClock.now
    await recordingCueAction(.stopped, stopCueToken)
    let captureCueMillis = DiagnosticTiming.milliseconds(since: captureCueStart)
    stopCueToken.invalidate()
    guard ownsFinishingRecording(runID: runID, operationID: operationID),
      !Task.isCancelled
    else {
      await discard(deferredCapture, runID: runID)
      return
    }
    enqueueDiagnostic(
      level: .debug,
      event: "recording.finishing",
      message:
        "Push-to-talk recording finished for \(gesture.rawValue) and is being queued for background processing.",
      runID: runID,
      metadata: ["captureFinishMillis": captureFinishMillis,
                 "captureSealMillis": captureSealMillis,
                 "captureCueMillis": captureCueMillis]
    )
    guard ownsFinishingRecording(runID: runID, operationID: operationID),
      !Task.isCancelled
    else {
      await discard(deferredCapture, runID: runID)
      return
    }
    let processingLease = try await liveAudioSession.processingLeaseForEnqueue()
    guard ownsFinishingRecording(runID: runID, operationID: operationID),
      !Task.isCancelled,
      activeRunID == runID
    else {
      await discard(deferredCapture, runID: runID)
      return
    }
    let ownershipTransfer = await capturedAudioProcessingQueue.enqueue(
      authorizationLease: processingLease,
      triggerEvent: triggerEvent,
      deferredCapture: deferredCapture
    )
    guard ownershipTransfer == .accepted else {
      await discard(deferredCapture, runID: runID)
      if activeRunID == runID {
        resetState()
      }
      removeFinishingRecording(runID: runID, operationID: operationID)
      return
    }
    guard ownsFinishingRecording(runID: runID, operationID: operationID),
      !Task.isCancelled,
      activeRunID == runID
    else {
      // A concurrent Stop observed queue ownership and requested the
      // queue's run-scoped cancellation while enqueue was suspended.
      await capturedAudioProcessingQueue.cancel(runID: runID)
      return
    }
    // Clear the exact run synchronously before diagnostics can re-enter and
    // allow a newer capture to start.
    resetState()
    removeFinishingRecording(runID: runID, operationID: operationID)
    enqueueDiagnostic(
      level: .info,
      event: "recording.queued",
      message: "Push-to-talk recording was queued for background workflow processing.",
      runID: runID
    )
  }

  private func scheduleDeferredRelease(
    target: DeferredPushToTalkReleaseTarget,
    gesture: PushToTalkGesture
  ) {
    guard !hasBegunApplicationShutdown else { return }
    cancelActiveDeferredRelease()
    let taskID = UUID()
    let task = Task { [weak self] in
      try? await Task.sleep(for: Self.preparingReleaseDebounce)
      guard let self else { return }
      if !Task.isCancelled {
        await self.handleDeferredRelease(taskID: taskID, gesture: gesture)
      }
      await self.retirePushToTalkReleaseTask(taskID)
    }
    activePushToTalkReleaseTaskID = taskID
    activeDeferredReleaseTarget = target
    livePushToTalkReleaseTasks[taskID] = task
  }

  fileprivate func cancelActiveDeferredRelease() {
    guard let activePushToTalkReleaseTaskID else { return }
    livePushToTalkReleaseTasks[activePushToTalkReleaseTaskID]?.cancel()
    self.activePushToTalkReleaseTaskID = nil
    activeDeferredReleaseTarget = nil
  }

  fileprivate func retirePushToTalkReleaseTask(_ taskID: UUID) {
    livePushToTalkReleaseTasks[taskID] = nil
    if activePushToTalkReleaseTaskID == taskID {
      activePushToTalkReleaseTaskID = nil
      activeDeferredReleaseTarget = nil
    }
  }

  private func handleDeferredRelease(
    taskID: UUID,
    gesture: PushToTalkGesture
  ) async {
    guard activePushToTalkReleaseTaskID == taskID,
      let target = activeDeferredReleaseTarget
    else {
      return
    }
    if pushToTalkGestureStateProvider(gesture) {
      enqueueDiagnostic(
        level: .debug,
        event: "recording.deferred-release-ignored",
        message:
          "Ignored a deferred push-to-talk release because the gesture still appears active.",
        runID: activeRunID
      )
      return
    }

    switch target {
    case .startTask(let taskID):
      if var pending = pendingStreamHotkeyStart, pending.taskID == taskID {
        if pending.controlMode == .toggle { return }
        pending.deferredReleaseMatured = true
        pendingStreamHotkeyStart = pending
      }
    case .run(let runID):
      await cancelPreparationAfterDeferredRelease(
        runID: runID,
        gesture: gesture,
        gestureWasChecked: true
      )
    }
  }

  private func retargetDeferredRelease(
    fromStartTask taskID: UUID,
    toRun runID: UUID
  ) {
    guard case .startTask(let targetTaskID) = activeDeferredReleaseTarget,
      targetTaskID == taskID
    else {
      return
    }
    activeDeferredReleaseTarget = .run(runID)
  }

  fileprivate func cancelPreparationAfterDeferredRelease(
    runID: UUID,
    gesture: PushToTalkGesture,
    gestureWasChecked: Bool = false
  ) async {
    if !gestureWasChecked, pushToTalkGestureStateProvider(gesture) {
      enqueueDiagnostic(
        level: .debug,
        event: "recording.deferred-release-ignored",
        message:
          "Ignored a deferred push-to-talk release because the gesture still appears active.",
        runID: runID
      )
      return
    }

    switch state {
    case .preparing(let currentRunID) where currentRunID == runID:
      enqueueDiagnostic(
        level: .debug,
        event: "recording.cancelled-after-deferred-release",
        message: "Push-to-talk remained released during startup, so live capture was cancelled.",
        runID: runID
      )
      await cancelActiveCapture(runID: runID)
    case .recording(let currentRunID) where currentRunID == runID:
      enqueueDiagnostic(
        level: .debug,
        event: "recording.finished-after-deferred-release",
        message:
          "Push-to-talk was released during startup and remained released after recording became active, so the active run is finishing now.",
        runID: runID
      )
      await endPushToTalk(triggeredBy: gesture)
    default:
      break
    }
  }

  fileprivate func resetState() {
    if let activeRunID {
      retireAudioCaptureLifetimeMonitor(runID: activeRunID)
    }
    cancelMaximumDurationTask(runID: activeRunID)
    cancelActivePushToTalkStartTask()
    cancelActiveDeferredRelease()
    state = .idle
    activeRunID = nil
    activeWorkflow = nil
    activeTriggerEvent = nil
    activeLiveAudioSession = nil
    activeControlMode = nil
    pendingStreamHotkeyStart = nil
    activePushToTalkStartTaskID = nil
    activeStartCueToken?.invalidate()
    activeStartCueToken = nil
  }

  fileprivate func cancelActiveCapture(runID: UUID) async {
    await cancelCaptures(runID: runID)
  }

  fileprivate func cancelCaptures(runID requestedRunID: UUID?) async {
    let tasks = beginManagedCancellations(runID: requestedRunID)
    for task in tasks {
      await task.value
    }
  }

  /// Claims every matching run before returning and leaves one task as the
  /// sole owner of its external teardown. This keeps the state busy across
  /// actor reentrancy while stream ingestion continues independently.
  fileprivate func beginManagedCancellations(runID requestedRunID: UUID?) -> [Task<Void, Never>] {
    var runIDs = Set<UUID>()
    if let requestedRunID {
      if activeRunID == requestedRunID
        || finishingRecordings[requestedRunID] != nil
        || managedCancellations[requestedRunID] != nil
      {
        runIDs.insert(requestedRunID)
      }
    } else {
      runIDs.formUnion(finishingRecordings.keys)
      runIDs.formUnion(managedCancellations.keys)
      if let activeRunID {
        runIDs.insert(activeRunID)
      }
    }
    return runIDs.compactMap { beginManagedCancellation(runID: $0) }
  }

  /// Installs the managed task and the `.cancelling` state without an actor
  /// suspension. Duplicate callers share the same operation; only the first
  /// caller may attach a user-visible failure to it.
  private func beginManagedCancellation(
    runID: UUID,
    failure: CancellationFailure? = nil
  ) -> Task<Void, Never>? {
    if let existing = managedCancellations[runID] {
      return existing.task
    }

    let finishing = finishingRecordings.removeValue(forKey: runID)
    let isActiveRun = activeRunID == runID
    guard isActiveRun || finishing != nil else { return nil }

    retireAudioCaptureLifetimeMonitor(runID: runID)
    finishing?.stopCueToken.invalidate()
    finishing?.task?.cancel()
    let liveAudioSession = finishing?.liveAudioSession ?? activeLiveAudioSession
    let work = CancellationWork(
      runID: runID,
      liveAudioSession: liveAudioSession,
      finishingTask: finishing?.task
    )

    if isActiveRun {
      cancelActivePushToTalkStartTask()
      cancelActiveDeferredRelease()
      pendingStreamHotkeyStart = nil
      activeStartCueToken?.invalidate()
      activeStartCueToken = nil
      state = .cancelling(runID)
    }
    _ = liveAudioSession?.audioLifetime.cancel()

    let operationID = UUID()
    let task = Task { [weak self] in
      guard let self else { return }
      await self.runManagedCancellation(
        work,
        operationID: operationID,
        failure: failure
      )
    }
    managedCancellations[runID] = ManagedCancellation(
      operationID: operationID,
      task: task
    )
    return task
  }

  private func runManagedCancellation(
    _ work: CancellationWork,
    operationID: UUID,
    failure: CancellationFailure?
  ) async {
    await audioCaptureService.cancelCapture(runID: work.runID)
    let cancellationResult = await work.liveAudioSession?.cancel()
    if cancellationResult == .queueOwned {
      await capturedAudioProcessingQueue.cancel(runID: work.runID)
    }
    if let finishingTask = work.finishingTask {
      await finishingTask.value
    }

    guard ownsManagedCancellation(runID: work.runID, operationID: operationID) else {
      return
    }
    if let failure {
      await publishFailure(
        runID: work.runID,
        workflow: failure.workflow,
        message: failure.message
      )
    }
    completeManagedCancellation(runID: work.runID, operationID: operationID)
  }

  fileprivate func isCancellationInProgress(runID: UUID) -> Bool {
    managedCancellations[runID] != nil
  }

  fileprivate func ownsManagedCancellation(runID: UUID, operationID: UUID) -> Bool {
    managedCancellations[runID]?.operationID == operationID
  }

  fileprivate func completeManagedCancellation(runID: UUID, operationID: UUID) {
    guard ownsManagedCancellation(runID: runID, operationID: operationID) else { return }
    managedCancellations[runID] = nil
    if activeRunID == runID {
      resetState()
    }
  }

  fileprivate func ownsFinishingRecording(runID: UUID, operationID: UUID) -> Bool {
    finishingRecordings[runID]?.operationID == operationID
  }

  fileprivate func removeFinishingRecording(runID: UUID, operationID: UUID) {
    guard let finishing = finishingRecordings[runID],
      finishing.operationID == operationID
    else { return }
    finishing.stopCueToken.invalidate()
    finishingRecordings[runID] = nil
  }

  fileprivate func discard(_ deferredCapture: DeferredCapturedAudio, runID: UUID) async {
    deferredCapture.cancel()
    let capturedAudio = await Task.detached {
      try? await deferredCapture.value()
    }.value
    guard let capturedAudio else { return }
    guard await cleanupOwner.transfer(capturedAudio, runID: runID) else { return }
    await cleanupOwner.drain(runID: runID)
  }

  fileprivate func handleLiveAuthorizationRevocation(
    runID: UUID,
    reason: LiveAudioAuthorizationRevocationReason
  ) async {
    guard activeRunID == runID else { return }
    let message = LiveAudioSessionError.authorizationInvalidated(reason).localizedDescription
    enqueueDiagnostic(
      level: .warning,
      event: "recording.live-authorization-revoked",
      message: "Live recording stopped because its privacy authorization changed.",
      runID: runID,
      metadata: ["reason": reason.rawValue]
    )
    let task = beginManagedCancellation(
      runID: runID,
      failure: CancellationFailure(
        workflow: activeWorkflow?.presentation,
        message: message
      )
    )
    await task?.value
  }
}
