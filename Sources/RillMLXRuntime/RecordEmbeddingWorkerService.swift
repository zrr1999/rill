import RillCore
import RillSpeechContracts

public actor RecordEmbeddingWorkerService: SpeechWorkerRequestHandling {
  private let store: RecordEmbeddingModelStore
  private var engine: Qwen3RecordEmbedder?

  public init() { store = .init() }
  init(store: RecordEmbeddingModelStore) { self.store = store }

  public func handle(
    _ request: SpeechWorkerRequest,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void
  ) async -> SpeechWorkerResponse {
    do {
      switch request.payload {
      case .prepareEmbeddingModel(let payload):
        guard payload.modelID == RecordEmbeddingModelCatalog.modelID else {
          return .failure(request: request, code: .unsupportedModel)
        }
        if engine == nil {
          let directory = try await store.directory(
            downloadIfNeeded: payload.downloadIfNeeded, progress: progress)
          engine = Qwen3RecordEmbedder(directory: directory)
        }
        return .prepared(request: request, modelID: payload.modelID)
      case .embedText(let payload):
        guard payload.modelID == RecordEmbeddingModelCatalog.modelID, let engine else {
          return .failure(request: request, code: .modelUnavailable)
        }
        let result = try await engine.embed(payload.text, purpose: payload.purpose)
        return .init(
          requestID: request.requestID, generation: request.generation,
          payload: .embeddingCompleted(result))
      default:
        return .failure(request: request, code: .unsupportedModel)
      }
    } catch is CancellationError {
      return .failure(request: request, code: .cancelled)
    } catch RecordEmbeddingError.invalidInput {
      return .failure(request: request, code: .invalidText)
    } catch MLXAudioSwiftRuntimeError.modelUnavailable {
      return .failure(request: request, code: .modelUnavailable)
    } catch {
      return .failure(request: request, code: .invalidRequest)
    }
  }
}
