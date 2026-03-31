import AppKit
import SwiftUI
import VoxTypeUI

@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    private static let defaultPanelSize = NSSize(width: 750, height: 520)
    fileprivate static let minimumPanelSize = NSSize(width: 600, height: 400)
    private static let dismissDelay: Duration = .milliseconds(250)
    private static let initialHideSuppressionInterval: TimeInterval = 0.40

    private var panel: NSPanel?
    private var previousApplication: NSRunningApplication?
    private var pendingHideTask: Task<Void, Never>?
    private var suppressAutomaticHideUntil: Date = .distantPast
    private var clickOutsideMonitor: Any?
    private var globalClickMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(model: AppModel) {
        if let panel, panel.isVisible {
            dismiss()
            return
        }

        pendingHideTask?.cancel()
        rememberPreviousApplication()
        suppressAutomaticHideUntil = Date().addingTimeInterval(Self.initialHideSuppressionInterval)
        let hostingController = FloatingClipboardHostingController(rootView: FloatingClipboardView(model: model))

        if let panel {
            panel.contentViewController = hostingController
            restorePanelSizeIfNeeded(panel)
            present(panel)
            return
        }

        let panel = FloatingClipboardPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultPanelSize),
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.onEscapePressed = { [weak self] in self?.dismiss() }
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
        panel.delegate = self
        centerOnActiveScreen(panel)
        self.panel = panel
        present(panel)
    }

    func dismiss() {
        pendingHideTask?.cancel()
        removeClickOutsideMonitor()
        guard let panel, panel.isVisible else { return }
        let previousApp = previousApplication
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.panel?.orderOut(nil)
                self?.panel?.alphaValue = 1  // Reset for next show
                if let previousApp {
                    previousApp.activate(options: [])
                }
            }
        }
    }

    func useSelectedItem(_ action: @escaping @Sendable () async -> Void) {
        pendingHideTask?.cancel()
        removeClickOutsideMonitor()
        panel?.orderOut(nil)
        let targetApplication = previousApplication
        Task { @MainActor in
            if let targetApplication {
                targetApplication.activate(options: [])
            }
            try? await Task.sleep(for: .milliseconds(140))
            await action()
        }
    }

    private func rememberPreviousApplication() {
        guard
            let frontmostApplication = NSWorkspace.shared.frontmostApplication,
            frontmostApplication.bundleIdentifier != Bundle.main.bundleIdentifier
        else {
            return
        }
        previousApplication = frontmostApplication
    }

    private func restorePreviousApplication() {
        guard let previousApplication else { return }
        previousApplication.activate(options: [])
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
        NSApp.activate(ignoringOtherApps: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        installClickOutsideMonitor()
    }

    private func centerOnActiveScreen(_ panel: NSPanel) {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - panel.frame.width / 2
        let y = visibleFrame.midY - panel.frame.height / 2 + visibleFrame.height * 0.1
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        // Local: clicks inside the app but outside the panel
        clickOutsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            let windowNumber = event.windowNumber
            if windowNumber != panel.windowNumber,
               !self.isChildOfPanel(NSApp.window(withWindowNumber: windowNumber)) {
                self.dismiss()
            }
            return event
        }
        // Global: clicks outside the app entirely (other apps, desktop, etc.)
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                guard Date() >= self.suppressAutomaticHideUntil else { return }
                self.dismiss()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }

    private func isChildOfPanel(_ window: NSWindow?) -> Bool {
        guard let panel, let window else { return false }
        if window === panel { return true }
        if window.parent === panel { return true }
        if panel.childWindows?.contains(window) ?? false { return true }
        if window.isKind(of: NSClassFromString("NSMenuWindowLevel") ?? NSWindow.self) { return true }
        // NSMenu, sheets, and popovers that belong to this panel
        if let sheetParent = window.sheetParent, sheetParent === panel { return true }
        return false
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        pendingHideTask?.cancel()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard Date() >= suppressAutomaticHideUntil else { return }

        pendingHideTask?.cancel()
        pendingHideTask = Task { @MainActor [weak self] in
            guard let self, self.panel != nil else { return }
            try? await Task.sleep(for: Self.dismissDelay)
            guard !Task.isCancelled else { return }

            // Keep open if a child window (menu, sheet, popover) took focus
            if NSApp.isActive, let keyWindow = NSApp.keyWindow, self.isChildOfPanel(keyWindow) {
                return
            }

            self.dismiss()
        }
    }

    func windowDidResignMain(_ notification: Notification) {
        pendingHideTask?.cancel()
        pendingHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            guard let self, let panel = self.panel, panel.isVisible else { return }
            guard !NSApp.isActive else { return }
            self.dismiss()
        }
    }

    func windowWillClose(_ notification: Notification) {
        removeClickOutsideMonitor()
    }
}

private final class FloatingClipboardPanel: NSPanel {
    var onEscapePressed: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

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
    @Bindable var model: AppModel

    var body: some View {
        ClipboardView(model: model)
            .frame(
                minWidth: ClipboardPanelController.minimumPanelSize.width,
                maxWidth: .infinity,
                minHeight: ClipboardPanelController.minimumPanelSize.height,
                maxHeight: .infinity
            )
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .top) {
                // Invisible drag handle at the top edge
                WindowDragHandle()
                    .frame(height: 8)
                    .frame(maxWidth: .infinity)
            }
    }
}
