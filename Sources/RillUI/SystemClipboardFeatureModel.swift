import Foundation
import Observation
import RillCore

@MainActor
@Observable
public final class SystemClipboardFeatureModel {
  public internal(set) var systemClipboardCaptureEnabled: Bool = false
  public internal(set) var clipboardCapturePreferenceRevision: UInt64 = 0
  public internal(set) var systemClipboardCaptureControlSnapshot:
    SystemClipboardCaptureControlSnapshot = SystemClipboardCaptureControlSnapshot(
      revision: 0,
      state: .paused
    )
}
