import Foundation

public struct SpeechVoiceActivity: Sendable, Equatable {
  public let isSpeech: Bool
  public let durationSeconds: Double

  public init(isSpeech: Bool, durationSeconds: Double) {
    self.isSpeech = isSpeech
    self.durationSeconds = durationSeconds
  }
}

/// Capture-side seam for worker-owned streaming preview and VAD events.
///
/// Implementations must keep model objects in the speech worker. The capture
/// process only appends bounded PCM frames and observes immutable text/VAD
/// snapshots, so model preparation never acquires the microphone.
public protocol LocalSpeechStreamingPreviewSession: AnyObject, Sendable {
  var providesVoiceActivity: Bool { get }
  var hasConfirmedText: Bool { get }
  var keytermStatus: RecognitionHintApplicationStatus { get }
  func accept(samples: [Float]) throws -> String
  func drainVoiceActivity() -> [SpeechVoiceActivity]
  func finish() async throws -> String
  func cancel() throws
}

public extension LocalSpeechStreamingPreviewSession {
  var providesVoiceActivity: Bool { false }
  var hasConfirmedText: Bool { false }
  var keytermStatus: RecognitionHintApplicationStatus { .unsupported }
  func drainVoiceActivity() -> [SpeechVoiceActivity] { [] }
  func cancel() throws {}
}
