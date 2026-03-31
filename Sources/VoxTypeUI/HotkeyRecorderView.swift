import AppKit
import SwiftUI
import VoxTypeCore

struct HotkeyRecorderView: View {
    let binding: HotkeyBindingDescriptor
    let language: AppLanguage
    let onRecord: (VoxTypeCore.KeyboardShortcut) -> Void
    let onReset: () -> Void

    @State private var isRecording = false
    @State private var localMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(currentBindingLabel)
                .font(.body.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 10) {
                Button(
                    isRecording
                        ? UIStrings.text(.clipboardPanelHotkeyRecording, language: language)
                        : UIStrings.text(.clipboardPanelHotkeyRecord, language: language)
                ) {
                    isRecording ? stopRecording() : startRecording()
                }

                Button(UIStrings.text(.clipboardPanelHotkeyReset, language: language)) {
                    stopRecording()
                    onReset()
                }
            }

            Text(UIStrings.text(.clipboardPanelHotkeyHint, language: language))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var currentBindingLabel: String {
        if isRecording {
            return UIStrings.text(.clipboardPanelHotkeyRecording, language: language)
        }

        switch binding {
        case .doubleCommand:
            return UIStrings.text(.clipboardPanelHotkeyDefault, language: language)
        case .keyboardShortcut(let shortcut):
            return format(shortcut)
        }
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleRecordingEvent(event)
        }
    }

    private func stopRecording() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        isRecording = false
    }

    private func handleRecordingEvent(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 {
            stopRecording()
            return nil
        }

        let modifiers = shortcutModifiers(from: event.modifierFlags)
        guard !modifiers.isEmpty else {
            NSSound.beep()
            return nil
        }

        guard !Self.modifierOnlyKeyCodes.contains(event.keyCode) else {
            return nil
        }

        onRecord(VoxTypeCore.KeyboardShortcut(keyCode: event.keyCode, modifiers: modifiers))
        stopRecording()
        return nil
    }

    private func shortcutModifiers(from flags: NSEvent.ModifierFlags) -> [VoxTypeCore.KeyboardShortcut.Modifier] {
        var modifiers: [VoxTypeCore.KeyboardShortcut.Modifier] = []
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

    private func format(_ shortcut: VoxTypeCore.KeyboardShortcut) -> String {
        shortcut.modifiers.map(Self.symbol(for:)).joined() + Self.keyLabel(for: shortcut.keyCode)
    }

    private static func symbol(for modifier: VoxTypeCore.KeyboardShortcut.Modifier) -> String {
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

    private static func keyLabel(for keyCode: UInt16) -> String {
        keyLabels[keyCode] ?? "Key \(keyCode)"
    }

    private static let modifierOnlyKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62]

    private static let keyLabels: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc",
        67: "*", 69: "+", 71: "Clear", 75: "/", 76: "Enter", 78: "-", 81: "=", 82: "0",
        83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13",
        106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Help", 115: "Home",
        116: "Page Up", 117: "Forward Delete", 118: "F4", 119: "End", 120: "F2", 121: "Page Down",
        122: "F1", 123: "Left", 124: "Right", 125: "Down", 126: "Up",
    ]
}
