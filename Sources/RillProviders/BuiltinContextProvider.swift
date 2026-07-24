import RillCore
import RillPlatform

public struct BuiltinContextProvider: ContextProvider {
    private let focusTracker: FocusTracker
    private let pasteboard: PasteboardController

    public init(focusTracker: FocusTracker, pasteboard: PasteboardController) {
        self.focusTracker = focusTracker
        self.pasteboard = pasteboard
    }

    public func captureContext() async -> ContextSnapshot {
        let focus = await MainActor.run {
            focusTracker.captureCurrent()
        }
        let clipboard = await pasteboard.privacySafeSnapshot()
        return ContextSnapshot(focus: focus, clipboard: clipboard)
    }

    public func capturePrivacyContext() async -> ContextSnapshot {
        let focus = await MainActor.run {
            focusTracker.capturePrivacyIdentity()
        }
        let descriptor = await pasteboard.currentDescriptor()
        return ContextSnapshot(focus: focus, clipboard: descriptor.policySnapshot)
    }

    public func captureContext(applying decision: PrivacyPolicyDecision) async -> ContextSnapshot {
        let shouldRedactSelectedText = decision.redactedPromptVariables.contains(.selected)
        let focus = await MainActor.run {
            shouldRedactSelectedText
                ? focusTracker.capturePrivacyIdentity()
                : focusTracker.captureCurrent()
        }
        let clipboard: ClipboardSnapshot
        if decision.redactedPromptVariables.contains(.clipboard) {
            let descriptor = await pasteboard.currentDescriptor()
            clipboard = descriptor.policySnapshot
        } else {
            clipboard = await pasteboard.privacySafeSnapshot()
        }
        return ContextSnapshot(focus: focus, clipboard: clipboard).applying(decision)
    }

    public func captureContext(
        applying decision: PrivacyPolicyDecision,
        ifFocusMatches expectedFocus: FocusPrivacyIdentitySample
    ) async -> ContextSnapshot? {
        let shouldRedactSelectedText = decision.redactedPromptVariables.contains(.selected)
        let focus = await MainActor.run { () -> FocusSnapshot? in
            let currentFocus = focusTracker.capturePrivacyIdentitySample()
            guard currentFocus.hasSamePrivacyIdentity(as: expectedFocus) else {
                return nil
            }
            return shouldRedactSelectedText
                ? currentFocus.focus
                : focusTracker.captureCurrent()
        }
        guard let focus else { return nil }

        let clipboard: ClipboardSnapshot
        if decision.redactedPromptVariables.contains(.clipboard) {
            let descriptor = await pasteboard.currentDescriptor()
            clipboard = descriptor.policySnapshot
        } else {
            clipboard = await pasteboard.privacySafeSnapshot()
        }
        return ContextSnapshot(focus: focus, clipboard: clipboard).applying(decision)
    }
}
