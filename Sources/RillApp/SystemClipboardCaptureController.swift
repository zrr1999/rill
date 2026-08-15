import AppKit
import ApplicationServices
import Foundation
import RillCore
import RillPlatform
import RillRuntime

@MainActor
protocol SystemClipboardAccess: Sendable {
  func currentClipboardDescriptor() async -> SystemClipboardDescriptor
  func readClipboardSnapshot(ifChangeCountIs expected: Int) async -> SystemClipboardSnapshot?
  func beginTemporaryClipboardWrite(
    _ snapshot: SystemClipboardSnapshot,
    ifChangeCountIs expected: Int
  ) async throws -> SystemClipboardPort.TemporaryWriteTransaction
  func writeClipboardSnapshot(
    _ snapshot: SystemClipboardSnapshot,
    ifChangeCountIs expected: Int
  ) async -> Int?
  func restoreTemporaryClipboardWrite(
    _ transaction: SystemClipboardPort.TemporaryWriteTransaction,
    ifChangeCountIs expected: Int
  ) async -> SystemClipboardPort.TemporaryRestoreOutcome
  func ownsClipboardChangeCount(_ changeCount: Int) async -> Bool
}

extension SystemClipboardPort: SystemClipboardAccess {
  func currentClipboardDescriptor() async -> SystemClipboardDescriptor {
    currentDescriptor()
  }

  func readClipboardSnapshot(ifChangeCountIs expected: Int) async -> SystemClipboardSnapshot? {
    await readSnapshot(ifChangeCountIs: expected)
  }

  func beginTemporaryClipboardWrite(
    _ snapshot: SystemClipboardSnapshot,
    ifChangeCountIs expected: Int
  ) async throws -> TemporaryWriteTransaction {
    try beginTemporaryWrite(snapshot, ifChangeCountIs: expected)
  }

  func writeClipboardSnapshot(
    _ snapshot: SystemClipboardSnapshot,
    ifChangeCountIs expected: Int
  ) async -> Int? {
    writeSnapshot(snapshot, ifChangeCountIs: expected)
  }

  func restoreTemporaryClipboardWrite(
    _ transaction: TemporaryWriteTransaction,
    ifChangeCountIs expected: Int
  ) async -> TemporaryRestoreOutcome {
    restore(transaction, ifChangeCountIs: expected)
  }

  func ownsClipboardChangeCount(_ changeCount: Int) async -> Bool {
    isOwnedChangeCount(changeCount)
  }
}

