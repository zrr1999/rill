import ApplicationServices
import Foundation
import VoxTypeCore

public final class HotkeyEventTap: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        case manualPasteInterceptRequested
        case clipboardPanelRequested
        case pushToTalkPressed
        case pushToTalkReleased
        case customHotkey(String)
    }

    private static let pasteKeyCode: CGKeyCode = 9
    private static let pushToTalkKeyCode: CGKeyCode = 49
    private static let pushToTalkModifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]
    private static let leftCommandKeyCode: CGKeyCode = 55
    private static let rightCommandKeyCode: CGKeyCode = 54
    private static let commandDoubleTapInterval: TimeInterval = 0.35
    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let tap = Unmanaged<HotkeyEventTap>.fromOpaque(userInfo).takeUnretainedValue()
        return tap.handle(type: type, event: event)
    }

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedSelfPointer: UnsafeMutableRawPointer?
    private var pasteInterceptEnabled = false
    private var skippedPasteEvents = 0
    private var commandTapReleaseAt: Date?
    private var commandTapArmed = false
    private var clipboardPanelHotkeyBinding: HotkeyBindingDescriptor = .doubleCommand

    public init() {}

    deinit {
        uninstall()
    }

    public func stream() -> AsyncStream<Event> {
        let id = UUID()
        return AsyncStream { continuation in
            withLock {
                continuations[id] = continuation
            }
            continuation.onTermination = { [weak self, id] _ in
                self?.removeContinuation(id)
            }
        }
    }

    public func setPasteInterceptEnabled(_ enabled: Bool) {
        withLock {
            pasteInterceptEnabled = enabled
        }
    }

    public func skipNextPasteInterception(count: Int = 1) {
        guard count > 0 else { return }
        withLock {
            skippedPasteEvents += count
        }
    }

    public func setClipboardPanelHotkeyBinding(_ binding: HotkeyBindingDescriptor) {
        withLock {
            clipboardPanelHotkeyBinding = binding
            commandTapArmed = false
        }
    }

    @discardableResult
    public func install() -> Bool {
        if Thread.isMainThread {
            return installOnMainRunLoop()
        }
        return DispatchQueue.main.sync {
            installOnMainRunLoop()
        }
    }

    public func uninstall() {
        if Thread.isMainThread {
            uninstallFromMainRunLoop()
            return
        }

        DispatchQueue.main.sync {
            uninstallFromMainRunLoop()
        }
    }

    private func installOnMainRunLoop() -> Bool {
        guard eventTap == nil else { return true }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.callback,
            userInfo: Unmanaged.passRetained(self).toOpaque()
        ) else {
            return false
        }

        retainedSelfPointer = Unmanaged.passUnretained(self).toOpaque()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    private func uninstallFromMainRunLoop() {
        guard let tap = eventTap else { return }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(tap)
        runLoopSource = nil
        eventTap = nil

        if let pointer = retainedSelfPointer {
            retainedSelfPointer = nil
            Unmanaged<HotkeyEventTap>.fromOpaque(pointer).release()
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            if type == .flagsChanged {
                return handleFlagsChanged(event)
            }
            if type == .keyUp, isPushToTalkEvent(event) {
                emit(.pushToTalkReleased)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        disarmCommandTapIfNeeded(for: event)

        if isPushToTalkEvent(event) {
            emit(.pushToTalkPressed)
            return nil
        }

        if matchesClipboardPanelShortcut(event) {
            emit(.clipboardPanelRequested)
            return nil
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == Self.pasteKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        guard event.flags.contains(.maskCommand), isPasteInterceptEnabled else {
            return Unmanaged.passUnretained(event)
        }

        if shouldAllowBypassedPasteEvent() {
            return Unmanaged.passUnretained(event)
        }

        emit(.manualPasteInterceptRequested)
        return nil
    }

    private var isPasteInterceptEnabled: Bool {
        withLock {
            pasteInterceptEnabled
        }
    }

    private func emit(_ event: Event) {
        let activeContinuations = withLock {
            Array(continuations.values)
        }
        for continuation in activeContinuations {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        withLock {
            continuations.removeValue(forKey: id)
        }
    }

    private func shouldAllowBypassedPasteEvent() -> Bool {
        withLock {
            guard skippedPasteEvents > 0 else { return false }
            skippedPasteEvents -= 1
            return true
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == Self.leftCommandKeyCode || keyCode == Self.rightCommandKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        guard usesDoubleCommandClipboardShortcut else {
            withLock {
                commandTapArmed = false
            }
            return Unmanaged.passUnretained(event)
        }

        let relevantFlags = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        if relevantFlags == .maskCommand {
            withLock {
                commandTapArmed = true
            }
            return Unmanaged.passUnretained(event)
        }

        let shouldEmit = withLock { () -> Bool in
            guard commandTapArmed else { return false }
            commandTapArmed = false
            guard relevantFlags.isEmpty else { return false }
            let now = Date()
            defer { commandTapReleaseAt = now }
            guard let previousReleaseAt = commandTapReleaseAt else { return false }
            return now.timeIntervalSince(previousReleaseAt) <= Self.commandDoubleTapInterval
        }

        if shouldEmit {
            emit(.clipboardPanelRequested)
        }
        return Unmanaged.passUnretained(event)
    }

    private func isPushToTalkEvent(_ event: CGEvent) -> Bool {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == Self.pushToTalkKeyCode else {
            return false
        }

        let relevantFlags = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        return relevantFlags == Self.pushToTalkModifiers
    }

    private func disarmCommandTapIfNeeded(for event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode != Self.leftCommandKeyCode, keyCode != Self.rightCommandKeyCode else { return }
        withLock {
            commandTapArmed = false
        }
    }

    private var usesDoubleCommandClipboardShortcut: Bool {
        withLock {
            if case .doubleCommand = clipboardPanelHotkeyBinding {
                return true
            }
            return false
        }
    }

    private func matchesClipboardPanelShortcut(_ event: CGEvent) -> Bool {
        let binding = withLock { clipboardPanelHotkeyBinding }
        guard case .keyboardShortcut(let shortcut) = binding else {
            return false
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == shortcut.keyCode else {
            return false
        }

        let relevantFlags = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        return relevantFlags == flags(for: shortcut.modifiers)
    }

    private func flags(for modifiers: [KeyboardShortcut.Modifier]) -> CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) { flags, modifier in
            switch modifier {
            case .command:
                flags.insert(.maskCommand)
            case .control:
                flags.insert(.maskControl)
            case .option:
                flags.insert(.maskAlternate)
            case .shift:
                flags.insert(.maskShift)
            }
        }
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
