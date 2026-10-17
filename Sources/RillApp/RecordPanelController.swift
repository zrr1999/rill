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

  private static let defaultPanelSize = RecordPanelPlacement.pageSize
  private static let autoHideSuppressionInterval: Duration = .milliseconds(200)
  private static let focusRestoreSettleInterval: Duration = .milliseconds(80)

  private var panel: NSPanel?
  private var pageContent: FloatingRecordContent?
  let presentation = RecordPanelPresentation()
  private weak var appModel: AppModel? {
    didSet {
      if appModel !== oldValue { observeLanguage() }
    }
  }
  private var draftTarget: RecordBufferTextOutput.Target?
  private var draftTextOutput = RecordBufferTextOutput()
  private var editingActivity: (Bool) -> Void = { _ in }
  private weak var draftsResponder: NSResponder?
  private var focusModeTask: Task<Void, Never>?

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
      self.hidePanel(
        restorePreviousApplication: false,
        onHidden: { output.output(id, capturedTarget: captured) })
    }
  }

  private func observeLanguage() {
    guard !hasBegunShutdown, let model = appModel else { return }
    let language = withObservationTracking {
      model.settings.language
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.observeLanguage() }
    }
    panel?.title = L10n.quickRecord(.title, language: language)
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

  func selectMode(_ mode: RecordPanelPresentation.Mode) {
    guard let panel, !hasMarkedText else { return }
    if presentation.mode == .drafts { draftsResponder = panel.firstResponder }
    panel.makeFirstResponder(nil)
    presentation.mode = mode
    if mode == .drafts, appModel?.recordWorkspace.buffers.editor.isVisible != true {
      appModel?.recordWorkspace.buffers.editor.open()
    }
    panel.makeKey()
    focusMode()
    editingActivity(panel.isKeyWindow && mode == .drafts)
  }

  private var canAutoHide: Bool {
    RecordPanelModalPolicy.shouldAutoHide(
      isVisible: panel?.isVisible == true,
      hasAttachedSheet: panel?.attachedSheet != nil,
      isSuppressed: panel?.isKeyWindow == true || hasMarkedText
        || quickPanelModel?.cleanup.isWorking == true
        || panel?.childWindows?.contains(where: \.isVisible) == true
    )
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
      guard let self, !Task.isCancelled,
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

  var isVisible: Bool { panel?.isVisible == true }
  var isKey: Bool { panel?.isKeyWindow == true }
  var isShutdown: Bool { hasBegunShutdown }

  /// Digit-key hook wired to the panel while it is shown; resolves a
  /// zero-based visible record index to a delivery through the same target
  /// locking path as the Insert button. Exposed for tests.
  private(set) var digitSelectionHandler: ((Int) -> Bool)?
  private(set) var quickPanelModel: RecordQuickPanelModel?

  func show(
    model: AppModel,
    mode: RecordPanelPresentation.Mode? = nil,
    toggle: Bool = true,
    deliverSelection: @escaping @Sendable (RecordReuseSubject, FocusedApplicationTargetIdentity) async -> RecordReuseOutcome,
    copySelection: @escaping @Sendable (RecordReuseSubject) async -> RecordReuseOutcome = { _ in .blocked },
    onDeliveryAbort: @escaping @Sendable () async -> Void,
    restoring comparison: RecordComparisonReturn? = nil
  ) {
    guard !hasBegunShutdown else { return }
    model.discardComparisonReturn()
    let mode = mode ?? presentation.mode
    if isVisible {
      if let comparison { quickPanelModel?.restoreComparison(comparison) }
      if toggle && presentation.mode == mode {
        handleEscape()
      } else {
        selectMode(mode)
      }
      return
    }
    appModel = model
    presentation.mode = mode
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
      guard self?.presentation.mode == .collections, self?.isVisible == true,
        let subject = session.subject(at: index)
      else { return false }
      useSelectedRecord(subject)
      return true
    }
    digitSelectionHandler = digitSelection
    let copyRecord: (RecordReuseSubject) -> Void = { [weak self] subject in
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
    }
    let configureJev: () -> Void = { [weak self, weak model] in
      guard let self, let model else { return }
      self.prepareForSettings(model: model) { [weak self, weak model] context in
        guard let self, let model, !self.hasBegunShutdown else { return }
        self.show(
          model: model, deliverSelection: deliverSelection, copySelection: copySelection,
          onDeliveryAbort: onDeliveryAbort, restoring: context)
      }
    }
    let content: FloatingRecordContent
    let replacesPage: Bool
    if let previous = pageContent, previous.model === model {
      previous.session = session
      previous.deliverSelection = useSelectedRecord
      previous.copySelection = copyRecord
      previous.onConfigureJev = configureJev
      content = previous
      replacesPage = false
    } else {
      content = FloatingRecordContent(
        model: model, session: session, deliverSelection: useSelectedRecord,
        copySelection: copyRecord, onConfigureJev: configureJev)
      pageContent = content
      replacesPage = true
    }
    let hostingController: FloatingRecordHostingController<FloatingRecordView>
    if let existing = panel?.contentViewController as? FloatingRecordHostingController<FloatingRecordView>, !replacesPage {
      hostingController = existing
    } else {
      let rootView = FloatingRecordView(
        content: content, presentation: presentation,
        onModeChange: { [weak self] in self?.selectMode($0) },
        onFinishEditing: { [weak self] in self?.dismiss() },
        onInteractionChange: { [weak self] in self?.scheduleHideOnFocusLoss() },
        onShowRecord: { [weak self] in self?.hidePanel(restorePreviousApplication: false) },
        onClose: { [weak self] in self?.handleEscape() })
      if let existing = panel?.contentViewController as? FloatingRecordHostingController<FloatingRecordView> {
        existing.replaceRootView(rootView)
        hostingController = existing
      } else {
        hostingController = FloatingRecordHostingController(rootView: rootView)
      }
    }
    if let panel {
      panel.title = L10n.quickRecord(.title, language: model.settings.language)
      (panel as? FloatingRecordPanel)?.onDigitPressed = digitSelection
      if panel.contentViewController !== hostingController { panel.contentViewController = hostingController }
      if panel.isVisible {
        dismiss()
        return
      }
      present(panel)
      return
    }

    let panel = FloatingRecordPanel(
      contentRect: NSRect(origin: .zero, size: Self.defaultPanelSize),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.title = L10n.quickRecord(.title, language: model.settings.language)
    panel.identifier = NSUserInterfaceItemIdentifier("record-panel.page")
    panel.delegate = self
    panel.onEscapePressed = { [weak self] in self?.handleEscape() }
    panel.onWillBecomeKey = { [weak self] in self?.beginEditingVisit() }
    panel.onDigitPressed = digitSelection
    panel.contentViewController = hostingController
    panel.setContentSize(Self.defaultPanelSize)
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.level = .floating
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    panel.animationBehavior = .utilityWindow
    panel.isMovableByWindowBackground = false
    panel.acceptsMouseMovedEvents = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.contentView?.wantsLayer = true
    panel.contentView?.layer?.cornerRadius = RecordPanelAppearance.cornerRadius
    panel.contentView?.layer?.masksToBounds = true
    self.panel = panel
    present(panel)
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
      if !session.isPreviewVisible { session.togglePreview() }
      present(panel)
    }
  }

  func dismiss() {
    guard !hasMarkedText else { return }
    hidePanel(restorePreviousApplication: true)
  }

  private func handleEscape() {
    guard let panel, !hasMarkedText, quickPanelModel?.cleanup.isWorking != true else { return }
    switch RecordPanelModalPolicy.escapeDestination(
      hasAttachedSheet: panel.attachedSheet != nil
    ) {
    case .attachedSheet:
      guard let attachedSheet = panel.attachedSheet else { return }
      panel.endSheet(attachedSheet, returnCode: .cancel)
    case .panel:
      dismiss()
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

  private func present(_ panel: NSPanel) {
    guard !hasBegunShutdown else { return }
    panelHideTask?.cancel()
    panelHideTask = nil
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
      let frame = RecordPanelPlacement.pageFrame(in: screen.visibleFrame)
      if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
    pasteTaskOwner.abortReservations()
    panelTransitionGeneration &+= 1
    pendingFocusHideTask?.cancel()
    pendingFocusRestoreTask?.cancel()
    pendingFocusRestoreTask = nil
    suppressAutoHide()
    defer { focusMode() }
    // Reduce Motion: skip the entrance fade and show the panel directly.
    if reduceMotionProvider() {
      panel.alphaValue = 1
      panel.orderFrontRegardless()
      panel.makeKey()
      return
    }
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    panel.makeKey()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.10
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
    }
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
    editingActivity(presentation.mode == .drafts)
  }

  func windowDidEndSheet(_ notification: Notification) { scheduleHideOnFocusLoss() }

  func windowDidResignKey(_ notification: Notification) {
    editingActivity(false)
    scheduleHideOnFocusLoss()
  }

  func windowDidResignMain(_ notification: Notification) {
    scheduleHideOnFocusLoss()
  }

  private func scheduleHideOnFocusLoss() {
    guard panelHideTask == nil else { return }
    pendingFocusHideTask?.cancel()
    // A focus loss during presentation still needs a decision when the
    // suppression ends; dropping it leaves a visible panel that cannot type.
    let delay = max(.milliseconds(90), ContinuousClock.now.duration(to: autoHideSuppressedUntil))
    pendingFocusHideTask = Task { @MainActor [weak self] in
      guard await RecordPanelModalPolicy.waitForAutoHideDelay(delay) else {
        return
      }
      guard let self, !self.hasBegunShutdown, self.panel?.isKeyWindow != true else { return }
      if self.panelHideTask == nil, self.canAutoHide {
        self.hidePanel(restorePreviousApplication: false)
      }
    }
  }
}

