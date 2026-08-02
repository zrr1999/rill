import Foundation

/// Capture-side seam for worker-owned streaming preview and VAD events.
///
/// Implementations must keep model objects in the speech worker. The capture
/// process only appends bounded PCM frames and observes immutable text/VAD
/// snapshots, so model preparation never acquires the microphone.
public protocol LocalSpeechStreamingPreviewSession: AnyObject, Sendable {
  var providesVoiceActivity: Bool { get }
  func accept(samples: [Float]) throws -> String
  func drainVoiceActivity() -> [SpeechWorkerVADActivity]
  func finish() async throws -> String
  func cancel() throws
}

public extension LocalSpeechStreamingPreviewSession {
  var providesVoiceActivity: Bool { false }
  func drainVoiceActivity() -> [SpeechWorkerVADActivity] { [] }
  func cancel() throws {}
}
