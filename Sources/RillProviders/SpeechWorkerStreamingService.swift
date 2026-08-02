import Foundation

/// Worker-side endpoint for the duplex v5 live-audio protocol.
public protocol SpeechWorkerStreamingRequestHandling: Sendable {
  func handleStreamingFrame(
    _ frame: SpeechWorkerFrame,
    emit: @escaping @Sendable (SpeechWorkerFrame) -> Void
  ) async
}

public extension SpeechWorkerStreamingRequestHandling {
  func streamFailure(
    for frame: SpeechWorkerFrame,
    code: SpeechWorkerFailureCode,
    emit: @escaping @Sendable (SpeechWorkerFrame) -> Void
  ) {
    emit(
      SpeechWorkerFrame(
        requestID: frame.requestID,
        generation: frame.generation,
        sessionID: frame.sessionID,
        sequence: frame.sequence,
        body: .event(.failure(code))
      )
    )
  }
}
