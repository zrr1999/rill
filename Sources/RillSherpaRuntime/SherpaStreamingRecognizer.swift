import CSherpaOnnx
import Darwin
import Foundation

public struct SherpaStreamingTransducerConfiguration: Equatable, Sendable {
  public static let maximumThreadCount = 16

  public var encoder: URL
  public var decoder: URL
  public var joiner: URL
  public var tokens: URL
  public var threadCount: Int

  public init(
    encoder: URL,
    decoder: URL,
    joiner: URL,
    tokens: URL,
    threadCount: Int = 2
  ) {
    self.encoder = encoder
    self.decoder = decoder
    self.joiner = joiner
    self.tokens = tokens
    self.threadCount = threadCount
  }

  fileprivate func validate() throws {
    guard (1...Self.maximumThreadCount).contains(threadCount) else {
      throw SherpaStreamingRecognizerError.invalidThreadCount(threadCount)
    }
    for artifact in [encoder, decoder, joiner, tokens] {
      guard artifact.isFileURL else {
        throw SherpaStreamingRecognizerError.missingArtifact(artifact)
      }
      var status = stat()
      guard lstat(artifact.path, &status) == 0,
        status.st_mode & S_IFMT == S_IFREG,
        status.st_nlink == 1
      else {
        throw SherpaStreamingRecognizerError.missingArtifact(artifact)
      }
    }
  }
}

public enum SherpaStreamingRecognizerError: Error, Equatable, Sendable {
  case invalidThreadCount(Int)
  case missingArtifact(URL)
  case failedToCreateRecognizer
  case failedToCreateStream
  case emptyAudio
  case invalidAudioSample(index: Int)
  case audioTooLong(sampleCount: Int)
  case invalidSampleRate(Int)
  case decodingFailed
  case streamFinished
}

/// A reusable native recognizer. Each capture creates an independent stream
/// carrying its own incremental decoder state.
public final class SherpaStreamingRecognizer: @unchecked Sendable {
  public let configuration: SherpaStreamingTransducerConfiguration

  fileprivate let handle: OpaquePointer

  public init(configuration: SherpaStreamingTransducerConfiguration) throws {
    try configuration.validate()
    self.configuration = configuration

    let created = configuration.encoder.path.withCString { encoder in
      configuration.decoder.path.withCString { decoder in
        configuration.joiner.path.withCString { joiner in
          configuration.tokens.path.withCString { tokens in
            RillSherpaCreateStreamingZipformerRecognizer(
              encoder,
              decoder,
              joiner,
              tokens,
              Int32(configuration.threadCount)
            )
          }
        }
      }
    }
    guard let created else {
      throw SherpaStreamingRecognizerError.failedToCreateRecognizer
    }
    handle = created
  }

  deinit {
    RillSherpaDestroyOnlineRecognizer(handle)
  }

  public func makeStream() throws -> SherpaStreamingRecognitionStream {
    try SherpaStreamingRecognitionStream(recognizer: self)
  }
}

public final class SherpaStreamingRecognitionStream: @unchecked Sendable {
  private let recognizer: SherpaStreamingRecognizer
  private let handle: OpaquePointer
  private let lock = NSLock()
  private var isFinished = false

  fileprivate init(recognizer: SherpaStreamingRecognizer) throws {
    guard let handle = RillSherpaCreateOnlineStream(recognizer.handle) else {
      throw SherpaStreamingRecognizerError.failedToCreateStream
    }
    self.recognizer = recognizer
    self.handle = handle
  }

  deinit {
    RillSherpaDestroyOnlineStream(handle)
  }

  public func accept(samples: [Float], sampleRate: Int = 16_000) throws -> String {
    guard !samples.isEmpty else {
      throw SherpaStreamingRecognizerError.emptyAudio
    }
    guard samples.count <= Int(Int32.max) else {
      throw SherpaStreamingRecognizerError.audioTooLong(sampleCount: samples.count)
    }
    guard sampleRate > 0, sampleRate <= Int(Int32.max) else {
      throw SherpaStreamingRecognizerError.invalidSampleRate(sampleRate)
    }
    if let invalidIndex = samples.firstIndex(where: {
      !$0.isFinite || !(-1...1).contains($0)
    }) {
      throw SherpaStreamingRecognizerError.invalidAudioSample(index: invalidIndex)
    }

    lock.lock()
    defer { lock.unlock() }
    guard !isFinished else {
      throw SherpaStreamingRecognizerError.streamFinished
    }
    var text: UnsafeMutablePointer<CChar>?
    let succeeded = samples.withUnsafeBufferPointer { buffer in
      RillSherpaOnlineStreamAcceptAndDecode(
        recognizer.handle,
        handle,
        buffer.baseAddress,
        Int32(buffer.count),
        Int32(sampleRate),
        &text
      )
    }
    guard succeeded == 1, let text else {
      throw SherpaStreamingRecognizerError.decodingFailed
    }
    defer { RillSherpaFreeString(text) }
    return String(cString: text)
  }

  public func finish() throws -> String {
    lock.lock()
    defer { lock.unlock() }
    guard !isFinished else {
      throw SherpaStreamingRecognizerError.streamFinished
    }
    isFinished = true
    var text: UnsafeMutablePointer<CChar>?
    guard
      RillSherpaOnlineStreamFinishAndDecode(
        recognizer.handle,
        handle,
        &text
      ) == 1,
      let text
    else {
      throw SherpaStreamingRecognizerError.decodingFailed
    }
    defer { RillSherpaFreeString(text) }
    return String(cString: text)
  }
}
