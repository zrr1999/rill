import RillSpeechContracts
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
  private let enabledModelIDsProvider: @Sendable () throws -> Set<String>
  private let residentModelIDsProvider: @Sendable () throws -> Set<String>
  private let synthesisTimeout: Duration
  private let idleReleaseCoordinator: TTSIdleReleaseCoordinator

  public init(
    supervisor: SpeechWorkerSupervisor,
    selectionSource: SpeechSynthesisModelSelectionSource = .init(),
    enabledModelIDsProvider: @escaping @Sendable () throws -> Set<String> = {
      SpeechSynthesisModelCatalog.supportedModelIdentifiers
    },
    residentModelIDsProvider: @escaping @Sendable () throws -> Set<String> = {
      SpeechSynthesisModelCatalog.supportedModelIdentifiers
    },
    idleReleaseDelay: Duration = .seconds(30),
    synthesisTimeout: Duration = .seconds(300)
  ) {
    self.supervisor = supervisor
    self.selectionSource = selectionSource
    self.enabledModelIDsProvider = enabledModelIDsProvider
    self.residentModelIDsProvider = residentModelIDsProvider
    self.synthesisTimeout = synthesisTimeout
    self.idleReleaseCoordinator = TTSIdleReleaseCoordinator(delay: idleReleaseDelay)
  }

  public func prepare(
    modelIdentifier: String? = nil,
    downloadIfNeeded: Bool,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void = { _ in }
  ) async throws {
    let modelIdentifier = modelIdentifier ?? selectionSource.currentModelIdentifier()
    guard SpeechSynthesisModelCatalog.supportedModelIdentifiers.contains(modelIdentifier),
      try enabledModelIDsProvider().contains(modelIdentifier)
    else {
      throw SpeechWorkerClientError.protocolViolation
    }
    await idleReleaseCoordinator.markActive(modelID: modelIdentifier)
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
    let modelIdentifier = request.modelID ?? selectionSource.currentModelIdentifier()
    guard SpeechSynthesisModelCatalog.supportedModelIdentifiers.contains(modelIdentifier),
      try enabledModelIDsProvider().contains(modelIdentifier)
    else {
      throw SpeechSynthesisActionError.invalidRequest
    }
    let residentModelIDs = try residentModelIDsProvider()
      .intersection(SpeechSynthesisModelCatalog.supportedModelIdentifiers)
    let resident = residentModelIDs.contains(modelIdentifier)
    let workerShouldRemainRunning = !residentModelIDs.isEmpty
    await idleReleaseCoordinator.markActive(modelID: modelIdentifier)
    defer {
      Task {
        await idleReleaseCoordinator.scheduleRelease(
          modelID: modelIdentifier,
          resident: resident
        ) { [supervisor] in
          if workerShouldRemainRunning {
            try? await supervisor.releaseTTSModel(modelID: modelIdentifier)
          } else {
            try? await supervisor.releaseLoadedModel()
          }
        }
      }
    }
    let result = try await supervisor.synthesize(
      SpeechWorkerSynthesisPayload(
        runID: request.runID,
        modelID: modelIdentifier,
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
    await idleReleaseCoordinator.cancelAll()
    try? await supervisor.releaseLoadedModel()
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

private actor TTSIdleReleaseCoordinator {
  private let delay: Duration
  private var pending: [String: Task<Void, Never>] = [:]

  init(delay: Duration) {
    precondition(delay > .zero)
    self.delay = delay
  }

  func markActive(modelID: String) {
    pending.removeValue(forKey: modelID)?.cancel()
  }

  func scheduleRelease(
    modelID: String,
    resident: Bool,
    release: @escaping @Sendable () async -> Void
  ) {
    pending.removeValue(forKey: modelID)?.cancel()
    guard !resident else { return }
    let delay = self.delay
    pending[modelID] = Task { [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await release()
      await self?.releaseFinished(modelID: modelID)
    }
  }

  func cancelAll() {
    for task in pending.values { task.cancel() }
    pending.removeAll()
  }

  private func releaseFinished(modelID: String) {
    pending.removeValue(forKey: modelID)
  }
}
