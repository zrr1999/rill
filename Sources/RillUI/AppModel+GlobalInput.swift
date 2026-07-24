import Foundation
import RillCore

@MainActor
public extension AppModel {
    func installGlobalInputActions(
        request: @escaping () -> Void,
        retry: @escaping () -> Void
    ) {
        requestGlobalInputAction = request
        retryGlobalInputAction = retry
    }

    func requestGlobalInputPermission() {
        requestGlobalInputAction()
    }

    func retryGlobalInputInstallation() {
        retryGlobalInputAction()
    }

    func installClipboardPanelShortcutRecordingActions(
        begin: @escaping () -> UUID,
        end: @escaping (UUID) -> Void,
        commit: @escaping (UUID, UInt16) -> Void
    ) {
        beginClipboardPanelShortcutRecordingAction = begin
        endClipboardPanelShortcutRecordingAction = end
        commitClipboardPanelShortcutRecordingAction = commit
    }

    func beginClipboardPanelShortcutRecording() -> UUID {
        beginClipboardPanelShortcutRecordingAction()
    }

    func endClipboardPanelShortcutRecording(_ suspensionID: UUID) {
        endClipboardPanelShortcutRecordingAction(suspensionID)
    }

    func commitClipboardPanelShortcutRecording(
        _ suspensionID: UUID,
        keyCode: UInt16
    ) {
        commitClipboardPanelShortcutRecordingAction(suspensionID, keyCode)
    }

    func updateGlobalInputCapability(_ capability: GlobalInputCapability) {
        globalInputCapability = capability
    }
}
