@preconcurrency import AVFoundation
import Foundation
import XCTest

@testable import RillCore
@testable import RillProviders

final class LocalSpeechVoiceCaptureRuntimeTests: XCTestCase {
  func testPermissionDenialFailsBeforeStartingAudioSource() async {
    let source = TestLocalSpeechAudioCaptureSource()
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { false },
      sourceFactory: { source }
    )

    do {
      try await runtime.startCapture(request: makeLocalSpeechRequest())
      XCTFail("Expected microphone permission denial.")
    } catch {
      XCTAssertEqual(
        error as? RealtimeAudioCaptureService.CaptureError,
        .microphonePermissionDenied
      )
    }
    XCTAssertEqual(source.startCount, 0)
  }

  func testCancellationDuringPermissionAwaitCannotStartOrReplaceNewCapture() async throws {
    let permissionGate = LocalSpeechPermissionRaceGate()
    let source = TestLocalSpeechAudioCaptureSource()
    let snapshots = LocalSpeechSnapshotProbe()
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { await permissionGate.requestPermission() },
      sourceFactory: { source },
      liveUpdateHandler: { await snapshots.append($0) }
    )
    let firstRunID = UUID()
    let firstLifetime = AudioCaptureLifetime(runID: firstRunID)
    let firstRequest = makeLocalSpeechRequest(
      runID: firstRunID,
      audioLifetime: firstLifetime
    )
    let firstStart = Task { try await runtime.startCapture(request: firstRequest) }
    await permissionGate.waitUntilFirstRequest()

    firstLifetime.cancel()
    await runtime.cancelCapture(for: firstRequest)

    let secondRunID = UUID()
    let secondLifetime = AudioCaptureLifetime(runID: secondRunID)
    let secondRequest = makeLocalSpeechRequest(
      runID: secondRunID,
      audioLifetime: secondLifetime
    )
    let secondStart = Task { try await runtime.startCapture(request: secondRequest) }
    try await source.waitUntilStarted()
    source.emit(
      samples: Array(repeating: 0.2, count: 4_800),
      cumulativeRMS: [0.005, 0.005, 0.005]
    )
    try await secondStart.value

    await permissionGate.resolveFirstRequest(granted: true)
    do {
      try await firstStart.value
      XCTFail("A cancelled permission request must not reclaim capture ownership.")
    } catch is CancellationError {
      // Expected.
    }

    let publishedSnapshots = await snapshots.values
    XCTAssertEqual(source.startCount, 1)
    XCTAssertFalse(
      publishedSnapshots.contains { $0.runID == firstRunID && $0.phase == .recording }
    )
    XCTAssertTrue(
      publishedSnapshots.contains { $0.runID == secondRunID && $0.phase == .recording }
    )
    XCTAssertEqual(firstLifetime.state, .revoked(.captureCancelled))
    XCTAssertEqual(secondLifetime.state, .active)
    await runtime.cancelCapture(for: secondRequest)
    XCTAssertEqual(source.stopCount, 1)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: makeLocalSpeechOutputURL(runID: secondRunID).path
      )
    )
  }

  func testRecordingWriterInitializationFailureRemovesPartialPlaintextFile() async {
    let source = TestLocalSpeechAudioCaptureSource()
    let cleanupProbe = LocalSpeechCleanupRemovalProbe()
    let cleanupOwner = ManagedTemporaryAudioCleanupOwner(
      removal: { try await cleanupProbe.remove($0) }
    )
    let runID = UUID()
    let outputURL = makeLocalSpeechOutputURL(runID: runID)
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source },
      recordingWriterFactory: { fileURL, _ in
        try Data("partial".utf8).write(to: fileURL)
        throw TestLocalSpeechFailure.writerInitialization
      },
      cleanupOwner: cleanupOwner
    )

    do {
      try await runtime.startCapture(request: makeLocalSpeechRequest(runID: runID))
      XCTFail("A failed writer initialization must reject capture startup.")
    } catch {
      XCTAssertEqual(
        error as? RealtimeAudioCaptureService.CaptureError,
        .microphoneStartFailed
      )
    }

    let removedURLs = await cleanupProbe.removedURLs
    XCTAssertEqual(removedURLs, [outputURL])
    XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    XCTAssertEqual(source.startCount, 0)
  }

  func testFirstUsableFrameMakesCaptureReadyAndFinishWritesCompleteWaveFile() async throws {
    let source = TestLocalSpeechAudioCaptureSource()
    let snapshots = LocalSpeechSnapshotProbe()
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source },
      liveUpdateHandler: { await snapshots.append($0) }
    )
    let request = makeLocalSpeechRequest(maxDurationSeconds: 120)

    let startTask = Task { try await runtime.startCapture(request: request) }
    try await source.waitUntilStarted()
    let phasesBeforeFirstFrame = await snapshots.phases
    XCTAssertFalse(
      phasesBeforeFirstFrame.contains(.recording),
      "Capture must stay preparing until VPIO supplies a usable frame."
    )
    let firstUsableFrame = Array(
      repeating: Float(0.2),
      count: LocalSpeechInputReadinessDetector.minimumUsableFrameSampleCount
    )
    source.emit(
      samples: firstUsableFrame,
      cumulativeRMS: [0.005]
    )
    try await startTask.value

    let capturedAudio = try await runtime.finishCaptureDeferred(for: request).value()
    defer { _ = try? capturedAudio.removeManagedTemporaryFile() }

    XCTAssertEqual(
      capturedAudio.durationSeconds,
      Double(firstUsableFrame.count) / 16_000,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      capturedAudio.format,
      AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .float32)
    )
    XCTAssertEqual(capturedAudio.metadata["live.provider"], "sherpa-onnx.capture")
    let fileURL = try XCTUnwrap(capturedAudio.fileURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    XCTAssertGreaterThan(try Data(contentsOf: fileURL).count, 44)
    XCTAssertGreaterThanOrEqual(source.stopCount, 1)

    let phases = await snapshots.phases
    XCTAssertTrue(phases.contains(.recording))
    XCTAssertEqual(phases.last, .hidden)
    let publishedSnapshots = await snapshots.values
    let recordingSnapshot = try XCTUnwrap(
      publishedSnapshots.first(where: { $0.phase == .recording })
    )
    XCTAssertNotNil(recordingSnapshot.recordingStartedAt)
    XCTAssertEqual(recordingSnapshot.maximumRecordingDurationSeconds, 120)
    let hiddenSnapshot = try XCTUnwrap(publishedSnapshots.last)
    XCTAssertNil(hiddenSnapshot.recordingStartedAt)
    XCTAssertNil(hiddenSnapshot.maximumRecordingDurationSeconds)
  }

  func testRemovingDurationLimitOnlyUpdatesTheActiveCapture() async throws {
    let source = TestLocalSpeechAudioCaptureSource()
    let snapshots = LocalSpeechSnapshotProbe()
    let runID = UUID()
    let writer = try TestLocalSpeechRecordingWriter(
      fileURL: makeLocalSpeechOutputURL(runID: runID),
      failure: .none
    )
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source },
      recordingWriterFactory: { _, _ in writer },
      liveUpdateHandler: { await snapshots.append($0) }
    )
    let request = makeLocalSpeechRequest(
      runID: runID,
      maxDurationSeconds: 120,
      canRemoveMaxDurationLimit: true
    )

    let startTask = Task { try await runtime.startCapture(request: request) }
    try await source.waitUntilStarted()
    source.emit(
      samples: Array(
        repeating: Float(0.2),
        count: LocalSpeechInputReadinessDetector.minimumUsableFrameSampleCount
      ),
      cumulativeRMS: [0.005]
    )
    try await startTask.value

    let firstRemoval = await runtime.removeMaximumDurationLimit(runID: runID)
    let repeatedRemoval = await runtime.removeMaximumDurationLimit(runID: runID)
    let staleRemoval = await runtime.removeMaximumDurationLimit(runID: UUID())
    XCTAssertTrue(firstRemoval)
    XCTAssertFalse(repeatedRemoval)
    XCTAssertFalse(staleRemoval)
    XCTAssertEqual(writer.removeFrameLimitCount, 1)

    let publishedSnapshots = await snapshots.values
    let unlimitedSnapshot = try XCTUnwrap(
      publishedSnapshots.last(where: {
        $0.runID == runID && $0.phase == .recording
          && $0.recordingDurationIsUnlimited == true
      })
    )
    XCTAssertNil(unlimitedSnapshot.maximumRecordingDurationSeconds)
    XCTAssertEqual(unlimitedSnapshot.canRemoveRecordingDurationLimit, false)

    await runtime.cancelCapture(for: request)
  }

  func testFixedStreamingPreviewPublishesHypothesisWithoutChangingCapturedAudio() async throws {
    let source = TestLocalSpeechAudioCaptureSource()
    let snapshots = LocalSpeechSnapshotProbe()
    let preview = TestLocalSpeechStreamingPreviewSession(
      results: [.success("你好 world"), .success("")],
      finishResult: .success("你好 world final")
    )
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source },
      streamingPreviewSessionFactory: { preview },
      liveUpdateHandler: { await snapshots.append($0) }
    )
    let request = makeLocalSpeechRequest()
    let samples = Array(repeating: Float(0.2), count: 4_800)

    let startTask = Task { try await runtime.startCapture(request: request) }
    try await source.waitUntilStarted()
    source.emit(samples: samples, cumulativeRMS: [0.005, 0.005, 0.005])
    try await startTask.value
    let trailingSamples = Array(repeating: Float(0.1), count: 1_600)
    source.emit(samples: trailingSamples, cumulativeRMS: [0.005])
    try await preview.waitUntilAcceptedSampleCount(2)

    let capturedAudio = try await runtime.finishCaptureDeferred(for: request).value()
    defer { _ = try? capturedAudio.removeManagedTemporaryFile() }
    let recordingSnapshots = await snapshots.values.filter { $0.phase == .recording }

    XCTAssertEqual(recordingSnapshots.last?.hypothesisText, "你好 world")
    XCTAssertEqual(preview.acceptedSampleCounts, [samples.count, trailingSamples.count])
    XCTAssertEqual(
      capturedAudio.durationSeconds,
      Double(samples.count + trailingSamples.count) / 16_000
    )
    XCTAssertEqual(
      capturedAudio.metadata[SherpaStreamingCaptureRecognizer.bestTextMetadataKey],
      "你好 world final"
    )
    XCTAssertEqual(
      capturedAudio.metadata[SherpaStreamingCaptureRecognizer.modelMetadataKey],
      SherpaStreamingPreviewService.modelID
    )
  }

  func testStreamingPreviewProjectionHoldsTransientRewritesUntilTheyStabilize() {
    var projection = LocalSpeechStreamingPreviewProjection()

    projection.observe("你好 Rill")
    XCTAssertEqual(projection.text, "你好 Rill")

    projection.observe("")
    projection.observe("天气")
    XCTAssertEqual(projection.text, "你好 Rill")

    projection.observe("天气如何")
    XCTAssertEqual(projection.text, "天气如何")

    projection.observe("天气如何呢")
    XCTAssertEqual(projection.text, "天气如何呢")
  }

  func testStreamingPreviewProjectionRemovesDuplicatedExtensionOverlap() {
    var projection = LocalSpeechStreamingPreviewProjection()

    projection.observe("今天天气")
    projection.observe("今天天气天气怎么样")
    XCTAssertEqual(projection.text, "今天天气怎么样")

    projection.observe("今天天气天气怎么样怎么样呢")
    XCTAssertEqual(projection.text, "今天天气怎么样呢")

    projection.reset()
    projection.observe("the quick")
    projection.observe("the quick quick brown")
    projection.observe("the quick quick brown brown fox")
    XCTAssertEqual(projection.text, "the quick brown fox")
  }

  func testStreamingPreviewProjectionPreservesIntentionalAndAmbiguousRepetition() {
    var projection = LocalSpeechStreamingPreviewProjection()

    projection.observe("谢谢")
    projection.observe("谢谢谢谢")
    XCTAssertEqual(projection.text, "谢谢谢谢")

    projection.reset()
    projection.observe("今天")
    projection.observe("今天天气")
    XCTAssertEqual(projection.text, "今天天气")

    projection.reset()
    projection.observe("我我")
    projection.observe("我我我觉得")
    XCTAssertEqual(projection.text, "我我觉得")
  }

  func testStreamingPreviewFailureFallsBackWithoutTerminatingCapture() async throws {
    let source = TestLocalSpeechAudioCaptureSource()
    let snapshots = LocalSpeechSnapshotProbe()
    let preview = TestLocalSpeechStreamingPreviewSession(results: [.failure])
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source },
      streamingPreviewSessionFactory: { preview },
      liveUpdateHandler: { await snapshots.append($0) }
    )
    let request = makeLocalSpeechRequest()

    let startTask = Task { try await runtime.startCapture(request: request) }
    try await source.waitUntilStarted()
    source.emit(
      samples: Array(repeating: 0.2, count: 4_800),
      cumulativeRMS: [0.005, 0.005, 0.005]
    )
    try await startTask.value
    let capturedAudio = try await runtime.finishCaptureDeferred(for: request).value()
    defer { _ = try? capturedAudio.removeManagedTemporaryFile() }

    let publishedSnapshots = await snapshots.values
    XCTAssertTrue(publishedSnapshots.contains { snapshot in
      snapshot.phase == .recording && snapshot.hypothesisText.isEmpty
    })
    XCTAssertGreaterThan(capturedAudio.durationSeconds, 0)
  }

  func testStreamingDirectWorkflowFailsBeforeCaptureWhenStreamingModelIsUnavailable() async {
    let source = TestLocalSpeechAudioCaptureSource()
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source },
      streamingPreviewSessionFactory: { nil }
    )
    var request = makeLocalSpeechRequest()
    request.workflow.pipeline.recognizerID = SherpaStreamingCaptureRecognizer.recognizerID

    do {
      try await runtime.startCapture(request: request)
      XCTFail("Streaming-direct must not record when its only recognizer is unavailable.")
    } catch {
      XCTAssertEqual(
        error as? RealtimeAudioCaptureService.CaptureError,
        .streamingSpeechUnavailable
      )
    }
    XCTAssertEqual(source.startCount, 0)
  }

  func testFinishDrainsEveryAcceptedTailChunkBeforeFinalizingWaveFile() async throws {
    let source = TestLocalSpeechAudioCaptureSource()
    let publishGate = LocalSpeechRecordingPublishGate()
    let voiceActivityDetector = TestLocalSpeechVoiceActivityDetector([
      .observations(Self.silenceObservations(count: 3)),
      .observations(Self.speechObservations(count: 1)),
      .failure,
    ])
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source },
      voiceActivityDetectorFactory: { _ in voiceActivityDetector },
      liveUpdateHandler: { snapshot in
        await publishGate.observe(snapshot)
      }
    )
    let runID = UUID()
    let endpointControl = AudioCaptureEndpointControl(
      runID: runID,
      policy: .shortDictation
    )
    let request = makeLocalSpeechRequest(runID: runID, endpointControl: endpointControl)
    let startupSamples = Array(repeating: Float(0.1), count: 4_800)
    let blockedTail = Array(repeating: Float(0.2), count: 1_600)
    let queuedTailA = Array(repeating: Float(0.3), count: 800)
    let queuedTailB = Array(repeating: Float(-0.4), count: 2_400)

    let startTask = Task { try await runtime.startCapture(request: request) }
    try await source.waitUntilStarted()
    source.emit(samples: startupSamples, cumulativeRMS: [0.005, 0.005, 0.005])
    try await startTask.value

    source.emit(samples: blockedTail, cumulativeRMS: [0.005, 0.005, 0.005, 0.005])
    await publishGate.waitUntilSecondRecordingPublishIsBlocked()
    source.emit(samples: queuedTailA, cumulativeRMS: [0.005, 0.005, 0.005, 0.005])
    source.emit(samples: queuedTailB, cumulativeRMS: [0.005, 0.005, 0.005, 0.005])

    let finishTask = Task { try await runtime.finishCaptureDeferred(for: request) }
    try await source.waitUntilStopCount(1)
    await publishGate.releaseSecondRecordingPublish()
    let capturedAudio = try await finishTask.value.value()
    defer { _ = try? capturedAudio.removeManagedTemporaryFile() }

    let expectedSamples = startupSamples + blockedTail + queuedTailA + queuedTailB
    let outputURL = try XCTUnwrap(capturedAudio.fileURL)
    let actualSamples = try readLocalSpeechWaveSamples(from: outputURL)
    XCTAssertEqual(actualSamples.count, expectedSamples.count)
    XCTAssertEqual(capturedAudio.durationSeconds, Double(expectedSamples.count) / 16_000)
    for (actual, expected) in zip(actualSamples, expectedSamples) {
      XCTAssertEqual(actual, expected, accuracy: 0.0001)
    }
    XCTAssertEqual(source.stopCount, 1)
    XCTAssertEqual(voiceActivityDetector.acceptedSampleCounts, [4_800, 1_600])
  }

  func testTwoMinuteFrameCeilingIncludesBoundedStartupGrace() async throws {
    let source = TestLocalSpeechAudioCaptureSource()
    let factoryProbe = LocalSpeechWriterFactoryProbe()
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source },
      recordingWriterFactory: { fileURL, frameLimit in
        factoryProbe.record(frameLimit: frameLimit)
        return try TestLocalSpeechRecordingWriter(fileURL: fileURL, failure: .none)
      }
    )
    let request = makeLocalSpeechRequest(maxDurationSeconds: 120)

    let startTask = Task { try await runtime.startCapture(request: request) }
    try await source.waitUntilStarted()
    source.emit(
      samples: Array(repeating: 0.2, count: 4_800),
      cumulativeRMS: [0.005, 0.005, 0.005]
    )
    try await startTask.value

    XCTAssertEqual(
      factoryProbe.frameLimits,
      [LocalSpeechIncrementalWaveWriter.maximumSupportedFrameCount]
    )
    await runtime.cancelCapture(for: request)
  }

  func testVoiceActivityObservationsAutomaticallySignalSpeechEnded() async throws {
    let source = TestLocalSpeechAudioCaptureSource()
    let thresholdProbe = LocalSpeechVoiceActivityThresholdProbe()
    let voiceActivityDetector = TestLocalSpeechVoiceActivityDetector([
      .observations(Self.silenceObservations(count: 3)),
      .observations(
        Self.speechObservations(count: 3)
          + Self.silenceObservations(count: 15)
      ),
    ])
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source },
      voiceActivityDetectorFactory: { threshold in
        thresholdProbe.record(threshold)
        return voiceActivityDetector
      }
    )
    let runID = UUID()
    let endpointControl = AudioCaptureEndpointControl(
      runID: runID,
      policy: .shortDictation
    )
    let terminalStream = try XCTUnwrap(endpointControl.claimStream())
    let request = makeLocalSpeechRequest(runID: runID, endpointControl: endpointControl)

    let terminalTask = Task<AudioCaptureTerminalSignal?, Never> {
      for await signal in terminalStream {
        return signal
      }
      return nil
    }
    let startTask = Task { try await runtime.startCapture(request: request) }
    try await source.waitUntilStarted()
    source.emit(
      samples: Array(repeating: 0.001, count: 4_800),
      cumulativeRMS: [0.005, 0.005, 0.005]
    )
    try await startTask.value
    XCTAssertEqual(thresholdProbe.thresholds, [0.3])

    source.emit(
      samples: Array(repeating: 0.1, count: 28_800),
      cumulativeRMS: Array(repeating: 0.005, count: 21)
    )

    let terminal = await terminalTask.value
    XCTAssertEqual(terminal?.reason, .speechEnded)
    XCTAssertEqual(terminal?.acousticSummary.observedSegmentCount, 20)
    XCTAssertEqual(terminal?.acousticSummary.observedDurationMilliseconds, 2_000)
    XCTAssertEqual(terminal?.acousticSummary.aboveThresholdDurationMilliseconds, 300)
    XCTAssertEqual(terminal?.acousticSummary.peakLevelPercentBucket, 30)
    await runtime.cancelCapture(for: request)
    XCTAssertEqual(voiceActivityDetector.acceptedSampleCounts, [4_800, 28_800])
    XCTAssertEqual(voiceActivityDetector.resetCount, 2)
  }

  func testEarlySpeechContributesBeforeReadyAndAutomaticallyEnds() async throws {
    let source = TestLocalSpeechAudioCaptureSource()
    let snapshots = LocalSpeechSnapshotProbe()
    let voiceActivityDetector = TestLocalSpeechVoiceActivityDetector([
      .observations(Self.speechObservations(count: 1)),
      .observations(Self.speechObservations(count: 2)),
      .observations(
        Self.speechObservations(count: 2)
          + Self.silenceObservations(count: 15)
      ),
    ])
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source },
      voiceActivityDetectorFactory: { _ in voiceActivityDetector },
      liveUpdateHandler: { await snapshots.append($0) }
    )
    let runID = UUID()
    let endpointControl = AudioCaptureEndpointControl(
      runID: runID,
      policy: .shortDictation
    )
    let terminalStream = try XCTUnwrap(endpointControl.claimStream())
    let request = makeLocalSpeechRequest(runID: runID, endpointControl: endpointControl)
    let terminalTask = Task<AudioCaptureTerminalSignal?, Never> {
      for await signal in terminalStream { return signal }
      return nil
    }

    let startTask = Task { try await runtime.startCapture(request: request) }
    try await source.waitUntilStarted()
    source.emit(
      samples: Array(repeating: 0.1, count: 1_600),
      cumulativeRMS: [0.016]
    )
    await Task.yield()
    let phasesBeforeCalibrationCompleted = await snapshots.phases
    XCTAssertFalse(phasesBeforeCalibrationCompleted.contains(.recording))
    source.emit(
      samples: Array(repeating: 0.01, count: 3_200),
      cumulativeRMS: [0.016, 0.005, 0.016]
    )
    try await startTask.value
    source.emit(
      samples: Array(repeating: 0.1, count: 27_200),
      cumulativeRMS: [0.016, 0.005, 0.016, 0.016, 0.016]
        + Array(repeating: 0.005, count: 15)
    )

    let terminal = await terminalTask.value
    XCTAssertEqual(terminal?.reason, .speechEnded)
    XCTAssertEqual(terminal?.acousticSummary.observedSegmentCount, 19)
    XCTAssertEqual(terminal?.acousticSummary.observedDurationMilliseconds, 1_900)
    let capturedAudio = try await runtime.finishCaptureDeferred(for: request).value()
    defer { _ = try? capturedAudio.removeManagedTemporaryFile() }
    XCTAssertGreaterThan(capturedAudio.durationSeconds, 0.3)
  }

  func testWakeCaptureKeepsOnlyTwoHundredMillisecondsBeforeFirstSpeech() async throws {
    let source = TestLocalSpeechAudioCaptureSource()
    let voiceActivityDetector = TestLocalSpeechVoiceActivityDetector([
      .observations(Self.silenceObservations(count: 1)),
      .observations(Self.speechObservations(count: 1)),
    ])
    let runID = UUID()
    let writer = try TestLocalSpeechRecordingWriter(
      fileURL: makeLocalSpeechOutputURL(runID: runID),
      failure: .none
    )
    let speechStarted = LocalSpeechCallbackCounter()
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source },
      recordingWriterFactory: { _, _ in writer },
      voiceActivityDetectorFactory: { _ in voiceActivityDetector },
      wakeWordSpeechStartedHandler: {
        speechStarted.increment()
      }
    )
    let endpointControl = AudioCaptureEndpointControl(
      runID: runID,
      policy: .shortDictation
    )
    let request = makeLocalSpeechRequest(
      runID: runID,
      endpointControl: endpointControl,
      triggerBinding: .wakeWord
    )

    let startTask = Task { try await runtime.startCapture(request: request) }
    try await source.waitUntilStarted()
    source.emit(
      samples: Array(repeating: 0.001, count: 4_800),
      cumulativeRMS: [0.005]
    )
    try await startTask.value
    XCTAssertEqual(writer.frameCount, 0)

    source.emit(
      samples: Array(repeating: 0.1, count: 1_600),
      cumulativeRMS: [0.005, 0.016]
    )
    try await writer.waitUntilFrameCount(3_200)

    let capturedAudio = try await runtime.finishCaptureDeferred(for: request).value()
    defer { _ = try? capturedAudio.removeManagedTemporaryFile() }
    XCTAssertEqual(speechStarted.value, 1)
    XCTAssertEqual(capturedAudio.durationSeconds, 0.2, accuracy: 0.0001)
  }

  func testStreamFailureBeforeFirstBufferFailsTypedAndStopsSource() async throws {
    let source = TestLocalSpeechAudioCaptureSource()
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source }
    )
    let request = makeLocalSpeechRequest()

    let startTask = Task { try await runtime.startCapture(request: request) }
    try await source.waitUntilStarted()
    source.fail(TestLocalSpeechFailure.stream)

    do {
      try await startTask.value
      XCTFail("Expected a typed microphone start failure.")
    } catch {
      XCTAssertEqual(
        error as? RealtimeAudioCaptureService.CaptureError,
        .microphoneStartFailed
      )
    }
    XCTAssertGreaterThanOrEqual(source.stopCount, 1)
  }

  func testRecordingWriterAppendFailureStopsAndRemovesPartialPlaintextFile() async throws {
    let source = TestLocalSpeechAudioCaptureSource()
    let cleanupProbe = LocalSpeechCleanupRemovalProbe()
    let cleanupOwner = ManagedTemporaryAudioCleanupOwner(
      removal: { try await cleanupProbe.remove($0) }
    )
    let runID = UUID()
    let outputURL = makeLocalSpeechOutputURL(runID: runID)
    let writer = try TestLocalSpeechRecordingWriter(
      fileURL: outputURL,
      failure: .append
    )
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source },
      recordingWriterFactory: { _, _ in writer },
      cleanupOwner: cleanupOwner
    )
    let request = makeLocalSpeechRequest(runID: runID)

    let startTask = Task { try await runtime.startCapture(request: request) }
    try await source.waitUntilStarted()
    source.emit(
      samples: Array(repeating: 0.2, count: 4_800),
      cumulativeRMS: [0.005, 0.005, 0.005]
    )
    do {
      try await startTask.value
      XCTFail("An incremental writer failure must reject capture readiness.")
    } catch {
      XCTAssertEqual(
        error as? RealtimeAudioCaptureService.CaptureError,
        .microphoneStartFailed
      )
    }

    let removedURLs = await cleanupProbe.removedURLs
    XCTAssertEqual(removedURLs, [outputURL])
    XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    XCTAssertEqual(source.stopCount, 1)
    XCTAssertEqual(writer.closeCount, 1)
  }

  func testStreamFailureAfterReadinessBeforeRecordingCommitCannotBeSwallowed() async throws {
    let source = TestLocalSpeechAudioCaptureSource()
    let snapshots = LocalSpeechSnapshotProbe()
    let unexpectedTermination = LocalSpeechUnexpectedTerminationProbe()
    let raceGate = LocalSpeechStartupRaceGate()
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source },
      liveUpdateHandler: { await snapshots.append($0) },
      unexpectedTerminationHandler: {
        await unexpectedTermination.record()
      },
      readinessCommitHook: {
        await raceGate.pauseBeforeRecordingCommit()
      },
      startupTerminationRecordedHook: {
        await raceGate.recordStartupTermination()
      }
    )
    let request = makeLocalSpeechRequest()

    let startTask = Task { try await runtime.startCapture(request: request) }
    try await source.waitUntilStarted()
    source.emit(
      samples: Array(repeating: 0.2, count: 4_800),
      cumulativeRMS: [0.005, 0.005, 0.005]
    )
    await raceGate.waitUntilRecordingCommitPaused()

    source.fail(AppleVoiceProcessingAudioError.streamBufferOverflow)
    await raceGate.waitUntilStartupTerminationRecorded()
    await raceGate.releaseRecordingCommit()

    do {
      try await startTask.value
      XCTFail("A stream that terminated before commit must not report recording readiness.")
    } catch {
      XCTAssertEqual(
        error as? RealtimeAudioCaptureService.CaptureError,
        .microphoneStartFailed
      )
    }

    let phases = await snapshots.phases
    let unexpectedTerminationCount = await unexpectedTermination.recordCount
    XCTAssertFalse(phases.contains(.recording))
    XCTAssertEqual(phases.filter { $0 == .hidden }.count, 1)
    XCTAssertEqual(unexpectedTerminationCount, 0)
    XCTAssertEqual(source.stopCount, 1)
  }

  func testStreamOverflowAfterReadinessSignalsUnexpectedTerminationExactlyOnce() async throws {
    let source = TestLocalSpeechAudioCaptureSource()
    let snapshots = LocalSpeechSnapshotProbe()
    let voiceActivityDetector = TestLocalSpeechVoiceActivityDetector([
      .observations(Self.silenceObservations(count: 3)),
      .observations(
        Self.speechObservations(count: 3)
          + Self.silenceObservations(count: 15)
      ),
    ])
    let unexpectedTermination = LocalSpeechUnexpectedTerminationProbe()
    let runID = UUID()
    let endpointControl = AudioCaptureEndpointControl(
      runID: runID,
      policy: .shortDictation
    )
    let terminalStream = try XCTUnwrap(endpointControl.claimStream())
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source },
      voiceActivityDetectorFactory: { _ in voiceActivityDetector },
      liveUpdateHandler: { await snapshots.append($0) },
      unexpectedTerminationHandler: {
        await unexpectedTermination.record()
      }
    )
    let request = makeLocalSpeechRequest(runID: runID, endpointControl: endpointControl)
    let terminalTask = Task<AudioCaptureTerminalSignal?, Never> {
      for await signal in terminalStream { return signal }
      return nil
    }

    let startTask = Task { try await runtime.startCapture(request: request) }
    try await source.waitUntilStarted()
    source.emit(
      samples: Array(repeating: 0.001, count: 4_800),
      cumulativeRMS: [0.005, 0.005, 0.005]
    )
    try await startTask.value

    source.fail(
      AppleVoiceProcessingAudioError.streamBufferOverflow,
      afterBuffering: Array(repeating: 0.1, count: 28_800),
      cumulativeRMS: Array(repeating: 0.005, count: 21)
    )
    source.fail(AppleVoiceProcessingAudioError.inputConfigurationChanged)

    await unexpectedTermination.waitUntilRecorded()
    endpointControl.finish()
    let terminal = await terminalTask.value
    let unexpectedTerminationCount = await unexpectedTermination.recordCount
    let phases = await snapshots.phases
    XCTAssertNil(terminal)
    XCTAssertEqual(unexpectedTerminationCount, 1)
    XCTAssertEqual(phases.filter { $0 == .failed }.count, 0)
    XCTAssertEqual(voiceActivityDetector.acceptedSampleCounts, [4_800])
    XCTAssertEqual(voiceActivityDetector.resetCount, 2)
    XCTAssertEqual(source.stopCount, 1)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: makeLocalSpeechOutputURL(runID: runID).path)
    )
  }

  func testManualFinishAfterStreamOverflowFailsBeforeWritingTruncatedAudio() async throws {
    let source = TestLocalSpeechAudioCaptureSource()
    let voiceActivityDetector = TestLocalSpeechVoiceActivityDetector([
      .observations(Self.silenceObservations(count: 3))
    ])
    let unexpectedTermination = LocalSpeechUnexpectedTerminationProbe()
    let runID = UUID()
    let endpointControl = AudioCaptureEndpointControl(
      runID: runID,
      policy: .shortDictation
    )
    let terminalStream = try XCTUnwrap(endpointControl.claimStream())
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source },
      voiceActivityDetectorFactory: { _ in voiceActivityDetector },
      unexpectedTerminationHandler: {
        await unexpectedTermination.record()
      }
    )
    let request = makeLocalSpeechRequest(runID: runID, endpointControl: endpointControl)
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-local-\(runID.uuidString)")
      .appendingPathExtension("wav")
    try? FileManager.default.removeItem(at: outputURL)
    defer { try? FileManager.default.removeItem(at: outputURL) }
    let terminalTask = Task<AudioCaptureTerminalSignal?, Never> {
      for await signal in terminalStream { return signal }
      return nil
    }

    let startTask = Task { try await runtime.startCapture(request: request) }
    try await source.waitUntilStarted()
    source.emit(
      samples: Array(repeating: 0.001, count: 4_800),
      cumulativeRMS: [0.005, 0.005, 0.005]
    )
    try await startTask.value

    source.markTerminalFailure(.streamBufferOverflow)
    do {
      _ = try await runtime.finishCaptureDeferred(for: request)
      XCTFail("A failed PCM stream must not publish truncated captured audio.")
    } catch {
      XCTAssertEqual(
        error as? AppleVoiceProcessingAudioError,
        .streamBufferOverflow
      )
    }

    endpointControl.finish()
    let terminal = await terminalTask.value
    let unexpectedTerminationCount = await unexpectedTermination.recordCount
    XCTAssertNil(terminal)
    XCTAssertEqual(unexpectedTerminationCount, 0)
    XCTAssertEqual(voiceActivityDetector.acceptedSampleCounts, [4_800])
    XCTAssertEqual(voiceActivityDetector.resetCount, 2)
    XCTAssertEqual(source.stopCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
  }

  func testManualFinishWinsAgainstAConcurrentPCMInactivityWake() async throws {
    let source = TestLocalSpeechAudioCaptureSource()
    let sleeper = ManualLocalSpeechPCMInactivitySleeper()
    let unexpectedTermination = LocalSpeechUnexpectedTerminationProbe()
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source },
      pcmInactivityTimeout: .seconds(2),
      pcmInactivitySleep: { _ in await sleeper.sleep() },
      unexpectedTerminationHandler: {
        await unexpectedTermination.record()
      }
    )
    let request = makeLocalSpeechRequest()

    let startTask = Task { try await runtime.startCapture(request: request) }
    try await source.waitUntilStarted()
    source.emit(
      samples: Array(repeating: 0.2, count: 4_800),
      cumulativeRMS: [0.2, 0.2, 0.2]
    )
    try await startTask.value
    await sleeper.waitUntilCallCount(1)

    let finishTask = Task { try await runtime.finishCaptureDeferred(for: request) }
    try await source.waitUntilStopCount(1)
    await sleeper.releaseNext()
    let capturedAudio = try await finishTask.value.value()
    defer { _ = try? capturedAudio.removeManagedTemporaryFile() }

    await Task.yield()
    let unexpectedTerminationCount = await unexpectedTermination.recordCount
    XCTAssertEqual(unexpectedTerminationCount, 0)
    XCTAssertGreaterThan(capturedAudio.durationSeconds, 0)
  }

  func testRecordingWriterFinalizeFailureRemovesClosedPlaintextFile() async throws {
    let source = TestLocalSpeechAudioCaptureSource()
    let cleanupProbe = LocalSpeechCleanupRemovalProbe()
    let cleanupOwner = ManagedTemporaryAudioCleanupOwner(
      removal: { try await cleanupProbe.remove($0) }
    )
    let runID = UUID()
    let outputURL = makeLocalSpeechOutputURL(runID: runID)
    let writer = try TestLocalSpeechRecordingWriter(
      fileURL: outputURL,
      failure: .finalize
    )
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source },
      recordingWriterFactory: { _, _ in writer },
      cleanupOwner: cleanupOwner
    )
    let request = makeLocalSpeechRequest(runID: runID)

    let startTask = Task { try await runtime.startCapture(request: request) }
    try await source.waitUntilStarted()
    source.emit(
      samples: Array(repeating: 0.2, count: 4_800),
      cumulativeRMS: [0.005, 0.005, 0.005]
    )
    try await startTask.value

    do {
      _ = try await runtime.finishCaptureDeferred(for: request)
      XCTFail("A finalize failure must not return a managed audio artifact.")
    } catch {
      XCTAssertEqual(error as? TestLocalSpeechFailure, .writerFinalize)
    }

    let removedURLs = await cleanupProbe.removedURLs
    XCTAssertEqual(removedURLs, [outputURL])
    XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    XCTAssertEqual(source.stopCount, 1)
    XCTAssertEqual(writer.closeCount, 1)
  }

  func testStaleFinishCannotHideAReplacementRunStreamFailure() async throws {
    let source = TestLocalSpeechAudioCaptureSource()
    let unexpectedTermination = LocalSpeechUnexpectedTerminationProbe()
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source },
      unexpectedTerminationHandler: {
        await unexpectedTermination.record()
      }
    )
    let firstRequest = makeLocalSpeechRequest()
    let firstStart = Task { try await runtime.startCapture(request: firstRequest) }
    try await source.waitUntilStartCount(1)
    source.emit(
      samples: Array(repeating: 0.001, count: 4_800),
      cumulativeRMS: [0.005, 0.005, 0.005]
    )
    try await firstStart.value
    await runtime.cancelCapture(for: firstRequest)

    let secondRequest = makeLocalSpeechRequest()
    let secondStart = Task { try await runtime.startCapture(request: secondRequest) }
    try await source.waitUntilStartCount(2)
    source.emit(
      samples: Array(repeating: 0.001, count: 4_800),
      cumulativeRMS: [0.005, 0.005, 0.005]
    )
    try await secondStart.value

    do {
      _ = try await runtime.finishCaptureDeferred(for: firstRequest)
      XCTFail("A stale run must not claim the replacement capture's finish boundary.")
    } catch {
      XCTAssertEqual(
        error as? RealtimeAudioCaptureService.CaptureError,
        .notCapturing
      )
    }

    source.markTerminalFailure(.streamBufferOverflow)
    do {
      _ = try await runtime.finishCaptureDeferred(for: secondRequest)
      XCTFail("The replacement run must retain its producer-failure state.")
    } catch {
      XCTAssertEqual(
        error as? AppleVoiceProcessingAudioError,
        .streamBufferOverflow
      )
    }
    let unexpectedTerminationCount = await unexpectedTermination.recordCount
    XCTAssertEqual(unexpectedTerminationCount, 0)
    XCTAssertEqual(source.stopCount, 2)
  }

  func testVoiceActivitySilenceSignalsInitialTimeout() async throws {
    let source = TestLocalSpeechAudioCaptureSource()
    let voiceActivityDetector = TestLocalSpeechVoiceActivityDetector([
      .observations(Self.silenceObservations(count: 3)),
      .observations(Self.silenceObservations(count: 117)),
    ])
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source },
      voiceActivityDetectorFactory: { _ in voiceActivityDetector }
    )
    let runID = UUID()
    let endpointControl = AudioCaptureEndpointControl(
      runID: runID,
      policy: .shortDictation
    )
    let terminalStream = try XCTUnwrap(endpointControl.claimStream())
    let request = makeLocalSpeechRequest(runID: runID, endpointControl: endpointControl)

    let terminalTask = Task<AudioCaptureTerminalSignal?, Never> {
      for await signal in terminalStream { return signal }
      return nil
    }
    let startTask = Task { try await runtime.startCapture(request: request) }
    try await source.waitUntilStarted()
    source.emit(
      samples: Array(repeating: 0.001, count: 4_800),
      cumulativeRMS: [0.005, 0.005, 0.005]
    )
    try await startTask.value
    source.emit(
      samples: Array(repeating: 0, count: 187_200),
      cumulativeRMS: Array(repeating: 0.005, count: 120)
    )

    let terminal = await terminalTask.value
    XCTAssertEqual(terminal?.reason, .initialSilenceTimedOut)
    XCTAssertEqual(terminal?.acousticSummary.observedDurationMilliseconds, 12_000)
    XCTAssertEqual(terminal?.acousticSummary.aboveThresholdDurationMilliseconds, 0)
    XCTAssertLessThan(terminal?.acousticSummary.peakLevelPercentBucket ?? 100, 30)
    await runtime.cancelCapture(for: request)
  }

  func testAllZeroStreamNeverBecomesReadyAndTimesOut() async throws {
    let source = TestLocalSpeechAudioCaptureSource()
    let timeoutGate = LocalSpeechReadinessTimeoutGate()
    let runID = UUID()
    let outputURL = makeLocalSpeechOutputURL(runID: runID)
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source },
      readinessSleep: { _ in await timeoutGate.wait() }
    )
    let request = makeLocalSpeechRequest(runID: runID)

    let startTask = Task { try await runtime.startCapture(request: request) }
    try await source.waitUntilStarted()
    source.emit(
      samples: Array(repeating: 0, count: 8_000),
      cumulativeRMS: Array(repeating: 0, count: 5)
    )
    await timeoutGate.release()

    do {
      try await startTask.value
      XCTFail("A digital-zero stream must not be reported as a ready microphone.")
    } catch {
      XCTAssertEqual(
        error as? RealtimeAudioCaptureService.CaptureError,
        .microphoneStartTimedOut
      )
    }
    XCTAssertGreaterThanOrEqual(source.stopCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
  }

  func testVoiceActivityFactoryFailureDoesNotStartAudioSource() async {
    let source = TestLocalSpeechAudioCaptureSource()
    let endpointControl = AudioCaptureEndpointControl(
      runID: UUID(),
      policy: .shortDictation
    )
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source },
      voiceActivityDetectorFactory: { _ in
        throw TestLocalSpeechFailure.voiceActivity
      }
    )
    let request = makeLocalSpeechRequest(
      runID: endpointControl.runID,
      endpointControl: endpointControl
    )

    do {
      try await runtime.startCapture(request: request)
      XCTFail("A failed VAD factory must reject capture startup.")
    } catch {
      XCTAssertEqual(
        error as? RealtimeAudioCaptureService.CaptureError,
        .voiceActivityDetectionUnavailable
      )
    }
    XCTAssertEqual(source.startCount, 0)
  }

  func testVoiceActivityFailureAfterReadinessTerminatesAndClearsDetector() async throws {
    let source = TestLocalSpeechAudioCaptureSource()
    let voiceActivityDetector = TestLocalSpeechVoiceActivityDetector([
      .observations(Self.silenceObservations(count: 3)),
      .failure,
    ])
    let unexpectedTermination = LocalSpeechUnexpectedTerminationProbe()
    let runID = UUID()
    let endpointControl = AudioCaptureEndpointControl(
      runID: runID,
      policy: .shortDictation
    )
    let terminalStream = try XCTUnwrap(endpointControl.claimStream())
    let runtime = LocalSpeechVoiceCaptureRuntime(
      permissionRequester: { true },
      sourceFactory: { source },
      voiceActivityDetectorFactory: { _ in voiceActivityDetector },
      unexpectedTerminationHandler: {
        await unexpectedTermination.record()
      }
    )
    let request = makeLocalSpeechRequest(runID: runID, endpointControl: endpointControl)
    let terminalTask = Task<AudioCaptureTerminalSignal?, Never> {
      for await signal in terminalStream { return signal }
      return nil
    }

    let startTask = Task { try await runtime.startCapture(request: request) }
    try await source.waitUntilStarted()
    source.emit(
      samples: Array(repeating: 0.001, count: 4_800),
      cumulativeRMS: [0.005, 0.005, 0.005]
    )
    try await startTask.value
    source.emit(
      samples: Array(repeating: 0.001, count: 1_600),
      cumulativeRMS: [0.005, 0.005, 0.005, 0.005]
    )

    await unexpectedTermination.waitUntilRecorded()
    endpointControl.finish()
    let terminal = await terminalTask.value
    XCTAssertNil(terminal)
    XCTAssertEqual(voiceActivityDetector.acceptedSampleCounts, [4_800, 1_600])
    XCTAssertEqual(voiceActivityDetector.resetCount, 2)
    XCTAssertGreaterThanOrEqual(source.stopCount, 1)
  }

  func testReadinessDetectorRequiresOneFiniteNonZeroUsableFrame() {
    var detector = LocalSpeechInputReadinessDetector()

    XCTAssertEqual(
      detector.observe(
        samples: Array(
          repeating: 0,
          count: LocalSpeechInputReadinessDetector.minimumUsableFrameSampleCount
        )
      ),
      .waiting
    )
    XCTAssertEqual(detector.observe(samples: [.nan]), .invalid)

    detector = LocalSpeechInputReadinessDetector()
    XCTAssertEqual(
      detector.observe(
        samples: Array(
          repeating: 0.001,
          count: LocalSpeechInputReadinessDetector.minimumUsableFrameSampleCount - 1
        )
      ),
      .waiting
    )
    XCTAssertEqual(detector.observe(samples: [0.001]), .ready)
    XCTAssertEqual(detector.observe(samples: [0]), .ready)
  }

  private static func speechObservations(
    count: Int
  ) -> [LocalSpeechVoiceActivityObservation] {
    Array(
      repeating: LocalSpeechVoiceActivityObservation(
        isSpeech: true,
        durationSeconds: 0.1,
        normalizedRMS: 0.014
      ),
      count: count
    )
  }

  private static func silenceObservations(
    count: Int,
    normalizedRMS: Float = 0.005
  ) -> [LocalSpeechVoiceActivityObservation] {
    Array(
      repeating: LocalSpeechVoiceActivityObservation(
        isSpeech: false,
        durationSeconds: 0.1,
        normalizedRMS: normalizedRMS
      ),
      count: count
    )
  }
}

