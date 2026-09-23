import Darwin
import Foundation
import RillCore

/// Stable, newline-framed protocol shared by the Rill host and speech worker.
///
/// Every frame is one compact JSON object followed by LF. Both peers enforce the
/// byte limits before decoding so an untrusted or corrupted peer cannot grow an
/// unbounded buffer. Paths identify audio only; model locations never cross the
/// process boundary.
public enum SpeechWorkerProtocol {
  public static let version = 5
  public static let maximumRequestByteCount = 64 * 1_024
  public static let maximumResponseByteCount = 1 * 1_024 * 1_024
  public static let maximumAudioPathByteCount = 4 * 1_024
  public static let maximumLanguageByteCount = 64
  public static let maximumKeytermCount = 16
  public static let maximumKeytermByteCount = 48
  public static let maximumKeytermScalarCount = 128
  public static let maximumMetadataEntryCount = 32
  public static let maximumMetadataComponentByteCount = 256
}

public enum SpeechWorkerOperation: String, Codable, Sendable, Equatable {
  case prepareModel
  case recognizeOffline
  case releaseModel
  case prepareTTSModel
  case synthesizeSpeech
  case releaseTTSModel
  case prepareEmbeddingModel
  case embedText
}

/// One bounded worker-side engine. The process entry point owns framing and
/// diagnostics; handlers own only validated operations and engine state.
public protocol SpeechWorkerRequestHandling: Sendable {
  func handle(
    _ request: SpeechWorkerRequest,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void
  ) async -> SpeechWorkerResponse
}

extension SpeechWorkerRequestHandling {
  public func handle(_ request: SpeechWorkerRequest) async -> SpeechWorkerResponse {
    await handle(request, progress: { _ in })
  }
}

public enum SpeechWorkerInputValidation {
  public static func validatedManagedAudioURL(path: String) throws -> URL {
    let audioURL = URL(fileURLWithPath: path).standardizedFileURL
    guard CapturedAudio.isManagedTemporaryFileURL(audioURL),
      try isRegularNonSymbolicFile(audioURL)
    else {
      throw SpeechWorkerClientError.invalidManagedAudio
    }
    return audioURL
  }

  private static func isRegularNonSymbolicFile(_ url: URL) throws -> Bool {
    var status = stat()
    let result = url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      return lstat(path, &status)
    }
    guard result == 0 else { return false }
    return (status.st_mode & S_IFMT) == S_IFREG
  }
}

public struct SpeechWorkerModelPreparationPayload: Codable, Sendable, Equatable {
  public var modelID: String
  public var downloadIfNeeded: Bool

  public init(modelID: String, downloadIfNeeded: Bool) {
    self.modelID = modelID
    self.downloadIfNeeded = downloadIfNeeded
  }
}

public struct SpeechWorkerRecognitionPayload: Codable, Sendable, Equatable {
  public var runID: UUID
  public var modelID: String
  public var language: String?
  public var keyterms: [String]
  public var threadCount: Int
  public var audioFilePath: String
  public var audioDurationSeconds: Double
  public var audioFormat: AudioFormat
  public var downloadIfNeeded: Bool

  public init(
    runID: UUID,
    modelID: String,
    language: String?,
    keyterms: [String],
    threadCount: Int,
    audioFilePath: String,
    audioDurationSeconds: Double,
    audioFormat: AudioFormat,
    downloadIfNeeded: Bool = false
  ) {
    self.runID = runID
    self.modelID = modelID
    self.language = language
    self.keyterms = keyterms
    self.threadCount = threadCount
    self.audioFilePath = audioFilePath
    self.audioDurationSeconds = audioDurationSeconds
    self.audioFormat = audioFormat
    self.downloadIfNeeded = downloadIfNeeded
  }
}

public struct SpeechWorkerSynthesisPayload: Codable, Sendable, Equatable {
  public var runID: UUID
  public var modelID: String
  public var text: String
  public var voice: String
  public var language: String?
  public var downloadIfNeeded: Bool

  public init(
    runID: UUID,
    modelID: String,
    text: String,
    voice: String,
    language: String?,
    downloadIfNeeded: Bool = false
  ) {
    self.runID = runID
    self.modelID = modelID
    self.text = text
    self.voice = voice
    self.language = language
    self.downloadIfNeeded = downloadIfNeeded
  }
}

