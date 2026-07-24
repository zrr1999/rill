import Darwin
import Foundation
import RillCore

public enum SpeechWorkerClientError: Error, LocalizedError, Sendable, Equatable {
  case workerUnavailable
  case workerDisconnected
  case protocolViolation
  case staleResponse
  case requestTimedOut
  case requestAlreadyActive
  case remoteFailure(SpeechWorkerFailureCode)
  case invalidManagedAudio
  case workerTerminationFailed

  public var errorDescription: String? {
    switch self {
    case .workerUnavailable:
      "The local speech worker is unavailable."
    case .workerDisconnected:
      "The local speech worker disconnected."
    case .protocolViolation:
      "The local speech worker returned an invalid response."
    case .staleResponse:
      "The local speech worker returned an obsolete response."
    case .requestTimedOut:
      "Local speech recognition timed out."
    case .requestAlreadyActive:
      "The local speech worker is already processing audio."
    case .remoteFailure(let code):
      switch code {
      case .invalidRequest, .unsupportedProtocol:
        "The local speech worker rejected the request."
      case .unsupportedModel:
        "The selected local speech model is unsupported."
      case .modelUnavailable:
        "The selected local speech model is unavailable."
      case .invalidAudio:
        "The recorded audio is invalid."
      case .recognitionFailed:
        "Local speech recognition failed."
      }
    case .invalidManagedAudio:
      "Local speech recognition requires Rill-managed temporary audio."
    case .workerTerminationFailed:
      "The local speech worker could not be stopped safely."
    }
  }
}

