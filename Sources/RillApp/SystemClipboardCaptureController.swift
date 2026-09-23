import ApplicationServices
import Foundation
import RillCore
import RillPlatform
import RillRuntime

@MainActor
protocol SystemClipboardAccess: Sendable {
  func currentClipboardChangeCount() async -> Int
  func currentClipboardDescriptor() async -> SystemClipboardDescriptor
  func readClipboardSnapshot(ifChangeCountIs expected: Int) async -> SystemClipboardSnapshot?
  func ownsClipboardChangeCount(_ changeCount: Int) async -> Bool
}

extension SystemClipboardPort: SystemClipboardAccess {
  func currentClipboardChangeCount() async -> Int {
    currentChangeCount()
  }

  func currentClipboardDescriptor() async -> SystemClipboardDescriptor {
    currentDescriptor()
  }

  func readClipboardSnapshot(ifChangeCountIs expected: Int) async -> SystemClipboardSnapshot? {
    await readSnapshot(ifChangeCountIs: expected)
  }

  func ownsClipboardChangeCount(_ changeCount: Int) async -> Bool {
    isOwnedChangeCount(changeCount)
  }
}

public actor SystemClipboardCaptureController {
  private struct CaptureOperation: Sendable, Equatable {
    var id: UInt64
    var controlRevision: UInt64
  }

  private struct InitialClipboardPrivacyEvaluation: Sendable {
    var context: ContextSnapshot
    var decision: PrivacyPolicyDecision

    var allowsClipboardCapture: Bool {
      decision.allowsClipboardCapture
    }
  }

  private struct PendingClipboardCapture: Sendable {
    var snapshot: SystemClipboardSnapshot
    var sourceApplication: FocusedApplicationIdentity
    var privacy: InitialClipboardPrivacyEvaluation
    var byteCount: Int
    var bufferReservation: BufferInputReservation
  }

  private static let privacyCheckInterval = Duration.milliseconds(750)
  private static let clipboardPollInterval = Duration.milliseconds(50)
  private static let clipboardReadRetryDelays: [Duration] = [
    .milliseconds(50), .milliseconds(50), .milliseconds(50), .milliseconds(50),
    .milliseconds(250), .milliseconds(750), .seconds(1), .seconds(2),
  ]

  private let hotkeyTap: HotkeyEventTap
  private let pasteboard: any SystemClipboardAccess
  private let recordStore: RecordStore
  private let sessionCoordinator: SessionCoordinator
  private let eventBus: EventBus
  private let diagnostics: DiagnosticsRecorder?
  private let privacySettingsProvider: @Sendable () async throws -> PrivacyPolicySettings
  private let focusIdentitySampleProvider: @Sendable () async -> FocusPrivacyIdentitySample
  private let captureControlStateObserver: @Sendable (SystemClipboardCaptureControlSnapshot) async -> Void
  private let accessibilityChecker: @Sendable () -> Bool

  private var started = false
  private var stopped = false
  private var stopCompleted = false
  private var stopWaiters: [CheckedContinuation<Void, Never>] = []
  private var hotkeyEventsTask: Task<Void, Never>?
  private var externalClipboardMonitorTask: Task<Void, Never>?
  private var isDeliveryInProgress = false
  private var deliveryOperationWaiters: [CheckedContinuation<Void, Never>] = []
  // Capture begins only after start() merges an explicit preference. The
  // fail-closed desired value below remains the source of truth.
  private var captureControlSnapshot = SystemClipboardCaptureControlSnapshot.initial
  private var desiredClipboardCaptureEnabled = false
  private var hasUnversionedClipboardCaptureRequest = false
  private var latestClipboardCapturePreferenceRevision: UInt64?
  private var nextOperationID: UInt64 = 0
  private var inFlightCaptureOperationIDs: Set<UInt64> = []
  private var captureOperationWaiters: [CheckedContinuation<Void, Never>] = []
  private var lastObservedPasteboardChangeCount: Int?
  private var lastObservedFocusIdentitySample: FocusPrivacyIdentitySample?
  private var lastPrivacyDiagnosticChangeCount: Int?
  private var nextClipboardPrivacyCheck: ContinuousClock.Instant?
  private var bufferCancellationTask: Task<Void, Never>?
  private var bufferCancellationRetries: [BufferEntryID: Task<Void, Never>] = [:]
  private var observedBufferInput: (changeCount: Int, reservation: BufferInputReservation)?
  private var clipboardReadRetry:
    (changeCount: Int, focus: FocusPrivacyIdentitySample, attempts: Int, nextAttempt: ContinuousClock.Instant?)?
  private var pendingClipboardCaptures: [PendingClipboardCapture] = []
  private var pendingClipboardByteCount = 0
  private var clipboardPersistenceTask: Task<Void, Never>?

  public init(
    hotkeyTap: HotkeyEventTap,
    pasteboard: SystemClipboardPort,
    recordStore: RecordStore,
    sessionCoordinator: SessionCoordinator,
    eventBus: EventBus,
    diagnostics: DiagnosticsRecorder? = nil,
    privacySettingsProvider: @escaping @Sendable () async throws -> PrivacyPolicySettings = {
      throw PrivacyPolicySettingsSourceError.notReady
    },
    focusSnapshotProvider: (@Sendable () async -> FocusSnapshot)? = nil,
    focusIdentitySampleProvider: (@Sendable () async -> FocusPrivacyIdentitySample)? = nil,
    captureControlStateObserver:
      @escaping @Sendable (SystemClipboardCaptureControlSnapshot) async -> Void = { _ in },
    accessibilityChecker: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }
  ) {
    self.init(
      hotkeyTap: hotkeyTap,
      pasteboard: pasteboard as any SystemClipboardAccess,
      recordStore: recordStore,
      sessionCoordinator: sessionCoordinator,
      eventBus: eventBus,
      diagnostics: diagnostics,
      privacySettingsProvider: privacySettingsProvider,
      focusSnapshotProvider: focusSnapshotProvider,
      focusIdentitySampleProvider: focusIdentitySampleProvider,
      captureControlStateObserver: captureControlStateObserver,
      accessibilityChecker: accessibilityChecker
    )
  }

  init(
    hotkeyTap: HotkeyEventTap,
    pasteboard: any SystemClipboardAccess,
    recordStore: RecordStore,
    sessionCoordinator: SessionCoordinator,
    eventBus: EventBus,
    diagnostics: DiagnosticsRecorder? = nil,
    privacySettingsProvider: @escaping @Sendable () async throws -> PrivacyPolicySettings = {
      throw PrivacyPolicySettingsSourceError.notReady
    },
    focusSnapshotProvider: (@Sendable () async -> FocusSnapshot)? = nil,
    focusIdentitySampleProvider: (@Sendable () async -> FocusPrivacyIdentitySample)? = nil,
    captureControlStateObserver:
      @escaping @Sendable (SystemClipboardCaptureControlSnapshot) async -> Void = { _ in },
    accessibilityChecker: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }
  ) {
    self.hotkeyTap = hotkeyTap
    self.pasteboard = pasteboard
    self.recordStore = recordStore
    self.sessionCoordinator = sessionCoordinator
    self.eventBus = eventBus
    self.diagnostics = diagnostics
    self.privacySettingsProvider = privacySettingsProvider
    if let focusIdentitySampleProvider {
      self.focusIdentitySampleProvider = focusIdentitySampleProvider
    } else if let focusSnapshotProvider {
      self.focusIdentitySampleProvider = {
        FocusPrivacyIdentitySample(
          focus: await focusSnapshotProvider(),
          applicationActivationRevision: 0
        )
      }
    } else {
      self.focusIdentitySampleProvider = {
        return FocusPrivacyIdentitySample(
          focus: .init(
            applicationName: nil,
            bundleIdentifier: nil,
            processIdentifier: nil,
            focusedRole: nil,
            selectedText: "",
            secureInput: false
          ),
          applicationActivationRevision: 0
        )
      }
    }
    self.captureControlStateObserver = captureControlStateObserver
    self.accessibilityChecker = accessibilityChecker
  }

  public func stop() async {
    if stopped {
      await waitForStopCompletion()
      return
    }
    stopped = true
    started = false
    _ = transitionCaptureControl(to: .pausing)

    let tasks = [
      hotkeyEventsTask,
      externalClipboardMonitorTask,
    ].compactMap { $0 }
    hotkeyEventsTask = nil
    externalClipboardMonitorTask = nil
    for task in tasks {
      task.cancel()
    }
    for task in tasks {
      await task.value
    }

    await waitForDeliveryOperation()
    await waitForInFlightCaptureOperations()
    await clipboardPersistenceTask?.value
    await bufferCancellationTask?.value
    let cancellationRetries = Array(bufferCancellationRetries.values)
    for task in cancellationRetries { task.cancel() }
    for task in cancellationRetries { await task.value }
    bufferCancellationRetries.removeAll()
    _ = transitionCaptureControl(to: .paused)
    finishStop()
  }

  public func start(
    initialClipboardCaptureEnabled: Bool,
    preferenceRevision: UInt64 = 0
  ) async {
    guard !started, !stopped else { return }
    mergeInitialClipboardCapturePreference(
      isEnabled: initialClipboardCaptureEnabled,
      preferenceRevision: preferenceRevision
    )
    hotkeyTap.setRecordPanelShortcutEnabled(true)
    started = true

    // Register before the application-level GlobalInputOwner installs the
    // producer. AsyncStream buffers events until the listener task starts.
    let hotkeyStream = hotkeyTap.stream()
    if captureControlSnapshot.state == .active {
      let initialDescriptor = await pasteboard.currentClipboardDescriptor()
      let initialFocusSample = await focusIdentitySampleProvider()
      lastObservedPasteboardChangeCount = initialDescriptor.changeCount
      lastObservedFocusIdentitySample = initialFocusSample
      let initialControlRevision = captureControlSnapshot.revision
      let initialPrivacy = await evaluateInitialClipboardPrivacy(
        descriptor: initialDescriptor,
        focus: initialFocusSample.focus
      )
      if isCurrentControlState(.active, revision: initialControlRevision) {
        await recordInitialClipboardPrivacyIfNeeded(initialPrivacy)
      }
    }
    hotkeyEventsTask = Task {
      for await event in hotkeyStream {
        await self.handleHotkey(event)
      }
    }

    startExternalClipboardMonitorIfNeeded()

    await publishCaptureControlState()
  }

  private func mergeInitialClipboardCapturePreference(
    isEnabled: Bool,
    preferenceRevision: UInt64
  ) {
    guard !hasUnversionedClipboardCaptureRequest else { return }
    guard
      latestClipboardCapturePreferenceRevision.map({ preferenceRevision > $0 }) ?? true
    else { return }

    latestClipboardCapturePreferenceRevision = preferenceRevision
    desiredClipboardCaptureEnabled = isEnabled
    if isEnabled {
      guard captureControlSnapshot.state != .active else { return }
      _ = transitionCaptureControl(to: .active)
      return
    }

    guard captureControlSnapshot.state != .paused else { return }
    _ = transitionCaptureControl(to: .paused)
  }

  private func startExternalClipboardMonitorIfNeeded() {
    guard started, !stopped, externalClipboardMonitorTask == nil else { return }
    guard desiredClipboardCaptureEnabled else { return }
    guard
      captureControlSnapshot.state == .active
        || captureControlSnapshot.state == .ignoringNextExternalChange
    else { return }

    externalClipboardMonitorTask = Task {
      while !Task.isCancelled {
        await self.pollExternalClipboardIfNeeded()
        try? await Task.sleep(for: Self.clipboardPollInterval)
      }
    }
  }

  private func pollExternalClipboardIfNeeded(at now: ContinuousClock.Instant = .now) async {
    let revision = captureControlSnapshot.revision
    let changeCount = await pasteboard.currentClipboardChangeCount()
    let focusSample = await focusIdentitySampleProvider()
    guard captureControlSnapshot.revision == revision else { return }
    // Keep idle polling cheap while still rechecking policy without a new copy.
    guard changeCount != lastObservedPasteboardChangeCount
      || isClipboardReadRetryDue(changeCount: changeCount, at: now)
      || lastObservedFocusIdentitySample?.hasSamePrivacyIdentity(as: focusSample) != true
      || nextClipboardPrivacyCheck.map({ now >= $0 }) != false
    else { return }
    nextClipboardPrivacyCheck = now + Self.privacyCheckInterval
    await captureExternalClipboardIfNeeded(at: now)
  }

  private func stopExternalClipboardMonitor() async {
    guard let task = externalClipboardMonitorTask else { return }
    externalClipboardMonitorTask = nil
    task.cancel()
    await task.value
  }

  public func setClipboardCapturePaused(_ isPaused: Bool) async {
    hasUnversionedClipboardCaptureRequest = true
    desiredClipboardCaptureEnabled = !isPaused
    await applyDesiredClipboardCaptureState()
  }

  /// Applies a persisted clipboard-capture preference only when it is newer than the
  /// last version observed by this runtime. This prevents an asynchronous settings load
  /// from overwriting a more recent user update during application startup.
  public func setSystemClipboardCaptureEnabled(
    _ isEnabled: Bool,
    preferenceRevision: UInt64
  ) async {
    guard latestClipboardCapturePreferenceRevision.map({ preferenceRevision > $0 }) ?? true else {
      return
    }
    latestClipboardCapturePreferenceRevision = preferenceRevision
    desiredClipboardCaptureEnabled = isEnabled
    await applyDesiredClipboardCaptureState()
  }

  private func applyDesiredClipboardCaptureState() async {
    guard !stopped else { return }
    hotkeyTap.setRecordPanelShortcutEnabled(true)
    let isPaused = !desiredClipboardCaptureEnabled
    if isPaused {
      await pauseClipboardCapture()
      return
    }

    await resumeClipboardCapture()
  }

  private func pauseClipboardCapture() async {
    switch captureControlSnapshot.state {
    case .pausing, .paused:
      return
    case .active, .resuming, .armingIgnoreNextExternalChange, .ignoringNextExternalChange:
      break
    }

    let transitionRevision = transitionCaptureControl(to: .pausing)
    await publishCaptureControlState()
    guard isCurrentControlState(.pausing, revision: transitionRevision) else { return }

    await stopExternalClipboardMonitor()
    guard isCurrentControlState(.pausing, revision: transitionRevision) else { return }
    await waitForInFlightCaptureOperations()
    guard isCurrentControlState(.pausing, revision: transitionRevision) else { return }
    await clipboardPersistenceTask?.value
    await bufferCancellationTask?.value
    guard isCurrentControlState(.pausing, revision: transitionRevision) else { return }

    let pausedRevision = transitionCaptureControl(to: .paused)
    await publishCaptureControlState()
    guard isCurrentControlState(.paused, revision: pausedRevision) else { return }
    await recordCaptureControlEvent(
      event: "clipboard.capture.paused",
      message: "Paused external clipboard capture after in-flight clipboard operations settled."
    )
    if desiredClipboardCaptureEnabled {
      await resumeClipboardCapture()
    }
  }

  private func resumeClipboardCapture() async {
    guard captureControlSnapshot.state == .paused else { return }
    let transitionRevision = transitionCaptureControl(to: .resuming)
    await publishCaptureControlState()
    guard isCurrentControlState(.resuming, revision: transitionRevision) else { return }

    var descriptor: SystemClipboardDescriptor
    var focusSample: FocusPrivacyIdentitySample
    var evaluation: InitialClipboardPrivacyEvaluation
    while true {
      descriptor = await pasteboard.currentClipboardDescriptor()
      guard isCurrentControlState(.resuming, revision: transitionRevision) else { return }
      focusSample = await focusIdentitySampleProvider()
      guard isCurrentControlState(.resuming, revision: transitionRevision) else { return }
      evaluation = await evaluateInitialClipboardPrivacy(
        descriptor: descriptor,
        focus: focusSample.focus
      )
      guard isCurrentControlState(.resuming, revision: transitionRevision) else { return }

      let verifiedDescriptor = await pasteboard.currentClipboardDescriptor()
      guard isCurrentControlState(.resuming, revision: transitionRevision) else { return }
      let verifiedFocusSample = await focusIdentitySampleProvider()
      guard isCurrentControlState(.resuming, revision: transitionRevision) else { return }
      guard verifiedDescriptor == descriptor,
        verifiedFocusSample.hasSamePrivacyIdentity(as: focusSample)
      else {
        continue
      }
      break
    }

    lastObservedPasteboardChangeCount = descriptor.changeCount
    lastObservedFocusIdentitySample = focusSample
    let activeRevision = transitionCaptureControl(to: .active)
    startExternalClipboardMonitorIfNeeded()
    await publishCaptureControlState()
    guard isCurrentControlState(.active, revision: activeRevision) else { return }
    await recordInitialClipboardPrivacyIfNeeded(evaluation)
    guard isCurrentControlState(.active, revision: activeRevision) else { return }
    await recordCaptureControlEvent(
      event: "clipboard.capture.resumed",
      message: "Resumed external clipboard capture from the current pasteboard baseline."
    )
    if !desiredClipboardCaptureEnabled {
      await pauseClipboardCapture()
    }
  }

  public func ignoreNextExternalClipboardChange() async {
    guard captureControlSnapshot.state == .active else { return }
    let transitionRevision = transitionCaptureControl(to: .armingIgnoreNextExternalChange)
    await publishCaptureControlState()
    guard isCurrentControlState(.armingIgnoreNextExternalChange, revision: transitionRevision)
    else { return }

    let descriptor = await pasteboard.currentClipboardDescriptor()
    guard isCurrentControlState(.armingIgnoreNextExternalChange, revision: transitionRevision)
    else { return }
    let focusSample = await focusIdentitySampleProvider()
    guard isCurrentControlState(.armingIgnoreNextExternalChange, revision: transitionRevision)
    else { return }
    lastObservedPasteboardChangeCount = descriptor.changeCount
    lastObservedFocusIdentitySample = focusSample

    await waitForInFlightCaptureOperations()
    guard isCurrentControlState(.armingIgnoreNextExternalChange, revision: transitionRevision)
    else { return }

    let ignoringRevision = transitionCaptureControl(to: .ignoringNextExternalChange)
    await publishCaptureControlState()
    guard isCurrentControlState(.ignoringNextExternalChange, revision: ignoringRevision) else {
      return
    }
    await recordCaptureControlEvent(
      event: "clipboard.capture.ignore-next-armed",
      message: "Armed one-time external clipboard capture suppression."
    )
  }

  public func deliverNextRecord() async {
    guard !stopped, !isDeliveryInProgress else { return }
    guard accessibilityChecker() else {
      await publishSelectedRecordDeliveryFailure(
        message: TextInjectionEngine.InjectionError.accessibilityPermissionRequired.localizedDescription
      )
      return
    }
    isDeliveryInProgress = true
    defer { finishDeliveryOperation() }
    let focus = await focusIdentitySampleProvider().focus
    guard !stopped, let target = FocusedApplicationTargetIdentity(focus: focus) else {
      await reportSelectedRecordDeliveryUnavailable()
      return
    }
    await sessionCoordinator.deliverNextRecord(
      for: FocusedApplicationIdentity(
        bundleIdentifier: focus.bundleIdentifier, applicationName: focus.applicationName),
      actionID: RecordActionID.focusedApplicationInsert,
      expectedTarget: target
    )
  }

  public func deliverSelectedRecord(
    _ subject: RecordDeliverySubject,
    to target: FocusedApplicationTargetIdentity
  ) async {
    guard !stopped else { return }
    guard accessibilityChecker() else {
      await eventBus.publish(
        .runFailed(
          runID: nil,
          workflow: WorkflowPresentation(
            fallbackName: "Record Delivery",
            titleKey: .recordDelivery
          ),
          message: TextInjectionEngine.InjectionError.accessibilityPermissionRequired
            .localizedDescription
        )
      )
      return
    }
    if isDeliveryInProgress {
      await publishSelectedRecordDeliveryFailure(
        message: HistoryFailureSanitizer.genericMessage
      )
      return
    }
    isDeliveryInProgress = true
    defer {
      finishDeliveryOperation()
    }

    await sessionCoordinator.deliverRecord(
      matching: subject, to: target, actionID: RecordActionID.focusedApplicationInsert)
  }

  public func reuseRecord(
    _ subject: RecordReuseSubject,
    to target: FocusedApplicationTargetIdentity? = nil,
    copyOnly: Bool = false
  ) async -> RecordReuseOutcome {
    guard !stopped, !isDeliveryInProgress else { return .blocked }
    guard copyOnly || accessibilityChecker() else {
      await reportSelectedRecordDeliveryUnavailable()
      return .permissionRequired
    }
    isDeliveryInProgress = true
    defer { finishDeliveryOperation() }
    return await sessionCoordinator.reuseRecord(subject, to: target, copyOnly: copyOnly)
  }

  public func reportSelectedRecordDeliveryUnavailable() async {
    await publishSelectedRecordDeliveryFailure(
      message: HistoryFailureSanitizer.genericMessage
    )
  }

  private func publishSelectedRecordDeliveryFailure(message: String) async {
    await eventBus.publish(
      .runFailed(
        runID: nil,
        workflow: WorkflowPresentation(
          fallbackName: "Record Delivery",
          titleKey: .recordDelivery
        ),
        message: message
      )
    )
  }

  private func focusedApplicationIdentity(
    _ routeContext: RecordRouteContext
  ) -> FocusedApplicationIdentity {
    FocusedApplicationIdentity(
      bundleIdentifier: routeContext.bundleIdentifier,
      applicationName: routeContext.applicationName
    )
  }
}