private enum TestLocalSpeechFailure: Error, Equatable {
  case stream
  case voiceActivity
  case writerInitialization
  case writerAppend
  case writerFinalize
  case timeout
}

private final class TestLocalSpeechStreamingPreviewSession:
  LocalSpeechStreamingPreviewSession,
  @unchecked Sendable
{
  enum Result {
    case success(String)
    case failure
  }

  private let lock = NSLock()
  private var results: [Result]
  private let finishResult: Result
  private var acceptedCounts: [Int] = []

  init(results: [Result], finishResult: Result = .success("")) {
    self.results = results
    self.finishResult = finishResult
  }

  var acceptedSampleCounts: [Int] {
    lock.withLock { acceptedCounts }
  }

  func waitUntilAcceptedSampleCount(_ expectedCount: Int) async throws {
    for _ in 0..<2_000 {
      if acceptedSampleCounts.count >= expectedCount { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Timed out waiting for the streaming preview session.")
    throw TestLocalSpeechFailure.timeout
  }

  func accept(samples: [Float]) throws -> String {
    try lock.withLock {
      acceptedCounts.append(samples.count)
      guard !results.isEmpty else { return "" }
      switch results.removeFirst() {
      case .success(let text):
        return text
      case .failure:
        throw TestLocalSpeechFailure.stream
      }
    }
  }

  func finish() throws -> String {
    switch finishResult {
    case .success(let text):
      text
    case .failure:
      throw TestLocalSpeechFailure.stream
    }
  }
}

private final class TestLocalSpeechRecordingWriter: LocalSpeechRecordingWriting,
  @unchecked Sendable
{
  enum Failure: Equatable {
    case none
    case append
    case finalize
  }

  let fileURL: URL

  private let failure: Failure
  private let lock = NSLock()
  private var storedFrameCount = 0
  private var isClosed = false
  private var storedCloseCount = 0
  private var storedRemoveFrameLimitCount = 0

  init(fileURL: URL, failure: Failure) throws {
    self.fileURL = fileURL
    self.failure = failure
    try Data().write(to: fileURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: fileURL.path
    )
  }

  var closeCount: Int {
    lock.withLock { storedCloseCount }
  }

  var removeFrameLimitCount: Int {
    lock.withLock { storedRemoveFrameLimitCount }
  }

  var frameCount: Int {
    lock.withLock { storedFrameCount }
  }

  func waitUntilFrameCount(_ expectedCount: Int) async throws {
    for _ in 0..<2_000 {
      if frameCount >= expectedCount { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Timed out waiting for the recording writer.")
    throw TestLocalSpeechFailure.timeout
  }

  func removeFrameLimit() {
    lock.withLock {
      storedRemoveFrameLimitCount += 1
    }
  }

  func append(_ samples: [Float]) throws {
    try lock.withLock {
      guard !isClosed else { throw TestLocalSpeechFailure.writerAppend }
      if failure == .append {
        throw TestLocalSpeechFailure.writerAppend
      }
      storedFrameCount += samples.count
    }
  }

  func finalize() throws -> LocalSpeechRecordingArtifact {
    try lock.withLock {
      guard !isClosed else { throw TestLocalSpeechFailure.writerFinalize }
      if failure == .finalize {
        throw TestLocalSpeechFailure.writerFinalize
      }
      isClosed = true
      return LocalSpeechRecordingArtifact(fileURL: fileURL, frameCount: storedFrameCount)
    }
  }

  func closeForDiscard() {
    lock.withLock {
      guard !isClosed else { return }
      isClosed = true
      storedCloseCount += 1
    }
  }
}

private final class LocalSpeechWriterFactoryProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var storedFrameLimits: [Int?] = []

  var frameLimits: [Int?] {
    lock.withLock { storedFrameLimits }
  }

  func record(frameLimit: Int?) {
    lock.withLock {
      storedFrameLimits.append(frameLimit)
    }
  }
}

private final class TestLocalSpeechVoiceActivityDetector: LocalSpeechVoiceActivityDetector,
  @unchecked Sendable
{
  enum Batch {
    case observations([LocalSpeechVoiceActivityObservation])
    case failure
  }

  private let lock = NSLock()
  private var batches: [Batch]
  private var acceptedCounts: [Int] = []
  private var resets = 0

  init(_ batches: [Batch]) {
    self.batches = batches
  }

  var acceptedSampleCounts: [Int] {
    lock.withLock { acceptedCounts }
  }

  var resetCount: Int {
    lock.withLock { resets }
  }

  func accept(samples: [Float]) throws -> [LocalSpeechVoiceActivityObservation] {
    try lock.withLock {
      acceptedCounts.append(samples.count)
      guard !batches.isEmpty else { return [] }
      switch batches.removeFirst() {
      case .observations(let observations):
        return observations
      case .failure:
        throw TestLocalSpeechFailure.voiceActivity
      }
    }
  }

  func reset() {
    lock.withLock {
      resets += 1
    }
  }
}

private final class LocalSpeechVoiceActivityThresholdProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Float] = []

  var thresholds: [Float] {
    lock.withLock { values }
  }

  func record(_ threshold: Float) {
    lock.withLock {
      values.append(threshold)
    }
  }
}

final class TestLocalSpeechAudioCaptureSource: LocalSpeechAudioCaptureSource,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var continuation: AsyncThrowingStream<[Float], Error>.Continuation?
  private var terminalState: AppleVoiceProcessingPCMStreamTerminalState?
  private var rms: [Float] = []
  private var preparations = 0
  private var starts = 0
  private var stops = 0
  private var shutdowns = 0
  private var preparationError: Error?

  var endpointRMS: [Float] {
    lock.withLock { rms }
  }

  var startCount: Int {
    lock.withLock { starts }
  }

  var prepareCount: Int {
    lock.withLock { preparations }
  }

  var stopCount: Int {
    lock.withLock { stops }
  }

  var shutdownCount: Int {
    lock.withLock { shutdowns }
  }

  func prepareStoppedFrontend() throws {
    let error = lock.withLock { () -> Error? in
      preparations += 1
      return preparationError
    }
    if let error { throw error }
  }

  func setPreparationError(_ error: Error?) {
    lock.withLock {
      preparationError = error
    }
  }

  func startStreaming() -> LocalSpeechAudioStream {
    let pair = AsyncThrowingStream<[Float], Error>.makeStream(bufferingPolicy: .unbounded)
    let terminalState = AppleVoiceProcessingPCMStreamTerminalState()
    lock.withLock {
      starts += 1
      continuation = pair.continuation
      self.terminalState = terminalState
    }
    return LocalSpeechAudioStream(
      stream: pair.stream,
      continuation: pair.continuation,
      terminalState: terminalState
    )
  }

  func stop() {
    let continuation = lock.withLock { () -> AsyncThrowingStream<[Float], Error>.Continuation? in
      stops += 1
      return self.continuation
    }
    continuation?.finish()
  }

  func shutdown() {
    lock.withLock {
      shutdowns += 1
    }
  }

  func emit(samples newSamples: [Float], cumulativeRMS: [Float]) {
    let continuation = lock.withLock { () -> AsyncThrowingStream<[Float], Error>.Continuation? in
      rms = cumulativeRMS
      return self.continuation
    }
    continuation?.yield(newSamples)
  }

  func fail(_ error: Error) {
    let (continuation, terminalState) = lock.withLock {
      (self.continuation, self.terminalState)
    }
    _ = terminalState?.claimProducerFailure(
      error as? AppleVoiceProcessingAudioError ?? .inputConfigurationChanged
    )
    continuation?.finish(throwing: error)
  }

  func fail(
    _ error: AppleVoiceProcessingAudioError,
    afterBuffering bufferedSamples: [Float],
    cumulativeRMS: [Float]
  ) {
    let (continuation, terminalState) = lock.withLock {
      rms = cumulativeRMS
      return (self.continuation, self.terminalState)
    }
    _ = terminalState?.claimProducerFailure(error)
    continuation?.yield(bufferedSamples)
    continuation?.finish(throwing: error)
  }

  func markTerminalFailure(_ error: AppleVoiceProcessingAudioError) {
    let terminalState = lock.withLock { self.terminalState }
    _ = terminalState?.claimProducerFailure(error)
  }

  func waitUntilStarted() async throws {
    try await waitUntilStartCount(1)
  }

  func waitUntilStartCount(_ expectedCount: Int) async throws {
    for _ in 0..<2_000 {
      if startCount >= expectedCount { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Timed out waiting for the capture source to start.")
    throw TestLocalSpeechFailure.timeout
  }

  func waitUntilStopCount(_ expectedCount: Int) async throws {
    for _ in 0..<2_000 {
      if stopCount >= expectedCount { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Timed out waiting for the capture source to stop.")
    throw TestLocalSpeechFailure.timeout
  }
}

private actor LocalSpeechReadinessTimeoutGate {
  private var isReleased = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isReleased else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    isReleased = true
    let currentWaiters = waiters
    waiters.removeAll()
    for waiter in currentWaiters {
      waiter.resume()
    }
  }
}

private actor LocalSpeechPermissionRaceGate {
  private var requestCount = 0
  private var firstRequestContinuation: CheckedContinuation<Bool, Never>?
  private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []

  func requestPermission() async -> Bool {
    requestCount += 1
    guard requestCount == 1 else { return true }
    let currentWaiters = firstRequestWaiters
    firstRequestWaiters.removeAll()
    for waiter in currentWaiters {
      waiter.resume()
    }
    return await withCheckedContinuation { firstRequestContinuation = $0 }
  }

  func waitUntilFirstRequest() async {
    guard requestCount == 0 else { return }
    await withCheckedContinuation { firstRequestWaiters.append($0) }
  }

  func resolveFirstRequest(granted: Bool) {
    firstRequestContinuation?.resume(returning: granted)
    firstRequestContinuation = nil
  }
}

private actor LocalSpeechStartupRaceGate {
  private var isRecordingCommitPaused = false
  private var isStartupTerminationRecorded = false
  private var recordingCommitContinuation: CheckedContinuation<Void, Never>?
  private var recordingCommitWaiters: [CheckedContinuation<Void, Never>] = []
  private var startupTerminationWaiters: [CheckedContinuation<Void, Never>] = []

  func pauseBeforeRecordingCommit() async {
    isRecordingCommitPaused = true
    let currentWaiters = recordingCommitWaiters
    recordingCommitWaiters.removeAll()
    for waiter in currentWaiters {
      waiter.resume()
    }
    await withCheckedContinuation { recordingCommitContinuation = $0 }
  }

  func waitUntilRecordingCommitPaused() async {
    guard !isRecordingCommitPaused else { return }
    await withCheckedContinuation { recordingCommitWaiters.append($0) }
  }

  func recordStartupTermination() {
    isStartupTerminationRecorded = true
    let currentWaiters = startupTerminationWaiters
    startupTerminationWaiters.removeAll()
    for waiter in currentWaiters {
      waiter.resume()
    }
  }

  func waitUntilStartupTerminationRecorded() async {
    guard !isStartupTerminationRecorded else { return }
    await withCheckedContinuation { startupTerminationWaiters.append($0) }
  }

  func releaseRecordingCommit() {
    recordingCommitContinuation?.resume()
    recordingCommitContinuation = nil
  }
}

private actor LocalSpeechRecordingPublishGate {
  private var recordingPublishCount = 0
  private var isSecondPublishBlocked = false
  private var shouldReleaseSecondPublish = false
  private var secondPublishContinuation: CheckedContinuation<Void, Never>?
  private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

  func observe(_ snapshot: LiveSubtitleSnapshot) async {
    guard snapshot.phase == .recording else { return }
    recordingPublishCount += 1
    guard recordingPublishCount == 2 else { return }
    isSecondPublishBlocked = true
    let currentWaiters = blockedWaiters
    blockedWaiters.removeAll()
    for waiter in currentWaiters {
      waiter.resume()
    }
    guard !shouldReleaseSecondPublish else { return }
    await withCheckedContinuation { secondPublishContinuation = $0 }
  }

  func waitUntilSecondRecordingPublishIsBlocked() async {
    guard !isSecondPublishBlocked else { return }
    await withCheckedContinuation { blockedWaiters.append($0) }
  }

  func releaseSecondRecordingPublish() {
    shouldReleaseSecondPublish = true
    secondPublishContinuation?.resume()
    secondPublishContinuation = nil
  }
}

private actor LocalSpeechCleanupRemovalProbe {
  private(set) var removedURLs: [URL] = []

  func remove(_ fileURL: URL) throws {
    removedURLs.append(fileURL)
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    try FileManager.default.removeItem(at: fileURL)
  }
}

private actor LocalSpeechSnapshotProbe {
  private var snapshots: [LiveSubtitleSnapshot] = []

  func append(_ snapshot: LiveSubtitleSnapshot) {
    snapshots.append(snapshot)
  }

  var phases: [LiveSubtitlePhase] {
    snapshots.map(\.phase)
  }

  var values: [LiveSubtitleSnapshot] {
    snapshots
  }
}

private actor LocalSpeechUnexpectedTerminationProbe {
  private(set) var recordCount = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func record() {
    recordCount += 1
    let currentWaiters = waiters
    waiters.removeAll()
    for waiter in currentWaiters {
      waiter.resume()
    }
  }

  func waitUntilRecorded() async {
    guard recordCount == 0 else { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}

private func makeLocalSpeechRequest(
  runID: UUID = UUID(),
  endpointControl: AudioCaptureEndpointControl? = nil,
  audioLifetime: AudioCaptureLifetime? = nil,
  maxDurationSeconds: Double? = nil,
  canRemoveMaxDurationLimit: Bool = false,
  triggerBinding: TriggerBinding = .hotkey
) -> AudioCaptureRequest {
  AudioCaptureRequest(
    runID: runID,
    workflow: WorkflowDefinition(
      name: "Local speech",
      trigger: triggerBinding,
      pipeline: PipelineDeclaration(
        recognizerID: "sherpa-onnx.local",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "teal")
    ),
    triggerEvent:
      triggerBinding == .wakeWord
      ? WorkflowTriggerEvent(
        id: runID,
        binding: triggerBinding,
        sourceID: "test"
      )
      : nil,
    maxDurationSeconds: maxDurationSeconds,
    canRemoveMaxDurationLimit: canRemoveMaxDurationLimit,
    endpointControl: endpointControl,
    audioLifetime: audioLifetime
  )
}

private final class LocalSpeechCallbackCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.withLock { count }
  }

  func increment() {
    lock.withLock { count += 1 }
  }
}

private func makeLocalSpeechOutputURL(runID: UUID) -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("rill-local-\(runID.uuidString)")
    .appendingPathExtension("wav")
}

private func readLocalSpeechWaveSamples(from url: URL) throws -> [Float] {
  let file = try AVAudioFile(forReading: url)
  let frameCount = AVAudioFrameCount(file.length)
  let buffer = try XCTUnwrap(
    AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)
  )
  try file.read(into: buffer)
  let channel = try XCTUnwrap(buffer.floatChannelData?.pointee)
  return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
}