public struct SpeechWorkerEmbeddingPayload: Codable, Sendable, Equatable {
  public var modelID: String
  public var text: String
  public var purpose: RecordEmbeddingPurpose

  public init(modelID: String, text: String, purpose: RecordEmbeddingPurpose) {
    self.modelID = modelID
    self.text = text
    self.purpose = purpose
  }
}

public enum SpeechWorkerRequestPayload: Codable, Sendable, Equatable {
  case prepareModel(SpeechWorkerModelPreparationPayload)
  case recognizeOffline(SpeechWorkerRecognitionPayload)
  case releaseModel(SpeechWorkerModelPreparationPayload)
  case prepareTTSModel(SpeechWorkerModelPreparationPayload)
  case synthesizeSpeech(SpeechWorkerSynthesisPayload)
  case releaseTTSModel(SpeechWorkerModelPreparationPayload)
  case prepareEmbeddingModel(SpeechWorkerModelPreparationPayload)
  case embedText(SpeechWorkerEmbeddingPayload)
}

/// Internal unary request view. Its wire representation is always a v5
/// `SpeechWorkerFrame`; the computed accessors keep engine handlers focused on
/// one operation while the stored payload remains a closed, strong union.
public struct SpeechWorkerRequest: Sendable, Equatable {
  public var protocolVersion: Int
  public var requestID: UUID
  public var generation: UInt64
  public var payload: SpeechWorkerRequestPayload

  public var operation: SpeechWorkerOperation {
    switch payload {
    case .prepareModel: .prepareModel
    case .recognizeOffline: .recognizeOffline
    case .releaseModel: .releaseModel
    case .prepareTTSModel: .prepareTTSModel
    case .synthesizeSpeech: .synthesizeSpeech
    case .releaseTTSModel: .releaseTTSModel
    case .prepareEmbeddingModel: .prepareEmbeddingModel
    case .embedText: .embedText
    }
  }

  public var recognitionPayload: SpeechWorkerRecognitionPayload? {
    get {
      guard case .recognizeOffline(let value) = payload else { return nil }
      return value
    }
    set {
      guard let newValue, case .recognizeOffline = payload else { return }
      payload = .recognizeOffline(newValue)
    }
  }

  public var modelPreparationPayload: SpeechWorkerModelPreparationPayload? {
    get {
      switch payload {
      case .prepareModel(let value), .releaseModel(let value),
        .prepareTTSModel(let value), .releaseTTSModel(let value),
        .prepareEmbeddingModel(let value):
        value
      case .recognizeOffline, .synthesizeSpeech, .embedText:
        nil
      }
    }
    set {
      guard let newValue else { return }
      switch payload {
      case .prepareModel:
        payload = .prepareModel(newValue)
      case .releaseModel:
        payload = .releaseModel(newValue)
      case .prepareTTSModel:
        payload = .prepareTTSModel(newValue)
      case .releaseTTSModel:
        payload = .releaseTTSModel(newValue)
      case .prepareEmbeddingModel:
        payload = .prepareEmbeddingModel(newValue)
      case .recognizeOffline, .synthesizeSpeech, .embedText:
        break
      }
    }
  }

  public var synthesisPayload: SpeechWorkerSynthesisPayload? {
    get {
      guard case .synthesizeSpeech(let value) = payload else { return nil }
      return value
    }
    set {
      guard let newValue, case .synthesizeSpeech = payload else { return }
      payload = .synthesizeSpeech(newValue)
    }
  }

  public var embeddingPayload: SpeechWorkerEmbeddingPayload? {
    guard case .embedText(let value) = payload else { return nil }
    return value
  }

  public init(
    protocolVersion: Int = SpeechWorkerProtocol.version,
    requestID: UUID,
    generation: UInt64,
    payload: SpeechWorkerRequestPayload
  ) {
    self.protocolVersion = protocolVersion
    self.requestID = requestID
    self.generation = generation
    self.payload = payload
  }

  public init(
    protocolVersion: Int = SpeechWorkerProtocol.version,
    requestID: UUID,
    generation: UInt64,
    payload: SpeechWorkerRecognitionPayload
  ) {
    self.protocolVersion = protocolVersion
    self.requestID = requestID
    self.generation = generation
    self.payload = .recognizeOffline(payload)
  }

