import Darwin
import Foundation
import RillCore

public final class SpeechSynthesisModelSelectionSource: @unchecked Sendable {
  private let lock = NSLock()
  private var modelIdentifier: String

  public init(
    modelIdentifier: String = SpeechSynthesisModelCatalog.defaultModel.id.rawValue
  ) {
    self.modelIdentifier =
      SpeechSynthesisModelCatalog.supportedModelIdentifiers.contains(modelIdentifier)
      ? modelIdentifier
      : SpeechSynthesisModelCatalog.defaultModel.id.rawValue
  }

  public func currentModelIdentifier() -> String {
    lock.lock()
    defer { lock.unlock() }
    return modelIdentifier
  }

  @discardableResult
  public func selectModel(_ modelIdentifier: String) -> Bool {
    guard SpeechSynthesisModelCatalog.supportedModelIdentifiers.contains(modelIdentifier) else {
      return false
    }
    lock.lock()
    defer { lock.unlock() }
    self.modelIdentifier = modelIdentifier
    return true
  }
}

public struct Qwen3TTSSpeechSynthesizer: SpeechSynthesizer {
  public let id = "speech.qwen3-tts"
  private let supervisor: SpeechWorkerSupervisor
  private let selectionSource: SpeechSynthesisModelSelectionSource
  private let synthesisTimeout: Duration

  public init(
    supervisor: SpeechWorkerSupervisor,
    selectionSource: SpeechSynthesisModelSelectionSource = .init(),
    synthesisTimeout: Duration = .seconds(300)
  ) {
    self.supervisor = supervisor
    self.selectionSource = selectionSource
    self.synthesisTimeout = synthesisTimeout
  }

  public func prepare(
    modelIdentifier: String? = nil,
    downloadIfNeeded: Bool,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void = { _ in }
  ) async throws {
    let modelIdentifier = modelIdentifier ?? selectionSource.currentModelIdentifier()
    guard SpeechSynthesisModelCatalog.supportedModelIdentifiers.contains(modelIdentifier) else {
      throw SpeechWorkerClientError.protocolViolation
    }
    _ = try await supervisor.prepareTTSModel(
      SpeechWorkerModelPreparationPayload(
        modelID: modelIdentifier,
        downloadIfNeeded: downloadIfNeeded
      ),
      timeout: .seconds(downloadIfNeeded ? 3_600 : 120),
      progress: progress
    )
  }

  public func synthesize(_ request: SpeechSynthesisRequest) async throws -> SpeechAsset {
    guard request.isValid, Qwen3TTSVoice(rawValue: request.voice) != nil else {
      throw SpeechSynthesisActionError.invalidRequest
    }
    let result = try await supervisor.synthesize(
      SpeechWorkerSynthesisPayload(
        runID: request.runID,
        modelID: selectionSource.currentModelIdentifier(),
        text: request.text,
        voice: request.voice,
        language: request.language,
        downloadIfNeeded: false
      ),
      timeout: synthesisTimeout
    )
    let fileURL = URL(fileURLWithPath: result.audioFilePath).standardizedFileURL
    guard
      SpeechAsset.isManagedTemporaryFileURL(fileURL),
      Self.isRegularNonSymbolicFile(fileURL)
    else {
      throw SpeechWorkerClientError.protocolViolation
    }
    do {
      return try SpeechAsset(
        fileURL: fileURL,
        durationSeconds: result.durationSeconds,
        format: AudioFormat(
          sampleRateHz: result.sampleRate,
          channelCount: result.channelCount,
          encoding: .float32
        ),
        ownership: .managedTemporary
      )
    } catch {
      _ = try? FileManager.default.removeItem(at: fileURL)
      throw SpeechWorkerClientError.protocolViolation
    }
  }

  public func releaseResources() async {
    try? await supervisor.releaseTTSModel(
      modelID: selectionSource.currentModelIdentifier()
    )
  }

  private static func isRegularNonSymbolicFile(_ url: URL) -> Bool {
    var status = stat()
    let result = url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      return lstat(path, &status)
    }
    return result == 0 && (status.st_mode & S_IFMT) == S_IFREG
  }
}
