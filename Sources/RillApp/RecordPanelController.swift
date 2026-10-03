import AppKit
import Observation
import SwiftUI
import RillCore
import RillPlatform
import RillUI

enum RecordPanelModalPolicy {
  /// SwiftUI sheets and alerts presented from the embedded Record workspace
  /// attach to the nonactivating panel. While one is attached, auto-hide is
  /// suppressed and the first Escape press closes the sheet instead of the
  /// panel.
  enum EscapeDestination: Equatable {
    case attachedSheet
    case panel
  }

  static func shouldAutoHide(
    isVisible: Bool,
    hasAttachedSheet: Bool,
    isSuppressed: Bool
  ) -> Bool {
    isVisible && !hasAttachedSheet && !isSuppressed
  }

  static func escapeDestination(hasAttachedSheet: Bool) -> EscapeDestination {
    hasAttachedSheet ? .attachedSheet : .panel
  }

  static func waitForAutoHideDelay(
    _ delay: Duration
  ) async -> Bool {
    do {
      try await Task.sleep(for: delay)
      return !Task.isCancelled
    } catch {
      return false
    }
  }
}

enum RecordPanelDigitShortcutPolicy {
  /// Maps a Command-modified main-keyboard digit press (1...9) to a zero-based
  /// index into the visible record list. The ANSI key codes are not
  /// contiguous — 5 and 6 are swapped and 8 sits at 28 — so the mapping is
  /// explicit rather than a range.
  static func visibleRecordIndex(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Int? {
    let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.intersection([.command, .option, .control, .shift]) == .command else { return nil }
    switch keyCode {
    case 18: return 0
    case 19: return 1
    case 20: return 2
    case 21: return 3
    case 23: return 4
    case 22: return 5
    case 26: return 6
    case 28: return 7
    case 25: return 8
    default: return nil
    }
  }
}

@MainActor
final class RecordPanelPasteTaskOwner {
  private struct Reservation {
    let prepare: @MainActor () async -> Bool
    let action: @MainActor () async -> Void
    let onAbort: (@MainActor @Sendable () async -> Void)?
  }

  private var reservations: [UUID: Reservation] = [:]
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var abortTasks: [UUID: Task<Void, Never>] = [:]
  private var hasBegunShutdown = false

  deinit {
    for task in tasks.values {
      task.cancel()
    }
    for task in abortTasks.values {
      task.cancel()
    }
  }

  @discardableResult
  func reserve(
    prepare: @escaping @MainActor () async -> Bool,
    action: @escaping @MainActor () async -> Void,
    onAbort: (@MainActor @Sendable () async -> Void)?
  ) -> UUID? {
    guard !hasBegunShutdown, reservations.isEmpty, tasks.isEmpty else {
      scheduleAbort(onAbort)
      return nil
    }
    let id = UUID()
    reservations[id] = Reservation(
      prepare: prepare,
      action: action,
      onAbort: onAbort
    )
    return id
  }

  func start(_ id: UUID) {
    guard !hasBegunShutdown, tasks.isEmpty,
      let reservation = reservations.removeValue(forKey: id)
    else {
      abort(id)
      return
    }
    let task = Task { @MainActor [weak self] in
      guard let self else {
        await reservation.onAbort?()
        return
      }
      defer { self.tasks[id] = nil }
      let isPrepared = await reservation.prepare()
      guard !Task.isCancelled,
        !self.hasBegunShutdown,
        isPrepared
      else {
        await reservation.onAbort?()
        return
      }
      await reservation.action()
    }
    tasks[id] = task
  }

  func abort(_ id: UUID) {
    guard let reservation = reservations.removeValue(forKey: id) else { return }
    scheduleAbort(reservation.onAbort)
  }

  func abortReservations() {
    let pending = Array(reservations.values)
    reservations.removeAll()
    for reservation in pending {
      scheduleAbort(reservation.onAbort)
    }
  }

  func reject(_ onAbort: (@MainActor @Sendable () async -> Void)?) {
    scheduleAbort(onAbort)
  }

  private func scheduleAbort(
    _ operation: (@MainActor @Sendable () async -> Void)?
  ) {
    guard let operation else { return }
    let id = UUID()
    let task = Task { @MainActor [weak self] in
      await operation()
      self?.abortTasks[id] = nil
    }
    abortTasks[id] = task
  }

  func shutdown() async {
    if !hasBegunShutdown {
      hasBegunShutdown = true
      abortReservations()
    }
    while !tasks.isEmpty || !abortTasks.isEmpty {
      let runningTasks = Array(tasks.values) + Array(abortTasks.values)
      for task in runningTasks {
        await task.value
      }
    }
  }
}

@MainActor
final class RecordPanelController: NSObject, NSWindowDelegate {
  private struct LockedPasteTarget {
    var identity: FocusedApplicationTargetIdentity
    var application: NSRunningApplication?
  }

