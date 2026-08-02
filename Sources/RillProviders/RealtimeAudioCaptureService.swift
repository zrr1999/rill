import AVFoundation
import Foundation
import RillCore
import RillPlatform

public actor RealtimeAudioCaptureService: AudioCaptureService {
  public nonisolated let sharedVoiceInputHub: SharedVoiceInputHub?
  typealias LocalSpeechCaptureRuntimeFactory =
    @Sendable (
      _ unexpectedTerminationHandler: @escaping @Sendable () async -> Void
    ) -> LocalSpeechVoiceCaptureRuntime

  private static let localSpeechRecognizerID = "local-speech"

  public enum CaptureError: Error, LocalizedError, Equatable {
    case alreadyCapturing
    case microphonePermissionDenied
    case microphoneStartFailed
    case microphoneStartTimedOut
    case voiceActivityDetectionUnavailable
    case invalidEndpointControl
    case notCapturing
    case shuttingDown

    public var errorDescription: String? {
      switch self {
      case .alreadyCapturing:
        return "An audio capture is already in progress."
      case .microphonePermissionDenied:
        return "Microphone permission is required for live subtitles."
      case .microphoneStartFailed:
        return "The microphone could not start recording."
      case .microphoneStartTimedOut:
        return "The microphone did not become ready in time."
      case .voiceActivityDetectionUnavailable:
        return "Local voice activity detection is unavailable."
      case .invalidEndpointControl:
        return "The audio endpoint control does not match the capture run."
      case .notCapturing:
        return "No audio capture is currently active."
      case .shuttingDown:
        return "Audio capture is shutting down."
      }
    }
  }

  private enum Lifecycle: Sendable, Equatable {
    case accepting
    case shuttingDown
    case terminated
  }

  private struct CaptureReservation: Sendable {
    let identity = UUID()
    let request: AudioCaptureRequest
  }

  private enum ActiveCapture {
    case preparing(CaptureReservation)
    case startingLocalSpeech(LocalSpeechCaptureState)
    case localSpeech(LocalSpeechCaptureState)
    case stoppingLocalSpeech(LocalSpeechCaptureState, Task<Void, Never>)
    case startingFallback(CaptureReservation)
    case fallback(CaptureReservation)

    var reservation: CaptureReservation {
      switch self {
      case .preparing(let reservation),
        .startingFallback(let reservation),
        .fallback(let reservation):
        return reservation
      case .startingLocalSpeech(let capture),
        .localSpeech(let capture):
        return capture.reservation
      case .stoppingLocalSpeech(let capture, _):
        return capture.reservation
      }
    }

    var request: AudioCaptureRequest {
      reservation.request
    }
  }

  private struct LocalSpeechCaptureState: Sendable {
    let reservation: CaptureReservation
    let runtime: LocalSpeechVoiceCaptureRuntime

    var request: AudioCaptureRequest { reservation.request }
  }

  private let legacyCaptureService: any AudioCaptureService
  private let liveUpdateHandler: @Sendable (LiveSubtitleSnapshot) async -> Void
  private let cleanupOwner: ManagedTemporaryAudioCleanupOwner
  private let localSpeechCaptureRuntimeFactory: LocalSpeechCaptureRuntimeFactory
  private let localSpeechCaptureSource: (any LocalSpeechAudioCaptureSource)?
  private let wakeWordSpeechStartedHandler: @Sendable () -> Void

  private var activeCapture: ActiveCapture?
  private var lifecycle: Lifecycle = .accepting
  private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    legacyCaptureService: (any AudioCaptureService)? = nil,
    streamingPreviewService: SpeechWorkerStreamingPreviewService? = nil,
    liveUpdateHandler: @escaping @Sendable (LiveSubtitleSnapshot) async -> Void = { _ in },
    cleanupOwner: ManagedTemporaryAudioCleanupOwner = ManagedTemporaryAudioCleanupOwner(),
    localSpeechStartupTimeout: Duration = .seconds(3),
    localSpeechReadinessSleep: @escaping @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    },
    wakeWordSpeechStartedHandler: @escaping @Sendable () -> Void = {}
  ) {
    self.legacyCaptureService =
      legacyCaptureService
      ?? AVAudioCaptureService(cleanupOwner: cleanupOwner)
    self.liveUpdateHandler = liveUpdateHandler
    self.cleanupOwner = cleanupOwner
    // Both channels use the input-only frontend. Rebuilding VoiceProcessingIO
    // on every push-to-talk run takes well over a second on real hardware and
    // also attaches Rill to the output device even though local recognition
    // only needs microphone PCM. The raw frontend still goes through the same
    // conversion, metering, buffering, arbitration, and full teardown when the
    // final subscriber leaves.
    let ambientVoiceInputProcessor = AppleVoiceProcessingAudioProcessor(
      sessionFactory: LiveRawMicrophoneAudioEngineSessionFactory()
    )
    let voiceInputProcessor = AppleVoiceProcessingAudioProcessor(
      sessionFactory: LiveRawMicrophoneAudioEngineSessionFactory()
    )
    let sharedVoiceInputHub = SharedVoiceInputHub(
      ambientProcessor: ambientVoiceInputProcessor,
      interactiveProcessor: voiceInputProcessor
    )
    self.sharedVoiceInputHub = sharedVoiceInputHub
    let localSpeechCaptureSource = SharedVoiceInputCaptureSource(
      hub: sharedVoiceInputHub,
      processor: voiceInputProcessor
    )
    self.localSpeechCaptureSource = localSpeechCaptureSource
    self.wakeWordSpeechStartedHandler = wakeWordSpeechStartedHandler
    self.localSpeechCaptureRuntimeFactory = Self.makeLocalSpeechCaptureRuntimeFactory(
      captureSource: localSpeechCaptureSource,
      streamingPreviewService: streamingPreviewService,
      liveUpdateHandler: liveUpdateHandler,
      cleanupOwner: cleanupOwner,
      startupTimeout: localSpeechStartupTimeout,
      readinessSleep: localSpeechReadinessSleep,
      wakeWordSpeechStartedHandler: wakeWordSpeechStartedHandler
    )
  }

  /// Internal construction seam for deterministic capture-lifecycle tests.
  init(
    legacyCaptureService: any AudioCaptureService,
    liveUpdateHandler: @escaping @Sendable (LiveSubtitleSnapshot) async -> Void,
    localSpeechCaptureRuntimeFactory: @escaping LocalSpeechCaptureRuntimeFactory
  ) {
    self.legacyCaptureService = legacyCaptureService
    self.liveUpdateHandler = liveUpdateHandler
    self.cleanupOwner = ManagedTemporaryAudioCleanupOwner()
    self.sharedVoiceInputHub = nil
    self.localSpeechCaptureRuntimeFactory = localSpeechCaptureRuntimeFactory
    self.localSpeechCaptureSource = nil
    self.wakeWordSpeechStartedHandler = {}
  }

  /// Internal production-shaped seam for proving that sequential local runs
  /// retain one stopped VPIO frontend instead of allocating a fresh audio
  /// engine for every recording.
  init(
    legacyCaptureService: any AudioCaptureService,
    liveUpdateHandler: @escaping @Sendable (LiveSubtitleSnapshot) async -> Void,
    localSpeechCaptureSource: any LocalSpeechAudioCaptureSource,
    isMicrophoneAuthorizedForLocalSpeechPrewarm:
      @escaping @Sendable () -> Bool = { true }
  ) {
    let cleanupOwner = ManagedTemporaryAudioCleanupOwner()
    self.legacyCaptureService = legacyCaptureService
    self.liveUpdateHandler = liveUpdateHandler
    self.cleanupOwner = cleanupOwner
    self.sharedVoiceInputHub = nil
    self.localSpeechCaptureSource = localSpeechCaptureSource
    self.wakeWordSpeechStartedHandler = {}
    _ = isMicrophoneAuthorizedForLocalSpeechPrewarm
    self.localSpeechCaptureRuntimeFactory = Self.makeLocalSpeechCaptureRuntimeFactory(
      captureSource: localSpeechCaptureSource,
      streamingPreviewService: nil,
      liveUpdateHandler: liveUpdateHandler,
      cleanupOwner: cleanupOwner,
      startupTimeout: .seconds(3),
      readinessSleep: { try await Task.sleep(for: $0) },
      wakeWordSpeechStartedHandler: {}
    )
  }

  private static func makeLocalSpeechCaptureRuntimeFactory(
    captureSource: any LocalSpeechAudioCaptureSource,
    streamingPreviewService: SpeechWorkerStreamingPreviewService?,
    liveUpdateHandler: @escaping @Sendable (LiveSubtitleSnapshot) async -> Void,
    cleanupOwner: ManagedTemporaryAudioCleanupOwner,
    startupTimeout: Duration,
    readinessSleep: @escaping @Sendable (Duration) async throws -> Void,
    wakeWordSpeechStartedHandler: @escaping @Sendable () -> Void
  ) -> LocalSpeechCaptureRuntimeFactory {
    { unexpectedTerminationHandler in
      LocalSpeechVoiceCaptureRuntime(
        sourceFactory: { captureSource },
        streamingPreviewSessionFactory: { request in
          await streamingPreviewService?.makeSession(for: request)
        },
        liveUpdateHandler: liveUpdateHandler,
        cleanupOwner: cleanupOwner,
        startupTimeout: startupTimeout,
        readinessSleep: readinessSleep,
        unexpectedTerminationHandler: unexpectedTerminationHandler,
        wakeWordSpeechStartedHandler: wakeWordSpeechStartedHandler
      )
    }
  }

  public nonisolated static func validateBundledVoiceActivityDetector() throws {
    guard MLXSileroVADConstants.chunkSampleCount == 512 else {
      throw CaptureError.voiceActivityDetectionUnavailable
    }
  }

  /// Kept as a source-compatible no-op. Model residency is worker-only and
  /// must never allocate or initialize a microphone frontend.
  public func prepareLocalSpeechAudioFrontendIfAuthorized() {
  }

  private func makeLocalSpeechCaptureRuntime(
    reservation: CaptureReservation
  ) -> LocalSpeechVoiceCaptureRuntime {
    localSpeechCaptureRuntimeFactory(
      { [weak self] in
        await self?.handleUnexpectedLocalSpeechTermination(reservation: reservation)
      }
    )
  }

  public func startCapture(_ request: AudioCaptureRequest) async throws {
    guard lifecycle == .accepting else {
      throw CaptureError.shuttingDown
    }
    if let endpointControl = request.endpointControl,
      endpointControl.runID != request.runID
    {
      endpointControl.finish()
      throw CaptureError.invalidEndpointControl
    }
    guard activeCapture == nil else {
      throw CaptureError.alreadyCapturing
    }
    let reservation = CaptureReservation(request: request)
    activeCapture = .preparing(reservation)

    if let recognizerID = request.workflow.plan.setup.speechRoute?.recognizerID,
      Self.localSpeechRecognizerIDs.contains(recognizerID)
    {
      try requireOwnership(of: reservation)
      let runtime = makeLocalSpeechCaptureRuntime(reservation: reservation)
      let capture = LocalSpeechCaptureState(reservation: reservation, runtime: runtime)
      activeCapture = .startingLocalSpeech(capture)
      do {
        try await runtime.startCapture(request: request)
        guard ownsStartingLocalSpeech(reservation) else {
          throw CancellationError()
        }
        activeCapture = .localSpeech(capture)
        return
      } catch is CancellationError {
        await cancelStartingReservationIfOwned(reservation)
        throw CancellationError()
      } catch {
        guard ownsStartingLocalSpeech(reservation) else {
          throw CancellationError()
        }
        clearActiveCapture(identity: reservation.identity)
        Self.revokeLifetime(for: request, reason: .serviceFailure)
        await publishFailureSnapshot(for: request, error: error)
        throw error
      }
    }

    try requireOwnership(of: reservation)
    activeCapture = .startingFallback(reservation)
    do {
      try await legacyCaptureService.startCapture(request)
      try requireOwnership(of: reservation)
      activeCapture = .fallback(reservation)
      await publishFallbackStartedSnapshot(for: request)
      try requireOwnership(of: reservation)
    } catch is CancellationError {
      // A cancellation may have reached the legacy service before its
      // asynchronous start installed resources. Sweep the same run once
      // more after start returns so a late resource cannot survive.
      await legacyCaptureService.cancelCapture(runID: request.runID)
      await cancelStartingReservationIfOwned(reservation)
      throw CancellationError()
    } catch {
      guard owns(reservation) else {
        await legacyCaptureService.cancelCapture(runID: request.runID)
        throw CancellationError()
      }
      clearActiveCapture(identity: reservation.identity)
      Self.revokeLifetime(for: request, reason: .serviceFailure)
      await publishFailureSnapshot(for: request, error: error)
      throw error
    }
  }

  private static let localSpeechRecognizerIDs: Set<String> = [
    localSpeechRecognizerID,
    "sherpa-onnx.local",
    "sherpa-onnx.streaming",
    "auto",
  ]

  public func finishCapture() async throws -> CapturedAudio {
    let deferredCapture = try await finishCaptureDeferred()
    return try await deferredCapture.value()
  }

  public func finishCaptureDeferred() async throws -> DeferredCapturedAudio {
    guard let activeCapture else {
      throw CaptureError.notCapturing
    }

    switch activeCapture {
    case .preparing(let reservation):
      clearActiveCapture(identity: reservation.identity)
      Self.cancelLifetime(for: reservation.request)
      await publishHiddenSnapshot(for: reservation.request)
      throw CaptureError.notCapturing
    case .startingLocalSpeech(let capture):
      Self.cancelLifetime(for: capture.request)
      capture.request.endpointControl?.finish()
      let teardownTask = Task {
        await capture.runtime.cancelCapture(for: capture.request)
      }
      self.activeCapture = .stoppingLocalSpeech(capture, teardownTask)
      await teardownTask.value
      clearActiveCapture(identity: capture.reservation.identity, finishEndpoint: false)
      throw CaptureError.notCapturing
    case .stoppingLocalSpeech(let capture, let teardownTask):
      await teardownTask.value
      clearActiveCapture(identity: capture.reservation.identity, finishEndpoint: false)
      throw CaptureError.notCapturing
    case .localSpeech(let capture):
      do {
        let deferredCapture = try await capture.runtime.finishCaptureDeferred(
          for: capture.request
        )
        guard ownsLocalSpeech(capture.reservation) else {
          await discardServiceOwnedCapture(deferredCapture, for: capture.request)
          throw CancellationError()
        }
        clearActiveCapture(identity: capture.reservation.identity)
        return monitoring(deferredCapture, for: capture.request)
      } catch {
        let stillOwned = ownsLocalSpeech(capture.reservation)
        if stillOwned {
          clearActiveCapture(
            identity: capture.reservation.identity,
            finishEndpoint: false
          )
          _ = capture.request.endpointControl?.send(.inputEndedUnexpectedly)
          Self.revokeLifetime(for: capture.request, reason: .serviceFailure)
          await publishFailureSnapshot(
            for: capture.request,
            error: CaptureError.microphoneStartFailed
          )
        }
        throw error
      }
    case .startingFallback(let reservation):
      clearActiveCapture(identity: reservation.identity)
      Self.cancelLifetime(for: reservation.request)
      await legacyCaptureService.cancelCapture(runID: reservation.request.runID)
      await publishHiddenSnapshot(for: reservation.request)
      throw CaptureError.notCapturing
    case .fallback(let reservation):
      let request = reservation.request
      let liveUpdateHandler = self.liveUpdateHandler
      let legacyCaptureService = self.legacyCaptureService
      let legacyDeferredCapture: DeferredCapturedAudio
      do {
        // The service contract requires input to be stopped before this
        // method returns; defer only result resolution and UI teardown.
        legacyDeferredCapture = try await legacyCaptureService.finishCaptureDeferred()
      } catch {
        clearActiveCapture(identity: reservation.identity)
        Self.revokeLifetime(for: request, reason: .serviceFailure)
        throw error
      }
      guard owns(reservation) else {
        await discardServiceOwnedCapture(legacyDeferredCapture, for: request)
        throw CancellationError()
      }
      clearActiveCapture(identity: reservation.identity)
      let deferredCapture = DeferredCapturedAudio(
        task: Task {
          let capturedAudio = try await legacyDeferredCapture.value()
          await liveUpdateHandler(
            LiveSubtitleSnapshot(
              runID: request.runID,
              workflow: request.workflow.presentation,
              phase: .hidden,
              networkUsage: request.liveSubtitleNetworkUsage,
              livePreviewPlacement: request.workflow.resolvedLivePreviewPlacement
            )
          )
          return capturedAudio
        })
      return monitoring(deferredCapture, for: request)
    }
  }

  public func cancelCapture() async {
    guard let runID = activeCapture?.request.runID else { return }
    await cancelCapture(runID: runID)
  }

  public func cancelCapture(runID: UUID) async {
    guard let activeCapture, activeCapture.request.runID == runID else { return }
    let reservation = activeCapture.reservation
    let request = reservation.request
    Self.cancelLifetime(for: request)

    switch activeCapture {
    case .preparing:
      clearActiveCapture(identity: reservation.identity)
      await publishHiddenSnapshot(for: request)
    case .startingLocalSpeech(let capture), .localSpeech(let capture):
      request.endpointControl?.finish()
      let teardownTask = Task {
        await capture.runtime.cancelCapture(for: capture.request)
      }
      self.activeCapture = .stoppingLocalSpeech(capture, teardownTask)
      await teardownTask.value
      clearActiveCapture(identity: reservation.identity, finishEndpoint: false)
    case .stoppingLocalSpeech(_, let teardownTask):
      await teardownTask.value
      clearActiveCapture(identity: reservation.identity, finishEndpoint: false)
    case .startingFallback, .fallback:
      clearActiveCapture(identity: reservation.identity)
      await legacyCaptureService.cancelCapture(runID: request.runID)
      await publishHiddenSnapshot(for: request)
    }
  }

  public func removeMaximumDurationLimit(runID: UUID) async -> Bool {
    guard let activeCapture, activeCapture.request.runID == runID else {
      return false
    }
    switch activeCapture {
    case .localSpeech(let capture):
      return await capture.runtime.removeMaximumDurationLimit(runID: runID)
    case .preparing, .startingLocalSpeech, .stoppingLocalSpeech,
      .startingFallback, .fallback:
      return false
    }
  }

  public func shutdown() async {
    switch lifecycle {
    case .accepting:
      lifecycle = .shuttingDown
    case .shuttingDown:
      await withCheckedContinuation { continuation in
        shutdownWaiters.append(continuation)
      }
      return
    case .terminated:
      return
    }

    await cancelCapture()
    localSpeechCaptureSource?.shutdown()
    await legacyCaptureService.shutdown()
    await cleanupOwner.drain()
    lifecycle = .terminated
    let waiters = shutdownWaiters
    shutdownWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  static func cleanUpFailedManagedTemporaryAudio(
    at fileURL: URL,
    runID: UUID,
    using cleanupOwner: ManagedTemporaryAudioCleanupOwner
  ) async {
    guard await cleanupOwner.transfer(fileURL: fileURL, runID: runID) else { return }
    await cleanupOwner.drain(runID: runID)
  }

  private func clearActiveCapture(identity: UUID, finishEndpoint: Bool = true) {
    guard let currentCapture = activeCapture,
      currentCapture.reservation.identity == identity
    else { return }
    let endpointControl = currentCapture.request.endpointControl
    activeCapture = nil
    if finishEndpoint {
      endpointControl?.finish()
    }
  }

  private func owns(_ reservation: CaptureReservation) -> Bool {
    activeCapture?.reservation.identity == reservation.identity
  }

  private func ownsStartingLocalSpeech(_ reservation: CaptureReservation) -> Bool {
    guard case .startingLocalSpeech(let capture) = activeCapture else { return false }
    return capture.reservation.identity == reservation.identity
  }

  private func ownsLocalSpeech(_ reservation: CaptureReservation) -> Bool {
    guard case .localSpeech(let capture) = activeCapture else { return false }
    return capture.reservation.identity == reservation.identity
  }

  private func requireOwnership(of reservation: CaptureReservation) throws {
    guard owns(reservation) else { throw CancellationError() }
  }

  private func cancelStartingReservationIfOwned(_ reservation: CaptureReservation) async {
    guard let activeCapture, activeCapture.reservation.identity == reservation.identity else {
      return
    }
    switch activeCapture {
    case .preparing, .startingLocalSpeech, .startingFallback:
      break
    case .localSpeech, .stoppingLocalSpeech, .fallback:
      return
    }
    clearActiveCapture(identity: reservation.identity)
    Self.cancelLifetime(for: reservation.request)
    await publishHiddenSnapshot(for: reservation.request)
  }

  private func handleUnexpectedLocalSpeechTermination(
    reservation: CaptureReservation
  ) async {
    guard ownsStartingLocalSpeech(reservation) || ownsLocalSpeech(reservation) else { return }
    clearActiveCapture(identity: reservation.identity, finishEndpoint: false)
    _ = reservation.request.endpointControl?.send(.inputEndedUnexpectedly)
    Self.revokeLifetime(for: reservation.request, reason: .serviceFailure)
    await publishFailureSnapshot(
      for: reservation.request,
      error: CaptureError.microphoneStartFailed
    )
  }

  private static func matchingLifetime(for request: AudioCaptureRequest) -> AudioCaptureLifetime? {
    guard let lifetime = request.audioLifetime, lifetime.runID == request.runID else { return nil }
    return lifetime
  }

  private static func cancelLifetime(for request: AudioCaptureRequest) {
    matchingLifetime(for: request)?.cancel()
  }

  private static func revokeLifetime(
    for request: AudioCaptureRequest,
    reason: AudioCaptureLifetime.RevocationReason
  ) {
    matchingLifetime(for: request)?.revoke(reason)
  }

  private func monitoring(
    _ deferredCapture: DeferredCapturedAudio,
    for request: AudioCaptureRequest
  ) -> DeferredCapturedAudio {
    DeferredCapturedAudio(
      task: Task {
        do {
          return try await deferredCapture.value()
        } catch {
          Self.revokeLifetime(for: request, reason: .serviceFailure)
          throw error
        }
      })
  }

  /// Reclaims a deferred payload whose caller lost the reservation while the
  /// provider was stopping input. Cancellation is only advisory, so a
  /// completed managed-temporary payload must also be drained explicitly.
  private func discardServiceOwnedCapture(
    _ deferredCapture: DeferredCapturedAudio,
    for request: AudioCaptureRequest
  ) async {
    deferredCapture.cancel()
    let capturedAudio = await Task.detached {
      try? await deferredCapture.value()
    }.value
    guard let capturedAudio,
      await cleanupOwner.transfer(capturedAudio, runID: request.runID)
    else {
      return
    }
    await cleanupOwner.drain(runID: request.runID)
  }

  private func publishFailureSnapshot(for request: AudioCaptureRequest, error: Error) async {
    await liveUpdateHandler(
      LiveSubtitleSnapshot(
        runID: request.runID,
        workflow: request.workflow.presentation,
        phase: .failed,
        providerID: request.workflow.plan.setup.speechRoute?.recognizerID,
        networkUsage: request.liveSubtitleNetworkUsage,
        livePreviewPlacement: request.workflow.resolvedLivePreviewPlacement
      )
    )
  }

  private func publishHiddenSnapshot(for request: AudioCaptureRequest) async {
    await liveUpdateHandler(
      LiveSubtitleSnapshot(
        runID: request.runID,
        workflow: request.workflow.presentation,
        phase: .hidden,
        networkUsage: request.liveSubtitleNetworkUsage,
        livePreviewPlacement: request.workflow.resolvedLivePreviewPlacement
      )
    )
  }

  private func publishFallbackStartedSnapshot(for request: AudioCaptureRequest) async {
    await liveUpdateHandler(
      LiveSubtitleSnapshot(
        runID: request.runID,
        workflow: request.workflow.presentation,
        phase: .recording,
        providerID: request.workflow.plan.setup.speechRoute?.recognizerID,
        networkUsage: request.liveSubtitleNetworkUsage,
        livePreviewPlacement: request.workflow.resolvedLivePreviewPlacement
      )
    )
  }

}
