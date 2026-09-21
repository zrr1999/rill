import AppKit
import SwiftUI
import RillCore

enum HotkeyRecorderInputDecision: Equatable {
    case ignore
    case cancel
    case moveFocus(forward: Bool)
    case record(RillCore.KeyboardShortcut)
    case reject
}

enum HotkeyRecorderInputPolicy {
    static func decision(
        keyCode: UInt16,
        modifiers: [RillCore.KeyboardShortcut.Modifier]
    ) -> HotkeyRecorderInputDecision {
        switch keyCode {
        case 53:
            return .cancel
        case 48:
            return .moveFocus(forward: !modifiers.contains(.shift))
        default:
            break
        }

        guard !modifierOnlyKeyCodes.contains(keyCode) else {
            return .ignore
        }
        guard !modifiers.isEmpty else {
            return .reject
        }

        let shortcut = RillCore.KeyboardShortcut(
            keyCode: keyCode,
            modifiers: modifiers
        )
        guard GlobalHotkeyPolicy.accepts(shortcut) else {
            return .reject
        }
        return .record(shortcut)
    }

    private static let modifierOnlyKeyCodes: Set<UInt16> = [
        54, 55, 56, 57, 58, 59, 60, 61, 62,
    ]
}

enum HotkeyCaptureFocusMove {
    static func perform(
        restoring previousResponder: NSResponder,
        restore: (NSResponder) -> Bool,
        currentFirstResponder: () -> NSResponder?,
        move: (NSResponder) -> Void
    ) {
        guard restore(previousResponder) else { return }
        guard let currentResponder = currentFirstResponder() else { return }
        move(currentResponder)
    }
}

struct HotkeyRecorderView: View {
    let binding: HotkeyBindingDescriptor
    let language: AppLanguage
    let beginRecordPanelShortcutRecording: () -> UUID
    let endRecordPanelShortcutRecording: (UUID) -> Void
    let commitRecordPanelShortcutRecording: (UUID, UInt16) -> Void
    let onRecord: (RillCore.KeyboardShortcut) -> Void
    let onReset: () -> Void

