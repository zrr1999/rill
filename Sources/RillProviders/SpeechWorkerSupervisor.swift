import RillSpeechContracts
import Darwin
import Foundation
import RillCore

/// Host-side ownership handle for one duplex live-audio session.
///
/// The handle serializes sequence assignment and writes. Events are emitted by
/// the worker until a terminal `completed` or `failure` frame closes the stream.
public final class SpeechWorkerStreamingSession: @unchecked Sendable {
  public let id: UUID
  public let events: AsyncThrowingStream<SpeechWorkerStreamEvent, Error>

  private let lock = NSLock()
  private let writeFrame: @Sendable (SpeechWorkerFrame) throws -> Void
  private let requestID: UUID
  private let generation: UInt64
  private var nextSequence: UInt64 = 1
  private var isTerminal = false

  fileprivate init(
    id: UUID,
    requestID: UUID,
    generation: UInt64,
    events: AsyncThrowingStream<SpeechWorkerStreamEvent, Error>,
    writeFrame: @escaping @Sendable (SpeechWorkerFrame) throws -> Void
  ) {
    self.id = id
    self.requestID = requestID
    self.generation = generation
    self.events = events
    self.writeFrame = writeFrame
  }

  public func append(samples: [Float]) throws {
    guard !samples.isEmpty,
      samples.count <= SpeechWorkerStreamingProtocol.maximumSamplesPerFrame,
      samples.allSatisfy(\.isFinite)
    else {
      throw SpeechWorkerProtocolError.invalidFrame
    }
    try send(.appendAudio(SpeechWorkerAudioChunk(samples: samples)), terminal: false)
  }

  public func finish() throws {
    try send(.finish, terminal: true)
  }

  public func cancel() throws {
    try send(.cancel, terminal: true)
  }

