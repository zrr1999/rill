import Foundation
import RillCore

extension VoiceRunModel {
  public func installLiveSubtitlePanelAction(
    _ action: @escaping @MainActor (LiveSubtitleSnapshot?, AppLanguage) -> Void
  ) {
    updateLiveSubtitlePanelAction = action
    syncLiveSubtitlePanel()
  }

  public func installLiveAudioCancellationAction(_ action: @escaping @MainActor (UUID?) -> Void) {
    updateLiveAudioCancellationAction = action
    syncLiveAudioCancellation()
  }

  func syncLiveAudioCancellation() {
    let runID = currentCaptureLiveSubtitleSnapshot.flatMap { snapshot in
      LiveSubtitlePresentationPolicy.isAudioCaptureActive(phase: snapshot.phase)
        ? snapshot.runID : nil
    }
    updateLiveAudioCancellationAction?(runID)
  }
}