  private static let defaultPanelSize = NSSize(width: 820, height: 600)
  fileprivate static let minimumPanelSize = NSSize(width: 620, height: 560)
  private static let autoHideSuppressionInterval: Duration = .milliseconds(200)
  private static let focusRestoreSettleInterval: Duration = .milliseconds(80)

  private var panel: NSPanel?
  let presentation = RecordPanelPresentation()
  private weak var appModel: AppModel?
  private var draftTarget: RecordBufferTextOutput.Target?
  private var draftTextOutput = RecordBufferTextOutput()
  private var editingActivity: (Bool) -> Void = { _ in }
  private var expandedFrame: NSRect?
  private weak var draftsResponder: NSResponder?
  private var focusModeTask: Task<Void, Never>?
  private var lastCollectionPreferences = (voice: false, clipboard: false)
  private var presentCollectionPanel: (() -> Void)?
  private let frameAutosaveName: String?

  func configureDrafts(
    model: AppModel, output: BufferOutputController,
    textOutput: RecordBufferTextOutput = .init(),
    editingActivity: @escaping (Bool) -> Void
  ) {
    appModel = model
    draftTextOutput = textOutput
    self.editingActivity = editingActivity
    model.recordWorkspace.buffers.editor.closeAction = { [weak self] in self?.dismiss() }
    model.recordWorkspace.buffers.editor.sendAction = { [weak self] id in
      guard let self else { return }
      let captured = self.draftTarget
      self.panel?.makeFirstResponder(nil)
      self.panel?.orderOut(nil)
      self.collapse()
      self.editingActivity(false)
      output.output(id, capturedTarget: captured)
      self.panel?.orderFrontRegardless()
    }
  }

  func startCollectionObservation(present: @escaping () -> Void) {
    presentCollectionPanel = present
    observeCollectionPreferences()
  }

  private func observeCollectionPreferences() {
    guard !hasBegunShutdown, let model = appModel else { return }
    let preferences = withObservationTracking {
      let settings = model.settings
      return (
        loading: settings.isLoading,
        voice: settings.builtinPushToTalkOutputMode == .saveToVoiceGroup,
        clipboard: settings.systemClipboardCaptureEnabled
      )
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.observeCollectionPreferences() }
    }
    guard !preferences.loading else { return }
    let newlyEnabled =
      (preferences.voice && !lastCollectionPreferences.voice)
      || (preferences.clipboard && !lastCollectionPreferences.clipboard)
    lastCollectionPreferences = (preferences.voice, preferences.clipboard)
    if newlyEnabled, !isVisible {
      presentCollectionPanel?()
      collapse()
    }
  }

  private func beginEditingVisit() {
    guard let model = appModel else { return }
    rememberPreviousApplication()
    draftTarget = draftTextOutput.captureDraftTarget()
    model.recordWorkspace.buffers.editor.targetName = draftTarget?.applicationName
    if presentation.mode == .drafts { model.recordWorkspace.buffers.editor.open() }
    quickPanelModel?.updateSourceApplication(lockPasteTarget()?.identity.bundleIdentifier)
    updatePasteTargetPresentation()
  }

  func selectMode(_ mode: RecordPanelPresentation.Mode, activate: Bool = true) {
    guard let panel, !hasMarkedText else { return }
    if presentation.mode == .drafts { draftsResponder = panel.firstResponder }
    panel.makeFirstResponder(nil)
    presentation.mode = mode
    if mode == .drafts, appModel?.recordWorkspace.buffers.editor.isVisible != true {
      appModel?.recordWorkspace.buffers.editor.open()
    }
    if presentation.isCollapsed { expand(activate: activate) } else if activate { focusMode() }
    editingActivity(panel.isKeyWindow && mode == .drafts)
  }

