import Foundation
import RillSherpaRuntime

protocol LocalSpeechStreamingPreviewSession: AnyObject, Sendable {
  func accept(samples: [Float]) throws -> String
  func finish() throws -> String
}

extension SherpaStreamingRecognitionStream: LocalSpeechStreamingPreviewSession {
  func accept(samples: [Float]) throws -> String {
    try accept(samples: samples, sampleRate: 16_000)
  }
}

/// Owns the fixed, low-latency model used for local subtitle hypotheses.
/// This runtime is deliberately independent from the selected offline model so
/// changing the final quality tier never changes capture latency.
public actor SherpaStreamingPreviewService {
  public static let modelID =
    SherpaOnnxModelID.streamingZipformerBilingualPreviewInt8.rawValue

  private let installer: SherpaOnnxModelInstaller
  private let threadCount: Int
  private var recognizer: SherpaStreamingRecognizer?

  public init(
    modelDirectoryURL: URL = SherpaOnnxRecognizer.defaultModelDirectoryURL,
    threadCount: Int = 2
  ) {
    self.installer = SherpaOnnxModelInstaller(destinationRootURL: modelDirectoryURL)
    self.threadCount = threadCount
  }

  /// Installs and constructs the preview recognizer. Callers may treat failure
  /// as optional capability loss; final offline recognition remains usable.
  public func prepare(
    downloadIfNeeded: Bool = true,
    progress: (@Sendable (SherpaOnnxModelInstallationProgress) -> Void)? = nil
  ) async throws {
    if recognizer != nil {
      let descriptor = SherpaOnnxModelCatalog.streamingZipformerBilingualPreviewInt8
      progress?(
        .init(
          phase: .complete,
          completedByteCount: descriptor.archiveByteCount,
          totalByteCount: descriptor.archiveByteCount
        )
      )
      return
    }

    let descriptor = SherpaOnnxModelCatalog.streamingZipformerBilingualPreviewInt8
    let directory: URL
    if downloadIfNeeded {
      directory = try await installer.install(
        descriptor,
        progressCallback: progress
      )
    } else {
      guard let installed = try await installer.existingInstalledURL(for: descriptor) else {
        throw SherpaOnnxRecognizer.RecognizerError.modelNotInstalled(descriptor.id.rawValue)
      }
      directory = installed
      progress?(
        .init(
          phase: .complete,
          completedByteCount: descriptor.archiveByteCount,
          totalByteCount: descriptor.archiveByteCount
        )
      )
    }
    try Task.checkCancellation()
    if recognizer == nil {
      recognizer = try SherpaStreamingRecognizer(
        configuration: SherpaStreamingTransducerConfiguration(
          encoder: directory.appendingPathComponent("encoder-epoch-99-avg-1.int8.onnx"),
          decoder: directory.appendingPathComponent("decoder-epoch-99-avg-1.int8.onnx"),
          joiner: directory.appendingPathComponent("joiner-epoch-99-avg-1.int8.onnx"),
          tokens: directory.appendingPathComponent("tokens.txt"),
          threadCount: threadCount
        )
      )
    }
  }

  func makeSessionIfReady() -> (any LocalSpeechStreamingPreviewSession)? {
    try? recognizer?.makeStream()
  }

  public func releaseLoadedModel() {
    recognizer = nil
  }
}
