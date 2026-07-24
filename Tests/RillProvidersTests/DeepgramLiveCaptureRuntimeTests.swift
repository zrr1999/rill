import AVFoundation
import XCTest

@testable import RillCore
@testable import RillProviders

final class DeepgramLiveCaptureRuntimeTests: XCTestCase {
  func testLiveReadinessWaitsForFirstAcceptedBufferFromMatchingScope() async throws {
    let scope = DeepgramLiveCaptureReadinessGate.Scope(runID: UUID(), generation: 7)
    let gate = DeepgramLiveCaptureReadinessGate(scope: scope)
    let sleepProbe = DeepgramBlockingReadinessSleepProbe()
    let waitTask = Task {
      try await gate.wait(
        timeout: .seconds(60),
        sleep: { duration in
          try await sleepProbe.sleep(for: duration)
        }
      )
    }
    await sleepProbe.waitUntilStarted()

    let staleScope = DeepgramLiveCaptureReadinessGate.Scope(
      runID: scope.runID,
      generation: scope.generation + 1
    )
    let acceptedStaleScope = await gate.signalAcceptedBuffer(scope: staleScope)
    let acceptedCurrentScope = await gate.signalAcceptedBuffer(scope: scope)
    XCTAssertFalse(acceptedStaleScope)
    XCTAssertTrue(acceptedCurrentScope)

    try await waitTask.value
  }

  func testLiveReadinessReportsPipelineFailureBeforeFirstBuffer() async {
    let scope = DeepgramLiveCaptureReadinessGate.Scope(runID: UUID(), generation: 1)
    let gate = DeepgramLiveCaptureReadinessGate(scope: scope)
    await gate.signalPipelineFailure(scope: scope)

    do {
      try await gate.wait(timeout: .seconds(60), sleep: { try await Task.sleep(for: $0) })
      XCTFail("A failed chunk pipeline must reject capture startup.")
    } catch let failure as DeepgramLiveCaptureReadinessGate.Failure {
      XCTAssertEqual(failure, .pipelineFailed)
    } catch {
      XCTFail("Unexpected readiness error: \(error)")
    }
  }

  func testLiveReadinessRejectsPipelineThatEndsBeforeFirstBuffer() async {
    let scope = DeepgramLiveCaptureReadinessGate.Scope(runID: UUID(), generation: 1)
    let gate = DeepgramLiveCaptureReadinessGate(scope: scope)
    await gate.signalPipelineEndedBeforeReady(scope: scope)

    do {
      try await gate.wait(timeout: .seconds(60), sleep: { try await Task.sleep(for: $0) })
      XCTFail("A chunk pipeline that ends before its first buffer must reject startup.")
    } catch let failure as DeepgramLiveCaptureReadinessGate.Failure {
      XCTAssertEqual(failure, .pipelineEndedBeforeReady)
    } catch {
      XCTFail("Unexpected readiness error: \(error)")
    }
  }

  func testLiveReadinessTimeoutIsDeterministicAndTyped() async {
    let scope = DeepgramLiveCaptureReadinessGate.Scope(runID: UUID(), generation: 1)
    let gate = DeepgramLiveCaptureReadinessGate(scope: scope)

    do {
      try await gate.wait(timeout: .seconds(60), sleep: { _ in })
      XCTFail("A missing first buffer must time out capture startup.")
    } catch let failure as DeepgramLiveCaptureReadinessGate.Failure {
      XCTAssertEqual(failure, .timedOut)
    } catch {
      XCTFail("Unexpected readiness error: \(error)")
    }
  }

  func testLiveReadinessCancellationCannotBeRevivedByLateBuffer() async {
    let scope = DeepgramLiveCaptureReadinessGate.Scope(runID: UUID(), generation: 1)
    let gate = DeepgramLiveCaptureReadinessGate(scope: scope)
    let sleepProbe = DeepgramBlockingReadinessSleepProbe()
    let waitTask = Task {
      try await gate.wait(
        timeout: .seconds(60),
        sleep: { duration in
          try await sleepProbe.sleep(for: duration)
        }
      )
    }
    await sleepProbe.waitUntilStarted()

    waitTask.cancel()
    do {
      try await waitTask.value
      XCTFail("A cancelled startup must not become ready.")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Unexpected cancellation error: \(error)")
    }
    let acceptedLateBuffer = await gate.signalAcceptedBuffer(scope: scope)
    XCTAssertFalse(acceptedLateBuffer)
  }