  public init(
    protocolVersion: Int = SpeechWorkerProtocol.version,
    requestID: UUID,
    generation: UInt64,
    modelPreparationPayload: SpeechWorkerModelPreparationPayload
  ) {
    self.protocolVersion = protocolVersion
    self.requestID = requestID
    self.generation = generation
    self.payload = .prepareModel(modelPreparationPayload)
  }

  public init(
    protocolVersion: Int = SpeechWorkerProtocol.version,
    requestID: UUID,
    generation: UInt64,
    ttsModelPreparationPayload: SpeechWorkerModelPreparationPayload
  ) {
    self.protocolVersion = protocolVersion
    self.requestID = requestID
    self.generation = generation
    payload = .prepareTTSModel(ttsModelPreparationPayload)
  }

  public init(
    protocolVersion: Int = SpeechWorkerProtocol.version,
    requestID: UUID,
    generation: UInt64,
    synthesisPayload: SpeechWorkerSynthesisPayload
  ) {
    self.protocolVersion = protocolVersion
    self.requestID = requestID
    self.generation = generation
    payload = .synthesizeSpeech(synthesisPayload)
  }

  public init(
    protocolVersion: Int = SpeechWorkerProtocol.version,
    requestID: UUID,
    generation: UInt64,
    releaseTTSModelID: String
  ) {
    self.protocolVersion = protocolVersion
    self.requestID = requestID
    self.generation = generation
    payload = .releaseTTSModel(
      SpeechWorkerModelPreparationPayload(
        modelID: releaseTTSModelID,
        downloadIfNeeded: false
      )
    )
  }

  public init(
    protocolVersion: Int = SpeechWorkerProtocol.version,
    requestID: UUID,
    generation: UInt64,
    releaseModelID: String
  ) {
    self.protocolVersion = protocolVersion
    self.requestID = requestID
    self.generation = generation
    payload = .releaseModel(
      SpeechWorkerModelPreparationPayload(
        modelID: releaseModelID,
        downloadIfNeeded: false
      )
    )
  }
}

public struct SpeechWorkerRecognitionResult: Codable, Sendable, Equatable {
  public var rawText: String
  public var bestText: String
  public var metadata: [String: String]
  public var processingDurationMillis: Int?

  public init(
    rawText: String,
    bestText: String,
    metadata: [String: String],
    processingDurationMillis: Int?
  ) {
    self.rawText = rawText
    self.bestText = bestText
    self.metadata = metadata
    self.processingDurationMillis = processingDurationMillis
  }
}

public struct SpeechWorkerSynthesisResult: Codable, Sendable, Equatable {
  public var audioFilePath: String
  public var sampleRate: Double
  public var channelCount: Int
  public var durationSeconds: Double

  public init(
    audioFilePath: String,
    sampleRate: Double,
    channelCount: Int,
    durationSeconds: Double
  ) {
    self.audioFilePath = audioFilePath
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.durationSeconds = durationSeconds
  }
}

public enum SpeechWorkerFailureCode: String, Codable, Sendable, Equatable {
  case invalidRequest
  case unsupportedProtocol
  case unsupportedModel
  case modelUnavailable
  case invalidAudio
  case recognitionFailed
  case invalidText
  case synthesisFailed
  case invalidSequence
  case streamBusy
  case streamingFailed
  case requestPreempted
  case cancelled
}

public enum SpeechWorkerResponseStatus: String, Codable, Sendable, Equatable {
  case progress
  case success
  case failure
}

public struct SpeechWorkerProgress: Codable, Sendable, Equatable {
  public enum Phase: String, Codable, Sendable, Equatable {
    case downloading
    case loading
  }

  public var phase: Phase
  public var completedUnitCount: Int64
  public var totalUnitCount: Int64

  public init(
    phase: Phase,
    completedUnitCount: Int64,
    totalUnitCount: Int64
  ) {
    self.phase = phase
    self.completedUnitCount = completedUnitCount
    self.totalUnitCount = totalUnitCount
  }

  public var fractionCompleted: Double {
    guard totalUnitCount > 0 else { return 0 }
    return min(max(Double(completedUnitCount) / Double(totalUnitCount), 0), 1)
  }
}

