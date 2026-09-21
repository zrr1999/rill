import Foundation

public enum SpeechWorkerClientError: Error, LocalizedError, Sendable, Equatable {
  case workerUnavailable
  case workerDisconnected
  case protocolViolation
  case staleResponse
  case requestTimedOut
  case requestAlreadyActive
  case remoteFailure(SpeechWorkerFailureCode)
  case invalidManagedAudio
  case workerTerminationFailed

  public var errorDescription: String? {
    switch self {
    case .workerUnavailable:
      "The local speech worker is unavailable."
    case .workerDisconnected:
      "The local speech worker disconnected."
    case .protocolViolation:
      "The local speech worker returned an invalid response."
    case .staleResponse:
      "The local speech worker returned an obsolete response."
    case .requestTimedOut:
      "Local speech recognition timed out."
    case .requestAlreadyActive:
      "The local speech worker is already processing audio."
    case .remoteFailure(let code):
      switch code {
      case .invalidRequest, .unsupportedProtocol:
        "The local speech worker rejected the request."
      case .unsupportedModel:
        "The selected local speech model is unsupported."
      case .modelUnavailable:
        "The selected local speech model is unavailable."
      case .invalidAudio:
        "The recorded audio is invalid."
      case .recognitionFailed:
        "Local speech recognition failed."
      case .invalidText:
        "The speech worker rejected the synthesis text."
      case .synthesisFailed:
        "Local speech synthesis failed."
      case .invalidSequence:
        "The live speech stream contained an invalid audio sequence."
      case .streamBusy:
        "The local speech worker already has an active live stream."
      case .streamingFailed:
        "Live local speech recognition failed."
      case .requestPreempted:
        "The speech task yielded to a higher-priority request."
      case .cancelled:
        "Live local speech recognition was cancelled."
      }
    case .invalidManagedAudio:
      "Local speech recognition requires Rill-managed temporary audio."
    case .workerTerminationFailed:
      "The local speech worker could not be stopped safely."
    }
  }
}
