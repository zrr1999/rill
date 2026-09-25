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

    func beginRecordPanelShortcutRecording() -> UUID {
        recordInteractions.beginShortcutRecording()
    }

    func endRecordPanelShortcutRecording(_ suspensionID: UUID) {
        recordInteractions.endShortcutRecording(suspensionID)
    }

    func commitRecordPanelShortcutRecording(
        _ suspensionID: UUID,
        keyCode: UInt16
    ) {
        recordInteractions.commitShortcutRecording(suspensionID, keyCode)
    }

    func updateGlobalInputCapability(_ capability: GlobalInputCapability) {
        globalInputCapability = capability
    }
}
