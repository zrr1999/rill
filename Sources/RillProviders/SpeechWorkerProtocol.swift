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
  public static let version = 4
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
  case prepareTTSModel
  case synthesizeSpeech
  case releaseTTSModel
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

public struct SpeechWorkerRequest: Codable, Sendable, Equatable {
  public var protocolVersion: Int
  public var requestID: UUID
  public var generation: UInt64
  public var operation: SpeechWorkerOperation
  public var recognitionPayload: SpeechWorkerRecognitionPayload?
  public var modelPreparationPayload: SpeechWorkerModelPreparationPayload?
  public var synthesisPayload: SpeechWorkerSynthesisPayload?

  public init(
    protocolVersion: Int = SpeechWorkerProtocol.version,
    requestID: UUID,
    generation: UInt64,
    payload: SpeechWorkerRecognitionPayload
  ) {
    self.protocolVersion = protocolVersion
    self.requestID = requestID
    self.generation = generation
    self.operation = .recognizeOffline
    self.recognitionPayload = payload
    self.modelPreparationPayload = nil
    self.synthesisPayload = nil
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
    self.operation = .prepareModel
    self.recognitionPayload = nil
    self.modelPreparationPayload = modelPreparationPayload
    self.synthesisPayload = nil
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
    self.operation = .prepareTTSModel
    recognitionPayload = nil
    modelPreparationPayload = ttsModelPreparationPayload
    synthesisPayload = nil
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
    self.operation = .synthesizeSpeech
    recognitionPayload = nil
    modelPreparationPayload = nil
    self.synthesisPayload = synthesisPayload
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
    operation = .releaseTTSModel
    recognitionPayload = nil
    modelPreparationPayload = SpeechWorkerModelPreparationPayload(
      modelID: releaseTTSModelID,
      downloadIfNeeded: false
    )
    synthesisPayload = nil
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

public struct SpeechWorkerResponse: Codable, Sendable, Equatable {
  public var protocolVersion: Int
  public var requestID: UUID
  public var generation: UInt64
  public var status: SpeechWorkerResponseStatus
  public var result: SpeechWorkerRecognitionResult?
  public var synthesisResult: SpeechWorkerSynthesisResult?
  public var preparedModelID: String?
  public var releasedModelID: String?
  public var progress: SpeechWorkerProgress?
  public var failure: SpeechWorkerFailureCode?

  public static func success(
    request: SpeechWorkerRequest,
    result: SpeechWorkerRecognitionResult
  ) -> SpeechWorkerResponse {
    SpeechWorkerResponse(
      protocolVersion: SpeechWorkerProtocol.version,
      requestID: request.requestID,
      generation: request.generation,
      status: .success,
      result: result,
      synthesisResult: nil,
      preparedModelID: nil,
      releasedModelID: nil,
      progress: nil,
      failure: nil
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
      status: .success,
      result: nil,
      synthesisResult: nil,
      preparedModelID: modelID,
      releasedModelID: nil,
      progress: nil,
      failure: nil
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
      status: .success,
      result: nil,
      synthesisResult: result,
      preparedModelID: nil,
      releasedModelID: nil,
      progress: nil,
      failure: nil
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
      status: .success,
      result: nil,
      synthesisResult: nil,
      preparedModelID: nil,
      releasedModelID: modelID,
      progress: nil,
      failure: nil
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
      status: .progress,
      result: nil,
      synthesisResult: nil,
      preparedModelID: nil,
      releasedModelID: nil,
      progress: update,
      failure: nil
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
      status: .failure,
      result: nil,
      synthesisResult: nil,
      preparedModelID: nil,
      releasedModelID: nil,
      progress: nil,
      failure: code
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
    try validate(request)
    return try encodeLine(request, maximumByteCount: SpeechWorkerProtocol.maximumRequestByteCount)
  }

  public static func decodeRequestLine(_ data: Data) throws -> SpeechWorkerRequest {
    guard data.count <= SpeechWorkerProtocol.maximumRequestByteCount else {
      throw SpeechWorkerProtocolError.frameTooLarge
    }
    let request: SpeechWorkerRequest = try decode(data)
    try validate(request)
    return request
  }

  public static func encodeResponseLine(_ response: SpeechWorkerResponse) throws -> Data {
    try validate(response)
    return try encodeLine(
      response,
      maximumByteCount: SpeechWorkerProtocol.maximumResponseByteCount
    )
  }

  public static func decodeResponseLine(_ data: Data) throws -> SpeechWorkerResponse {
    guard data.count <= SpeechWorkerProtocol.maximumResponseByteCount else {
      throw SpeechWorkerProtocolError.frameTooLarge
    }
    let response: SpeechWorkerResponse = try decode(data)
    try validate(response)
    return response
  }

  private static func encodeLine<Value: Encodable>(
    _ value: Value,
    maximumByteCount: Int
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let frame: Data
    do {
      frame = try encoder.encode(value)
    } catch {
      throw SpeechWorkerProtocolError.invalidFrame
    }
    guard frame.count <= maximumByteCount else {
      throw SpeechWorkerProtocolError.frameTooLarge
    }
    var line = frame
    line.append(0x0A)
    return line
  }

  private static func decode<Value: Decodable>(_ data: Data) throws -> Value {
    do {
      return try JSONDecoder().decode(Value.self, from: data)
    } catch {
      throw SpeechWorkerProtocolError.invalidFrame
    }
  }

  private static func validate(_ request: SpeechWorkerRequest) throws {
    guard request.protocolVersion == SpeechWorkerProtocol.version else {
      throw SpeechWorkerProtocolError.unsupportedVersion
    }
    guard request.generation > 0 else {
      throw SpeechWorkerProtocolError.invalidRequest
    }
    switch request.operation {
    case .prepareModel:
      guard request.recognitionPayload == nil,
        request.synthesisPayload == nil,
        let payload = request.modelPreparationPayload,
        isBoundedPlainText(payload.modelID, maximumByteCount: 128)
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
        (1...SherpaOnnxRecognizer.maximumThreadCount).contains(payload.threadCount),
        payload.audioDurationSeconds.isFinite,
        payload.audioDurationSeconds >= 0,
        acceptsLongAudio
          || payload.audioDurationSeconds
            <= SherpaOnnxRecognizer.maximumAcceptedAudioDurationSeconds,
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

  private static func validate(_ response: SpeechWorkerResponse) throws {
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
