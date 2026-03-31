import ApplicationServices
import Foundation
import VoxTypeCore

public actor TextInjectionEngine {
    static let maximumKeyboardEventLength = 20

    public enum InjectionMethod: Sendable {
        case clipboardPaste
        case keyboard
    }

    public enum InjectionError: Error, LocalizedError, Equatable {
        case accessibilityPermissionRequired
        case unableToCreatePasteEvent
        case unableToCreateKeyboardEvent

        public var errorDescription: String? {
            switch self {
            case .accessibilityPermissionRequired:
                return "Accessibility permission is required for text injection."
            case .unableToCreatePasteEvent:
                return "Unable to create the paste event for text injection."
            case .unableToCreateKeyboardEvent:
                return "Unable to create keyboard events for text injection."
            }
        }
    }

    public init(
        pasteboard: PasteboardController,
        accessibilityChecker: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.pasteboard = pasteboard
        self.accessibilityChecker = accessibilityChecker
    }

    private let pasteboard: PasteboardController
    private let accessibilityChecker: @Sendable () -> Bool

    static func utf16Chunks(for text: String, maxLength: Int = maximumKeyboardEventLength) -> [[UInt16]] {
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty else { return [] }
        return stride(from: 0, to: utf16.count, by: maxLength).map { offset in
            Array(utf16[offset..<Swift.min(offset + maxLength, utf16.count)])
        }
    }

    public func inject(
        _ text: String,
        method: InjectionMethod = .clipboardPaste
    ) async throws {
        guard !text.isEmpty else { return }
        guard accessibilityChecker() else {
            throw InjectionError.accessibilityPermissionRequired
        }

        switch method {
        case .clipboardPaste:
            let snapshot = await pasteboard.currentSnapshot()
            let changeCount = await pasteboard.writePlainText(text)
            try await pasteCurrentClipboard()
            _ = await pasteboard.restore(snapshot, ifChangeCountIs: changeCount)
        case .keyboard:
            try await simulateKeyboard(text)
        }
    }

    public func injectClipboardSnapshot(_ snapshot: ClipboardSnapshot) async throws {
        guard snapshot.hasTransferableContent else { return }
        guard accessibilityChecker() else {
            throw InjectionError.accessibilityPermissionRequired
        }

        let preservedSnapshot = await pasteboard.currentSnapshot()
        let changeCount = await pasteboard.writeSnapshot(snapshot)
        try await pasteCurrentClipboard()
        _ = await pasteboard.restore(preservedSnapshot, ifChangeCountIs: changeCount)
    }

    @discardableResult
    public func pasteCurrentClipboard() async throws -> Bool {
        guard accessibilityChecker() else {
            throw InjectionError.accessibilityPermissionRequired
        }
        try simulatePaste()
        try? await Task.sleep(for: .milliseconds(120))
        return true
    }

    private func simulatePaste() throws {
        let keyCode: CGKeyCode = 9
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw InjectionError.unableToCreatePasteEvent
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func simulateKeyboard(_ text: String) async throws {
        let chunks = Self.utf16Chunks(for: text)
        guard !chunks.isEmpty else { return }

        for (index, originalChunk) in chunks.enumerated() {
            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw InjectionError.unableToCreateKeyboardEvent
            }

            var chunk = originalChunk
            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            if index < chunks.count - 1 {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }
}
