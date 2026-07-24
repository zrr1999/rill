import AppKit

@MainActor
enum ClipboardInputMethodGuard {
    static func shouldHandleReturn(for responder: NSResponder?) -> Bool {
        !isComposingMarkedText(in: responder)
    }

    /// Delete belongs to an active field editor even when it is not currently
    /// composing marked text. Letting the key bubble to the clipboard page
    /// would turn ordinary query/tag editing into destructive history removal.
    static func shouldHandleDelete(for responder: NSResponder?) -> Bool {
        !(responder is NSTextView)
    }

    static func isComposingMarkedText(in responder: NSResponder?) -> Bool {
        guard let textView = responder as? NSTextView else { return false }
        return textView.hasMarkedText()
    }
}
