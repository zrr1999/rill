import VoxTypeCore
import VoxTypePlatform

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
        let clipboard = await pasteboard.currentSnapshot()
        return ContextSnapshot(focus: focus, clipboard: clipboard)
    }
}