private final class FloatingRecordPanel: NSPanel {
  var onWillBecomeKey: (() -> Void)?
  var onEscapePressed: (() -> Void)?
  var onDigitPressed: ((Int) -> Bool)?

  override var canBecomeKey: Bool { true }
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
    let hosting = FirstMouseHostingView(rootView: rootView)
    hosting.sizingOptions = []
    view = hosting
  }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }
}

@MainActor @Observable
private final class FloatingRecordContent {
  let model: AppModel
  var session: RecordQuickPanelModel
  var deliverSelection: @MainActor @Sendable (RecordReuseSubject) -> Void
  var copySelection: (RecordReuseSubject) -> Void
  var onConfigureJev: () -> Void

  init(
    model: AppModel, session: RecordQuickPanelModel,
    deliverSelection: @escaping @MainActor @Sendable (RecordReuseSubject) -> Void,
    copySelection: @escaping (RecordReuseSubject) -> Void,
    onConfigureJev: @escaping () -> Void
  ) {
    self.model = model
    self.session = session
    self.deliverSelection = deliverSelection
    self.copySelection = copySelection
    self.onConfigureJev = onConfigureJev
  }
}

private struct FloatingRecordView: View {
  let content: FloatingRecordContent
  let presentation: RecordPanelPresentation
  let onModeChange: (RecordPanelPresentation.Mode) -> Void
  let onFinishEditing: () -> Void
  let onInteractionChange: () -> Void
  let onShowRecord: () -> Void
  let onClose: () -> Void

