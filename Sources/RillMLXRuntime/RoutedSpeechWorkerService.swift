import RillProviders

/// Routes only reviewed model identities to worker-side engines.
///
/// Adding an engine requires a catalog identity and one bounded handler; the
/// process protocol, parent supervisor, and application registry stay stable.
public actor RoutedSpeechWorkerService:
  SpeechWorkerRequestHandling,
  SpeechWorkerStreamingRequestHandling
{
  private let mlxAudioSwift: any SpeechWorkerRequestHandling
  private let mlxAudioSwiftStreaming: (any SpeechWorkerStreamingRequestHandling)?

  public init(
    mlxAudioSwift: any SpeechWorkerRequestHandling = MLXAudioSwiftSpeechWorkerService(),
    mlxAudioSwiftStreaming: (any SpeechWorkerStreamingRequestHandling)? = nil
  ) {
    self.mlxAudioSwift = mlxAudioSwift
    self.mlxAudioSwiftStreaming =
      mlxAudioSwiftStreaming
      ?? (mlxAudioSwift as? any SpeechWorkerStreamingRequestHandling)
  }

  public func handle(
    _ request: SpeechWorkerRequest,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void
  ) async -> SpeechWorkerResponse {
    let modelID =
      request.recognitionPayload?.modelID
      ?? request.synthesisPayload?.modelID
      ?? request.modelPreparationPayload?.modelID
      ?? ""
    if MLXAudioModelCatalog.distributableModelIdentifiers.contains(modelID)
      || SpeechSynthesisModelCatalog.supportedModelIdentifiers.contains(modelID)
    {
      return await mlxAudioSwift.handle(request, progress: progress)
    }
    return .failure(request: request, code: .unsupportedModel)
  }

  public func handleStreamingFrame(
    _ frame: SpeechWorkerFrame,
    emit: @escaping @Sendable (SpeechWorkerFrame) -> Void
  ) async {
    guard let mlxAudioSwiftStreaming else {
      streamFailure(for: frame, code: .streamingFailed, emit: emit)
      return
    }
    await mlxAudioSwiftStreaming.handleStreamingFrame(frame, emit: emit)
  }
}
