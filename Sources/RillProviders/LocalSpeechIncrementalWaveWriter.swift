@preconcurrency import AVFoundation
import Foundation

enum LocalSpeechCaptureLimits {
  static let sampleRateHz = 16_000.0
  static let maximumRequestedDurationSeconds = 120.0
  static let startupToleranceSeconds = 3.1
  static let maximumAcceptedDurationSeconds =
    maximumRequestedDurationSeconds + startupToleranceSeconds
  static let maximumAcceptedFrameCount = Int(
    (maximumAcceptedDurationSeconds * sampleRateHz).rounded(.down)
  )
}

struct LocalSpeechRecordingArtifact: Sendable, Equatable {
  let fileURL: URL
  let frameCount: Int
}

protocol LocalSpeechRecordingWriting: AnyObject, Sendable {
  var fileURL: URL { get }

  func append(_ samples: [Float]) throws
  func removeFrameLimit()
  func finalize() throws -> LocalSpeechRecordingArtifact
  func closeForDiscard()
}

extension LocalSpeechRecordingWriting {
  func removeFrameLimit() {}
}

typealias LocalSpeechRecordingWriterFactory =
  @Sendable (URL, Int?) throws -> any LocalSpeechRecordingWriting

enum LocalSpeechIncrementalWaveWriterError: Error, Sendable, Equatable {
  case invalidSamples
  case alreadyClosed
  case invalidFrameLimit
  case frameCountOverflow
  case frameLimitExceeded
}

final class LocalSpeechIncrementalWaveWriter: LocalSpeechRecordingWriting, @unchecked Sendable {
  static let sampleRateHz = LocalSpeechCaptureLimits.sampleRateHz
  static let framesPerWrite = 1_600
  static let maximumRequestedDurationSeconds =
    LocalSpeechCaptureLimits.maximumRequestedDurationSeconds
  static let maximumStartupGraceSeconds = LocalSpeechCaptureLimits.startupToleranceSeconds
  static let maximumSupportedDurationSeconds =
    LocalSpeechCaptureLimits.maximumAcceptedDurationSeconds
  static let maximumSupportedFrameCount = LocalSpeechCaptureLimits.maximumAcceptedFrameCount
  static let requiredFilePermissions = 0o600

  let fileURL: URL

  private let lock = NSLock()
  private let format: AVAudioFormat
  private let scratchBuffer: AVAudioPCMBuffer
  private var maximumFrameCount: Int?
  private var audioFile: AVAudioFile?
  private var frameCount = 0

  init(
    fileURL: URL,
    maximumFrameCount: Int? = LocalSpeechIncrementalWaveWriter.maximumSupportedFrameCount
  ) throws {
    if let maximumFrameCount, maximumFrameCount < 0 {
      throw LocalSpeechIncrementalWaveWriterError.invalidFrameLimit
    }
    self.fileURL = fileURL
    self.maximumFrameCount = maximumFrameCount
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Self.sampleRateHz,
        channels: 1,
        interleaved: false
      ),
      let scratchBuffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(Self.framesPerWrite)
      )
    else {
      throw RealtimeAudioCaptureService.CaptureError.microphoneStartFailed
    }
    self.format = format
    self.scratchBuffer = scratchBuffer

    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: fileURL.path) {
      try fileManager.removeItem(at: fileURL)
    }
    let audioFile = try AVAudioFile(
      forWriting: fileURL,
      settings: format.settings,
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: Self.requiredFilePermissions)],
      ofItemAtPath: fileURL.path
    )
    self.audioFile = audioFile
  }

  func append(_ samples: [Float]) throws {
    guard !samples.isEmpty else { return }
    guard samples.allSatisfy(\.isFinite) else {
      throw LocalSpeechIncrementalWaveWriterError.invalidSamples
    }

    try lock.withLock {
      guard let audioFile else {
        throw LocalSpeechIncrementalWaveWriterError.alreadyClosed
      }
      guard frameCount <= Int.max - samples.count else {
        throw LocalSpeechIncrementalWaveWriterError.frameCountOverflow
      }
      if let maximumFrameCount {
        guard frameCount + samples.count <= maximumFrameCount else {
          throw LocalSpeechIncrementalWaveWriterError.frameLimitExceeded
        }
      }

      var offset = 0
      while offset < samples.count {
        let writeCount = min(Self.framesPerWrite, samples.count - offset)
        scratchBuffer.frameLength = AVAudioFrameCount(writeCount)
        guard let channel = scratchBuffer.floatChannelData?.pointee else {
          throw RealtimeAudioCaptureService.CaptureError.microphoneStartFailed
        }
        samples.withUnsafeBufferPointer { pointer in
          guard let baseAddress = pointer.baseAddress else { return }
          channel.update(from: baseAddress.advanced(by: offset), count: writeCount)
        }
        try audioFile.write(from: scratchBuffer)
        frameCount += writeCount
        offset += writeCount
      }
    }
  }

  func removeFrameLimit() {
    lock.withLock {
      maximumFrameCount = nil
    }
  }

  func finalize() throws -> LocalSpeechRecordingArtifact {
    try lock.withLock {
      guard audioFile != nil else {
        throw LocalSpeechIncrementalWaveWriterError.alreadyClosed
      }
      audioFile = nil
      return LocalSpeechRecordingArtifact(fileURL: fileURL, frameCount: frameCount)
    }
  }

  func closeForDiscard() {
    lock.withLock {
      audioFile = nil
    }
  }
}
