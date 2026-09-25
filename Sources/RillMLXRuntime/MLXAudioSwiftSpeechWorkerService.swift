import RillSpeechContracts
import Darwin
import Foundation
import MLX
import MLXAudioCore
import MLXAudioSTT
import MLXAudioTTS
import RillCore

public enum MLXAudioSwiftRuntimeError: Error, LocalizedError, Sendable, Equatable {
  case architectureUnsupported
  case unsupportedModel(String)
  case modelUnavailable(String)
  case invalidModelStore
  case invalidAudio
  case modelLoadFailed
  case invalidText
  case synthesisFailed

  public var errorDescription: String? {
    switch self {
    case .architectureUnsupported:
      "MLX-Audio Swift requires Apple Silicon."
    case .unsupportedModel(let modelID):
      "The MLX-Audio Swift model is unsupported: \(modelID)."
    case .modelUnavailable(let modelID):
      "The MLX-Audio Swift model is unavailable: \(modelID)."
    case .invalidModelStore:
      "The MLX-Audio Swift model store is invalid."
    case .invalidAudio:
      "The captured audio is invalid."
    case .modelLoadFailed:
      "The MLX-Audio Swift model could not be loaded."
    case .invalidText:
      "The speech synthesis request is invalid."
    case .synthesisFailed:
      "MLX-Audio Swift speech synthesis failed."
    }
  }
}

struct MLXAudioSwiftInferenceOutput: Sendable, Equatable {
  let text: String
  let detectedLanguage: String?
  let processingDurationMillis: Int
  var promptTokenCount: Int? = nil
  var includedKeytermCount: Int? = nil
  var omittedKeytermCount: Int? = nil
}

protocol MLXAudioSwiftInferenceEngine: Sendable {
  func prepare(
    modelID: String,
    downloadIfNeeded: Bool,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void
  ) async throws -> String

  func recognize(
    modelID: String,
    audioURL: URL,
    language: String?,
    keyterms: [String],
    downloadIfNeeded: Bool
  ) async throws -> MLXAudioSwiftInferenceOutput

  func makeStreamingSession(
    modelID: String,
    language: String?,
    profile: SpeechWorkerStreamingProfile,
    downloadIfNeeded: Bool
  ) async throws -> MLXAudioSwiftStreamingHandle

  func release(modelID: String) async throws
}

extension MLXAudioSwiftInferenceEngine {
  func release(modelID _: String) async throws {}

  func makeStreamingSession(
    modelID: String,
    language _: String?,
    profile _: SpeechWorkerStreamingProfile,
    downloadIfNeeded _: Bool
  ) async throws -> MLXAudioSwiftStreamingHandle {
    throw MLXAudioSwiftRuntimeError.unsupportedModel(modelID)
  }
}

enum MLXAudioSwiftStreamingEvent: Sendable, Equatable {
  case transcript(confirmed: String, provisional: String)
  case stats(SpeechWorkerStreamingStats)
  case ended(fullText: String)
}

struct MLXAudioSwiftStreamingHandle: @unchecked Sendable {
  let events: AsyncStream<MLXAudioSwiftStreamingEvent>
  let feedAudio: @Sendable ([Float]) -> Void
  let stop: @Sendable () -> Void
  let cancel: @Sendable () -> Void
}