    @State private var isRecording = false
    @State private var recordingSuspensionID: UUID?
    @State private var focusRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: RillSpacing.row) {
            Button {
                startRecording()
            } label: {
                Text(currentBindingLabel)
                    .font(.body.weight(.medium))
                    .padding(.horizontal, RillSpacing.card)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            // RillCard regular-tier fill; asymmetric padding keeps this manual.
            .background {
                let shape = RoundedRectangle(cornerRadius: RillRadius.row, style: .continuous)
                if isRecording {
                    shape.fill(Color.accentColor.opacity(0.12))
                } else {
                    shape.fill(.quaternary.opacity(RillCardProminence.regular.fillOpacity))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: RillRadius.row, style: .continuous)
                    .strokeBorder(
                        Color.accentColor.opacity(isRecording ? 0.5 : 0),
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: RillRadius.row, style: .continuous))
            .accessibilityLabel(UIStrings.text(.recordPanelHotkeyRecorderLabel, language: language))
            .accessibilityValue(Text(currentBindingLabel))
            .accessibilityIdentifier("settings.clipboard-hotkey.keycap")
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isRecording)

            HStack(spacing: 10) {
                Button(
                    UIStrings.text(
                        isRecording
                            ? .recordPanelHotkeyRecording
                            : .recordPanelHotkeyRecord,
                        language: language
                    )
                ) {
                    isRecording ? cancelRecording() : startRecording()
                }
                .accessibilityLabel(UIStrings.text(.recordPanelHotkeyRecorderLabel, language: language))
                .accessibilityValue(Text(currentBindingLabel))
                .accessibilityHint(UIStrings.text(.recordPanelHotkeyHint, language: language))
                .accessibilityIdentifier("settings.clipboard-hotkey.record")

                Button(UIStrings.text(.recordPanelHotkeyReset, language: language)) {
                    cancelRecording()
                    onReset()
                }
                .help(L10n.settingsText(.settingsHotkeyResetHelp, language: language))
                .accessibilityIdentifier("settings.clipboard-hotkey.reset")
            }

            Text(UIStrings.text(.recordPanelHotkeyHint, language: language))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .overlay(alignment: .topLeading) {
            HotkeyCaptureResponder(
                isCaptureActive: isRecording,
                focusRequest: focusRequest,
                onDecision: handleRecordingDecision,
                onFocusLost: cancelRecording
            )
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
        }
        .onDisappear {
            cancelRecording()
        }
    }

    private var currentBindingLabel: String {
        if isRecording {
            return UIStrings.text(.recordPanelHotkeyRecording, language: language)
        }

        switch binding {
        case .doubleCommand:
            return UIStrings.text(.recordPanelHotkeyDefault, language: language)
        case .keyboardShortcut(let shortcut):
            return format(shortcut)
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        recordingSuspensionID = beginRecordPanelShortcutRecording()
        isRecording = true
        focusRequest &+= 1
    }

    private func cancelRecording() {
        finishRecording()
    }

    private func finishRecording() {
        isRecording = false
        guard let recordingSuspensionID else { return }
        self.recordingSuspensionID = nil
        endRecordPanelShortcutRecording(recordingSuspensionID)
    }

    private func handleRecordingDecision(_ decision: HotkeyRecorderInputDecision) {
        switch decision {
        case .ignore:
            break
        case .cancel, .moveFocus:
            cancelRecording()
        case .record(let shortcut):
            guard let recordingSuspensionID else { return }
            self.recordingSuspensionID = nil
            isRecording = false
            // Install the binding before transferring the recorder lease to the
            // event tap. That lease keeps repeats inside the same physical press
            // until its matching key-up and keeps new global voice presses from
            // racing the recorder's focus restoration.
            onRecord(shortcut)
            commitRecordPanelShortcutRecording(
                recordingSuspensionID,
                shortcut.keyCode
            )
        case .reject:
            NSSound.beep()
        }
    }

    private func format(_ shortcut: RillCore.KeyboardShortcut) -> String {
        shortcut.modifiers.map(Self.symbol(for:)).joined() + keyLabel(for: shortcut.keyCode)
    }

    private static func symbol(for modifier: RillCore.KeyboardShortcut.Modifier) -> String {
        switch modifier {
        case .command:
            return "⌘"
        case .control:
            return "⌃"
        case .option:
            return "⌥"
        case .shift:
            return "⇧"
        }
    }

    private func keyLabel(for keyCode: UInt16) -> String {
        if let namedKey = Self.namedKeyTextKeys[keyCode] {
            return L10n.settingsText(namedKey, language: language)
        }
        return Self.keyGlyphs[keyCode]
            ?? String(
                format: L10n.settingsText(.settingsHotkeyKeyUnknownFormat, language: language),
                Int(keyCode)
            )
    }

    /// Named keys are localized; letters, digits, symbols, and F-keys keep
    /// their physical glyphs.
    private static let namedKeyTextKeys: [UInt16: SettingsTextKey] = [
        36: .settingsHotkeyKeyReturn, 48: .settingsHotkeyKeyTab, 49: .settingsHotkeyKeySpace,
        51: .settingsHotkeyKeyDelete, 53: .settingsHotkeyKeyEsc, 71: .settingsHotkeyKeyClear,
        76: .settingsHotkeyKeyEnter, 114: .settingsHotkeyKeyHelp, 115: .settingsHotkeyKeyHome,
        116: .settingsHotkeyKeyPageUp, 117: .settingsHotkeyKeyForwardDelete,
        119: .settingsHotkeyKeyEnd, 121: .settingsHotkeyKeyPageDown,
        123: .settingsHotkeyKeyLeft, 124: .settingsHotkeyKeyRight,
        125: .settingsHotkeyKeyDown, 126: .settingsHotkeyKeyUp,
    ]

    private static let keyGlyphs: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 50: "`",
        67: "*", 69: "+", 75: "/", 78: "-", 81: "=", 82: "0",
        83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13",
        106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        118: "F4", 120: "F2", 122: "F1",
    ]
}

private struct HotkeyCaptureResponder: NSViewRepresentable {
    let isCaptureActive: Bool
    let focusRequest: Int
    let onDecision: (HotkeyRecorderInputDecision) -> Void
    let onFocusLost: () -> Void

    func makeNSView(context: Context) -> HotkeyCaptureView {
        HotkeyCaptureView()
    }

    func updateNSView(_ view: HotkeyCaptureView, context: Context) {
        view.onDecision = onDecision
        view.onFocusLost = onFocusLost
        view.updateCaptureState(
            isActive: isCaptureActive,
            focusRequest: focusRequest
        )
    }

    static func dismantleNSView(_ view: HotkeyCaptureView, coordinator: ()) {
        view.shutdown()
    }
}

final class HotkeyCaptureView: NSView {
    private enum DeferredRestoreReason: Hashable {
        case applicationInactive
        case windowNotKey
    }

    var onDecision: ((HotkeyRecorderInputDecision) -> Void)?
    var onFocusLost: (() -> Void)?
    var applicationIsActiveProvider: () -> Bool = { NSApp.isActive }
    var windowIsKeyProvider: (NSWindow) -> Bool = { $0.isKeyWindow }

