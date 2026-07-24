@preconcurrency import AVFoundation
import Foundation
import RillCore

struct FailClosedAsyncBuffer<Element: Sendable>: Sendable {
  let stream: AsyncStream<Element>

  private let continuation: AsyncStream<Element>.Continuation
  private let overflowGate = FailClosedOverflowGate()
  private let onOverflow: @Sendable () -> Void

  init(capacity: Int, onOverflow: @escaping @Sendable () -> Void) {
    precondition(capacity > 0)
    let channel = AsyncStream<Element>.makeStream(
      bufferingPolicy: .bufferingNewest(capacity)
    )
    stream = channel.stream
    continuation = channel.continuation
    self.onOverflow = onOverflow
  }

  @discardableResult
  func yield(_ element: Element) -> Bool {
    switch continuation.yield(element) {
    case .enqueued:
      return true
    case .dropped:
      overflowGate.runOnce(onOverflow)
      continuation.finish()
      return false
    case .terminated:
      return false
    @unknown default:
      overflowGate.runOnce(onOverflow)
      continuation.finish()
      return false
    }
  }

  func finish() {
    continuation.finish()
  }
}

private final class FailClosedOverflowGate: @unchecked Sendable {
  private let lock = NSLock()
  private var didOverflow = false

  func runOnce(_ operation: @Sendable () -> Void) {
    let shouldRun = lock.withLock {
      guard didOverflow == false else { return false }
      didOverflow = true
      return true
    }
    if shouldRun {
      operation()
    }
  }
}