public actor MLXAudioSwiftSpeechWorkerService:
  SpeechWorkerRequestHandling,
  SpeechWorkerStreamingRequestHandling
{
  private struct ActiveStream {
    let requestID: UUID
    let generation: UInt64
    let sessionID: UUID
    let mode: SpeechWorkerStreamMode
    let emit: @Sendable (SpeechWorkerFrame) -> Void
    var nextCommandSequence: UInt64
    var nextEventSequence: UInt64
    var totalSampleCount: UInt64
    var speechIsActive: Bool
    var previewText: String
    var handle: MLXAudioSwiftStreamingHandle?
    var eventTask: Task<Void, Never>?
  }

  private let engine: any MLXAudioSwiftInferenceEngine
  private let ttsEngine: any MLXAudioSwiftTTSInferenceEngine
  private let vadRuntime: MLXSileroVADRuntime
  private var activeStreams: [UUID: ActiveStream] = [:]

  public init() {
    self.engine = MLXAudioSwiftQwenEngine()
    self.ttsEngine = MLXAudioSwiftQwenTTSEngine()
    self.vadRuntime = MLXSileroVADRuntime()
  }

  public func handleStreamingFrame(
    _ frame: SpeechWorkerFrame,
    emit: @escaping @Sendable (SpeechWorkerFrame) -> Void
  ) async {
    guard frame.protocolVersion == SpeechWorkerProtocol.version,
      case .command(let command) = frame.body
    else {
      streamFailure(for: frame, code: .invalidRequest, emit: emit)
      return
    }

    switch command {
    case .cancelRequest:
      streamFailure(for: frame, code: .invalidRequest, emit: emit)
    case .start(let payload):
      await startStream(frame: frame, payload: payload, emit: emit)
    case .appendAudio(let chunk):
      await appendStreamAudio(frame: frame, chunk: chunk, emit: emit)
    case .finish:
      await finishStream(frame: frame)
    case .cancel:
      await cancelStream(frame: frame)
    }
  }

  private func startStream(
    frame: SpeechWorkerFrame,
    payload: SpeechWorkerStreamStart,
    emit: @escaping @Sendable (SpeechWorkerFrame) -> Void
  ) async {
    guard activeStreams[frame.sessionID] == nil,
      activeStreams.count < 8,
      payload.mode == .vadOnly
        || !activeStreams.values.contains(where: { $0.mode == .vadAndTranscription })
    else {
      streamFailure(for: frame, code: .streamBusy, emit: emit)
      return
    }
    guard frame.sequence == 0 else {
      streamFailure(for: frame, code: .invalidSequence, emit: emit)
      return
    }

    activeStreams[frame.sessionID] = ActiveStream(
      requestID: frame.requestID,
      generation: frame.generation,
      sessionID: frame.sessionID,
      mode: payload.mode,
      emit: emit,
      nextCommandSequence: 1,
      nextEventSequence: 0,
      totalSampleCount: 0,
      speechIsActive: false,
      previewText: "",
      handle: nil,
      eventTask: nil
    )
    emitStreamEvent(.accepted(queuePosition: 0), sessionID: frame.sessionID)

    do {
      try await vadRuntime.start(
        sessionID: frame.sessionID,
        downloadIfNeeded: payload.downloadIfNeeded
      )
      if payload.mode == .vadAndTranscription {
        let handle = try await engine.makeStreamingSession(
          modelID: payload.modelID,
          language: payload.language,
          profile: payload.profile,
          downloadIfNeeded: payload.downloadIfNeeded
        )
        guard activeStreams[frame.sessionID] != nil else {
          handle.cancel()
          return
        }
        activeStreams[frame.sessionID]?.handle = handle
        let eventTask = Task { [weak self] in
          for await event in handle.events {
            guard !Task.isCancelled else { break }
            await self?.forwardStreamingEvent(event, sessionID: frame.sessionID)
          }
        }
        activeStreams[frame.sessionID]?.eventTask = eventTask
        emitStreamEvent(.started(modelID: payload.modelID), sessionID: frame.sessionID)
      } else {
        emitStreamEvent(
          .started(modelID: MLXSileroVADConstants.modelID),
          sessionID: frame.sessionID
        )
      }
    } catch {
      emitStreamEvent(
        .failure(Self.failureCode(for: error)),
        sessionID: frame.sessionID
      )
      clearActiveStream(sessionID: frame.sessionID, cancelHandle: true)
      await vadRuntime.cancel(sessionID: frame.sessionID)
    }
  }

  private func appendStreamAudio(
    frame: SpeechWorkerFrame,
    chunk: SpeechWorkerAudioChunk,
    emit: @escaping @Sendable (SpeechWorkerFrame) -> Void
  ) async {
    guard var stream = activeStreams[frame.sessionID],
      stream.requestID == frame.requestID,
      stream.generation == frame.generation
    else {
      streamFailure(for: frame, code: .invalidRequest, emit: emit)
      return
    }
    guard frame.sequence == stream.nextCommandSequence else {
      emitStreamEvent(.failure(.invalidSequence), sessionID: frame.sessionID)
      clearActiveStream(sessionID: frame.sessionID, cancelHandle: true)
      await vadRuntime.cancel(sessionID: frame.sessionID)
      return
    }
    let samples: [Float]
    do {
      samples = try chunk.decodedSamples()
    } catch {
      emitStreamEvent(.failure(.invalidRequest), sessionID: frame.sessionID)
      clearActiveStream(sessionID: frame.sessionID, cancelHandle: true)
      await vadRuntime.cancel(sessionID: frame.sessionID)
      return
    }

    stream.nextCommandSequence += 1
    stream.totalSampleCount += UInt64(samples.count)
    activeStreams[frame.sessionID] = stream
    do {
      let observations = try await vadRuntime.accept(
        sessionID: frame.sessionID,
        samples: samples
      )
      publishVADObservations(observations, sessionID: frame.sessionID)
    } catch {
      emitStreamEvent(.failure(.streamingFailed), sessionID: frame.sessionID)
      clearActiveStream(sessionID: frame.sessionID, cancelHandle: true)
      await vadRuntime.cancel(sessionID: frame.sessionID)
      return
    }
    activeStreams[frame.sessionID]?.handle?.feedAudio(samples)
  }

  private func finishStream(frame: SpeechWorkerFrame) async {
    guard let stream = activeStreams[frame.sessionID],
      stream.requestID == frame.requestID,
      stream.generation == frame.generation,
      frame.sequence == stream.nextCommandSequence
    else {
      if activeStreams[frame.sessionID] != nil {
        emitStreamEvent(.failure(.invalidSequence), sessionID: frame.sessionID)
        clearActiveStream(sessionID: frame.sessionID, cancelHandle: true)
        await vadRuntime.cancel(sessionID: frame.sessionID)
      }
      return
    }
    do {
      publishVADObservations(
        try await vadRuntime.finish(sessionID: frame.sessionID),
        sessionID: frame.sessionID
      )
    } catch {
      emitStreamEvent(.failure(.streamingFailed), sessionID: frame.sessionID)
      clearActiveStream(sessionID: frame.sessionID, cancelHandle: true)
      return
    }
    if activeStreams[frame.sessionID]?.speechIsActive == true {
      emitStreamEvent(
        .speechEnded(sampleOffset: stream.totalSampleCount),
        sessionID: frame.sessionID
      )
      activeStreams[frame.sessionID]?.speechIsActive = false
    }
    if let handle = stream.handle {
      // The upstream Qwen session performs a final encoder pass from a detached
      // task. MLX Swift does not permit its lazy arrays to cross threads, and
      // that pass can corrupt the compiler cache in release builds. Streaming
      // is preview-only in Rill, so preserve the latest display projection and
      // cancel the incremental session; the sealed WAV still receives the
      // authoritative offline decode immediately afterwards.
      handle.cancel()
      // `StreamingInferenceSession.cancel()` cancels its detached decode task
      // without joining it. Give the task one bounded token boundary to drain
      // before completion permits model reuse or worker shutdown.
      try? await Task.sleep(for: .milliseconds(250))
      emitStreamEvent(
        .completed(previewText: stream.previewText),
        sessionID: frame.sessionID
      )
      clearActiveStream(sessionID: frame.sessionID, cancelHandle: false)
    } else {
      emitStreamEvent(.completed(previewText: ""), sessionID: frame.sessionID)
      clearActiveStream(sessionID: frame.sessionID, cancelHandle: false)
    }
  }

  private func cancelStream(frame: SpeechWorkerFrame) async {
    guard let stream = activeStreams[frame.sessionID],
      stream.requestID == frame.requestID,
      stream.generation == frame.generation,
      frame.sequence == stream.nextCommandSequence
    else { return }
    emitStreamEvent(.failure(.cancelled), sessionID: frame.sessionID)
    clearActiveStream(sessionID: frame.sessionID, cancelHandle: true)
    await vadRuntime.cancel(sessionID: frame.sessionID)
  }

  private func publishVADObservations(
    _ observations: [MLXSileroVADObservation],
    sessionID: UUID
  ) {
    for observation in observations {
      emitStreamEvent(.vadActivity(observation.activity), sessionID: sessionID)
      guard var stream = activeStreams[sessionID] else { return }
      stream.speechIsActive = observation.activity.isSpeech
      activeStreams[sessionID] = stream
      switch observation.transition {
      case .speechStarted:
        emitStreamEvent(
          .speechStarted(sampleOffset: observation.activity.sampleOffset),
          sessionID: sessionID
        )
      case .speechEnded:
        emitStreamEvent(
          .speechEnded(sampleOffset: observation.activity.sampleOffset),
          sessionID: sessionID
        )
      case nil:
        break
      }
    }
  }

  private func forwardStreamingEvent(
    _ event: MLXAudioSwiftStreamingEvent,
    sessionID: UUID
  ) {
    guard activeStreams[sessionID] != nil else { return }
    switch event {
    case .transcript(let confirmed, let provisional):
      let previewText = (confirmed + provisional).trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      if !previewText.isEmpty {
        activeStreams[sessionID]?.previewText = previewText
      }
      emitStreamEvent(
        .transcriptUpdate(
          SpeechWorkerTranscriptUpdate(
            confirmed: confirmed,
            provisional: provisional
          )
        ),
        sessionID: sessionID
      )
    case .stats(let stats):
      emitStreamEvent(.stats(stats), sessionID: sessionID)
    case .ended(let fullText):
      emitStreamEvent(.completed(previewText: fullText), sessionID: sessionID)
      clearActiveStream(sessionID: sessionID, cancelHandle: false)
    }
  }

  private func emitStreamEvent(
    _ event: SpeechWorkerStreamEvent,
    sessionID: UUID
  ) {
    guard var stream = activeStreams[sessionID] else { return }
    let frame = SpeechWorkerFrame(
      requestID: stream.requestID,
      generation: stream.generation,
      sessionID: stream.sessionID,
      sequence: stream.nextEventSequence,
      body: .event(event)
    )
    stream.nextEventSequence += 1
    activeStreams[sessionID] = stream
    stream.emit(frame)
  }

  private func clearActiveStream(sessionID: UUID, cancelHandle: Bool) {
    guard let stream = activeStreams.removeValue(forKey: sessionID) else { return }
    stream.eventTask?.cancel()
    if cancelHandle {
      stream.handle?.cancel()
    }
  }

  init(
    engine: any MLXAudioSwiftInferenceEngine,
    ttsEngine: any MLXAudioSwiftTTSInferenceEngine = MLXAudioSwiftQwenTTSEngine(),
    vadRuntime: MLXSileroVADRuntime = MLXSileroVADRuntime()
  ) {
    self.engine = engine
    self.ttsEngine = ttsEngine
    self.vadRuntime = vadRuntime
  }

  public func handle(
    _ request: SpeechWorkerRequest,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void
  ) async -> SpeechWorkerResponse {
    do {
      guard request.protocolVersion == SpeechWorkerProtocol.version else {
        throw SpeechWorkerProtocolError.unsupportedVersion
      }
      switch request.operation {
      case .prepareEmbeddingModel, .embedText:
        return .failure(request: request, code: .unsupportedModel)
      case .prepareModel:
        guard request.recognitionPayload == nil,
          let payload = request.modelPreparationPayload
        else {
          throw SpeechWorkerProtocolError.invalidRequest
        }
        let prepared = try await engine.prepare(
          modelID: payload.modelID,
          downloadIfNeeded: payload.downloadIfNeeded,
          progress: progress
        )
        return .prepared(request: request, modelID: prepared)

      case .recognizeOffline:
        guard request.modelPreparationPayload == nil,
          let payload = request.recognitionPayload
        else {
          throw SpeechWorkerProtocolError.invalidRequest
        }
        guard payload.audioDurationSeconds.isFinite,
          payload.audioDurationSeconds >= 0
        else {
          throw MLXAudioSwiftRuntimeError.invalidAudio
        }
        let audioURL: URL
        do {
          audioURL = try SpeechWorkerInputValidation.validatedManagedAudioURL(
            path: payload.audioFilePath
          )
        } catch {
          throw MLXAudioSwiftRuntimeError.invalidAudio
        }
        let output = try await engine.recognize(
          modelID: payload.modelID,
          audioURL: audioURL,
          language: payload.language,
          keyterms: payload.keyterms,
          downloadIfNeeded: payload.downloadIfNeeded
        )
        var metadata = [
          "provider.kind": LocalSpeechModelBackend.mlxAudioSwift.rawValue,
          "provider.model": payload.modelID,
          "provider.runtime": "mlx-audio-swift-0.1.3",
        ]
        if let model = MLXAudioModelID(rawValue: payload.modelID) {
          metadata["provider.model_revision"] = MLXAudioModelCatalog.descriptor(for: model).revision
        }
        if let tokens = output.promptTokenCount { metadata["provider.prompt_tokens"] = String(tokens) }
        if let included = output.includedKeytermCount { metadata["provider.keyterms_used"] = String(included) }
        if let omitted = output.omittedKeytermCount { metadata["provider.keyterms_omitted"] = String(omitted) }
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss > 0 {
          // Darwin reports bytes for the lifetime high-water mark of this worker.
          metadata["provider.worker_peak_rss_bytes"] = String(usage.ru_maxrss)
        }
        if let detectedLanguage = output.detectedLanguage {
          metadata["provider.detected_language"] = detectedLanguage
        }
        let result = SpeechWorkerRecognitionResult(
          rawText: output.text,
          bestText: output.text,
          metadata: metadata,
          processingDurationMillis: output.processingDurationMillis
        )
        return .success(request: request, result: result)
      case .releaseModel:
        guard request.recognitionPayload == nil,
          request.synthesisPayload == nil,
          let payload = request.modelPreparationPayload
        else {
          throw SpeechWorkerProtocolError.invalidRequest
        }
        try await engine.release(modelID: payload.modelID)
        return .released(request: request, modelID: payload.modelID)
      case .prepareTTSModel:
        guard request.recognitionPayload == nil,
          request.synthesisPayload == nil,
          let payload = request.modelPreparationPayload
        else {
          throw SpeechWorkerProtocolError.invalidRequest
        }
        let prepared = try await ttsEngine.prepareTTS(
          modelID: payload.modelID,
          downloadIfNeeded: payload.downloadIfNeeded,
          progress: progress
        )
        return .prepared(request: request, modelID: prepared)
      case .synthesizeSpeech:
        guard request.recognitionPayload == nil,
          request.modelPreparationPayload == nil,
          let payload = request.synthesisPayload
        else {
          throw SpeechWorkerProtocolError.invalidRequest
        }
        let output = try await ttsEngine.synthesize(payload: payload)
        return .synthesized(
          request: request,
          result: SpeechWorkerSynthesisResult(
            audioFilePath: output.audioFileURL.path,
            sampleRate: output.sampleRate,
            channelCount: output.channelCount,
            durationSeconds: output.durationSeconds
          )
        )
      case .releaseTTSModel:
        guard request.recognitionPayload == nil,
          request.synthesisPayload == nil,
          let payload = request.modelPreparationPayload
        else {
          throw SpeechWorkerProtocolError.invalidRequest
        }
        try await ttsEngine.releaseTTS(modelID: payload.modelID)
        return .released(request: request, modelID: payload.modelID)
      }
    } catch {
      return .failure(request: request, code: Self.failureCode(for: error))
    }
  }

  private static func failureCode(for error: Error) -> SpeechWorkerFailureCode {
    if error is CancellationError {
      return .requestPreempted
    }
    if let error = error as? SpeechWorkerProtocolError {
      switch error {
      case .unsupportedVersion:
        return .unsupportedProtocol
      case .frameTooLarge, .unterminatedFrame, .invalidFrame, .invalidRequest, .invalidResponse:
        return .invalidRequest
      }
    }
    if let error = error as? MLXAudioSwiftRuntimeError {
      switch error {
      case .unsupportedModel:
        return .unsupportedModel
      case .modelUnavailable, .invalidModelStore, .modelLoadFailed:
        return .modelUnavailable
      case .invalidAudio:
        return .invalidAudio
      case .invalidText:
        return .invalidText
      case .synthesisFailed:
        return .synthesisFailed
      case .architectureUnsupported:
        return .recognitionFailed
      }
    }
    return .recognitionFailed
  }
}

