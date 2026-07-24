import Foundation
import XCTest

@testable import RillApp
@testable import RillCore
@testable import RillRuntime

private actor WorkflowAudioEventProbe {
  private var events: [RillEvent] = []

  func append(_ event: RillEvent) {
    events.append(event)
  }

  func snapshot() -> [RillEvent] {
    events
  }
}

actor BlockingControllerDiagnosticRepository: DiagnosticRepository {
  private let blockedEvent: String
  private var storedEvents: [DiagnosticEvent] = []
  private var hasEnteredBlockedSave = false
  private var isReleased = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  init(blockedEvent: String) {
    self.blockedEvent = blockedEvent
  }

  func save(_ event: DiagnosticEvent) async throws {
    try await save(event, generation: .initial)
  }

  func save(
    _ event: DiagnosticEvent,
    generation: RunHistoryWriteGeneration
  ) async throws {
    _ = generation
    if event.event == blockedEvent {
      hasEnteredBlockedSave = true
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
    }
    storedEvents.append(event)
  }

  func events(matching query: DiagnosticQuery) async throws -> [DiagnosticEvent] {
    _ = query
    return storedEvents
  }

  func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration {
    .initial
  }

  func waitUntilBlockedSaveEntered() async {
    guard !hasEnteredBlockedSave else { return }
    await withCheckedContinuation { continuation in
      entryWaiters.append(continuation)
    }
  }

  func releaseBlockedSave() {
    isReleased = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  func savedEventNames() -> [String] {
    storedEvents.map(\.event)
  }
}

private actor ThrowingAudioCaptureService: AudioCaptureService {
  enum TestError: Error {
    case finishFailed
  }

  private(set) var startRequest: AudioCaptureRequest?
  private(set) var cancelCallCount = 0
  private(set) var finishCallCount = 0
  private var finishShouldThrow = false
  private var shouldRevokeLifetimeBeforeStartReturns = false
  private var finishContinuation: CheckedContinuation<Void, Never>?
  private var finishDidSuspend = false
  private var finishSuspensionWaiters: [CheckedContinuation<Void, Never>] = []
  private var cancelShouldSuspend = false
  private var cancelContinuations: [CheckedContinuation<Void, Never>] = []
  private var cancelDidSuspend = false
  private var cancelSuspensionWaiters: [CheckedContinuation<Void, Never>] = []
  private var cancelCountWaiters:
    [(
      target: Int,
      continuation: CheckedContinuation<Void, Never>
    )] = []

  func setFinishShouldThrow(_ shouldThrow: Bool) {
    finishShouldThrow = shouldThrow
  }

  func setShouldRevokeLifetimeBeforeStartReturns(_ shouldRevoke: Bool) {
    shouldRevokeLifetimeBeforeStartReturns = shouldRevoke
  }

  func setCancelShouldSuspend(_ shouldSuspend: Bool) {
    cancelShouldSuspend = shouldSuspend
  }

  func startCapture(_ request: AudioCaptureRequest) async throws {
    startRequest = request
    if shouldRevokeLifetimeBeforeStartReturns {
      request.audioLifetime?.revoke(.authorizationInvalidated)
    }
  }

  func finishCapture() async throws -> CapturedAudio {
    let audio = try CapturedAudio(
      durationSeconds: 1.0,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
      fileURL: URL(fileURLWithPath: "/dev/null")
    )
    return audio
  }

  func finishCaptureDeferred() async throws -> DeferredCapturedAudio {
    finishCallCount += 1
    // Wait for the test to control timing
    await withCheckedContinuation { continuation in
      finishContinuation = continuation
      finishDidSuspend = true
      let waiters = finishSuspensionWaiters
      finishSuspensionWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }

    if finishShouldThrow {
      throw TestError.finishFailed
    }

    startRequest = nil
    let audio = try CapturedAudio(
      durationSeconds: 1.0,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
      fileURL: URL(fileURLWithPath: "/dev/null")
    )
    return .resolved(audio)
  }

  func cancelCapture() async {
    await recordCancel()
  }

  func cancelCapture(runID: UUID) async {
    guard startRequest?.runID == runID else { return }
    await recordCancel()
  }

  private func recordCancel() async {
    cancelCallCount += 1
    startRequest = nil
    resumeSatisfiedCancelCountWaiters()
    guard cancelShouldSuspend else { return }
    cancelDidSuspend = true
    let waiters = cancelSuspensionWaiters
    cancelSuspensionWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { continuation in
      cancelContinuations.append(continuation)
    }
  }

  func allowFinishToComplete() {
    finishContinuation?.resume()
    finishContinuation = nil
  }

  func waitUntilFinishSuspends() async {
    guard !finishDidSuspend else { return }
    await withCheckedContinuation { continuation in
      finishSuspensionWaiters.append(continuation)
    }
  }

  func waitUntilCancelSuspends() async {
    guard !cancelDidSuspend else { return }
    await withCheckedContinuation { continuation in
      cancelSuspensionWaiters.append(continuation)
    }
  }

  func allowCancelToComplete() {
    cancelShouldSuspend = false
    let continuations = cancelContinuations
    cancelContinuations.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
  }

  func waitUntilCancelCount(reaches target: Int) async {
    guard cancelCallCount < target else { return }
    await withCheckedContinuation { continuation in
      cancelCountWaiters.append((target, continuation))
    }
  }

  func snapshot() -> (request: AudioCaptureRequest?, cancelCount: Int, finishCount: Int) {
    (startRequest, cancelCallCount, finishCallCount)
  }

  private func resumeSatisfiedCancelCountWaiters() {
    let waiters = cancelCountWaiters
    cancelCountWaiters.removeAll()
    for waiter in waiters {
      if cancelCallCount >= waiter.target {
        waiter.continuation.resume()
      } else {
        cancelCountWaiters.append(waiter)
      }
    }
  }
}

private actor WorkflowLiveContextStore {
  private var context: ContextSnapshot

  init(_ context: ContextSnapshot) {
    self.context = context
  }

  func read() -> ContextSnapshot { context }
  func replace(_ context: ContextSnapshot) { self.context = context }
}

private actor TransferredWorkflowCaptureService: AudioCaptureService {
  private let capturedAudio: CapturedAudio
  private var activeRunID: UUID?
  private var didTransfer = false
  private var transferWaiters: [CheckedContinuation<Void, Never>] = []

  init(capturedAudio: CapturedAudio) {
    self.capturedAudio = capturedAudio
  }

  func startCapture(_ request: AudioCaptureRequest) async throws {
    activeRunID = request.runID
  }

  func finishCapture() async throws -> CapturedAudio {
    activeRunID = nil
    return capturedAudio
  }

  func finishCaptureDeferred() async throws -> DeferredCapturedAudio {
    activeRunID = nil
    didTransfer = true
    let waiters = transferWaiters
    transferWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    return .resolved(capturedAudio)
  }

  func cancelCapture() async {
    activeRunID = nil
  }

  func cancelCapture(runID: UUID) async {
    guard activeRunID == runID else { return }
    activeRunID = nil
  }

  func waitUntilTransferred() async {
    guard !didTransfer else { return }
    await withCheckedContinuation { continuation in
      transferWaiters.append(continuation)
    }
  }
}

private actor WorkflowSealGate {
  private let context: ContextSnapshot
  private var isArmed = false
  private var didEnter = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  init(context: ContextSnapshot) {
    self.context = context
  }

  func arm() {
    isArmed = true
  }

  func read() async -> ContextSnapshot {
    guard isArmed else { return context }
    isArmed = false
    didEnter = true
    let waiters = entryWaiters
    entryWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { continuation in
      releaseWaiters.append(continuation)
    }
    return context
  }

  func waitUntilEntered() async {
    guard !didEnter else { return }
    await withCheckedContinuation { continuation in
      entryWaiters.append(continuation)
    }
  }

  func release() {
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
}

private actor WorkflowShutdownCompletionProbe {
  private var completed = false

  func markCompleted() {
    completed = true
  }

  func isCompleted() -> Bool {
    completed
  }
}

private actor WorkflowRecognitionOptionsProbe {
  private var contexts: [ContextSnapshot] = []

  func resolve(
    context: ContextSnapshot,
    options: SpeechRecognitionRequestOptions
  ) -> SpeechRecognitionRequestOptions {
    contexts.append(context)
    return options
  }

  func callCount() -> Int {
    contexts.count
  }
}

private actor WorkflowQueueTransferGate {
  private var entered = false
  private var released = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func suspendAfterTransfer() async {
    entered = true
    let waiters = entryWaiters
    entryWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    guard !released else { return }
    await withCheckedContinuation { continuation in
      releaseWaiters.append(continuation)
    }
  }

  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { continuation in
      entryWaiters.append(continuation)
    }
  }

  func release() {
    released = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
}

private enum WorkflowPreflightTestError: Error, LocalizedError, Equatable {
  case unavailable

  var errorDescription: String? { "Recognition service is unavailable." }
}

private actor WorkflowRunOrderingProbe {
  private var preflightCount = 0
  private var contextCount = 0
  private var confirmationCount = 0
  private var optionsCount = 0

  func rejectPreflight() throws {
    preflightCount += 1
    throw WorkflowPreflightTestError.unavailable
  }

  func readContext() -> ContextSnapshot {
    contextCount += 1
    return .empty
  }

  func confirmCloudRun() -> Bool {
    confirmationCount += 1
    return true
  }

  func resolveOptions() -> SpeechRecognitionRequestOptions {
    optionsCount += 1
    return .empty
  }

  func snapshot() -> (preflight: Int, context: Int, confirmation: Int, options: Int) {
    (preflightCount, contextCount, confirmationCount, optionsCount)
  }
}

final class WorkflowAudioRunControllerTests: XCTestCase {
  func testPreparingPreviewUsesOwnedRunBeforePreflightCompletes() async throws {
    let audioCaptureService = ThrowingAudioCaptureService()
    let eventBus = EventBus()
    var deliveryIterator = eventBus.lifecycleDeliveryStream.makeAsyncIterator()
    let coordinator = SessionCoordinator(
      contextProvider: TestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      deliveryStack: DeliveryStack(eventBus: eventBus),
      eventBus: eventBus
    )
    let queue = CapturedAudioProcessingQueue(
      sessionCoordinator: coordinator,
      eventBus: eventBus
    )
    let preflightGate = WorkflowSealGate(context: .empty)
    await preflightGate.arm()
    let controller = WorkflowAudioRunController(
      audioCaptureService: audioCaptureService,
      capturedAudioProcessingQueue: queue,
      eventBus: eventBus,
      runPreflight: { _ in _ = await preflightGate.read() },
      privacyRunGate: makeWorkflowAudioTestPrivacyGate()
    )
    let workflow = WorkflowDefinition(
      name: "Immediate recording preview",
      trigger: .manual,
      pipeline: PipelineDeclaration(
        recognizerID: "sherpa-onnx.local",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
    )

    let startTask = Task {
      try await controller.startRun(workflow: workflow, binding: .manual)
    }
    await preflightGate.waitUntilEntered()

    let delivery = await deliveryIterator.next()
    guard case .event(.liveSubtitleUpdated(let preview)) = delivery else {
      XCTFail("Preparing must be the first workflow-audio presentation event.")
      await preflightGate.release()
      _ = try? await startTask.value
      await controller.shutdown()
      await queue.shutdown()
      return
    }
    XCTAssertEqual(preview.phase, .preparing)
    XCTAssertEqual(preview.workflow, workflow.presentation)
    XCTAssertEqual(preview.providerID, workflow.pipeline.recognizerID)
    let captureBeforePreflight = await audioCaptureService.snapshot()
    XCTAssertNil(captureBeforePreflight.request)

    await preflightGate.release()
    try await startTask.value
    let startedCapture = await audioCaptureService.snapshot()
    let runID = try XCTUnwrap(startedCapture.request?.runID)
    XCTAssertEqual(preview.runID, runID)

    await controller.cancelRun(runID: runID)
    await controller.shutdown()
    await queue.shutdown()
  }

  func testStopDuringFailingPreflightCannotResurrectFailedPreview() async throws {
    let audioCaptureService = ThrowingAudioCaptureService()
    let eventBus = EventBus()
    var deliveryIterator = eventBus.lifecycleDeliveryStream.makeAsyncIterator()
    let coordinator = SessionCoordinator(
      contextProvider: TestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      deliveryStack: DeliveryStack(eventBus: eventBus),
      eventBus: eventBus
    )
    let queue = CapturedAudioProcessingQueue(
      sessionCoordinator: coordinator,
      eventBus: eventBus
    )
    let preflightGate = WorkflowSealGate(context: .empty)
    await preflightGate.arm()
    let controller = WorkflowAudioRunController(
      audioCaptureService: audioCaptureService,
      capturedAudioProcessingQueue: queue,
      eventBus: eventBus,
      runPreflight: { _ in
        _ = await preflightGate.read()
        throw WorkflowPreflightTestError.unavailable
      },
      privacyRunGate: makeWorkflowAudioTestPrivacyGate()
    )
    let workflow = WorkflowDefinition(
      name: "Stopped failing preview",
      trigger: .manual,
      pipeline: PipelineDeclaration(
        recognizerID: "sherpa-onnx.local",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
    )

    let startTask = Task {
      try await controller.startRun(workflow: workflow, binding: .manual)
    }
    await preflightGate.waitUntilEntered()
    guard case .event(.liveSubtitleUpdated(let preparing)) = await deliveryIterator.next()
    else {
      XCTFail("The run must publish preparing before preflight completes.")
      await preflightGate.release()
      _ = try? await startTask.value
      await controller.shutdown()
      await queue.shutdown()
      return
    }

    await controller.cancelRun(runID: preparing.runID)
    await preflightGate.release()
    do {
      try await startTask.value
      XCTFail("The released preflight must preserve its original failure.")
    } catch let error as WorkflowPreflightTestError {
      XCTAssertEqual(error, .unavailable)
    }

    guard case .event(.liveSubtitleUpdated(let terminal)) = await deliveryIterator.next()
    else {
      XCTFail("The stopped run must publish a terminal preview update.")
      await controller.shutdown()
      await queue.shutdown()
      return
    }
    XCTAssertEqual(terminal.runID, preparing.runID)
    XCTAssertEqual(terminal.phase, .hidden)

    await controller.shutdown()
    await queue.shutdown()
  }

  func testSpeechEndpointKeepsCaptureSlotUntilFinishBoundaryThenAllowsRestartDuringSeal()
    async throws
  {
    let audioCaptureService = ThrowingAudioCaptureService()
    let eventBus = EventBus()
    let coordinator = SessionCoordinator(
      contextProvider: TestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      deliveryStack: DeliveryStack(eventBus: eventBus),
      eventBus: eventBus
    )
    let queue = CapturedAudioProcessingQueue(
      sessionCoordinator: coordinator,
      eventBus: eventBus
    )
    let sealGate = WorkflowSealGate(context: makeWorkflowLiveContext())
    let controller = WorkflowAudioRunController(
      audioCaptureService: audioCaptureService,
      capturedAudioProcessingQueue: queue,
      eventBus: eventBus,
      privacyContextProvider: { await sealGate.read() },
      authorizedContextProvider: { _ in await sealGate.read() },
      recognizerDurationProvider: { recognizerID in
        recognizerID == "sherpa-onnx.local" ? 20 : nil
      },
      privacyRunGate: makeWorkflowAudioTestPrivacyGate()
    )
    let workflow = WorkflowDefinition(
      name: "Automatically ending recording",
      trigger: .manual,
      pipeline: PipelineDeclaration(
        recognizerID: "sherpa-onnx.local",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
    )

    try await controller.startRun(workflow: workflow, binding: .manual)
    let started = await audioCaptureService.snapshot()
    let request = try XCTUnwrap(started.request)
    let endpointControl = try XCTUnwrap(request.endpointControl)
    XCTAssertEqual(endpointControl.runID, request.runID)
    XCTAssertEqual(request.maxDurationSeconds, 20)

    await sealGate.arm()
    XCTAssertTrue(endpointControl.send(.speechEnded))
    XCTAssertFalse(endpointControl.send(.maximumDurationReached))
    await audioCaptureService.waitUntilFinishSuspends()

    do {
      try await controller.startRun(workflow: workflow, binding: .manual)
      XCTFail("A replacement run must wait for the capture finish boundary.")
    } catch let error as WorkflowAudioRunController.RunError {
      XCTAssertEqual(error, .alreadyRecording)
    }

    let manualStop = Task {
      try await controller.finishRun()
    }
    await audioCaptureService.allowFinishToComplete()
    await sealGate.waitUntilEntered()

    try await controller.startRun(workflow: workflow, binding: .manual)
    let restarted = await audioCaptureService.snapshot()
    XCTAssertNotEqual(restarted.request?.runID, request.runID)

    await sealGate.release()
    try await manualStop.value

    let finished = await audioCaptureService.snapshot()
    XCTAssertEqual(finished.finishCount, 1)
    await controller.cancelRun(runID: restarted.request?.runID)
    await controller.shutdown()
    await queue.shutdown()
  }

  func testStopDuringPreparingDoesNotJoinOlderPostBoundaryFinish() async throws {
    let audioCaptureService = ThrowingAudioCaptureService()
    let eventBus = EventBus()
    let coordinator = SessionCoordinator(
      contextProvider: TestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      deliveryStack: DeliveryStack(eventBus: eventBus),
      eventBus: eventBus
    )
    let queue = CapturedAudioProcessingQueue(
      sessionCoordinator: coordinator,
      eventBus: eventBus
    )
    let sealGate = WorkflowSealGate(context: makeWorkflowLiveContext())
    let preflightGate = WorkflowSealGate(context: .empty)
    let controller = WorkflowAudioRunController(
      audioCaptureService: audioCaptureService,
      capturedAudioProcessingQueue: queue,
      privacyContextProvider: { await sealGate.read() },
      authorizedContextProvider: { _ in await sealGate.read() },
      runPreflight: { _ in _ = await preflightGate.read() },
      privacyRunGate: makeWorkflowAudioTestPrivacyGate()
    )
    let workflow = WorkflowDefinition(
      name: "Run-scoped stop",
      trigger: .manual,
      pipeline: PipelineDeclaration(
        recognizerID: "sherpa-onnx.local",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
    )

    try await controller.startRun(workflow: workflow, binding: .manual)
    await sealGate.arm()
    let oldFinish = Task {
      try await controller.finishRun()
    }
    await audioCaptureService.waitUntilFinishSuspends()
    await audioCaptureService.allowFinishToComplete()
    await sealGate.waitUntilEntered()

    await preflightGate.arm()
    let newStart = Task {
      try await controller.startRun(workflow: workflow, binding: .manual)
    }
    await preflightGate.waitUntilEntered()

    do {
      try await controller.finishRun()
      XCTFail("Stopping a preparing run must not join an older finishing run.")
    } catch let error as WorkflowAudioRunController.RunError {
      XCTAssertEqual(error, .notRecording)
    }

    await preflightGate.release()
    try await newStart.value
    let restartedRunID = await audioCaptureService.snapshot().request?.runID
    await sealGate.release()
    try await oldFinish.value
    await controller.cancelRun(runID: restartedRunID)
    await controller.shutdown()
    await queue.shutdown()
  }

  func testInitialSilenceEndpointCancelsWithoutFinishingBlankAudio() async throws {
    let audioCaptureService = ThrowingAudioCaptureService()
    await audioCaptureService.setCancelShouldSuspend(true)
    let diagnostics = DiagnosticsRecorder()
    let eventBus = EventBus()
    let eventStream = await eventBus.stream()
    let eventProbe = WorkflowAudioEventProbe()
    let eventTask = Task {
      for await event in eventStream {
        await eventProbe.append(event)
      }
    }
    defer { eventTask.cancel() }
    let coordinator = SessionCoordinator(
      contextProvider: TestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      deliveryStack: DeliveryStack(eventBus: eventBus),
      eventBus: eventBus
    )
    let queue = CapturedAudioProcessingQueue(
      sessionCoordinator: coordinator,
      eventBus: eventBus
    )
    let controller = WorkflowAudioRunController(
      audioCaptureService: audioCaptureService,
      capturedAudioProcessingQueue: queue,
      diagnostics: diagnostics,
      eventBus: eventBus,
      privacyRunGate: makeWorkflowAudioTestPrivacyGate()
    )
    let workflow = WorkflowDefinition(
      name: "Silent recording",
      trigger: .manual,
      pipeline: PipelineDeclaration(
        recognizerID: "sherpa-onnx.local",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
    )

    try await controller.startRun(workflow: workflow, binding: .manual)
    let started = await audioCaptureService.snapshot()
    let request = try XCTUnwrap(started.request)
    let endpointControl = try XCTUnwrap(request.endpointControl)

    XCTAssertTrue(endpointControl.observeEnergy(relativeLevel: 0.1, durationSeconds: 0.1))
    XCTAssertTrue(endpointControl.observeEnergy(relativeLevel: 0.42, durationSeconds: 0.2))
    XCTAssertTrue(endpointControl.observeEnergy(relativeLevel: 0.5, durationSeconds: 0.15))
    XCTAssertTrue(endpointControl.observeEnergy(relativeLevel: 0.2, durationSeconds: 0.05))
    XCTAssertTrue(endpointControl.observeEnergy(relativeLevel: 0.4, durationSeconds: 0.25))
    XCTAssertTrue(endpointControl.send(.initialSilenceTimedOut))
    await audioCaptureService.waitUntilCancelSuspends()
    XCTAssertFalse(endpointControl.send(.speechEnded))
    do {
      try await controller.startRun(workflow: workflow, binding: .manual)
      XCTFail("A replacement run must wait for the capture cancel boundary.")
    } catch let error as WorkflowAudioRunController.RunError {
      XCTAssertEqual(error, .alreadyRecording)
    }

    await audioCaptureService.allowCancelToComplete()
    var restartedRunID: UUID?
    for _ in 0..<100 where restartedRunID == nil {
      do {
        try await controller.startRun(workflow: workflow, binding: .manual)
        restartedRunID = await audioCaptureService.snapshot().request?.runID
      } catch let error as WorkflowAudioRunController.RunError
        where error == .alreadyRecording
      {
        await Task.yield()
      }
    }
    XCTAssertNotNil(restartedRunID)

    let cancelled = await audioCaptureService.snapshot()
    XCTAssertEqual(cancelled.cancelCount, 1)
    XCTAssertEqual(cancelled.finishCount, 0)
    XCTAssertEqual(request.audioLifetime?.state, .revoked(.captureCancelled))

    var matchingFailure: String?
    for _ in 0..<100 where matchingFailure == nil {
      for event in await eventProbe.snapshot() {
        if case .runFailed(let runID, _, let message) = event,
          runID == request.runID
        {
          matchingFailure = message
          break
        }
      }
      if matchingFailure == nil {
        await Task.yield()
      }
    }
    XCTAssertEqual(matchingFailure, HistoryFailureSanitizer.noSpeechMessage)

    await controller.cancelRun(runID: restartedRunID)
    await controller.shutdown()
    let recordedDiagnostics = await diagnostics.snapshot()
    let terminalDiagnostic = try XCTUnwrap(
      recordedDiagnostics.first {
        $0.runID == request.runID
          && $0.event == "workflow.audio-recording.terminal-signal"
      }
    )
    XCTAssertEqual(
      terminalDiagnostic.metadata,
      [
        "reason": "initialSilenceTimedOut",
        "acousticObservedSegmentCount": "5",
        "acousticObservedDurationMilliseconds": "750",
        "acousticAboveThresholdDurationMilliseconds": "600",
        "acousticPeakLevelPercentBucket": "50",
        "acousticMaximumConsecutiveAboveThresholdDurationMilliseconds": "350",
      ]
    )
    await queue.shutdown()
  }

  func testBlockedStartedDiagnosticDoesNotDelayReadyReturnAndShutdownDrainsIt() async throws {
    let repository = BlockingControllerDiagnosticRepository(
      blockedEvent: "workflow.audio-recording.started"
    )
    let diagnostics = DiagnosticsRecorder(repository: repository)
    let audioCaptureService = ThrowingAudioCaptureService()
    let eventBus = EventBus()
    let coordinator = SessionCoordinator(
      contextProvider: TestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      deliveryStack: DeliveryStack(eventBus: eventBus),
      eventBus: eventBus
    )
    let queue = CapturedAudioProcessingQueue(
      sessionCoordinator: coordinator,
      eventBus: eventBus
    )
    let controller = WorkflowAudioRunController(
      audioCaptureService: audioCaptureService,
      capturedAudioProcessingQueue: queue,
      diagnostics: diagnostics,
      privacyRunGate: makeWorkflowAudioTestPrivacyGate()
    )
    let workflow = WorkflowDefinition(
      name: "Diagnostic-independent recording",
      trigger: .manual,
      pipeline: PipelineDeclaration(
        recognizerID: "sherpa-onnx.local",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
    )
    let startCompletion = WorkflowShutdownCompletionProbe()
    let startTask = Task {
      try await controller.startRun(workflow: workflow, binding: .manual)
      await startCompletion.markCompleted()
    }

    await repository.waitUntilBlockedSaveEntered()
    for _ in 0..<100 {
      if await startCompletion.isCompleted() { break }
      await Task.yield()
    }

    let didReturnWhileDiagnosticWasBlocked = await startCompletion.isCompleted()
    let captureWhileDiagnosticWasBlocked = await audioCaptureService.snapshot()
    XCTAssertTrue(
      didReturnWhileDiagnosticWasBlocked,
      "Durable diagnostic persistence must not keep the manual recording UI in preparing."
    )
    XCTAssertNotNil(captureWhileDiagnosticWasBlocked.request)

    let shutdownCompletion = WorkflowShutdownCompletionProbe()
    let shutdownTask = Task {
      await controller.shutdown()
      await shutdownCompletion.markCompleted()
    }
    await audioCaptureService.waitUntilCancelCount(reaches: 1)
    for _ in 0..<100 {
      await Task.yield()
    }
    let didShutdownBeforeDiagnosticWasReleased = await shutdownCompletion.isCompleted()
    XCTAssertFalse(
      didShutdownBeforeDiagnosticWasReleased,
      "Shutdown must drain a started diagnostic write after sealing the queue."
    )

    await repository.releaseBlockedSave()
    try await startTask.value
    await shutdownTask.value
    let savedEvents = await repository.savedEventNames()
    XCTAssertEqual(savedEvents, ["workflow.audio-recording.started"])
    await queue.shutdown()
  }

  func testRevokedLifetimeAtCaptureReadinessNeverPublishesRecording() async throws {
    let diagnostics = DiagnosticsRecorder()
    let audioCaptureService = ThrowingAudioCaptureService()
    await audioCaptureService.setShouldRevokeLifetimeBeforeStartReturns(true)
    let eventBus = EventBus()
    let coordinator = SessionCoordinator(
      contextProvider: TestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      deliveryStack: DeliveryStack(eventBus: eventBus),
      eventBus: eventBus
    )
    let queue = CapturedAudioProcessingQueue(
      sessionCoordinator: coordinator,
      eventBus: eventBus
    )
    let controller = WorkflowAudioRunController(
      audioCaptureService: audioCaptureService,
      capturedAudioProcessingQueue: queue,
      diagnostics: diagnostics,
      privacyRunGate: makeWorkflowAudioTestPrivacyGate()
    )
    let workflow = WorkflowDefinition(
      name: "Revoked-at-readiness recording",
      trigger: .manual,
      pipeline: PipelineDeclaration(
        recognizerID: "sherpa-onnx.local",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
    )

    do {
      try await controller.startRun(workflow: workflow, binding: .manual)
      XCTFail("A capture whose live authorization was revoked before readiness must not start.")
    } catch is CancellationError {
      // Expected.
    }

    let capture = await audioCaptureService.snapshot()
    let recordedDiagnostics = await diagnostics.snapshot()
    XCTAssertNil(capture.request)
    XCTAssertEqual(capture.cancelCount, 1)
    XCTAssertFalse(
      recordedDiagnostics.contains {
        $0.event == "workflow.audio-recording.started"
      })

    await controller.shutdown()
    await queue.shutdown()
  }

  func testLiveCloudRunStopsWhenFocusBecomesSensitive() async throws {
    let audioCaptureService = ThrowingAudioCaptureService()
    let eventBus = EventBus()
    let coordinator = SessionCoordinator(
      contextProvider: TestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      deliveryStack: DeliveryStack(eventBus: eventBus),
      eventBus: eventBus
    )
    let contexts = WorkflowLiveContextStore(makeWorkflowLiveContext())
    let controller = WorkflowAudioRunController(
      audioCaptureService: audioCaptureService,
      capturedAudioProcessingQueue: CapturedAudioProcessingQueue(
        sessionCoordinator: coordinator,
        eventBus: eventBus
      ),
      eventBus: eventBus,
      privacyContextProvider: { await contexts.read() },
      authorizedContextProvider: { _ in await contexts.read() },
      liveAuthorizationMonitorInterval: .milliseconds(5),
      privacyRunGate: PrivacyRunGate(
        settingsProvider: { .defaults },
        cloudConfirmationProvider: { _, _, _ in true }
      )
    )
    let workflow = WorkflowDefinition(
      name: "Live Cloud Workflow",
      trigger: .manual,
      pipeline: PipelineDeclaration(
        recognizerID: "deepgram.prerecorded",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
    )

    try await controller.startRun(workflow: workflow, binding: .manual)
    let startedRequest = await audioCaptureService.snapshot().request
    XCTAssertNotNil(startedRequest?.audioLifetime)
    let endpointControl = try XCTUnwrap(startedRequest?.endpointControl)

    await contexts.replace(
      makeWorkflowLiveContext(bundleIdentifier: "com.1password.1password")
    )
    await waitUntil {
      await audioCaptureService.snapshot().cancelCount == 1
    }

    let capture = await audioCaptureService.snapshot()
    XCTAssertNil(capture.request)
    XCTAssertEqual(
      startedRequest?.audioLifetime?.state,
      .revoked(.authorizationInvalidated)
    )
    XCTAssertFalse(
      endpointControl.send(.speechEnded),
      "Authorization revocation must retire the endpoint subscription."
    )
    do {
      try await controller.finishRun()
      XCTFail("A privacy-revoked run must no longer be finishable.")
    } catch let error as WorkflowAudioRunController.RunError {
      XCTAssertEqual(error, .notRecording)
    }
  }

  func testStaleLiveRevocationCannotCancelNewerWorkflowRun() async throws {
    let audioCaptureService = ThrowingAudioCaptureService()
    let eventBus = EventBus()
    let coordinator = SessionCoordinator(
      contextProvider: TestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      deliveryStack: DeliveryStack(eventBus: eventBus),
      eventBus: eventBus
    )
    let contexts = WorkflowLiveContextStore(makeWorkflowLiveContext())
    let controller = WorkflowAudioRunController(
      audioCaptureService: audioCaptureService,
      capturedAudioProcessingQueue: CapturedAudioProcessingQueue(
        sessionCoordinator: coordinator,
        eventBus: eventBus
      ),
      eventBus: eventBus,
      privacyContextProvider: { await contexts.read() },
      authorizedContextProvider: { _ in await contexts.read() },
      liveAuthorizationMonitorInterval: .seconds(30),
      privacyRunGate: PrivacyRunGate(
        settingsProvider: { .defaults },
        cloudConfirmationProvider: { _, _, _ in true }
      )
    )
    let workflow = WorkflowDefinition(
      name: "Run-scoped Cloud Workflow",
      trigger: .manual,
      pipeline: PipelineDeclaration(
        recognizerID: "deepgram.prerecorded",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
    )

    try await controller.startRun(workflow: workflow, binding: .manual)
    let firstSnapshot = await audioCaptureService.snapshot()
    let firstRunID = try XCTUnwrap(firstSnapshot.request?.runID)
    await controller.cancelRun(runID: firstRunID)

    try await controller.startRun(workflow: workflow, binding: .manual)
    let secondSnapshot = await audioCaptureService.snapshot()
    let secondRunID = try XCTUnwrap(secondSnapshot.request?.runID)
    XCTAssertNotEqual(firstRunID, secondRunID)

    await controller.handleLiveAuthorizationRevocation(
      runID: firstRunID,
      reason: .policyBlocked
    )

    let snapshot = await audioCaptureService.snapshot()
    XCTAssertEqual(snapshot.request?.runID, secondRunID)
    XCTAssertEqual(snapshot.cancelCount, 1)
    await controller.cancelRun(runID: secondRunID)
  }

  func testCancelDuringFinishPreventsOldRunFromEnteringQueue() async throws {
    let audioCaptureService = ThrowingAudioCaptureService()
    let eventBus = EventBus()
    let coordinator = SessionCoordinator(
      contextProvider: TestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      deliveryStack: DeliveryStack(eventBus: eventBus),
      eventBus: eventBus
    )
    let queue = CapturedAudioProcessingQueue(
      sessionCoordinator: coordinator,
      eventBus: eventBus
    )
    let contexts = WorkflowLiveContextStore(makeWorkflowLiveContext())
    let controller = WorkflowAudioRunController(
      audioCaptureService: audioCaptureService,
      capturedAudioProcessingQueue: queue,
      eventBus: eventBus,
      privacyContextProvider: { await contexts.read() },
      authorizedContextProvider: { _ in await contexts.read() },
      privacyRunGate: PrivacyRunGate(
        settingsProvider: { .defaults },
        cloudConfirmationProvider: { _, _, _ in true }
      )
    )
    let workflow = WorkflowDefinition(
      name: "Finishing Cloud Workflow",
      trigger: .manual,
      pipeline: PipelineDeclaration(
        recognizerID: "deepgram.prerecorded",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
    )

    try await controller.startRun(workflow: workflow, binding: .manual)
    let started = await audioCaptureService.snapshot()
    let runID = try XCTUnwrap(started.request?.runID)
    let lifetime = try XCTUnwrap(started.request?.audioLifetime)
    let finishTask = Task {
      try await controller.finishRun()
    }
    await audioCaptureService.waitUntilFinishSuspends()

    let cancellationTask = Task {
      await controller.cancelRun(runID: runID)
    }
    await waitUntil {
      await audioCaptureService.snapshot().cancelCount == 1
    }
    await audioCaptureService.allowFinishToComplete()
    await cancellationTask.value
    try await finishTask.value

    let pendingCount = await queue.pendingCount
    XCTAssertEqual(pendingCount, 0)
    XCTAssertEqual(lifetime.state, .revoked(.captureCancelled))
  }

  func testCancelAfterQueueTransferDoesNotLetOldFinishClearNewRun() async throws {
    let audioCaptureService = ThrowingAudioCaptureService()
    let eventBus = EventBus()
    let coordinator = SessionCoordinator(
      contextProvider: TestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      deliveryStack: DeliveryStack(eventBus: eventBus),
      eventBus: eventBus
    )
    let transferGate = WorkflowQueueTransferGate()
    let queue = CapturedAudioProcessingQueue(
      sessionCoordinator: coordinator,
      eventBus: eventBus,
      rejectedCapturedAudioRemoval: { capturedAudio in
        _ = try capturedAudio.removeManagedTemporaryFile()
      },
      rejectedCleanupInitialRetryDelay: .milliseconds(1),
      rejectedCleanupMaximumRetryDelay: .milliseconds(4),
      rejectedCleanupSleep: { delay in
        try await Task.sleep(for: delay)
      },
      ownershipTransferObserver: { _ in
        await transferGate.suspendAfterTransfer()
      }
    )
    let controller = WorkflowAudioRunController(
      audioCaptureService: audioCaptureService,
      capturedAudioProcessingQueue: queue,
      privacyRunGate: makeWorkflowAudioTestPrivacyGate()
    )
    let firstWorkflow = WorkflowDefinition(
      name: "Transferred Run",
      trigger: .manual,
      pipeline: PipelineDeclaration(recognizerID: "test", outputActions: []),
      ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
    )
    let secondWorkflow = WorkflowDefinition(
      name: "New Run",
      trigger: .manual,
      pipeline: PipelineDeclaration(recognizerID: "test", outputActions: []),
      ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "red")
    )

    try await controller.startRun(workflow: firstWorkflow, binding: .manual)
    let firstCapture = await audioCaptureService.snapshot()
    let firstRunID = try XCTUnwrap(firstCapture.request?.runID)
    let finishTask = Task {
      try await controller.finishRun()
    }
    await audioCaptureService.waitUntilFinishSuspends()
    await audioCaptureService.allowFinishToComplete()
    await transferGate.waitUntilEntered()

    let cancellationTask = Task {
      await controller.cancelRun(runID: firstRunID)
    }
    try await controller.startRun(workflow: secondWorkflow, binding: .manual)
    let secondCapture = await audioCaptureService.snapshot()
    let secondRunID = try XCTUnwrap(secondCapture.request?.runID)
    XCTAssertNotEqual(firstRunID, secondRunID)

    await transferGate.release()
    await cancellationTask.value
    try await finishTask.value

    let finalCapture = await audioCaptureService.snapshot()
    XCTAssertEqual(finalCapture.request?.runID, secondRunID)
    XCTAssertEqual(
      finalCapture.cancelCount,
      0,
      "A post-boundary cancellation must not touch the replacement capture."
    )
    await controller.cancelRun(runID: secondRunID)
    await queue.shutdown()
  }

  func testApplicationShutdownWaitsForTransferredCaptureCleanup() async throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-workflow-shutdown-" + UUID().uuidString + ".wav")
    try Data([0x00]).write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let capturedAudio = try CapturedAudio(
      durationSeconds: 1,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
      fileURL: fileURL,
      fileOwnership: .managedTemporary
    )
    let captureService = TransferredWorkflowCaptureService(capturedAudio: capturedAudio)
    let eventBus = EventBus()
    let coordinator = SessionCoordinator(
      contextProvider: TestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      deliveryStack: DeliveryStack(eventBus: eventBus),
      eventBus: eventBus
    )
    let queue = CapturedAudioProcessingQueue(
      sessionCoordinator: coordinator,
      eventBus: eventBus
    )
    let sealGate = WorkflowSealGate(context: makeWorkflowLiveContext())
    let controller = WorkflowAudioRunController(
      audioCaptureService: captureService,
      capturedAudioProcessingQueue: queue,
      privacyContextProvider: { await sealGate.read() },
      authorizedContextProvider: { _ in await sealGate.read() },
      liveAuthorizationMonitorInterval: .seconds(60),
      privacyRunGate: PrivacyRunGate(
        settingsProvider: { .defaults },
        cloudConfirmationProvider: { _, _, _ in true }
      )
    )
    let workflow = WorkflowDefinition(
      name: "Shutdown Cleanup Workflow",
      trigger: .manual,
      pipeline: PipelineDeclaration(
        recognizerID: "deepgram.prerecorded",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
    )

    try await controller.startRun(workflow: workflow, binding: .manual)
    await sealGate.arm()
    let finishTask = Task {
      try await controller.finishRun()
    }
    await captureService.waitUntilTransferred()
    await sealGate.waitUntilEntered()

    let completion = WorkflowShutdownCompletionProbe()
    let shutdown = ApplicationShutdownOperation.make(
      cancelRecording: {},
      cancelWorkflowRun: { await controller.cancelRun() },
      cancelFailedAudioRecoveryRetries: {},
      stopLocalHistoryMaintenance: {},
      shutdownAudioQueue: { await queue.shutdown() },
      cancelDeepgramTest: {},
      stopStackPaste: {},
      stopClipboardGroupScheduler: {},
      stopLocalSpeechPreparation: {},
      stopEventListener: {},
      flushPersistence: {}
    )
    let shutdownTask = Task {
      await shutdown()
      await completion.markCompleted()
    }
    await Task.yield()

    let didCompleteBeforeRelease = await completion.isCompleted()
    XCTAssertFalse(didCompleteBeforeRelease)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    await sealGate.release()
    await shutdownTask.value
    try await finishTask.value

    let didCompleteAfterRelease = await completion.isCompleted()
    XCTAssertTrue(didCompleteAfterRelease)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
  }

  func testShutdownSealsControllerBeforeSuspendedPreflightResumes() async throws {
    let audioCaptureService = ThrowingAudioCaptureService()
    let eventBus = EventBus()
    let coordinator = SessionCoordinator(
      contextProvider: TestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      deliveryStack: DeliveryStack(eventBus: eventBus),
      eventBus: eventBus
    )
    let queue = CapturedAudioProcessingQueue(
      sessionCoordinator: coordinator,
      eventBus: eventBus
    )
    let preflightGate = WorkflowSealGate(context: .empty)
    await preflightGate.arm()
    let controller = WorkflowAudioRunController(
      audioCaptureService: audioCaptureService,
      capturedAudioProcessingQueue: queue,
      runPreflight: { _ in
        _ = await preflightGate.read()
      },
      privacyRunGate: PrivacyRunGate(
        settingsProvider: { .defaults },
        cloudConfirmationProvider: { _, _, _ in true }
      )
    )
    let workflow = WorkflowDefinition(
      name: "Suspended Preflight Workflow",
      trigger: .manual,
      pipeline: PipelineDeclaration(
        recognizerID: "sherpa-onnx.local",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
    )
    let startTask = Task {
      try await controller.startRun(workflow: workflow, binding: .manual)
    }
    await preflightGate.waitUntilEntered()

    await controller.shutdown()

    do {
      try await controller.startRun(workflow: workflow, binding: .manual)
      XCTFail("Shutdown must permanently reject later workflow starts.")
    } catch let error as WorkflowAudioRunController.RunError {
      XCTAssertEqual(error, .shuttingDown)
    } catch {
      XCTFail("Unexpected post-shutdown error: \(error)")
    }

    await preflightGate.release()
    do {
      try await startTask.value
      XCTFail("A preflight released after shutdown must not start capture.")
    } catch is CancellationError {
      // Expected: shutdown invalidated the preparing run before release.
    }

    let capture = await audioCaptureService.snapshot()
    XCTAssertNil(capture.request)
    await queue.shutdown()
  }

  func testMissingPrivacyGateFailsClosedBeforeContextOptionsOrCapture() async {
    let audioCaptureService = ThrowingAudioCaptureService()
    let eventBus = EventBus()
    let coordinator = SessionCoordinator(
      contextProvider: TestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      deliveryStack: DeliveryStack(eventBus: eventBus),
      eventBus: eventBus
    )
    let optionsProbe = WorkflowRecognitionOptionsProbe()
    let controller = WorkflowAudioRunController(
      audioCaptureService: audioCaptureService,
      capturedAudioProcessingQueue: CapturedAudioProcessingQueue(
        sessionCoordinator: coordinator,
        eventBus: eventBus
      ),
      contextProvider: {
        XCTFail("A missing privacy gate must not read full context.")
        return .empty
      },
      recognitionOptionsProvider: { _, context in
        await optionsProbe.resolve(context: context, options: .empty)
      }
    )
    let workflow = WorkflowDefinition(
      name: "Local Workflow",
      trigger: .manual,
      pipeline: PipelineDeclaration(
        recognizerID: "sherpa-onnx.local",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
    )

    do {
      try await controller.startRun(workflow: workflow, binding: .manual)
      XCTFail("A missing privacy gate must block the run.")
    } catch let error as SessionCoordinator.SessionError {
      guard case .privacyAuthorizationRequired = error else {
        return XCTFail("Unexpected session error: \(error)")
      }
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let capture = await audioCaptureService.snapshot()
    let optionsCount = await optionsProbe.callCount()
    XCTAssertNil(capture.request)
    XCTAssertEqual(optionsCount, 0)
  }

  func testFinishRunRaceCondition_DoesNotCancelNewCapture() async throws {
    // A failed finish must cross a run-scoped cancel boundary before the
    // capture slot can be reused by a replacement run.

    let audioCaptureService = ThrowingAudioCaptureService()
    let eventBus = EventBus()
    let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
    let deliveryStack = DeliveryStack(eventBus: eventBus, diagnostics: diagnostics)
    let resolver = CandidateResolver(eventBus: eventBus, diagnostics: diagnostics)
    let coordinator = SessionCoordinator(
      contextProvider: TestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: resolver,
      deliveryStack: deliveryStack,
      eventBus: eventBus,
      diagnostics: diagnostics
    )

    // Need to wrap the mock queue in a real CapturedAudioProcessingQueue
    // Actually, we can't access the real queue easily, so let's just use it directly
    let realProcessingQueue = CapturedAudioProcessingQueue(
      sessionCoordinator: coordinator,
      eventBus: eventBus,
      diagnostics: diagnostics
    )

    let controller = WorkflowAudioRunController(
      audioCaptureService: audioCaptureService,
      capturedAudioProcessingQueue: realProcessingQueue,
      diagnostics: diagnostics,
      privacyRunGate: makeWorkflowAudioTestPrivacyGate()
    )

    let workflow1 = WorkflowDefinition(
      name: "First Workflow",
      trigger: .hotkey,
      pipeline: PipelineDeclaration(
        recognizerID: "test",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
    )

    let workflow2 = WorkflowDefinition(
      name: "Second Workflow",
      trigger: .hotkey,
      pipeline: PipelineDeclaration(
        recognizerID: "test",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "red")
    )

    // Start the first run
    try await controller.startRun(workflow: workflow1, binding: TriggerBinding.hotkey)
    let snapshot1 = await audioCaptureService.snapshot()
    XCTAssertNotNil(snapshot1.request)
    XCTAssertEqual(snapshot1.request?.workflow.name, "First Workflow")

    // Configure finishCaptureDeferred to throw
    await audioCaptureService.setFinishShouldThrow(true)

    // Start finishRun in the background - it will suspend at finishCaptureDeferred
    let finishTask = Task {
      do {
        try await controller.finishRun()
        XCTFail("Expected finishRun to throw")
      } catch {
        // Expected - finishCaptureDeferred will throw
      }
    }

    // The controller must retain capture-slot ownership while the old
    // capture's deferred finalization is suspended.
    await audioCaptureService.waitUntilFinishSuspends()

    do {
      try await controller.startRun(workflow: workflow2, binding: TriggerBinding.hotkey)
      XCTFail("A replacement run must wait for the failed finish's cancel boundary.")
    } catch let error as WorkflowAudioRunController.RunError {
      XCTAssertEqual(error, .alreadyRecording)
    }

    // Let finalization throw; the controller then cancels the old run before
    // publishing the capture slot as idle.
    await audioCaptureService.allowFinishToComplete()
    await finishTask.value

    try await controller.startRun(workflow: workflow2, binding: TriggerBinding.hotkey)
    let snapshot2 = await audioCaptureService.snapshot()

    XCTAssertEqual(snapshot2.cancelCount, 1)
    XCTAssertNotNil(snapshot2.request, "The second run should remain active")
    XCTAssertEqual(snapshot2.request?.workflow.name, "Second Workflow")
    await controller.cancelRun(runID: snapshot2.request?.runID)
    await realProcessingQueue.shutdown()
  }

  func testManualCloudRunIsBlockedBeforeAudioCaptureWhenConfirmationIsDeclined() async {
    let audioCaptureService = ThrowingAudioCaptureService()
    let eventBus = EventBus()
    let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
    let deliveryStack = DeliveryStack(eventBus: eventBus, diagnostics: diagnostics)
    let coordinator = SessionCoordinator(
      contextProvider: TestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: CandidateResolver(eventBus: eventBus, diagnostics: diagnostics),
      deliveryStack: deliveryStack,
      eventBus: eventBus,
      diagnostics: diagnostics
    )
    let queue = CapturedAudioProcessingQueue(
      sessionCoordinator: coordinator,
      eventBus: eventBus,
      diagnostics: diagnostics
    )
    let gate = PrivacyRunGate(
      settingsProvider: {
        PrivacyPolicySettings(sensitiveAppRules: [], cloudConfirmationRequired: true)
      },
      cloudConfirmationProvider: { _, _, _ in false }
    )
    let optionsProbe = WorkflowRecognitionOptionsProbe()
    let privacyContext = ContextSnapshot(
      focus: FocusSnapshot(
        applicationName: "Test App",
        bundleIdentifier: "com.example.TestApp",
        processIdentifier: 1,
        focusedRole: nil,
        selectedText: "",
        secureInput: false
      ),
      clipboard: ClipboardSnapshot(plainText: "", changeCount: 1)
    )
    let controller = WorkflowAudioRunController(
      audioCaptureService: audioCaptureService,
      capturedAudioProcessingQueue: queue,
      diagnostics: diagnostics,
      contextProvider: { privacyContext },
      privacyContextProvider: { privacyContext },
      authorizedContextProvider: { decision in privacyContext.applying(decision) },
      recognitionOptionsProvider: { _, context in
        await optionsProbe.resolve(
          context: context,
          options: SpeechRecognitionRequestOptions(
            hints: RecognitionHints(keyterms: ["must-not-be-resolved"])
          )
        )
      },
      privacyRunGate: gate
    )
    let workflow = WorkflowDefinition(
      name: "Cloud Workflow",
      trigger: .manual,
      pipeline: PipelineDeclaration(recognizerID: "deepgram.prerecorded", outputActions: []),
      ui: WorkflowUIConfig(symbolName: "cloud", accentColorName: "blue")
    )

    do {
      try await controller.startRun(workflow: workflow, binding: .manual)
      XCTFail("Expected cloud confirmation to block capture.")
    } catch let error as PrivacyRunGate.GateError {
      XCTAssertEqual(error, .cloudConfirmationDeclined)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let captureSnapshot = await audioCaptureService.snapshot()
    XCTAssertNil(captureSnapshot.request)
    let optionsCallCount = await optionsProbe.callCount()
    XCTAssertEqual(optionsCallCount, 0)
  }

  func testManualPreflightFailurePrecedesPrivacyContextOptionsAndCaptureAndReturnsIdle() async {
    let audioCaptureService = ThrowingAudioCaptureService()
    let eventBus = EventBus()
    let coordinator = SessionCoordinator(
      contextProvider: TestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      deliveryStack: DeliveryStack(eventBus: eventBus),
      eventBus: eventBus
    )
    let ordering = WorkflowRunOrderingProbe()
    let gate = PrivacyRunGate(
      settingsProvider: { .defaults },
      cloudConfirmationProvider: { _, _, _ in
        await ordering.confirmCloudRun()
      }
    )
    let controller = WorkflowAudioRunController(
      audioCaptureService: audioCaptureService,
      capturedAudioProcessingQueue: CapturedAudioProcessingQueue(
        sessionCoordinator: coordinator,
        eventBus: eventBus
      ),
      contextProvider: { await ordering.readContext() },
      privacyContextProvider: { await ordering.readContext() },
      authorizedContextProvider: { _ in await ordering.readContext() },
      recognitionOptionsProvider: { _, _ in await ordering.resolveOptions() },
      runPreflight: { _ in try await ordering.rejectPreflight() },
      privacyRunGate: gate
    )
    let workflow = WorkflowDefinition(
      name: "Unavailable Cloud Workflow",
      trigger: .manual,
      pipeline: PipelineDeclaration(recognizerID: "deepgram.prerecorded", outputActions: []),
      ui: WorkflowUIConfig(symbolName: "cloud", accentColorName: "blue")
    )

    for _ in 0..<2 {
      do {
        try await controller.startRun(workflow: workflow, binding: .manual)
        XCTFail("Expected preflight to fail.")
      } catch let error as WorkflowPreflightTestError {
        XCTAssertEqual(error, .unavailable)
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }

    let counts = await ordering.snapshot()
    let capture = await audioCaptureService.snapshot()
    XCTAssertEqual(counts.preflight, 2)
    XCTAssertEqual(counts.context, 0)
    XCTAssertEqual(counts.confirmation, 0)
    XCTAssertEqual(counts.options, 0)
    XCTAssertNil(capture.request)
    XCTAssertEqual(capture.cancelCount, 0)
  }

  func testLegacyClipboardWorkflowIsRejectedBeforePreflightPrivacyContextOptionsOrCapture() async {
    let audioCaptureService = ThrowingAudioCaptureService()
    let eventBus = EventBus()
    let coordinator = SessionCoordinator(
      contextProvider: TestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      deliveryStack: DeliveryStack(eventBus: eventBus),
      eventBus: eventBus
    )
    let ordering = WorkflowRunOrderingProbe()
    let gate = PrivacyRunGate(
      settingsProvider: {
        _ = await ordering.readContext()
        return .defaults
      },
      cloudConfirmationProvider: { _, _, _ in
        await ordering.confirmCloudRun()
      }
    )
    let controller = WorkflowAudioRunController(
      audioCaptureService: audioCaptureService,
      capturedAudioProcessingQueue: CapturedAudioProcessingQueue(
        sessionCoordinator: coordinator,
        eventBus: eventBus
      ),
      contextProvider: { await ordering.readContext() },
      privacyContextProvider: { await ordering.readContext() },
      authorizedContextProvider: { _ in await ordering.readContext() },
      recognitionOptionsProvider: { _, _ in await ordering.resolveOptions() },
      runPreflight: { _ in try await ordering.rejectPreflight() },
      privacyRunGate: gate
    )
    let workflow = WorkflowDefinition(
      name: "Legacy Clipboard Automation",
      trigger: .manual,
      pipeline: PipelineDeclaration(
        recognizerID: "deepgram.prerecorded",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "bolt", accentColorName: "orange"),
      metadata: ["eventType": "groupItemCreated"]
    )

    do {
      try await controller.startRun(workflow: workflow, binding: .manual)
      XCTFail("Expected legacy clipboard automation to be rejected.")
    } catch let error as SessionCoordinator.SessionError {
      guard case .unsupportedWorkflow(.legacyClipboardAutomationUnsupported) = error else {
        return XCTFail("Unexpected session error: \(error)")
      }
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let counts = await ordering.snapshot()
    let capture = await audioCaptureService.snapshot()
    XCTAssertEqual(counts.preflight, 0)
    XCTAssertEqual(counts.context, 0)
    XCTAssertEqual(counts.confirmation, 0)
    XCTAssertEqual(counts.options, 0)
    XCTAssertNil(capture.request)
    XCTAssertEqual(capture.cancelCount, 0)
  }

  func testManualRunSnapshotsRecognitionOptionsBeforeCaptureStarts() async throws {
    let audioCaptureService = ThrowingAudioCaptureService()
    let eventBus = EventBus()
    let coordinator = SessionCoordinator(
      contextProvider: TestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      deliveryStack: DeliveryStack(eventBus: eventBus),
      eventBus: eventBus
    )
    let queue = CapturedAudioProcessingQueue(
      sessionCoordinator: coordinator,
      eventBus: eventBus
    )
    let expectedContext = ContextSnapshot(
      focus: FocusSnapshot(
        applicationName: "Editor",
        bundleIdentifier: "com.example.editor",
        processIdentifier: 42,
        focusedRole: "AXTextArea",
        selectedText: "",
        secureInput: false
      ),
      clipboard: ClipboardSnapshot(plainText: "", changeCount: 0)
    )
    let expectedOptions = SpeechRecognitionRequestOptions(
      language: "zh-CN",
      hints: RecognitionHints(keyterms: ["Rill"])
    )
    let optionsProbe = WorkflowRecognitionOptionsProbe()
    let controller = WorkflowAudioRunController(
      audioCaptureService: audioCaptureService,
      capturedAudioProcessingQueue: queue,
      contextProvider: { expectedContext },
      privacyContextProvider: { expectedContext },
      authorizedContextProvider: { decision in expectedContext.applying(decision) },
      recognitionOptionsProvider: { _, context in
        await optionsProbe.resolve(context: context, options: expectedOptions)
      },
      privacyRunGate: PrivacyRunGate(
        settingsProvider: {
          PrivacyPolicySettings(
            sensitiveAppRules: [],
            cloudConfirmationRequired: false
          )
        },
        cloudConfirmationProvider: { _, _, _ in true }
      )
    )
    let workflow = WorkflowDefinition(
      name: "Local Workflow",
      trigger: .manual,
      pipeline: PipelineDeclaration(recognizerID: "sherpa-onnx.local", outputActions: []),
      ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
    )

    try await controller.startRun(workflow: workflow, binding: .manual)

    let captureSnapshot = await audioCaptureService.snapshot()
    XCTAssertEqual(captureSnapshot.request?.options, expectedOptions)
    let optionsCallCount = await optionsProbe.callCount()
    XCTAssertEqual(optionsCallCount, 1)
    await controller.cancelRun()
  }

  private func waitUntil(
    attempts: Int = 100,
    _ predicate: () async -> Bool
  ) async {
    for _ in 0..<attempts {
      if await predicate() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("The workflow live capture did not reach the expected state.")
  }
}

private func makeWorkflowAudioTestPrivacyGate() -> PrivacyRunGate {
  PrivacyRunGate(
    settingsProvider: {
      PrivacyPolicySettings(
        sensitiveAppRules: [],
        cloudConfirmationRequired: false
      )
    },
    cloudConfirmationProvider: { _, _, _ in true },
    destinationClassifier: { _ in .classified([.localSpeech]) }
  )
}

private struct TestContextProvider: ContextProvider {
  func captureContext() async -> ContextSnapshot { .empty }
}

private func makeWorkflowLiveContext(
  bundleIdentifier: String = "com.apple.Notes"
) -> ContextSnapshot {
  ContextSnapshot(
    focus: FocusSnapshot(
      applicationName: "Workflow Live Test",
      bundleIdentifier: bundleIdentifier,
      processIdentifier: 44,
      focusedRole: nil,
      selectedText: "",
      secureInput: false
    ),
    clipboard: ClipboardSnapshot(plainText: "", changeCount: 0)
  )
}
