@preconcurrency import AVFoundation
import Foundation
import RillCore

public enum SystemSpeechSynthesisError: Error, LocalizedError, Sendable {
  case invalidRequest
  case outputCreationFailed
  case synthesisFailed

  public var errorDescription: String? {
    switch self {
    case .invalidRequest:
      return "The speech synthesis request is invalid."
    case .outputCreationFailed:
      return "The system speech output file could not be created."
    case .synthesisFailed:
      return "The system voice could not synthesize this text."
    }
  }
}

public actor SystemSpeechSynthesizer: SpeechSynthesizer {
  public nonisolated let id = "speech.system"
  private var activeSession: SystemSpeechWriteSession?

  public init() {}

  public func synthesize(_ request: SpeechSynthesisRequest) async throws -> SpeechAsset {
    guard request.isValid else {
      throw SystemSpeechSynthesisError.invalidRequest
    }
    activeSession?.cancel()
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-speech-\(request.runID.uuidString.lowercased())-\(UUID().uuidString.lowercased()).wav"
    )
    let session = SystemSpeechWriteSession(outputURL: outputURL)
    activeSession = session
    defer {
      if activeSession === session {
        activeSession = nil
      }
    }
    do {
      let result = try await session.synthesize(request)
      return try SpeechAsset(
        fileURL: outputURL,
        durationSeconds: result.durationSeconds,
        format: AudioFormat(
          sampleRateHz: result.sampleRate,
          channelCount: result.channelCount,
          encoding: .float32
        ),
        ownership: .managedTemporary
      )
    } catch {
      try? FileManager.default.removeItem(at: outputURL)
      throw error
    }
  }

  public func releaseResources() async {
    activeSession?.cancel()
    activeSession = nil
  }
}

private final class SystemSpeechWriteSession: @unchecked Sendable {
  struct Result: Sendable {
    let durationSeconds: Double
    let sampleRate: Double
    let channelCount: Int
  }

  private let outputURL: URL
  private let lock = NSLock()
  private let synthesizer = AVSpeechSynthesizer()
  private var continuation: CheckedContinuation<Result, Error>?
  private var outputFile: AVAudioFile?
  private var sampleRate = Double.zero
  private var channelCount = 0
  private var frameCount: AVAudioFramePosition = 0
  private var completed = false

  init(outputURL: URL) {
    self.outputURL = outputURL
  }

  func synthesize(_ request: SpeechSynthesisRequest) async throws -> Result {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.withLock {
          self.continuation = continuation
        }
        let utterance = AVSpeechUtterance(string: request.text)
        let language =
          request.language?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? Self.inferredLanguage(for: request.text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        synthesizer.write(utterance) { [weak self] buffer in
          self?.accept(buffer)
        }
      }
    } onCancel: {
      self.cancel()
    }
  }

  func cancel() {
    synthesizer.stopSpeaking(at: .immediate)
    finish(.failure(CancellationError()))
  }

  private func accept(_ buffer: AVAudioBuffer) {
    guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
      finish(.failure(SystemSpeechSynthesisError.synthesisFailed))
      return
    }
    if pcmBuffer.frameLength == 0 {
      let result = lock.withLock { () -> Result? in
        guard
          sampleRate > 0,
          channelCount > 0,
          frameCount > 0
        else {
          return nil
        }
        return Result(
          durationSeconds: Double(frameCount) / sampleRate,
          sampleRate: sampleRate,
          channelCount: channelCount
        )
      }
      finish(
        result.map { .success($0) } ??
          .failure(SystemSpeechSynthesisError.synthesisFailed)
      )
      return
    }

    do {
      try lock.withLock {
        guard !completed else { return }
        if outputFile == nil {
          outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: pcmBuffer.format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
          )
          sampleRate = pcmBuffer.format.sampleRate
          channelCount = Int(pcmBuffer.format.channelCount)
        }
        try outputFile?.write(from: pcmBuffer)
        frameCount += AVAudioFramePosition(pcmBuffer.frameLength)
      }
    } catch {
      synthesizer.stopSpeaking(at: .immediate)
      finish(.failure(SystemSpeechSynthesisError.outputCreationFailed))
    }
  }

  private func finish(_ result: Swift.Result<Result, Error>) {
    let continuation:
      CheckedContinuation<Result, Error>? = lock.withLock {
      guard !completed else { return nil }
      completed = true
      outputFile = nil
      let continuation = self.continuation
      self.continuation = nil
      return continuation
    }
    continuation?.resume(with: result)
  }

  private static func inferredLanguage(for text: String) -> String {
    text.unicodeScalars.contains(where: {
      (0x3400...0x4DBF).contains($0.value)
        || (0x4E00...0x9FFF).contains($0.value)
    }) ? "zh-CN" : "en-US"
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