enum MLXAudioSwiftQwenOptions {
  static func resolvedLanguage(_ language: String?) -> String? {
    let normalized = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    switch normalized.lowercased() {
    case "", "auto":
      return nil
    case "zh", "zh-cn", "zh-hans", "zh-tw", "zh-hant", "cmn":
      return "Chinese"
    case "en", "en-us", "en-gb":
      return "English"
    case "yue", "yue-hk", "yue-hant-hk":
      return "Cantonese"
    default:
      return normalized
    }
  }

  static func context(from keyterms: [String]) -> String {
    let sanitized = LocalSpeechRecognitionPolicy.sanitizedQwenHotwords(keyterms)
    guard !sanitized.isEmpty else { return "" }
    return "Keywords: \(sanitized.joined(separator: ", "))."
  }
}

private final class MLXQwenDecodeLease: @unchecked Sendable {
  private let lock = NSLock()
  private var isReleased = false
  private let releaseAction: @Sendable () -> Void

  init(releaseAction: @escaping @Sendable () -> Void) {
    self.releaseAction = releaseAction
  }

  func release() {
    let shouldRelease = lock.withLock {
      guard !isReleased else { return false }
      isReleased = true
      return true
    }
    if shouldRelease { releaseAction() }
  }

  deinit {
    release()
  }
}