public enum SpeechWorkerResponsePayload: Codable, Sendable, Equatable {
  case progress(SpeechWorkerProgress)
  case recognitionCompleted(SpeechWorkerRecognitionResult)
  case synthesisCompleted(SpeechWorkerSynthesisResult)
  case embeddingCompleted(RecordTextEmbedding)
  case modelPrepared(String)
  case modelReleased(String)
  case failure(SpeechWorkerFailureCode)
}

/// Internal unary response view backed by a closed payload union. Responses
/// share the same sequenced v5 frame envelope as streaming events.
public struct SpeechWorkerResponse: Sendable, Equatable {
  public var protocolVersion: Int
  public var requestID: UUID
  public var generation: UInt64
  public var sequence: UInt64
  public var payload: SpeechWorkerResponsePayload

  public var status: SpeechWorkerResponseStatus {
    switch payload {
    case .progress: .progress
    case .failure: .failure
    case .recognitionCompleted, .synthesisCompleted, .embeddingCompleted, .modelPrepared, .modelReleased:
      .success
    }
  }

  public var result: SpeechWorkerRecognitionResult? {
    guard case .recognitionCompleted(let value) = payload else { return nil }
    return value
  }

  public var synthesisResult: SpeechWorkerSynthesisResult? {
    guard case .synthesisCompleted(let value) = payload else { return nil }
    return value
  }

  public var embeddingResult: RecordTextEmbedding? {
    guard case .embeddingCompleted(let value) = payload else { return nil }
    return value
  }

  public var preparedModelID: String? {
    guard case .modelPrepared(let value) = payload else { return nil }
    return value
  }

  public var releasedModelID: String? {
    guard case .modelReleased(let value) = payload else { return nil }
    return value
  }

  public var progress: SpeechWorkerProgress? {
    get {
      guard case .progress(let value) = payload else { return nil }
      return value
    }
    set {
      guard let newValue, case .progress = payload else { return }
      payload = .progress(newValue)
    }
  }

  public var failure: SpeechWorkerFailureCode? {
    guard case .failure(let value) = payload else { return nil }
    return value
  }

  public init(
    protocolVersion: Int = SpeechWorkerProtocol.version,
    requestID: UUID,
    generation: UInt64,
    sequence: UInt64 = 0,
    payload: SpeechWorkerResponsePayload
  ) {
    self.protocolVersion = protocolVersion
    self.requestID = requestID
    self.generation = generation
    self.sequence = sequence
    self.payload = payload
  }

  public static func success(
    request: SpeechWorkerRequest,
    result: SpeechWorkerRecognitionResult
  ) -> SpeechWorkerResponse {
    SpeechWorkerResponse(
      protocolVersion: SpeechWorkerProtocol.version,
      requestID: request.requestID,
      generation: request.generation,
      payload: .recognitionCompleted(result)
    )
  }

  public static func prepared(
    request: SpeechWorkerRequest,
    modelID: String
  ) -> SpeechWorkerResponse {
    SpeechWorkerResponse(
      protocolVersion: SpeechWorkerProtocol.version,
      requestID: request.requestID,
      generation: request.generation,
      payload: .modelPrepared(modelID)
    )
  }

  public static func synthesized(
    request: SpeechWorkerRequest,
    result: SpeechWorkerSynthesisResult
  ) -> SpeechWorkerResponse {
    SpeechWorkerResponse(
      protocolVersion: SpeechWorkerProtocol.version,
      requestID: request.requestID,
      generation: request.generation,
      payload: .synthesisCompleted(result)
    )
  }

  public static func released(
    request: SpeechWorkerRequest,
    modelID: String
  ) -> SpeechWorkerResponse {
    SpeechWorkerResponse(
      protocolVersion: SpeechWorkerProtocol.version,
      requestID: request.requestID,
      generation: request.generation,
      payload: .modelReleased(modelID)
    )
  }

  public static func progress(
    request: SpeechWorkerRequest,
    update: SpeechWorkerProgress
  ) -> SpeechWorkerResponse {
    SpeechWorkerResponse(
      protocolVersion: SpeechWorkerProtocol.version,
      requestID: request.requestID,
      generation: request.generation,
      payload: .progress(update)
    )
  }

  public static func failure(
    request: SpeechWorkerRequest,
    code: SpeechWorkerFailureCode
  ) -> SpeechWorkerResponse {
    SpeechWorkerResponse(
      protocolVersion: SpeechWorkerProtocol.version,
      requestID: request.requestID,
      generation: request.generation,
      payload: .failure(code)
    )
  }
}

