import RillCore

extension AppModel {
    public func installLiveSubtitlePanelAction(
        _ action: @escaping @MainActor (LiveSubtitleSnapshot?, AppLanguage) -> Void
    ) {
        updateLiveSubtitlePanelAction = action
        syncLiveSubtitlePanel()
    }
}