extension SystemClipboardCaptureController {
  fileprivate func captureExternalClipboardIfNeeded(at now: ContinuousClock.Instant = .now) async {
    guard
      captureControlSnapshot.state == .active
        || captureControlSnapshot.state == .ignoringNextExternalChange
    else { return }
    let observedControlRevision = captureControlSnapshot.revision
    let observedControlState = captureControlSnapshot.state
    let descriptor = await pasteboard.currentClipboardDescriptor()
    guard captureControlSnapshot.revision == observedControlRevision,
      captureControlSnapshot.state == observedControlState
    else { return }
    let focusSample = await focusIdentitySampleProvider()
    guard captureControlSnapshot.revision == observedControlRevision,
      captureControlSnapshot.state == observedControlState
    else { return }
    let evaluation = await evaluateInitialClipboardPrivacy(
      descriptor: descriptor,
      focus: focusSample.focus
    )
    guard captureControlSnapshot.revision == observedControlRevision,
      captureControlSnapshot.state == observedControlState
    else { return }
    let descriptorAfterPolicy = await pasteboard.currentClipboardDescriptor()
    guard captureControlSnapshot.revision == observedControlRevision,
      captureControlSnapshot.state == observedControlState
    else { return }
    let focusAfterPolicy = await focusIdentitySampleProvider()
    guard captureControlSnapshot.revision == observedControlRevision,
      captureControlSnapshot.state == observedControlState
    else { return }
    guard descriptorAfterPolicy == descriptor,
      focusAfterPolicy.hasSamePrivacyIdentity(as: focusSample)
    else {
      lastObservedFocusIdentitySample = focusAfterPolicy
      if !focusAfterPolicy.hasSamePrivacyIdentity(as: focusSample) {
        await recordFocusTransitionCaptureSkip(focus: focusAfterPolicy.focus)
      } else {
        await recordClipboardReadRace(context: evaluation.context)
      }
      return
    }

    if let observedBufferInput, observedBufferInput.changeCount != descriptor.changeCount {
      abandonObservedBufferInput()
    }
    let crossedPrivacyIdentity =
      lastObservedFocusIdentitySample.map {
        !focusSample.hasSamePrivacyIdentity(as: $0)
      } ?? false
    if let retry = clipboardReadRetry, !retry.focus.hasSamePrivacyIdentity(as: focusSample) {
      clipboardReadRetry = nil
      abandonObservedBufferInput()
    }

    guard evaluation.allowsClipboardCapture else {
      lastObservedPasteboardChangeCount = descriptor.changeCount
      lastObservedFocusIdentitySample = focusSample
      clipboardReadRetry = nil
      abandonObservedBufferInput()
      await recordCaptureDecision(
        evaluation.decision,
        context: evaluation.context,
        event: "clipboard.capture.skipped",
        message: "Skipped clipboard capture because of the active privacy policy."
      )
      return
    }

    guard descriptor.changeCount != lastObservedPasteboardChangeCount
      || isClipboardReadRetryDue(changeCount: descriptor.changeCount, at: now)
    else {
      lastObservedFocusIdentitySample = focusSample
      return
    }

    switch captureControlSnapshot.state {
    case .pausing, .paused, .resuming:
      lastObservedPasteboardChangeCount = descriptor.changeCount
      lastObservedFocusIdentitySample = focusSample
      return
    case .armingIgnoreNextExternalChange:
      lastObservedFocusIdentitySample = focusSample
      return
    case .active, .ignoringNextExternalChange:
      break
    }

    guard descriptor.hasTransferableContent else {
      lastObservedPasteboardChangeCount = descriptor.changeCount
      lastObservedFocusIdentitySample = focusSample
      clipboardReadRetry?.nextAttempt = nil
      if !crossedPrivacyIdentity {
        if captureControlSnapshot.state == .active {
          let operation = beginCaptureOperation(controlRevision: observedControlRevision)
          defer { finishCaptureOperation(operation.id) }
          let isOwned = await pasteboard.ownsClipboardChangeCount(descriptor.changeCount)
          guard isCaptureOperationCurrent(operation) else { return }
          if !isOwned { _ = try? await bufferReservation(for: descriptor.changeCount) }
          guard isCaptureOperationCurrent(operation) else {
            abandonObservedBufferInput()
            return
          }
        }
        retryClipboardReadIfNeeded(changeCount: descriptor.changeCount, focus: focusSample, at: now)
      }
      if clipboardReadRetry?.nextAttempt == nil { abandonObservedBufferInput() }
      return
    }
    let isOwnedChangeCount = await pasteboard.ownsClipboardChangeCount(descriptor.changeCount)
    guard captureControlSnapshot.revision == observedControlRevision,
      captureControlSnapshot.state == observedControlState
    else { return }
    guard descriptor.changeCount != lastObservedPasteboardChangeCount
      || isClipboardReadRetryDue(changeCount: descriptor.changeCount, at: now)
    else { return }
    lastObservedPasteboardChangeCount = descriptor.changeCount
    lastObservedFocusIdentitySample = focusSample
    clipboardReadRetry?.nextAttempt = nil
    guard !isOwnedChangeCount else { return }

    switch captureControlSnapshot.state {
    case .ignoringNextExternalChange:
      _ = transitionCaptureControl(to: .active)
      await publishCaptureControlState()
      await recordCaptureControlEvent(
        event: "clipboard.capture.ignore-next-consumed",
        message: "Ignored one external clipboard change without reading its payload."
      )
      return
    case .active:
      break
    case .pausing, .armingIgnoreNextExternalChange, .paused, .resuming:
      return
    }

    guard !crossedPrivacyIdentity else {
      await recordFocusTransitionCaptureSkip(focus: focusSample.focus)
      return
    }

    let captureRevision = captureControlSnapshot.revision
    let captureOperation = beginCaptureOperation(controlRevision: captureRevision)
    defer { finishCaptureOperation(captureOperation.id) }

    let bufferReservation: BufferInputReservation
    do { bufferReservation = try await self.bufferReservation(for: descriptor.changeCount) }
    catch { return }
    var acceptedBufferInput = false
    defer {
      if acceptedBufferInput {
        observedBufferInput = nil
      } else if clipboardReadRetry?.changeCount != descriptor.changeCount || clipboardReadRetry?.nextAttempt == nil {
        abandonObservedBufferInput()
      }
    }
    guard isCaptureOperationCurrent(captureOperation) else { return }
    let routeContext = RecordRouteContext(
      applicationName: focusSample.focus.applicationName,
      bundleIdentifier: focusSample.focus.bundleIdentifier
    )
    let descriptorBeforePayloadRead = await pasteboard.currentClipboardDescriptor()
    guard isCaptureOperationCurrent(captureOperation) else { return }
    let focusBeforePayloadRead = await focusIdentitySampleProvider()
    guard isCaptureOperationCurrent(captureOperation) else { return }
    let evaluationBeforePayloadRead = await evaluateInitialClipboardPrivacy(
      descriptor: descriptorBeforePayloadRead,
      focus: focusBeforePayloadRead.focus
    )
    guard isCaptureOperationCurrent(captureOperation) else { return }
    let descriptorAfterPreReadPolicy = await pasteboard.currentClipboardDescriptor()
    guard isCaptureOperationCurrent(captureOperation) else { return }
    let focusAfterPreReadPolicy = await focusIdentitySampleProvider()
    guard isCaptureOperationCurrent(captureOperation) else { return }
    guard descriptorBeforePayloadRead == descriptor,
      descriptorAfterPreReadPolicy == descriptor,
      focusBeforePayloadRead.hasSamePrivacyIdentity(as: focusSample),
      focusAfterPreReadPolicy.hasSamePrivacyIdentity(as: focusBeforePayloadRead),
      evaluationBeforePayloadRead.decision == evaluation.decision,
      evaluationBeforePayloadRead.allowsClipboardCapture
    else {
      lastObservedFocusIdentitySample = focusAfterPreReadPolicy
      if !evaluationBeforePayloadRead.allowsClipboardCapture {
        await recordCaptureDecision(
          evaluationBeforePayloadRead.decision,
          context: evaluationBeforePayloadRead.context,
          event: "clipboard.capture.skipped",
          message:
            "Skipped clipboard capture because the privacy boundary changed before payload read."
        )
      } else if !focusBeforePayloadRead.hasSamePrivacyIdentity(as: focusSample)
        || !focusAfterPreReadPolicy.hasSamePrivacyIdentity(as: focusBeforePayloadRead)
      {
        await recordFocusTransitionCaptureSkip(focus: focusAfterPreReadPolicy.focus)
      } else {
        await recordClipboardReadRace(context: evaluation.context)
      }
      return
    }

    guard
      let snapshot = await pasteboard.readClipboardSnapshot(
        ifChangeCountIs: descriptor.changeCount
      )
    else {
      guard isCaptureOperationCurrent(captureOperation) else { return }
      retryClipboardReadIfNeeded(changeCount: descriptor.changeCount, focus: focusSample, at: now)
      await recordClipboardReadRace(context: evaluation.context)
      return
    }
    guard isCaptureOperationCurrent(captureOperation) else { return }
    let descriptorAfterPayloadRead = await pasteboard.currentClipboardDescriptor()
    guard isCaptureOperationCurrent(captureOperation) else { return }
    let focusAfterPayloadRead = await focusIdentitySampleProvider()
    guard isCaptureOperationCurrent(captureOperation) else { return }
    let evaluationAfterPayloadRead = await evaluateInitialClipboardPrivacy(
      descriptor: descriptorAfterPayloadRead,
      focus: focusAfterPayloadRead.focus
    )
    guard isCaptureOperationCurrent(captureOperation) else { return }
    let descriptorAfterPostReadPolicy = await pasteboard.currentClipboardDescriptor()
    guard isCaptureOperationCurrent(captureOperation) else { return }
    let focusAfterPostReadPolicy = await focusIdentitySampleProvider()
    guard isCaptureOperationCurrent(captureOperation) else { return }
    guard descriptorAfterPayloadRead == descriptor,
      descriptorAfterPostReadPolicy == descriptor,
      focusAfterPayloadRead.hasSamePrivacyIdentity(as: focusSample),
      focusAfterPostReadPolicy.hasSamePrivacyIdentity(as: focusAfterPayloadRead),
      evaluationAfterPayloadRead.decision == evaluation.decision,
      evaluationAfterPayloadRead.allowsClipboardCapture
    else {
      lastObservedFocusIdentitySample = focusAfterPostReadPolicy
      if !evaluationAfterPayloadRead.allowsClipboardCapture {
        await recordCaptureDecision(
          evaluationAfterPayloadRead.decision,
          context: evaluationAfterPayloadRead.context,
          event: "clipboard.capture.skipped",
          message: "Discarded clipboard payload because the privacy boundary changed during read."
        )
      } else if !focusAfterPayloadRead.hasSamePrivacyIdentity(as: focusSample)
        || !focusAfterPostReadPolicy.hasSamePrivacyIdentity(as: focusAfterPayloadRead)
      {
        await recordFocusTransitionCaptureSkip(focus: focusAfterPostReadPolicy.focus)
      } else {
        await recordClipboardReadRace(context: evaluation.context)
      }
      return
    }

    guard snapshot.hasTransferableContent else {
      if snapshot.captureStorageRejection == nil {
        retryClipboardReadIfNeeded(changeCount: descriptor.changeCount, focus: focusSample, at: now)
      }
      return
    }

    let byteCount = snapshot.plainText.utf8.count + (snapshot.imagePNGData?.count ?? 0)
      + snapshot.fileURLs.reduce(0) { $0 + $1.absoluteString.utf8.count }
    // Accepted snapshots survive a newer copy; disk latency must not delay polling.
    // Backpressure bounds both the number of captures and retained rich payloads.
    if pendingClipboardCaptures.count >= 8
      || pendingClipboardByteCount + byteCount > 64 * 1_024 * 1_024
    {
      await clipboardPersistenceTask?.value
    }
    pendingClipboardCaptures.append(
      PendingClipboardCapture(
        snapshot: snapshot,
        sourceApplication: focusedApplicationIdentity(routeContext),
        privacy: evaluation,
        byteCount: byteCount,
        bufferReservation: bufferReservation
      )
    )
    acceptedBufferInput = true
    pendingClipboardByteCount += byteCount
    if clipboardPersistenceTask == nil {
      clipboardPersistenceTask = Task { await self.persistPendingClipboardCaptures() }
    }
  }

