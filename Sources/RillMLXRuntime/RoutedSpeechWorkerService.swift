import RillProviders

/// Routes only reviewed model identities to worker-side engines.
///
/// Adding an engine requires a catalog identity and one bounded handler; the
/// process protocol, parent supervisor, and application registry stay stable.
public actor RoutedSpeechWorkerService: SpeechWorkerRequestHandling {
  private let sherpaOnnx: any SpeechWorkerRequestHandling
  private let mlxAudioSwift: any SpeechWorkerRequestHandling

  public init(
    sherpaOnnx: any SpeechWorkerRequestHandling = SherpaOnnxSpeechWorkerService(),
    mlxAudioSwift: any SpeechWorkerRequestHandling = MLXAudioSwiftSpeechWorkerService()
  ) {
    self.sherpaOnnx = sherpaOnnx
    self.mlxAudioSwift = mlxAudioSwift
  }

  public func handle(_ request: SpeechWorkerRequest) async -> SpeechWorkerResponse {
    let modelID =
      request.recognitionPayload?.modelID
      ?? request.modelPreparationPayload?.modelID
      ?? ""
    if MLXAudioModelCatalog.distributableModelIdentifiers.contains(modelID) {
      return await mlxAudioSwift.handle(request)
    }
    return await sherpaOnnx.handle(request)
  }
}
