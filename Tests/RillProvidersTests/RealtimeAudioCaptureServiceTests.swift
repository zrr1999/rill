import XCTest

@testable import RillCore
@testable import RillProviders

private actor LegacyAudioCaptureProbe: AudioCaptureService {
  private(set) var startRequest: AudioCaptureRequest?
  private(set) var startCallCount = 0
  private(set) var finishCallCount = 0
  private(set) var cancelCallCount = 0
  private let audio: CapturedAudio

  init(audio: CapturedAudio) {
    self.audio = audio
  }

  func startCapture(_ request: AudioCaptureRequest) async throws {
    startCallCount += 1
    startRequest = request
  }

  func finishCapture() async throws -> CapturedAudio {
    finishCallCount += 1
    return audio
  }

  func cancelCapture() async {
    cancelCallCount += 1
    startRequest = nil
  }

  func snapshot() -> AudioCaptureRequest? {
    startRequest
  }
}

private actor BlockingLateLegacyAudioCaptureProbe: AudioCaptureService {
  private(set) var startCallCount = 0
  private(set) var finishCallCount = 0
  private(set) var cancelCallCount = 0
  private var activeRequest: AudioCaptureRequest?
  private var firstStartObserved = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstStartRelease: CheckedContinuation<Void, Never>?
  private let audio: CapturedAudio

  init(audio: CapturedAudio) {
    self.audio = audio
  }

  func startCapture(_ request: AudioCaptureRequest) async throws {
    startCallCount += 1
    if startCallCount == 1 {
      firstStartObserved = true
      let waiters = startWaiters
      startWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      await withCheckedContinuation { continuation in
        firstStartRelease = continuation
      }
    }
    activeRequest = request
  }

  func finishCapture() async throws -> CapturedAudio {
    guard activeRequest != nil else {
      throw RealtimeAudioCaptureService.CaptureError.notCapturing
    }
    finishCallCount += 1
    activeRequest = nil
    return audio
  }

  func cancelCapture() async {
    cancelCallCount += 1
    activeRequest = nil
  }

  func cancelCapture(runID: UUID) async {
    cancelCallCount += 1
    if activeRequest?.runID == runID {
      activeRequest = nil
    }
  }

  func waitUntilFirstStart() async {
    if firstStartObserved { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func releaseFirstStart() {
    firstStartRelease?.resume()
    firstStartRelease = nil
  }

  func snapshot() -> AudioCaptureRequest? {
    activeRequest
  }
}

private actor BlockingDeferredLegacyAudioCaptureProbe: AudioCaptureService {
  private let audio: CapturedAudio
  private var activeRequest: AudioCaptureRequest?
  private var finishObserved = false
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []
  private var finishRelease: CheckedContinuation<Void, Never>?

  init(audio: CapturedAudio) {
    self.audio = audio
  }

  func startCapture(_ request: AudioCaptureRequest) async throws {
    activeRequest = request
  }

  func finishCapture() async throws -> CapturedAudio {
    let deferredCapture = try await finishCaptureDeferred()
    return try await deferredCapture.value()
  }

  func finishCaptureDeferred() async throws -> DeferredCapturedAudio {
    guard activeRequest != nil else {
      throw RealtimeAudioCaptureService.CaptureError.notCapturing
    }
    activeRequest = nil
    finishObserved = true
    let waiters = finishWaiters
    finishWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      finishRelease = continuation
    }
    // Intentionally return a result that has already ignored cancellation.
    // The outer service must still reclaim its managed temporary file after
    // losing reservation ownership.
    return .resolved(audio)
  }

  func cancelCapture() async {
    activeRequest = nil
  }

  func waitUntilFinishObserved() async {
    if finishObserved { return }
    await withCheckedContinuation { continuation in
      finishWaiters.append(continuation)
    }
  }

  func releaseFinish() {
    finishRelease?.resume()
    finishRelease = nil
  }
}

private actor PermissionRequestProbe {
  private(set) var callCount = 0

  func request() -> Bool {
    callCount += 1
    return true
  }
}

private actor BlockingPermissionProbe {
  private var requested = false
  private var requestWaiters: [CheckedContinuation<Void, Never>] = []
  private var resolution: CheckedContinuation<Bool, Never>?

  func request() async -> Bool {
    requested = true
    let waiters = requestWaiters
    requestWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    return await withCheckedContinuation { continuation in
      resolution = continuation
    }
  }

  func waitUntilRequested() async {
    if requested { return }
    await withCheckedContinuation { continuation in
      requestWaiters.append(continuation)
    }
  }

  func resolve(_ granted: Bool) {
    resolution?.resume(returning: granted)
    resolution = nil
  }
}

private actor DeepgramConfigurationSequence {
  private var configurations: [DeepgramRecognizer.Configuration?]

  init(_ configurations: [DeepgramRecognizer.Configuration?]) {
    self.configurations = configurations
  }

  func next() -> DeepgramRecognizer.Configuration? {
    guard !configurations.isEmpty else { return nil }
    return configurations.removeFirst()
  }
}

private actor BlockingFirstDeepgramConfigurationProbe {
  private var callCount = 0
  private var firstRequestObserved = false
  private var requestWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstResolution: CheckedContinuation<DeepgramRecognizer.Configuration?, Never>?

  func next() async -> DeepgramRecognizer.Configuration? {
    callCount += 1
    guard callCount == 1 else { return nil }

    firstRequestObserved = true
    let waiters = requestWaiters
    requestWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    return await withCheckedContinuation { continuation in
      firstResolution = continuation
    }
  }

  func waitUntilFirstRequest() async {
    if firstRequestObserved { return }
    await withCheckedContinuation { continuation in
      requestWaiters.append(continuation)
    }
  }

  func resolveFirst(with configuration: DeepgramRecognizer.Configuration?) {
    firstResolution?.resume(returning: configuration)
    firstResolution = nil
  }
}

private actor LiveSnapshotProbe {
  private var snapshots: [LiveSubtitleSnapshot] = []

  func record(_ snapshot: LiveSubtitleSnapshot) {
    snapshots.append(snapshot)
  }

  func all() -> [LiveSubtitleSnapshot] {
    snapshots
  }
}

private actor LocalSpeechTerminationSnapshotProbe {
  private var snapshots: [LiveSubtitleSnapshot] = []
  private var didObserveRevokedFailure = false
  private var revokedFailureWaiters: [CheckedContinuation<Void, Never>] = []

  func record(_ snapshot: LiveSubtitleSnapshot, lifetimeWasRevoked: Bool) {
    snapshots.append(snapshot)
    guard snapshot.phase == .failed, lifetimeWasRevoked else { return }
    didObserveRevokedFailure = true
    let waiters = revokedFailureWaiters
    revokedFailureWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  func waitUntilRevokedFailure() async {
    guard !didObserveRevokedFailure else { return }
    await withCheckedContinuation { continuation in
      revokedFailureWaiters.append(continuation)
    }
  }

  func failureCount() -> Int {
    snapshots.filter { $0.phase == .failed }.count
  }
}

private actor LocalSpeechUnexpectedTerminationGate {
  private var didEnter = false
  private var isReleased = false
  private var didForward = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
  private var forwardWaiters: [CheckedContinuation<Void, Never>] = []

  func intercept(_ handler: @Sendable () async -> Void) async {
    didEnter = true
    let entered = entryWaiters
    entryWaiters.removeAll()
    for waiter in entered {
      waiter.resume()
    }
    if !isReleased {
      await withCheckedContinuation { continuation in
        releaseWaiters.append(continuation)
      }
    }
    await handler()
    didForward = true
    let forwarded = forwardWaiters
    forwardWaiters.removeAll()
    for waiter in forwarded {
      waiter.resume()
    }
  }

  func waitUntilEntered() async {
    guard !didEnter else { return }
    await withCheckedContinuation { continuation in
      entryWaiters.append(continuation)
    }
  }

  func release() {
    isReleased = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  func waitUntilForwarded() async {
    guard !didForward else { return }
    await withCheckedContinuation { continuation in
      forwardWaiters.append(continuation)
    }
  }
}

actor ManualLocalSpeechPCMInactivitySleeper {
  private struct CallWaiter {
    let expectedCount: Int
    let continuation: CheckedContinuation<Void, Never>
  }

  private var callCount = 0
  private var sleepWaiters: [CheckedContinuation<Void, Never>] = []
  private var callWaiters: [CallWaiter] = []

  func sleep() async {
    callCount += 1
    let readyWaiters = callWaiters.filter { callCount >= $0.expectedCount }
    callWaiters.removeAll { callCount >= $0.expectedCount }
    for waiter in readyWaiters {
      waiter.continuation.resume()
    }
    await withCheckedContinuation { continuation in
      sleepWaiters.append(continuation)
    }
  }

  func waitUntilCallCount(_ expectedCount: Int) async {
    guard callCount < expectedCount else { return }
    await withCheckedContinuation { continuation in
      callWaiters.append(
        CallWaiter(expectedCount: expectedCount, continuation: continuation)
      )
    }
  }

  func releaseNext() {
    precondition(!sleepWaiters.isEmpty)
    sleepWaiters.removeFirst().resume()
  }
}

private final class ServiceTestLocalSpeechVoiceActivityDetector:
  LocalSpeechVoiceActivityDetector,
  @unchecked Sendable
{
  func accept(samples: [Float]) throws -> [LocalSpeechVoiceActivityObservation] {
    guard !samples.isEmpty else { return [] }
    return [
      LocalSpeechVoiceActivityObservation(
        isSpeech: false,
        durationSeconds: Double(samples.count) / 16_000,
        normalizedRMS: 0.001
      )
    ]
  }

  func reset() {}
}

private actor ManagedAudioRemovalRetryProbe {
  private var attempts = 0

  func remove(_ fileURL: URL) throws {
    attempts += 1
    if attempts == 1 {
      throw CocoaError(.fileWriteUnknown)
    }
    try FileManager.default.removeItem(at: fileURL)
  }

  func attemptCount() -> Int {
    attempts
  }
}

private actor BlockingLocalSpeechRemovalGate {
  private var didEnter = false
  private var isReleased = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func remove(_ fileURL: URL) async throws {
    didEnter = true
    let waiters = entryWaiters
    entryWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    if !isReleased {
      await withCheckedContinuation { continuation in
        releaseWaiters.append(continuation)
      }
    }
    try FileManager.default.removeItem(at: fileURL)
  }

  func waitUntilEntered() async {
    guard !didEnter else { return }
    await withCheckedContinuation { continuation in
      entryWaiters.append(continuation)
    }
  }

  func release() {
    isReleased = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}

final class RealtimeAudioCaptureServiceTests: XCTestCase {
  func testBundledVoiceActivityDetectorValidationUsesProviderSurface() throws {
    XCTAssertNoThrow(
      try RealtimeAudioCaptureService.validateBundledVoiceActivityDetector()
    )
  }

  func testLocalSpeechAudioFrontendPrewarmDoesNotTouchAudioWithoutAuthorization() async throws {
    let audio = try makeProbeAudio(named: "local-speech-prewarm-unauthorized")
    let source = TestLocalSpeechAudioCaptureSource()
    let service = RealtimeAudioCaptureService(
      legacyCaptureService: LegacyAudioCaptureProbe(audio: audio),
      liveUpdateHandler: { _ in },
      localSpeechCaptureSource: source,
      isMicrophoneAuthorizedForLocalSpeechPrewarm: { false }
    )

    await service.prepareLocalSpeechAudioFrontendIfAuthorized()

    XCTAssertEqual(source.prepareCount, 0)
    XCTAssertEqual(source.startCount, 0)
    XCTAssertEqual(source.stopCount, 0)
    await service.shutdown()
    XCTAssertEqual(source.shutdownCount, 1)
  }

  func testAuthorizedLocalSpeechAudioFrontendPrewarmOnlyPreparesAndFailureStaysSilent()
    async throws
  {
    let audio = try makeProbeAudio(named: "local-speech-prewarm-authorized")
    let source = TestLocalSpeechAudioCaptureSource()
    let snapshotProbe = LiveSnapshotProbe()
    let service = RealtimeAudioCaptureService(
      legacyCaptureService: LegacyAudioCaptureProbe(audio: audio),
      liveUpdateHandler: { snapshot in await snapshotProbe.record(snapshot) },
      localSpeechCaptureSource: source,
      isMicrophoneAuthorizedForLocalSpeechPrewarm: { true }
    )
    source.setPreparationError(
      AppleVoiceProcessingAudioError.automaticGainControlDidNotActivate
    )

    await service.prepareLocalSpeechAudioFrontendIfAuthorized()

    XCTAssertEqual(source.prepareCount, 1)
    XCTAssertEqual(source.startCount, 0)
    XCTAssertEqual(source.stopCount, 0)
    let snapshotsAfterFailure = await snapshotProbe.all()
    XCTAssertTrue(snapshotsAfterFailure.isEmpty)

    source.setPreparationError(nil)
    await service.prepareLocalSpeechAudioFrontendIfAuthorized()
    XCTAssertEqual(source.prepareCount, 2)
    XCTAssertEqual(source.startCount, 0)

    await service.shutdown()
    XCTAssertEqual(source.shutdownCount, 1)
    await service.prepareLocalSpeechAudioFrontendIfAuthorized()
    XCTAssertEqual(source.prepareCount, 2)
  }

  func testSequentialLocalCapturesReuseOneStoppedVoiceProcessingSource() async throws {
    let audio = try makeProbeAudio(named: "local-speech-source-reuse")
    let legacyCapture = LegacyAudioCaptureProbe(audio: audio)
    let source = TestLocalSpeechAudioCaptureSource()
    let service = RealtimeAudioCaptureService(
      legacyCaptureService: legacyCapture,
      liveUpdateHandler: { _ in },
      localSpeechCaptureSource: source
    )

    for startCount in 1...2 {
      let runID = UUID()
      let lifetime = AudioCaptureLifetime(runID: runID)
      let request = AudioCaptureRequest(
        runID: runID,
        workflow: makeWorkflow(recognizerID: "sherpa-onnx.local"),
        audioLifetime: lifetime
      )
      let startTask = Task { try await service.startCapture(request) }
      try await source.waitUntilStartCount(startCount)
      source.emit(
        samples: Array(
          repeating: 0.001,
          count: LocalSpeechInputReadinessDetector.minimumUsableFrameSampleCount
        ),
        cumulativeRMS: [0.001]
      )
      try await startTask.value
      if startCount == 1 {
        await service.prepareLocalSpeechAudioFrontendIfAuthorized()
        XCTAssertEqual(source.prepareCount, 0)
      }
      await service.cancelCapture(runID: runID)

      XCTAssertEqual(lifetime.state, .revoked(.captureCancelled))
    }

    XCTAssertEqual(source.startCount, 2)
    XCTAssertEqual(source.stopCount, 2)
    let legacyStartCount = await legacyCapture.startCallCount
    XCTAssertEqual(legacyStartCount, 0)
    await service.shutdown()
  }

  func testLocalPCMInactivityFailsAbnormallyCleansUpAndAllowsImmediateRetry() async throws {
    let audio = try makeProbeAudio(named: "local-speech-pcm-inactivity")
    let legacyCapture = LegacyAudioCaptureProbe(audio: audio)
    let source = TestLocalSpeechAudioCaptureSource()
    let sleeper = ManualLocalSpeechPCMInactivitySleeper()
    let snapshotProbe = LocalSpeechTerminationSnapshotProbe()
    let service = RealtimeAudioCaptureService(
      legacyCaptureService: legacyCapture,
      liveUpdateHandler: { snapshot in
        await snapshotProbe.record(snapshot, lifetimeWasRevoked: true)
      },
      localSpeechCaptureRuntimeFactory: { unexpectedTerminationHandler in
        LocalSpeechVoiceCaptureRuntime(
          permissionRequester: { true },
          sourceFactory: { source },
          voiceActivityDetectorFactory: { _ in
            ServiceTestLocalSpeechVoiceActivityDetector()
          },
          pcmInactivityTimeout: .seconds(2),
          pcmInactivitySleep: { _ in await sleeper.sleep() },
          unexpectedTerminationHandler: unexpectedTerminationHandler
        )
      }
    )
    let firstRunID = UUID()
    let firstLifetime = AudioCaptureLifetime(runID: firstRunID)
    let firstEndpoint = AudioCaptureEndpointControl(
      runID: firstRunID,
      policy: .shortDictation
    )
    let firstTerminalStream = try XCTUnwrap(firstEndpoint.claimStream())
    let firstTerminal = Task<AudioCaptureTerminalSignal?, Never> {
      for await signal in firstTerminalStream { return signal }
      return nil
    }
    let firstRequest = AudioCaptureRequest(
      runID: firstRunID,
      workflow: makeWorkflow(recognizerID: "sherpa-onnx.local"),
      endpointControl: firstEndpoint,
      audioLifetime: firstLifetime
    )

    let firstStart = Task { try await service.startCapture(firstRequest) }
    try await source.waitUntilStartCount(1)
    source.emit(
      samples: Array(repeating: 0.001, count: 4_800),
      cumulativeRMS: [0.001, 0.001, 0.001]
    )
    try await firstStart.value
    await sleeper.waitUntilCallCount(1)
    await sleeper.releaseNext()

    let terminal = await firstTerminal.value
    XCTAssertEqual(terminal?.reason, .inputEndedUnexpectedly)
    await snapshotProbe.waitUntilRevokedFailure()
    XCTAssertEqual(firstLifetime.state, .revoked(.serviceFailure))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: makeServiceLocalSpeechOutputURL(runID: firstRunID).path
      )
    )
    XCTAssertEqual(source.stopCount, 1)

    let secondRunID = UUID()
    let secondRequest = AudioCaptureRequest(
      runID: secondRunID,
      workflow: makeWorkflow(recognizerID: "sherpa-onnx.local"),
      audioLifetime: AudioCaptureLifetime(runID: secondRunID)
    )
    let secondStart = Task { try await service.startCapture(secondRequest) }
    try await source.waitUntilStartCount(2)
    source.emit(
      samples: Array(repeating: 0.001, count: 4_800),
      cumulativeRMS: [0.001, 0.001, 0.001]
    )
    try await secondStart.value
    await sleeper.waitUntilCallCount(2)

    let cancellation = Task { await service.cancelCapture(runID: secondRunID) }
    try await source.waitUntilStopCount(2)
    await sleeper.releaseNext()
    await cancellation.value
    XCTAssertEqual(source.stopCount, 2)
    let failureCount = await snapshotProbe.failureCount()
    XCTAssertEqual(failureCount, 1)
    await service.shutdown()
  }

  func testLocalCancelRetainsCaptureSlotUntilSharedSourceTeardownCompletes() async throws {
    let audio = try makeProbeAudio(named: "local-speech-cancel-slot")
    let legacyCapture = LegacyAudioCaptureProbe(audio: audio)
    let source = TestLocalSpeechAudioCaptureSource()
    let removalGate = BlockingLocalSpeechRemovalGate()
    let cleanupOwner = ManagedTemporaryAudioCleanupOwner(
      removal: { fileURL in try await removalGate.remove(fileURL) }
    )
    let service = RealtimeAudioCaptureService(
      legacyCaptureService: legacyCapture,
      liveUpdateHandler: { _ in },
      localSpeechCaptureRuntimeFactory: { unexpectedTerminationHandler in
        LocalSpeechVoiceCaptureRuntime(
          permissionRequester: { true },
          sourceFactory: { source },
          voiceActivityDetectorFactory: { _ in
            ServiceTestLocalSpeechVoiceActivityDetector()
          },
          cleanupOwner: cleanupOwner,
          unexpectedTerminationHandler: unexpectedTerminationHandler
        )
      }
    )
    let firstRunID = UUID()
    let firstRequest = AudioCaptureRequest(
      runID: firstRunID,
      workflow: makeWorkflow(recognizerID: "sherpa-onnx.local"),
      audioLifetime: AudioCaptureLifetime(runID: firstRunID)
    )
    let firstStart = Task { try await service.startCapture(firstRequest) }
    try await source.waitUntilStarted()
    source.emit(
      samples: Array(
        repeating: 0.001,
        count: LocalSpeechInputReadinessDetector.minimumUsableFrameSampleCount
      ),
      cumulativeRMS: [0.001]
    )
    try await firstStart.value

    let cancellation = Task { await service.cancelCapture(runID: firstRunID) }
    await removalGate.waitUntilEntered()

    let secondRunID = UUID()
    let secondRequest = AudioCaptureRequest(
      runID: secondRunID,
      workflow: makeWorkflow(recognizerID: "sherpa-onnx.local"),
      audioLifetime: AudioCaptureLifetime(runID: secondRunID)
    )
    do {
      try await service.startCapture(secondRequest)
      XCTFail("A replacement run must wait for the shared source teardown boundary.")
    } catch let error as RealtimeAudioCaptureService.CaptureError {
      XCTAssertEqual(error, .alreadyCapturing)
    }
    XCTAssertEqual(source.startCount, 1)

    await removalGate.release()
    await cancellation.value

    let secondStart = Task { try await service.startCapture(secondRequest) }
    try await source.waitUntilStartCount(2)
    source.emit(
      samples: Array(
        repeating: 0.001,
        count: LocalSpeechInputReadinessDetector.minimumUsableFrameSampleCount
      ),
      cumulativeRMS: [0.001]
    )
    try await secondStart.value
    await service.cancelCapture(runID: secondRunID)
    await service.shutdown()
  }

  func testFinishDuringLocalStartupRetainsSlotUntilCancellationTeardownCompletes() async throws {
    let audio = try makeProbeAudio(named: "local-speech-startup-finish-slot")
    let legacyCapture = LegacyAudioCaptureProbe(audio: audio)
    let source = TestLocalSpeechAudioCaptureSource()
    let removalGate = BlockingLocalSpeechRemovalGate()
    let cleanupOwner = ManagedTemporaryAudioCleanupOwner(
      removal: { fileURL in try await removalGate.remove(fileURL) }
    )
    let service = RealtimeAudioCaptureService(
      legacyCaptureService: legacyCapture,
      liveUpdateHandler: { _ in },
      localSpeechCaptureRuntimeFactory: { unexpectedTerminationHandler in
        LocalSpeechVoiceCaptureRuntime(
          permissionRequester: { true },
          sourceFactory: { source },
          voiceActivityDetectorFactory: { _ in
            ServiceTestLocalSpeechVoiceActivityDetector()
          },
          cleanupOwner: cleanupOwner,
          unexpectedTerminationHandler: unexpectedTerminationHandler
        )
      }
    )
    let firstRunID = UUID()
    let firstRequest = AudioCaptureRequest(
      runID: firstRunID,
      workflow: makeWorkflow(recognizerID: "sherpa-onnx.local"),
      audioLifetime: AudioCaptureLifetime(runID: firstRunID)
    )
    let firstStart = Task { try await service.startCapture(firstRequest) }
    try await source.waitUntilStarted()
    let finish = Task { try await service.finishCaptureDeferred() }
    await removalGate.waitUntilEntered()

    let replacementRunID = UUID()
    let replacement = AudioCaptureRequest(
      runID: replacementRunID,
      workflow: makeWorkflow(recognizerID: "sherpa-onnx.local"),
      audioLifetime: AudioCaptureLifetime(runID: replacementRunID)
    )
    do {
      try await service.startCapture(replacement)
      XCTFail("Startup cancellation must retain the capture slot through teardown.")
    } catch let error as RealtimeAudioCaptureService.CaptureError {
      XCTAssertEqual(error, .alreadyCapturing)
    }

    await removalGate.release()
    do {
      _ = try await finish.value
      XCTFail("Finishing a capture that is still starting must fail closed.")
    } catch let error as RealtimeAudioCaptureService.CaptureError {
      XCTAssertEqual(error, .notCapturing)
    }
    do {
      try await firstStart.value
      XCTFail("The cancelled startup must not become active after teardown.")
    } catch is CancellationError {
    }
    XCTAssertEqual(source.startCount, 1)
    await service.shutdown()
  }

  func testLocalSpeechUnexpectedTerminationPublishesExactlyOneFailureSnapshotAndSignal()
    async throws
  {
    let audio = try makeProbeAudio(named: "local-speech-unexpected-termination")
    let legacyCapture = LegacyAudioCaptureProbe(audio: audio)
    let source = TestLocalSpeechAudioCaptureSource()
    let snapshotProbe = LocalSpeechTerminationSnapshotProbe()
    let runID = UUID()
    let lifetime = AudioCaptureLifetime(runID: runID)
    let liveUpdateHandler: @Sendable (LiveSubtitleSnapshot) async -> Void = { snapshot in
      await snapshotProbe.record(
        snapshot,
        lifetimeWasRevoked: lifetime.state == .revoked(.serviceFailure)
      )
    }
    let service = RealtimeAudioCaptureService(
      legacyCaptureService: legacyCapture,
      liveUpdateHandler: liveUpdateHandler,
      localSpeechCaptureRuntimeFactory: { unexpectedTerminationHandler in
        LocalSpeechVoiceCaptureRuntime(
          permissionRequester: { true },
          sourceFactory: { source },
          voiceActivityDetectorFactory: { _ in
            ServiceTestLocalSpeechVoiceActivityDetector()
          },
          liveUpdateHandler: liveUpdateHandler,
          unexpectedTerminationHandler: unexpectedTerminationHandler
        )
      }
    )
    let endpointControl = AudioCaptureEndpointControl(
      runID: runID,
      policy: .shortDictation
    )
    let terminalStream = try XCTUnwrap(endpointControl.claimStream())
    let terminalSignals = Task<[AudioCaptureTerminalSignal], Never> {
      var signals: [AudioCaptureTerminalSignal] = []
      for await signal in terminalStream {
        signals.append(signal)
      }
      return signals
    }
    let request = AudioCaptureRequest(
      runID: runID,
      workflow: makeWorkflow(recognizerID: "sherpa-onnx.local"),
      endpointControl: endpointControl,
      audioLifetime: lifetime
    )

    let startTask = Task { try await service.startCapture(request) }
    try await source.waitUntilStarted()
    source.emit(
      samples: Array(repeating: 0.001, count: 4_800),
      cumulativeRMS: [0.001, 0.001, 0.001]
    )
    try await startTask.value
    source.fail(AppleVoiceProcessingAudioError.inputConfigurationChanged)

    let signals = await terminalSignals.value
    await snapshotProbe.waitUntilRevokedFailure()
    let failureCount = await snapshotProbe.failureCount()
    XCTAssertEqual(signals.map(\.reason), [.inputEndedUnexpectedly])
    XCTAssertEqual(failureCount, 1)
    XCTAssertEqual(lifetime.state, .revoked(.serviceFailure))
  }

  func testLocalSpeechFinishFailureWinsBeforeLateUnexpectedCallbackExactlyOnce() async throws {
    let audio = try makeProbeAudio(named: "local-speech-finish-failure-wins")
    let legacyCapture = LegacyAudioCaptureProbe(audio: audio)
    let source = TestLocalSpeechAudioCaptureSource()
    let snapshotProbe = LocalSpeechTerminationSnapshotProbe()
    let terminationGate = LocalSpeechUnexpectedTerminationGate()
    let runID = UUID()
    let lifetime = AudioCaptureLifetime(runID: runID)
    let liveUpdateHandler: @Sendable (LiveSubtitleSnapshot) async -> Void = { snapshot in
      await snapshotProbe.record(
        snapshot,
        lifetimeWasRevoked: lifetime.state == .revoked(.serviceFailure)
      )
    }
    let service = RealtimeAudioCaptureService(
      legacyCaptureService: legacyCapture,
      liveUpdateHandler: liveUpdateHandler,
      localSpeechCaptureRuntimeFactory: { unexpectedTerminationHandler in
        LocalSpeechVoiceCaptureRuntime(
          permissionRequester: { true },
          sourceFactory: { source },
          voiceActivityDetectorFactory: { _ in
            ServiceTestLocalSpeechVoiceActivityDetector()
          },
          liveUpdateHandler: liveUpdateHandler,
          unexpectedTerminationHandler: {
            await terminationGate.intercept(unexpectedTerminationHandler)
          }
        )
      }
    )
    let endpointControl = AudioCaptureEndpointControl(
      runID: runID,
      policy: .shortDictation
    )
    let terminalStream = try XCTUnwrap(endpointControl.claimStream())
    let terminalSignals = Task<[AudioCaptureTerminalSignal], Never> {
      var signals: [AudioCaptureTerminalSignal] = []
      for await signal in terminalStream {
        signals.append(signal)
      }
      return signals
    }
    let request = AudioCaptureRequest(
      runID: runID,
      workflow: makeWorkflow(recognizerID: "sherpa-onnx.local"),
      endpointControl: endpointControl,
      audioLifetime: lifetime
    )

    let startTask = Task { try await service.startCapture(request) }
    try await source.waitUntilStarted()
    source.emit(
      samples: Array(repeating: 0.001, count: 4_800),
      cumulativeRMS: [0.001, 0.001, 0.001]
    )
    try await startTask.value
    source.fail(AppleVoiceProcessingAudioError.inputConfigurationChanged)
    await terminationGate.waitUntilEntered()

    do {
      _ = try await service.finishCaptureDeferred()
      XCTFail("The service must surface the detached runtime's typed finish failure.")
    } catch {
      XCTAssertEqual(
        error as? RealtimeAudioCaptureService.CaptureError,
        .notCapturing
      )
    }
    let signals = await terminalSignals.value
    await snapshotProbe.waitUntilRevokedFailure()
    await terminationGate.release()
    await terminationGate.waitUntilForwarded()
    let failureCount = await snapshotProbe.failureCount()
    XCTAssertEqual(signals.map(\.reason), [.inputEndedUnexpectedly])
    XCTAssertEqual(failureCount, 1)
    XCTAssertEqual(lifetime.state, .revoked(.serviceFailure))
  }

  func testStartRejectsEndpointControlForDifferentRunBeforeCaptureSideEffects() async throws {
    let audio = try makeProbeAudio(named: "endpoint-control-mismatch")
    let legacyCapture = LegacyAudioCaptureProbe(audio: audio)
    let service = RealtimeAudioCaptureService(
      legacyCaptureService: legacyCapture,
    )
    let requestRunID = UUID()
    let endpointControl = AudioCaptureEndpointControl(
      runID: UUID(),
      policy: .shortDictation
    )
    let request = AudioCaptureRequest(
      runID: requestRunID,
      workflow: makeWorkflow(recognizerID: "fallback.file"),
      endpointControl: endpointControl
    )

    do {
      try await service.startCapture(request)
      XCTFail("A mismatched endpoint capability must fail closed.")
    } catch let error as RealtimeAudioCaptureService.CaptureError {
      XCTAssertEqual(error, .invalidEndpointControl)
    }

    let legacyStartCount = await legacyCapture.startCallCount
    XCTAssertEqual(legacyStartCount, 0)
    let stream = try XCTUnwrap(endpointControl.claimStream())
    var iterator = stream.makeAsyncIterator()
    let signal = await iterator.next()
    XCTAssertNil(signal)
  }

  func testShutdownSealsServiceBeforeSuspendedConfigurationResumes() async throws {
    let audio = try makeProbeAudio(named: "shutdown-seal")
    let legacyCapture = LegacyAudioCaptureProbe(audio: audio)
    let configurationProbe = BlockingFirstDeepgramConfigurationProbe()
    let service = RealtimeAudioCaptureService(
      legacyCaptureService: legacyCapture,
      deepgramConfigurationProvider: { await configurationProbe.next() },
    )
    let runID = UUID()
    let lifetime = AudioCaptureLifetime(runID: runID)
    let request = AudioCaptureRequest(
      runID: runID,
      workflow: makeWorkflow(recognizerID: "deepgram.prerecorded"),
      audioLifetime: lifetime
    )
    let startTask = Task {
      try await service.startCapture(request)
    }
    await configurationProbe.waitUntilFirstRequest()

    await service.shutdown()

    do {
      try await service.startCapture(request)
      XCTFail("Shutdown must permanently reject later capture starts.")
    } catch let error as RealtimeAudioCaptureService.CaptureError {
      XCTAssertEqual(error, .shuttingDown)
    } catch {
      XCTFail("Unexpected post-shutdown error: \(error)")
    }

    await configurationProbe.resolveFirst(with: nil)
    do {
      try await startTask.value
      XCTFail("A configuration lookup released after shutdown must not start capture.")
    } catch is CancellationError {
      // Expected: shutdown cleared the in-flight capture reservation.
    }

    let legacyStartCount = await legacyCapture.startCallCount
    XCTAssertEqual(legacyStartCount, 0)
    XCTAssertEqual(lifetime.state, .revoked(.captureCancelled))
  }

  func testFailedWaveCleanupTransfersPartialFileAndRetriesBeforeReturning() async throws {
    let runID = UUID()
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-realtime-write-failure-\(runID.uuidString).wav")
    try Data("partial-wave-canary".utf8).write(to: fileURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let probe = ManagedAudioRemovalRetryProbe()
    let cleanupOwner = ManagedTemporaryAudioCleanupOwner(
      removal: { url in
        try await probe.remove(url)
      },
      initialRetryDelay: .milliseconds(1),
      maximumRetryDelay: .milliseconds(1),
      sleep: { _ in }
    )

    await RealtimeAudioCaptureService.cleanUpFailedManagedTemporaryAudio(
      at: fileURL,
      runID: runID,
      using: cleanupOwner
    )

    let attemptCount = await probe.attemptCount()
    let pendingCount = await cleanupOwner.pendingCount
    XCTAssertEqual(attemptCount, 2)
    XCTAssertEqual(pendingCount, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
  }

  func testDeepgramMissingAPIKeyFailsBeforePermissionOrFallbackCapture() async throws {
    try await assertDeepgramConfigurationFailsBeforeLocalCapture(
      configuration: .init(apiKey: " \n "),
      expectedError: .missingAPIKey,
      forbiddenDiagnosticFragments: ["api.deepgram.com"]
    )
  }

  func testDeepgramInvalidBaseURLFailsBeforePermissionOrFallbackCapture() async throws {
    try await assertDeepgramConfigurationFailsBeforeLocalCapture(
      configuration: .init(
        apiKey: "configuration-secret-canary",
        baseURL: "http://configuration-url-canary.example.com"
      ),
      expectedError: .invalidBaseURL,
      forbiddenDiagnosticFragments: [
        "configuration-secret-canary",
        "configuration-url-canary.example.com",
      ]
    )
  }

  func testConfiguredDeepgramPermissionFailureNeverFallsBackToRawCapture() async throws {
    let audio = try makeProbeAudio(named: "deepgram-permission-failure")
    let legacyCapture = LegacyAudioCaptureProbe(audio: audio)
    let snapshotProbe = LiveSnapshotProbe()
    let service = RealtimeAudioCaptureService(
      legacyCaptureService: legacyCapture,
      deepgramConfigurationProvider: { .init(apiKey: "test-key") },
      deepgramMicrophonePermissionRequester: { false },
      liveUpdateHandler: { snapshot in
        await snapshotProbe.record(snapshot)
      }
    )
    let runID = UUID()
    let lifetime = AudioCaptureLifetime(runID: runID)
    let request = AudioCaptureRequest(
      runID: runID,
      workflow: makeWorkflow(recognizerID: "deepgram.prerecorded"),
      audioLifetime: lifetime
    )

    do {
      try await service.startCapture(request)
      XCTFail("A configured Deepgram live startup failure must be terminal.")
    } catch let error as RealtimeAudioCaptureService.CaptureError {
      XCTAssertEqual(error, .microphonePermissionDenied)
    }

    let legacyStartCount = await legacyCapture.startCallCount
    let snapshots = await snapshotProbe.all()
    XCTAssertEqual(legacyStartCount, 0)
    XCTAssertEqual(snapshots.last?.phase, .failed)
    XCTAssertEqual(lifetime.state, .revoked(.serviceFailure))
  }

  func testDeepgramUnexpectedTerminationRequiresReservationAndRunOwnership() {
    let reservationID = UUID()
    let runID = UUID()
    let scope = DeepgramLiveCaptureReadinessGate.Scope(runID: runID, generation: 4)

    XCTAssertTrue(
      RealtimeAudioCaptureService.acceptsDeepgramUnexpectedTermination(
        activeReservationIdentity: reservationID,
        expectedReservationIdentity: reservationID,
        expectedRunID: runID,
        scope: scope
      )
    )
    XCTAssertFalse(
      RealtimeAudioCaptureService.acceptsDeepgramUnexpectedTermination(
        activeReservationIdentity: UUID(),
        expectedReservationIdentity: reservationID,
        expectedRunID: runID,
        scope: scope
      )
    )
    XCTAssertFalse(
      RealtimeAudioCaptureService.acceptsDeepgramUnexpectedTermination(
        activeReservationIdentity: reservationID,
        expectedReservationIdentity: reservationID,
        expectedRunID: UUID(),
        scope: scope
      )
    )
  }

  func testCloudWorkflowAttemptsLiveCaptureThenFallsBack() async throws {
    let audio = try CapturedAudio(
      durationSeconds: 1.0,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
      fileURL: URL(fileURLWithPath: "/tmp/rill-cloud-capture.wav")
    )
    let legacyCapture = LegacyAudioCaptureProbe(audio: audio)
    let snapshotProbe = LiveSnapshotProbe()
    let service = RealtimeAudioCaptureService(
      legacyCaptureService: legacyCapture,
      liveUpdateHandler: { snapshot in
        await snapshotProbe.record(snapshot)
      }
    )
    let runID = UUID()
    let lifetime = AudioCaptureLifetime(runID: runID)
    let request = AudioCaptureRequest(
      runID: runID,
      workflow: makeWorkflow(recognizerID: "deepgram.prerecorded"),
      audioLifetime: lifetime
    )

    try await service.startCapture(request)
    let legacyRequest = await legacyCapture.snapshot()
    let snapshots = await snapshotProbe.all()

    XCTAssertEqual(legacyRequest?.runID, request.runID)
    XCTAssertEqual(snapshots.last?.phase, .recording)
    XCTAssertEqual(snapshots.last?.providerID, "deepgram.prerecorded")

    await service.cancelCapture()
    let updatedSnapshots = await snapshotProbe.all()
    XCTAssertEqual(updatedSnapshots.last?.phase, .hidden)
  }

  func testDeepgramMissingLifetimeFailsClosedBeforePermissionOrFallback() async throws {
    let audio = try makeProbeAudio(named: "missing-lifetime")
    let legacyCapture = LegacyAudioCaptureProbe(audio: audio)
    let permissionProbe = PermissionRequestProbe()
    let service = RealtimeAudioCaptureService(
      legacyCaptureService: legacyCapture,
      deepgramConfigurationProvider: { .init(apiKey: "test-key") },
      deepgramMicrophonePermissionRequester: { await permissionProbe.request() },
    )
    let request = AudioCaptureRequest(
      runID: UUID(),
      workflow: makeWorkflow(recognizerID: "deepgram.prerecorded")
    )

    do {
      try await service.startCapture(request)
      XCTFail("Missing live authorization must fail closed.")
    } catch let error as DeepgramLiveRuntimeError {
      XCTAssertEqual(error, .missingAudioLifetime)
    }

    let permissionCallCount = await permissionProbe.callCount
    let legacyStartCallCount = await legacyCapture.startCallCount
    XCTAssertEqual(permissionCallCount, 0)
    XCTAssertEqual(legacyStartCallCount, 0)
  }

  func testDeepgramRevokedLifetimeFailsClosedWithoutAudioSideEffects() async throws {
    let audio = try makeProbeAudio(named: "revoked-lifetime")
    let legacyCapture = LegacyAudioCaptureProbe(audio: audio)
    let permissionProbe = PermissionRequestProbe()
    let service = RealtimeAudioCaptureService(
      legacyCaptureService: legacyCapture,
      deepgramConfigurationProvider: { .init(apiKey: "test-key") },
      deepgramMicrophonePermissionRequester: { await permissionProbe.request() },
    )
    let runID = UUID()
    let lifetime = AudioCaptureLifetime(runID: runID)
    lifetime.revoke(.authorizationInvalidated)
    let request = AudioCaptureRequest(
      runID: runID,
      workflow: makeWorkflow(recognizerID: "deepgram.prerecorded"),
      audioLifetime: lifetime
    )

    do {
      try await service.startCapture(request)
      XCTFail("Revoked live authorization must fail closed.")
    } catch let error as DeepgramLiveRuntimeError {
      XCTAssertEqual(error, .audioAuthorizationRevoked)
    }

    let permissionCallCount = await permissionProbe.callCount
    let legacyStartCallCount = await legacyCapture.startCallCount
    XCTAssertEqual(permissionCallCount, 0)
    XCTAssertEqual(legacyStartCallCount, 0)
    XCTAssertEqual(lifetime.state, .revoked(.authorizationInvalidated))
  }

  func testRunScopedCancellationCannotCancelNewerFallbackCapture() async throws {
    let audio = try makeProbeAudio(named: "run-scoped-cancel")
    let legacyCapture = LegacyAudioCaptureProbe(audio: audio)
    let service = RealtimeAudioCaptureService(
      legacyCaptureService: legacyCapture,
    )
    let firstRunID = UUID()
    let firstLifetime = AudioCaptureLifetime(runID: firstRunID)
    let firstRequest = AudioCaptureRequest(
      runID: firstRunID,
      workflow: makeWorkflow(recognizerID: "deepgram.prerecorded"),
      audioLifetime: firstLifetime
    )
    try await service.startCapture(firstRequest)
    await service.cancelCapture(runID: firstRunID)

    let secondRunID = UUID()
    let secondLifetime = AudioCaptureLifetime(runID: secondRunID)
    let secondRequest = AudioCaptureRequest(
      runID: secondRunID,
      workflow: makeWorkflow(recognizerID: "deepgram.prerecorded"),
      audioLifetime: secondLifetime
    )
    try await service.startCapture(secondRequest)
    await service.cancelCapture(runID: firstRunID)

    let deferred = try await service.finishCaptureDeferred()
    let cancelCallCount = await legacyCapture.cancelCallCount
    let finishCallCount = await legacyCapture.finishCallCount
    XCTAssertEqual(cancelCallCount, 1)
    XCTAssertEqual(finishCallCount, 1, "Input must stop before deferred return.")
    XCTAssertEqual(firstLifetime.state, .revoked(.captureCancelled))
    XCTAssertEqual(
      secondLifetime.state, .active, "Runtime owns successful completion after revalidation.")
    _ = try await deferred.value()
  }

  func testCancellingStartingRunCannotLeakIntoNextRun() async throws {
    let audio = try makeProbeAudio(named: "starting-run-cancel")
    let legacyCapture = LegacyAudioCaptureProbe(audio: audio)
    let permissionProbe = BlockingPermissionProbe()
    let configurationSequence = DeepgramConfigurationSequence([
      .init(apiKey: "test-key"),
      nil,
    ])
    let service = RealtimeAudioCaptureService(
      legacyCaptureService: legacyCapture,
      deepgramConfigurationProvider: { await configurationSequence.next() },
      deepgramMicrophonePermissionRequester: { await permissionProbe.request() },
    )
    let firstRunID = UUID()
    let firstLifetime = AudioCaptureLifetime(runID: firstRunID)
    let firstRequest = AudioCaptureRequest(
      runID: firstRunID,
      workflow: makeWorkflow(recognizerID: "deepgram.prerecorded"),
      audioLifetime: firstLifetime
    )

    let startingTask = Task {
      try await service.startCapture(firstRequest)
    }
    await permissionProbe.waitUntilRequested()
    await service.cancelCapture(runID: firstRunID)
    await permissionProbe.resolve(true)

    do {
      try await startingTask.value
      XCTFail("The cancelled starting run must not become active.")
    } catch is CancellationError {
      // Expected.
    }

    let secondRunID = UUID()
    let secondLifetime = AudioCaptureLifetime(runID: secondRunID)
    try await service.startCapture(
      AudioCaptureRequest(
        runID: secondRunID,
        workflow: makeWorkflow(recognizerID: "deepgram.prerecorded"),
        audioLifetime: secondLifetime
      )
    )
    await service.cancelCapture(runID: firstRunID)

    let deferred = try await service.finishCaptureDeferred()
    XCTAssertEqual(firstLifetime.state, .revoked(.captureCancelled))
    XCTAssertEqual(secondLifetime.state, .active)
    _ = try await deferred.value()
  }

  func testConfigurationReservationRejectsConcurrentStartAndCannotOverwriteNewerRun() async throws {
    let audio = try makeProbeAudio(named: "configuration-reservation")
    let legacyCapture = LegacyAudioCaptureProbe(audio: audio)
    let configurationProbe = BlockingFirstDeepgramConfigurationProbe()
    let service = RealtimeAudioCaptureService(
      legacyCaptureService: legacyCapture,
      deepgramConfigurationProvider: { await configurationProbe.next() },
    )
    let firstRunID = UUID()
    let firstLifetime = AudioCaptureLifetime(runID: firstRunID)
    let firstRequest = AudioCaptureRequest(
      runID: firstRunID,
      workflow: makeWorkflow(recognizerID: "deepgram.prerecorded"),
      audioLifetime: firstLifetime
    )
    let firstStart = Task {
      try await service.startCapture(firstRequest)
    }
    await configurationProbe.waitUntilFirstRequest()

    let rejectedRunID = UUID()
    do {
      try await service.startCapture(
        AudioCaptureRequest(
          runID: rejectedRunID,
          workflow: makeWorkflow(recognizerID: "deepgram.prerecorded"),
          audioLifetime: AudioCaptureLifetime(runID: rejectedRunID)
        )
      )
      XCTFail("A preparing reservation must reject a concurrent start.")
    } catch let error as RealtimeAudioCaptureService.CaptureError {
      XCTAssertEqual(error, .alreadyCapturing)
    }

    await service.cancelCapture(runID: firstRunID)

    // Reuse the run ID deliberately: ownership is the reservation identity,
    // not caller-provided metadata that can be repeated by a stale task.
    let secondRunID = firstRunID
    let secondLifetime = AudioCaptureLifetime(runID: secondRunID)
    try await service.startCapture(
      AudioCaptureRequest(
        runID: secondRunID,
        workflow: makeWorkflow(recognizerID: "deepgram.prerecorded"),
        audioLifetime: secondLifetime
      )
    )
    await configurationProbe.resolveFirst(with: .init(apiKey: "late-test-key"))

    do {
      try await firstStart.value
      XCTFail("The cancelled configuration lookup must not reclaim capture ownership.")
    } catch is CancellationError {
      // Expected.
    }

    let activeLegacyRequest = await legacyCapture.snapshot()
    let legacyStartCount = await legacyCapture.startCallCount
    XCTAssertEqual(activeLegacyRequest?.runID, secondRunID)
    XCTAssertTrue(activeLegacyRequest?.audioLifetime === secondLifetime)
    XCTAssertEqual(legacyStartCount, 1)
    XCTAssertEqual(firstLifetime.state, .revoked(.captureCancelled))
    XCTAssertEqual(secondLifetime.state, .active)

    let deferred = try await service.finishCaptureDeferred()
    _ = try await deferred.value()
  }

  func testCancelledStartingFallbackSweepsResourceInstalledAfterCancellation() async throws {
    let audio = try makeProbeAudio(named: "late-fallback-start")
    let legacyCapture = BlockingLateLegacyAudioCaptureProbe(audio: audio)
    let service = RealtimeAudioCaptureService(
      legacyCaptureService: legacyCapture,
    )
    let firstRunID = UUID()
    let firstLifetime = AudioCaptureLifetime(runID: firstRunID)
    let firstStart = Task {
      try await service.startCapture(
        AudioCaptureRequest(
          runID: firstRunID,
          workflow: makeWorkflow(recognizerID: "deepgram.prerecorded"),
          audioLifetime: firstLifetime
        )
      )
    }
    await legacyCapture.waitUntilFirstStart()

    // The first cancellation runs before the legacy implementation installs
    // its resource, so only the post-start sweep can remove the late capture.
    await service.cancelCapture(runID: firstRunID)
    let captureBeforeLateInstall = await legacyCapture.snapshot()
    let initialCancelCallCount = await legacyCapture.cancelCallCount
    XCTAssertNil(captureBeforeLateInstall)
    XCTAssertEqual(initialCancelCallCount, 1)
    await legacyCapture.releaseFirstStart()

    do {
      try await firstStart.value
      XCTFail("A cancelled late fallback start must not report success.")
    } catch is CancellationError {
      // Expected.
    }

    let captureAfterLateSweep = await legacyCapture.snapshot()
    let finalCancelCallCount = await legacyCapture.cancelCallCount
    XCTAssertNil(captureAfterLateSweep)
    XCTAssertEqual(finalCancelCallCount, 2)
    XCTAssertEqual(firstLifetime.state, .revoked(.captureCancelled))

    let secondRunID = UUID()
    let secondLifetime = AudioCaptureLifetime(runID: secondRunID)
    try await service.startCapture(
      AudioCaptureRequest(
        runID: secondRunID,
        workflow: makeWorkflow(recognizerID: "deepgram.prerecorded"),
        audioLifetime: secondLifetime
      )
    )

    let secondRequest = await legacyCapture.snapshot()
    XCTAssertEqual(secondRequest?.runID, secondRunID)
    XCTAssertTrue(secondRequest?.audioLifetime === secondLifetime)
    let deferred = try await service.finishCaptureDeferred()
    _ = try await deferred.value()
    let finishCallCount = await legacyCapture.finishCallCount
    XCTAssertEqual(finishCallCount, 1)
  }

  func testCancellationDuringDeferredFinishReclaimsCompletedManagedTemporaryAudio() async throws {
    let runID = UUID()
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-deferred-ownership-race-\(runID.uuidString).wav")
    try Data("managed-audio-race-canary".utf8).write(to: outputURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: outputURL) }
    let audio = try CapturedAudio(
      durationSeconds: 1,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
      fileURL: outputURL,
      fileOwnership: .managedTemporary
    )
    let legacyCapture = BlockingDeferredLegacyAudioCaptureProbe(audio: audio)
    let cleanupOwner = ManagedTemporaryAudioCleanupOwner(
      initialRetryDelay: .milliseconds(1),
      maximumRetryDelay: .milliseconds(1),
      sleep: { _ in }
    )
    let service = RealtimeAudioCaptureService(
      legacyCaptureService: legacyCapture,
      cleanupOwner: cleanupOwner
    )
    let lifetime = AudioCaptureLifetime(runID: runID)
    try await service.startCapture(
      AudioCaptureRequest(
        runID: runID,
        workflow: makeWorkflow(recognizerID: "deepgram.prerecorded"),
        audioLifetime: lifetime
      )
    )

    let finishTask = Task {
      try await service.finishCaptureDeferred()
    }
    await legacyCapture.waitUntilFinishObserved()
    await service.cancelCapture(runID: runID)
    await legacyCapture.releaseFinish()

    do {
      _ = try await finishTask.value
      XCTFail("A finish that lost reservation ownership must be cancelled.")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Unexpected deferred ownership error: \(error)")
    }

    await cleanupOwner.drain(runID: runID)
    let pendingCleanupCount = await cleanupOwner.pendingCount
    XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    XCTAssertEqual(pendingCleanupCount, 0)
    XCTAssertEqual(lifetime.state, .revoked(.captureCancelled))
  }

  private func assertDeepgramConfigurationFailsBeforeLocalCapture(
    configuration: DeepgramRecognizer.Configuration,
    expectedError: DeepgramRecognizer.RecognizerError,
    forbiddenDiagnosticFragments: [String]
  ) async throws {
    let audio = try CapturedAudio(
      durationSeconds: 1.0,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
      fileURL: URL(fileURLWithPath: "/tmp/rill-deepgram-config-rejection.wav")
    )
    let legacyCapture = LegacyAudioCaptureProbe(audio: audio)
    let permissionProbe = PermissionRequestProbe()
    let snapshotProbe = LiveSnapshotProbe()
    let service = RealtimeAudioCaptureService(
      legacyCaptureService: legacyCapture,
      deepgramConfigurationProvider: { configuration },
      deepgramMicrophonePermissionRequester: {
        await permissionProbe.request()
      },
      liveUpdateHandler: { snapshot in
        await snapshotProbe.record(snapshot)
      }
    )
    let runID = UUID()
    let lifetime = AudioCaptureLifetime(runID: runID)
    let request = AudioCaptureRequest(
      runID: runID,
      workflow: makeWorkflow(recognizerID: "deepgram.prerecorded"),
      audioLifetime: lifetime
    )
    let expectedOutputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-deepgram-live-\(request.runID.uuidString)")
      .appendingPathExtension("wav")
    try? FileManager.default.removeItem(at: expectedOutputURL)

    do {
      try await service.startCapture(request)
      XCTFail("Expected Deepgram configuration validation to fail")
    } catch let error as DeepgramRecognizer.RecognizerError {
      XCTAssertEqual(error, expectedError)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let permissionRequestCount = await permissionProbe.callCount
    let legacyStartCount = await legacyCapture.startCallCount
    let snapshots = await snapshotProbe.all()
    let statusText = snapshots.last?.statusText ?? ""
    XCTAssertEqual(permissionRequestCount, 0)
    XCTAssertEqual(legacyStartCount, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: expectedOutputURL.path))
    XCTAssertEqual(snapshots.last?.phase, .failed)
    XCTAssertEqual(snapshots.last?.providerID, "deepgram.prerecorded")
    XCTAssertTrue(statusText.isEmpty)
    XCTAssertEqual(lifetime.state, .revoked(.serviceFailure))
    for fragment in forbiddenDiagnosticFragments {
      XCTAssertFalse(statusText.contains(fragment))
    }
  }
}

private func makeProbeAudio(named name: String) throws -> CapturedAudio {
  try CapturedAudio(
    durationSeconds: 1,
    format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
    fileURL: URL(fileURLWithPath: "/tmp/rill-\(name).wav")
  )
}

private func makeWorkflow(recognizerID: String) -> WorkflowDefinition {
  WorkflowDefinition(
    name: "Capture Workflow",
    trigger: .hotkey,
    pipeline: PipelineDeclaration(
      recognizerID: recognizerID,
      outputActions: []
    ),
    ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "teal")
  )
}

private func makeServiceLocalSpeechOutputURL(runID: UUID) -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("rill-local-\(runID.uuidString)")
    .appendingPathExtension("wav")
}