  func testLiveEventsAndProjectionsRequireExactCurrentRunAndGeneration() {
    let runID = UUID()
    let staleRunID = UUID()
    let scope = DeepgramLiveCaptureReadinessGate.Scope(runID: runID, generation: 9)

    XCTAssertTrue(
      DeepgramLiveCaptureRuntime.acceptsLiveEvent(
        activeRunID: runID,
        activeGeneration: 9,
        eventScope: scope
      )
    )
    XCTAssertFalse(
      DeepgramLiveCaptureRuntime.acceptsLiveEvent(
        activeRunID: staleRunID,
        activeGeneration: 9,
        eventScope: scope
      )
    )
    XCTAssertFalse(
      DeepgramLiveCaptureRuntime.acceptsLiveEvent(
        activeRunID: runID,
        activeGeneration: 10,
        eventScope: scope
      )
    )
    XCTAssertFalse(
      DeepgramLiveCaptureRuntime.acceptsLiveProjection(
        activeRunID: runID,
        activeGeneration: 9,
        recordingGeneration: nil,
        projectionScope: scope
      ),
      "Startup projections must stay hidden before the first accepted audio buffer."
    )
    XCTAssertTrue(
      DeepgramLiveCaptureRuntime.acceptsLiveProjection(
        activeRunID: runID,
        activeGeneration: 9,
        recordingGeneration: 9,
        projectionScope: scope
      )
    )
    XCTAssertFalse(
      DeepgramLiveCaptureRuntime.acceptsLiveProjection(
        activeRunID: runID,
        activeGeneration: 10,
        recordingGeneration: 10,
        projectionScope: scope
      ),
      "A projection from an older capture generation must not revive on a reused run ID."
    )
  }

  func testUnexpectedTerminalGateRejectsStaleGenerationAndClaimsCurrentFailureOnce() {
    let runID = UUID()
    let currentScope = DeepgramLiveCaptureReadinessGate.Scope(
      runID: runID,
      generation: 12
    )
    let staleScope = DeepgramLiveCaptureReadinessGate.Scope(
      runID: runID,
      generation: 11
    )
    var gate = DeepgramLiveTerminalGate()

    XCTAssertFalse(
      gate.claim(
        activeRunID: runID,
        activeGeneration: 12,
        recordingGeneration: 12,
        eventScope: staleScope,
        isFinishing: false
      )
    )
    XCTAssertTrue(
      gate.claim(
        activeRunID: runID,
        activeGeneration: 12,
        recordingGeneration: 12,
        eventScope: currentScope,
        isFinishing: false
      )
    )
    XCTAssertFalse(
      gate.claim(
        activeRunID: runID,
        activeGeneration: 12,
        recordingGeneration: 12,
        eventScope: currentScope,
        isFinishing: false
      ),
      "Concurrent receive, conversion, and route failures must collapse to one terminal event."
    )
  }

  func testUnexpectedTerminalGateRejectsIntentionalFinish() {
    let runID = UUID()
    let scope = DeepgramLiveCaptureReadinessGate.Scope(runID: runID, generation: 3)
    var gate = DeepgramLiveTerminalGate()

    XCTAssertFalse(
      gate.claim(
        activeRunID: runID,
        activeGeneration: 3,
        recordingGeneration: 3,
        eventScope: scope,
        isFinishing: true
      )
    )
  }

  func testServiceOwnedFileTransfersToCleanupOwnerAndDrainsBeforeReturning() async throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-deepgram-live-cleanup-\(UUID().uuidString).wav")
    try Data([0x01, 0x02]).write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let probe = DeepgramCleanupHandoffProbe()
    let owner = ManagedTemporaryAudioCleanupOwner(
      removal: { try await probe.remove($0) }
    )
    let runtime = DeepgramLiveCaptureRuntime(
      liveUpdateHandler: { _ in },
      cleanupOwner: owner
    )

