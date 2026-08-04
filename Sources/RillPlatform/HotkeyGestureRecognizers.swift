import ApplicationServices
import Foundation
import RillCore

/// Recognizes one isolated pair of Command key taps using monotonic time.
///
/// Every unrelated key, modifier, pointer-down, or scroll event clears both the
/// active tap and the previous release. This prevents ordinary interaction
/// between two Command taps from being misinterpreted as a global shortcut.
struct DoubleCommandTapRecognizer {
    static let maximumPairGap: Duration = .milliseconds(350)
    static let maximumTapDuration: Duration = .milliseconds(350)
    static let leftCommandKeyCode: CGKeyCode = 55
    static let rightCommandKeyCode: CGKeyCode = 54

    private var armedKeyCode: CGKeyCode?
    private var pressAt: ContinuousClock.Instant?
    private var previousReleaseAt: ContinuousClock.Instant?

    mutating func reset() {
        armedKeyCode = nil
        pressAt = nil
        previousReleaseAt = nil
    }

    mutating func handle(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        at now: ContinuousClock.Instant
    ) -> Bool {
        guard type == .flagsChanged, Self.isCommandKey(keyCode) else {
            reset()
            return false
        }

        let relevantFlags = flags.intersection([
            .maskCommand,
            .maskControl,
            .maskAlternate,
            .maskShift,
            .maskSecondaryFn,
        ])
        if relevantFlags == .maskCommand {
            if let previousReleaseAt,
               previousReleaseAt.duration(to: now) > Self.maximumPairGap
            {
                self.previousReleaseAt = nil
            }
            armedKeyCode = keyCode
            pressAt = now
            return false
        }

        guard relevantFlags.isEmpty,
              armedKeyCode == keyCode,
              let pressAt
        else {
            reset()
            return false
        }
        armedKeyCode = nil
        self.pressAt = nil
        let tapDuration = pressAt.duration(to: now)
        guard tapDuration >= .zero,
              tapDuration <= Self.maximumTapDuration
        else {
            previousReleaseAt = nil
            return false
        }
        guard let previousReleaseAt else {
            self.previousReleaseAt = now
            return false
        }

        let interval = previousReleaseAt.duration(to: pressAt)
        self.previousReleaseAt = nil
        return interval >= .zero && interval <= Self.maximumPairGap
    }

    private static func isCommandKey(_ keyCode: CGKeyCode) -> Bool {
        keyCode == leftCommandKeyCode || keyCode == rightCommandKeyCode
    }
}

enum ClipboardPanelShortcutRecognizerOutput: Equatable {
    case passThrough
    case swallow(shouldEmit: Bool)
}

struct ClipboardPanelShortcutRecognizer {
    private var activeKeyCode: CGKeyCode?

    mutating func reset() {
        activeKeyCode = nil
    }

    mutating func handle(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        binding: HotkeyBindingDescriptor
    ) -> ClipboardPanelShortcutRecognizerOutput {
        if type == .keyUp {
            if activeKeyCode == keyCode {
                activeKeyCode = nil
                return .swallow(shouldEmit: false)
            }
            return .passThrough
        }

        if type == .keyDown, activeKeyCode == keyCode {
            // Once the original chord is consumed, keep every repeat for that
            // physical key inside the same latch even if a modifier is released
            // before key-up. Otherwise a late repeat can leak into the front app.
            return .swallow(shouldEmit: false)
        }

        guard type == .keyDown,
              case .keyboardShortcut(let shortcut) = binding,
              GlobalHotkeyPolicy.accepts(shortcut),
              keyCode == shortcut.keyCode
        else {
            return .passThrough
        }

        let relevantFlags = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        guard relevantFlags == Self.flags(for: shortcut.modifiers) else {
            return .passThrough
        }

        guard activeKeyCode != keyCode else {
            return .swallow(shouldEmit: false)
        }

        activeKeyCode = keyCode
        return .swallow(shouldEmit: true)
    }

    private static func flags(for modifiers: [KeyboardShortcut.Modifier]) -> CGEventFlags {
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
}

enum LiveAudioEscapeRecognizerOutput: Equatable {
    case passThrough
    case swallow(UUID?)
}

struct LiveAudioEscapeRecognizer {
    private var activeRunID: UUID?
    private var latchedRunID: UUID?

    mutating func setActiveRunID(_ runID: UUID?) {
        activeRunID = runID
    }

    mutating func reset() {
        activeRunID = nil
        latchedRunID = nil
    }

    mutating func resetLatch() {
        latchedRunID = nil
    }

    mutating func handle(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> LiveAudioEscapeRecognizerOutput {
        guard keyCode == HotkeyEventTap.escapeKeyCode else { return .passThrough }

        switch type {
        case .keyDown:
            if latchedRunID != nil {
                return .swallow(nil)
            }
            let disallowedModifiers = flags.intersection([
                .maskCommand,
                .maskControl,
                .maskAlternate,
                .maskShift,
            ])
            guard disallowedModifiers.isEmpty, let activeRunID else {
                return .passThrough
            }
            latchedRunID = activeRunID
            return .swallow(activeRunID)
        case .keyUp:
            guard latchedRunID != nil else { return .passThrough }
            latchedRunID = nil
            return .swallow(nil)
        default:
            return .passThrough
        }
    }
}

enum PushToTalkGestureRecognizerOutput: Equatable {
    case passThrough
    case swallow(HotkeyEventTap.Event?)
}

struct PushToTalkGestureRecognizer {
    private enum ActiveTrigger: Equatable {
        case functionKey
        case legacyShortcut
    }