  func collapse() {
    guard let panel, !presentation.isCollapsed, !hasMarkedText, panel.attachedSheet == nil else { return }
    focusModeTask?.cancel()
    if presentation.mode == .drafts { draftsResponder = panel.firstResponder }
    expandedFrame = panel.frame
    saveExpandedFrame()
    presentation.expandedWidth = panel.frame.width
    presentation.expandedHeight = panel.frame.height
    panel.makeFirstResponder(nil)
    presentation.isCollapsed = true
    (panel as? FloatingRecordPanel)?.permitsKey = false
    panel.minSize = NSSize(width: 320, height: 56)
    panel.contentMinSize = panel.minSize
    panel.styleMask.remove(.resizable)
    let origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - 56)
    panel.setFrame(NSRect(origin: origin, size: panel.minSize), display: true)
    panel.isMovableByWindowBackground = true
    panel.resignKey()
    editingActivity(false)
  }

  func expand(activate: Bool = true) {
    guard let panel, presentation.isCollapsed else { return }
    let size = expandedFrame?.size ?? Self.defaultPanelSize
    let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    presentation.isCollapsed = false
    (panel as? FloatingRecordPanel)?.permitsKey = true
    panel.styleMask.insert(.resizable)
    panel.minSize = Self.minimumPanelSize
    panel.contentMinSize = Self.minimumPanelSize
    var frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
    if let screen = panel.screen {
      frame.origin.x = max(screen.visibleFrame.minX, min(frame.minX, screen.visibleFrame.maxX - frame.width))
      frame.origin.y = max(screen.visibleFrame.minY, min(frame.minY, screen.visibleFrame.maxY - frame.height))
    }
    panel.setFrame(frame, display: true)
    panel.isMovableByWindowBackground = false
    if activate {
      panel.makeKey()
      focusMode()
    }
  }

  private var hasMarkedText: Bool {
    (panel?.firstResponder as? NSTextView)?.hasMarkedText() == true
      || appModel?.recordWorkspace.buffers.editor.session?.hasMarkedText == true
  }

  private func focusMode() {
    focusModeTask?.cancel()
    focusModeTask = Task { @MainActor [weak self] in
      await withCheckedContinuation { continuation in
        RunLoop.main.perform(inModes: [.default]) { continuation.resume() }
      }
      guard let self, !Task.isCancelled, !self.presentation.isCollapsed,
        let panel = self.panel, panel.isVisible
      else { return }
      let previous = self.presentation.mode == .drafts ? self.draftsResponder : nil
      if let view = previous as? NSView, view.window === panel {
        panel.makeFirstResponder(view)
        return
      }
      let identifier = self.presentation.mode == .collections ? "records.quick-search" : "record-buffer.editor"
      if let view = self.findView(in: panel.contentView, identifier: identifier) { panel.makeFirstResponder(view) }
    }
  }

  private func findView(in view: NSView?, identifier: String) -> NSView? {
    guard let view else { return nil }
    if view.accessibilityIdentifier() == identifier { return view }
    for child in view.subviews {
      if let match = findView(in: child, identifier: identifier) { return match }
    }
    return nil
  }

  private var previousApplication: NSRunningApplication?
  private var recentExternalApplication: NSRunningApplication?
  private var pendingFocusHideTask: Task<Void, Never>?
  private var pendingFocusRestoreTask: Task<Void, Never>?
  private let pasteTaskOwner = RecordPanelPasteTaskOwner()
  private var panelTransitionGeneration: UInt64 = 0
  private var panelHideTask: Task<Void, Never>?
  private var retiringSessionTasks: [UUID: Task<Void, Never>] = [:]
  private var hasBegunShutdown = false
  private var autoHideSuppressedUntil = ContinuousClock.now
  private let pasteTargetProvider: (@MainActor () -> FocusedApplicationTargetIdentity?)?
  private let pasteTargetRestorer: (@MainActor (FocusedApplicationTargetIdentity) async -> Bool)?
  private let reduceMotionProvider: @MainActor () -> Bool

  override init() {
    frameAutosaveName = "RillRecordPanel"
    pasteTargetProvider = nil
    pasteTargetRestorer = nil
    reduceMotionProvider = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    super.init()
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(activeApplicationDidChange(_:)),
      name: NSWorkspace.didActivateApplicationNotification,
      object: nil
    )
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(pasteTargetApplicationDidTerminate(_:)),
      name: NSWorkspace.didTerminateApplicationNotification, object: nil
    )
    rememberPreviousApplication()
  }

  init(
    pasteTargetProvider: @escaping @MainActor () -> FocusedApplicationTargetIdentity?,
    pasteTargetRestorer: @escaping @MainActor (FocusedApplicationTargetIdentity) async -> Bool,
    reduceMotionProvider: @escaping @MainActor () -> Bool = {
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
  ) {
    frameAutosaveName = nil
    self.pasteTargetProvider = pasteTargetProvider
    self.pasteTargetRestorer = pasteTargetRestorer
    self.reduceMotionProvider = reduceMotionProvider
    super.init()
  }

  deinit {
    focusModeTask?.cancel()
    panelHideTask?.cancel()
    pendingFocusHideTask?.cancel()
    pendingFocusRestoreTask?.cancel()
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }

  var isVisible: Bool { panel?.isVisible ?? false }
  var isKey: Bool { panel?.isKeyWindow == true }
  var isShutdown: Bool { hasBegunShutdown }

  /// Digit-key hook wired to the panel while it is shown; resolves a
  /// zero-based visible record index to a delivery through the same target
  /// locking path as the Insert button. Exposed for tests.
  private(set) var digitSelectionHandler: ((Int) -> Bool)?
  private(set) var quickPanelModel: RecordQuickPanelModel?

  func show(
    model: AppModel,
    mode: RecordPanelPresentation.Mode = .collections,
    toggle: Bool = true,
    activate: Bool = true,
    deliverSelection: @escaping @Sendable (RecordReuseSubject, FocusedApplicationTargetIdentity) async -> RecordReuseOutcome,
    copySelection: @escaping @Sendable (RecordReuseSubject) async -> RecordReuseOutcome = { _ in .blocked },
    onDeliveryAbort: @escaping @Sendable () async -> Void,
    restoring comparison: RecordComparisonReturn? = nil
  ) {
    guard !hasBegunShutdown else { return }
    if activate { model.discardComparisonReturn() }
    if isVisible {
      // Output status is visible in either mode. Keep ongoing input in place.
      if !activate, !presentation.isCollapsed { return }
      if let comparison { quickPanelModel?.restoreComparison(comparison) }
      if toggle && presentation.mode == mode && !presentation.isCollapsed {
        handleEscape()
      } else if presentation.isCollapsed {
        selectMode(mode, activate: activate)
      } else {
        selectMode(mode, activate: activate)
        if activate {
          panel?.makeKey()
          focusMode()
        }
      }
      return
    }
    appModel = model
    presentation.mode = mode
    presentation.isCollapsed = false
    rememberPreviousApplication()
    if mode == .drafts { model.recordWorkspace.buffers.editor.open() }
    if let previousSession = quickPanelModel {
      previousSession.stop()
      let id = UUID()
      retiringSessionTasks[id] = Task { [weak self] in
        await previousSession.shutdown()
        self?.retiringSessionTasks[id] = nil
      }
    }
    let session = model.recordWorkspace.makeQuickPanelModel()
    session.start(sourceBundleIdentifier: previousApplication?.bundleIdentifier)
    if let comparison { session.restoreComparison(comparison) }
    quickPanelModel = session
    updatePasteTargetPresentation()
    let useSelectedRecord: @MainActor @Sendable (RecordReuseSubject) -> Void = { [weak self] subject in
      self?.useSelectedItem { [weak self] target in
        let result = await deliverSelection(subject, target)
        await self?.handleReuseOutcome(result, session: session)
      } onAbort: { [weak self] in
        await onDeliveryAbort()
        self?.handleReuseOutcome(.targetUnavailable, session: session)
      }
    }
    let digitSelection: (Int) -> Bool = { [weak self] index in
      guard self?.presentation.mode == .collections, self?.presentation.isCollapsed == false,
        let subject = session.subject(at: index)
      else { return false }
      useSelectedRecord(subject)
      return true
    }
    digitSelectionHandler = digitSelection
    let rootView = FloatingRecordView(
      model: model, session: session, presentation: presentation,
      onModeChange: { [weak self] in self?.selectMode($0) },
      onCollapse: { [weak self] in self?.collapse() },
      onExpand: { [weak self] in self?.selectMode(.drafts) },
      onNeedsAttention: { [weak self] in self?.selectMode(.drafts, activate: false) },
      deliverSelection: useSelectedRecord,
      copySelection: { [weak self] subject in
        guard let self,
          let reservation = self.pasteTaskOwner.reserve(
            prepare: { true },
            action: { [weak self] in
              let result = await copySelection(subject)
              self?.handleReuseOutcome(result, session: session)
            }, onAbort: nil
          )
        else { return }
        self.pasteTaskOwner.start(reservation)
      },
      onShowRecord: { [weak self] in self?.hidePanel(restorePreviousApplication: false) },
      onConfigureJev: { [weak self, weak model] in
        guard let self, let model else { return }
        self.prepareForSettings(model: model) { [weak self, weak model] context in
          guard let self, let model, !self.hasBegunShutdown else { return }
          self.show(
            model: model, deliverSelection: deliverSelection, copySelection: copySelection,
            onDeliveryAbort: onDeliveryAbort, restoring: context)
        }
      },
      onClose: { [weak self] in self?.dismiss() }
    )
    let hostingController: FloatingRecordHostingController<FloatingRecordView>
    if let existing = panel?.contentViewController as? FloatingRecordHostingController<FloatingRecordView> {
      existing.replaceRootView(rootView)
      hostingController = existing
    } else {
      hostingController = FloatingRecordHostingController(rootView: rootView)
    }

    if let panel {
      panel.title = L10n.quickRecord(.title, language: model.settings.language)
      (panel as? FloatingRecordPanel)?.onDigitPressed = digitSelection
      if panel.contentViewController !== hostingController { panel.contentViewController = hostingController }
      restorePanelSizeIfNeeded(panel)
      if panel.isVisible {
        dismiss()
        return
      }
      present(panel, activate: activate)
      return
    }

    let panel = FloatingRecordPanel(
      contentRect: NSRect(origin: .zero, size: Self.defaultPanelSize),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView, .resizable],
      backing: .buffered,
      defer: false
    )
    panel.title = L10n.quickRecord(.title, language: model.settings.language)
    panel.delegate = self
    panel.onEscapePressed = { [weak self] in self?.handleEscape() }
    panel.onWillBecomeKey = { [weak self] in self?.beginEditingVisit() }
    panel.onDigitPressed = digitSelection
    panel.contentViewController = hostingController
    panel.minSize = Self.minimumPanelSize
    panel.contentMinSize = Self.minimumPanelSize
    panel.setContentSize(Self.defaultPanelSize)
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.level = .floating
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    panel.animationBehavior = .utilityWindow
    panel.isMovableByWindowBackground = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.contentView?.wantsLayer = true
    panel.contentView?.layer?.cornerRadius = RillRadius.panel
    panel.contentView?.layer?.masksToBounds = true
    centerOnActiveScreen(panel)
    if let frameAutosaveName { panel.setFrameUsingName(frameAutosaveName) }
    self.panel = panel
    present(panel, activate: activate)
  }

  func prepareForSettings(model: AppModel, resume: @escaping @MainActor (RecordComparisonReturn) -> Void) {
    if let context = quickPanelModel?.comparisonReturnContext() {
      model.offerComparisonReturn(context, resume: resume)
    } else {
      model.discardComparisonReturn()
    }
    hidePanel(restorePreviousApplication: false)
  }

  private func handleReuseOutcome(_ result: RecordReuseOutcome, session: RecordQuickPanelModel) {
    guard !hasBegunShutdown, session === quickPanelModel else { return }
    session.report(result)
    if result != .delivered && result != .copied, let panel, !panel.isVisible {
      session.resume()
      present(panel)
    }
  }

  func dismiss() {
    hidePanel(restorePreviousApplication: !presentation.isCollapsed)
  }

  private func handleEscape() {
    guard let panel, !hasMarkedText, quickPanelModel?.cleanup.isWorking != true else { return }
    if panel.attachedSheet == nil, presentation.mode == .collections, quickPanelModel?.isPreviewVisible == true {
      quickPanelModel?.closePreview()
      return
    }
    switch RecordPanelModalPolicy.escapeDestination(
      hasAttachedSheet: panel.attachedSheet != nil
    ) {
    case .attachedSheet:
      guard let attachedSheet = panel.attachedSheet else { return }
      panel.endSheet(attachedSheet, returnCode: .cancel)
    case .panel:
      if presentation.mode == .drafts && !presentation.isCollapsed { collapse() } else { dismiss() }
    }
  }

  func useSelectedItem(
    _ action: @escaping @Sendable (FocusedApplicationTargetIdentity) async -> Void,
    onAbort: (@MainActor @Sendable () async -> Void)? = nil
  ) {
    guard !hasBegunShutdown else {
      pasteTaskOwner.reject(onAbort)
      return
    }
    guard let lockedTarget = lockPasteTarget() else {
      pasteTaskOwner.reject(onAbort)
      return
    }
    guard
      let reservationID = pasteTaskOwner.reserve(
        prepare: { [weak self] in
          guard let self else { return false }
          return await self.restoreLockedPasteTarget(lockedTarget)
        },
        action: {
          await action(lockedTarget.identity)
        },
        onAbort: onAbort
      )
    else {
      return
    }
    suppressAutoHide()
    let pasteTaskOwner = pasteTaskOwner
    hidePanel(
      restorePreviousApplication: false,
      onHidden: { pasteTaskOwner.start(reservationID) },
      onInvalidated: { pasteTaskOwner.abort(reservationID) }
    )
  }

  func shutdown() async {
    guard !hasBegunShutdown else {
      await pasteTaskOwner.shutdown()
      return
    }
    hasBegunShutdown = true
    presentCollectionPanel = nil
    focusModeTask?.cancel()
    appModel?.recordWorkspace.buffers.editor.close()
    editingActivity(false)
    panelHideTask?.cancel()
    await panelHideTask?.value
    panelHideTask = nil
    await quickPanelModel?.shutdown()
    for task in Array(retiringSessionTasks.values) { await task.value }
    panelTransitionGeneration &+= 1
    pendingFocusHideTask?.cancel()
    pendingFocusHideTask = nil
    pendingFocusRestoreTask?.cancel()
    pendingFocusRestoreTask = nil
    panel?.orderOut(nil)
    panel?.alphaValue = 1
    await pasteTaskOwner.shutdown()
  }

  private func lockPasteTarget() -> LockedPasteTarget? {
    if let pasteTargetProvider {
      guard let identity = pasteTargetProvider() else { return nil }
      return LockedPasteTarget(identity: identity, application: nil)
    }

    let application: NSRunningApplication?
    if let previousApplication, !previousApplication.isTerminated {
      application = previousApplication
    } else {
      application = fallbackExternalApplication
    }
    guard let application,
      !application.isTerminated,
      let identity = FocusedApplicationTargetIdentity(
        processIdentifier: application.processIdentifier,
        bundleIdentifier: application.bundleIdentifier
      )
    else {
      return nil
    }
    return LockedPasteTarget(identity: identity, application: application)
  }

  private func restoreLockedPasteTarget(_ target: LockedPasteTarget) async -> Bool {
    if let pasteTargetRestorer {
      return await pasteTargetRestorer(target.identity)
    }
    guard let application = target.application,
      await restorePreviousApplicationIfNeeded(application)
    else {
      return false
    }
    guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
      return false
    }
    let frontmostFocus = FocusSnapshot(
      applicationName: nil,
      bundleIdentifier: frontmostApplication.bundleIdentifier,
      processIdentifier: frontmostApplication.processIdentifier,
      focusedRole: nil,
      selectedText: "",
      secureInput: false
    )
    return target.identity.matches(frontmostFocus)
  }

  @objc private func activeApplicationDidChange(_ notification: Notification) {
    guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
      return
    }
    rememberExternalApplication(application)
    updatePasteTargetPresentation()
  }

  @objc private func pasteTargetApplicationDidTerminate(_ notification: Notification) {
    updatePasteTargetPresentation()
  }

  private func updatePasteTargetPresentation() {
    let target = lockPasteTarget()
    quickPanelModel?.pasteTargetName = target?.application?.localizedName ?? target?.identity.bundleIdentifier
  }

  private func rememberPreviousApplication() {
    guard pasteTargetProvider == nil else { return }
    if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
      rememberExternalApplication(frontmostApplication)
    {
      previousApplication = frontmostApplication
      return
    }
    previousApplication = fallbackExternalApplication
  }

  @discardableResult
  private func rememberExternalApplication(_ application: NSRunningApplication) -> Bool {
    guard application.bundleIdentifier != Bundle.main.bundleIdentifier,
      !application.isTerminated
    else {
      return false
    }
    recentExternalApplication = application
    return true
  }

  private var fallbackExternalApplication: NSRunningApplication? {
    guard let recentExternalApplication, !recentExternalApplication.isTerminated else {
      return nil
    }
    return recentExternalApplication
  }

  private func restorePanelSizeIfNeeded(_ panel: NSPanel) {
    guard
      panel.frame.width < Self.minimumPanelSize.width
        || panel.frame.height < Self.minimumPanelSize.height
    else {
      return
    }

    let size = expandedFrame?.size ?? Self.defaultPanelSize
    let resizedFrame = NSRect(
      x: panel.frame.minX, y: panel.frame.maxY - size.height,
      width: size.width, height: size.height)
    panel.setFrame(resizedFrame, display: true, animate: false)
  }

  private func present(_ panel: NSPanel, activate: Bool = true) {
    panelHideTask?.cancel()
    panelHideTask = nil
    (panel as? FloatingRecordPanel)?.permitsKey = true
    panel.styleMask.insert(.resizable)
    panel.minSize = Self.minimumPanelSize
    panel.contentMinSize = Self.minimumPanelSize
    restorePanelSizeIfNeeded(panel)
    guard !hasBegunShutdown else { return }
    pasteTaskOwner.abortReservations()
    panelTransitionGeneration &+= 1
    pendingFocusHideTask?.cancel()
    pendingFocusRestoreTask?.cancel()
    pendingFocusRestoreTask = nil
    suppressAutoHide()
    defer { if activate { focusMode() } }
    // Reduce Motion: skip the entrance fade and show the panel directly.
    if reduceMotionProvider() {
      panel.alphaValue = 1
      panel.orderFrontRegardless()
      if activate { panel.makeKey() }
      return
    }
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    if activate { panel.makeKey() }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.15
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
    }
  }

  private func centerOnActiveScreen(_ panel: NSPanel) {
    let screen =
      NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
      ?? NSScreen.main
      ?? NSScreen.screens.first
    guard let screen else { return }
    let visibleFrame = screen.visibleFrame
    let originX = visibleFrame.midX - panel.frame.width / 2
    let originY = visibleFrame.midY - panel.frame.height / 2
    panel.setFrameOrigin(NSPoint(x: originX, y: originY))
  }

  private func hidePanel(
    restorePreviousApplication: Bool,
    onHidden: (@MainActor () -> Void)? = nil,
    onInvalidated: (@MainActor () -> Void)? = nil
  ) {
    focusModeTask?.cancel()
    panel?.makeFirstResponder(nil)
    appModel?.recordWorkspace.buffers.editor.close()
    editingActivity(false)
    quickPanelModel?.stop()
    if onHidden == nil, onInvalidated == nil {
      pasteTaskOwner.abortReservations()
    }
    pendingFocusHideTask?.cancel()
    pendingFocusHideTask = nil
    guard let panel, panel.isVisible else {
      onHidden?()
      return
    }
    panelTransitionGeneration &+= 1
    let transitionGeneration = panelTransitionGeneration
    let previousApp = restorePreviousApplication ? previousApplication ?? fallbackExternalApplication : nil
    // Reduce Motion: skip the exit fade and hide the panel directly.
    panelHideTask?.cancel()
    guard !reduceMotionProvider() else {
      finishHide(
        transitionGeneration: transitionGeneration,
        previousApp: previousApp,
        onHidden: onHidden,
        onInvalidated: onInvalidated
      )
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().alphaValue = 0
    }
    // A no-op AppKit alpha animation may omit its completion. The session
    // owns the dismissal deadline so rapid Enter/Escape cannot strand a paste.
    panelHideTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .milliseconds(120)) } catch {
        onInvalidated?()
        return
      }
      guard let self else {
        onInvalidated?()
        return
      }
      self.finishHide(
        transitionGeneration: transitionGeneration, previousApp: previousApp,
        onHidden: onHidden, onInvalidated: onInvalidated)
      if self.panelTransitionGeneration == transitionGeneration { self.panelHideTask = nil }
    }
  }

  private func finishHide(
    transitionGeneration: UInt64,
    previousApp: NSRunningApplication?,
    onHidden: (@MainActor () -> Void)?,
    onInvalidated: (@MainActor () -> Void)?
  ) {
    guard panelTransitionGeneration == transitionGeneration,
      !hasBegunShutdown
    else {
      onInvalidated?()
      return
    }
    panel?.orderOut(nil)
    panel?.alphaValue = 1
    guard previousApp != nil else {
      onHidden?()
      return
    }
    let focusTask = Task { @MainActor [weak self] in
      guard let self else { return }
      _ = await self.restorePreviousApplicationIfNeeded(previousApp)
      guard !Task.isCancelled,
        self.panelTransitionGeneration == transitionGeneration,
        !self.hasBegunShutdown
      else { return }
      self.pendingFocusRestoreTask = nil
      onHidden?()
    }
    pendingFocusRestoreTask = focusTask
  }

  private func suppressAutoHide() {
    autoHideSuppressedUntil = ContinuousClock.now.advanced(by: Self.autoHideSuppressionInterval)
  }

  private var shouldSuppressAutoHide: Bool {
    ContinuousClock.now < autoHideSuppressedUntil
  }

  private func restorePreviousApplicationIfNeeded(_ application: NSRunningApplication?) async -> Bool {
    guard !Task.isCancelled, !hasBegunShutdown else { return false }
    guard let application, !application.isTerminated else { return application == nil }

    requestForeground(for: application)
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(800))
    var nextForegroundRequest = ContinuousClock.now.advanced(by: .milliseconds(160))
    while ContinuousClock.now < deadline {
      if isFrontmost(application) {
        return await confirmForegroundRestoreSettled(for: application)
      }
      if ContinuousClock.now >= nextForegroundRequest {
        requestForeground(for: application)
        nextForegroundRequest = ContinuousClock.now.advanced(by: .milliseconds(160))
      }
      do {
        try await Task.sleep(for: .milliseconds(25))
      } catch {
        return false
      }
    }
    guard isFrontmost(application) else { return false }
    return await confirmForegroundRestoreSettled(for: application)
  }

  private func confirmForegroundRestoreSettled(for application: NSRunningApplication) async -> Bool {
    do {
      try await Task.sleep(for: Self.focusRestoreSettleInterval)
    } catch {
      return false
    }
    return isFrontmost(application)
  }

  private func requestForeground(for application: NSRunningApplication) {
    application.unhide()
    _ = application.activate(options: [.activateAllWindows])
  }

  private func isFrontmost(_ application: NSRunningApplication) -> Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
  }

  func windowDidBecomeKey(_ notification: Notification) {
    pendingFocusHideTask?.cancel()
    editingActivity(presentation.mode == .drafts && !presentation.isCollapsed)
  }

  func windowDidMove(_ notification: Notification) { saveExpandedFrame() }

  func windowDidResize(_ notification: Notification) { saveExpandedFrame() }

  private func saveExpandedFrame() {
    guard !presentation.isCollapsed, let frameAutosaveName else { return }
    panel?.saveFrame(usingName: frameAutosaveName)
  }

  func windowDidResignKey(_ notification: Notification) {
    editingActivity(false)
    scheduleHideOnFocusLoss()
  }

  func windowDidResignMain(_ notification: Notification) {
    scheduleHideOnFocusLoss()
  }

  private func scheduleHideOnFocusLoss() {
    pendingFocusHideTask?.cancel()
    // A focus loss during presentation still needs a decision when the
    // suppression ends; dropping it leaves a visible panel that cannot type.
    let delay = max(.milliseconds(90), ContinuousClock.now.duration(to: autoHideSuppressedUntil))
    pendingFocusHideTask = Task { @MainActor [weak self] in
      guard await RecordPanelModalPolicy.waitForAutoHideDelay(delay) else {
        return
      }
      guard let self, !self.hasBegunShutdown, self.panel?.isKeyWindow != true else { return }
      guard
        RecordPanelModalPolicy.shouldAutoHide(
          isVisible: self.isVisible,
          hasAttachedSheet: self.panel?.attachedSheet != nil,
          isSuppressed: self.shouldSuppressAutoHide || self.presentation.isCollapsed
            || self.presentation.isPinned || self.hasMarkedText
        )
      else { return }
      if self.presentation.mode == .drafts { self.collapse() } else { self.hidePanel(restorePreviousApplication: false) }
    }
  }
}