    private var isCaptureActive = false
    private var requestedFocus = 0
    private var appliedFocus = 0
    private weak var responderBeforeCapture: NSResponder?
    private weak var observedWindow: NSWindow?
    private var deferredRestoreReasons: Set<DeferredRestoreReason> = []

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        observeApplicationFocus()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observeApplicationFocus()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func updateCaptureState(isActive: Bool, focusRequest: Int) {
        if isActive, focusRequest != requestedFocus {
            abandonDeferredResponderRestore()
        }
        requestedFocus = focusRequest
        if isActive {
            isCaptureActive = true
            applyRequestedFocusIfPossible()
        } else {
            isCaptureActive = false
            if deferredRestoreReasons.isEmpty {
                restoreResponderAfterControlledFinish()
            }
        }
    }

    func shutdown() {
        cancelAndAbandonCapture()
        NotificationCenter.default.removeObserver(self)
        observedWindow = nil
        responderBeforeCapture = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let previousWindow = observedWindow
        updateWindowObservation()
        if let previousWindow, previousWindow !== window {
            if isCaptureActive {
                cancelAndAbandonCapture()
            } else {
                abandonDeferredResponderRestore()
            }
            return
        }
        applyRequestedFocusIfPossible()
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign, isCaptureActive {
            // Without an earlier deactivation notification, this is a
            // user-owned focus transition. Cancel the recorder, but never
            // restore the responder that preceded capture.
            cancelAndAbandonCapture()
        }
        return didResign
    }