public enum SpeechWorkerProtocolError: Error, LocalizedError, Sendable, Equatable {
  case frameTooLarge
  case unterminatedFrame
  case invalidFrame
  case unsupportedVersion
  case invalidRequest
  case invalidResponse

  public var errorDescription: String? {
    switch self {
    case .frameTooLarge:
      "The speech worker protocol frame exceeded its size limit."
    case .unterminatedFrame:
      "The speech worker protocol frame was incomplete."
    case .invalidFrame:
      "The speech worker protocol frame was invalid."
    case .unsupportedVersion:
      "The speech worker protocol version is unsupported."
    case .invalidRequest:
      "The speech worker request was invalid."
    case .invalidResponse:
      "The speech worker response was invalid."
    }
  }
}

public enum SpeechWorkerProtocolCodec {
  public static func encodeRequestLine(_ request: SpeechWorkerRequest) throws -> Data {
    try validateRequest(request)
    return try SpeechWorkerFrameCodec.encodeCommandLine(
      SpeechWorkerFrame(
        protocolVersion: request.protocolVersion,
        requestID: request.requestID,
        generation: request.generation,
        sessionID: request.requestID,
        sequence: 0,
        body: .request(request.payload)
      )
    )
  }

  public static func decodeRequestLine(_ data: Data) throws -> SpeechWorkerRequest {
    let frame = try SpeechWorkerFrameCodec.decodeCommandLine(data)
    guard frame.sessionID == frame.requestID,
      frame.sequence == 0,
      case .request(let payload) = frame.body
    else {
      throw SpeechWorkerProtocolError.invalidRequest
    }
    let request = SpeechWorkerRequest(
      protocolVersion: frame.protocolVersion,
      requestID: frame.requestID,
      generation: frame.generation,
      payload: payload
    )
    try validateRequest(request)
    return request
  }

  public static func encodeResponseLine(_ response: SpeechWorkerResponse) throws -> Data {
    try validateResponse(response)
    return try SpeechWorkerFrameCodec.encodeEventLine(
      SpeechWorkerFrame(
        protocolVersion: response.protocolVersion,
        requestID: response.requestID,
        generation: response.generation,
        sessionID: response.requestID,
        sequence: response.sequence,
        body: .response(response.payload)
      )
    )
  }

  public static func decodeResponseLine(_ data: Data) throws -> SpeechWorkerResponse {
    let frame = try SpeechWorkerFrameCodec.decodeEventLine(data)
    guard frame.sessionID == frame.requestID,
      case .response(let payload) = frame.body
    else {
      throw SpeechWorkerProtocolError.invalidResponse
    }
    let response = SpeechWorkerResponse(
      protocolVersion: frame.protocolVersion,
      requestID: frame.requestID,
      generation: frame.generation,
      sequence: frame.sequence,
      payload: payload
    )
    try validateResponse(response)
    return response
  }

