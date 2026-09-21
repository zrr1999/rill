import Foundation
import RillCore

/// The single duplex envelope used by every speech-worker v5 command and event.
/// Unary operations use strong request/response payloads; live audio uses
/// bounded, sequenced PCM commands and asynchronous stream events.
public struct SpeechWorkerFrame: Codable, Sendable, Equatable {
  public var protocolVersion: Int
  public var requestID: UUID
  public var generation: UInt64
  public var sessionID: UUID
  public var sequence: UInt64
  public var kind: SpeechWorkerFrameKind
  public var body: SpeechWorkerFrameBody

  public init(
    protocolVersion: Int = SpeechWorkerProtocol.version,
    requestID: UUID,
    generation: UInt64,
    sessionID: UUID,
    sequence: UInt64,
    body: SpeechWorkerFrameBody
  ) {
    self.protocolVersion = protocolVersion
    self.requestID = requestID
    self.generation = generation
    self.sessionID = sessionID
    self.sequence = sequence
    self.kind = body.kind
    self.body = body
  }
}

public enum SpeechWorkerFrameKind: String, Codable, Sendable, Equatable {
  case command
  case event
}

public enum SpeechWorkerFrameBody: Codable, Sendable, Equatable {
  case request(SpeechWorkerRequestPayload)
  case response(SpeechWorkerResponsePayload)
  case command(SpeechWorkerStreamCommand)
  case event(SpeechWorkerStreamEvent)
}

extension SpeechWorkerFrameBody {
  fileprivate var kind: SpeechWorkerFrameKind {
    switch self {
    case .request, .command: .command
    case .response, .event: .event
    }
  }
}

public enum SpeechWorkerStreamMode: String, Codable, Sendable, Equatable, CaseIterable {
  case vadOnly = "vad-only"
  case vadAndTranscription = "vad-and-transcription"
}

public enum SpeechWorkerStreamingProfile: String, Codable, Sendable, Equatable, CaseIterable {
  case realtime
  case agent
  case subtitle
}

public enum SpeechWorkerTaskPriority: Int, Codable, Sendable, Equatable, Comparable, CaseIterable {
  case background = 0
  case wakeCandidate = 10
  case foregroundFinal = 20
  case interactive = 30
  case voiceActivity = 40

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public struct SpeechWorkerStreamStart: Codable, Sendable, Equatable {
  public var modelID: String
  public var language: String?
  public var keyterms: [String]
  public var mode: SpeechWorkerStreamMode
  public var profile: SpeechWorkerStreamingProfile
  public var priority: SpeechWorkerTaskPriority
  public var audioFormat: AudioFormat
  public var downloadIfNeeded: Bool

  public init(
    modelID: String,
    language: String?,
    keyterms: [String],
    mode: SpeechWorkerStreamMode,
    profile: SpeechWorkerStreamingProfile,
    priority: SpeechWorkerTaskPriority,
    audioFormat: AudioFormat = SpeechWorkerStreamingProtocol.requiredAudioFormat,
    downloadIfNeeded: Bool = false
  ) {
    self.modelID = modelID
    self.language = language
    self.keyterms = keyterms
    self.mode = mode
    self.profile = profile
    self.priority = priority
    self.audioFormat = audioFormat
    self.downloadIfNeeded = downloadIfNeeded
  }
}

public struct SpeechWorkerAudioChunk: Codable, Sendable, Equatable {
  /// IEEE-754 Float32, little-endian, mono PCM. `Data` uses Codable's bounded
  /// Base64 representation on the JSONL wire.
  public var pcmFloat32LittleEndian: Data

  public init(pcmFloat32LittleEndian: Data) {
    self.pcmFloat32LittleEndian = pcmFloat32LittleEndian
  }

  public init(samples: [Float]) {
    var values = samples.map(\.bitPattern).map { $0.littleEndian }
    self.pcmFloat32LittleEndian = values.withUnsafeMutableBytes { Data($0) }
  }

  public func decodedSamples() throws -> [Float] {
    let data = pcmFloat32LittleEndian
    guard !data.isEmpty,
      data.count.isMultiple(of: MemoryLayout<UInt32>.size),
      data.count <= SpeechWorkerStreamingProtocol.maximumAudioPayloadByteCount
    else {
      throw SpeechWorkerProtocolError.invalidFrame
    }
    let words: [UInt32] = data.withUnsafeBytes { bytes in
      stride(from: 0, to: data.count, by: MemoryLayout<UInt32>.size).map {
        bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self)
      }
    }
    let samples = words.map { Float(bitPattern: UInt32(littleEndian: $0)) }
    guard samples.allSatisfy(\.isFinite) else {
      throw SpeechWorkerProtocolError.invalidFrame
    }
    return samples
  }
}