    let cleanup = Task {
      await runtime.removeServiceOwnedFile(fileURL, runID: UUID())
      await probe.recordCallerReturned()
    }
    await probe.waitUntilRemovalStarted()

    let suspendedSnapshot = await probe.snapshot()
    XCTAssertEqual(suspendedSnapshot.removedURL, fileURL.standardizedFileURL)
    XCTAssertFalse(suspendedSnapshot.callerReturned)
    let pendingBeforeRelease = await owner.pendingCount
    XCTAssertEqual(pendingBeforeRelease, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    await probe.releaseRemoval()
    await cleanup.value

    let completedSnapshot = await probe.snapshot()
    XCTAssertTrue(completedSnapshot.callerReturned)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    let pendingAfterDrain = await owner.pendingCount
    XCTAssertEqual(pendingAfterDrain, 0)
  }

  func testBoundedAudioBufferOverflowRevokesLifetimeAndRunsTeardownOnce() async throws {
    let runID = UUID()
    let lifetime = AudioCaptureLifetime(runID: runID)
    let request = makeAudioCaptureRequest(runID: runID, audioLifetime: lifetime)
    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-overflow-test-\(runID.uuidString)")
      .appendingPathExtension("wav")
    try Data("audio-canary".utf8).write(to: temporaryURL, options: .atomic)
    let teardownProbe = OverflowTeardownProbe(fileURL: temporaryURL)

    let buffer: FailClosedAsyncBuffer<Int> = DeepgramLiveCaptureRuntime.makeFailClosedAudioBuffer(
      capacity: 1,
      request: request,
      onOverflow: { teardownProbe.run() }
    )

    XCTAssertTrue(buffer.yield(1))
    XCTAssertFalse(buffer.yield(2), "The first dropped element must terminate the channel.")
    XCTAssertFalse(buffer.yield(3), "A terminated channel must reject later audio.")

    var bufferedValues: [Int] = []
    for await value in buffer.stream {
      bufferedValues.append(value)
    }

    XCTAssertEqual(bufferedValues, [2], "The buffer must never grow beyond its declared capacity.")
    XCTAssertEqual(lifetime.state, .revoked(.serviceFailure))
    XCTAssertEqual(teardownProbe.callCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
  }

  func testMakeOutputFilePreservesRequestedPCMFormat() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("wav")
    defer { try? FileManager.default.removeItem(at: url) }

    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
      )
    else {
      XCTFail("Failed to create output format")
      return
    }

    let file = try DeepgramLiveCaptureRuntime.makeOutputFile(for: url, format: format)

