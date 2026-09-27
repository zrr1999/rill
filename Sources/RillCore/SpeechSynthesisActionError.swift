import Foundation

public enum SpeechSynthesisActionError: Error, LocalizedError, Sendable {
  case invalidRequest
  case preferredProviderUnavailable
  case synthesisFailed
  case playbackFailed

  public var errorDescription: String? {
    switch self {
    case .invalidRequest:
      return "The speech output action contains an invalid request."
    case .preferredProviderUnavailable:
      return "Qwen3-TTS is not available in this build."
    case .synthesisFailed:
      return "Speech synthesis could not complete."
    case .playbackFailed:
      return "Speech playback could not complete."
    }
  }
}