private actor MLXQwenDecodeGate {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
  }

  private var isHeld = false
  private var waiters: [Waiter] = []

  func acquire() async throws -> MLXQwenDecodeLease {
    if !isHeld {
      isHeld = true
      return makeLease()
    }
    let id = UUID()
    let acquired = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: false)
          return
        }
        waiters.append(Waiter(id: id, continuation: continuation))
      }
    } onCancel: {
      Task { await self.cancelWaiter(id: id) }
    }
    guard acquired else { throw CancellationError() }
    return makeLease()
  }

  private func makeLease() -> MLXQwenDecodeLease {
    MLXQwenDecodeLease { [weak self] in
      Task { await self?.release() }
    }
  }

  private func cancelWaiter(id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume(returning: false)
  }

  private func release() {
    guard !waiters.isEmpty else {
      isHeld = false
      return
    }
    waiters.removeFirst().continuation.resume(returning: true)
  }
}

actor MLXAudioSwiftQwenEngine: MLXAudioSwiftInferenceEngine {
  private struct LoadedModel {
    let id: MLXAudioModelID
    let model: Qwen3ASRModel
  }

  private let store: MLXAudioSwiftModelStore
  private let clearMemoryCache: @Sendable () -> Void
  private let decodeGate = MLXQwenDecodeGate()
  private var loadedModels: [MLXAudioModelID: LoadedModel] = [:]

  init(
    store: MLXAudioSwiftModelStore = .init(),
    clearMemoryCache: @escaping @Sendable () -> Void = { Memory.clearCache() }
  ) {
    self.store = store
    self.clearMemoryCache = clearMemoryCache
  }

  func prepare(
    modelID: String,
    downloadIfNeeded: Bool,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void
  ) async throws -> String {
    #if !arch(arm64)
      throw MLXAudioSwiftRuntimeError.architectureUnsupported
    #else
      guard let id = MLXAudioModelID(rawValue: modelID),
        MLXAudioModelCatalog.distributableModelIdentifiers.contains(modelID)
      else {
        throw MLXAudioSwiftRuntimeError.unsupportedModel(modelID)
      }
      if loadedModels[id] != nil {
        return id.rawValue
      }
      let descriptor = MLXAudioModelCatalog.descriptor(for: id)
      let modelDirectory = try await store.modelDirectory(
        descriptor: descriptor,
        downloadIfNeeded: downloadIfNeeded,
        progress: progress
      )
      progress(
        SpeechWorkerProgress(
          phase: .loading,
          completedUnitCount: 0,
          totalUnitCount: 1
        )
      )
      let model: Qwen3ASRModel
      do {
        model = try await Qwen3ASRModel.fromModelDirectory(modelDirectory)
      } catch {
        throw MLXAudioSwiftRuntimeError.modelLoadFailed
      }
      loadedModels[id] = LoadedModel(id: id, model: model)
      progress(
        SpeechWorkerProgress(
          phase: .loading,
          completedUnitCount: 1,
          totalUnitCount: 1
        )
      )
      return id.rawValue
    #endif
  }

  func recognize(
    modelID: String,
    audioURL: URL,
    language: String?,
    keyterms: [String],
    downloadIfNeeded: Bool
  ) async throws -> MLXAudioSwiftInferenceOutput {
    _ = try await prepare(
      modelID: modelID,
      downloadIfNeeded: downloadIfNeeded,
      progress: { _ in }
    )
    guard let id = MLXAudioModelID(rawValue: modelID),
      let loadedModel = loadedModels[id]
    else {
      throw MLXAudioSwiftRuntimeError.modelLoadFailed
    }
    let resolvedLanguage = MLXAudioSwiftQwenOptions.resolvedLanguage(language)
    guard let tokenizer = loadedModel.model.tokenizer else {
      throw MLXAudioSwiftRuntimeError.modelLoadFailed
    }
    let prompt = RecognitionPromptBudget.resolve(keyterms: keyterms, maximumTokens: 64) {
      tokenizer.encode(text: $0).count
    }
    let lease = try await decodeGate.acquire()
    defer { lease.release() }
    let output: STTOutput
    do {
      try Task.checkCancellation()
      let (_, audio) = try loadAudioArray(from: audioURL, sampleRate: 16_000)
      var finalOutput: STTOutput?
      for try await event in loadedModel.model.generateStream(
        audio: audio,
        temperature: 0,
        context: prompt.context,
        language: resolvedLanguage
      ) {
        try Task.checkCancellation()
        if case .result(let result) = event {
          finalOutput = result
        }
      }
      try Task.checkCancellation()
      guard let finalOutput else {
        throw MLXAudioSwiftRuntimeError.invalidAudio
      }
      output = finalOutput
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as MLXAudioSwiftRuntimeError {
      throw error
    } catch {
      throw MLXAudioSwiftRuntimeError.invalidAudio
    }
    let durationMillis = max(0, Int(output.totalTime * 1_000))
    let result = MLXAudioSwiftInferenceOutput(
      text: output.text.trimmingCharacters(in: .whitespacesAndNewlines),
      detectedLanguage: output.language ?? resolvedLanguage,
      processingDurationMillis: durationMillis,
      promptTokenCount: prompt.tokenCount,
      includedKeytermCount: prompt.includedCount,
      omittedKeytermCount: prompt.omittedCount
    )
    // The Sendable output owns no MLX buffers. Reclaim decode intermediates only
    // after it is complete so cancellation and streaming model lifetimes remain intact.
    clearMemoryCache()
    return result
  }

  func release(modelID: String) async throws {
    guard let id = MLXAudioModelID(rawValue: modelID) else {
      throw MLXAudioSwiftRuntimeError.unsupportedModel(modelID)
    }
    loadedModels.removeValue(forKey: id)
    clearMemoryCache()
  }

  func makeStreamingSession(
    modelID: String,
    language: String?,
    profile: SpeechWorkerStreamingProfile,
    downloadIfNeeded: Bool
  ) async throws -> MLXAudioSwiftStreamingHandle {
    _ = try await prepare(
      modelID: modelID,
      downloadIfNeeded: downloadIfNeeded,
      progress: { _ in }
    )
    guard let id = MLXAudioModelID(rawValue: modelID),
      let loadedModel = loadedModels[id]
    else {
      throw MLXAudioSwiftRuntimeError.modelLoadFailed
    }
    let decodeLease = try await decodeGate.acquire()

    let delayPreset: DelayPreset
    switch profile {
    case .realtime:
      delayPreset = .realtime
    case .agent:
      delayPreset = .agent
    case .subtitle:
      delayPreset = .subtitle
    }
    let decodeInterval: Double = profile == .realtime ? 0.5 : 1.0
    let session = StreamingInferenceSession(
      model: loadedModel.model,
      config: StreamingConfig(
        decodeIntervalSeconds: decodeInterval,
        delayPreset: delayPreset,
        language: MLXAudioSwiftQwenOptions.resolvedLanguage(language),
        temperature: 0,
        maxDecodeWindows: 1,
        finalizeCompletedWindows: true
      )
    )
    let (events, continuation) = AsyncStream<MLXAudioSwiftStreamingEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(256)
    )
    let mappingTask = Task {
      defer { decodeLease.release() }
      for await event in session.events {
        guard !Task.isCancelled else { break }
        switch event {
        case .provisional(let text):
          continuation.yield(.transcript(confirmed: "", provisional: text))
        case .confirmed(let text):
          continuation.yield(.transcript(confirmed: text, provisional: ""))
        case .displayUpdate(let confirmedText, let provisionalText):
          continuation.yield(
            .transcript(
              confirmed: confirmedText,
              provisional: provisionalText
            )
          )
        case .stats(let stats):
          continuation.yield(
            .stats(
              SpeechWorkerStreamingStats(
                encodedWindowCount: stats.encodedWindowCount,
                totalAudioSeconds: stats.totalAudioSeconds,
                tokensPerSecond: stats.tokensPerSecond,
                realTimeFactor: stats.realTimeFactor,
                peakMemoryBytes: UInt64(max(stats.peakMemoryGB, 0) * 1_000_000_000)
              )
            )
          )
        case .ended(let fullText):
          continuation.yield(.ended(fullText: fullText))
          continuation.finish()
        }
      }
      continuation.finish()
    }
    return MLXAudioSwiftStreamingHandle(
      events: events,
      feedAudio: { samples in session.feedAudio(samples: samples) },
      stop: { session.stop() },
      cancel: {
        mappingTask.cancel()
        session.cancel()
        continuation.finish()
        decodeLease.release()
      }
    )
  }
}
