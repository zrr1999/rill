import RillCore

extension VoiceRunModel {
  public func installLiveSubtitlePanelAction(
    _ action: @escaping @MainActor (LiveSubtitleSnapshot?, AppLanguage) -> Void
  ) {
    updateLiveSubtitlePanelAction = action
    syncLiveSubtitlePanel()
  }
}
