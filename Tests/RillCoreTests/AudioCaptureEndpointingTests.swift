import XCTest

@testable import RillCore

final class AudioCaptureEndpointingTests: XCTestCase {
  private let policy = SpeechEndpointPolicy(
    initialSilenceTimeoutSeconds: 1,
    minimumSpeechDurationSeconds: 0.3,
    trailingSilenceDurationSeconds: 0.5,
    voiceActivityThreshold: 0.3
  )

  func testVoiceActivityThresholdUsesSherpaOpenInterval() {
    XCTAssertFalse(SpeechEndpointPolicy.isValidVoiceActivityThreshold(.nan))
    XCTAssertFalse(SpeechEndpointPolicy.isValidVoiceActivityThreshold(0))
    XCTAssertTrue(SpeechEndpointPolicy.isValidVoiceActivityThreshold(0.3))
    XCTAssertFalse(SpeechEndpointPolicy.isValidVoiceActivityThreshold(1))
  }

  func testInitialSilenceTimesOutWithoutLatchingTransientNoise() {
    var detector = SpeechEndpointDetector(policy: policy)

    XCTAssertNil(detector.observe(isSpeech: true, durationSeconds: 0.1))
    XCTAssertNil(detector.observe(isSpeech: false, durationSeconds: 0.1))
    for _ in 0..<7 {
      XCTAssertNil(detector.observe(isSpeech: false, durationSeconds: 0.1))
    }

    XCTAssertEqual(
      detector.observe(isSpeech: false, durationSeconds: 0.1),
      .initialSilenceTimedOut
    )
    XCTAssertEqual(detector.state, .ended(.initialSilenceTimedOut))
    XCTAssertNil(detector.observe(isSpeech: true, durationSeconds: 1))
  }

  func testSpeechEndsOnlyAfterMinimumSpeechAndTrailingSilence() {
    var detector = SpeechEndpointDetector(policy: policy)

    for _ in 0..<3 {
      XCTAssertNil(detector.observe(isSpeech: true, durationSeconds: 0.1))
    }
    XCTAssertEqual(detector.state, .speaking)

    for _ in 0..<3 {
      XCTAssertNil(detector.observe(isSpeech: false, durationSeconds: 0.1))
    }
    XCTAssertEqual(detector.state, .trailingSilence)

    XCTAssertNil(detector.observe(isSpeech: true, durationSeconds: 0.1))
    XCTAssertEqual(detector.state, .speaking)

    for _ in 0..<4 {
      XCTAssertNil(detector.observe(isSpeech: false, durationSeconds: 0.1))
    }
    XCTAssertEqual(
      detector.observe(isSpeech: false, durationSeconds: 0.1),
      .speechEnded
    )
    XCTAssertEqual(detector.state, .ended(.speechEnded))
  }

  func testNonPositiveIntervalsDoNotAdvanceDetector() {
    var detector = SpeechEndpointDetector(policy: policy)

    XCTAssertNil(detector.observe(isSpeech: true, durationSeconds: 0))
    XCTAssertNil(detector.observe(isSpeech: true, durationSeconds: -1))
    XCTAssertEqual(detector.state, .waitingForSpeech)
  }

  func testSignalChannelPublishesOnlyTheFirstTerminalReason() async throws {
    let runID = UUID()
    let channel = AudioCaptureEndpointControl(runID: runID, policy: policy)
    let stream = try XCTUnwrap(channel.claimStream())
    let readTask = Task {
      var signals: [AudioCaptureTerminalSignal] = []
      for await signal in stream {
        signals.append(signal)
      }
      return signals
    }

    XCTAssertTrue(channel.send(.speechEnded))
    XCTAssertFalse(channel.send(.maximumDurationReached))

    let signals = await readTask.value
    XCTAssertEqual(
      signals,
      [AudioCaptureTerminalSignal(runID: runID, reason: .speechEnded)]
    )
  }

  func testFinishingSignalChannelWithoutReasonEndsStream() async throws {
    let channel = AudioCaptureEndpointControl(runID: UUID(), policy: policy)
    let stream = try XCTUnwrap(channel.claimStream())
    let readTask = Task {
      var count = 0
      for await _ in stream {
        count += 1
      }
      return count
    }

    channel.finish()

    let count = await readTask.value
    XCTAssertEqual(count, 0)
  }

  func testSignalSentBeforeConsumerClaimRemainsBuffered() async throws {
    let runID = UUID()
    let control = AudioCaptureEndpointControl(runID: runID, policy: policy)

    XCTAssertTrue(control.send(.speechEnded))
    let stream = try XCTUnwrap(control.claimStream())
    var iterator = stream.makeAsyncIterator()
    let signal = await iterator.next()
    let end = await iterator.next()

    XCTAssertEqual(
      signal,
      AudioCaptureTerminalSignal(runID: runID, reason: .speechEnded)
    )
    XCTAssertNil(end)
  }