  static func validateRequest(_ request: SpeechWorkerRequest) throws {
    guard request.protocolVersion == SpeechWorkerProtocol.version else {
      throw SpeechWorkerProtocolError.unsupportedVersion
    }
    guard request.generation > 0 else {
      throw SpeechWorkerProtocolError.invalidRequest
    }
    switch request.operation {
    case .prepareEmbeddingModel:
      guard let payload = request.modelPreparationPayload,
        payload.modelID == RecordEmbeddingModelCatalog.modelID
      else { throw SpeechWorkerProtocolError.invalidRequest }
    case .embedText:
      guard let payload = request.embeddingPayload,
        payload.modelID == RecordEmbeddingModelCatalog.modelID,
        !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        payload.text.utf8.count <= 48 * 1_024
      else { throw SpeechWorkerProtocolError.invalidRequest }
    case .prepareModel, .releaseModel:
      guard request.recognitionPayload == nil,
        request.synthesisPayload == nil,
        let payload = request.modelPreparationPayload,
        isBoundedPlainText(payload.modelID, maximumByteCount: 128),
        MLXAudioModelCatalog.distributableModelIdentifiers.contains(payload.modelID)
      else {
        throw SpeechWorkerProtocolError.invalidRequest
      }
    case .recognizeOffline:
      let acceptsLongAudio =
        request.recognitionPayload.map {
          MLXAudioModelCatalog.distributableModelIdentifiers.contains($0.modelID)
        } ?? false
      guard request.modelPreparationPayload == nil,
        request.synthesisPayload == nil,
        let payload = request.recognitionPayload,
        isBoundedPlainText(payload.modelID, maximumByteCount: 128),
        (1...LocalSpeechRecognitionPolicy.maximumThreadCount).contains(payload.threadCount),
        payload.audioDurationSeconds.isFinite,
        payload.audioDurationSeconds >= 0,
        acceptsLongAudio
          || payload.audioDurationSeconds
            <= LocalSpeechRecognitionPolicy.maximumAcceptedAudioDurationSeconds,
        payload.audioFormat.sampleRateHz.isFinite,
        payload.audioFormat.sampleRateHz > 0,
        payload.audioFormat.channelCount > 0,
        payload.audioFormat.channelCount <= 8,
        isBoundedPath(payload.audioFilePath),
        isBoundedLanguage(payload.language),
        payload.keyterms.count <= SpeechWorkerProtocol.maximumKeytermCount,
        payload.keyterms.allSatisfy(isBoundedKeyterm)
      else {
        throw SpeechWorkerProtocolError.invalidRequest
      }
    case .prepareTTSModel, .releaseTTSModel:
      guard request.recognitionPayload == nil,
        request.synthesisPayload == nil,
        let payload = request.modelPreparationPayload,
        SpeechSynthesisModelCatalog.supportedModelIdentifiers.contains(payload.modelID)
      else {
        throw SpeechWorkerProtocolError.invalidRequest
      }
    case .synthesizeSpeech:
      guard request.recognitionPayload == nil,
        request.modelPreparationPayload == nil,
        let payload = request.synthesisPayload,
        SpeechSynthesisModelCatalog.supportedModelIdentifiers.contains(payload.modelID),
        isBoundedPlainText(
          payload.text,
          maximumByteCount: SpeechSynthesisRequest.maximumTextByteCount
        ),
        payload.text.unicodeScalars.count <= SpeechSynthesisRequest.maximumTextScalarCount,
        isBoundedPlainText(payload.voice, maximumByteCount: 128),
        isBoundedLanguage(payload.language)
      else {
        throw SpeechWorkerProtocolError.invalidRequest
      }
    }
  }

  static func validateResponse(_ response: SpeechWorkerResponse) throws {
    guard response.protocolVersion == SpeechWorkerProtocol.version else {
      throw SpeechWorkerProtocolError.unsupportedVersion
    }
    guard response.generation > 0 else {
      throw SpeechWorkerProtocolError.invalidResponse
    }
    switch response.status {
    case .progress:
      guard response.result == nil,
        response.synthesisResult == nil,
        response.preparedModelID == nil,
        response.releasedModelID == nil,
        response.failure == nil,
        let progress = response.progress,
        progress.completedUnitCount >= 0,
        progress.totalUnitCount > 0,
        progress.completedUnitCount <= progress.totalUnitCount
      else {
        throw SpeechWorkerProtocolError.invalidResponse
      }
    case .success:
      guard response.failure == nil,
        response.progress == nil,
        [
          response.result != nil,
          response.synthesisResult != nil,
          response.embeddingResult != nil,
          response.preparedModelID != nil,
          response.releasedModelID != nil,
        ].filter({ $0 }).count == 1
      else {
        throw SpeechWorkerProtocolError.invalidResponse
      }
      if let result = response.result {
        guard
          result.metadata.count <= SpeechWorkerProtocol.maximumMetadataEntryCount,
          result.metadata.allSatisfy({ key, value in
            isBoundedPlainText(
              key,
              maximumByteCount: SpeechWorkerProtocol.maximumMetadataComponentByteCount
            )
              && isBoundedPlainText(
                value,
                maximumByteCount: SpeechWorkerProtocol.maximumMetadataComponentByteCount
              )
          })
        else {
          throw SpeechWorkerProtocolError.invalidResponse
        }
      }
      if let result = response.embeddingResult {
        guard (1...16).contains(result.vectors.count), result.vectors.allSatisfy({ vector in
          vector.count == 1_024 && vector.allSatisfy(\.isFinite)
        }) else { throw SpeechWorkerProtocolError.invalidResponse }
      }
      if let preparedModelID = response.preparedModelID,
        !isBoundedPlainText(preparedModelID, maximumByteCount: 128)
      {
        throw SpeechWorkerProtocolError.invalidResponse
      }
      if let releasedModelID = response.releasedModelID,
        !isBoundedPlainText(releasedModelID, maximumByteCount: 128)
      {
        throw SpeechWorkerProtocolError.invalidResponse
      }
      if let result = response.synthesisResult {
        guard
          isBoundedPath(result.audioFilePath),
          result.sampleRate.isFinite,
          result.sampleRate > 0,
          result.channelCount == 1,
          result.durationSeconds.isFinite,
          result.durationSeconds > 0
        else {
          throw SpeechWorkerProtocolError.invalidResponse
        }
      }
    case .failure:
      guard response.result == nil,
        response.synthesisResult == nil,
        response.preparedModelID == nil,
        response.releasedModelID == nil,
        response.progress == nil,
        response.failure != nil
      else {
        throw SpeechWorkerProtocolError.invalidResponse
      }
    }
  }

