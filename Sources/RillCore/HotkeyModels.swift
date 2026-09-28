import Foundation

public struct KeyboardShortcut: Sendable, Equatable {
    public enum Modifier: String, CaseIterable, Sendable {
        case command
        case control
        case option
        case shift

        fileprivate static let orderedCases: [Modifier] = [.control, .option, .shift, .command]
    }

    public var keyCode: UInt16
    public var modifiers: [Modifier]

    public init(keyCode: UInt16, modifiers: [Modifier]) {
        self.keyCode = keyCode
        self.modifiers = Self.normalize(modifiers)
    }

    public init?(storageString: String) {
        let components = storageString.split(separator: "|", omittingEmptySubsequences: false)
        guard
            components.count == 2,
            let keyCode = UInt16(components[1])
        else {
            return nil
        }

        let modifiers = components[0]
            .split(separator: "+")
            .compactMap { Modifier(rawValue: String($0)) }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    public var storageString: String {
        "\(modifiers.map(\.rawValue).joined(separator: "+"))|\(keyCode)"
    }

    private static func normalize(_ modifiers: [Modifier]) -> [Modifier] {
        var seen = Set<Modifier>()
        return Modifier.orderedCases.filter { modifier in
            guard modifiers.contains(modifier), !seen.contains(modifier) else { return false }
            seen.insert(modifier)
            return true
        }
    }
}

public extension KeyboardShortcut {
    static let outputNext = KeyboardShortcut(keyCode: 9, modifiers: [.command, .shift])
}

public enum GlobalHotkeyPolicy {
    public enum Rejection: Sendable, Equatable {
        case missingModifier
        case modifierOnlyTyping
        case standardApplicationShortcut
        case systemReserved
        case rillReserved
    }

    public static func rejection(for shortcut: KeyboardShortcut) -> Rejection? {
        guard !shortcut.modifiers.isEmpty else {
            return .missingModifier
        }

        if systemReservedShortcuts.contains(where: { $0.matches(shortcut) }) {
            return .systemReserved
        }

        if shortcut.keyCode == legacyPushToTalkKeyCode,
           shortcut.modifiers == [.control, .option, .shift]
        {
            return .rillReserved
        }

        // Command-only chords are the standard macOS application command space.
        // A session-wide event tap must not repurpose them in whichever app has focus.
        if shortcut.modifiers == [.command] {
            return .standardApplicationShortcut
        }

        // A single Shift, Option, or Control modifier still changes normal text
        // entry or common editor commands in the foreground application. Require a
        // deliberate multi-modifier chord for a session-wide event tap.
        if shortcut.modifiers.count == 1 {
            return .modifierOnlyTyping
        }

        return nil
    }

    public static func accepts(_ shortcut: KeyboardShortcut) -> Bool {
        rejection(for: shortcut) == nil
    }

    private struct ShortcutSignature {
        let keyCode: UInt16
        let modifiers: [KeyboardShortcut.Modifier]

        func matches(_ shortcut: KeyboardShortcut) -> Bool {
            shortcut.keyCode == keyCode && shortcut.modifiers == modifiers
        }
    }

    // Key codes use the stable macOS virtual-key layout already persisted by Rill.
    // Keep this list limited to session/lifecycle and system-navigation commands whose
    // interception would be especially surprising or destructive.
    private static let systemReservedShortcuts: [ShortcutSignature] = [
        .init(keyCode: 12, modifiers: [.command]), // Quit (Command-Q).
        .init(keyCode: 13, modifiers: [.command]), // Close window (Command-W).
        .init(keyCode: 48, modifiers: [.command]), // Switch application (Command-Tab).
        .init(keyCode: 49, modifiers: [.command]), // Spotlight (Command-Space).
        .init(keyCode: 49, modifiers: [.option, .command]), // Spotlight results.
        .init(keyCode: 49, modifiers: [.control, .command]), // Character viewer.
        .init(keyCode: 50, modifiers: [.command]), // Cycle windows (Command-`).
        .init(keyCode: 53, modifiers: [.option, .command]), // Force Quit.
        .init(keyCode: 12, modifiers: [.control, .command]), // Lock screen.
        .init(keyCode: 12, modifiers: [.shift, .command]), // Log out with confirmation.
        .init(keyCode: 12, modifiers: [.option, .shift, .command]), // Log out immediately.
    ]

    private static let legacyPushToTalkKeyCode: UInt16 = 49
}

public enum HotkeyBindingDescriptor: Sendable, Equatable {
    case doubleCommand
    case keyboardShortcut(KeyboardShortcut)

    public init(storageString: String?) {
        guard let storageString, !storageString.isEmpty else {
            self = .doubleCommand
            return
        }
        if storageString == "double-command" {
            self = .doubleCommand
            return
        }
        if let shortcut = KeyboardShortcut(storageString: storageString),
           GlobalHotkeyPolicy.accepts(shortcut)
        {
            self = .keyboardShortcut(shortcut)
            return
        }
        self = .doubleCommand
    }

    public var storageString: String {
        switch self {
        case .doubleCommand:
            return "double-command"
        case .keyboardShortcut(let shortcut):
            return shortcut.storageString
        }
    }
}