private final class FloatingRecordPanel: NSPanel {
  var permitsKey = true
  var onWillBecomeKey: (() -> Void)?
  var onEscapePressed: (() -> Void)?
  var onDigitPressed: ((Int) -> Bool)?

  override var canBecomeKey: Bool { permitsKey }
  override var canBecomeMain: Bool { false }

  override func becomeKey() {
    if !isKeyWindow { onWillBecomeKey?() }
    super.becomeKey()
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if handleDigitShortcut(event) { return true }
    return super.performKeyEquivalent(with: event)
  }

  override func keyDown(with event: NSEvent) {
    if handleDigitShortcut(event) { return }
    super.keyDown(with: event)
  }

  private func handleDigitShortcut(_ event: NSEvent) -> Bool {
    guard attachedSheet == nil,
      (firstResponder as? NSTextView)?.hasMarkedText() != true,
      let index = RecordPanelDigitShortcutPolicy.visibleRecordIndex(
        keyCode: event.keyCode,
        modifierFlags: event.modifierFlags
      )
    else { return false }
    return onDigitPressed?(index) == true
  }

  override func cancelOperation(_ sender: Any?) {
    onEscapePressed?()
  }
}

private final class FloatingRecordHostingController<Content: View>: NSViewController {
  private var rootView: Content