actor DeepgramLiveCaptureReadinessGate {
  struct Scope: Equatable, Sendable {
    let runID: UUID
    let generation: UInt64
  }

  enum Failure: Error, Equatable, Sendable {
    case pipelineFailed
    case pipelineEndedBeforeReady
    case timedOut
  }

  private enum Resolution: Sendable {
    case ready
    case failed(Failure)
    case cancelled
  }

  private let scope: Scope
  private var resolution: Resolution?
  private var waiters: [CheckedContinuation<Resolution, Never>] = []

  init(scope: Scope) {
    self.scope = scope
  }

  func wait(
    timeout: Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) async throws {
    let timeoutTask = Task { [weak self] in
      do {
        try await sleep(timeout)
      } catch {
        return
      }
      await self?.resolve(.failed(.timedOut))
    }

    let resolution = await withTaskCancellationHandler {
      await nextResolution()
    } onCancel: {
      Task { [weak self] in
        await self?.resolve(.cancelled)
      }
    }
    timeoutTask.cancel()
    await timeoutTask.value
    try Task.checkCancellation()

    switch resolution {
    case .ready:
      return
    case .failed(let failure):
      throw failure
    case .cancelled:
      throw CancellationError()
    }
  }

  @discardableResult
  func signalAcceptedBuffer(scope: Scope) -> Bool {
    guard self.scope == scope else { return false }
    return resolve(.ready)
  }

  @discardableResult
  func signalPipelineFailure(scope: Scope) -> Bool {
    guard self.scope == scope else { return false }
    return resolve(.failed(.pipelineFailed))
  }

  @discardableResult
  func signalPipelineEndedBeforeReady(scope: Scope) -> Bool {
    guard self.scope == scope else { return false }
    return resolve(.failed(.pipelineEndedBeforeReady))
  }

  func cancel() {
    resolve(.cancelled)
  }

  private func nextResolution() async -> Resolution {
    if let resolution {
      return resolution
    }
    return await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  @discardableResult
  private func resolve(_ resolution: Resolution) -> Bool {
    guard self.resolution == nil else { return false }
    self.resolution = resolution
    let waiters = waiters
    self.waiters.removeAll()
    for waiter in waiters {
      waiter.resume(returning: resolution)
    }
    return true
  }
}

/// One-shot ownership gate for failures that happen after microphone startup.
/// A run ID alone is not sufficient because callers may deliberately reuse it;
/// every terminal event must also belong to the active capture generation.
struct DeepgramLiveTerminalGate: Sendable {
  private var notifiedGeneration: UInt64?

  mutating func claim(
    activeRunID: UUID?,
    activeGeneration: UInt64?,
    recordingGeneration: UInt64?,
    eventScope: DeepgramLiveCaptureReadinessGate.Scope,
    isFinishing: Bool
  ) -> Bool {
    guard !isFinishing,
      activeRunID == eventScope.runID,
      activeGeneration == eventScope.generation,
      recordingGeneration == eventScope.generation,
      notifiedGeneration != eventScope.generation
    else {
      return false
    }
    notifiedGeneration = eventScope.generation
    return true
  }
}

actor DeepgramLiveCaptureRuntime {
  private struct WebSocketRequestPlan {
    let request: URLRequest
    let plan: DeepgramRequestPlan
  }

  private struct LiveProjection: Sendable {
    let phase: LiveSubtitlePhase
    let confirmedText: String
    let hypothesisText: String
    let statusText: String?
    let levelMeter: [Float]
  }

  private struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
  }

  private static let providerID = DeepgramRecognizer.liveProviderID
  private static let projectionThrottleInterval: ContinuousClock.Duration = .milliseconds(80)
  private static let finalizeWaitTimeout: ContinuousClock.Duration = .milliseconds(250)
  private static let closeWaitTimeout: ContinuousClock.Duration = .milliseconds(650)
  private static let quietAfterFinalizeDuration: ContinuousClock.Duration = .milliseconds(50)
  private static let quietAfterCloseDuration: ContinuousClock.Duration = .milliseconds(80)
  private static let defaultStartupTimeout: Duration = .seconds(3)
  private static let tapBufferSize: AVAudioFrameCount = 2_048
  // Live audio must not accumulate behind a slow file or network consumer.
  // Saturation terminates authorization instead of degrading silently.
  static let audioChunkBufferCapacity = 16
  private static let outputSampleRate: Double = 16_000

  private let liveUpdateHandler: @Sendable (LiveSubtitleSnapshot) async -> Void
  private let session: URLSession
  private let hintDiagnosticReporter: DeepgramHintDiagnosticReporter
  private let microphonePermissionRequester: @Sendable () async -> Bool
  private let cleanupOwner: ManagedTemporaryAudioCleanupOwner
  private let startupTimeout: Duration
  private let readinessSleep: @Sendable (Duration) async throws -> Void
  private let unexpectedTerminationHandler:
    @Sendable (DeepgramLiveCaptureReadinessGate.Scope) async -> Void

  private var preparingRequest: AudioCaptureRequest?
  private var cancelledRunIDs: Set<UUID> = []
  private var activeRequest: AudioCaptureRequest?
  private var activeModel: String?
  private var engine: AVAudioEngine?
  private var retainedVoiceProcessingTarget: DeepgramVoiceProcessingEngineTarget?
  private var converter: AVAudioConverter?
  private var outputFormat: AVAudioFormat?
  private var outputFile: AVAudioFile?
  private var outputURL: URL?
  private var webSocketTask: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var chunkProcessingTask: Task<Void, Never>?
  private var chunkBuffer: FailClosedAsyncBuffer<AudioChunk>?
  private var activeReadinessGate: DeepgramLiveCaptureReadinessGate?
  private var engineConfigurationObserver: NotificationObserverToken?
  private var captureGeneration: UInt64 = 0
  private var activeGeneration: UInt64?
  private var recordingGeneration: UInt64?
  private var terminalGate = DeepgramLiveTerminalGate()
  private var endpointDetector: SpeechEndpointDetector?
  private var latestProjection: LiveProjection?
  private var lastProjectionPublishTime: ContinuousClock.Instant?
  private var pendingProjectionTask: Task<Void, Never>?
  private var isProjectionFlushScheduled = false
  private var shouldPublishLiveUpdates = false
  private var finalSegments: [String] = []
  private var interimText = ""
  private var levelMeter: [Float] = []
  private var totalFramesWritten: AVAudioFramePosition = 0
  private var deepgramRequestID: String?
  private var lastServerMessageTime: ContinuousClock.Instant?
  private var finalizeRequestedAt: ContinuousClock.Instant?
  private var closeRequestedAt: ContinuousClock.Instant?
  private var closeStreamSentAt: ContinuousClock.Instant?
  private var didResolveCurrentTranscript = false
  private var didReceiveUtteranceEnd = false
  private var didReceiveAuthoritativeResultAfterClose = false
  private var didReceiveAcceptedFinalizeResult = false
  private var lastAcceptedWordEnd: Double?
  private var receiveLoopFinished = false
  private var streamingFailed = false

  init(
    session: URLSession = .shared,
    liveUpdateHandler: @escaping @Sendable (LiveSubtitleSnapshot) async -> Void,
    hintDiagnosticReporter: @escaping DeepgramHintDiagnosticReporter = { _ in },
    microphonePermissionRequester: (@Sendable () async -> Bool)? = nil,
    cleanupOwner: ManagedTemporaryAudioCleanupOwner = ManagedTemporaryAudioCleanupOwner(),
    startupTimeout: Duration = DeepgramLiveCaptureRuntime.defaultStartupTimeout,
    readinessSleep: @escaping @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    },
    unexpectedTerminationHandler:
      @escaping @Sendable (DeepgramLiveCaptureReadinessGate.Scope) async -> Void = { _ in }
  ) {
    self.session = session
    self.liveUpdateHandler = liveUpdateHandler
    self.hintDiagnosticReporter = hintDiagnosticReporter
    self.cleanupOwner = cleanupOwner
    self.startupTimeout = startupTimeout
    self.readinessSleep = readinessSleep
    self.unexpectedTerminationHandler = unexpectedTerminationHandler
    self.microphonePermissionRequester =
      microphonePermissionRequester ?? {
        await Self.requestMicrophonePermission()
      }
  }

  func startCapture(
    request: AudioCaptureRequest,
    configuration: DeepgramRecognizer.Configuration
  ) async throws {
    guard activeRequest == nil, preparingRequest == nil else {
      throw RealtimeAudioCaptureService.CaptureError.alreadyCapturing
    }
    preparingRequest = request
    defer {
      if preparingRequest?.runID == request.runID {
        preparingRequest = nil
      }
      cancelledRunIDs.remove(request.runID)
    }
    try throwIfCancelled(for: request)
    _ = try Self.requireTransmissionPermit(for: request)

    // Request planning is pure configuration validation. Keep it ahead of
    // permission prompts and every audio resource allocation so an invalid
    // cloud configuration cannot cause a local recording side effect.
    let webSocketRequestPlan = try Self.makeWebSocketRequestPlan(
      for: request, configuration: configuration)
    guard await microphonePermissionRequester() else {
      throw RealtimeAudioCaptureService.CaptureError.microphonePermissionDenied
    }
    try throwIfCancelled(for: request)
    _ = try Self.requireTransmissionPermit(for: request)

    let outputURL = Self.makeTemporaryRecordingURL(for: request.runID)
    do {
      let webSocketRequest = webSocketRequestPlan.request
      await hintDiagnosticReporter(webSocketRequestPlan.plan.hintDiagnosticReport)
      try throwIfCancelled(for: request)
      _ = try Self.requireTransmissionPermit(for: request)
      guard
        let requestedOutputFormat = AVAudioFormat(
          commonFormat: .pcmFormatInt16,
          sampleRate: Self.outputSampleRate,
          channels: 1,
          interleaved: false
        )
      else {
        throw DeepgramLiveRuntimeError.invalidAudioFormat
      }

      if FileManager.default.fileExists(atPath: outputURL.path) {
        await removeServiceOwnedFile(outputURL, runID: request.runID)
      }

      let voiceProcessingTarget: DeepgramVoiceProcessingEngineTarget
      if let retainedVoiceProcessingTarget {
        voiceProcessingTarget = retainedVoiceProcessingTarget
      } else {
        let engine = AVAudioEngine()
        voiceProcessingTarget = DeepgramVoiceProcessingEngineTarget(engine: engine)
        // Keep the VPIO graph alive across capture failures. CoreAudio may still
        // deliver property-listener callbacks after prepare/start returns an
        // error, so releasing the engine while unwinding that error is unsafe.
        retainedVoiceProcessingTarget = voiceProcessingTarget
      }
      let engine = voiceProcessingTarget.engine
      try AppleVoiceProcessingEngineConfigurator().configure(voiceProcessingTarget)
      let inputNode = engine.inputNode
      let inputFormat = inputNode.outputFormat(forBus: 0)
      let outputFile = try Self.makeOutputFile(for: outputURL, format: requestedOutputFormat)
      let outputFormat = outputFile.processingFormat
      guard
        Self.supportsStreamingOutputFormat(outputFormat),
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
      else {
        throw DeepgramLiveRuntimeError.invalidAudioFormat
      }

      resetState()
      captureGeneration &+= 1
      let scope = DeepgramLiveCaptureReadinessGate.Scope(
        runID: request.runID,
        generation: captureGeneration
      )
      let readinessGate = DeepgramLiveCaptureReadinessGate(scope: scope)
      let socket = session.webSocketTask(with: webSocketRequest)
      let chunkBuffer: FailClosedAsyncBuffer<AudioChunk> = Self.makeFailClosedAudioBuffer(
        capacity: Self.audioChunkBufferCapacity,
        request: request
      ) { [weak self, weak socket, readinessGate] in
        // Cut the transport immediately on the audio callback's overflow
        // signal; actor teardown then stops input and removes the payload.
        socket?.cancel(with: .normalClosure, reason: nil)
        Task { [weak self] in
          await readinessGate.signalPipelineFailure(scope: scope)
          await self?.handleAudioBufferOverflow(for: request, scope: scope)
        }
      }
      let stream = chunkBuffer.stream

      try throwIfCancelled(for: request)
      activeRequest = request
      preparingRequest = nil
      activeModel = webSocketRequestPlan.plan.model
      activeGeneration = scope.generation
      recordingGeneration = nil
      terminalGate = DeepgramLiveTerminalGate()
      endpointDetector = request.endpointControl.map {
        SpeechEndpointDetector(policy: $0.policy)
      }
      self.engine = engine
      self.converter = converter
      self.outputFormat = outputFormat
      self.outputFile = outputFile
      self.outputURL = outputURL
      webSocketTask = socket
      self.chunkBuffer = chunkBuffer
      activeReadinessGate = readinessGate
      shouldPublishLiveUpdates = false

      receiveTask = Task { [weak self] in
        await self?.receiveLoop(for: scope, readinessGate: readinessGate)
      }
      chunkProcessingTask = Task { [weak self] in
        await self?.processAudioChunks(stream, for: scope, readinessGate: readinessGate)
      }

      let tapChunkBuffer = self.chunkBuffer
      inputNode.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: inputFormat) {
        buffer, _ in
        guard let tapChunkBuffer else { return }
        guard let copy = Self.copyBuffer(buffer) else {
          socket.cancel(with: .goingAway, reason: nil)
          Task { [weak runtime = self] in
            await readinessGate.signalPipelineFailure(scope: scope)
            await runtime?.scheduleUnexpectedTermination(for: scope)
          }
          return
        }
        tapChunkBuffer.yield(AudioChunk(buffer: copy))
      }

      do {
        try throwIfCancelled(for: request)
        _ = try Self.requireTransmissionPermit(for: request)
        socket.resume()
        engine.prepare()
        guard voiceProcessingTarget.formatsRemainMatched else {
          throw AppleVoiceProcessingAudioError.voiceProcessingFormatsDidNotRemainMatched
        }
        _ = try Self.requireTransmissionPermit(for: request)
        try engine.start()
        let observer = NotificationCenter.default.addObserver(
          forName: .AVAudioEngineConfigurationChange,
          object: engine,
          queue: nil
        ) { [weak self, weak socket, weak engine, readinessGate] _ in
          // A graph notification is only terminal when the hardware route has
          // actually stopped this engine. Benign graph reconfiguration while
          // it remains running must not abort an otherwise healthy capture.
          guard engine?.isRunning == false else { return }
          socket?.cancel(with: .goingAway, reason: nil)
          Task { [weak self] in
            await readinessGate.signalPipelineFailure(scope: scope)
            await self?.scheduleUnexpectedTermination(for: scope)
          }
        }
        engineConfigurationObserver = NotificationObserverToken(observer)
        try await readinessGate.wait(
          timeout: startupTimeout,
          sleep: readinessSleep
        )
        try throwIfCancelled(for: request)
        _ = try Self.requireTransmissionPermit(for: request)
        guard
          Self.acceptsLiveEvent(
            activeRunID: activeRequest?.runID,
            activeGeneration: activeGeneration,
            eventScope: scope
          )
        else {
          throw CancellationError()
        }
        activeReadinessGate = nil
        recordingGeneration = scope.generation
        shouldPublishLiveUpdates = true
        latestProjection = LiveProjection(
          phase: .recording,
          confirmedText: "",
          hypothesisText: "",
          statusText: nil,
          levelMeter: []
        )
        await publishProjection(
          latestProjection,
          runID: request.runID,
          workflow: request.workflow.presentation,
          generation: scope.generation
        )
        guard
          Self.acceptsLiveProjection(
            activeRunID: activeRequest?.runID,
            activeGeneration: activeGeneration,
            recordingGeneration: recordingGeneration,
            projectionScope: scope
          )
        else {
          throw CancellationError()
        }
      } catch is CancellationError {
        await discardActiveCapture(
          for: request,
          generation: scope.generation,
          cancelLifetime: false,
          awaitChunkTask: true
        )
        throw CancellationError()
      } catch let failure as DeepgramLiveCaptureReadinessGate.Failure {
        await discardActiveCapture(
          for: request,
          generation: scope.generation,
          cancelLifetime: false,
          awaitChunkTask: true
        )
        switch failure {
        case .timedOut:
          throw RealtimeAudioCaptureService.CaptureError.microphoneStartTimedOut
        case .pipelineFailed, .pipelineEndedBeforeReady:
          throw RealtimeAudioCaptureService.CaptureError.microphoneStartFailed
        }
      } catch {
        await discardActiveCapture(
          for: request,
          generation: scope.generation,
          cancelLifetime: false,
          awaitChunkTask: true
        )
        throw error
      }
    } catch {
      await removeServiceOwnedFile(outputURL, runID: request.runID)
      throw error
    }
  }

  func finishCapture(for request: AudioCaptureRequest) async throws -> CapturedAudio {
    try await beginFinishingCapture(for: request, publishFinalizingSnapshot: true)
    return try await completeCaptureAfterAudioDrain(for: request)
  }

  func finishCaptureDeferred(for request: AudioCaptureRequest) async throws -> DeferredCapturedAudio
  {
    try await beginFinishingCapture(for: request, publishFinalizingSnapshot: false)
    await publishHiddenSnapshot(for: request)
    return DeferredCapturedAudio(
      task: Task {
        try await self.completeCaptureAfterAudioDrain(for: request)
      })
  }

  /// Stops microphone input and drains every already-buffered audio chunk
  /// before the deferred handle crosses back to the caller. No audio send can
  /// begin after `finishCaptureDeferred()` returns.
  private func beginFinishingCapture(
    for request: AudioCaptureRequest,
    publishFinalizingSnapshot: Bool
  ) async throws {
    guard activeRequest?.runID == request.runID else {
      throw RealtimeAudioCaptureService.CaptureError.notCapturing
    }

    closeRequestedAt = ContinuousClock.now
    removeEngineConfigurationObserver()
    stopEngine()
    shouldPublishLiveUpdates = false
    pendingProjectionTask?.cancel()
    pendingProjectionTask = nil
    isProjectionFlushScheduled = false
    chunkBuffer?.finish()
    chunkBuffer = nil
    if let chunkProcessingTask {
      await chunkProcessingTask.value
    }

    guard activeRequest?.runID == request.runID else {
      throw DeepgramLiveRuntimeError.audioAuthorizationRevoked
    }
    do {
      _ = try Self.requireTransmissionPermit(for: request)
    } catch {
      await discardActiveCapture(for: request, cancelLifetime: false, awaitChunkTask: true)
      throw error
    }

    if publishFinalizingSnapshot, let latestProjection {
      await liveUpdateHandler(
        LiveSubtitleSnapshot(
          runID: request.runID,
          workflow: request.workflow.presentation,
          phase: .finalizing,
          confirmedText: latestProjection.confirmedText,
          hypothesisText: latestProjection.hypothesisText,
          statusText: latestProjection.statusText,
          levelMeter: latestProjection.levelMeter,
          providerID: Self.providerID
        )
      )
    }
  }

  private func completeCaptureAfterAudioDrain(
    for request: AudioCaptureRequest
  ) async throws -> CapturedAudio {
    guard activeRequest?.runID == request.runID else {
      throw RealtimeAudioCaptureService.CaptureError.notCapturing
    }

    if !streamingFailed {
      finalizeRequestedAt = ContinuousClock.now
      do {
        try await sendControlMessage(["type": "Finalize"], for: request)
        await waitForServerMessages(
          timeout: Self.finalizeWaitTimeout,
          quietDuration: Self.quietAfterFinalizeDuration,
          requestedAt: finalizeRequestedAt,
          lifetime: request.audioLifetime
        )
        closeStreamSentAt = ContinuousClock.now
        try await sendControlMessage(["type": "CloseStream"], for: request)
        await waitForServerMessages(
          timeout: Self.closeWaitTimeout,
          quietDuration: Self.quietAfterCloseDuration,
          requestedAt: closeStreamSentAt,
          lifetime: request.audioLifetime
        )
      } catch let error as DeepgramLiveRuntimeError where error.isAuthorizationFailure {
        await discardActiveCapture(for: request, cancelLifetime: false, awaitChunkTask: true)
        throw error
      } catch {
        streamingFailed = true
      }
    }

    let durationSeconds = Double(totalFramesWritten) / Self.outputSampleRate
    let resolvedOutputURL = outputURL
    let resolvedOutputFormat = outputFormat
    let resolvedRequestID = deepgramRequestID
    let resolvedModel = activeModel
    let resolvedTranscript = Self.trustedReusableTranscript(
      reusableTranscript,
      streamingFailed: streamingFailed,
      acceptedFinalizeResult: didReceiveAcceptedFinalizeResult
    )

    await shutdownSocket(for: request.runID)

    guard request.audioLifetime?.isActive == true else {
      await cleanup(removeOutputFile: true)
      throw DeepgramLiveRuntimeError.audioAuthorizationRevoked
    }
    await cleanup(removeOutputFile: false)

    guard let resolvedOutputURL, let resolvedOutputFormat else {
      if let resolvedOutputURL {
        await removeServiceOwnedFile(resolvedOutputURL, runID: request.runID)
      }
      throw DeepgramLiveRuntimeError.missingOutputFile
    }

    var metadata = request.metadata.merging(
      [
        "runID": request.runID.uuidString,
        "live.provider": Self.providerID,
      ],
      uniquingKeysWith: { _, new in new }
    )
    if let resolvedModel {
      metadata[DeepgramRecognizer.liveModelMetadataKey] = resolvedModel
    }
    if let resolvedRequestID {
      metadata[DeepgramRecognizer.liveRequestIDMetadataKey] = resolvedRequestID
    }
    if let resolvedTranscript {
      metadata[DeepgramRecognizer.liveBestTextMetadataKey] = resolvedTranscript
      metadata[DeepgramRecognizer.liveRawTextMetadataKey] = resolvedTranscript
    }

    do {
      return try CapturedAudio(
        durationSeconds: durationSeconds,
        format: AudioFormat(
          sampleRateHz: resolvedOutputFormat.sampleRate,
          channelCount: Int(resolvedOutputFormat.channelCount),
          encoding: .pcm16
        ),
        fileURL: resolvedOutputURL,
        fileOwnership: .managedTemporary,
        metadata: metadata
      )
    } catch {
      await removeServiceOwnedFile(resolvedOutputURL, runID: request.runID)
      throw error
    }
  }

  func cancelCapture(for request: AudioCaptureRequest) async {
    if preparingRequest?.runID == request.runID {
      cancelledRunIDs.insert(request.runID)
      preparingRequest = nil
      Self.matchingLifetime(for: request)?.cancel()
      await publishHiddenSnapshot(for: request)
      return
    }
    guard activeRequest?.runID == request.runID else { return }
    await discardActiveCapture(for: request, cancelLifetime: true, awaitChunkTask: true)
  }

  private var reusableTranscript: String? {
    guard interimText.isEmpty else { return nil }
    let transcript = Self.joinedTranscript(finalSegments)
    return transcript.nonEmpty
  }

  private func processAudioChunks(
    _ stream: AsyncStream<AudioChunk>,
    for scope: DeepgramLiveCaptureReadinessGate.Scope,
    readinessGate: DeepgramLiveCaptureReadinessGate
  ) async {
    for await chunk in stream {
      guard
        !Task.isCancelled,
        Self.acceptsLiveEvent(
          activeRunID: activeRequest?.runID,
          activeGeneration: activeGeneration,
          eventScope: scope
        ),
        let request = activeRequest
      else {
        break
      }
      do {
        _ = try Self.requireTransmissionPermit(for: request)
        try await processAudioChunk(
          chunk,
          scope: scope,
          readinessGate: readinessGate
        )
      } catch {
        await readinessGate.signalPipelineFailure(scope: scope)
        scheduleUnexpectedTermination(for: scope)
        return
      }
    }
    await readinessGate.signalPipelineEndedBeforeReady(scope: scope)
    scheduleUnexpectedTermination(for: scope)
  }

  private func processAudioChunk(
    _ chunk: AudioChunk,
    scope: DeepgramLiveCaptureReadinessGate.Scope,
    readinessGate: DeepgramLiveCaptureReadinessGate
  ) async throws {
    guard let converter, let outputFormat, let outputFile else {
      throw DeepgramLiveRuntimeError.invalidAudioFormat
    }

    let convertedBuffer = try Self.convertBuffer(
      chunk.buffer, using: converter, outputFormat: outputFormat)
    guard convertedBuffer.frameLength > 0 else { return }

    try outputFile.write(from: convertedBuffer)
    totalFramesWritten += AVAudioFramePosition(convertedBuffer.frameLength)

    let audioData = try Self.data(from: convertedBuffer)
    let meterLevel = Self.normalizedRMSLevel(from: convertedBuffer)
    levelMeter.append(meterLevel)
    if levelMeter.count > 20 {
      levelMeter.removeFirst(levelMeter.count - 20)
    }

    guard
      Self.acceptsLiveEvent(
        activeRunID: self.activeRequest?.runID,
        activeGeneration: activeGeneration,
        eventScope: scope
      )
    else {
      return
    }

    guard !streamingFailed, let webSocketTask, let activeRequest else {
      throw DeepgramLiveRuntimeError.streamingFailed
    }
    do {
      _ = try Self.requireTransmissionPermit(for: activeRequest)
      try await webSocketTask.send(.data(audioData))
    } catch let error as DeepgramLiveRuntimeError where error.isAuthorizationFailure {
      throw error
    } catch {
      if Self.acceptsLiveEvent(
        activeRunID: self.activeRequest?.runID,
        activeGeneration: activeGeneration,
        eventScope: scope
      ) {
        streamingFailed = true
      }
      throw DeepgramLiveRuntimeError.streamingFailed
    }

    await readinessGate.signalAcceptedBuffer(scope: scope)
    observeEndpoint(in: convertedBuffer, request: activeRequest, scope: scope)

    guard
      Self.acceptsLiveEvent(
        activeRunID: self.activeRequest?.runID,
        activeGeneration: activeGeneration,
        eventScope: scope
      )
    else {
      return
    }

    let currentProjection = LiveProjection(
      phase: currentPhase,
      confirmedText: Self.joinedTranscript(finalSegments),
      hypothesisText: interimText,
      statusText: nil,
      levelMeter: levelMeter
    )
    await handleProjection(currentProjection, scope: scope)
  }

  private var currentPhase: LiveSubtitlePhase {
    if closeRequestedAt != nil {
      return .finalizing
    }
    let confirmedText = Self.joinedTranscript(finalSegments)
    if !confirmedText.isEmpty || !interimText.isEmpty {
      return .transcribing
    }
    return levelMeter.contains(where: { $0 > 0.01 }) ? .recording : .listening
  }

  private func receiveLoop(
    for scope: DeepgramLiveCaptureReadinessGate.Scope,
    readinessGate: DeepgramLiveCaptureReadinessGate
  ) async {
    defer {
      if Self.acceptsLiveEvent(
        activeRunID: activeRequest?.runID,
        activeGeneration: activeGeneration,
        eventScope: scope
      ) {
        receiveLoopFinished = true
      }
    }

    guard let webSocketTask else {
      await readinessGate.signalPipelineFailure(scope: scope)
      scheduleUnexpectedTermination(for: scope)
      return
    }
    while Self.acceptsLiveEvent(
      activeRunID: activeRequest?.runID,
      activeGeneration: activeGeneration,
      eventScope: scope
    ), !Task.isCancelled {
      do {
        let message = try await webSocketTask.receive()
        guard
          Self.acceptsLiveEvent(
            activeRunID: activeRequest?.runID,
            activeGeneration: activeGeneration,
            eventScope: scope
          ), !Task.isCancelled
        else {
          return
        }
        lastServerMessageTime = ContinuousClock.now
        switch message {
        case .string(let text):
          await processServerMessage(text, scope: scope)
        case .data(let data):
          if let text = String(data: data, encoding: .utf8) {
            await processServerMessage(text, scope: scope)
          }
        @unknown default:
          continue
        }
      } catch {
        if Self.acceptsLiveEvent(
          activeRunID: activeRequest?.runID,
          activeGeneration: activeGeneration,
          eventScope: scope
        ), !Task.isCancelled {
          streamingFailed = true
          await readinessGate.signalPipelineFailure(scope: scope)
          scheduleUnexpectedTermination(for: scope)
        }
        return
      }
    }
  }

  private func processServerMessage(
    _ text: String,
    scope: DeepgramLiveCaptureReadinessGate.Scope
  ) async {
    guard
      Self.acceptsLiveEvent(
        activeRunID: activeRequest?.runID,
        activeGeneration: activeGeneration,
        eventScope: scope
      )
    else {
      return
    }
    guard let data = text.data(using: .utf8) else { return }
    guard let message = try? JSONDecoder().decode(DeepgramStreamMessage.self, from: data) else {
      return
    }

    if let requestID = message.requestID?.nonEmpty ?? message.metadata?.requestID?.nonEmpty {
      deepgramRequestID = requestID
    }
    if message.isUtteranceEnd {
      didReceiveUtteranceEnd = true
      let detectedSpeech = Self.shouldSignalSpeechEndedForUtteranceEnd(
        message,
        hasFinalSegments: !finalSegments.isEmpty,
        interimText: interimText
      )
      if promoteInterimTranscriptToFinalIfNeeded(lastWordEnd: message.lastWordEnd) {
        let projection = LiveProjection(
          phase: currentPhase,
          confirmedText: Self.joinedTranscript(finalSegments),
          hypothesisText: interimText,
          statusText: nil,
          levelMeter: levelMeter
        )
        await handleProjection(projection, scope: scope)
      }
      if detectedSpeech,
        Self.acceptsLiveEvent(
          activeRunID: activeRequest?.runID,
          activeGeneration: activeGeneration,
          eventScope: scope
        )
      {
        _ = activeRequest?.endpointControl?.send(.speechEnded)
      }
      return
    }

    guard message.isResultsMessage else { return }
    guard shouldAcceptResultMessage(message) else { return }
    if Self.isAcceptedFinalizeResult(
      message,
      lastAcceptedWordEnd: lastAcceptedWordEnd
    ) {
      didReceiveAcceptedFinalizeResult = true
    }
    let transcript = Self.filterTranscript(message.transcriptText ?? "")

    if message.isAuthoritativeResult {
      let resolvedTranscript = transcript ?? interimText.nonEmpty
      if let resolvedTranscript, finalSegments.last != resolvedTranscript {
        finalSegments.append(resolvedTranscript)
      }
      interimText = ""
      if let lastWordEnd = message.lastWordEnd {
        lastAcceptedWordEnd = max(lastAcceptedWordEnd ?? lastWordEnd, lastWordEnd)
      }
      didResolveCurrentTranscript = resolvedTranscript != nil || reusableTranscript != nil
      if closeStreamSentAt != nil {
        didReceiveAuthoritativeResultAfterClose = true
      }
    } else {
      let nextInterim = transcript ?? ""
      interimText = nextInterim
      if !nextInterim.isEmpty {
        if let lastWordEnd = message.lastWordEnd {
          lastAcceptedWordEnd = max(lastAcceptedWordEnd ?? lastWordEnd, lastWordEnd)
        }
        didResolveCurrentTranscript = false
        didReceiveUtteranceEnd = false
      }
    }

    let projection = LiveProjection(
      phase: currentPhase,
      confirmedText: Self.joinedTranscript(finalSegments),
      hypothesisText: interimText,
      statusText: nil,
      levelMeter: levelMeter
    )
    await handleProjection(projection, scope: scope)
  }

  private func shouldAcceptResultMessage(_ message: DeepgramStreamMessage) -> Bool {
    Self.resultMessageIsCurrent(
      message,
      lastAcceptedWordEnd: lastAcceptedWordEnd
    )
  }

  static func isAcceptedFinalizeResult(
    _ message: DeepgramStreamMessage,
    lastAcceptedWordEnd: Double?
  ) -> Bool {
    message.isResultsMessage
      && message.fromFinalize == true
      && resultMessageIsCurrent(
        message,
        lastAcceptedWordEnd: lastAcceptedWordEnd
      )
  }

  static func shouldSignalSpeechEndedForUtteranceEnd(
    _ message: DeepgramStreamMessage,
    hasFinalSegments: Bool,
    interimText: String
  ) -> Bool {
    message.isUtteranceEnd
      && (message.lastWordEnd != nil
        || hasFinalSegments
        || interimText.nonEmpty != nil)
  }

  static func trustedReusableTranscript(
    _ transcript: String?,
    streamingFailed: Bool,
    acceptedFinalizeResult: Bool
  ) -> String? {
    guard !streamingFailed, acceptedFinalizeResult else { return nil }
    return transcript
  }

  static func acceptsLiveEvent(
    activeRunID: UUID?,
    activeGeneration: UInt64?,
    eventScope: DeepgramLiveCaptureReadinessGate.Scope
  ) -> Bool {
    activeRunID == eventScope.runID
      && activeGeneration == eventScope.generation
  }

  static func acceptsLiveProjection(
    activeRunID: UUID?,
    activeGeneration: UInt64?,
    recordingGeneration: UInt64?,
    projectionScope: DeepgramLiveCaptureReadinessGate.Scope
  ) -> Bool {
    acceptsLiveEvent(
      activeRunID: activeRunID,
      activeGeneration: activeGeneration,
      eventScope: projectionScope
    )
      && recordingGeneration == projectionScope.generation
  }

  private static func resultMessageIsCurrent(
    _ message: DeepgramStreamMessage,
    lastAcceptedWordEnd: Double?
  ) -> Bool {
    guard let lastWordEnd = message.lastWordEnd else { return true }
    guard let lastAcceptedWordEnd else { return true }
    return lastWordEnd + 0.05 >= lastAcceptedWordEnd
  }

  @discardableResult
  private func promoteInterimTranscriptToFinalIfNeeded(lastWordEnd: Double?) -> Bool {
    guard let transcript = interimText.nonEmpty else { return false }
    if finalSegments.last != transcript {
      finalSegments.append(transcript)
    }
    interimText = ""
    didResolveCurrentTranscript = true
    if let lastWordEnd {
      lastAcceptedWordEnd = max(lastAcceptedWordEnd ?? lastWordEnd, lastWordEnd)
    }
    return true
  }

  private var hasStableReusableTranscript: Bool {
    reusableTranscript != nil
      && (didResolveCurrentTranscript
        || didReceiveUtteranceEnd
        || didReceiveAcceptedFinalizeResult
        || didReceiveAuthoritativeResultAfterClose)
  }

  private func waitForServerMessages(
    timeout: ContinuousClock.Duration,
    quietDuration: ContinuousClock.Duration,
    requestedAt: ContinuousClock.Instant?,
    lifetime: AudioCaptureLifetime?
  ) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)

    while ContinuousClock.now < deadline {
      guard lifetime?.isActive == true else { return }
      if receiveLoopFinished {
        return
      }
      if didReceiveAuthoritativeResultAfterClose, reusableTranscript != nil {
        return
      }
      if didReceiveAcceptedFinalizeResult, reusableTranscript != nil {
        return
      }
      if didReceiveUtteranceEnd, reusableTranscript != nil {
        return
      }
      if let lastServerMessageTime,
        requestedAt.map({ lastServerMessageTime > $0 }) ?? true,
        ContinuousClock.now - lastServerMessageTime > quietDuration,
        hasStableReusableTranscript
      {
        return
      }

      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  private func handleProjection(
    _ projection: LiveProjection,
    scope: DeepgramLiveCaptureReadinessGate.Scope
  ) async {
    guard
      Self.acceptsLiveEvent(
        activeRunID: activeRequest?.runID,
        activeGeneration: activeGeneration,
        eventScope: scope
      )
    else {
      return
    }
    latestProjection = projection
    guard shouldPublishLiveUpdates,
      Self.acceptsLiveProjection(
        activeRunID: activeRequest?.runID,
        activeGeneration: activeGeneration,
        recordingGeneration: recordingGeneration,
        projectionScope: scope
      )
    else {
      return
    }

    let now = ContinuousClock.now
    if let lastProjectionPublishTime,
      now - lastProjectionPublishTime < Self.projectionThrottleInterval
    {
      guard isProjectionFlushScheduled == false else { return }
      isProjectionFlushScheduled = true
      pendingProjectionTask = Task { [weak self] in
        try? await Task.sleep(for: Self.projectionThrottleInterval)
        guard !Task.isCancelled else { return }
        await self?.flushPendingProjection(for: scope)
      }
      return
    }

    lastProjectionPublishTime = now
    isProjectionFlushScheduled = false
    guard let workflow = activeRequest?.workflow.presentation else { return }
    await publishProjection(
      projection,
      runID: scope.runID,
      workflow: workflow,
      generation: scope.generation
    )
  }

  private func flushPendingProjection(
    for scope: DeepgramLiveCaptureReadinessGate.Scope
  ) async {
    guard
      Self.acceptsLiveProjection(
        activeRunID: activeRequest?.runID,
        activeGeneration: activeGeneration,
        recordingGeneration: recordingGeneration,
        projectionScope: scope
      )
    else {
      return
    }
    isProjectionFlushScheduled = false
    guard let latestProjection, let workflow = activeRequest?.workflow.presentation else { return }
    lastProjectionPublishTime = ContinuousClock.now
    await publishProjection(
      latestProjection,
      runID: scope.runID,
      workflow: workflow,
      generation: scope.generation
    )
  }

  private func publishProjection(
    _ projection: LiveProjection?,
    runID: UUID,
    workflow: WorkflowPresentation,
    generation: UInt64
  ) async {
    let scope = DeepgramLiveCaptureReadinessGate.Scope(
      runID: runID,
      generation: generation
    )
    guard let projection,
      Self.acceptsLiveProjection(
        activeRunID: activeRequest?.runID,
        activeGeneration: activeGeneration,
        recordingGeneration: recordingGeneration,
        projectionScope: scope
      )
    else {
      return
    }
    await liveUpdateHandler(
      LiveSubtitleSnapshot(
        runID: runID,
        workflow: workflow,
        phase: projection.phase,
        confirmedText: projection.confirmedText,
        hypothesisText: projection.hypothesisText,
        statusText: projection.statusText,
        levelMeter: projection.levelMeter,
        providerID: Self.providerID
      )
    )
  }

  private func publishHiddenSnapshot(for request: AudioCaptureRequest) async {
    await liveUpdateHandler(
      LiveSubtitleSnapshot(
        runID: request.runID,
        workflow: request.workflow.presentation,
        phase: .hidden
      )
    )
  }

  private func sendControlMessage(
    _ object: [String: String],
    for request: AudioCaptureRequest
  ) async throws {
    guard let webSocketTask else { return }
    _ = try Self.requireTransmissionPermit(for: request)
    let data = try JSONSerialization.data(withJSONObject: object)
    guard let text = String(data: data, encoding: .utf8) else {
      throw DeepgramLiveRuntimeError.invalidControlMessage
    }
    try await webSocketTask.send(.string(text))
  }

  private func shutdownSocket(for runID: UUID) async {
    let task = receiveTask
    task?.cancel()
    if let webSocketTask {
      webSocketTask.cancel(with: .normalClosure, reason: nil)
    }
    if let task {
      await task.value
    }
    if activeRequest?.runID == runID {
      receiveTask = nil
    }
  }

  private func stopEngine() {
    engine?.inputNode.removeTap(onBus: 0)
    engine?.stop()
  }

  private func removeEngineConfigurationObserver() {
    guard let engineConfigurationObserver else { return }
    NotificationCenter.default.removeObserver(engineConfigurationObserver.token)
    self.engineConfigurationObserver = nil
  }

  /// Revocation teardown is intentionally different from normal finishing:
  /// queued chunks are discarded and no Finalize or CloseStream is emitted.
  private func discardActiveCapture(
    for request: AudioCaptureRequest,
    generation: UInt64? = nil,
    cancelLifetime: Bool,
    awaitChunkTask: Bool
  ) async {
    guard activeRequest?.runID == request.runID else { return }
    if let generation, activeGeneration != generation { return }
    if cancelLifetime {
      Self.matchingLifetime(for: request)?.cancel()
    }

    // Privacy teardown order: stop input, discard buffered work, then close
    // the transport and remove the local temporary payload.
    removeEngineConfigurationObserver()
    stopEngine()
    if let activeReadinessGate {
      await activeReadinessGate.cancel()
    }
    shouldPublishLiveUpdates = false
    pendingProjectionTask?.cancel()
    pendingProjectionTask = nil
    isProjectionFlushScheduled = false
    chunkBuffer?.finish()
    chunkBuffer = nil

    let chunkTask = chunkProcessingTask
    if awaitChunkTask {
      chunkTask?.cancel()
    }
    let oldReceiveTask = receiveTask
    oldReceiveTask?.cancel()
    webSocketTask?.cancel(with: .normalClosure, reason: nil)

    if awaitChunkTask, let chunkTask {
      await chunkTask.value
    }
    if let oldReceiveTask {
      await oldReceiveTask.value
    }

    await cleanup(removeOutputFile: true)
    await publishHiddenSnapshot(for: request)
  }

  static func makeFailClosedAudioBuffer<Element: Sendable>(
    capacity: Int,
    request: AudioCaptureRequest,
    onOverflow: @escaping @Sendable () -> Void
  ) -> FailClosedAsyncBuffer<Element> {
    FailClosedAsyncBuffer(capacity: capacity) {
      matchingLifetime(for: request)?.revoke(.serviceFailure)
      onOverflow()
    }
  }

  private func handleAudioBufferOverflow(
    for request: AudioCaptureRequest,
    scope: DeepgramLiveCaptureReadinessGate.Scope
  ) async {
    guard
      request.runID == scope.runID,
      Self.acceptsLiveEvent(
        activeRunID: activeRequest?.runID,
        activeGeneration: activeGeneration,
        eventScope: scope
      )
    else {
      return
    }
    scheduleUnexpectedTermination(for: scope)
  }

  /// Schedules teardown outside the receive/chunk task that reported the
  /// failure. The teardown can then safely drain both tasks without ever
  /// awaiting the currently executing task.
  private func scheduleUnexpectedTermination(
    for scope: DeepgramLiveCaptureReadinessGate.Scope
  ) {
    Task { [weak self] in
      await Task.yield()
      await self?.terminateUnexpectedlyIfOwned(for: scope)
    }
  }

  private func terminateUnexpectedlyIfOwned(
    for scope: DeepgramLiveCaptureReadinessGate.Scope
  ) async {
    guard
      terminalGate.claim(
        activeRunID: activeRequest?.runID,
        activeGeneration: activeGeneration,
        recordingGeneration: recordingGeneration,
        eventScope: scope,
        isFinishing: closeRequestedAt != nil
      ),
      let request = activeRequest
    else {
      return
    }

    streamingFailed = true
    Self.matchingLifetime(for: request)?.revoke(.serviceFailure)
    await discardActiveCapture(
      for: request,
      generation: scope.generation,
      cancelLifetime: false,
      awaitChunkTask: true
    )
    await unexpectedTerminationHandler(scope)
  }

  private func observeEndpoint(
    in buffer: AVAudioPCMBuffer,
    request: AudioCaptureRequest,
    scope: DeepgramLiveCaptureReadinessGate.Scope
  ) {
    guard
      Self.acceptsLiveEvent(
        activeRunID: activeRequest?.runID,
        activeGeneration: activeGeneration,
        eventScope: scope
      ),
      let endpointControl = request.endpointControl,
      var detector = endpointDetector
    else {
      return
    }

    _ = Self.observeProcessedEndpoint(
      in: buffer,
      endpointControl: endpointControl,
      detector: &detector
    )
    endpointDetector = detector
  }

  @discardableResult
  static func observeProcessedEndpoint(
    in buffer: AVAudioPCMBuffer,
    endpointControl: AudioCaptureEndpointControl,
    detector: inout SpeechEndpointDetector
  ) -> SpeechEndpointOutcome? {
    let durationSeconds = sampleDuration(
      frameLength: buffer.frameLength,
      sampleRate: buffer.format.sampleRate
    )
    let relativeEnergy = endpointRelativeEnergy(
      fromNormalizedRMS: normalizedRMSLevel(from: buffer)
    )
    endpointControl.observeEnergy(
      relativeLevel: relativeEnergy,
      durationSeconds: durationSeconds
    )
    let outcome = detector.observe(
      isSpeech: relativeEnergy >= endpointControl.policy.voiceActivityThreshold,
      durationSeconds: durationSeconds
    )

    switch outcome {
    case .initialSilenceTimedOut:
      _ = endpointControl.send(.initialSilenceTimedOut)
    case .speechEnded:
      _ = endpointControl.send(.speechEnded)
    case nil:
      break
    }
    return outcome
  }

  static func requireTransmissionPermit(
    for request: AudioCaptureRequest
  ) throws -> AudioCaptureLifetime.TransmissionPermit {
    guard let lifetime = request.audioLifetime else {
      throw DeepgramLiveRuntimeError.missingAudioLifetime
    }
    guard lifetime.runID == request.runID else {
      throw DeepgramLiveRuntimeError.audioLifetimeRunMismatch
    }
    guard let permit = lifetime.acquireTransmissionPermit() else {
      throw DeepgramLiveRuntimeError.audioAuthorizationRevoked
    }
    return permit
  }

  private static func matchingLifetime(for request: AudioCaptureRequest) -> AudioCaptureLifetime? {
    guard let lifetime = request.audioLifetime, lifetime.runID == request.runID else { return nil }
    return lifetime
  }

  private func throwIfCancelled(for request: AudioCaptureRequest) throws {
    if cancelledRunIDs.contains(request.runID) {
      throw CancellationError()
    }
    try Task.checkCancellation()
  }

  private func cleanup(removeOutputFile: Bool) async {
    removeEngineConfigurationObserver()
    pendingProjectionTask?.cancel()
    if let activeReadinessGate {
      await activeReadinessGate.cancel()
    }
    let cleanupRunID = activeRequest?.runID
    if removeOutputFile, let outputURL, let cleanupRunID {
      _ = await cleanupOwner.transfer(fileURL: outputURL, runID: cleanupRunID)
    }

    activeRequest = nil
    preparingRequest = nil
    activeModel = nil
    engine = nil
    converter = nil
    outputFormat = nil
    outputFile = nil
    outputURL = nil
    webSocketTask = nil
    receiveTask = nil
    chunkProcessingTask = nil
    chunkBuffer = nil
    activeReadinessGate = nil
    engineConfigurationObserver = nil
    activeGeneration = nil
    recordingGeneration = nil
    terminalGate = DeepgramLiveTerminalGate()
    endpointDetector = nil
    latestProjection = nil
    lastProjectionPublishTime = nil
    pendingProjectionTask = nil
    isProjectionFlushScheduled = false
    shouldPublishLiveUpdates = false
    finalSegments = []
    interimText = ""
    levelMeter = []
    totalFramesWritten = 0
    deepgramRequestID = nil
    lastServerMessageTime = nil
    finalizeRequestedAt = nil
    closeRequestedAt = nil
    closeStreamSentAt = nil
    didResolveCurrentTranscript = false
    didReceiveUtteranceEnd = false
    didReceiveAuthoritativeResultAfterClose = false
    didReceiveAcceptedFinalizeResult = false
    lastAcceptedWordEnd = nil
    receiveLoopFinished = false
    streamingFailed = false

    if removeOutputFile, let cleanupRunID {
      await cleanupOwner.drain(runID: cleanupRunID)
    }
  }

  func removeServiceOwnedFile(_ fileURL: URL, runID: UUID) async {
    _ = await cleanupOwner.transfer(fileURL: fileURL, runID: runID)
    await cleanupOwner.drain(runID: runID)
  }

  private func resetState() {
    pendingProjectionTask?.cancel()
    activeReadinessGate = nil
    activeGeneration = nil
    recordingGeneration = nil
    terminalGate = DeepgramLiveTerminalGate()
    endpointDetector = nil
    latestProjection = nil
    lastProjectionPublishTime = nil
    pendingProjectionTask = nil
    isProjectionFlushScheduled = false
    shouldPublishLiveUpdates = false
    finalSegments = []
    interimText = ""
    levelMeter = []
    totalFramesWritten = 0
    deepgramRequestID = nil
    lastServerMessageTime = nil
    finalizeRequestedAt = nil
    closeRequestedAt = nil
    closeStreamSentAt = nil
    didResolveCurrentTranscript = false
    didReceiveUtteranceEnd = false
    didReceiveAuthoritativeResultAfterClose = false
    didReceiveAcceptedFinalizeResult = false
    lastAcceptedWordEnd = nil
    receiveLoopFinished = false
    streamingFailed = false
  }

  private static func makeTemporaryRecordingURL(for runID: UUID) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-deepgram-live-\(runID.uuidString)")
      .appendingPathExtension("wav")
  }

  static func makeOutputFile(for outputURL: URL, format: AVAudioFormat) throws -> AVAudioFile {
    try AVAudioFile(
      forWriting: outputURL,
      settings: format.settings,
      commonFormat: format.commonFormat,
      interleaved: format.isInterleaved
    )
  }

  static func makeWebSocketRequest(
    for request: AudioCaptureRequest,
    configuration: DeepgramRecognizer.Configuration
  ) throws -> URLRequest {
    try makeWebSocketRequestPlan(for: request, configuration: configuration).request
  }

  private static func makeWebSocketRequestPlan(
    for request: AudioCaptureRequest,
    configuration: DeepgramRecognizer.Configuration
  ) throws -> WebSocketRequestPlan {
    let validatedConfiguration = try DeepgramConfigurationValidator.validate(configuration)
    guard
      var components = URLComponents(
        url: validatedConfiguration.baseURL,
        resolvingAgainstBaseURL: false
      )
    else {
      throw DeepgramRecognizer.RecognizerError.invalidBaseURL
    }
    switch components.scheme?.lowercased() {
    case "http":
      components.scheme = "ws"
    case "https":
      components.scheme = "wss"
    default:
      throw DeepgramRecognizer.RecognizerError.invalidBaseURL
    }
    components.path = "/v1/listen"

    let plan = DeepgramRequestPlanner.plan(
      options: request.options,
      workflow: request.workflow,
      configuration: configuration,
      source: .live
    )
    var queryItems = [
      URLQueryItem(name: "model", value: plan.model),
      URLQueryItem(name: "encoding", value: "linear16"),
      URLQueryItem(name: "sample_rate", value: "16000"),
      URLQueryItem(name: "channels", value: "1"),
      URLQueryItem(name: "interim_results", value: "true"),
      URLQueryItem(name: "punctuate", value: "true"),
      URLQueryItem(name: "smart_format", value: configuration.smartFormat ? "true" : "false"),
      URLQueryItem(name: "vad_events", value: configuration.vadEvents ? "true" : "false"),
    ]

    if let endpointingMillis = configuration.endpointingMillis {
      queryItems.append(URLQueryItem(name: "endpointing", value: String(endpointingMillis)))
    }
    if let utteranceEndMillis = configuration.utteranceEndMillis {
      queryItems.append(URLQueryItem(name: "utterance_end_ms", value: String(utteranceEndMillis)))
    }

    if let language = plan.language {
      queryItems.append(URLQueryItem(name: "language", value: language))
    }
    DeepgramRequestPlanner.appendKeyterms(from: plan, to: &queryItems)
    components.queryItems = queryItems

    guard let url = components.url else {
      throw DeepgramRecognizer.RecognizerError.invalidBaseURL
    }
    var request = URLRequest(url: url)
    request.setValue("Token \(validatedConfiguration.apiKey)", forHTTPHeaderField: "Authorization")
    return WebSocketRequestPlan(request: request, plan: plan)
  }

  private static func supportsStreamingOutputFormat(_ format: AVAudioFormat) -> Bool {
    format.commonFormat == .pcmFormatInt16
      && format.channelCount == 1
      && abs(format.sampleRate - Self.outputSampleRate) < 0.5
  }

  private static func convertBuffer(
    _ buffer: AVAudioPCMBuffer,
    using converter: AVAudioConverter,
    outputFormat: AVAudioFormat
  ) throws -> AVAudioPCMBuffer {
    let ratio = outputFormat.sampleRate / buffer.format.sampleRate
    let outputCapacity = AVAudioFrameCount(
      max(1, Int((Double(buffer.frameLength) * ratio).rounded(.up)) + 8))
    guard
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: outputCapacity
      )
    else {
      throw DeepgramLiveRuntimeError.invalidAudioFormat
    }

    let inputState = ConversionInputState()
    let sourceBuffer = PCMBufferBox(buffer)
    var conversionError: NSError?
    let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
      if inputState.didProvideInput {
        outStatus.pointee = .noDataNow
        return nil
      }
      inputState.didProvideInput = true
      outStatus.pointee = .haveData
      return sourceBuffer.buffer
    }

    if let conversionError {
      throw conversionError
    }
    if status == .error {
      throw DeepgramLiveRuntimeError.audioConversionFailed
    }

    return outputBuffer
  }

  private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
    else {
      return nil
    }
    copy.frameLength = buffer.frameLength

    let frameCount = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)

    switch buffer.format.commonFormat {
    case .pcmFormatFloat32:
      guard let source = buffer.floatChannelData, let destination = copy.floatChannelData else {
        return nil
      }
      let byteCount = frameCount * MemoryLayout<Float>.size
      if buffer.format.isInterleaved {
        memcpy(destination.pointee, source.pointee, byteCount * channelCount)
      } else {
        for channel in 0..<channelCount {
          memcpy(destination[channel], source[channel], byteCount)
        }
      }
    case .pcmFormatInt16:
      guard let source = buffer.int16ChannelData, let destination = copy.int16ChannelData else {
        return nil
      }
      let byteCount = frameCount * MemoryLayout<Int16>.size
      if buffer.format.isInterleaved {
        memcpy(destination.pointee, source.pointee, byteCount * channelCount)
      } else {
        for channel in 0..<channelCount {
          memcpy(destination[channel], source[channel], byteCount)
        }
      }
    default:
      return nil
    }

    return copy
  }

  private static func data(from buffer: AVAudioPCMBuffer) throws -> Data {
    let byteCount =
      Int(buffer.frameLength) * Int(buffer.format.channelCount) * MemoryLayout<Int16>.size
    guard let channelData = buffer.int16ChannelData else {
      throw DeepgramLiveRuntimeError.invalidAudioFormat
    }
    return Data(bytes: channelData.pointee, count: byteCount)
  }

  private static func normalizedRMSLevel(from buffer: AVAudioPCMBuffer) -> Float {
    guard let channelData = buffer.int16ChannelData else { return 0 }
    let sampleCount = Int(buffer.frameLength) * Int(buffer.format.channelCount)
    guard sampleCount > 0 else { return 0 }

    let samples = UnsafeBufferPointer(start: channelData.pointee, count: sampleCount)
    let meanSquare =
      samples.reduce(into: Float.zero) { partial, sample in
        let value = Float(sample) / Float(Int16.max)
        partial += value * value
      } / Float(sampleCount)
    return min(max(sqrt(meanSquare), 0), 1)
  }

  static func sampleDuration(
    frameLength: AVAudioFrameCount,
    sampleRate: Double
  ) -> Double {
    guard sampleRate > 0 else { return 0 }
    return Double(frameLength) / sampleRate
  }

  /// Maps processed PCM RMS into the same normalized activity domain used by
  /// the shared endpoint policy. Apple Voice Processing has already removed
  /// much of the stationary floor; an RMS of 0.015 therefore corresponds to
  /// the default policy's 0.3 speech threshold without treating small fan or
  /// keyboard noise as sustained speech.
  static func endpointRelativeEnergy(fromNormalizedRMS rms: Float) -> Float {
    min(max(rms / 0.05, 0), 1)
  }

  private static func joinedTranscript(_ segments: [String]) -> String {
    segments
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func filterTranscript(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func requestMicrophonePermission() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return true
    case .denied, .restricted:
      return false
    case .notDetermined:
      return await withCheckedContinuation { continuation in
        AVCaptureDevice.requestAccess(for: .audio) { granted in
          continuation.resume(returning: granted)
        }
      }
    @unknown default:
      return false
    }
  }
}