    XCTAssertEqual(file.processingFormat.commonFormat, .pcmFormatInt16)
    XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
    XCTAssertEqual(file.processingFormat.channelCount, 1)
    XCTAssertFalse(file.processingFormat.isInterleaved)
  }

  func testMakeWebSocketRequestEnablesLowLatencyQueryParameters() throws {
    let request = makeAudioCaptureRequest()
    let configuration = DeepgramRecognizer.Configuration(apiKey: "test-key")

    let webSocketRequest = try DeepgramLiveCaptureRuntime.makeWebSocketRequest(
      for: request,
      configuration: configuration
    )
    let components = try XCTUnwrap(
      URLComponents(url: webSocketRequest.url!, resolvingAgainstBaseURL: false))
    let queryItems = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

    XCTAssertEqual(queryItems["endpointing"], "250")
    XCTAssertEqual(queryItems["utterance_end_ms"], "1000")
    XCTAssertEqual(queryItems["vad_events"], "true")
    XCTAssertEqual(queryItems["interim_results"], "true")
  }

  func testMakeWebSocketRequestUsesTrimmedAPIKey() throws {
    let request = try DeepgramLiveCaptureRuntime.makeWebSocketRequest(
      for: makeAudioCaptureRequest(),
      configuration: .init(apiKey: "  test-key  ")
    )

    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token test-key")
  }

  func testMakeWebSocketRequestUsesWorkflowModelOptionsLanguageAndRepeatedKeyterms() throws {
    let request = makeAudioCaptureRequest(
      model: "nova-3-medical",
      language: "workflow-language",
      options: SpeechRecognitionRequestOptions(
        language: " zh-CN ",
        hints: RecognitionHints(keyterms: [" Rill ", "Rill", "rill"])
      )
    )
    let configuration = DeepgramRecognizer.Configuration(
      apiKey: "test-key",
      model: "nova-3",
      language: "global-language"
    )

    let webSocketRequest = try DeepgramLiveCaptureRuntime.makeWebSocketRequest(
      for: request,
      configuration: configuration
    )
    let queryItems = try XCTUnwrap(
      URLComponents(url: webSocketRequest.url!, resolvingAgainstBaseURL: false)?.queryItems
    )

    XCTAssertEqual(queryItems.first(where: { $0.name == "model" })?.value, "nova-3-medical")
    XCTAssertEqual(queryItems.first(where: { $0.name == "language" })?.value, "zh-CN")
    XCTAssertEqual(
      queryItems.filter { $0.name == "keyterm" }.compactMap(\.value),
      ["Rill", "rill"]
    )
  }

  func testMakeWebSocketRequestOmitsKeytermsForNonAllowlistedModel() throws {
    let keytermCanary = "live-private-keyterm-canary"
    let request = makeAudioCaptureRequest(
      model: "nova-3-special",
      options: SpeechRecognitionRequestOptions(
        hints: RecognitionHints(keyterms: [keytermCanary])
      )
    )

    let webSocketRequest = try DeepgramLiveCaptureRuntime.makeWebSocketRequest(
      for: request,
      configuration: .init(apiKey: "test-key")
    )
    let queryItems = try XCTUnwrap(
      URLComponents(url: webSocketRequest.url!, resolvingAgainstBaseURL: false)?.queryItems
    )
    let plan = DeepgramRequestPlanner.plan(
      options: request.options,
      workflow: request.workflow,
      configuration: .init(apiKey: "test-key"),
      source: .live
    )

    XCTAssertTrue(queryItems.filter { $0.name == "keyterm" }.isEmpty)
    XCTAssertEqual(plan.hintDiagnosticReport.source, .live)
    XCTAssertEqual(plan.hintDiagnosticReport.outcome, .unsupportedModel)
    XCTAssertEqual(plan.hintDiagnosticReport.count, 0)
    XCTAssertEqual(plan.hintDiagnosticReport.omittedCount, 1)
    XCTAssertFalse(String(reflecting: plan.hintDiagnosticReport).contains(keytermCanary))
    XCTAssertFalse(
      String(reflecting: plan.hintDiagnosticReport).contains(webSocketRequest.url!.absoluteString))
  }

  func testMakeWebSocketRequestRejectsPublicPlainHTTP() {
    XCTAssertThrowsError(
      try DeepgramLiveCaptureRuntime.makeWebSocketRequest(
        for: makeAudioCaptureRequest(),
        configuration: .init(
          apiKey: "test-key",
          baseURL: "http://api.example.com"
        )
      )
    ) { error in
      XCTAssertEqual(error as? DeepgramRecognizer.RecognizerError, .invalidBaseURL)
    }
  }

  func testMakeWebSocketRequestAllowsLoopbackHTTPForLocalDevelopment() throws {
    let request = try DeepgramLiveCaptureRuntime.makeWebSocketRequest(
      for: makeAudioCaptureRequest(),
      configuration: .init(
        apiKey: "test-key",
        baseURL: "http://127.0.0.1:8787"
      )
    )

    XCTAssertEqual(request.url?.scheme, "ws")
    XCTAssertEqual(request.url?.host, "127.0.0.1")
    XCTAssertEqual(request.url?.port, 8787)
  }

  func testDeepgramStreamMessageTreatsSpeechFinalAsAuthoritative() throws {
    let payload = Data(
      #"{"type":"Results","speech_final":true,"channel":{"alternatives":[{"transcript":"hello world"}]}}"#
        .utf8
    )

    let message = try JSONDecoder().decode(DeepgramStreamMessage.self, from: payload)

    XCTAssertTrue(message.isResultsMessage)
    XCTAssertTrue(message.isAuthoritativeResult)
    XCTAssertEqual(message.transcriptText, "hello world")
  }

  func testDeepgramStreamMessageDecodesUtteranceEndWithoutFailingOnChannelArray() throws {
    let payload = Data(#"{"type":"UtteranceEnd","channel":[0,2],"last_word_end":3.1}"#.utf8)

    let message = try JSONDecoder().decode(DeepgramStreamMessage.self, from: payload)

    XCTAssertTrue(message.isUtteranceEnd)
    XCTAssertEqual(try XCTUnwrap(message.lastWordEnd), 3.1, accuracy: 0.0001)
    XCTAssertEqual(message.utteranceChannels, [0, 2])
  }

  func testUtteranceEndWithoutSpeechEvidenceCannotStopCapture() throws {
    let message = try JSONDecoder().decode(
      DeepgramStreamMessage.self,
      from: Data(#"{"type":"UtteranceEnd","channel":[0]}"#.utf8)
    )

    XCTAssertFalse(
      DeepgramLiveCaptureRuntime.shouldSignalSpeechEndedForUtteranceEnd(
        message,
        hasFinalSegments: false,
        interimText: ""
      )
    )
    XCTAssertTrue(
      DeepgramLiveCaptureRuntime.shouldSignalSpeechEndedForUtteranceEnd(
        message,
        hasFinalSegments: false,
        interimText: "spoken words"
      )
    )
  }

  func testEndpointTimingUsesProcessedSampleDuration() {
    XCTAssertEqual(
      DeepgramLiveCaptureRuntime.sampleDuration(frameLength: 1_600, sampleRate: 16_000),
      0.1,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      DeepgramLiveCaptureRuntime.endpointRelativeEnergy(fromNormalizedRMS: 0.015),
      0.3,
      accuracy: 0.000_001
    )
  }

  func testProcessedBuffersFeedMeasuredDurationAndEnergyIntoAcousticSummary() async throws {
    func makeBuffer(sample: Int16) throws -> AVAudioPCMBuffer {
      let format = try XCTUnwrap(
        AVAudioFormat(
          commonFormat: .pcmFormatInt16,
          sampleRate: 16_000,
          channels: 1,
          interleaved: false
        )
      )
      let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800)
      )
      buffer.frameLength = 800
      let samples = try XCTUnwrap(buffer.int16ChannelData?.pointee)
      for index in 0..<Int(buffer.frameLength) {
        samples[index] = sample
      }
      return buffer
    }

    let runID = UUID()
    let policy = SpeechEndpointPolicy(
      initialSilenceTimeoutSeconds: 1,
      minimumSpeechDurationSeconds: 0.05,
      trailingSilenceDurationSeconds: 0.05,
      voiceActivityThreshold: 0.3
    )
    let endpointControl = AudioCaptureEndpointControl(runID: runID, policy: policy)
    let stream = try XCTUnwrap(endpointControl.claimStream())
    var detector = SpeechEndpointDetector(policy: policy)
    let processedSpeech = try makeBuffer(sample: Int16.max / 10)
    let processedSilence = try makeBuffer(sample: 0)

    XCTAssertNil(
      DeepgramLiveCaptureRuntime.observeProcessedEndpoint(
        in: processedSpeech,
        endpointControl: endpointControl,
        detector: &detector
      )
    )
    XCTAssertEqual(
      DeepgramLiveCaptureRuntime.observeProcessedEndpoint(
        in: processedSilence,
        endpointControl: endpointControl,
        detector: &detector
      ),
      .speechEnded
    )

    var iterator = stream.makeAsyncIterator()
    let nextSignal = await iterator.next()
    let signal = try XCTUnwrap(nextSignal)
    XCTAssertEqual(signal.runID, runID)
    XCTAssertEqual(signal.reason, .speechEnded)
    XCTAssertEqual(
      signal.acousticSummary,
      AudioCaptureAcousticSummary(
        observedSegmentCount: 2,
        observedDurationMilliseconds: 100,
        aboveThresholdDurationMilliseconds: 50,
        peakLevelPercentBucket: 100,
        maximumConsecutiveAboveThresholdDurationMilliseconds: 50
      )
    )
    let end = await iterator.next()
    XCTAssertNil(end)
  }

  func testOnlyResultsFromFinalizeCanBecomeAcceptedFinalizeResult() throws {
    let ordinaryFinal = try JSONDecoder().decode(
      DeepgramStreamMessage.self,
      from: Data(
        #"{"type":"Results","is_final":true,"last_word_end":2.0,"channel":{"alternatives":[{"transcript":"ordinary final"}]}}"#
          .utf8
      )
    )
    let utteranceEnd = try JSONDecoder().decode(
      DeepgramStreamMessage.self,
      from: Data(
        #"{"type":"UtteranceEnd","from_finalize":true,"last_word_end":2.0,"channel":[0]}"#.utf8
      )
    )
    let resultWithoutFinalize = try JSONDecoder().decode(
      DeepgramStreamMessage.self,
      from: Data(
        #"{"type":"Results","last_word_end":2.0,"channel":{"alternatives":[{"transcript":"no finalize acknowledgement"}]}}"#
          .utf8
      )
    )
    let acceptedFinalize = try JSONDecoder().decode(
      DeepgramStreamMessage.self,
      from: Data(
        #"{"type":"Results","from_finalize":true,"last_word_end":2.0,"channel":{"alternatives":[{"transcript":"complete"}]}}"#
          .utf8
      )
    )

    XCTAssertFalse(
      DeepgramLiveCaptureRuntime.isAcceptedFinalizeResult(
        ordinaryFinal,
        lastAcceptedWordEnd: nil
      )
    )
    XCTAssertFalse(
      DeepgramLiveCaptureRuntime.isAcceptedFinalizeResult(
        utteranceEnd,
        lastAcceptedWordEnd: nil
      )
    )
    XCTAssertFalse(
      DeepgramLiveCaptureRuntime.isAcceptedFinalizeResult(
        resultWithoutFinalize,
        lastAcceptedWordEnd: nil
      )
    )
    XCTAssertTrue(
      DeepgramLiveCaptureRuntime.isAcceptedFinalizeResult(
        acceptedFinalize,
        lastAcceptedWordEnd: nil
      )
    )
  }

  func testStaleResultsFromFinalizeCannotBecomeAcceptedFinalizeResult() throws {
    let staleFinalize = try JSONDecoder().decode(
      DeepgramStreamMessage.self,
      from: Data(
        #"{"type":"Results","from_finalize":true,"last_word_end":1.0,"channel":{"alternatives":[{"transcript":"stale"}]}}"#
          .utf8
      )
    )

    XCTAssertFalse(
      DeepgramLiveCaptureRuntime.isAcceptedFinalizeResult(
        staleFinalize,
        lastAcceptedWordEnd: 2.0
      )
    )
  }

  func testLiveTranscriptReuseRequiresHealthyStreamingAndAcceptedFinalize() {
    let transcript = "complete transcript"

    XCTAssertNil(
      DeepgramLiveCaptureRuntime.trustedReusableTranscript(
        transcript,
        streamingFailed: false,
        acceptedFinalizeResult: false
      ),
      "An ordinary final or utterance end cannot prove that all drained audio was transcribed."
    )
    XCTAssertNil(
      DeepgramLiveCaptureRuntime.trustedReusableTranscript(
        transcript,
        streamingFailed: true,
        acceptedFinalizeResult: true
      ),
      "A transport failure must force recognition from the complete recording."
    )
    XCTAssertNil(
      DeepgramLiveCaptureRuntime.trustedReusableTranscript(
        nil,
        streamingFailed: false,
        acceptedFinalizeResult: true
      )
    )
    XCTAssertEqual(
      DeepgramLiveCaptureRuntime.trustedReusableTranscript(
        transcript,
        streamingFailed: false,
        acceptedFinalizeResult: true
      ),
      transcript
    )
  }

  func testTransmissionPermitRequiresMatchingActiveLifetime() throws {
    let runID = UUID()
    let lifetime = AudioCaptureLifetime(runID: runID)
    let request = makeAudioCaptureRequest(runID: runID, audioLifetime: lifetime)

    XCTAssertEqual(
      try DeepgramLiveCaptureRuntime.requireTransmissionPermit(for: request).runID, runID)

    lifetime.revoke(.authorizationInvalidated)
    XCTAssertThrowsError(try DeepgramLiveCaptureRuntime.requireTransmissionPermit(for: request)) {
      error in
      XCTAssertEqual(error as? DeepgramLiveRuntimeError, .audioAuthorizationRevoked)
    }
  }

  func testTransmissionPermitRejectsMissingAndMismatchedLifetime() {
    let runID = UUID()
    let missing = makeAudioCaptureRequest(runID: runID)
    let otherRunLifetime = AudioCaptureLifetime(runID: UUID())
    let mismatched = makeAudioCaptureRequest(
      runID: runID,
      audioLifetime: otherRunLifetime
    )

    XCTAssertThrowsError(try DeepgramLiveCaptureRuntime.requireTransmissionPermit(for: missing)) {
      error in
      XCTAssertEqual(error as? DeepgramLiveRuntimeError, .missingAudioLifetime)
    }
    XCTAssertThrowsError(try DeepgramLiveCaptureRuntime.requireTransmissionPermit(for: mismatched))
    { error in
      XCTAssertEqual(error as? DeepgramLiveRuntimeError, .audioLifetimeRunMismatch)
    }
    XCTAssertEqual(otherRunLifetime.state, .active)
  }
}