/// Owns one persistent speech worker and serializes its request/response lane.
///
/// A generation belongs to exactly one child process. Cancellation, timeout,
/// model release, and application shutdown invalidate that generation, send
/// SIGTERM, wait 500 ms, then send SIGKILL if necessary. No continuation is
/// released until that bounded termination sequence has completed.
public actor SpeechWorkerSupervisor {
  public struct Configuration: Sendable, Equatable {
    public var executableURL: URL
    public var arguments: [String]
    public var environment: [String: String]

    public init(
      executableURL: URL,
      arguments: [String] = [],
      environment: [String: String] = [:]
    ) {
      self.executableURL = executableURL
      self.arguments = arguments
      self.environment = environment
    }
  }

  private static let terminationGracePeriod = Duration.milliseconds(500)
  private static let forcedExitWait = Duration.milliseconds(500)
  private static let stderrRetainedByteLimit = 64 * 1_024

  private let configuration: Configuration
  private let requestIDGenerator: @Sendable () -> UUID
  private var generation: UInt64 = 0
  private var session: SpeechWorkerProcessSession?
  private var retiringSession: SpeechWorkerProcessSession?
  private var activeRequestID: UUID?
  private var isShutdown = false

  public init(configuration: Configuration) {
    self.configuration = configuration
    self.requestIDGenerator = { UUID() }
  }

  init(
    configuration: Configuration,
    requestIDGenerator: @escaping @Sendable () -> UUID
  ) {
    self.configuration = configuration
    self.requestIDGenerator = requestIDGenerator
  }

  public func recognize(
    _ payload: SpeechWorkerRecognitionPayload,
    timeout: Duration
  ) async throws -> SpeechWorkerRecognitionResult {
    _ = try ensureSession()
    let response = try await exchange(
      SpeechWorkerRequest(
        requestID: requestIDGenerator(),
        generation: generation,
        payload: payload
      ),
      timeout: timeout
    )
    guard let result = response.result, response.preparedModelID == nil else {
      if let session {
        try await invalidate(session)
      }
      throw SpeechWorkerClientError.protocolViolation
    }
    return result
  }

  public func prepareModel(
    _ payload: SpeechWorkerModelPreparationPayload,
    timeout: Duration
  ) async throws -> String {
    _ = try ensureSession()
    let response = try await exchange(
      SpeechWorkerRequest(
        requestID: requestIDGenerator(),
        generation: generation,
        modelPreparationPayload: payload
      ),
      timeout: timeout
    )
    guard response.result == nil, response.preparedModelID == payload.modelID else {
      if let session {
        try await invalidate(session)
      }
      throw SpeechWorkerClientError.protocolViolation
    }
    return payload.modelID
  }

  private func exchange(
    _ request: SpeechWorkerRequest,
    timeout: Duration
  ) async throws -> SpeechWorkerResponse {
    precondition(timeout > .zero)
    guard activeRequestID == nil else {
      throw SpeechWorkerClientError.requestAlreadyActive
    }
    let session = try ensureSession()
    let requestID = request.requestID
    let requestGeneration = request.generation
    activeRequestID = request.requestID
    do {
      let response = try await session.exchange(request, timeout: timeout)
      if Task.isCancelled {
        try await invalidate(session)
        activeRequestID = nil
        throw CancellationError()
      }
      guard self.session === session, generation == requestGeneration else {
        throw SpeechWorkerClientError.staleResponse
      }
      guard response.requestID == requestID,
        response.generation == requestGeneration,
        response.protocolVersion == SpeechWorkerProtocol.version
      else {
        try await invalidate(session)
        throw SpeechWorkerClientError.staleResponse
      }
      activeRequestID = nil
      switch response.status {
      case .success:
        return response
      case .failure:
        guard let failure = response.failure else {
          try await invalidate(session)
          throw SpeechWorkerClientError.protocolViolation
        }
        throw SpeechWorkerClientError.remoteFailure(failure)
      }
    } catch {
      activeRequestID = nil
      if !session.isRunning {
        self.session = nil
      }
      throw error
    }
  }

  /// Drops the worker's native model cache by retiring the entire process.
  public func releaseLoadedModel() async throws {
    if let session {
      try await invalidate(session)
    } else if let retiringSession {
      try await finishRetirement(retiringSession)
    }
  }

  /// Bounded application-shutdown hook. A successful return means no child PID
  /// owned by this supervisor remains alive.
  public func shutdown() async throws {
    isShutdown = true
    if let session {
      try await invalidate(session)
    } else if let retiringSession {
      try await finishRetirement(retiringSession)
    }
  }

  func activeProcessIdentifier() -> pid_t? {
    session?.processIdentifier ?? retiringSession?.processIdentifier
  }

  func retainedStderrByteCount() -> Int {
    session?.retainedStderrByteCount ?? 0
  }

  private func ensureSession() throws -> SpeechWorkerProcessSession {
    guard !isShutdown, retiringSession == nil else {
      throw SpeechWorkerClientError.workerUnavailable
    }
    if let session, session.isRunning {
      return session
    }
    advanceGeneration()
    do {
      let session = try SpeechWorkerProcessSession(
        configuration: configuration,
        terminationGracePeriod: Self.terminationGracePeriod,
        forcedExitWait: Self.forcedExitWait,
        stderrRetainedByteLimit: Self.stderrRetainedByteLimit
      )
      self.session = session
      return session
    } catch {
      self.session = nil
      throw SpeechWorkerClientError.workerUnavailable
    }
  }

  private func invalidate(_ expectedSession: SpeechWorkerProcessSession) async throws {
    if session === expectedSession {
      session = nil
      advanceGeneration()
    }
    if retiringSession == nil {
      retiringSession = expectedSession
    }
    try await finishRetirement(expectedSession)
  }

  private func finishRetirement(_ expectedSession: SpeechWorkerProcessSession) async throws {
    let terminated = await expectedSession.terminateAndWait()
    guard terminated else {
      throw SpeechWorkerClientError.workerTerminationFailed
    }
    if retiringSession === expectedSession {
      retiringSession = nil
    }
  }

  private func advanceGeneration() {
    generation = generation == .max ? 1 : generation + 1
  }
}

/// SpeechRecognizer adapter for the subprocess-owned sherpa-onnx runtime.
/// There is deliberately no in-process recognition fallback.
public struct SherpaOnnxWorkerRecognizer: LocalSpeechBackendRecognizer {
  public let id: String
  public let backend = LocalSpeechModelBackend.sherpaOnnx
  public let capabilities = SpeechRecognizerCapabilities(
    supportedHintKinds: [.keyterm],
    maximumAudioDurationSeconds: Double(SherpaOnnxRecognizer.maximumAudioDurationSeconds)
  )

  private let supervisor: SpeechWorkerSupervisor
  private let defaultConfiguration: SherpaOnnxRecognizer.Configuration
  private let configurationProvider:
    (@Sendable () async throws -> SherpaOnnxRecognizer.Configuration)?
  private let workerTimeout: Duration

