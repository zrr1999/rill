import Darwin
import Foundation
import RillCore

/// Executes final offline recognition inside the speech worker process.
///
/// The service accepts catalog identities only. It creates and retains one
/// product recognizer, whose native runtime keeps its existing one-entry cache.
/// Neither a model directory nor native runtime configuration is accepted over
/// IPC.
public actor SherpaOnnxSpeechWorkerService: SpeechWorkerRequestHandling {
  private struct RecognizerKey: Equatable {
    let modelID: SherpaOnnxModelID
    let threadCount: Int
  }

  private var cachedRecognizer: (key: RecognizerKey, value: SherpaOnnxRecognizer)?

  public init() {}

  public func handle(
    _ request: SpeechWorkerRequest,
    progress _: @escaping @Sendable (SpeechWorkerProgress) -> Void
  ) async -> SpeechWorkerResponse {
    do {
      let result = try await recognize(request)
      return .success(request: request, result: result)
    } catch {
      return .failure(request: request, code: Self.failureCode(for: error))
    }
  }

  private func recognize(
    _ request: SpeechWorkerRequest
  ) async throws -> SpeechWorkerRecognitionResult {
    guard request.protocolVersion == SpeechWorkerProtocol.version else {
      throw SpeechWorkerProtocolError.unsupportedVersion
    }
    guard request.operation == .recognizeOffline else {
      throw SpeechWorkerProtocolError.invalidRequest
    }

    guard let payload = request.recognitionPayload,
      request.modelPreparationPayload == nil
    else {
      throw SpeechWorkerProtocolError.invalidRequest
    }
    guard SherpaOnnxModelCatalog.distributableModelIdentifiers.contains(payload.modelID),
      let modelID = SherpaOnnxModelID(rawValue: payload.modelID)
    else {
      throw SherpaOnnxRecognizer.RecognizerError.unsupportedModelIdentifier(payload.modelID)
    }
    try SherpaOnnxRecognizer.validateThreadCount(payload.threadCount)
    try SherpaOnnxRecognizer.validateCapturedAudioDuration(payload.audioDurationSeconds)

    let audioURL: URL
    do {
      audioURL = try SpeechWorkerInputValidation.validatedManagedAudioURL(
        path: payload.audioFilePath
      )
    } catch {
      throw SherpaOnnxRecognizer.RecognizerError.invalidAudioFile
    }
    let capturedAudio = try CapturedAudio(
      durationSeconds: payload.audioDurationSeconds,
      format: payload.audioFormat,
      fileURL: audioURL,
      fileOwnership: .managedTemporary
    )

    let key = RecognizerKey(
      modelID: modelID,
      threadCount: payload.threadCount
    )
    let recognizer: SherpaOnnxRecognizer
    if let cachedRecognizer, cachedRecognizer.key == key {
      recognizer = cachedRecognizer.value
    } else {
      if let previous = cachedRecognizer?.value {
        await previous.stopRuntime()
      }
      recognizer = SherpaOnnxRecognizer(
        configuration: .init(
          modelIdentifier: modelID.rawValue,
          language: nil,
          downloadIfNeeded: false,
          prewarm: false,
          threadCount: payload.threadCount
        )
      )
      cachedRecognizer = (key, recognizer)
    }

    let workflow = WorkflowDefinition(
      id: payload.runID,
      name: "Speech Worker",
      plan: WorkflowPlan(
        setup: WorkflowSetupPhase(
          speechRoute: WorkflowSpeechRoute(recognizerID: recognizer.id)
        ),
        process: WorkflowProcessPhase(
          steps: [WorkflowProcessStep(kind: .recognizeSpeech)]
        ),
        output: WorkflowOutputPhase(
          actions: [OutputActionReference(id: "clipboard.copy")]
        )
      ),
      ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "accent")
    )
    let result = try await recognizer.recognize(
      RecognitionRequest(
        runID: payload.runID,
        workflow: workflow,
        contextSnapshot: .empty,
        capturedAudio: capturedAudio,
        options: SpeechRecognitionRequestOptions(
          language: payload.language,
          hints: RecognitionHints(keyterms: payload.keyterms)
        )
      )
    )
    return SpeechWorkerRecognitionResult(
      rawText: result.rawText,
      bestText: result.bestText,
      metadata: result.metadata,
      processingDurationMillis: result.processingDurationMillis
    )
  }

  private static func failureCode(for error: Error) -> SpeechWorkerFailureCode {
    if let error = error as? SpeechWorkerProtocolError {
      switch error {
      case .unsupportedVersion:
        return .unsupportedProtocol
      case .frameTooLarge, .unterminatedFrame, .invalidFrame, .invalidRequest, .invalidResponse:
        return .invalidRequest
      }
    }
    if let error = error as? SherpaOnnxRecognizer.RecognizerError {
      switch error {
      case .unsupportedModelIdentifier, .invalidThreadCount:
        return .unsupportedModel
      case .modelNotInstalled:
        return .modelUnavailable
      case .missingCapturedAudio,
        .fileBackedAudioRequired,
        .invalidAudioFile,
        .emptyAudio,
        .audioTooLong,
        .nonFiniteAudioSample,
        .audioConversionFailed:
        return .invalidAudio
      }
    }
    if error is SherpaOnnxModelInstallationError {
      return .modelUnavailable
    }
    return .recognitionFailed
  }
}