    private enum FunctionKeyState {
        case up
        case modified
    }

    private static let functionFamilyKeyCodes: Set<CGKeyCode> = [
        // F1-F20. macOS adds maskSecondaryFn to these keys even when the
        // physical Fn/Globe key is not held.
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
        103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
        // Arrow and navigation keys carry the same synthetic flag.
        123, 124, 125, 126, 114, 115, 116, 117, 119, 121,
    ]
    private static let modifierKeyCodes: Set<CGKeyCode> = [
        // Caps Lock plus the left/right Command, Shift, Option, and Control keys.
        57, 54, 55, 56, 60, 58, 61, 59, 62,
    ]

    private var activeTrigger: ActiveTrigger?
    private var functionKeyState = FunctionKeyState.up
    private var interruptionReleaseEmitted = false

    var activeGesture: HotkeyEventTap.PushToTalkGesture? {
        switch activeTrigger {
        case .functionKey:
            return .fnHold
        case .legacyShortcut:
            return .controlOptionShiftSpace
        case nil:
            return nil
        }
    }

    var interruptedActiveGesture: HotkeyEventTap.PushToTalkGesture? {
        interruptionReleaseEmitted ? activeGesture : nil
    }

    mutating func clearInterruptedActiveTrigger() {
        guard interruptionReleaseEmitted else { return }
        activeTrigger = nil
        interruptionReleaseEmitted = false
    }

    mutating func interrupt(
        preservingActiveTrigger: Bool = false
    ) -> HotkeyEventTap.Event? {
        guard let activeGesture else {
            if !preservingActiveTrigger {
                functionKeyState = .up
            }
            return nil
        }
        guard !interruptionReleaseEmitted else {
            if !preservingActiveTrigger {
                activeTrigger = nil
                interruptionReleaseEmitted = false
                return .pushToTalkReleased(activeGesture)
            }
            return nil
        }
        if preservingActiveTrigger {
            interruptionReleaseEmitted = true
        } else {
            activeTrigger = nil
            interruptionReleaseEmitted = false
        }
        return .pushToTalkReleased(activeGesture)
    }

    mutating func handle(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> PushToTalkGestureRecognizerOutput {
        switch type {
        case .flagsChanged:
            return handleFunctionKeyChange(keyCode: keyCode, flags: flags)
        case .keyDown:
            return handleLegacyShortcutKeyDown(keyCode: keyCode, flags: flags)
        case .keyUp:
            return handleLegacyShortcutKeyUp(keyCode: keyCode)
        default:
            return .passThrough
        }
    }

    private mutating func handleFunctionKeyChange(
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> PushToTalkGestureRecognizerOutput {
        let isFunctionKeyPressed = flags.contains(.maskSecondaryFn)
        let hasOtherModifiers = !flags.intersection([
            .maskCommand,
            .maskControl,
            .maskAlternate,
            .maskShift,
        ]).isEmpty
        switch activeTrigger {
        case .functionKey:
            if isFunctionKeyPressed {
                return .swallow(nil)
            }
            activeTrigger = nil
            functionKeyState = .up
            interruptionReleaseEmitted = false
            return .swallow(.pushToTalkReleased(.fnHold))
        case .legacyShortcut:
            return .passThrough
        case nil:
            guard isFunctionKeyPressed else {
                functionKeyState = .up
                return .passThrough
            }
            guard !hasOtherModifiers else {
                functionKeyState = .modified
                return .passThrough
            }
            guard functionKeyState != .modified,
                  Self.isPhysicalFunctionKeyTransition(keyCode)
            else {
                return .passThrough
            }
            activeTrigger = .functionKey
            interruptionReleaseEmitted = false
            return .swallow(.pushToTalkPressed(.fnHold))
        }
    }

    private static func isPhysicalFunctionKeyTransition(_ keyCode: CGKeyCode) -> Bool {
        if keyCode == HotkeyEventTap.functionKeyCode || keyCode == HotkeyEventTap.globeKeyCode {
            return true
        }
        return !functionFamilyKeyCodes.contains(keyCode)
            && !modifierKeyCodes.contains(keyCode)
    }

    private mutating func handleLegacyShortcutKeyDown(
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> PushToTalkGestureRecognizerOutput {
        guard keyCode == HotkeyEventTap.legacyPushToTalkKeyCode else {
            return .passThrough
        }

        let relevantFlags = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        guard relevantFlags == HotkeyEventTap.legacyPushToTalkModifiers else {
            return .passThrough
        }

        switch activeTrigger {
        case nil:
            activeTrigger = .legacyShortcut
            interruptionReleaseEmitted = false
            return .swallow(.pushToTalkPressed(.controlOptionShiftSpace))
        case .legacyShortcut:
            return .swallow(nil)
        case .functionKey:
            return .passThrough
        }
    }

    private mutating func handleLegacyShortcutKeyUp(
        keyCode: CGKeyCode
    ) -> PushToTalkGestureRecognizerOutput {
        guard keyCode == HotkeyEventTap.legacyPushToTalkKeyCode else {
            return .passThrough
        }

        guard activeTrigger == .legacyShortcut else {
            return .passThrough
        }

        activeTrigger = nil
        interruptionReleaseEmitted = false
        return .swallow(.pushToTalkReleased(.controlOptionShiftSpace))
    }
}