  public init(
    id: String = "sherpa-onnx.local",
    supervisor: SpeechWorkerSupervisor,
    configuration: SherpaOnnxRecognizer.Configuration = .init(),
    configurationProvider:
      (@Sendable () async throws -> SherpaOnnxRecognizer.Configuration)? = nil,
    workerTimeout: Duration = .seconds(600)
  ) {
    precondition(workerTimeout > .zero)
    self.id = id
    self.supervisor = supervisor
    self.defaultConfiguration = configuration
    self.configurationProvider = configurationProvider
    self.workerTimeout = workerTimeout
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
    try SherpaOnnxRecognizer.validateCapturedAudioDuration(capturedAudio.durationSeconds)

    let baseConfiguration = try await configurationProvider?() ?? defaultConfiguration
    let configuration = SherpaOnnxRecognizer.applyingWorkflowModelOverride(
      to: baseConfiguration,
      workflow: request.workflow
    )
    let modelIdentifier = configuration.modelIdentifier.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard SherpaOnnxModelCatalog.distributableModelIdentifiers.contains(modelIdentifier),
      SherpaOnnxModelID(rawValue: modelIdentifier) != nil
    else {
      throw SherpaOnnxRecognizer.RecognizerError.unsupportedModelIdentifier(modelIdentifier)
    }
    try SherpaOnnxRecognizer.validateThreadCount(configuration.threadCount)
    let language = SherpaOnnxRecognizer.resolvedLanguage(
      requestLanguage: request.options.language,
      workflowLanguage: request.workflow.metadata[WorkflowMetadataKey.languageOverride],
      configurationLanguage: configuration.language
    )
    let keyterms = SherpaOnnxRecognizer.sanitizedQwenHotwords(request.options.hints.keyterms)
    let payload = SpeechWorkerRecognitionPayload(
      runID: request.runID,
      modelID: modelIdentifier,
      language: language,
      keyterms: keyterms,
      threadCount: configuration.threadCount,
      audioFilePath: audioFileURL.standardizedFileURL.path,
      audioDurationSeconds: capturedAudio.durationSeconds,
      audioFormat: capturedAudio.format
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

private enum SpeechWorkerExchangeOutcome: Sendable {
  case response(Result<SpeechWorkerResponse, SpeechWorkerClientError>)
  case timedOut
  case cancelled
}

private actor SpeechWorkerExchangeRace {
  private var outcome: SpeechWorkerExchangeOutcome?
  private var waiter: CheckedContinuation<SpeechWorkerExchangeOutcome, Never>?

  func wait() async -> SpeechWorkerExchangeOutcome {
    if let outcome { return outcome }
    return await withCheckedContinuation { continuation in
      precondition(waiter == nil)
      waiter = continuation
    }
  }

  func resolve(_ outcome: SpeechWorkerExchangeOutcome) {
    guard self.outcome == nil else { return }
    self.outcome = outcome
    let waiter = waiter
    self.waiter = nil
    waiter?.resume(returning: outcome)
  }
}

private final class SpeechWorkerProcessSession: @unchecked Sendable {
  private let process: Process
  private let input: FileHandle
  private let output: FileHandle
  private let errorOutput: FileHandle
  private let outputReader: SpeechWorkerBoundedLineReader
  private let terminationGracePeriod: Duration
  private let forcedExitWait: Duration
  private let stderrRetainedByteLimit: Int
  private let lock = NSLock()
  private var retainedStderr = Data()
  private var terminationTask: Task<Bool, Never>?
  private var handlesAreClosed = false

  var processIdentifier: pid_t { process.processIdentifier }
  var isRunning: Bool { process.isRunning }

  var retainedStderrByteCount: Int {
    lock.withLock { retainedStderr.count }
  }

  init(
    configuration: SpeechWorkerSupervisor.Configuration,
    terminationGracePeriod: Duration,
    forcedExitWait: Duration,
    stderrRetainedByteLimit: Int
  ) throws {
    let process = Process()
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.executableURL = configuration.executableURL
    process.arguments = configuration.arguments
    if !configuration.environment.isEmpty {
      process.environment = ProcessInfo.processInfo.environment.merging(
        configuration.environment,
        uniquingKeysWith: { _, configured in configured }
      )
    }
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    self.process = process
    self.input = inputPipe.fileHandleForWriting
    self.output = outputPipe.fileHandleForReading
    self.errorOutput = errorPipe.fileHandleForReading
    self.outputReader = SpeechWorkerBoundedLineReader(fileHandle: outputPipe.fileHandleForReading)
    self.terminationGracePeriod = terminationGracePeriod
    self.forcedExitWait = forcedExitWait
    self.stderrRetainedByteLimit = stderrRetainedByteLimit
    errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
      } else {
        self?.drainStderr(data)
      }
    }

    do {
      try process.run()
    } catch {
      errorPipe.fileHandleForReading.readabilityHandler = nil
      try? inputPipe.fileHandleForWriting.close()
      try? outputPipe.fileHandleForReading.close()
      try? errorPipe.fileHandleForReading.close()
      throw error
    }
    try? inputPipe.fileHandleForReading.close()
    try? outputPipe.fileHandleForWriting.close()
    try? errorPipe.fileHandleForWriting.close()
  }

  deinit {
    if process.isRunning {
      _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }
    closeHandles()
  }

  func exchange(
    _ request: SpeechWorkerRequest,
    timeout: Duration
  ) async throws -> SpeechWorkerResponse {
    if Task.isCancelled {
      _ = await terminateAndWait()
      throw CancellationError()
    }
    let line: Data
    do {
      line = try SpeechWorkerProtocolCodec.encodeRequestLine(request)
      try input.write(contentsOf: line)
    } catch is SpeechWorkerProtocolError {
      _ = await terminateAndWait()
      throw SpeechWorkerClientError.protocolViolation
    } catch {
      _ = await terminateAndWait()
      throw SpeechWorkerClientError.workerDisconnected
    }

    let race = SpeechWorkerExchangeRace()
    let responseTask = Task.detached(priority: Task.currentPriority) { [self] in
      let result: Result<SpeechWorkerResponse, SpeechWorkerClientError>
      do {
        guard
          let data = try outputReader.readLine(
            maximumByteCount: SpeechWorkerProtocol.maximumResponseByteCount
          )
        else {
          result = .failure(.workerDisconnected)
          await race.resolve(.response(result))
          return
        }
        result = .success(try SpeechWorkerProtocolCodec.decodeResponseLine(data))
      } catch is SpeechWorkerProtocolError {
        result = .failure(.protocolViolation)
      } catch {
        result = .failure(.workerDisconnected)
      }
      await race.resolve(.response(result))
    }
    let timeoutTask = Task.detached(priority: .utility) {
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      await race.resolve(.timedOut)
    }

    let outcome = await withTaskCancellationHandler {
      await race.wait()
    } onCancel: {
      Task {
        await race.resolve(.cancelled)
      }
    }
    timeoutTask.cancel()

    switch outcome {
    case .response(let result):
      switch result {
      case .success(let response):
        return response
      case .failure(let error):
        let terminated = await terminateAndWait()
        guard terminated else {
          throw SpeechWorkerClientError.workerTerminationFailed
        }
        throw error
      }
    case .timedOut:
      let terminated = await terminateAndWait()
      responseTask.cancel()
      guard terminated else {
        throw SpeechWorkerClientError.workerTerminationFailed
      }
      throw SpeechWorkerClientError.requestTimedOut
    case .cancelled:
      let terminated = await terminateAndWait()
      responseTask.cancel()
      guard terminated else {
        throw SpeechWorkerClientError.workerTerminationFailed
      }
      throw CancellationError()
    }
  }

  func terminateAndWait() async -> Bool {
    let task = lock.withLock { () -> Task<Bool, Never> in
      if let terminationTask { return terminationTask }
      let task = Task.detached(priority: .utility) { [self] in
        await performBoundedTermination()
      }
      terminationTask = task
      return task
    }
    return await task.value
  }

  private func performBoundedTermination() async -> Bool {
    guard process.isRunning else {
      closeHandles()
      return true
    }

    process.terminate()
    if await waitForExit(for: terminationGracePeriod) {
      closeHandles()
      return true
    }

    _ = Darwin.kill(process.processIdentifier, SIGKILL)
    let terminated = await waitForExit(for: forcedExitWait)
    closeHandles()
    return terminated
  }

  private func waitForExit(for duration: Duration) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: duration)
    while process.isRunning, clock.now < deadline {
      await Self.sleepIgnoringCancellation(for: .milliseconds(10))
    }
    return !process.isRunning
  }

  private static func sleepIgnoringCancellation(for duration: Duration) async {
    await Task.detached(priority: .utility) {
      try? await Task.sleep(for: duration)
    }.value
  }

  private func drainStderr(_ data: Data) {
    lock.withLock {
      let remaining = max(stderrRetainedByteLimit - retainedStderr.count, 0)
      if remaining > 0 {
        retainedStderr.append(contentsOf: data.prefix(remaining))
      }
    }
  }

  private func closeHandles() {
    let shouldClose = lock.withLock { () -> Bool in
      guard !handlesAreClosed else { return false }
      handlesAreClosed = true
      return true
    }
    guard shouldClose else { return }
    errorOutput.readabilityHandler = nil
    try? input.close()
    try? output.close()
    try? errorOutput.close()
  }
}