  private static func isBoundedPath(_ value: String) -> Bool {
    guard value.utf8.count <= SpeechWorkerProtocol.maximumAudioPathByteCount,
      value.hasPrefix("/"),
      !value.isEmpty
    else {
      return false
    }
    return !containsControlCharacter(value)
  }

  private static func isBoundedLanguage(_ value: String?) -> Bool {
    guard let value else { return true }
    return isBoundedPlainText(
      value,
      maximumByteCount: SpeechWorkerProtocol.maximumLanguageByteCount
    )
  }

  private static func isBoundedKeyterm(_ value: String) -> Bool {
    !value.isEmpty
      && value.unicodeScalars.count <= SpeechWorkerProtocol.maximumKeytermScalarCount
      && value.utf8.count <= SpeechWorkerProtocol.maximumKeytermByteCount
      && !value.contains(",")
      && !containsControlCharacter(value)
  }

  private static func isBoundedPlainText(_ value: String, maximumByteCount: Int) -> Bool {
    !value.isEmpty
      && value.utf8.count <= maximumByteCount
      && !containsControlCharacter(value)
  }

  private static func containsControlCharacter(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
      CharacterSet.controlCharacters.contains(scalar)
        || CharacterSet.newlines.contains(scalar)
    }
  }
}

/// A stateful reader that preserves bytes after LF for the next protocol frame.
public final class SpeechWorkerBoundedLineReader: @unchecked Sendable {
  private let fileHandle: FileHandle
  private let lock = NSLock()
  private var buffer = Data()
  private var reachedEndOfFile = false

  public init(fileHandle: FileHandle) {
    self.fileHandle = fileHandle
  }

  public func readLine(maximumByteCount: Int) throws -> Data? {
    precondition(maximumByteCount > 0)
    lock.lock()
    defer { lock.unlock() }

    while true {
      if let newlineIndex = buffer.firstIndex(of: 0x0A) {
        let byteCount = buffer.distance(from: buffer.startIndex, to: newlineIndex)
        guard byteCount <= maximumByteCount else {
          buffer.removeAll(keepingCapacity: false)
          throw SpeechWorkerProtocolError.frameTooLarge
        }
        let line = Data(buffer[..<newlineIndex])
        buffer.removeSubrange(buffer.startIndex...newlineIndex)
        return line
      }
      guard buffer.count <= maximumByteCount else {
        buffer.removeAll(keepingCapacity: false)
        throw SpeechWorkerProtocolError.frameTooLarge
      }
      if reachedEndOfFile {
        guard buffer.isEmpty else {
          buffer.removeAll(keepingCapacity: false)
          throw SpeechWorkerProtocolError.unterminatedFrame
        }
        return nil
      }

      var bytes = [UInt8](repeating: 0, count: 4 * 1_024)
      let byteCount = bytes.withUnsafeMutableBytes { buffer in
        Darwin.read(fileHandle.fileDescriptor, buffer.baseAddress, buffer.count)
      }
      if byteCount < 0, errno == EINTR {
        continue
      }
      guard byteCount >= 0 else {
        throw SpeechWorkerProtocolError.invalidFrame
      }
      if byteCount == 0 {
        reachedEndOfFile = true
      } else {
        buffer.append(contentsOf: bytes.prefix(Int(byteCount)))
      }
    }
  }
}
