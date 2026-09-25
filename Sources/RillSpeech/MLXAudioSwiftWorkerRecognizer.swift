import RillSpeechContracts
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
  private let diagnosticReporter: @Sendable (DiagnosticEvent) async -> Void
  private let idleReleaseCoordinator: LocalSpeechIdleReleaseCoordinator

  public init(
    id: String = "local-speech",
    supervisor: SpeechWorkerSupervisor,
    settingsProvider: @escaping @Sendable () async throws -> LocalSpeechSettings,
    workerTimeout: Duration = .seconds(600),
    preparationTimeout: Duration = .seconds(1_800),
    idleReleaseDelay: Duration = .seconds(30),
    diagnosticReporter: @escaping @Sendable (DiagnosticEvent) async -> Void = { _ in }
  ) {
    precondition(workerTimeout > .zero)
    precondition(preparationTimeout > .zero)
    self.id = id
    self.supervisor = supervisor
    self.settingsProvider = settingsProvider
    self.workerTimeout = workerTimeout
    self.preparationTimeout = preparationTimeout
    self.diagnosticReporter = diagnosticReporter
    self.idleReleaseCoordinator = LocalSpeechIdleReleaseCoordinator(
      delay: idleReleaseDelay
    )
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
    await idleReleaseCoordinator.markActive(modelID: modelIdentifier)
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
    do {
      return try await recognizeCapturedAudio(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      await recordRecognitionDiagnostic(
        event: .providerLocalSpeechRecognitionFailed,
        level: .error,
        outcome: "failed",
        failureCode: Self.diagnosticFailureCode(error),
        runID: request.runID
      )
      throw error
    }
  }

  private func recognizeCapturedAudio(_ request: RecognitionRequest) async throws -> RecognitionResult {
    try Task.checkCancellation()
    guard let capturedAudio = request.capturedAudio,
      capturedAudio.fileOwnership == .managedTemporary,
      let audioFileURL = capturedAudio.fileURL,
      CapturedAudio.isManagedTemporaryFileURL(audioFileURL)
    else {
      throw SpeechWorkerClientError.invalidManagedAudio
    }
    guard capturedAudio.durationSeconds.isFinite, capturedAudio.durationSeconds >= 0 else {
      throw SpeechWorkerClientError.invalidManagedAudio
    }

    let settings = try await settingsProvider()
    guard let modelIdentifier = request.options.modelID else {
      throw LocalSpeechSettingsSourceError.notReady
    }
    guard let modelID = MLXAudioModelID(rawValue: modelIdentifier),
      MLXAudioModelCatalog.distributableModelIdentifiers.contains(modelIdentifier)
    else {
      throw LocalSpeechModelSelectionError.unsupportedModelIdentifier(modelIdentifier)
    }
    guard settings.enabledModelIDs.contains(modelIdentifier) else {
      throw LocalSpeechModelSelectionError.modelNotEnabled(modelIdentifier)
    }
    let keyterms = LocalSpeechRecognitionPolicy.sanitizedQwenHotwords(request.options.hints.keyterms)
    let payload = SpeechWorkerRecognitionPayload(
      runID: request.runID,
      modelID: modelID.rawValue,
      language: request.options.language,
      keyterms: keyterms,
      threadCount: 1,
      audioFilePath: audioFileURL.standardizedFileURL.path,
      audioDurationSeconds: capturedAudio.durationSeconds,
      audioFormat: capturedAudio.format,
      downloadIfNeeded: settings.downloadIfNeeded
    )
    await idleReleaseCoordinator.markActive(modelID: modelIdentifier)
    defer {
      let resident = settings.residentModelIDs.contains(modelIdentifier)
      Task {
        await idleReleaseCoordinator.scheduleRelease(
          modelID: modelIdentifier,
          resident: resident
        ) { [supervisor] in
          try? await supervisor.releaseModel(modelID: modelIdentifier)
        }
      }
    }
    let result = try await recognizeWithOneWorkerRecovery(
      payload,
      priority: Self.taskPriority(for: request)
    )
    var metadata = result.metadata
    let workerOmitted = Int(metadata["provider.keyterms_omitted"] ?? "0") ?? 0
    metadata["provider.keyterms_omitted"] = String(
      request.options.hints.keyterms.count - keyterms.count + workerOmitted)
    return RecognitionResult(
      rawText: result.rawText,
      bestText: result.bestText,
      metadata: metadata,
      processingDurationMillis: result.processingDurationMillis
    )
  }

  public func releaseLoadedModel() async throws {
    try await supervisor.releaseLoadedModel()
  }

  public func stopRuntime() async throws {
    try await supervisor.shutdown()
  }

  private func recognizeWithOneWorkerRecovery(
    _ payload: SpeechWorkerRecognitionPayload,
    priority: SpeechWorkerTaskPriority
  ) async throws -> SpeechWorkerRecognitionResult {
    do {
      return try await supervisor.recognize(
        payload,
        timeout: workerTimeout,
        priority: priority
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let initialError as SpeechWorkerClientError {
      guard case .remoteFailure(.recognitionFailed) = initialError else {
        throw initialError
      }
      await recordRecognitionDiagnostic(
        event: .providerLocalSpeechRecognitionRetry,
        level: .warning,
        outcome: "pending",
        failureCode: Self.diagnosticFailureCode(initialError),
        runID: payload.runID
      )
      do {
        try await supervisor.releaseLoadedModel()
        try Task.checkCancellation()
        let result = try await supervisor.recognize(
          payload,
          timeout: workerTimeout,
          priority: priority
        )
        await recordRecognitionDiagnostic(
          event: .providerLocalSpeechRecognitionRetry,
          level: .info,
          outcome: "completed",
          failureCode: Self.diagnosticFailureCode(initialError),
          runID: payload.runID
        )
        return result
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        await recordRecognitionDiagnostic(
          event: .providerLocalSpeechRecognitionRetry,
          level: .error,
          outcome: "failed",
          failureCode: Self.diagnosticFailureCode(error),
          runID: payload.runID
        )
        throw error
      }
    }
  }

  private func recordRecognitionDiagnostic(
    event: DiagnosticEventName,
    level: DiagnosticLevel,
    outcome: String,
    failureCode: String,
    runID: UUID
  ) async {
    await diagnosticReporter(
      DiagnosticEvent(
        runID: runID,
        subsystem: .providers,
        level: level,
        event: event,
        message: "The isolated local speech worker reported a bounded recognition outcome.",
        metadata: [
          "provider": "local-speech",
          "provider.kind": LocalSpeechModelBackend.mlxAudioSwift.rawValue,
          "recognizerID": id,
          "stage": "recognizing",
          "outcome": outcome,
          "failureCode": failureCode,
        ]
      )
    )
  }

  private static func diagnosticFailureCode(_ error: Error) -> String {
    if let selectionError = error as? LocalSpeechModelSelectionError {
      return switch selectionError {
      case .unsupportedModelIdentifier: "unsupportedModel"
      case .modelNotEnabled: "model-disabled"
      case .backendUnavailable: "worker-unavailable"
      }
    }
    if error is LocalSpeechSettingsSourceError { return "settings-unavailable" }
    guard let error = error as? SpeechWorkerClientError else { return "unclassified" }
    return switch error {
    case .workerUnavailable: "worker-unavailable"
    case .workerDisconnected: "worker-disconnected"
    case .protocolViolation: "protocol-violation"
    case .staleResponse: "stale-response"
    case .requestTimedOut: "request-timed-out"
    case .requestAlreadyActive: "request-already-active"
    case .remoteFailure(let code): code.rawValue
    case .invalidManagedAudio: "invalid-managed-audio"
    case .workerTerminationFailed: "worker-termination-failed"
    }
  }

  private static func taskPriority(
    for request: RecognitionRequest
  ) -> SpeechWorkerTaskPriority {
    switch request.priority {
    case .interactive: .interactive
    case .foregroundFinal: .foregroundFinal
    case .wakeCandidate: .wakeCandidate
    }
  }
}

private actor LocalSpeechIdleReleaseCoordinator {
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

  private func releaseFinished(modelID: String) {
    pending.removeValue(forKey: modelID)
  }
}