private final class OverflowTeardownProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let fileURL: URL
  private var storedCallCount = 0

  init(fileURL: URL) {
    self.fileURL = fileURL
  }

  var callCount: Int {
    lock.withLock { storedCallCount }
  }

  func run() {
    lock.withLock {
      storedCallCount += 1
    }
    try? FileManager.default.removeItem(at: fileURL)
  }
}

private actor DeepgramBlockingReadinessSleepProbe {
  private var hasStarted = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  func sleep(for duration: Duration) async throws {
    hasStarted = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    try await Task.sleep(for: duration)
  }

  func waitUntilStarted() async {
    if hasStarted { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }
}

private actor DeepgramCleanupHandoffProbe {
  private var removalStarted = false
  private var removalReleased = false
  private var removedURL: URL?
  private var callerReturned = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func remove(_ fileURL: URL) async throws {
    removedURL = fileURL.standardizedFileURL
    removalStarted = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    if !removalReleased {
      await withCheckedContinuation { continuation in
        releaseWaiters.append(continuation)
      }
    }
    try FileManager.default.removeItem(at: fileURL)
  }

  func waitUntilRemovalStarted() async {
    guard !removalStarted else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func releaseRemoval() {
    removalReleased = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  func recordCallerReturned() {
    callerReturned = true
  }

  func snapshot() -> (removedURL: URL?, callerReturned: Bool) {
    (removedURL, callerReturned)
  }
}

private func makeAudioCaptureRequest(
  runID: UUID = UUID(),
  model: String = "nova-3",
  language: String = "en-US",
  options: SpeechRecognitionRequestOptions = .empty,
  audioLifetime: AudioCaptureLifetime? = nil
) -> AudioCaptureRequest {
  AudioCaptureRequest(
    runID: runID,
    workflow: WorkflowDefinition(
      name: "Deepgram Live Test Workflow",
      pipeline: PipelineDeclaration(
        recognizerID: "deepgram.prerecorded",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "cyan"),
      metadata: [
        WorkflowMetadataKey.languageOverride: language,
        WorkflowMetadataKey.deepgramModelOverride: model,
      ]
    ),
    options: options,
    audioLifetime: audioLifetime
  )
}