enum DeepgramLiveRuntimeError: Error, LocalizedError, Equatable {
  case missingAudioLifetime
  case audioLifetimeRunMismatch
  case audioAuthorizationRevoked
  case audioConversionFailed
  case streamingFailed
  case invalidAudioFormat
  case invalidControlMessage
  case missingOutputFile

  var isAuthorizationFailure: Bool {
    switch self {
    case .missingAudioLifetime, .audioLifetimeRunMismatch, .audioAuthorizationRevoked:
      return true
    case .audioConversionFailed,
      .streamingFailed,
      .invalidAudioFormat,
      .invalidControlMessage,
      .missingOutputFile:
      return false
    }
  }

  var errorDescription: String? {
    switch self {
    case .missingAudioLifetime:
      return "Deepgram live capture requires a run-scoped audio authorization lifetime."
    case .audioLifetimeRunMismatch:
      return "The live audio authorization does not match this capture run."
    case .audioAuthorizationRevoked:
      return "Live audio authorization is no longer active."
    case .audioConversionFailed:
      return "The microphone audio could not be converted for Deepgram live streaming."
    case .streamingFailed:
      return "The Deepgram live audio stream ended unexpectedly."
    case .invalidAudioFormat:
      return "The Deepgram live capture audio format is unavailable."
    case .invalidControlMessage:
      return "The Deepgram live control message could not be encoded."
    case .missingOutputFile:
      return "The Deepgram live capture could not produce a recording file."
    }
  }
}