  init(rootView: Content) {
    self.rootView = rootView
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  func replaceRootView(_ content: Content) {
    rootView = content
    (viewIfLoaded as? FirstMouseHostingView<Content>)?.rootView = content
  }

  override func loadView() {
    view = FirstMouseHostingView(rootView: rootView)
  }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }
}

private struct FloatingRecordView: View {
  let model: AppModel
  let session: RecordQuickPanelModel
  let presentation: RecordPanelPresentation
  let onModeChange: (RecordPanelPresentation.Mode) -> Void
  let onCollapse: () -> Void
  let onExpand: () -> Void
  let onNeedsAttention: () -> Void
  let deliverSelection: @MainActor @Sendable (RecordReuseSubject) -> Void
  let copySelection: (RecordReuseSubject) -> Void
  let onShowRecord: () -> Void
  let onConfigureJev: () -> Void
  let onClose: () -> Void
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    UnifiedRecordPanelView(
      presentation: presentation, model: model,
      onModeChange: onModeChange, onCollapse: onCollapse,
      onExpand: onExpand, onClose: onClose, onNeedsAttention: onNeedsAttention
    ) {
      RecordQuickPanelView(
        model: session, language: model.settings.language, capturePaused: !model.settings.systemClipboardCaptureEnabled,
        onPaste: deliverSelection, onCopy: copySelection,
        onShowRecord: { id in
          Task { await model.showRecord(id) }
          onShowRecord()
          NSApp.activate(ignoringOtherApps: true)
          openWindow(id: "main")
        }, onClose: onClose,
        onConfigureJev: { request in
          onConfigureJev()
          model.showSettings(request.section, item: request.item)
          NSApp.activate(ignoringOtherApps: true)
          openWindow(id: "main")
        }
      )
    }
    .clipShape(RoundedRectangle(cornerRadius: RillRadius.panel, style: .continuous))
  }
}
