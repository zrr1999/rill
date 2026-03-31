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
        if let shortcut = KeyboardShortcut(storageString: storageString) {
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