  private func send(_ command: SpeechWorkerStreamCommand, terminal: Bool) throws {
    try lock.withLock {
      guard !isTerminal else { throw SpeechWorkerClientError.staleResponse }
      let frame = SpeechWorkerFrame(
        requestID: requestID,
        generation: generation,
        sessionID: id,
        sequence: nextSequence,
        body: .command(command)
      )
      try writeFrame(frame)
      nextSequence += 1
      if terminal { isTerminal = true }
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
  private struct RequestLaneWaiter {
    let id: UUID
    let priority: SpeechWorkerTaskPriority
    let order: UInt64
    let continuation: CheckedContinuation<Bool, Never>
  }

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
  private var activeRequestPriority: SpeechWorkerTaskPriority?
  private var preemptionRequestedForRequestID: UUID?
  private var requestLaneIsHeld = false
  private var requestLaneWaiters: [RequestLaneWaiter] = []
  private var nextWaiterOrder: UInt64 = 0
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
    timeout: Duration,
    priority: SpeechWorkerTaskPriority = .foregroundFinal
  ) async throws -> SpeechWorkerRecognitionResult {
    _ = try ensureSession()
    let response = try await exchange(
      SpeechWorkerRequest(
        requestID: requestIDGenerator(),
        generation: generation,
        payload: payload
      ),
      timeout: timeout,
      priority: priority
    )
    guard let result = response.result,
      response.synthesisResult == nil,
      response.preparedModelID == nil,
      response.releasedModelID == nil
    else {
      if let session {
        try await invalidate(session)
      }
      throw SpeechWorkerClientError.protocolViolation
    }
    return result
  }

  public func prepareModel(
    _ payload: SpeechWorkerModelPreparationPayload,
    timeout: Duration,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void = { _ in }
  ) async throws -> String {
    _ = try ensureSession()
    let response = try await exchange(
      SpeechWorkerRequest(
        requestID: requestIDGenerator(),
        generation: generation,
        modelPreparationPayload: payload
      ),
      timeout: timeout,
      priority: .background,
      progress: progress
    )
    guard response.result == nil,
      response.synthesisResult == nil,
      response.preparedModelID == payload.modelID,
      response.releasedModelID == nil
    else {
      if let session {
        try await invalidate(session)
      }
      throw SpeechWorkerClientError.protocolViolation
    }
    return payload.modelID
  }

  public func prepareTTSModel(
    _ payload: SpeechWorkerModelPreparationPayload,
    timeout: Duration,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void = { _ in }
  ) async throws -> String {
    _ = try ensureSession()
    let response = try await exchange(
      SpeechWorkerRequest(
        requestID: requestIDGenerator(),
        generation: generation,
        ttsModelPreparationPayload: payload
      ),
      timeout: timeout,
      priority: .background,
      progress: progress
    )
    guard response.result == nil,
      response.synthesisResult == nil,
      response.preparedModelID == payload.modelID,
      response.releasedModelID == nil
    else {
      if let session {
        try await invalidate(session)
      }
      throw SpeechWorkerClientError.protocolViolation
    }
    return payload.modelID
  }

  public func synthesize(
    _ payload: SpeechWorkerSynthesisPayload,
    timeout: Duration
  ) async throws -> SpeechWorkerSynthesisResult {
    _ = try ensureSession()
    let response = try await exchange(
      SpeechWorkerRequest(
        requestID: requestIDGenerator(),
        generation: generation,
        synthesisPayload: payload
      ),
      timeout: timeout,
      priority: .interactive
    )
    guard let result = response.synthesisResult,
      response.result == nil,
      response.preparedModelID == nil,
      response.releasedModelID == nil
    else {
      if let session {
        try await invalidate(session)
      }
      throw SpeechWorkerClientError.protocolViolation
    }
    return result
  }

  public func releaseTTSModel(
    modelID: String,
    timeout: Duration = .seconds(10)
  ) async throws {
    guard session != nil else { return }
    let response = try await exchange(
      SpeechWorkerRequest(
        requestID: requestIDGenerator(),
        generation: generation,
        releaseTTSModelID: modelID
      ),
      timeout: timeout,
      priority: .background
    )
    guard response.result == nil,
      response.synthesisResult == nil,
      response.preparedModelID == nil,
      response.releasedModelID == modelID
    else {
      if let session {
        try await invalidate(session)
      }
      throw SpeechWorkerClientError.protocolViolation
    }
  }

  public func releaseModel(
    modelID: String,
    timeout: Duration = .seconds(10)
  ) async throws {
    guard session != nil else { return }
    let response = try await exchange(
      SpeechWorkerRequest(
        requestID: requestIDGenerator(),
        generation: generation,
        releaseModelID: modelID
      ),
      timeout: timeout,
      priority: .background
    )
    guard response.result == nil,
      response.synthesisResult == nil,
      response.preparedModelID == nil,
      response.releasedModelID == modelID
    else {
      if let session { try await invalidate(session) }
      throw SpeechWorkerClientError.protocolViolation
    }
  }

  public func startStreaming(
    _ payload: SpeechWorkerStreamStart
  ) async throws -> SpeechWorkerStreamingSession {
    try Task.checkCancellation()
    if payload.mode == .vadAndTranscription {
      try requestActiveRequestPreemptionIfNeeded(incomingPriority: payload.priority)
    }
    let processSession = try ensureSession()
    let requestID = requestIDGenerator()
    let sessionID = UUID()
    let requestGeneration = generation
    let startFrame = SpeechWorkerFrame(
      requestID: requestID,
      generation: requestGeneration,
      sessionID: sessionID,
      sequence: 0,
      body: .command(.start(payload))
    )
    return try processSession.openStreamingSession(
      startFrame: startFrame
    ) { [weak self, weak processSession] failure in
      guard let self, let processSession else { return }
      Task {
        await self.streamingSessionEnded(
          processSession: processSession,
          generation: requestGeneration,
          failure: failure
        )
      }
    }
  }

  private func streamingSessionEnded(
    processSession: SpeechWorkerProcessSession,
    generation expectedGeneration: UInt64,
    failure: SpeechWorkerClientError?
  ) async {
    if failure != nil || generation != expectedGeneration || session !== processSession {
      if session === processSession {
        try? await invalidate(processSession)
      }
    }
  }

  private func exchange(
    _ request: SpeechWorkerRequest,
    timeout: Duration,
    priority: SpeechWorkerTaskPriority,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void = { _ in }
  ) async throws -> SpeechWorkerResponse {
    var currentRequest = request
    while true {
      do {
        return try await exchangeOnce(
          currentRequest,
          timeout: timeout,
          priority: priority,
          progress: progress
        )
      } catch SpeechWorkerClientError.remoteFailure(.requestPreempted) {
        try Task.checkCancellation()
        currentRequest.requestID = requestIDGenerator()
        currentRequest.generation = generation
      }
    }
  }

  private func exchangeOnce(
    _ request: SpeechWorkerRequest,
    timeout: Duration,
    priority: SpeechWorkerTaskPriority,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void
  ) async throws -> SpeechWorkerResponse {
    precondition(timeout > .zero)
    let laneID = UUID()
    try await acquireRequestLane(id: laneID, priority: priority)
    defer { releaseRequestLane(id: laneID) }
    try Task.checkCancellation()

    let session = try ensureSession()
    let requestID = request.requestID
    let requestGeneration = request.generation
    activeRequestID = request.requestID
    activeRequestPriority = priority
    do {
      let response = try await session.exchange(
        request,
        timeout: timeout,
        progress: progress
      )
      if Task.isCancelled {
        try await invalidate(session)
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
      switch response.status {
      case .progress:
        try await invalidate(session)
        throw SpeechWorkerClientError.protocolViolation
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
      if !session.isRunning {
        self.session = nil
      }
      throw error
    }
  }

  private func acquireRequestLane(
    id: UUID,
    priority: SpeechWorkerTaskPriority
  ) async throws {
    if !requestLaneIsHeld, requestLaneWaiters.isEmpty {
      requestLaneIsHeld = true
      return
    }

    try requestActiveRequestPreemptionIfNeeded(incomingPriority: priority)

    let acquired = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: false)
          return
        }
        let order = nextWaiterOrder
        nextWaiterOrder &+= 1
        requestLaneWaiters.append(
          RequestLaneWaiter(
            id: id,
            priority: priority,
            order: order,
            continuation: continuation
          )
        )
        requestLaneWaiters.sort {
          if $0.priority != $1.priority { return $0.priority > $1.priority }
          return $0.order < $1.order
        }
      }
    } onCancel: {
      Task {
        await self.cancelRequestLaneWaiter(id: id)
      }
    }
    guard acquired else { throw CancellationError() }
  }

  private func cancelRequestLaneWaiter(id: UUID) {
    guard let index = requestLaneWaiters.firstIndex(where: { $0.id == id }) else {
      return
    }
    let waiter = requestLaneWaiters.remove(at: index)
    waiter.continuation.resume(returning: false)
  }

  private func releaseRequestLane(id _: UUID) {
    activeRequestID = nil
    activeRequestPriority = nil
    preemptionRequestedForRequestID = nil
    guard !requestLaneWaiters.isEmpty else {
      requestLaneIsHeld = false
      return
    }
    requestLaneIsHeld = true
    let waiter = requestLaneWaiters.removeFirst()
    waiter.continuation.resume(returning: true)
  }

  private func requestActiveRequestPreemptionIfNeeded(
    incomingPriority: SpeechWorkerTaskPriority
  ) throws {
    guard let activeRequestID,
      let activeRequestPriority,
      incomingPriority > activeRequestPriority,
      preemptionRequestedForRequestID != activeRequestID,
      let session
    else { return }
    try session.preemptUnaryRequest(
      requestID: activeRequestID,
      generation: generation
    )
    preemptionRequestedForRequestID = activeRequestID
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

  func queuedRequestCountForTesting() -> Int {
    requestLaneWaiters.count
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
  private struct UnarySink {
    let generation: UInt64
    var expectedSequence: UInt64
    let continuation: AsyncThrowingStream<SpeechWorkerResponse, Error>.Continuation
  }

  private struct StreamingSink {
    let requestID: UUID
    let generation: UInt64
    var expectedSequence: UInt64
    let continuation: AsyncThrowingStream<SpeechWorkerStreamEvent, Error>.Continuation
    let onTerminal: @Sendable (SpeechWorkerClientError?) -> Void
  }

  private let process: Process
  private let input: FileHandle
  private let output: FileHandle
  private let errorOutput: FileHandle
  private let outputReader: SpeechWorkerBoundedLineReader
  private let terminationGracePeriod: Duration
  private let forcedExitWait: Duration
  private let stderrRetainedByteLimit: Int
  private let lock = NSLock()
  private let writeLock = NSLock()
  private var retainedStderr = Data()
  private var terminationTask: Task<Bool, Never>?
  private var handlesAreClosed = false
  private var unarySinks: [UUID: UnarySink] = [:]
  private var streamingSinks: [UUID: StreamingSink] = [:]
  private var outputPumpTask: Task<Void, Never>?

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
    outputPumpTask = Task.detached(priority: .userInitiated) { [weak self] in
      self?.pumpOutput()
    }
  }

  deinit {
    outputPumpTask?.cancel()
    if process.isRunning {
      _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }
    closeHandles()
  }

  func exchange(
    _ request: SpeechWorkerRequest,
    timeout: Duration,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void
  ) async throws -> SpeechWorkerResponse {
    if Task.isCancelled {
      _ = await terminateAndWait()
      throw CancellationError()
    }
    let (responses, responseContinuation) = AsyncThrowingStream<
      SpeechWorkerResponse,
      Error
    >.makeStream(bufferingPolicy: .bufferingNewest(32))
    let registered = lock.withLock {
      unarySinks.updateValue(
        UnarySink(
          generation: request.generation,
          expectedSequence: 0,
          continuation: responseContinuation
        ),
        forKey: request.requestID
      ) == nil
    }
    guard registered else {
      responseContinuation.finish(throwing: SpeechWorkerClientError.requestAlreadyActive)
      throw SpeechWorkerClientError.requestAlreadyActive
    }
    let line: Data
    do {
      line = try SpeechWorkerProtocolCodec.encodeRequestLine(request)
      try writeLock.withLock {
        try input.write(contentsOf: line)
      }
    } catch is SpeechWorkerProtocolError {
      removeUnarySink(requestID: request.requestID)
      _ = await terminateAndWait()
      throw SpeechWorkerClientError.protocolViolation
    } catch {
      removeUnarySink(requestID: request.requestID)
      _ = await terminateAndWait()
      throw SpeechWorkerClientError.workerDisconnected
    }

    let race = SpeechWorkerExchangeRace()
    let responseTask = Task.detached(priority: Task.currentPriority) {
      let result: Result<SpeechWorkerResponse, SpeechWorkerClientError>
      do {
        var terminalResponse: SpeechWorkerResponse?
        for try await response in responses {
          if response.status == .progress {
            guard let update = response.progress else {
              throw SpeechWorkerClientError.protocolViolation
            }
            progress(update)
          } else {
            terminalResponse = response
            break
          }
        }
        guard let terminalResponse else {
          throw SpeechWorkerClientError.workerDisconnected
        }
        result = .success(terminalResponse)
      } catch is SpeechWorkerProtocolError {
        result = .failure(.protocolViolation)
      } catch let error as SpeechWorkerClientError {
        result = .failure(error)
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
      removeUnarySink(requestID: request.requestID)
      let terminated = await terminateAndWait()
      responseTask.cancel()
      guard terminated else {
        throw SpeechWorkerClientError.workerTerminationFailed
      }
      throw SpeechWorkerClientError.requestTimedOut
    case .cancelled:
      removeUnarySink(requestID: request.requestID)
      let terminated = await terminateAndWait()
      responseTask.cancel()
      guard terminated else {
        throw SpeechWorkerClientError.workerTerminationFailed
      }
      throw CancellationError()
    }
  }

  func preemptUnaryRequest(requestID: UUID, generation: UInt64) throws {
    let frame = SpeechWorkerFrame(
      requestID: UUID(),
      generation: generation,
      sessionID: requestID,
      sequence: 0,
      body: .command(.cancelRequest(requestID))
    )
    let encoded: Data
    do {
      encoded = try SpeechWorkerFrameCodec.encodeCommandLine(frame)
    } catch {
      throw SpeechWorkerClientError.protocolViolation
    }
    do {
      try writeLock.withLock {
        try input.write(contentsOf: encoded)
      }
    } catch {
      throw SpeechWorkerClientError.workerDisconnected
    }
  }

  func openStreamingSession(
    startFrame: SpeechWorkerFrame,
    onTerminal: @escaping @Sendable (SpeechWorkerClientError?) -> Void
  ) throws -> SpeechWorkerStreamingSession {
    let (events, continuation) = AsyncThrowingStream<
      SpeechWorkerStreamEvent,
      Error
    >.makeStream(bufferingPolicy: .bufferingNewest(512))
    let handle = SpeechWorkerStreamingSession(
      id: startFrame.sessionID,
      requestID: startFrame.requestID,
      generation: startFrame.generation,
      events: events,
      writeFrame: { [weak self] frame in
        guard let self else { throw SpeechWorkerClientError.workerDisconnected }
        let encoded: Data
        do {
          encoded = try SpeechWorkerFrameCodec.encodeCommandLine(frame)
        } catch {
          throw SpeechWorkerClientError.protocolViolation
        }
        do {
          try self.writeLock.withLock {
            try self.input.write(contentsOf: encoded)
          }
        } catch {
          throw SpeechWorkerClientError.workerDisconnected
        }
      }
    )

    let registered = lock.withLock {
      streamingSinks.updateValue(
        StreamingSink(
          requestID: startFrame.requestID,
          generation: startFrame.generation,
          expectedSequence: 0,
          continuation: continuation,
          onTerminal: onTerminal
        ),
        forKey: startFrame.sessionID
      ) == nil
    }
    guard registered else {
      continuation.finish(throwing: SpeechWorkerClientError.requestAlreadyActive)
      throw SpeechWorkerClientError.requestAlreadyActive
    }

    let encoded: Data
    do {
      encoded = try SpeechWorkerFrameCodec.encodeCommandLine(startFrame)
      try writeLock.withLock {
        try input.write(contentsOf: encoded)
      }
    } catch is SpeechWorkerProtocolError {
      removeStreamingSink(
        sessionID: startFrame.sessionID,
        error: .protocolViolation
      )
      throw SpeechWorkerClientError.protocolViolation
    } catch {
      removeStreamingSink(
        sessionID: startFrame.sessionID,
        error: .workerDisconnected
      )
      throw SpeechWorkerClientError.workerDisconnected
    }
    return handle
  }

  /// The only stdout reader for this process. Unary responses and live events
  /// can be interleaved arbitrarily without competing reads from FileHandle.
  private func pumpOutput() {
    do {
      while !Task.isCancelled {
        guard
          let data = try outputReader.readLine(
            maximumByteCount: SpeechWorkerProtocol.maximumResponseByteCount
          )
        else {
          throw SpeechWorkerClientError.workerDisconnected
        }
        let frame: SpeechWorkerFrame
        do {
          frame = try SpeechWorkerFrameCodec.decodeEventLine(data)
        } catch {
          throw SpeechWorkerClientError.protocolViolation
        }
        switch frame.body {
        case .event:
          try dispatchStreamingFrame(frame)
        case .response(let payload):
          let response = SpeechWorkerResponse(
            protocolVersion: frame.protocolVersion,
            requestID: frame.requestID,
            generation: frame.generation,
            sequence: frame.sequence,
            payload: payload
          )
          try dispatchUnaryResponse(response)
        case .request, .command:
          throw SpeechWorkerClientError.protocolViolation
        }
      }
    } catch let error as SpeechWorkerClientError {
      failAllSinks(error)
    } catch {
      failAllSinks(.workerDisconnected)
    }
  }

  private func dispatchUnaryResponse(
    _ response: SpeechWorkerResponse
  ) throws {
    let dispatch: (
      AsyncThrowingStream<SpeechWorkerResponse, Error>.Continuation,
      Bool
    )? = lock.withLock {
      guard var sink = unarySinks[response.requestID],
        sink.generation == response.generation,
        sink.expectedSequence == response.sequence,
        response.protocolVersion == SpeechWorkerProtocol.version
      else { return nil }
      sink.expectedSequence &+= 1
      let isTerminal = response.status != .progress
      if isTerminal {
        unarySinks.removeValue(forKey: response.requestID)
      } else {
        unarySinks[response.requestID] = sink
      }
      return (sink.continuation, isTerminal)
    }
    guard let dispatch else { throw SpeechWorkerClientError.staleResponse }
    dispatch.0.yield(response)
    if dispatch.1 { dispatch.0.finish() }
  }

  private func dispatchStreamingFrame(_ frame: SpeechWorkerFrame) throws {
    let dispatch: (
      AsyncThrowingStream<SpeechWorkerStreamEvent, Error>.Continuation,
      @Sendable (SpeechWorkerClientError?) -> Void,
      SpeechWorkerStreamEvent,
      SpeechWorkerClientError?
    )? = lock.withLock {
      guard var sink = streamingSinks[frame.sessionID],
        sink.requestID == frame.requestID,
        sink.generation == frame.generation,
        frame.sequence == sink.expectedSequence,
        case .event(let event) = frame.body
      else { return nil }
      sink.expectedSequence += 1
      let terminalFailure: SpeechWorkerClientError?
      let isTerminal: Bool
      switch event {
      case .completed:
        isTerminal = true
        terminalFailure = nil
      case .failure(let code):
        isTerminal = true
        terminalFailure = .remoteFailure(code)
      case .accepted, .started, .vadActivity, .speechStarted, .speechEnded,
        .transcriptUpdate, .stats:
        isTerminal = false
        terminalFailure = nil
      }
      if isTerminal {
        streamingSinks.removeValue(forKey: frame.sessionID)
      } else {
        streamingSinks[frame.sessionID] = sink
      }
      return (sink.continuation, sink.onTerminal, event, terminalFailure)
    }
    guard let dispatch else { throw SpeechWorkerClientError.staleResponse }
    dispatch.0.yield(dispatch.2)
    switch dispatch.2 {
    case .completed:
      dispatch.0.finish()
      dispatch.1(nil)
    case .failure:
      dispatch.0.finish(throwing: dispatch.3)
      dispatch.1(dispatch.3)
    case .accepted, .started, .vadActivity, .speechStarted, .speechEnded,
      .transcriptUpdate, .stats:
      break
    }
  }

  private func removeUnarySink(requestID: UUID) {
    let continuation = lock.withLock {
      unarySinks.removeValue(forKey: requestID)?.continuation
    }
    continuation?.finish(throwing: SpeechWorkerClientError.workerDisconnected)
  }

  private func removeStreamingSink(
    sessionID: UUID,
    error: SpeechWorkerClientError
  ) {
    let sink = lock.withLock { streamingSinks.removeValue(forKey: sessionID) }
    sink?.continuation.finish(throwing: error)
    sink?.onTerminal(error)
  }

  private func failAllSinks(_ error: SpeechWorkerClientError) {
    let sinks = lock.withLock { () -> ([UnarySink], [StreamingSink]) in
      let unary = Array(unarySinks.values)
      let streaming = Array(streamingSinks.values)
      unarySinks.removeAll()
      streamingSinks.removeAll()
      return (unary, streaming)
    }
    for sink in sinks.0 {
      sink.continuation.finish(throwing: error)
    }
    for sink in sinks.1 {
      sink.continuation.finish(throwing: error)
      sink.onTerminal(error)
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
