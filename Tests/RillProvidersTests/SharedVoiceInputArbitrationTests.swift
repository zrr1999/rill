@testable import RillSpeech
import XCTest

@testable import RillProviders

final class SharedVoiceInputArbitrationTests: XCTestCase {
  func testInteractiveRecognitionPreemptsAmbientWakeWordFrames() {
    let activity = SharedVoiceInputActivity(
      activeChannels: [.ambientWakeWord, .interactiveRecognition]
    )

    XCTAssertEqual(activity.highestPriorityChannel, .interactiveRecognition)
    XCTAssertTrue(activity.isInteractiveRecognitionActive)
    XCTAssertTrue(
      SharedVoiceInputArbitration.shouldDeliver(
        to: .interactiveRecognition,
        activity: activity
      )
    )
    XCTAssertFalse(
      SharedVoiceInputArbitration.shouldDeliver(
        to: .ambientWakeWord,
        activity: activity
      )
    )
  }

  func testAmbientWakeWordReceivesFramesWhenItIsTheOnlyConsumer() {
    let activity = SharedVoiceInputActivity(
      activeChannels: [.ambientWakeWord]
    )

    XCTAssertEqual(activity.highestPriorityChannel, .ambientWakeWord)
    XCTAssertFalse(activity.isInteractiveRecognitionActive)
    XCTAssertTrue(
      SharedVoiceInputArbitration.shouldDeliver(
        to: .ambientWakeWord,
        activity: activity
      )
    )
  }

  func testProducerSwitchesFrontendsAndReleasesVoiceProcessingWhenInteractiveRunEnds()
    async throws
  {
    let ambientPreempted = expectation(description: "ambient frontend released on preemption")
    let ambientReleased = expectation(description: "resumed ambient frontend released")
    let interactiveReleased = expectation(description: "interactive frontend released")
    let ambientProbe = VoiceInputFrontendLifecycleProbe(
      releaseExpectations: [ambientPreempted, ambientReleased]
    )
    let interactiveProbe = VoiceInputFrontendLifecycleProbe(
      releaseExpectations: [interactiveReleased]
    )
    let hub = SharedVoiceInputHub(
      ambientProcessor: AppleVoiceProcessingAudioProcessor(
        sessionFactory: VoiceInputFrontendSessionFactory(probe: ambientProbe)
      ),
      interactiveProcessor: AppleVoiceProcessingAudioProcessor(
        sessionFactory: VoiceInputFrontendSessionFactory(probe: interactiveProbe)
      )
    )

    let ambient = try await hub.subscribe(channel: .ambientWakeWord)
    XCTAssertEqual(ambientProbe.snapshot(), .init(configure: 1, start: 1, stop: 0))
    XCTAssertEqual(ambientProbe.liveFrontendCount, 1)
    XCTAssertEqual(interactiveProbe.snapshot(), .zero)
    XCTAssertEqual(interactiveProbe.liveFrontendCount, 0)

    let interactive = try await hub.subscribe(channel: .interactiveRecognition)
    await fulfillment(of: [ambientPreempted], timeout: 2)
    let suspendedAmbient = ambientProbe.snapshot()
    XCTAssertEqual(suspendedAmbient.configure, 1)
    XCTAssertEqual(suspendedAmbient.start, 1)
    XCTAssertGreaterThanOrEqual(suspendedAmbient.stop, 1)
    XCTAssertEqual(ambientProbe.liveFrontendCount, 0)
    XCTAssertEqual(interactiveProbe.snapshot(), .init(configure: 1, start: 1, stop: 0))
    XCTAssertEqual(interactiveProbe.liveFrontendCount, 1)

    await hub.unsubscribe(id: interactive.id)
    await fulfillment(of: [interactiveReleased], timeout: 2)
    let stoppedInteractive = interactiveProbe.snapshot()
    XCTAssertEqual(stoppedInteractive.configure, 1)
    XCTAssertEqual(stoppedInteractive.start, 1)
    XCTAssertGreaterThanOrEqual(stoppedInteractive.stop, 1)
    XCTAssertEqual(interactiveProbe.liveFrontendCount, 0)
    let resumedAmbient = ambientProbe.snapshot()
    XCTAssertEqual(resumedAmbient.configure, 2)
    XCTAssertEqual(resumedAmbient.start, 2)
    XCTAssertGreaterThanOrEqual(resumedAmbient.stop, 1)
    XCTAssertEqual(ambientProbe.liveFrontendCount, 1)

    await hub.unsubscribe(id: ambient.id)
    await fulfillment(of: [ambientReleased], timeout: 2)
    let finalAmbientSnapshot = ambientProbe.snapshot()
    XCTAssertEqual(finalAmbientSnapshot.configure, 2)
    XCTAssertEqual(finalAmbientSnapshot.start, 2)
    XCTAssertGreaterThanOrEqual(finalAmbientSnapshot.stop, 2)
    XCTAssertEqual(ambientProbe.liveFrontendCount, 0)
    await hub.shutdown()
  }
}

private final class VoiceInputFrontendLifecycleProbe: @unchecked Sendable {
  struct Snapshot: Equatable {
    let configure: Int
    let start: Int
    let stop: Int

    static let zero = Snapshot(configure: 0, start: 0, stop: 0)
  }

  private let lock = NSLock()
  private var configureCount = 0
  private var startCount = 0
  private var stopCount = 0
  private var frontendCount = 0
  private var releaseExpectations: [XCTestExpectation]

  init(releaseExpectations: [XCTestExpectation]) {
    self.releaseExpectations = releaseExpectations
  }

  var liveFrontendCount: Int {
    lock.withLock { frontendCount }
  }

  func recordFrontendCreated() {
    lock.withLock { frontendCount += 1 }
  }

  func recordFrontendReleased() {
    let expectation = lock.withLock {
      frontendCount -= 1
      return releaseExpectations.isEmpty ? nil : releaseExpectations.removeFirst()
    }
    expectation?.fulfill()
  }

  func recordConfigure() {
    lock.withLock { configureCount += 1 }
  }

  func recordStart() {
    lock.withLock { startCount += 1 }
  }

  func recordStop() {
    lock.withLock { stopCount += 1 }
  }

  func snapshot() -> Snapshot {
    lock.withLock {
      Snapshot(configure: configureCount, start: startCount, stop: stopCount)
    }
  }
}

private struct VoiceInputFrontendSessionFactory:
  AppleVoiceProcessingAudioEngineSessionFactory,
  Sendable
{
  let probe: VoiceInputFrontendLifecycleProbe

  func makeSession(inputDeviceID: AppleVoiceProcessingInputDeviceID?)
    -> any AppleVoiceProcessingAudioEngineSession
  {
    VoiceInputFrontendSession(probe: probe)
  }
}

private final class VoiceInputFrontendSession:
  AppleVoiceProcessingAudioEngineSession,
  @unchecked Sendable
{
  private let probe: VoiceInputFrontendLifecycleProbe

  init(probe: VoiceInputFrontendLifecycleProbe) {
    self.probe = probe
    probe.recordFrontendCreated()
  }

  deinit {
    probe.recordFrontendReleased()
  }

  func configureVoiceProcessing() throws {
    probe.recordConfigure()
  }

  func start(
    format: AppleVoiceProcessingCaptureFormat,
    bufferHandler: @escaping @Sendable ([Float]) -> Void,
    failureHandler: @escaping @Sendable (AppleVoiceProcessingAudioError) -> Void
  ) throws {
    probe.recordStart()
  }

  func stop() {
    probe.recordStop()
  }
}