  func testEnergySummaryIsIntegerOnlyBucketedAndFrozenAtomicallyAtSend() async throws {
    let runID = UUID()
    let control = AudioCaptureEndpointControl(runID: runID, policy: policy)
    let stream = try XCTUnwrap(control.claimStream())

    XCTAssertTrue(control.observeEnergy(relativeLevel: 0.1, durationSeconds: 0.1))
    XCTAssertTrue(control.observeEnergy(relativeLevel: 0.42, durationSeconds: 0.2))
    XCTAssertTrue(control.observeEnergy(relativeLevel: 0.5, durationSeconds: 0.15))
    XCTAssertTrue(control.observeEnergy(relativeLevel: 0.2, durationSeconds: 0.05))
    XCTAssertTrue(control.observeEnergy(relativeLevel: 0.4, durationSeconds: 0.25))
    XCTAssertFalse(control.observeEnergy(relativeLevel: .nan, durationSeconds: 1))
    XCTAssertFalse(control.observeEnergy(relativeLevel: 0.5, durationSeconds: .infinity))
    XCTAssertFalse(control.observeEnergy(relativeLevel: 0.5, durationSeconds: 0))

    XCTAssertTrue(control.send(.speechEnded))
    XCTAssertFalse(
      control.observeEnergy(relativeLevel: 1, durationSeconds: 10),
      "An observation after send must not mutate the terminal snapshot."
    )

    var iterator = stream.makeAsyncIterator()
    let nextSignal = await iterator.next()
    let signal = try XCTUnwrap(nextSignal)
    XCTAssertEqual(signal.runID, runID)
    XCTAssertEqual(signal.reason, .speechEnded)
    XCTAssertEqual(
      signal.acousticSummary,
      AudioCaptureAcousticSummary(
        observedSegmentCount: 5,
        observedDurationMilliseconds: 750,
        aboveThresholdDurationMilliseconds: 600,
        peakLevelPercentBucket: 50,
        maximumConsecutiveAboveThresholdDurationMilliseconds: 350
      )
    )
    let end = await iterator.next()
    XCTAssertNil(end)
  }

  func testNativeVoiceActivityAndMeasuredLevelRemainIndependentInSummary() async throws {
    let control = AudioCaptureEndpointControl(runID: UUID(), policy: policy)
    let stream = try XCTUnwrap(control.claimStream())

    XCTAssertTrue(
      control.observeVoiceActivity(
        isSpeech: true,
        relativeLevel: 0.28,
        durationSeconds: 0.1
      )
    )
    XCTAssertTrue(control.send(.speechEnded))

    var iterator = stream.makeAsyncIterator()
    let nextSignal = await iterator.next()
    let signal = try XCTUnwrap(nextSignal)
    XCTAssertEqual(signal.acousticSummary.aboveThresholdDurationMilliseconds, 100)
    XCTAssertEqual(signal.acousticSummary.peakLevelPercentBucket, 30)
  }

  func testConcurrentEnergyObservationsAreCountedWithoutDataRaces() async throws {
    let control = AudioCaptureEndpointControl(runID: UUID(), policy: policy)
    let stream = try XCTUnwrap(control.claimStream())

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<100 {
        group.addTask {
          XCTAssertTrue(
            control.observeEnergy(relativeLevel: 0.375, durationSeconds: 0.01)
          )
        }
      }
    }
    XCTAssertTrue(control.send(.speechEnded))

    var iterator = stream.makeAsyncIterator()
    let nextSignal = await iterator.next()
    let signal = try XCTUnwrap(nextSignal)
    XCTAssertEqual(
      signal.acousticSummary,
      AudioCaptureAcousticSummary(
        observedSegmentCount: 100,
        observedDurationMilliseconds: 1_000,
        aboveThresholdDurationMilliseconds: 1_000,
        peakLevelPercentBucket: 40,
        maximumConsecutiveAboveThresholdDurationMilliseconds: 1_000
      )
    )
  }

  func testPeakEnergyUsesTheUpperFivePercentBucketAndClampsToRange() async throws {
    for (level, expectedBucket): (Float, UInt64) in [
      (-1, 0),
      (0, 0),
      (0.001, 5),
      (0.1, 10),
      (0.2, 20),
      (0.3, 30),
      (0.4, 40),
      (0.301, 35),
      (0.999, 100),
      (2, 100),
    ] {
      let control = AudioCaptureEndpointControl(runID: UUID(), policy: policy)
      let stream = try XCTUnwrap(control.claimStream())
      XCTAssertTrue(control.observeEnergy(relativeLevel: level, durationSeconds: 0.01))
      XCTAssertTrue(control.send(.speechEnded))

      var iterator = stream.makeAsyncIterator()
      let nextSignal = await iterator.next()
      let signal = try XCTUnwrap(nextSignal)
      XCTAssertEqual(
        signal.acousticSummary.peakLevelPercentBucket,
        expectedBucket,
        "Unexpected upper bucket for relative level \(level)."
      )
    }
  }

  func testEndpointStreamCanOnlyBeClaimedOnce() {
    let control = AudioCaptureEndpointControl(runID: UUID(), policy: policy)

    XCTAssertNotNil(control.claimStream())
    XCTAssertNil(control.claimStream())
  }

  func testConcurrentTerminalSignalsHaveExactlyOneWinner() async throws {
    let runID = UUID()
    let control = AudioCaptureEndpointControl(runID: runID, policy: policy)
    let stream = try XCTUnwrap(control.claimStream())

    let winnerCount = await withTaskGroup(of: Bool.self) { group in
      for index in 0..<32 {
        group.addTask {
          control.send(index.isMultiple(of: 2) ? .speechEnded : .maximumDurationReached)
        }
      }
      var count = 0
      for await didWin in group where didWin {
        count += 1
      }
      return count
    }
    var iterator = stream.makeAsyncIterator()
    let signal = await iterator.next()
    let end = await iterator.next()

    XCTAssertEqual(winnerCount, 1)
    XCTAssertEqual(signal?.runID, runID)
    XCTAssertTrue(
      signal?.reason == .speechEnded || signal?.reason == .maximumDurationReached
    )
    XCTAssertNil(end)
  }
}