struct DeepgramStreamMessage: Decodable {
  struct Channel: Decodable {
    struct Alternative: Decodable {
      let transcript: String
    }

    let alternatives: [Alternative]
  }

  struct Metadata: Decodable {
    let requestID: String?

    enum CodingKeys: String, CodingKey {
      case requestID = "request_id"
    }
  }

  let type: String?
  let channel: Channel?
  let utteranceChannels: [Int]?
  let isFinal: Bool?
  let speechFinal: Bool?
  let fromFinalize: Bool?
  let metadata: Metadata?
  let requestID: String?
  let lastWordEnd: Double?

  var normalizedType: String? {
    type?.lowercased()
  }

  var isResultsMessage: Bool {
    normalizedType == "results"
  }

  var isUtteranceEnd: Bool {
    normalizedType == "utteranceend"
  }

  var isAuthoritativeResult: Bool {
    isFinal == true || speechFinal == true || fromFinalize == true
  }

  var transcriptText: String? {
    channel?.alternatives.first?.transcript
  }

  init() {
    type = nil
    channel = nil
    utteranceChannels = nil
    isFinal = nil
    speechFinal = nil
    fromFinalize = nil
    metadata = nil
    requestID = nil
    lastWordEnd = nil
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decodeIfPresent(String.self, forKey: .type)
    channel = try? container.decode(Channel.self, forKey: .channel)
    utteranceChannels = try? container.decode([Int].self, forKey: .channel)
    isFinal = try container.decodeIfPresent(Bool.self, forKey: .isFinal)
    speechFinal = try container.decodeIfPresent(Bool.self, forKey: .speechFinal)
    fromFinalize = try container.decodeIfPresent(Bool.self, forKey: .fromFinalize)
    metadata = try container.decodeIfPresent(Metadata.self, forKey: .metadata)
    requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
    lastWordEnd = try container.decodeIfPresent(Double.self, forKey: .lastWordEnd)
  }

