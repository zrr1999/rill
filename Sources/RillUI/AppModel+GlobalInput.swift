import Foundation
import RillCore

@MainActor
public extension AppModel {
    func requestGlobalInputPermission() {
        requestGlobalInputAction()
    }

    func retryGlobalInputInstallation() {
        retryGlobalInputAction()
    }

    func installRecordPanelShortcutRecordingActions(
        begin: @escaping () -> UUID,
        end: @escaping (UUID) -> Void,
        commit: @escaping (UUID, UInt16) -> Void
    ) {
        beginRecordPanelShortcutRecordingAction = begin
        endRecordPanelShortcutRecordingAction = end
        commitRecordPanelShortcutRecordingAction = commit
    }

    func beginRecordPanelShortcutRecording() -> UUID {
        beginRecordPanelShortcutRecordingAction()
    }

    func endRecordPanelShortcutRecording(_ suspensionID: UUID) {
        endRecordPanelShortcutRecordingAction(suspensionID)
    }

    func commitRecordPanelShortcutRecording(
        _ suspensionID: UUID,
        keyCode: UInt16
    ) {
        commitRecordPanelShortcutRecordingAction(suspensionID, keyCode)
    }

    func updateGlobalInputCapability(_ capability: GlobalInputCapability) {
        globalInputCapability = capability
    }
}