public enum SpeechWorkerStreamCommand: Codable, Sendable, Equatable {
  /// Worker-internal control command used by the supervisor to yield a lower
  /// priority unary decode at an upstream cancellation-safe token boundary.
  case cancelRequest(UUID)
  case start(SpeechWorkerStreamStart)
  case appendAudio(SpeechWorkerAudioChunk)
  case finish
  case cancel
}

public struct SpeechWorkerVADActivity: Codable, Sendable, Equatable {
  public var probability: Float
  public var isSpeech: Bool
  public var sampleOffset: UInt64

  public init(probability: Float, isSpeech: Bool, sampleOffset: UInt64) {
    self.probability = probability
    self.isSpeech = isSpeech
    self.sampleOffset = sampleOffset
  }
}

public struct SpeechWorkerTranscriptUpdate: Codable, Sendable, Equatable {
  public var confirmed: String
  public var provisional: String

  public init(confirmed: String, provisional: String) {
    self.confirmed = confirmed
    self.provisional = provisional
  }
}

public struct SpeechWorkerStreamingStats: Codable, Sendable, Equatable {
  public var encodedWindowCount: Int
  public var totalAudioSeconds: Double
  public var tokensPerSecond: Double
  public var realTimeFactor: Double
  public var peakMemoryBytes: UInt64

  public init(
    encodedWindowCount: Int,
    totalAudioSeconds: Double,
    tokensPerSecond: Double,
    realTimeFactor: Double,
    peakMemoryBytes: UInt64
  ) {
    self.encodedWindowCount = encodedWindowCount
    self.totalAudioSeconds = totalAudioSeconds
    self.tokensPerSecond = tokensPerSecond
    self.realTimeFactor = realTimeFactor
    self.peakMemoryBytes = peakMemoryBytes
  }
}

public enum SpeechWorkerStreamEvent: Codable, Sendable, Equatable {
  case accepted(queuePosition: Int)
  case started(modelID: String)
  case vadActivity(SpeechWorkerVADActivity)
  case speechStarted(sampleOffset: UInt64)
  case speechEnded(sampleOffset: UInt64)
  case transcriptUpdate(SpeechWorkerTranscriptUpdate)
  case stats(SpeechWorkerStreamingStats)
  case completed(previewText: String)
  case failure(SpeechWorkerFailureCode)
}

public enum SpeechWorkerStreamingProtocol {
  public static let requiredAudioFormat = AudioFormat(
    sampleRateHz: 16_000,
    channelCount: 1,
    encoding: .float32
  )
  public static let preferredSamplesPerFrame = 1_600
  public static let maximumSamplesPerFrame = 3_200
  public static let maximumAudioPayloadByteCount =
    maximumSamplesPerFrame * MemoryLayout<Float>.size
  public static let maximumTranscriptByteCount = 64 * 1_024
  public static let maximumStreamEventCount = 100_000
}

public enum MLXSileroVADConstants {
  public static let modelID = "mlx-community/silero-vad-v6"
  public static let chunkSampleCount = 512
}

public enum SpeechWorkerFrameCodec {
  public static func encodeCommandLine(_ frame: SpeechWorkerFrame) throws -> Data {
    try validateCommand(frame)
    return try encode(
      frame,
      maximumByteCount: SpeechWorkerProtocol.maximumRequestByteCount
    )
  }

  public static func decodeCommandLine(_ data: Data) throws -> SpeechWorkerFrame {
    guard data.count <= SpeechWorkerProtocol.maximumRequestByteCount else {
      throw SpeechWorkerProtocolError.frameTooLarge
    }
    let frame = try decode(data)
    try validateCommand(frame)
    return frame
  }

  public static func encodeEventLine(_ frame: SpeechWorkerFrame) throws -> Data {
    try validateEvent(frame)
    return try encode(
      frame,
      maximumByteCount: SpeechWorkerProtocol.maximumResponseByteCount
    )
  }

  public static func decodeEventLine(_ data: Data) throws -> SpeechWorkerFrame {
    guard data.count <= SpeechWorkerProtocol.maximumResponseByteCount else {
      throw SpeechWorkerProtocolError.frameTooLarge
    }
    let frame = try decode(data)
    try validateEvent(frame)
    return frame
  }

  public static func isStreamingFrame(_ data: Data) -> Bool {
    guard let frame = try? decode(data) else { return false }
    switch frame.body {
    case .command, .event:
      return true
    case .request, .response:
      return false
    }
  }

  private static func validateBase(_ frame: SpeechWorkerFrame) throws {
    guard frame.protocolVersion == SpeechWorkerProtocol.version,
      frame.generation > 0
    else {
      throw SpeechWorkerProtocolError.unsupportedVersion
    }
  }

