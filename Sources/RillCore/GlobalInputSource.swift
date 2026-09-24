import Foundation

public enum PushToTalkGesture: String, Sendable, Equatable {
  case fnHold = "fn-hold"
  case controlOptionShiftSpace = "control-option-shift-space"
}

public enum GlobalInputEvent: Sendable, Equatable {
  case recordPanelRequested
  case recordBufferOutputRequested
  case pushToTalkPressed(PushToTalkGesture)
  case pushToTalkReleased(PushToTalkGesture)
  case liveAudioCancellationRequested(UUID)
  case globalInputUnavailable
  case customHotkey(String)
}

public protocol GlobalInputSource: Sendable {
  func stream() -> AsyncStream<GlobalInputEvent>
  func isPushToTalkGestureActive(_ gesture: PushToTalkGesture) -> Bool
}