  private func persistPendingClipboardCaptures() async {
    while let capture = pendingClipboardCaptures.first {
      var attempts = 0
      while true {
        do {
          try await capture.bufferReservation.committed.value
          _ = try await recordStore.captureSystemClipboard(
            snapshot: capture.snapshot,
            sourceApplication: capture.sourceApplication,
            allowsWorkflowCapture: capture.privacy.decision.allowsWorkflowCapture,
            bufferEntryID: capture.bufferReservation.id
          )
          if !capture.privacy.decision.allowsWorkflowCapture {
            await recordCaptureDecision(
              capture.privacy.decision,
              context: capture.privacy.context,
              event: "clipboard.capture.workflow-skipped",
              message: "Saved clipboard history without emitting a workflow event."
            )
          }
          break
        } catch {
          if error as? RecordStoreError == .persistenceUnavailable, attempts < 2 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(50 * attempts))
            continue
          }
          await diagnostics?.record(
            DiagnosticEvent(
              subsystem: .systemClipboard,
              level: .warning,
              event: "clipboard.state.persist-failed",
              message: "Could not save the external clipboard to record history."
            )
          )
          break
        }
      }
      await cancelBufferInputWithRetry(capture.bufferReservation.id)
      pendingClipboardCaptures.removeFirst()
      pendingClipboardByteCount -= capture.byteCount
    }
    clipboardPersistenceTask = nil
  }

  private func bufferReservation(for changeCount: Int) async throws -> BufferInputReservation {
    if let observedBufferInput, observedBufferInput.changeCount == changeCount { return observedBufferInput.reservation }
    abandonObservedBufferInput()
    let reservation = try await recordStore.observeBufferInput(in: RecordBuffer.clipboardID)
    observedBufferInput = (changeCount, reservation)
    return reservation
  }

  private func abandonObservedBufferInput() {
    guard let reservation = observedBufferInput?.reservation else { return }
    observedBufferInput = nil
    let previous = bufferCancellationTask
    bufferCancellationTask = Task {
      await previous?.value
      _ = try? await reservation.committed.value
      await cancelBufferInputWithRetry(reservation.id)
    }
  }

  private func cancelBufferInputWithRetry(_ id: BufferEntryID) async {
    do { try await recordStore.cancelBufferInput(id) }
    catch {
      guard !stopped, bufferCancellationRetries[id] == nil else { return }
      bufferCancellationRetries[id] = Task {
        while !Task.isCancelled {
          do {
            try await Task.sleep(for: .milliseconds(250))
            try await recordStore.cancelBufferInput(id)
            break
          } catch { if Task.isCancelled { break } }
        }
        bufferCancellationRetries.removeValue(forKey: id)
      }
    }
  }

  private func isClipboardReadRetryDue(changeCount: Int, at now: ContinuousClock.Instant) -> Bool {
    guard let retry = clipboardReadRetry, retry.changeCount == changeCount,
      let nextAttempt = retry.nextAttempt
    else { return false }
    return now >= nextAttempt
  }

  private func retryClipboardReadIfNeeded(
    changeCount: Int, focus: FocusPrivacyIdentitySample, at now: ContinuousClock.Instant
  ) {
    guard lastObservedPasteboardChangeCount == changeCount else { return }
    if clipboardReadRetry?.changeCount != changeCount {
      clipboardReadRetry = (changeCount, focus, 0, nil)
    }
    guard let retry = clipboardReadRetry,
      retry.attempts < Self.clipboardReadRetryDelays.count
    else { return }
    clipboardReadRetry = (
      changeCount, focus, retry.attempts + 1, now + Self.clipboardReadRetryDelays[retry.attempts]
    )
  }

  private func evaluateInitialClipboardPrivacy(
    descriptor: SystemClipboardDescriptor,
    focus: FocusSnapshot
  ) async -> InitialClipboardPrivacyEvaluation {
    let context = ContextSnapshot(
      focus: focus,
      clipboard: descriptor.policySnapshot
    )
    let decision = await capturePrivacyDecision(for: context)
    return InitialClipboardPrivacyEvaluation(context: context, decision: decision)
  }

  private func recordInitialClipboardPrivacyIfNeeded(
    _ evaluation: InitialClipboardPrivacyEvaluation
  ) async {
    guard !evaluation.decision.allowsClipboardCapture else { return }
    await recordCaptureDecision(
      evaluation.decision,
      context: evaluation.context,
      event: "clipboard.capture.initial-skipped",
      message: "Kept the initial clipboard outside Rill because of the active privacy policy."
    )
  }

  fileprivate func publishCaptureControlState() async {
    let snapshot = captureControlSnapshot
    await captureControlStateObserver(snapshot)
  }

  @discardableResult
  fileprivate func transitionCaptureControl(to state: SystemClipboardCaptureControlState) -> UInt64 {
    captureControlSnapshot.revision &+= 1
    captureControlSnapshot.state = state
    clipboardReadRetry = nil
    abandonObservedBufferInput()
    return captureControlSnapshot.revision
  }

  fileprivate func isCurrentControlState(
    _ state: SystemClipboardCaptureControlState,
    revision: UInt64
  ) -> Bool {
    captureControlSnapshot.revision == revision && captureControlSnapshot.state == state
  }

  private func beginCaptureOperation(controlRevision: UInt64) -> CaptureOperation {
    nextOperationID &+= 1
    let operation = CaptureOperation(id: nextOperationID, controlRevision: controlRevision)
    inFlightCaptureOperationIDs.insert(operation.id)
    return operation
  }

  private func isCaptureOperationCurrent(_ operation: CaptureOperation) -> Bool {
    inFlightCaptureOperationIDs.contains(operation.id)
      && isCurrentControlState(.active, revision: operation.controlRevision)
  }

  fileprivate func finishCaptureOperation(_ operationID: UInt64) {
    guard inFlightCaptureOperationIDs.remove(operationID) != nil else { return }
    guard inFlightCaptureOperationIDs.isEmpty else { return }
    let waiters = captureOperationWaiters
    captureOperationWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  fileprivate func finishDeliveryOperation() {
    guard isDeliveryInProgress else { return }
    isDeliveryInProgress = false
    let waiters = deliveryOperationWaiters
    deliveryOperationWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  fileprivate func finishStop() {
    guard !stopCompleted else { return }
    stopCompleted = true
    let waiters = stopWaiters
    stopWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  fileprivate func waitForStopCompletion() async {
    while !stopCompleted {
      await withCheckedContinuation { continuation in
        stopWaiters.append(continuation)
      }
    }
  }

  fileprivate func waitForDeliveryOperation() async {
    while isDeliveryInProgress {
      await withCheckedContinuation { continuation in
        deliveryOperationWaiters.append(continuation)
      }
    }
  }

  fileprivate func waitForInFlightCaptureOperations() async {
    while !inFlightCaptureOperationIDs.isEmpty {
      await withCheckedContinuation { continuation in
        captureOperationWaiters.append(continuation)
      }
    }
  }

  fileprivate func recordCaptureControlEvent(event: String, message: String) async {
    guard let diagnostics else { return }
    await diagnostics.record(
      DiagnosticEvent(
        subsystem: .systemClipboard,
        level: .info,
        event: event,
        message: message,
        metadata: [
          "revision": String(captureControlSnapshot.revision),
          "state": captureControlSnapshot.state.rawValue,
        ]
      )
    )
  }

  fileprivate func recordClipboardReadRace(context: ContextSnapshot) async {
    guard let diagnostics else { return }
    await diagnostics.record(
      DiagnosticEvent(
        subsystem: .systemClipboard,
        level: .debug,
        event: "clipboard.capture.changed-before-read",
        message:
          "Skipped clipboard capture because the pasteboard changed during privacy evaluation.",
        metadata: ["bundleID": context.focus.bundleIdentifier ?? ""]
      )
    )
  }

  fileprivate func recordFocusTransitionCaptureSkip(focus: FocusSnapshot) async {
    guard let diagnostics else { return }
    await diagnostics.record(
      DiagnosticEvent(
        subsystem: .systemClipboard,
        level: .info,
        event: "clipboard.capture.focus-transition-skipped",
        message:
          "Skipped clipboard capture because application focus changed before the copy source could be verified.",
        metadata: [
          "bundleID": focus.bundleIdentifier ?? "",
          "activationRevision": String(
            lastObservedFocusIdentitySample?.applicationActivationRevision ?? 0
          ),
        ]
      )
    )
  }

  fileprivate func capturePrivacyDecision(for context: ContextSnapshot) async
    -> PrivacyPolicyDecision
  {
    do {
      let settings = try await privacySettingsProvider()
      return PrivacyPolicy.evaluate(context: context, settings: settings)
    } catch {
      return PrivacyPolicyDecision(
        decisions: [.skipClipboardCapture, .skipWorkflowCapture],
        reasons: [.privacySettingsUnavailable],
        redactedContext: ContextSnapshot(
          focus: context.focus,
          clipboard: SystemClipboardSnapshot(
            plainText: "",
            changeCount: context.clipboard.changeCount,
            captureTags: context.clipboard.captureTags,
            protections: context.clipboard.protections
          )
        ),
        redactedPromptVariables: [.clipboard],
        // The closed reason above is sufficient for diagnostics and receipts;
        // do not carry the settings backend's free-form error or app identity.
        metadata: [:]
      )
    }
  }

  fileprivate func recordCaptureDecision(
    _ decision: PrivacyPolicyDecision,
    context: ContextSnapshot,
    event: String,
    message: String
  ) async {
    guard let diagnostics else { return }
    guard context.clipboard.changeCount != lastPrivacyDiagnosticChangeCount else { return }
    lastPrivacyDiagnosticChangeCount = context.clipboard.changeCount
    let isPolicyUnavailable = decision.reasons.contains(.privacySettingsUnavailable)
    await diagnostics.record(
      DiagnosticEvent(
        subsystem: .systemClipboard,
        level: isPolicyUnavailable ? .warning : .info,
        event: isPolicyUnavailable ? "clipboard.capture.policy-unavailable" : event,
        message: isPolicyUnavailable
          ? "Clipboard privacy settings could not be loaded; capture was blocked."
          : message,
        metadata: [
          "bundleID": context.focus.bundleIdentifier ?? "",
          "decisions": decision.decisions.map(\.rawValue).joined(separator: ","),
          "reasons": decision.reasons.map(\.rawValue).joined(separator: ","),
          "protections": context.clipboard.protections.map(\.rawValue).joined(separator: ","),
          "error": isPolicyUnavailable ? decision.metadata["privacy.policy.error"] ?? "" : "",
        ]
      )
    )
  }

  fileprivate func handleHotkey(_ event: HotkeyEventTap.Event) async {
    switch event {
    case .recordBufferOutputRequested:
      guard !stopped else { return }
      await eventBus.publish(.recordBufferOutputRequested)
    case .recordPanelRequested:
      guard !stopped else { return }
      await eventBus.publish(.recordPanelRequested)
    case .globalInputUnavailable, .pushToTalkPressed, .pushToTalkReleased,
      .liveAudioCancellationRequested, .customHotkey:
      break
    }
  }

}

extension SystemClipboardCaptureController {
  func testingCaptureExternalClipboardIfNeeded() async {
    await captureExternalClipboardIfNeeded()
    await clipboardPersistenceTask?.value
  }

  func testingPollExternalClipboardIfNeeded(
    at now: ContinuousClock.Instant = .now,
    waitForPersistence: Bool = true
  ) async {
    await pollExternalClipboardIfNeeded(at: now)
    if waitForPersistence { await clipboardPersistenceTask?.value }
  }

  func testingStopExternalClipboardMonitor() async {
    await stopExternalClipboardMonitor()
  }

  func testingHandleHotkey(_ event: HotkeyEventTap.Event) async {
    await handleHotkey(event)
  }

  func testingCaptureControlSnapshot() -> SystemClipboardCaptureControlSnapshot {
    captureControlSnapshot
  }
}
