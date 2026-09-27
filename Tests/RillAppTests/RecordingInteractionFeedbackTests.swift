import RillDomainTestSupport
import Foundation
import Testing

@testable import RillApp
import RillCore
@testable import RillWorkflows

@MainActor
struct RecordingInteractionFeedbackTests {
  @Test func sharedAppActionPlaysBothSoundsAndRejectsInvalidatedTokens() async {
    var played: [RecordingInteractionCue] = []
    let action = AppBootstrap.recordingCueAction { played.append($0) }
    await action(.started, RecordingCueToken())
    await action(.stopped, RecordingCueToken())
    let staleToken = RecordingCueToken()
    staleToken.invalidate()
    await action(.started, staleToken)
    await action(.stopped, staleToken)

    #expect(played == [.started, .stopped])
  }
}

struct WorkflowAudioRunControllerCueTests {
  @Test(arguments: [TriggerBinding.manual, .menuBar, .hotkey, .wakeWord])
  func cuesFollowCaptureBoundaries(binding: TriggerBinding) async throws {
    let fixture = CueFixture()
    try await fixture.controller.startRun(workflow: fixture.workflow, binding: binding)
    try await fixture.controller.finishRun()

    let expected: [CueCapture.Event] = binding == .wakeWord
      ? [.started, .finished, .cue(.stopped)]
      : [.started, .cue(.started), .finished, .cue(.stopped)]
    #expect(await fixture.capture.events == expected)
    await fixture.shutdown()
  }

  @Test func cancellationSuppressesStartWaitingAtEffectBoundary() async throws {
    let gate = CueBarrier()
    let fixture = CueFixture(blockedCue: .started, gate: gate)
    let start = Task {
      try await fixture.controller.startRun(workflow: fixture.workflow, binding: .manual)
    }
    await gate.waitUntilEntered()
    await fixture.controller.cancelRun()
    await gate.release()
    try await start.value

    #expect(await fixture.capture.events == [.started, .cancelled])
    await fixture.shutdown()
  }

  @Test func newCaptureSuppressesPreviousStopWaitingAtEffectBoundary() async throws {
    let gate = CueBarrier()
    let fixture = CueFixture(blockedCue: .stopped, gate: gate)
    try await fixture.controller.startRun(workflow: fixture.workflow, binding: .manual)
    let finish = Task { try await fixture.controller.finishRun() }
    await gate.waitUntilEntered()
    try await fixture.controller.startRun(workflow: fixture.workflow, binding: .menuBar)
    await gate.release()
    try await finish.value
    try await fixture.controller.finishRun()

    #expect(await fixture.capture.events == [
      .started, .cue(.started), .finished, .started, .cue(.started), .finished, .cue(.stopped),
    ])
    await fixture.shutdown()
  }

  @Test func shutdownInvalidatesAndDrainsEnteredStartCue() async throws {
    let gate = CueBarrier()
    let fixture = CueFixture(blockedCue: .started, gate: gate)
    let start = Task {
      try await fixture.controller.startRun(workflow: fixture.workflow, binding: .manual)
    }
    await gate.waitUntilEntered()
    let shutdown = Task { await fixture.controller.shutdown() }
    await fixture.capture.waitUntilCancelled()
    // Capture cancellation has completed, but shutdown still owns the cue task.
    #expect(await fixture.capture.didShutdown == false)
    await gate.release()
    try await start.value
    await shutdown.value

    #expect(await fixture.capture.events == [.started, .cancelled])
    #expect(await fixture.capture.didShutdown)
    await fixture.queue.shutdown()
  }

  @Test(arguments: [CueCapture.Failure.start, .finish])
  fileprivate func failedCaptureNeverPlaysStop(failure: CueCapture.Failure) async {
    let fixture = CueFixture(failure: failure)
    do {
      try await fixture.controller.startRun(workflow: fixture.workflow, binding: .manual)
      try await fixture.controller.finishRun()
      Issue.record("The capture fixture must fail.")
    } catch {
      #expect(error is CueCapture.Failure)
    }
    let events = await fixture.capture.events
    #expect(!events.contains(.cue(.stopped)))
    #expect(events.contains(.cue(.started)) == (failure == .finish))
    await fixture.shutdown()
  }
}

private struct CueFixture {
  let capture: CueCapture
  let controller: WorkflowAudioRunController
  let queue: CapturedAudioProcessingQueue
  let workflow = WorkflowDefinition(
    name: "Recording feedback",
    trigger: .manual,
    pipeline: PipelineDeclaration(recognizerID: "missing", outputActions: []),
    ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
  )

  init(
    failure: CueCapture.Failure? = nil,
    blockedCue: RecordingInteractionCue? = nil,
    gate: CueBarrier? = nil
  ) {
    let capture = CueCapture(failure: failure)
    self.capture = capture
    let eventBus = EventBus()
    let coordinator = makeTestSessionCoordinator(
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      eventBus: eventBus
    )
    queue = makeTestCapturedAudioProcessingQueue(sessionCoordinator: coordinator, eventBus: eventBus)
    controller = makeTestWorkflowAudioRunController(
      audioCaptureService: capture,
      capturedAudioProcessingQueue: queue,
      privacyRunGate: PrivacyRunGate(
        settingsProvider: {
          PrivacyPolicySettings(sensitiveAppRules: [], cloudConfirmationRequired: false)
        },
        cloudConfirmationProvider: { _, _, _ in true },
        destinationClassifier: { _ in .classified([.localSpeech]) }
      ),
      recordingCueAction: { cue, token in
        if cue == blockedCue { await gate?.enterOnce() }
        await capture.play(cue, token: token)
      }
    )
  }

  func shutdown() async {
    await controller.shutdown()
    await queue.shutdown()
  }
}

private struct CueContextProvider: ContextProvider {
  func captureContext() async -> ContextSnapshot { .empty }
}

private actor CueCapture: AudioCaptureService {
  enum Failure: Error { case start, finish }
  enum Event: Equatable { case started, finished, cancelled, cue(RecordingInteractionCue) }
  let failure: Failure?
  private(set) var events: [Event] = []
  private(set) var didShutdown = false
  private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

  init(failure: Failure?) { self.failure = failure }

  func startCapture(_ request: AudioCaptureRequest) async throws {
    if failure == .start { throw Failure.start }
    events.append(.started)
  }

  func finishCapture() async throws -> CapturedAudio {
    if failure == .finish { throw Failure.finish }
    events.append(.finished)
    return try CapturedAudio(
      durationSeconds: 1,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
      fileURL: URL(fileURLWithPath: "/dev/null")
    )
  }

  func cancelCapture() async {
    events.append(.cancelled)
    let waiters = cancelWaiters
    cancelWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  func shutdown() async { didShutdown = true }

  func waitUntilCancelled() async {
    guard !events.contains(.cancelled) else { return }
    await withCheckedContinuation { cancelWaiters.append($0) }
  }

  func play(_ cue: RecordingInteractionCue, token: RecordingCueToken) {
    token.performIfValid { events.append(.cue(cue)) }
  }
}

private actor CueBarrier {
  private var entered = false
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []

  func enterOnce() async {
    guard !entered else { return }
    entered = true
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
      let waiters = entryWaiters
      entryWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }
  }

  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { entryWaiters.append($0) }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}
