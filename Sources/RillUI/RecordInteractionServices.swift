import Foundation
import RillCore

@MainActor
public struct RecordInteractionServices {
  let copy: (RecordReuseSubject) async -> RecordReuseOutcome
  let setCaptureEnabled: (Bool, UInt64) -> Void
  let ignoreNextExternalChange: () -> Void
  let updateHotkey: (HotkeyBindingDescriptor) -> Void
  let beginShortcutRecording: () -> UUID
  let endShortcutRecording: (UUID) -> Void
  let commitShortcutRecording: (UUID, UInt16) -> Void

  public init(
    copy: @escaping (RecordReuseSubject) async -> RecordReuseOutcome,
    setCaptureEnabled: @escaping (Bool, UInt64) -> Void,
    ignoreNextExternalChange: @escaping () -> Void,
    updateHotkey: @escaping (HotkeyBindingDescriptor) -> Void,
    beginShortcutRecording: @escaping () -> UUID,
    endShortcutRecording: @escaping (UUID) -> Void,
    commitShortcutRecording: @escaping (UUID, UInt16) -> Void
  ) {
    self.copy = copy
    self.setCaptureEnabled = setCaptureEnabled
    self.ignoreNextExternalChange = ignoreNextExternalChange
    self.updateHotkey = updateHotkey
    self.beginShortcutRecording = beginShortcutRecording
    self.endShortcutRecording = endShortcutRecording
    self.commitShortcutRecording = commitShortcutRecording
  }
}