  private static func validateCommand(_ frame: SpeechWorkerFrame) throws {
    try validateBase(frame)
    guard frame.kind == .command else {
      throw SpeechWorkerProtocolError.invalidFrame
    }
    if case .request(let payload) = frame.body {
      guard frame.sessionID == frame.requestID, frame.sequence == 0 else {
        throw SpeechWorkerProtocolError.invalidFrame
      }
      try SpeechWorkerProtocolCodec.validateRequest(
        SpeechWorkerRequest(
          protocolVersion: frame.protocolVersion,
          requestID: frame.requestID,
          generation: frame.generation,
          payload: payload
        )
      )
      return
    }
    guard case .command(let command) = frame.body else {
      throw SpeechWorkerProtocolError.invalidFrame
    }
    switch command {
    case .cancelRequest(let requestID):
      guard frame.sequence == 0, frame.sessionID == requestID else {
        throw SpeechWorkerProtocolError.invalidFrame
      }
    case .start(let payload):
      guard frame.sequence == 0,
        payload.audioFormat == SpeechWorkerStreamingProtocol.requiredAudioFormat,
        !payload.modelID.isEmpty,
        payload.modelID.utf8.count <= 256,
        payload.keyterms.count <= SpeechWorkerProtocol.maximumKeytermCount,
        (payload.language?.utf8.count ?? 0)
          <= SpeechWorkerProtocol.maximumLanguageByteCount,
        payload.keyterms.allSatisfy({
          !$0.isEmpty
            && $0.utf8.count <= SpeechWorkerProtocol.maximumKeytermByteCount
            && $0.unicodeScalars.count
              <= SpeechWorkerProtocol.maximumKeytermScalarCount
        })
      else {
        throw SpeechWorkerProtocolError.invalidFrame
      }
    case .appendAudio(let chunk):
      guard frame.sequence > 0 else {
        throw SpeechWorkerProtocolError.invalidFrame
      }
      _ = try chunk.decodedSamples()
    case .finish, .cancel:
      guard frame.sequence > 0 else {
        throw SpeechWorkerProtocolError.invalidFrame
      }
    }
  }

  private static func validateEvent(_ frame: SpeechWorkerFrame) throws {
    try validateBase(frame)
    guard frame.kind == .event else {
      throw SpeechWorkerProtocolError.invalidFrame
    }
    if case .response(let payload) = frame.body {
      guard frame.sessionID == frame.requestID else {
        throw SpeechWorkerProtocolError.invalidFrame
      }
      try SpeechWorkerProtocolCodec.validateResponse(
        SpeechWorkerResponse(
          protocolVersion: frame.protocolVersion,
          requestID: frame.requestID,
          generation: frame.generation,
          sequence: frame.sequence,
          payload: payload
        )
      )
      return
    }
    guard case .event(let event) = frame.body else {
      throw SpeechWorkerProtocolError.invalidFrame
    }
    switch event {
    case .accepted(let position):
      guard position >= 0 else { throw SpeechWorkerProtocolError.invalidFrame }
    case .started(let modelID):
      guard !modelID.isEmpty, modelID.utf8.count <= 256 else {
        throw SpeechWorkerProtocolError.invalidFrame
      }
    case .vadActivity(let activity):
      guard activity.probability.isFinite,
        (0...1).contains(activity.probability)
      else {
        throw SpeechWorkerProtocolError.invalidFrame
      }
    case .transcriptUpdate(let update):
      guard update.confirmed.utf8.count <= SpeechWorkerStreamingProtocol.maximumTranscriptByteCount,
        update.provisional.utf8.count <= SpeechWorkerStreamingProtocol.maximumTranscriptByteCount
      else {
        throw SpeechWorkerProtocolError.frameTooLarge
      }
    case .stats(let stats):
      guard stats.encodedWindowCount >= 0,
        stats.totalAudioSeconds.isFinite,
        stats.totalAudioSeconds >= 0,
        stats.tokensPerSecond.isFinite,
        stats.tokensPerSecond >= 0,
        stats.realTimeFactor.isFinite,
        stats.realTimeFactor >= 0
      else {
        throw SpeechWorkerProtocolError.invalidFrame
      }
    case .completed(let text):
      guard text.utf8.count <= SpeechWorkerStreamingProtocol.maximumTranscriptByteCount else {
        throw SpeechWorkerProtocolError.frameTooLarge
      }
    case .speechStarted, .speechEnded, .failure:
      break
    }
  }

  private static func encode<T: Encodable>(
    _ value: T,
    maximumByteCount: Int
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0A)
    guard data.count <= maximumByteCount else {
      throw SpeechWorkerProtocolError.frameTooLarge
    }
    return data
  }

  private static func decode(_ data: Data) throws -> SpeechWorkerFrame {
    let payload: Data
    if data.last == 0x0A {
      payload = data.dropLast()
    } else {
      payload = data
    }
    do {
      return try JSONDecoder().decode(SpeechWorkerFrame.self, from: payload)
    } catch {
      throw SpeechWorkerProtocolError.invalidFrame
    }
  }
}
