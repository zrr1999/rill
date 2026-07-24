import AppKit
import SwiftUI
import RillCore
import RillUI

enum ClipboardPanelModalPolicy {
    /// Opening any SwiftUI sheet from the nonactivating AppKit panel remains
    /// disabled until attached-sheet focus, Escape routing, auto-hide, and key
    /// isolation have all passed live accessibility testing in the packaged app.
    static let allowsSheetPresentation = false

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
        _ delay: Duration = .milliseconds(90)
    ) async -> Bool {
        do {
            try await Task.sleep(for: delay)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

@MainActor
final class ClipboardPanelPasteTaskOwner {
    private struct Reservation {
        let prepare: @MainActor () async -> Bool
        let action: @MainActor () async -> Void
        let onAbort: (@MainActor @Sendable () -> Void)?
    }

    private var reservations: [UUID: Reservation] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var hasBegunShutdown = false

    deinit {
        for task in tasks.values {
            task.cancel()
        }
    }

    @discardableResult
    func reserve(
        prepare: @escaping @MainActor () async -> Bool,
        action: @escaping @MainActor () async -> Void,
        onAbort: (@MainActor @Sendable () -> Void)?
    ) -> UUID? {
        guard !hasBegunShutdown, reservations.isEmpty, tasks.isEmpty else {
            onAbort?()
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
              let reservation = reservations.removeValue(forKey: id) else {
            abort(id)
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else {
                reservation.onAbort?()
                return
            }
            defer { self.tasks[id] = nil }
            let isPrepared = await reservation.prepare()
            guard !Task.isCancelled,
                  !self.hasBegunShutdown,
                  isPrepared else {
                reservation.onAbort?()
                return
            }
            await reservation.action()
        }
        tasks[id] = task
    }

    func abort(_ id: UUID) {
        guard let reservation = reservations.removeValue(forKey: id) else { return }
        reservation.onAbort?()
    }

    func abortReservations() {
        let pending = Array(reservations.values)
        reservations.removeAll()
        for reservation in pending {
            reservation.onAbort?()
        }
    }

    func shutdown() async {
        if !hasBegunShutdown {
            hasBegunShutdown = true
            abortReservations()
        }
        while !tasks.isEmpty {
            let runningTasks = Array(tasks.values)
            for task in runningTasks {
                await task.value
            }
        }
    }
}

@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    private struct LockedPasteTarget {
        var identity: ClipboardPasteTargetIdentity
        var application: NSRunningApplication?
    }

    private static let defaultPanelSize = NSSize(width: 750, height: 520)
    fileprivate static let minimumPanelSize = NSSize(width: 600, height: 400)
    private static let autoHideSuppressionInterval: Duration = .milliseconds(200)
    private static let focusRestoreSettleInterval: Duration = .milliseconds(80)

    private var panel: NSPanel?
    private var previousApplication: NSRunningApplication?
    private var recentExternalApplication: NSRunningApplication?
    private var pendingFocusHideTask: Task<Void, Never>?
    private var pendingFocusRestoreTask: Task<Void, Never>?
    private let pasteTaskOwner = ClipboardPanelPasteTaskOwner()
    private var panelTransitionGeneration: UInt64 = 0
    private var hasBegunShutdown = false
    private var autoHideSuppressedUntil = ContinuousClock.now
    private let pasteTargetProvider: (@MainActor () -> ClipboardPasteTargetIdentity?)?
    private let pasteTargetRestorer: (@MainActor (ClipboardPasteTargetIdentity) async -> Bool)?

    override init() {
        pasteTargetProvider = nil
        pasteTargetRestorer = nil
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        rememberPreviousApplication()
    }

    init(
        pasteTargetProvider: @escaping @MainActor () -> ClipboardPasteTargetIdentity?,
        pasteTargetRestorer: @escaping @MainActor (ClipboardPasteTargetIdentity) async -> Bool
    ) {
        self.pasteTargetProvider = pasteTargetProvider
        self.pasteTargetRestorer = pasteTargetRestorer
        super.init()
    }

    deinit {
        pendingFocusHideTask?.cancel()
        pendingFocusRestoreTask?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var isShutdown: Bool { hasBegunShutdown }

    func show(model: AppModel) {
        guard !hasBegunShutdown else { return }
        rememberPreviousApplication()
        let previewContext = ClipboardRouteContext(
            applicationName: previousApplication?.localizedName,
            bundleIdentifier: previousApplication?.bundleIdentifier
        )
        let hostingController = FloatingClipboardHostingController(
            rootView: FloatingClipboardView(
                model: model,
                previewContext: previewContext,
                onClose: dismiss
            )
        )

        if let panel {
            panel.contentViewController = hostingController
            restorePanelSizeIfNeeded(panel)
            if panel.isVisible {
                dismiss()
                return
            }
            present(panel)
            return
        }

        let panel = FloatingClipboardPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultPanelSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.onEscapePressed = { [weak self] in self?.handleEscape() }
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
        panel.contentView?.layer?.cornerRadius = 16
        panel.contentView?.layer?.masksToBounds = true
        centerOnActiveScreen(panel)
        self.panel = panel
        present(panel)
    }

    func dismiss() {
        hidePanel(restorePreviousApplication: true)
    }

    private func handleEscape() {
        guard let panel else { return }
        switch ClipboardPanelModalPolicy.escapeDestination(
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
        _ action: @escaping @Sendable (ClipboardPasteTargetIdentity) async -> Void,
        onAbort: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard !hasBegunShutdown else {
            onAbort?()
            return
        }
        guard let lockedTarget = lockPasteTarget() else {
            onAbort?()
            return
        }
        guard let reservationID = pasteTaskOwner.reserve(
            prepare: { [weak self] in
                guard let self else { return false }
                return await self.restoreLockedPasteTarget(lockedTarget)
            },
            action: {
                await action(lockedTarget.identity)
            },
            onAbort: onAbort
        ) else {
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
              let identity = ClipboardPasteTargetIdentity(
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
    }

    private func rememberPreviousApplication() {
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           rememberExternalApplication(frontmostApplication) {
            previousApplication = frontmostApplication
            return
        }
        previousApplication = fallbackExternalApplication
    }

    @discardableResult
    private func rememberExternalApplication(_ application: NSRunningApplication) -> Bool {
        guard application.bundleIdentifier != Bundle.main.bundleIdentifier,
              !application.isTerminated else {
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

        let resizedFrame = NSRect(origin: panel.frame.origin, size: Self.defaultPanelSize)
        panel.setFrame(resizedFrame, display: true, animate: false)
        centerOnActiveScreen(panel)
    }

    private func present(_ panel: NSPanel) {
        guard !hasBegunShutdown else { return }
        pasteTaskOwner.abortReservations()
        panelTransitionGeneration &+= 1
        pendingFocusHideTask?.cancel()
        pendingFocusRestoreTask?.cancel()
        pendingFocusRestoreTask = nil
        suppressAutoHide()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func centerOnActiveScreen(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visibleFrame = screen.visibleFrame
        let originX = visibleFrame.midX - panel.frame.width / 2
        let originY = visibleFrame.midY - panel.frame.height / 2 + visibleFrame.height * 0.1
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    private func hidePanel(
        restorePreviousApplication: Bool,
        onHidden: (@MainActor () -> Void)? = nil,
        onInvalidated: (@MainActor () -> Void)? = nil
    ) {
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
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else {
                    onInvalidated?()
                    return
                }
                guard self.panelTransitionGeneration == transitionGeneration,
                      !self.hasBegunShutdown else {
                    onInvalidated?()
                    return
                }
                self.panel?.orderOut(nil)
                self.panel?.alphaValue = 1
                guard previousApp != nil else {
                    onHidden?()
                    return
                }
                let focusTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = await self.restorePreviousApplicationIfNeeded(previousApp)
                    guard !Task.isCancelled,
                          self.panelTransitionGeneration == transitionGeneration,
                          !self.hasBegunShutdown else { return }
                    self.pendingFocusRestoreTask = nil
                    onHidden?()
                }
                self.pendingFocusRestoreTask = focusTask
            }
        }
    }

    private func suppressAutoHide() {
        autoHideSuppressedUntil = ContinuousClock.now.advanced(by: Self.autoHideSuppressionInterval)
    }

    private var shouldSuppressAutoHide: Bool {
        ContinuousClock.now < autoHideSuppressedUntil
    }

    private func restorePreviousApplicationIfNeeded(_ application: NSRunningApplication?) async -> Bool {
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
        guard let bundleURL = application.bundleURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in }
    }

    private func isFrontmost(_ application: NSRunningApplication) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
    }

    func windowDidBecomeKey(_ notification: Notification) {
        pendingFocusHideTask?.cancel()
    }

    func windowDidResignKey(_ notification: Notification) {
        scheduleHideOnFocusLoss()
    }

    func windowDidResignMain(_ notification: Notification) {
        scheduleHideOnFocusLoss()
    }

    private func scheduleHideOnFocusLoss() {
        pendingFocusHideTask?.cancel()
        pendingFocusHideTask = Task { @MainActor [weak self] in
            guard await ClipboardPanelModalPolicy.waitForAutoHideDelay() else {
                return
            }
            guard let self else { return }
            guard ClipboardPanelModalPolicy.shouldAutoHide(
                isVisible: self.isVisible,
                hasAttachedSheet: self.panel?.attachedSheet != nil,
                isSuppressed: self.shouldSuppressAutoHide
            ) else { return }
            self.hidePanel(restorePreviousApplication: false)
        }
    }
}

private final class FloatingClipboardPanel: NSPanel {
    var onEscapePressed: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscapePressed?()
    }
}

private final class FloatingClipboardHostingController<Content: View>: NSHostingController<Content> {
    override func loadView() {
        view = FirstMouseHostingView(rootView: rootView)
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// Transparent view that allows window dragging from its area.
private final class WindowDragHandleView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// SwiftUI wrapper for the drag handle — place this as an overlay on the panel edge.
private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowDragHandleView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct FloatingClipboardView: View {
    let model: AppModel
    let previewContext: ClipboardRouteContext?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(UIStrings.text(.clipboardTitle, language: model.language))
                    .font(.headline)

                Spacer(minLength: 0)

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(UIStrings.text(.dismiss, language: model.language))
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background {
                WindowDragHandle()
            }

            Divider()
                .padding(.horizontal, 16)

            ClipboardView(
                model: model,
                previewContext: previewContext,
                allowsSheetPresentation: ClipboardPanelModalPolicy.allowsSheetPresentation,
                allowsDryRunPreview: ClipboardPanelModalPolicy.allowsSheetPresentation,
                showsPersistenceWarning: false
            )
                .frame(
                    minWidth: ClipboardPanelController.minimumPanelSize.width,
                    maxWidth: .infinity,
                    minHeight: ClipboardPanelController.minimumPanelSize.height,
                    maxHeight: .infinity
                )
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