    override func keyDown(with event: NSEvent) {
        guard handleCaptureKeyEvent(event) else {
            super.keyDown(with: event)
            return
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, handleCaptureKeyEvent(event) else {
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    private func handleCaptureKeyEvent(_ event: NSEvent) -> Bool {
        guard isCaptureActive else { return false }
        let decision = HotkeyRecorderInputPolicy.decision(
            keyCode: event.keyCode,
            modifiers: Self.shortcutModifiers(from: event.modifierFlags)
        )
        switch decision {
        case .ignore, .reject:
            onDecision?(decision)
        case .cancel, .record:
            finishCapture(decision, focusMove: nil)
        case .moveFocus(let forward):
            finishCapture(decision, focusMove: forward)
        }
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        guard isCaptureActive else {
            super.cancelOperation(sender)
            return
        }
        finishCapture(.cancel, focusMove: nil)
    }

    @objc
    private func applicationWillResignActive() {
        deferResponderRestore(for: .applicationInactive)
    }

    @objc
    private func applicationDidBecomeActive() {
        completeDeferredResponderRestore(for: .applicationInactive)
    }

    @objc
    private func windowDidResignKey() {
        deferResponderRestore(for: .windowNotKey)
    }

    @objc
    private func windowDidBecomeKey() {
        completeDeferredResponderRestore(for: .windowNotKey)
    }

    private func finishCapture(
        _ decision: HotkeyRecorderInputDecision,
        focusMove: Bool?
    ) {
        guard isCaptureActive else { return }
        isCaptureActive = false
        deferredRestoreReasons.removeAll()
        let previousResponder = responderBeforeCapture
        responderBeforeCapture = nil
        onDecision?(decision)

        guard let window else { return }
        let currentResponder = Self.liveResponder(window.firstResponder, in: window)
        if let currentResponder, currentResponder !== self {
            if let focusMove {
                moveFocus(from: currentResponder, forward: focusMove, in: window)
            }
            return
        }

        let restorationResponder = Self.liveResponder(previousResponder, in: window)
            ?? fallbackResponder(in: window, forward: focusMove ?? true)
        if let focusMove {
            if let restorationResponder {
                HotkeyCaptureFocusMove.perform(
                    restoring: restorationResponder,
                    restore: { window.makeFirstResponder($0) },
                    currentFirstResponder: { window.firstResponder },
                    move: { moveFocus(from: $0, forward: focusMove, in: window) }
                )
            } else {
                moveFocus(from: self, forward: focusMove, in: window)
            }
            ensureLiveFallbackResponder(in: window, forward: focusMove)
            return
        }

        if let restorationResponder {
            _ = window.makeFirstResponder(restorationResponder)
        }
        ensureLiveFallbackResponder(in: window, forward: true)
    }

    private func applyRequestedFocusIfPossible() {
        guard isCaptureActive, requestedFocus != appliedFocus, let window else { return }
        guard applicationIsActiveProvider(), windowIsKeyProvider(window) else {
            cancelAndAbandonCapture()
            return
        }
        let previousResponder = window.firstResponder
        guard window.makeFirstResponder(self) else {
            cancelAndAbandonCapture()
            return
        }
        responderBeforeCapture = previousResponder
        appliedFocus = requestedFocus
    }

    private func restoreResponderAfterControlledFinish() {
        let previousResponder = responderBeforeCapture
        responderBeforeCapture = nil
        guard let window,
              window.firstResponder === self else {
            return
        }
        let restorationResponder = Self.liveResponder(previousResponder, in: window)
            ?? fallbackResponder(in: window, forward: true)
        if let restorationResponder {
            _ = window.makeFirstResponder(restorationResponder)
        }
        ensureLiveFallbackResponder(in: window, forward: true)
    }

    private func deferResponderRestore(for reason: DeferredRestoreReason) {
        if !isCaptureActive {
            if !deferredRestoreReasons.isEmpty {
                deferredRestoreReasons.insert(reason)
            }
            return
        }

        isCaptureActive = false
        deferredRestoreReasons.insert(reason)
        onFocusLost?()
    }

    private func completeDeferredResponderRestore(for reason: DeferredRestoreReason) {
        guard deferredRestoreReasons.remove(reason) != nil,
              deferredRestoreReasons.isEmpty else {
            return
        }

        let previousResponder = responderBeforeCapture
        responderBeforeCapture = nil
        guard let window,
              window.firstResponder === self else {
            return
        }
        let restorationResponder = Self.liveResponder(previousResponder, in: window)
            ?? fallbackResponder(in: window, forward: true)
        if let restorationResponder {
            _ = window.makeFirstResponder(restorationResponder)
        }
        ensureLiveFallbackResponder(in: window, forward: true)
    }

    private func ensureLiveFallbackResponder(
        in window: NSWindow,
        forward: Bool
    ) {
        if Self.liveResponder(window.firstResponder, in: window) != nil,
           window.firstResponder !== self {
            return
        }
        guard let fallback = fallbackResponder(in: window, forward: forward) else {
            return
        }
        _ = window.makeFirstResponder(fallback)
    }

    private func fallbackResponder(
        in window: NSWindow,
        forward: Bool
    ) -> NSResponder? {
        if let initial = Self.liveResponder(window.initialFirstResponder, in: window),
           initial !== self {
            return initial
        }

        var cursor: NSView? = forward ? nextValidKeyView : previousValidKeyView
        var visited: Set<ObjectIdentifier> = []
        while let candidate = cursor {
            let identifier = ObjectIdentifier(candidate)
            guard visited.insert(identifier).inserted else { break }
            if candidate !== self,
               let liveCandidate = Self.liveResponder(candidate, in: window) {
                return liveCandidate
            }
            cursor = forward ? candidate.nextValidKeyView : candidate.previousValidKeyView
        }

        return Self.liveResponder(window.contentView, in: window)
    }

    private func moveFocus(
        from responder: NSResponder,
        forward: Bool,
        in window: NSWindow
    ) {
        if forward {
            window.selectNextKeyView(responder)
        } else {
            window.selectPreviousKeyView(responder)
        }
    }

    private static func liveResponder(
        _ responder: NSResponder?,
        in window: NSWindow
    ) -> NSResponder? {
        guard let responder else { return nil }
        if let fieldEditor = responder as? NSTextView,
           fieldEditor.isFieldEditor,
           let control = fieldEditor.delegate as? NSView {
            guard control.window === window,
                  !control.isHiddenOrHasHiddenAncestor else {
                return nil
            }
            return control
        }
        guard let view = responder as? NSView,
              view.window === window,
              !view.isHiddenOrHasHiddenAncestor else {
            return nil
        }
        return view
    }

    private func cancelAndAbandonCapture() {
        let shouldNotify = isCaptureActive
        isCaptureActive = false
        deferredRestoreReasons.removeAll()
        responderBeforeCapture = nil
        if shouldNotify {
            onFocusLost?()
        }
    }

    private func abandonDeferredResponderRestore() {
        deferredRestoreReasons.removeAll()
        responderBeforeCapture = nil
    }

    private func observeApplicationFocus() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: NSApplication.willResignActiveNotification,
            object: NSApplication.shared
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApplication.shared
        )
    }

    private func updateWindowObservation() {
        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didResignKeyNotification,
                object: observedWindow
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didBecomeKeyNotification,
                object: observedWindow
            )
        }
        observedWindow = window
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
        }
    }

    private static func shortcutModifiers(
        from flags: NSEvent.ModifierFlags
    ) -> [RillCore.KeyboardShortcut.Modifier] {
        var modifiers: [RillCore.KeyboardShortcut.Modifier] = []
        if flags.contains(.control) {
            modifiers.append(.control)
        }
        if flags.contains(.option) {
            modifiers.append(.option)
        }
        if flags.contains(.shift) {
            modifiers.append(.shift)
        }
        if flags.contains(.command) {
            modifiers.append(.command)
        }
        return modifiers
    }
}