public actor SystemClipboardCaptureController {
  private struct MirroredClipboardPreview: Equatable {
    var snapshot: SystemClipboardSnapshot
    var subject: RecordDeliverySubject
  }

  private struct CaptureOperation: Sendable, Equatable {
    var id: UInt64
    var controlRevision: UInt64
  }

  private struct PendingMirrorTransaction: Sendable, Equatable {
    var id: UInt64
    var controlRevision: UInt64
    var preservedClipboard: SystemClipboardSnapshot
    var preview: MirroredClipboardPreview
  }

  private struct InitialClipboardPrivacyEvaluation: Sendable {
    var context: ContextSnapshot
    var decision: PrivacyPolicyDecision

    var allowsClipboardCapture: Bool {
      decision.allowsClipboardCapture
    }
  }

  private struct MirrorPrivacyAuthorization: Sendable {
    var descriptor: SystemClipboardDescriptor
    var focusSample: FocusPrivacyIdentitySample
    var decision: PrivacyPolicyDecision
    var controlRevision: UInt64
  }

  private struct RichPastePrivacyAuthorization: Sendable {
    var descriptor: SystemClipboardDescriptor
    var focusSample: FocusPrivacyIdentitySample
    var decision: PrivacyPolicyDecision
    var mirroredChangeCount: Int
  }

  private enum RichPasteError: Error, LocalizedError {
    case privacyBoundaryChanged

    var errorDescription: String? {
      "Rich clipboard paste was blocked because the target privacy boundary changed."
    }
  }

  private static let monitorInterval = Duration.milliseconds(750)
  private static let maxMirroredPlainTextLength = 32_000

  private let hotkeyTap: HotkeyEventTap
  private let pasteboard: any SystemClipboardAccess
  private let recordStore: RecordStore
  private let focusedApplicationDelivery: FocusedApplicationDeliveryController
  private let eventBus: EventBus
  private let diagnostics: DiagnosticsRecorder?
  private let privacySettingsProvider: @Sendable () async throws -> PrivacyPolicySettings
  private let focusIdentitySampleProvider: @Sendable () async -> FocusPrivacyIdentitySample
  private let activeRouteContextProvider: (@Sendable () async -> RecordRouteContext)?
  private let captureControlStateObserver: @Sendable (SystemClipboardCaptureControlSnapshot) async -> Void
  private let accessibilityChecker: @Sendable () -> Bool
  private let pasteCommandSender: @Sendable () async -> Bool

  private var started = false
  private var stopped = false
  private var stopCompleted = false
  private var stopWaiters: [CheckedContinuation<Void, Never>] = []
  private var hotkeyEventsTask: Task<Void, Never>?
  private var routeRefreshMonitorTask: Task<Void, Never>?
  private var externalClipboardMonitorTask: Task<Void, Never>?
  private var preservedClipboard: SystemClipboardSnapshot?
  private var preservedClipboardTransaction: SystemClipboardPort.TemporaryWriteTransaction?
  private var ownedChangeCount: Int?
  private var mirroredPreview: MirroredClipboardPreview?
  private var latestRouteSnapshot = RecordRouteProjection()
  private var latestRouteContext: RecordRouteContext?
  private var isDeliveryInProgress = false
  private var deliveryOperationWaiters: [CheckedContinuation<Void, Never>] = []
  private var activeProgrammaticPasteSessionIDs: Set<UInt64> = []
  private var inFlightProgrammaticPasteOperationIDs: Set<UInt64> = []
  private var programmaticPasteOperationWaiters: [CheckedContinuation<Void, Never>] = []
  private var privacyPasteBypassActive = false
  private var richPasteLeaseInProgress = false
  // This pre-start state is not capture authority: no clipboard monitor or
  // interception begins until start() merges an explicit preference. The
  // fail-closed desired value below remains the source of truth.
  private var captureControlSnapshot = SystemClipboardCaptureControlSnapshot.initial
  private var desiredClipboardCaptureEnabled = false
  private var hasUnversionedClipboardCaptureRequest = false
  private var latestClipboardCapturePreferenceRevision: UInt64?
  private var nextOperationID: UInt64 = 0
  private var inFlightCaptureOperationIDs: Set<UInt64> = []
  private var captureOperationWaiters: [CheckedContinuation<Void, Never>] = []
  private var pendingMirrorTransaction: PendingMirrorTransaction?
  private var mirrorTransactionWaiters: [CheckedContinuation<Void, Never>] = []
  private var lastObservedPasteboardChangeCount: Int?
  private var lastObservedFocusIdentitySample: FocusPrivacyIdentitySample?
  private var lastPrivacyDiagnosticChangeCount: Int?

  public init(
    hotkeyTap: HotkeyEventTap,
    pasteboard: SystemClipboardPort,
    contextProvider: any ContextProvider,
    recordStore: RecordStore,
    recordDeliveryCoordinator: RecordDeliveryCoordinator? = nil,
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
    accessibilityChecker: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
    pasteCommandSender: @escaping @Sendable () async -> Bool = {
      await PasteCommandSender.sendWithEventSpacing()
    }
  ) {
    self.init(
      hotkeyTap: hotkeyTap,
      pasteboard: pasteboard as any SystemClipboardAccess,
      contextProvider: contextProvider,
      recordStore: recordStore,
      recordDeliveryCoordinator: recordDeliveryCoordinator,
      sessionCoordinator: sessionCoordinator,
      eventBus: eventBus,
      diagnostics: diagnostics,
      privacySettingsProvider: privacySettingsProvider,
      focusSnapshotProvider: focusSnapshotProvider,
      focusIdentitySampleProvider: focusIdentitySampleProvider,
      captureControlStateObserver: captureControlStateObserver,
      accessibilityChecker: accessibilityChecker,
      pasteCommandSender: pasteCommandSender
    )
  }

  init(
    hotkeyTap: HotkeyEventTap,
    pasteboard: any SystemClipboardAccess,
    contextProvider: any ContextProvider,
    recordStore: RecordStore,
    recordDeliveryCoordinator: RecordDeliveryCoordinator? = nil,
    sessionCoordinator: SessionCoordinator,
    eventBus: EventBus,
    diagnostics: DiagnosticsRecorder? = nil,
    privacySettingsProvider: @escaping @Sendable () async throws -> PrivacyPolicySettings = {
      throw PrivacyPolicySettingsSourceError.notReady
    },
    focusSnapshotProvider: (@Sendable () async -> FocusSnapshot)? = nil,
    focusIdentitySampleProvider: (@Sendable () async -> FocusPrivacyIdentitySample)? = nil,
    activeRouteContextProvider: (@Sendable () async -> RecordRouteContext)? = nil,
    captureControlStateObserver:
      @escaping @Sendable (SystemClipboardCaptureControlSnapshot) async -> Void = { _ in },
    accessibilityChecker: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
    pasteCommandSender: @escaping @Sendable () async -> Bool = {
      await PasteCommandSender.sendWithEventSpacing()
    }
  ) {
    self.hotkeyTap = hotkeyTap
    self.pasteboard = pasteboard
    self.recordStore = recordStore
    self.focusedApplicationDelivery = FocusedApplicationDeliveryController(
      recordDeliveryCoordinator:
        recordDeliveryCoordinator ?? RecordDeliveryCoordinator(store: recordStore),
      sessionCoordinator: sessionCoordinator
    )
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
    self.activeRouteContextProvider = activeRouteContextProvider
    self.captureControlStateObserver = captureControlStateObserver
    self.accessibilityChecker = accessibilityChecker
    self.pasteCommandSender = pasteCommandSender
  }

  public func stop() async {
    if stopped {
      await waitForStopCompletion()
      return
    }
    stopped = true
    started = false
    privacyPasteBypassActive = true
    _ = transitionCaptureControl(to: .pausing)
    hotkeyTap.setPasteInterceptEnabled(false)

    let tasks = [
      hotkeyEventsTask,
      routeRefreshMonitorTask,
      externalClipboardMonitorTask,
    ].compactMap { $0 }
    hotkeyEventsTask = nil
    routeRefreshMonitorTask = nil
    externalClipboardMonitorTask = nil
    for task in tasks {
      task.cancel()
    }
    for task in tasks {
      await task.value
    }

    await waitForInFlightProgrammaticPasteOperations()
    await waitForDeliveryOperation()
    await waitForInFlightCaptureOperations()
    await waitForPendingMirrorTransaction()
    await drainPreservedClipboardRecoveryForApplicationShutdown()
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
    hotkeyTap.setRecordPanelShortcutEnabled(desiredClipboardCaptureEnabled)
    started = true

    // Register before the application-level GlobalInputOwner installs the
    // producer. AsyncStream buffers events until the listener task starts.
    let hotkeyStream = hotkeyTap.stream()
    hotkeyTap.setPasteInterceptEnabled(false)
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
        applyInitialClipboardPrivacy(initialPrivacy)
        await recordInitialClipboardPrivacyIfNeeded(initialPrivacy)
      }
    }
    hotkeyEventsTask = Task {
      for await event in hotkeyStream {
        await self.handleHotkey(event)
      }
    }

    routeRefreshMonitorTask = Task {
      while !Task.isCancelled {
        await self.refreshActiveRouteSnapshotIfNeeded()
        try? await Task.sleep(for: Self.monitorInterval)
      }
    }
    startExternalClipboardMonitorIfNeeded()

    await refreshActiveRouteSnapshot(forceContextRefresh: true)
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

    privacyPasteBypassActive = true
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
        await self.captureExternalClipboardIfNeeded()
        try? await Task.sleep(for: Self.monitorInterval)
      }
    }
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
    hotkeyTap.setRecordPanelShortcutEnabled(desiredClipboardCaptureEnabled)
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
    privacyPasteBypassActive = true
    updatePasteInterceptState()
    await publishCaptureControlState()
    guard isCurrentControlState(.pausing, revision: transitionRevision) else { return }

    await stopExternalClipboardMonitor()
    guard isCurrentControlState(.pausing, revision: transitionRevision) else { return }
    await waitForInFlightCaptureOperations()
    guard isCurrentControlState(.pausing, revision: transitionRevision) else { return }
    await waitForPendingMirrorTransaction()
    guard isCurrentControlState(.pausing, revision: transitionRevision) else { return }
    await restorePreservedClipboardIfNeeded()
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
    privacyPasteBypassActive = true
    updatePasteInterceptState()
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
    applyInitialClipboardPrivacy(evaluation)
    let activeRevision = transitionCaptureControl(to: .active)
    startExternalClipboardMonitorIfNeeded()
    if started {
      await refreshActiveRouteSnapshot(forceContextRefresh: true)
      guard isCurrentControlState(.active, revision: activeRevision) else { return }
    }
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
    privacyPasteBypassActive = true
    updatePasteInterceptState()
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
    await waitForPendingMirrorTransaction()
    guard isCurrentControlState(.armingIgnoreNextExternalChange, revision: transitionRevision)
    else { return }
    await restorePreservedClipboardIfNeeded()
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
    guard !stopped else { return }
    guard accessibilityChecker() else {
      hotkeyTap.setPasteInterceptEnabled(false)
      await eventBus.publish(
        .runFailed(
          runID: nil,
          workflow: WorkflowPresentation(fallbackName: "Stack Delivery", titleKey: .recordDelivery),
          message: TextInjectionEngine.InjectionError.accessibilityPermissionRequired
            .localizedDescription
        )
      )
      return
    }
    guard !isDeliveryInProgress else { return }
    isDeliveryInProgress = true
    hotkeyTap.setPasteInterceptEnabled(false)
    defer {
      finishDeliveryOperation()
    }

    let routeContext = await currentRouteContext()
    latestRouteContext = routeContext
    let routeSnapshot = await recordRouteProjection(for: routeContext)

    switch routeSnapshot.previewContentKind {
    case .image?, .files?:
      await handleRouteSnapshot(routeSnapshot, routeContext: routeContext)
      await pasteMirroredClipboardItem(for: routeContext)
    case .text?:
      await focusedApplicationDelivery.deliverNext(
        to: focusedApplicationIdentity(routeContext)
      )
    case nil:
      break
    }
    await refreshActiveRouteSnapshot(forceContextRefresh: true)
  }

  public func deliverSelectedRecord(
    _ subject: RecordDeliverySubject,
    to target: FocusedApplicationTargetIdentity
  ) async {
    guard !stopped else { return }
    guard accessibilityChecker() else {
      hotkeyTap.setPasteInterceptEnabled(false)
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
    hotkeyTap.setPasteInterceptEnabled(false)
    defer {
      finishDeliveryOperation()
    }

    let didBeginDelivery = await performProgrammaticPaste {
      await self.focusedApplicationDelivery.deliver(subject, to: target)
    }
    if !didBeginDelivery {
      await publishSelectedRecordDeliveryFailure(
        message: HistoryFailureSanitizer.genericMessage
      )
    }
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

  @discardableResult
  public func performProgrammaticPaste(
    _ operation: @Sendable () async -> Void
  ) async -> Bool {
    guard let operationID = beginProgrammaticPasteOperation() else { return false }
    defer {
      finishProgrammaticPasteOperation(operationID)
    }

    var shouldRefreshRoute = false
    var didPerformOperation = false
    do {
      defer {
        shouldRefreshRoute = finishProgrammaticPasteSession(operationID)
      }
      await waitForPendingMirrorTransaction()
      let restoreOutcome = await restorePreservedClipboardIfNeeded()
      if case .writeFailed? = restoreOutcome {
        didPerformOperation = false
      } else {
        await operation()
        didPerformOperation = true
      }
    }
    if shouldRefreshRoute {
      await refreshActiveRouteSnapshot(forceContextRefresh: true)
    }
    return didPerformOperation
  }

  private func refreshActiveRouteSnapshot(forceContextRefresh: Bool = false) async {
    guard !isPreviewMirroringSuspended else {
      updatePasteInterceptState()
      return
    }
    let routeContext: RecordRouteContext
    if !forceContextRefresh, let latestRouteContext {
      routeContext = latestRouteContext
    } else {
      routeContext = await currentRouteContext()
    }
    await refreshActiveRouteSnapshot(using: routeContext)
  }

  private func refreshActiveRouteSnapshotIfNeeded() async {
    guard !isPreviewMirroringSuspended else {
      updatePasteInterceptState()
      return
    }
    let routeContext = await currentRouteContext()
    guard routeContext != latestRouteContext else {
      updatePasteInterceptState()
      return
    }
    await refreshActiveRouteSnapshot(using: routeContext)
  }

  private func refreshActiveRouteSnapshot(using routeContext: RecordRouteContext) async {
    let snapshot = await recordRouteProjection(for: routeContext)
    await handleRouteSnapshot(snapshot, routeContext: routeContext)
  }

  private func recordRouteProjection(
    for routeContext: RecordRouteContext
  ) async -> RecordRouteProjection {
    (try? await recordStore.routeProjection(target: focusedApplicationIdentity(routeContext)))
      ?? RecordRouteProjection()
  }

  private func focusedApplicationIdentity(
    _ routeContext: RecordRouteContext
  ) -> FocusedApplicationIdentity {
    FocusedApplicationIdentity(
      bundleIdentifier: routeContext.bundleIdentifier,
      applicationName: routeContext.applicationName
    )
  }

  private func handleRouteSnapshot(
    _ snapshot: RecordRouteProjection,
    routeContext: RecordRouteContext
  ) async {
    latestRouteContext = routeContext
    latestRouteSnapshot = snapshot
    updatePasteInterceptState()

    guard snapshot.count > 0,
      let previewSnapshot = snapshot.previewSnapshot,
      let previewSubject = snapshot.previewSubject
    else {
      mirroredPreview = nil
      if preservedClipboard != nil || preservedClipboardTransaction != nil || ownedChangeCount != nil {
        await restorePreservedClipboardIfNeeded()
      }
      return
    }

    // Keep route state current, but do not let panel-driven paste overwrite the clipboard mid-injection.
    guard !isPreviewMirroringSuspended else { return }
    guard let privacyAuthorization = await authorizeMirrorPrivacy() else { return }
    guard !isPreviewMirroringSuspended else { return }

    let preview = MirroredClipboardPreview(
      snapshot: previewSnapshot,
      subject: previewSubject
    )
    if preservedClipboard == nil {
      guard
        let preservedSnapshot = await pasteboard.readClipboardSnapshot(
          ifChangeCountIs: privacyAuthorization.descriptor.changeCount
        )
      else {
        await failClosedMirrorPrivacyAuthorization()
        return
      }
      guard !isPreviewMirroringSuspended,
        await validateMirrorPrivacyAuthorization(
          privacyAuthorization,
          verifyClipboardDescriptor: true
        )
      else {
        await failClosedMirrorPrivacyAuthorization()
        return
      }
      preservedClipboard = preservedSnapshot
    }

    guard !isPreviewMirroringSuspended,
      await validateMirrorPrivacyAuthorization(
        privacyAuthorization,
        verifyClipboardDescriptor: true
      )
    else {
      await failClosedMirrorPrivacyAuthorization()
      return
    }
    if let preservedClipboard,
      previewSnapshot.hasEquivalentTransferableContent(as: preservedClipboard)
    {
      if ownedChangeCount != nil {
        await restorePreservedClipboardIfNeeded()
      } else {
        lastObservedPasteboardChangeCount = preservedClipboard.changeCount
      }
      mirroredPreview = preview
      return
    }

    guard mirroredPreview != preview else { return }
    guard shouldMirrorPreviewSnapshot(previewSnapshot) else {
      if ownedChangeCount != nil {
        await restorePreservedClipboardIfNeeded()
      }
      return
    }

    guard let preservedClipboard else { return }
    nextOperationID &+= 1
    let transaction = PendingMirrorTransaction(
      id: nextOperationID,
      controlRevision: captureControlSnapshot.revision,
      preservedClipboard: preservedClipboard,
      preview: preview
    )
    pendingMirrorTransaction = transaction
    updatePasteInterceptState()

    let restoreTransaction: SystemClipboardPort.TemporaryWriteTransaction
    let mirroredChangeCount: Int
    if let preservedClipboardTransaction {
      guard
        let updatedChangeCount = await pasteboard.writeClipboardSnapshot(
          previewSnapshot,
          ifChangeCountIs: privacyAuthorization.descriptor.changeCount
        )
      else {
        self.preservedClipboard = nil
        self.preservedClipboardTransaction = nil
        ownedChangeCount = nil
        mirroredPreview = nil
        activatePrivacyPasteBypass()
        finishPendingMirrorTransaction(transaction.id)
        await recordPendingMirrorSettlement(outcome: .skippedChangeCount)
        return
      }
      restoreTransaction = preservedClipboardTransaction
      mirroredChangeCount = updatedChangeCount
    } else {
      do {
        let temporaryTransaction = try await pasteboard.beginTemporaryClipboardWrite(
          previewSnapshot,
          ifChangeCountIs: privacyAuthorization.descriptor.changeCount
        )
        restoreTransaction = temporaryTransaction
        mirroredChangeCount = temporaryTransaction.temporaryChangeCount
      } catch {
        // Capturing every pasteboard representation and the replacement write
        // are one conditional operation. If either fails, leave the user's
        // clipboard untouched and abandon this preview generation.
        self.preservedClipboard = nil
        self.preservedClipboardTransaction = nil
        ownedChangeCount = nil
        mirroredPreview = nil
        activatePrivacyPasteBypass()
        finishPendingMirrorTransaction(transaction.id)
        await recordPendingMirrorSettlement(outcome: .skippedChangeCount)
        return
      }
    }

    guard pendingMirrorTransaction?.id == transaction.id else {
      let outcome = await restoreTemporaryClipboardWithRetry(
        restoreTransaction,
        expectedChangeCount: mirroredChangeCount
      )
      settleStandaloneTemporaryClipboardRestore(
        outcome,
        transaction: restoreTransaction,
        preservedClipboard: transaction.preservedClipboard
      )
      finishPendingMirrorTransaction(transaction.id)
      await recordPendingMirrorSettlement(outcome: outcome)
      return
    }

    if await pasteboard.currentClipboardDescriptor().changeCount != mirroredChangeCount {
      // The pasteboard changed after authorization. Do not restore the
      // stale preserved payload over the external writer; the next poll
      // will evaluate and capture the new value from scratch.
      self.preservedClipboard = nil
      self.preservedClipboardTransaction = nil
      ownedChangeCount = nil
      mirroredPreview = nil
      activatePrivacyPasteBypass()
      finishPendingMirrorTransaction(transaction.id)
      await recordPendingMirrorSettlement(outcome: .skippedChangeCount)
      return
    }
    lastObservedPasteboardChangeCount = mirroredChangeCount
    let descriptorAfterWrite = await pasteboard.currentClipboardDescriptor()
    let focusAfterWrite = await focusIdentitySampleProvider()
    let policyAfterWrite = await capturePrivacyDecision(
      for: ContextSnapshot(
        focus: focusAfterWrite.focus,
        clipboard: privacyAuthorization.descriptor.policySnapshot
      )
    )
    let descriptorAfterPolicy = await pasteboard.currentClipboardDescriptor()
    let focusAfterPolicy = await focusIdentitySampleProvider()
    let stillOwnsCurrentClipboard =
      descriptorAfterWrite.changeCount == mirroredChangeCount
      && descriptorAfterPolicy.changeCount == mirroredChangeCount
    let privacyIsCurrent =
      focusAfterWrite.hasSamePrivacyIdentity(
        as: privacyAuthorization.focusSample
      )
      && focusAfterPolicy.hasSamePrivacyIdentity(as: focusAfterWrite)
      && policyAfterWrite == privacyAuthorization.decision
      && policyAfterWrite.allowsClipboardCapture
    if !privacyIsCurrent {
      lastObservedFocusIdentitySample = focusAfterPolicy
      activatePrivacyPasteBypass()
    }
    let shouldCommit =
      pendingMirrorTransaction?.id == transaction.id
      && stillOwnsCurrentClipboard
      && isCurrentControlState(.active, revision: transaction.controlRevision)
      && transaction.controlRevision == privacyAuthorization.controlRevision
      && privacyIsCurrent
      && activeProgrammaticPasteSessionIDs.isEmpty
      && !privacyPasteBypassActive
      && latestRouteSnapshot.count > 0
      && latestRouteSnapshot.previewSnapshot == transaction.preview.snapshot
      && latestRouteSnapshot.previewSubject == transaction.preview.subject

    guard shouldCommit else {
      finishPendingMirrorTransaction(transaction.id)
      var restoreOutcome = SystemClipboardPort.TemporaryRestoreOutcome.skippedChangeCount
      if stillOwnsCurrentClipboard {
        restoreOutcome = await restoreTemporaryClipboardWithRetry(
          restoreTransaction,
          expectedChangeCount: mirroredChangeCount
        )
        settleStandaloneTemporaryClipboardRestore(
          restoreOutcome,
          transaction: restoreTransaction,
          preservedClipboard: transaction.preservedClipboard
        )
      }
      if self.preservedClipboard == transaction.preservedClipboard, ownedChangeCount == nil {
        self.preservedClipboard = nil
        self.preservedClipboardTransaction = nil
      }
      mirroredPreview = nil
      await recordPendingMirrorSettlement(outcome: restoreOutcome)
      return
    }

    ownedChangeCount = mirroredChangeCount
    self.preservedClipboard = transaction.preservedClipboard
    preservedClipboardTransaction = restoreTransaction
    mirroredPreview = preview
    lastObservedFocusIdentitySample = focusAfterPolicy
    finishPendingMirrorTransaction(transaction.id)

    if let diagnostics {
      await diagnostics.record(
        DiagnosticEvent(
          subsystem: .systemClipboard,
          level: .debug,
          event: "clipboard.preview.mirrored",
          message: "Mirrored the active clipboard item to the system clipboard.",
          metadata: [
            "count": String(snapshot.count),
          ]
        )
      )
    }
  }

  private func pasteMirroredClipboardItem(for routeContext: RecordRouteContext) async {
    let recordDeliveryWorkflow = WorkflowPresentation(
      fallbackName: "Record Delivery", titleKey: .recordDelivery)
    guard let authorization = await authorizeRichPastePrivacy(for: routeContext) else {
      await rejectRichPaste(
        leaseID: nil,
        workflow: recordDeliveryWorkflow,
        error: RichPasteError.privacyBoundaryChanged
      )
      return
    }

    richPasteLeaseInProgress = true
    updatePasteInterceptState()
    defer {
      richPasteLeaseInProgress = false
      updatePasteInterceptState()
    }
    guard let subject = mirroredPreview?.subject else {
      await rejectRichPaste(
        leaseID: nil,
        workflow: recordDeliveryWorkflow,
        error: RecordStoreError.membershipUnavailable
      )
      return
    }
    let lease: RecordDeliveryLease
    do {
      lease = try await focusedApplicationDelivery.beginRichDelivery(matching: subject)
    } catch {
      await rejectRichPaste(
        leaseID: nil,
        workflow: recordDeliveryWorkflow,
        error: error
      )
      return
    }

    do {
      guard await validateRichPastePrivacy(authorization) else {
        await rejectRichPaste(
          leaseID: lease.id,
          workflow: recordDeliveryWorkflow,
          error: RichPasteError.privacyBoundaryChanged
        )
        return
      }
      try await simulatePaste()
      // Once the OS event sender reports success, the output cannot be
      // recalled. Treat it as committed so a later focus transition or
      // cancellation cannot leave the item queued for duplicate output.
      try? await Task.sleep(for: .milliseconds(120))
      try await focusedApplicationDelivery.completeRichDelivery(lease.id)
    } catch {
      await focusedApplicationDelivery.failRichDelivery(lease.id)
      await activatePrivacyPasteBypassRestoringClipboard()
      await eventBus.publish(
        .runFailed(
          runID: nil,
          workflow: recordDeliveryWorkflow,
          message: HistoryFailureSanitizer.genericMessage
        )
      )
    }
  }

  private func authorizeRichPastePrivacy(
    for routeContext: RecordRouteContext
  ) async -> RichPastePrivacyAuthorization? {
    guard let mirroredChangeCount = ownedChangeCount,
      mirroredPreview != nil,
      !privacyPasteBypassActive,
      captureControlSnapshot.state == .active
    else { return nil }

    let descriptor = await pasteboard.currentClipboardDescriptor()
    guard descriptor.changeCount == mirroredChangeCount,
      descriptor.protections.isEmpty,
      await pasteboard.ownsClipboardChangeCount(mirroredChangeCount)
    else { return nil }
    let focusSample = await focusIdentitySampleProvider()
    guard focusSample.hasVerifiablePrivacyIdentity,
      routeContext.matchesPrivacyIdentity(focusSample.focus)
    else { return nil }
    let decision = await capturePrivacyDecision(
      for: ContextSnapshot(
        focus: focusSample.focus,
        clipboard: descriptor.policySnapshot
      )
    )
    let descriptorAfterPolicy = await pasteboard.currentClipboardDescriptor()
    let focusAfterPolicy = await focusIdentitySampleProvider()
    guard descriptorAfterPolicy == descriptor,
      focusAfterPolicy.hasSamePrivacyIdentity(as: focusSample),
      decision.allowsClipboardCapture
    else { return nil }

    return RichPastePrivacyAuthorization(
      descriptor: descriptor,
      focusSample: focusSample,
      decision: decision,
      mirroredChangeCount: mirroredChangeCount
    )
  }

  private func validateRichPastePrivacy(
    _ authorization: RichPastePrivacyAuthorization
  ) async -> Bool {
    guard !privacyPasteBypassActive,
      captureControlSnapshot.state == .active,
      ownedChangeCount == authorization.mirroredChangeCount
    else { return false }
    let descriptor = await pasteboard.currentClipboardDescriptor()
    guard descriptor == authorization.descriptor,
      await pasteboard.ownsClipboardChangeCount(authorization.mirroredChangeCount)
    else { return false }
    let focusSample = await focusIdentitySampleProvider()
    guard focusSample.hasSamePrivacyIdentity(as: authorization.focusSample) else { return false }
    let decision = await capturePrivacyDecision(
      for: ContextSnapshot(
        focus: focusSample.focus,
        clipboard: descriptor.policySnapshot
      )
    )
    let descriptorAfterPolicy = await pasteboard.currentClipboardDescriptor()
    let focusAfterPolicy = await focusIdentitySampleProvider()
    return descriptorAfterPolicy == authorization.descriptor
      && focusAfterPolicy.hasSamePrivacyIdentity(as: focusSample)
      && decision == authorization.decision
      && decision.allowsClipboardCapture
  }

  private func rejectRichPaste(
    leaseID: UUID?,
    workflow: WorkflowPresentation,
    error: Error
  ) async {
    if let leaseID {
      await focusedApplicationDelivery.failRichDelivery(leaseID)
    }
    await activatePrivacyPasteBypassRestoringClipboard()
    await eventBus.publish(
      .runFailed(
        runID: nil,
        workflow: workflow,
        message: HistoryFailureSanitizer.genericMessage
      )
    )
  }

}

extension SystemClipboardCaptureController {
  private func authorizeMirrorPrivacy() async -> MirrorPrivacyAuthorization? {
    guard captureControlSnapshot.state == .active,
      activeProgrammaticPasteSessionIDs.isEmpty,
      pendingMirrorTransaction == nil
    else { return nil }

    let controlRevision = captureControlSnapshot.revision
    let descriptor = await pasteboard.currentClipboardDescriptor()
    guard isCurrentControlState(.active, revision: controlRevision) else { return nil }
    let focusSample = await focusIdentitySampleProvider()
    guard isCurrentControlState(.active, revision: controlRevision) else { return nil }
    let context = ContextSnapshot(
      focus: focusSample.focus,
      clipboard: descriptor.policySnapshot
    )
    let decision = await capturePrivacyDecision(for: context)
    guard isCurrentControlState(.active, revision: controlRevision) else { return nil }

    guard decision.allowsClipboardCapture else {
      lastObservedPasteboardChangeCount = descriptor.changeCount
      lastObservedFocusIdentitySample = focusSample
      await failClosedMirrorPrivacyAuthorization()
      await recordCaptureDecision(
        decision,
        context: context,
        event: "clipboard.preview.mirroring-skipped",
        message: "Skipped clipboard preview mirroring because of the active privacy policy."
      )
      return nil
    }

    let authorization = MirrorPrivacyAuthorization(
      descriptor: descriptor,
      focusSample: focusSample,
      decision: decision,
      controlRevision: controlRevision
    )
    guard
      await validateMirrorPrivacyAuthorization(
        authorization,
        verifyClipboardDescriptor: true
      )
    else {
      await failClosedMirrorPrivacyAuthorization()
      return nil
    }
    deactivatePrivacyPasteBypass()
    return authorization
  }

  private func validateMirrorPrivacyAuthorization(
    _ authorization: MirrorPrivacyAuthorization,
    verifyClipboardDescriptor: Bool
  ) async -> Bool {
    guard isCurrentControlState(.active, revision: authorization.controlRevision),
      activeProgrammaticPasteSessionIDs.isEmpty,
      pendingMirrorTransaction == nil
    else {
      activatePrivacyPasteBypass()
      return false
    }

    let descriptor = await pasteboard.currentClipboardDescriptor()
    guard isCurrentControlState(.active, revision: authorization.controlRevision) else {
      activatePrivacyPasteBypass()
      return false
    }
    let focusSample = await focusIdentitySampleProvider()
    guard isCurrentControlState(.active, revision: authorization.controlRevision) else {
      activatePrivacyPasteBypass()
      return false
    }
    let context = ContextSnapshot(
      focus: focusSample.focus,
      clipboard: authorization.descriptor.policySnapshot
    )
    let decision = await capturePrivacyDecision(for: context)
    guard isCurrentControlState(.active, revision: authorization.controlRevision) else {
      activatePrivacyPasteBypass()
      return false
    }
    let descriptorAfterPolicy = await pasteboard.currentClipboardDescriptor()
    guard isCurrentControlState(.active, revision: authorization.controlRevision) else {
      activatePrivacyPasteBypass()
      return false
    }
    let focusAfterPolicy = await focusIdentitySampleProvider()
    guard isCurrentControlState(.active, revision: authorization.controlRevision) else {
      activatePrivacyPasteBypass()
      return false
    }

    let descriptorIsCurrent =
      !verifyClipboardDescriptor
      || (descriptor == authorization.descriptor
        && descriptorAfterPolicy == authorization.descriptor)
    let focusIsCurrent =
      focusSample.hasSamePrivacyIdentity(as: authorization.focusSample)
      && focusAfterPolicy.hasSamePrivacyIdentity(as: focusSample)
    let policyIsCurrent = decision == authorization.decision && decision.allowsClipboardCapture
    guard descriptorIsCurrent, focusIsCurrent, policyIsCurrent else {
      lastObservedFocusIdentitySample = focusAfterPolicy
      activatePrivacyPasteBypass()
      if !decision.allowsClipboardCapture {
        if verifyClipboardDescriptor {
          lastObservedPasteboardChangeCount = descriptorAfterPolicy.changeCount
        }
        await recordCaptureDecision(
          decision,
          context: context,
          event: "clipboard.preview.mirroring-skipped",
          message: "Skipped clipboard preview mirroring because the privacy boundary changed."
        )
      } else if !focusIsCurrent {
        await recordFocusTransitionCaptureSkip(focus: focusSample.focus)
      }
      return false
    }
    return true
  }

  fileprivate func failClosedMirrorPrivacyAuthorization() async {
    activatePrivacyPasteBypass()
    await restorePreservedClipboardIfNeeded()
  }

  fileprivate func captureExternalClipboardIfNeeded() async {
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
      await activatePrivacyPasteBypassRestoringClipboard()
      if !focusAfterPolicy.hasSamePrivacyIdentity(as: focusSample) {
        await recordFocusTransitionCaptureSkip(focus: focusAfterPolicy.focus)
      } else {
        await recordClipboardReadRace(context: evaluation.context)
      }
      return
    }

    let crossedPrivacyIdentity =
      lastObservedFocusIdentitySample.map {
        !focusSample.hasSamePrivacyIdentity(as: $0)
      } ?? false

    guard evaluation.allowsClipboardCapture else {
      lastObservedPasteboardChangeCount = descriptor.changeCount
      lastObservedFocusIdentitySample = focusSample
      await activatePrivacyPasteBypassRestoringClipboard()
      await recordCaptureDecision(
        evaluation.decision,
        context: evaluation.context,
        event: "clipboard.capture.skipped",
        message: "Skipped clipboard capture because of the active privacy policy."
      )
      return
    }

    guard descriptor.changeCount != lastObservedPasteboardChangeCount else {
      lastObservedFocusIdentitySample = focusSample
      if observedControlState == .active {
        deactivatePrivacyPasteBypass()
      }
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
      if captureControlSnapshot.state == .active {
        deactivatePrivacyPasteBypass()
      }
      return
    }
    let isOwnedChangeCount = await pasteboard.ownsClipboardChangeCount(descriptor.changeCount)
    guard captureControlSnapshot.revision == observedControlRevision,
      captureControlSnapshot.state == observedControlState
    else { return }
    guard descriptor.changeCount != lastObservedPasteboardChangeCount else { return }
    lastObservedPasteboardChangeCount = descriptor.changeCount
    lastObservedFocusIdentitySample = focusSample
    guard !isOwnedChangeCount else {
      if captureControlSnapshot.state == .active {
        deactivatePrivacyPasteBypass()
      }
      return
    }

    switch captureControlSnapshot.state {
    case .ignoringNextExternalChange:
      privacyPasteBypassActive = true
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
      await activatePrivacyPasteBypassRestoringClipboard()
      await recordFocusTransitionCaptureSkip(focus: focusSample.focus)
      return
    }

    let routeContext = RecordRouteContext(
      applicationName: focusSample.focus.applicationName,
      bundleIdentifier: focusSample.focus.bundleIdentifier
    )
    latestRouteContext = routeContext
    let captureRevision = captureControlSnapshot.revision
    let captureOperation = beginCaptureOperation(controlRevision: captureRevision)
    defer { finishCaptureOperation(captureOperation.id) }

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
      await activatePrivacyPasteBypassRestoringClipboard()
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
      activatePrivacyPasteBypass()
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
      await activatePrivacyPasteBypassRestoringClipboard()
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

    deactivatePrivacyPasteBypass()
    preservedClipboard = snapshot
    preservedClipboardTransaction = nil
    guard isCaptureOperationCurrent(captureOperation) else {
      preservedClipboard = nil
      preservedClipboardTransaction = nil
      return
    }
    _ = try? await recordStore.captureSystemClipboard(
      snapshot: snapshot,
      sourceApplication: focusedApplicationIdentity(routeContext),
      allowsWorkflowCapture: evaluation.decision.allowsWorkflowCapture
    )
    if !evaluation.decision.allowsWorkflowCapture {
      await recordCaptureDecision(
        evaluation.decision,
        context: evaluation.context,
        event: "clipboard.capture.workflow-skipped",
        message: "Saved clipboard history without emitting a workflow event."
      )
    }
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

  private func applyInitialClipboardPrivacy(_ evaluation: InitialClipboardPrivacyEvaluation) {
    if evaluation.allowsClipboardCapture {
      deactivatePrivacyPasteBypass()
    } else {
      activatePrivacyPasteBypass()
    }
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

  fileprivate func activatePrivacyPasteBypass() {
    privacyPasteBypassActive = true
    updatePasteInterceptState()
  }

  fileprivate func activatePrivacyPasteBypassRestoringClipboard() async {
    activatePrivacyPasteBypass()
    await waitForPendingMirrorTransaction()
    await restorePreservedClipboardIfNeeded()
  }

  fileprivate func deactivatePrivacyPasteBypass() {
    guard privacyPasteBypassActive else { return }
    privacyPasteBypassActive = false
    updatePasteInterceptState()
  }

  fileprivate func publishCaptureControlState() async {
    let snapshot = captureControlSnapshot
    await captureControlStateObserver(snapshot)
  }

  @discardableResult
  fileprivate func transitionCaptureControl(to state: SystemClipboardCaptureControlState) -> UInt64 {
    captureControlSnapshot.revision &+= 1
    captureControlSnapshot.state = state
    updatePasteInterceptState()
    return captureControlSnapshot.revision
  }

  fileprivate func isCurrentControlState(
    _ state: SystemClipboardCaptureControlState,
    revision: UInt64
  ) -> Bool {
    captureControlSnapshot.revision == revision && captureControlSnapshot.state == state
  }

  private func beginProgrammaticPasteOperation() -> UInt64? {
    guard !stopped else { return nil }
    nextOperationID &+= 1
    let operationID = nextOperationID
    activeProgrammaticPasteSessionIDs.insert(operationID)
    inFlightProgrammaticPasteOperationIDs.insert(operationID)
    updatePasteInterceptState()
    return operationID
  }

  @discardableResult
  private func finishProgrammaticPasteSession(_ operationID: UInt64) -> Bool {
    guard activeProgrammaticPasteSessionIDs.remove(operationID) != nil else { return false }
    guard activeProgrammaticPasteSessionIDs.isEmpty else {
      updatePasteInterceptState()
      return false
    }
    return true
  }

  private func finishProgrammaticPasteOperation(_ operationID: UInt64) {
    let removedActiveSession = activeProgrammaticPasteSessionIDs.remove(operationID) != nil
    guard inFlightProgrammaticPasteOperationIDs.remove(operationID) != nil else { return }
    if removedActiveSession {
      updatePasteInterceptState()
    }
    guard inFlightProgrammaticPasteOperationIDs.isEmpty else { return }
    let waiters = programmaticPasteOperationWaiters
    programmaticPasteOperationWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
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
    updatePasteInterceptState()
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

  fileprivate func waitForInFlightProgrammaticPasteOperations() async {
    while !inFlightProgrammaticPasteOperationIDs.isEmpty {
      await withCheckedContinuation { continuation in
        programmaticPasteOperationWaiters.append(continuation)
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

  fileprivate func waitForPendingMirrorTransaction() async {
    while pendingMirrorTransaction != nil {
      await withCheckedContinuation { continuation in
        mirrorTransactionWaiters.append(continuation)
      }
    }
  }

  fileprivate func finishPendingMirrorTransaction(_ transactionID: UInt64) {
    guard pendingMirrorTransaction?.id == transactionID else { return }
    pendingMirrorTransaction = nil
    let waiters = mirrorTransactionWaiters
    mirrorTransactionWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    updatePasteInterceptState()
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

  fileprivate func recordPendingMirrorSettlement(
    outcome: SystemClipboardPort.TemporaryRestoreOutcome
  ) async {
    guard let diagnostics else { return }
    let level: DiagnosticLevel
    let event: String
    let message: String
    switch outcome {
    case .restored:
      level = .info
      event = "clipboard.preview.pending-write-restored"
      message = "Restored the preserved clipboard after a pending preview write was invalidated."
    case .skippedChangeCount:
      level = .debug
      event = "clipboard.preview.pending-write-discarded"
      message = "Discarded an invalidated preview write after external clipboard ownership changed."
    case .writeFailed:
      level = .error
      event = "clipboard.preview.pending-write-recovery-pending"
      message = "Preserved clipboard recovery remains pending after a preview write was invalidated."
    }
    await diagnostics.record(
      DiagnosticEvent(
        subsystem: .systemClipboard,
        level: level,
        event: event,
        message: message
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

  @discardableResult
  fileprivate func restorePreservedClipboardIfNeeded() async
    -> SystemClipboardPort.TemporaryRestoreOutcome?
  {
    await waitForPendingMirrorTransaction()
    guard preservedClipboard != nil,
      let preservedClipboardTransaction,
      let ownedChangeCount
    else {
      self.preservedClipboard = nil
      self.preservedClipboardTransaction = nil
      self.ownedChangeCount = nil
      mirroredPreview = nil
      return nil
    }

    let restoreOutcome = await restoreTemporaryClipboardWithRetry(
      preservedClipboardTransaction,
      expectedChangeCount: ownedChangeCount
    )

    let level: DiagnosticLevel
    let event: String
    let message: String
    switch restoreOutcome {
    case .restored:
      lastObservedPasteboardChangeCount = await pasteboard.currentClipboardDescriptor().changeCount
      level = .info
      event = "clipboard.preview.restored"
      message = "Restored the clipboard after the active clipboard route became empty."
      self.preservedClipboard = nil
      self.preservedClipboardTransaction = nil
      self.ownedChangeCount = nil
    case .skippedChangeCount:
      level = .debug
      event = "clipboard.preview.restore-skipped"
      message = "Skipped restoring the clipboard because it changed outside Rill ownership."
      self.preservedClipboard = nil
      self.preservedClipboardTransaction = nil
      self.ownedChangeCount = nil
    case let .writeFailed(retryChangeCount):
      level = .error
      event = "clipboard.preview.restore-pending"
      message = "Preserved clipboard recovery remains pending and will be retried without repeating paste delivery."
      self.ownedChangeCount = retryChangeCount
    }
    mirroredPreview = nil
    if let diagnostics {
      await diagnostics.record(
        DiagnosticEvent(
          subsystem: .systemClipboard,
          level: level,
          event: event,
          message: message
        )
      )
    }
    return restoreOutcome
  }

  fileprivate func restoreTemporaryClipboardWithRetry(
    _ transaction: SystemClipboardPort.TemporaryWriteTransaction,
    expectedChangeCount: Int
  ) async -> SystemClipboardPort.TemporaryRestoreOutcome {
    let initialOutcome = await pasteboard.restoreTemporaryClipboardWrite(
      transaction,
      ifChangeCountIs: expectedChangeCount
    )
    guard case let .writeFailed(retryChangeCount) = initialOutcome else {
      return initialOutcome
    }
    return await pasteboard.restoreTemporaryClipboardWrite(
      transaction,
      ifChangeCountIs: retryChangeCount
    )
  }

  fileprivate func drainPreservedClipboardRecoveryForApplicationShutdown() async {
    var retryDelay = Duration.milliseconds(25)
    while preservedClipboardTransaction != nil || ownedChangeCount != nil {
      let outcome = await restorePreservedClipboardIfNeeded()
      guard case .writeFailed = outcome else { return }
      try? await Task.sleep(for: retryDelay)
      retryDelay = min(retryDelay * 2, .seconds(1))
    }
  }

  fileprivate func settleStandaloneTemporaryClipboardRestore(
    _ outcome: SystemClipboardPort.TemporaryRestoreOutcome,
    transaction: SystemClipboardPort.TemporaryWriteTransaction,
    preservedClipboard: SystemClipboardSnapshot
  ) {
    switch outcome {
    case let .writeFailed(retryChangeCount):
      self.preservedClipboard = preservedClipboard
      preservedClipboardTransaction = transaction
      ownedChangeCount = retryChangeCount
    case .restored, .skippedChangeCount:
      if preservedClipboardTransaction == transaction {
        self.preservedClipboard = nil
        preservedClipboardTransaction = nil
        ownedChangeCount = nil
      }
    }
    mirroredPreview = nil
  }

  fileprivate func shouldMirrorPreviewSnapshot(_ snapshot: SystemClipboardSnapshot) -> Bool {
    guard snapshot.imagePNGData == nil, snapshot.fileURLs.isEmpty else {
      return true
    }
    return snapshot.plainText.count <= Self.maxMirroredPlainTextLength
  }

  fileprivate func handleHotkey(_ event: HotkeyEventTap.Event) async {
    switch event {
    case .manualPasteInterceptRequested:
      if await shouldBypassPasteInterception() {
        await pasteSystemClipboardWithoutInterception()
      } else {
        await deliverNextRecord()
      }
    case .recordPanelRequested:
      guard desiredClipboardCaptureEnabled else { return }
      await eventBus.publish(.recordPanelRequested)
    case .globalInputUnavailable, .pushToTalkPressed, .pushToTalkReleased,
      .liveAudioCancellationRequested, .customHotkey:
      break
    }
  }

  fileprivate func shouldBypassPasteInterception() async -> Bool {
    guard captureControlSnapshot.state == .active, !privacyPasteBypassActive else {
      return true
    }
    let controlRevision = captureControlSnapshot.revision
    let descriptor = await pasteboard.currentClipboardDescriptor()
    guard isCurrentControlState(.active, revision: controlRevision), !privacyPasteBypassActive
    else {
      return true
    }
    guard descriptor.hasTransferableContent else { return false }
    let focusSample = await focusIdentitySampleProvider()
    guard isCurrentControlState(.active, revision: controlRevision), !privacyPasteBypassActive
    else {
      return true
    }
    let context = ContextSnapshot(
      focus: focusSample.focus,
      clipboard: descriptor.policySnapshot
    )
    let decision = await capturePrivacyDecision(for: context)
    guard isCurrentControlState(.active, revision: controlRevision), !privacyPasteBypassActive
    else {
      return true
    }
    guard !decision.allowsClipboardCapture else { return false }
    await activatePrivacyPasteBypassRestoringClipboard()
    await recordCaptureDecision(
      decision,
      context: context,
      event: "clipboard.paste.interception-bypassed",
      message: "Bypassed stack paste interception for a privacy-protected clipboard."
    )
    return true
  }

  fileprivate func pasteSystemClipboardWithoutInterception() async {
    guard let operationID = beginProgrammaticPasteOperation() else { return }
    defer {
      finishProgrammaticPasteOperation(operationID)
    }

    var shouldRefreshRoute = false
    let didSendPaste: Bool
    do {
      defer {
        shouldRefreshRoute = finishProgrammaticPasteSession(operationID)
      }
      switch captureControlSnapshot.state {
      case .pausing, .armingIgnoreNextExternalChange:
        await waitForInFlightCaptureOperations()
      case .active, .paused, .resuming, .ignoringNextExternalChange:
        break
      }
      await waitForPendingMirrorTransaction()
      await restorePreservedClipboardIfNeeded()
      hotkeyTap.skipNextPasteInterception()
      didSendPaste = await pasteCommandSender()
    }
    if shouldRefreshRoute {
      await refreshActiveRouteSnapshot(forceContextRefresh: true)
    }
    guard didSendPaste else {
      await eventBus.publish(
        .runFailed(
          runID: nil,
          workflow: WorkflowPresentation(fallbackName: "System Paste", titleKey: .recordDelivery),
          message: TextInjectionEngine.InjectionError.unableToCreatePasteEvent.localizedDescription
        )
      )
      return
    }
  }

  fileprivate func currentRouteContext() async -> RecordRouteContext {
    if let activeRouteContextProvider {
      return await activeRouteContextProvider()
    }

    let frontmostApplication = await MainActor.run {
      NSWorkspace.shared.frontmostApplication
    }

    if let frontmostApplication {
      return RecordRouteContext(
        applicationName: frontmostApplication.localizedName,
        bundleIdentifier: frontmostApplication.bundleIdentifier
      )
    }

    let identity = await focusIdentitySampleProvider()
    return RecordRouteContext(
      applicationName: identity.focus.applicationName,
      bundleIdentifier: identity.focus.bundleIdentifier
    )
  }

  fileprivate func simulatePaste() async throws {
    guard await pasteCommandSender() else {
      throw TextInjectionEngine.InjectionError.unableToCreatePasteEvent
    }
  }

  fileprivate func updatePasteInterceptState() {
    hotkeyTap.setPasteInterceptEnabled(
      latestRouteSnapshot.count > 0
        && accessibilityChecker()
        && !isDeliveryInProgress
        && !isPreviewMirroringSuspended
    )
  }

  fileprivate var isPreviewMirroringSuspended: Bool {
    !activeProgrammaticPasteSessionIDs.isEmpty
      || privacyPasteBypassActive
      || richPasteLeaseInProgress
      || captureControlSnapshot.state != .active
      || pendingMirrorTransaction != nil
  }
}

extension SystemClipboardCaptureController {
  func testingHandleRouteSnapshot(
    _ snapshot: RecordRouteProjection,
    routeContext: RecordRouteContext
  ) async {
    await handleRouteSnapshot(snapshot, routeContext: routeContext)
  }

  func testingCaptureExternalClipboardIfNeeded() async {
    await captureExternalClipboardIfNeeded()
  }

  func testingHandleHotkey(_ event: HotkeyEventTap.Event) async {
    await handleHotkey(event)
  }

  func testingPrivacyPasteBypassActive() -> Bool {
    privacyPasteBypassActive
  }

  func testingCaptureControlState() -> (isPaused: Bool, isIgnoringNext: Bool) {
    (
      isPaused: captureControlSnapshot.state.isPaused,
      isIgnoringNext: captureControlSnapshot.state.isIgnoringNextExternalChange
    )
  }

  func testingCaptureControlSnapshot() -> SystemClipboardCaptureControlSnapshot {
    captureControlSnapshot
  }

  func testingMonitorState() -> (routeRefreshActive: Bool, externalCaptureActive: Bool) {
    (
      routeRefreshActive: routeRefreshMonitorTask != nil,
      externalCaptureActive: externalClipboardMonitorTask != nil
    )
  }

  func testingProgrammaticPasteOperationCounts() -> (active: Int, inFlight: Int) {
    (
      active: activeProgrammaticPasteSessionIDs.count,
      inFlight: inFlightProgrammaticPasteOperationIDs.count
    )
  }

  func testingShouldBypassPasteInterception() async -> Bool {
    await shouldBypassPasteInterception()
  }

  func testingPasteMirroredClipboardItem(
    for routeContext: RecordRouteContext
  ) async {
    await pasteMirroredClipboardItem(for: routeContext)
  }
}

private extension RecordRouteProjection {
  var previewContentKind: RecordPayloadKind? {
    switch previewPayload?.kind {
    case .text?: .text
    case .image?: .image
    case .files?: .files
    case nil: nil
    }
  }

  var previewSnapshot: SystemClipboardSnapshot? {
    guard let previewPayload else { return nil }
    let captureTags = previewSubject?.captureTags ?? []
    switch previewPayload {
    case .text(let text):
      return SystemClipboardSnapshot(plainText: text, changeCount: 0, captureTags: captureTags)
    case .image(let data):
      return SystemClipboardSnapshot(
        plainText: "",
        imagePNGData: data,
        changeCount: 0,
        captureTags: captureTags
      )
    case .files(let urls):
      return SystemClipboardSnapshot(
        plainText: "",
        fileURLs: urls,
        changeCount: 0,
        captureTags: captureTags
      )
    }
  }
}

extension RecordRouteContext {
  fileprivate func matchesPrivacyIdentity(_ focus: FocusSnapshot) -> Bool {
    if let bundleIdentifier {
      return focus.bundleIdentifier == bundleIdentifier
    }
    if let applicationName, let focusedApplicationName = focus.applicationName {
      return focusedApplicationName == applicationName
    }
    return true
  }
}