  var body: some View {
    UnifiedRecordPanelView(
      presentation: presentation, model: content.model,
      onModeChange: onModeChange, onFinishEditing: onFinishEditing,
      onInteractionChange: onInteractionChange, onClose: onClose
    ) {
      FloatingRecordCollectionsView(content: content, onShowRecord: onShowRecord, onClose: onClose)
    }
    .onChange(of: content.session.cleanup.isWorking) { _, _ in onInteractionChange() }
    .environment(\.locale, content.model.settings.language.formattingLocale)
    .clipShape(RoundedRectangle(cornerRadius: RecordPanelAppearance.cornerRadius, style: .continuous))
  }
}

private struct FloatingRecordCollectionsView: View {
  let content: FloatingRecordContent
  let onShowRecord: () -> Void
  let onClose: () -> Void
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    let model = content.model
    RecordQuickPanelView(
      model: content.session, language: model.settings.language, capturePaused: !model.settings.systemClipboardCaptureEnabled,
      onPaste: content.deliverSelection, onCopy: content.copySelection,
      onShowRecord: { id in
        Task { await model.showRecord(id) }
        onShowRecord()
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
      }, onClose: onClose,
      onConfigureJev: { request in
        content.onConfigureJev()
        model.showSettings(request.section, item: request.item)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
      }
    )
  }
}