  enum CodingKeys: String, CodingKey {
    case type
    case channel
    case isFinal = "is_final"
    case speechFinal = "speech_final"
    case fromFinalize = "from_finalize"
    case metadata
    case requestID = "request_id"
    case lastWordEnd = "last_word_end"
  }
}

private final class PCMBufferBox: @unchecked Sendable {
  let buffer: AVAudioPCMBuffer

  init(_ buffer: AVAudioPCMBuffer) {
    self.buffer = buffer
  }
}

private final class NotificationObserverToken: @unchecked Sendable {
  let token: NSObjectProtocol

  init(_ token: NSObjectProtocol) {
    self.token = token
  }
}

private final class DeepgramVoiceProcessingEngineTarget:
  AppleVoiceProcessingEngineConfigurationTarget
{
  fileprivate let engine: AVAudioEngine
  private let outputPath: AppleVoiceProcessingOutputPath

  init(engine: AVAudioEngine) {
    self.engine = engine
    outputPath = AppleVoiceProcessingOutputPath(engine: engine)
  }

  var isRunning: Bool { engine.isRunning }
  var isInputVoiceProcessingEnabled: Bool {
    engine.inputNode.isVoiceProcessingEnabled
  }
  var isOutputVoiceProcessingEnabled: Bool {
    engine.outputNode.isVoiceProcessingEnabled
  }
  var voiceProcessingInputFormat: AppleVoiceProcessingIOFormat? {
    outputPath.inputFormat
  }
  var isVoiceProcessingBypassed: Bool {
    get { engine.inputNode.isVoiceProcessingBypassed }
    set { engine.inputNode.isVoiceProcessingBypassed = newValue }
  }
  var isVoiceProcessingInputMuted: Bool {
    get { engine.inputNode.isVoiceProcessingInputMuted }
    set { engine.inputNode.isVoiceProcessingInputMuted = newValue }
  }
  var isVoiceProcessingAGCEnabled: Bool {
    get { engine.inputNode.isVoiceProcessingAGCEnabled }
    set { engine.inputNode.isVoiceProcessingAGCEnabled = newValue }
  }

  func setVoiceProcessingEnabled(_ isEnabled: Bool) throws {
    try engine.inputNode.setVoiceProcessingEnabled(isEnabled)
  }

  func configureVoiceProcessingInputDevice() throws {}

  func establishVoiceProcessingOutputPath(
    matching format: AppleVoiceProcessingIOFormat
  ) -> Bool {
    outputPath.establish(matching: format)
  }

  var formatsRemainMatched: Bool {
    guard let inputFormat = outputPath.inputFormat else { return false }
    return outputPath.isEstablished(matching: inputFormat)
  }
}

private final class ConversionInputState: @unchecked Sendable {
  var didProvideInput = false
}

extension String {
  fileprivate var nonEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
