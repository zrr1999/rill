import Foundation
import RillCore

/// Native Swift MLX-Audio adapter hosted by RillSpeechWorker.
///
/// The host never links MLX or Python. It sends bounded requests to the same
/// supervised helper boundary used by other local engines.
public struct MLXAudioSwiftWorkerRecognizer: LocalSpeechBackendRecognizer {
  public let id: String
  public let backend = LocalSpeechModelBackend.mlxAudioSwift
  public let capabilities = SpeechRecognizerCapabilities(
    supportedHintKinds: [.keyterm]
  )

  private let supervisor: SpeechWorkerSupervisor
  private let settingsProvider: @Sendable () async throws -> LocalSpeechSettings
  private let workerTimeout: Duration
  private let preparationTimeout: Duration

  public init(
    id: String = "mlx-audio-swift.local",
    supervisor: SpeechWorkerSupervisor,
    settingsProvider: @escaping @Sendable () async throws -> LocalSpeechSettings,
    workerTimeout: Duration = .seconds(600),
    preparationTimeout: Duration = .seconds(1_800)
  ) {
    precondition(workerTimeout > .zero)
    precondition(preparationTimeout > .zero)
    self.id = id
    self.supervisor = supervisor
    self.settingsProvider = settingsProvider
    self.workerTimeout = workerTimeout
    self.preparationTimeout = preparationTimeout
  }

  public func prepareModel(
    modelIdentifier: String,
    downloadIfNeeded: Bool,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void = { _ in }
  ) async throws -> String {
    guard let modelID = MLXAudioModelID(rawValue: modelIdentifier),
      MLXAudioModelCatalog.distributableModelIdentifiers.contains(modelIdentifier)
    else {
      throw LocalSpeechModelSelectionError.unsupportedModelIdentifier(modelIdentifier)
    }
    let prepared = try await supervisor.prepareModel(
      SpeechWorkerModelPreparationPayload(
        modelID: modelID.rawValue,
        downloadIfNeeded: downloadIfNeeded
      ),
      timeout: preparationTimeout,
      progress: progress
    )
    guard prepared == modelID.rawValue else {
      throw SpeechWorkerClientError.protocolViolation
    }
    return prepared
  }

  public func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
    try Task.checkCancellation()
    guard let capturedAudio = request.capturedAudio,
      capturedAudio.fileOwnership == .managedTemporary,
      let audioFileURL = capturedAudio.fileURL,
      CapturedAudio.isManagedTemporaryFileURL(audioFileURL)
    else {
      throw SpeechWorkerClientError.invalidManagedAudio
    }
    guard capturedAudio.durationSeconds.isFinite, capturedAudio.durationSeconds >= 0 else {
      throw SherpaOnnxRecognizer.RecognizerError.invalidAudioFile
    }

    let settings = try await settingsProvider()
    let modelIdentifier = LocalSpeechModelCatalog.effectiveModelIdentifier(
      settings: settings,
      workflow: request.workflow
    )
    guard let modelID = MLXAudioModelID(rawValue: modelIdentifier),
      MLXAudioModelCatalog.distributableModelIdentifiers.contains(modelIdentifier)
    else {
      throw LocalSpeechModelSelectionError.unsupportedModelIdentifier(modelIdentifier)
    }
    let language = SherpaOnnxRecognizer.resolvedLanguage(
      requestLanguage: request.options.language,
      workflowLanguage: request.workflow.metadata[WorkflowMetadataKey.languageOverride],
      configurationLanguage: settings.language
    )
    let payload = SpeechWorkerRecognitionPayload(
      runID: request.runID,
      modelID: modelID.rawValue,
      language: language,
      keyterms: SherpaOnnxRecognizer.sanitizedQwenHotwords(request.options.hints.keyterms),
      threadCount: 1,
      audioFilePath: audioFileURL.standardizedFileURL.path,
      audioDurationSeconds: capturedAudio.durationSeconds,
      audioFormat: capturedAudio.format,
      downloadIfNeeded: settings.downloadIfNeeded
    )
    let result = try await supervisor.recognize(payload, timeout: workerTimeout)
    return RecognitionResult(
      rawText: result.rawText,
      bestText: result.bestText,
      metadata: result.metadata,
      processingDurationMillis: result.processingDurationMillis
    )
  }

  public func releaseLoadedModel() async throws {
    try await supervisor.releaseLoadedModel()
  }

  public func stopRuntime() async throws {
    try await supervisor.shutdown()
  }
}
