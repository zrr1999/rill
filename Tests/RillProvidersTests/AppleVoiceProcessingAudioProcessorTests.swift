@testable import RillSpeech
@preconcurrency import AVFoundation
import Dispatch
import Foundation
import RillCore
import XCTest

@testable import RillProviders

final class AppleVoiceProcessingAudioProcessorTests: XCTestCase {
  func testVoiceProcessingIOFormatPreservesTheExactNativeFormat() throws {
    let nativeFormat = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
      )
    )
    let differentlyInterleavedFormat = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: true
      )
    )

    let ioFormat = AppleVoiceProcessingIOFormat(audioFormat: nativeFormat)

    XCTAssertTrue(ioFormat.audioFormat === nativeFormat)
    XCTAssertTrue(ioFormat.matches(nativeFormat))
    XCTAssertFalse(ioFormat.matches(differentlyInterleavedFormat))
  }

  func testChannelSelectorChoosesNonFirstAggregateChannelWithStrongestSignal() throws {
    let selection = try XCTUnwrap(
      AppleVoiceProcessingChannelSelector.select(
        channelSamples: [
          Array(repeating: 0, count: 8),
          Array(repeating: 0.04, count: 8),
          Array(repeating: 0.2, count: 8),
          Array(repeating: 0.01, count: 8),
        ]
      )
    )

    XCTAssertEqual(selection.selectedChannel, 2)
    XCTAssertEqual(selection.channelRMS[0], 0, accuracy: 0.0001)
    XCTAssertEqual(selection.channelRMS[2], 0.2, accuracy: 0.0001)
  }

  func testChannelSelectorUsesFirstChannelForAnAllSilentAggregateBuffer() throws {
    let selection = try XCTUnwrap(
      AppleVoiceProcessingChannelSelector.select(
        channelSamples: Array(
          repeating: Array(repeating: 0, count: 8),
          count: 9
        )
      )
    )

    XCTAssertEqual(selection.selectedChannel, 0)
    XCTAssertEqual(selection.channelRMS, Array(repeating: 0, count: 9))
  }

  func testCaptureConverterUsesActualAggregateBufferFormatAndPreservesActiveChannel() throws {
    let inputFormat = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
      )
    )
    let inputBuffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4_800)
    )
    inputBuffer.frameLength = 4_800
    let inputChannels = try XCTUnwrap(inputBuffer.floatChannelData)
    for frame in 0..<Int(inputBuffer.frameLength) {
      let phase = 2 * Double.pi * 1_000 * Double(frame) / inputFormat.sampleRate
      inputChannels[0][frame] = -0.19 * Float(sin(phase))
      inputChannels[1][frame] = 0.2 * Float(sin(phase))
    }
    let outputFormat = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
      )
    )

    let conversion = try AppleVoiceProcessingCaptureConverter(
      outputFormat: outputFormat
    ).convert(inputBuffer)

    XCTAssertEqual(conversion.diagnostics.inputSampleRate, 48_000)
    XCTAssertEqual(conversion.diagnostics.inputChannelCount, 2)
    XCTAssertEqual(conversion.diagnostics.selectedChannel, 1)
    // AVAudioConverter retains a small resampler delay between streaming
    // chunks. The first 100 ms input block may therefore emit fewer than
    // 1,600 frames; duration is recovered by subsequent chunks.
    XCTAssertTrue((1_280...1_600).contains(conversion.samples.count))
    XCTAssertGreaterThan(conversion.diagnostics.outputRMS, 0.05)
    XCTAssertTrue(conversion.shouldReportDiagnostics)
  }

  func testConfiguratorEstablishesOutputPathAndEnablesUnmutedVoiceProcessingWhileStopped() throws {
    let target = TestVoiceProcessingConfigurationTarget()

    try AppleVoiceProcessingEngineConfigurator().configure(target)

    XCTAssertEqual(target.enableRequests, [true])
    XCTAssertEqual(target.outputPathRequestCount, 1)
    XCTAssertEqual(
      target.requestedOutputFormats,
      [AppleVoiceProcessingIOFormat(sampleRate: 48_000, channelCount: 1)]
    )
    XCTAssertTrue(target.isInputVoiceProcessingEnabled)
    XCTAssertTrue(target.isOutputVoiceProcessingEnabled)
    XCTAssertFalse(target.isVoiceProcessingBypassed)
    XCTAssertFalse(target.isVoiceProcessingInputMuted)
    XCTAssertTrue(target.isVoiceProcessingAGCEnabled)
    XCTAssertEqual(
      target.operations,
      [
        .setVoiceProcessingEnabled(true),
        .minimizeOtherAudioDucking,
        .configureInputDevice,
        .establishOutputPath(
          AppleVoiceProcessingIOFormat(sampleRate: 48_000, channelCount: 1)
        ),
        .setBypassed(false),
        .setInputMuted(false),
        .setAGCEnabled(true),
      ]
    )
  }

  func testConfiguratorRejectsRunningEngineBeforeActivation() {
    let target = TestVoiceProcessingConfigurationTarget()
    target.isRunning = true

    XCTAssertThrowsError(
      try AppleVoiceProcessingEngineConfigurator().configure(target)
    ) { error in
      XCTAssertEqual(error as? AppleVoiceProcessingAudioError, .engineMustBeStopped)
    }
    XCTAssertTrue(target.enableRequests.isEmpty)
  }

  func testConfiguratorSurfacesActivationFailure() {
    let target = TestVoiceProcessingConfigurationTarget()
    target.activationError = TestFailure.activation

    XCTAssertThrowsError(
      try AppleVoiceProcessingEngineConfigurator().configure(target)
    ) { error in
      guard let audioError = error as? AppleVoiceProcessingAudioError,
        case .voiceProcessingActivationFailed(let description) = audioError
      else {
        return XCTFail("Expected an explicit voice-processing activation failure.")
      }
      XCTAssertTrue(description.contains("activation"))
    }
  }

  func testConfiguratorRejectsActivationThatDoesNotTakeEffect() {
    let target = TestVoiceProcessingConfigurationTarget()
    target.activationTakesEffect = false

    XCTAssertThrowsError(
      try AppleVoiceProcessingEngineConfigurator().configure(target)
    ) { error in
      XCTAssertEqual(
        error as? AppleVoiceProcessingAudioError,
        .voiceProcessingDidNotActivate
      )
    }
  }

  func testConfiguratorRejectsUnavailableVoiceProcessingOutputPath() {
    let target = TestVoiceProcessingConfigurationTarget()
    target.outputPathAvailable = false

    XCTAssertThrowsError(
      try AppleVoiceProcessingEngineConfigurator().configure(target)
    ) { error in
      XCTAssertEqual(
        error as? AppleVoiceProcessingAudioError,
        .voiceProcessingOutputPathUnavailable
      )
    }
    XCTAssertEqual(target.outputPathRequestCount, 1)
  }

  func testConfiguratorRejectsUnavailableVoiceProcessingInputFormat() {
    let target = TestVoiceProcessingConfigurationTarget()
    target.voiceProcessingInputFormat = nil

    XCTAssertThrowsError(
      try AppleVoiceProcessingEngineConfigurator().configure(target)
    ) { error in
      XCTAssertEqual(error as? AppleVoiceProcessingAudioError, .invalidInputFormat)
    }
    XCTAssertEqual(target.outputPathRequestCount, 0)
  }

  func testConfiguratorConfiguresSelectedInputBeforeResolvingOutputFormat() {
    let target = TestVoiceProcessingConfigurationTarget()

    try? AppleVoiceProcessingEngineConfigurator().configure(target)

    XCTAssertEqual(
      Array(target.operations.prefix(3)),
      [
        .setVoiceProcessingEnabled(true),
        .minimizeOtherAudioDucking,
        .configureInputDevice,
      ]
    )
  }

  func testConfiguratorRejectsBypassOrAGCThatDoesNotTakeEffect() {
    let bypassTarget = TestVoiceProcessingConfigurationTarget()
    bypassTarget.allowsBypassChange = false
    XCTAssertThrowsError(
      try AppleVoiceProcessingEngineConfigurator().configure(bypassTarget)
    ) { error in
      XCTAssertEqual(
        error as? AppleVoiceProcessingAudioError,
        .voiceProcessingBypassCouldNotBeDisabled
      )
    }

    let agcTarget = TestVoiceProcessingConfigurationTarget()
    agcTarget.allowsAGCChange = false
    XCTAssertThrowsError(
      try AppleVoiceProcessingEngineConfigurator().configure(agcTarget)
    ) { error in
      XCTAssertEqual(
        error as? AppleVoiceProcessingAudioError,
        .automaticGainControlDidNotActivate
      )
    }

    let mutedTarget = TestVoiceProcessingConfigurationTarget()
    mutedTarget.allowsInputMuteChange = false
    XCTAssertThrowsError(
      try AppleVoiceProcessingEngineConfigurator().configure(mutedTarget)
    ) { error in
      XCTAssertEqual(
        error as? AppleVoiceProcessingAudioError,
        .voiceProcessingInputCouldNotBeUnmuted
      )
    }
  }

  func testConfigurationChangePolicyIgnoresStartupNegotiationButFailsRunningCapture() {
    var policy = AppleVoiceProcessingConfigurationChangePolicy()

    XCTAssertFalse(policy.shouldFailCaptureOnChange)
    let initialRevision = policy.revision
    XCTAssertFalse(policy.observeConfigurationChange())
    XCTAssertFalse(policy.completeStartValidation(ifRevisionMatches: initialRevision))
    XCTAssertTrue(policy.completeStartValidation(ifRevisionMatches: policy.revision))
    XCTAssertTrue(policy.shouldFailCaptureOnChange)
    XCTAssertTrue(policy.observeConfigurationChange())
  }

  func testConfigurationReuseStateSkipsNormalRestartButReconfiguresAfterFailure() {
    let state = AppleVoiceProcessingConfigurationReuseState()

    XCTAssertTrue(state.requiresConfiguration)
    XCTAssertFalse(state.isConfigured)

    state.markConfigured()
    XCTAssertFalse(state.requiresConfiguration)
    XCTAssertTrue(state.isConfigured)

    // A normal stop deliberately leaves the retained graph reusable. Only a
    // failed start or a stable-run configuration change invalidates it.
    XCTAssertFalse(state.requiresConfiguration)

    state.invalidate()
    XCTAssertTrue(state.requiresConfiguration)
    XCTAssertFalse(state.isConfigured)

    state.markConfigured()
    XCTAssertFalse(state.requiresConfiguration)
    XCTAssertTrue(state.isConfigured)
  }

  func testStartedStateRevalidatesVoiceProcessingAndGraphAfterEngineStart() {
    let valid = AppleVoiceProcessingStartedState(
      isRunning: true,
      isInputVoiceProcessingEnabled: true,
      isOutputVoiceProcessingEnabled: true,
      isVoiceProcessingBypassed: false,
      isVoiceProcessingInputMuted: false,
      isVoiceProcessingAGCEnabled: true,
      formatsRemainMatched: true
    )
    XCTAssertNoThrow(try AppleVoiceProcessingStartedStateValidator().validate(valid))

    let mismatched = AppleVoiceProcessingStartedState(
      isRunning: true,
      isInputVoiceProcessingEnabled: true,
      isOutputVoiceProcessingEnabled: true,
      isVoiceProcessingBypassed: false,
      isVoiceProcessingInputMuted: false,
      isVoiceProcessingAGCEnabled: true,
      formatsRemainMatched: false
    )
    XCTAssertThrowsError(try AppleVoiceProcessingStartedStateValidator().validate(mismatched)) {
      error in
      XCTAssertEqual(
        error as? AppleVoiceProcessingAudioError,
        .voiceProcessingFormatsDidNotRemainMatched
      )
    }
  }

  func testProcessorConfiguresBeforeStartingAndStreamsSpeechRecognitionSamples() async throws {
    let session = TestVoiceProcessingAudioEngineSession()
    let processor = AppleVoiceProcessingAudioProcessor(
      sessionFactory: TestVoiceProcessingAudioEngineSessionFactory(session: session)
    )
    let (stream, continuation) = processor.startStreamingRecordingLive(inputDeviceID: nil)
    session.emit([0.1, -0.2, 0.3])
    var iterator = stream.makeAsyncIterator()

    XCTAssertEqual(session.events, [.configure, .start])
    XCTAssertEqual(session.captureFormat, .speechRecognition)
    let streamedSamples = try await iterator.next()
    XCTAssertEqual(streamedSamples, [0.1, -0.2, 0.3])

    continuation.finish()
    processor.stopRecording()
    XCTAssertEqual(session.events, [.configure, .start, .stop])
  }

  func testProcessorPreparesStoppedFrontendWithoutStartingAndReusesConfiguration() throws {
    let session = TestVoiceProcessingAudioEngineSession()
    session.emulatesConfigurationReuse = true
    let factory = TestVoiceProcessingAudioEngineSessionFactory(session: session)
    let processor = AppleVoiceProcessingAudioProcessor(sessionFactory: factory)

    try processor.prepareRecordingFrontend(inputDeviceID: nil)

    XCTAssertEqual(factory.makeCount, 1)
    XCTAssertEqual(session.events, [.configure])

    let (stream, continuation) = processor.startStreamingRecordingLive(inputDeviceID: nil)
    XCTAssertEqual(factory.makeCount, 1)
    XCTAssertEqual(session.events, [.configure, .start])

    continuation.finish()
    processor.stopRecording()
    XCTAssertEqual(session.events, [.configure, .start, .stop])
    withExtendedLifetime(stream) {}
  }

  func testProcessorReusesValidatedConfigurationAcrossNormalRecordingRestart() throws {
    let session = TestVoiceProcessingAudioEngineSession()
    session.emulatesConfigurationReuse = true
    let processor = AppleVoiceProcessingAudioProcessor(
      sessionFactory: TestVoiceProcessingAudioEngineSessionFactory(session: session)
    )

    let (firstStream, firstContinuation) =
      processor.startStreamingRecordingLive(inputDeviceID: nil)
    processor.stopRecording()
    firstContinuation.finish()

    let (secondStream, secondContinuation) =
      processor.startStreamingRecordingLive(inputDeviceID: nil)

    XCTAssertEqual(
      session.events,
      [.configure, .start, .stop, .start],
      "A normal restart must not repeat the expensive VoiceProcessingIO configuration."
    )

    processor.stopRecording()
    secondContinuation.finish()
    XCTAssertEqual(session.events, [.configure, .start, .stop, .start, .stop])
    withExtendedLifetime((firstStream, secondStream)) {}
  }

  func testFailedStoppedFrontendPreparationDoesNotBlockCaptureStaleRouteRetry() async throws {
    let session = TestVoiceProcessingAudioEngineSession()
    session.emulatesConfigurationReuse = true
    session.configurationErrors = [.automaticGainControlDidNotActivate]
    session.startErrors = [.voiceProcessingFormatsDidNotRemainMatched]
    let factory = TestVoiceProcessingAudioEngineSessionFactory(session: session)
    let processor = AppleVoiceProcessingAudioProcessor(sessionFactory: factory)

    XCTAssertThrowsError(
      try processor.prepareRecordingFrontend(inputDeviceID: nil)
    ) { error in
      XCTAssertEqual(
        error as? AppleVoiceProcessingAudioError,
        .automaticGainControlDidNotActivate
      )
    }

    let (stream, continuation) = processor.startStreamingRecordingLive(inputDeviceID: nil)

    XCTAssertEqual(factory.makeCount, 1)
    XCTAssertEqual(
      session.events,
      [.configure, .configure, .start, .stop, .configure, .start]
    )
    continuation.finish()
    processor.stopRecording()
    withExtendedLifetime(stream) {}
  }

  func testStoppedFrontendPreparationCaptureAndShutdownAreLinearized() async throws {
    let session = TestVoiceProcessingAudioEngineSession()
    session.emulatesConfigurationReuse = true
    let configureEntered = DispatchSemaphore(value: 0)
    let allowConfigure = DispatchSemaphore(value: 0)
    let startEntered = DispatchSemaphore(value: 0)
    let allowStart = DispatchSemaphore(value: 0)
    let stopEntered = DispatchSemaphore(value: 0)
    session.configureHook = {
      configureEntered.signal()
      allowConfigure.wait()
    }
    session.startHook = {
      startEntered.signal()
      allowStart.wait()
    }
    session.stopHook = {
      stopEntered.signal()
    }
    let processor = AppleVoiceProcessingAudioProcessor(
      sessionFactory: TestVoiceProcessingAudioEngineSessionFactory(session: session)
    )

    let prepareTask = Task.detached {
      try processor.prepareRecordingFrontend(inputDeviceID: nil)
    }
    let didEnterConfigure = await wait(
      for: configureEntered,
      timeout: .now() + .seconds(1)
    )
    XCTAssertTrue(didEnterConfigure)

    let startTask = Task.detached {
      processor.startStreamingRecordingLive(inputDeviceID: nil)
    }
    let didStartBeforePreparationCompleted = await wait(
      for: startEntered,
      timeout: .now() + .milliseconds(30)
    )
    XCTAssertFalse(didStartBeforePreparationCompleted)

    allowConfigure.signal()
    try await prepareTask.value
    let didEnterStart = await wait(
      for: startEntered,
      timeout: .now() + .seconds(1)
    )
    XCTAssertTrue(didEnterStart)

    let shutdownTask = Task.detached {
      processor.shutdown()
    }
    let didStopBeforeStartCompleted = await wait(
      for: stopEntered,
      timeout: .now() + .milliseconds(30)
    )
    XCTAssertFalse(didStopBeforeStartCompleted)

    allowStart.signal()
    let (stream, continuation) = await startTask.value
    await shutdownTask.value
    let didStopAfterStartCompleted = await wait(
      for: stopEntered,
      timeout: .now() + .seconds(1)
    )
    XCTAssertTrue(didStopAfterStartCompleted)
    XCTAssertEqual(session.events, [.configure, .start, .stop])

    continuation.finish()
    withExtendedLifetime(stream) {}
  }

  func testProcessorMeasuresDisplayEnergyInExactFortyMillisecondOutputFrames() {
    let session = TestVoiceProcessingAudioEngineSession()
    let processor = AppleVoiceProcessingAudioProcessor(
      sessionFactory: TestVoiceProcessingAudioEngineSessionFactory(session: session)
    )

    let (stream, continuation) = processor.startStreamingRecordingLive(inputDeviceID: nil)
    session.emit(Array(repeating: 0.1, count: 639))
    XCTAssertTrue(processor.meterRMS.isEmpty)

    session.emit([0.1])
    XCTAssertEqual(processor.meterRMS.count, 1)
    XCTAssertEqual(processor.retainedMeterSampleCount, 0)

    session.emit(Array(repeating: 0.1, count: 1_281))
    XCTAssertEqual(processor.meterRMS.count, 3)
    XCTAssertEqual(processor.retainedMeterSampleCount, 1)
    continuation.finish()
    processor.stopRecording()
    withExtendedLifetime(stream) {}
  }

  func testProcessorRetainsOnlyBoundedEnergyStateAcrossLongStream() async throws {
    let session = TestVoiceProcessingAudioEngineSession()
    let processor = AppleVoiceProcessingAudioProcessor(
      sessionFactory: TestVoiceProcessingAudioEngineSessionFactory(session: session)
    )
    let (stream, continuation) = processor.startStreamingRecordingLive(inputDeviceID: nil)
    var iterator = stream.makeAsyncIterator()
    let chunk = Array(repeating: Float(0.01), count: 533)
    let chunkCount = 5_000

    for _ in 0..<chunkCount {
      session.emit(chunk)
      let streamedChunk = try await iterator.next()
      XCTAssertEqual(streamedChunk?.count, chunk.count)
    }

    let totalFrameCount = chunk.count * chunkCount
    XCTAssertEqual(
      processor.retainedMeterSampleCount,
      totalFrameCount % AppleVoiceProcessingAudioProcessor.meterFrameSampleCount
    )
    XCTAssertLessThan(
      processor.retainedMeterSampleCount,
      AppleVoiceProcessingAudioProcessor.meterFrameSampleCount
    )
    XCTAssertEqual(
      processor.meterRMS.count,
      AppleVoiceProcessingAudioProcessor.maximumRetainedMeterRMSSampleCount
    )
    continuation.finish()
    processor.stopRecording()
  }

  func testProcessorReportsUnthresholdedRMSForTheDisplayMeter() {
    let harness = makeStartedProcessor()

    harness.session.emit(constantMeterFrame(amplitude: 0.02))
    harness.session.emit(constantMeterFrame(amplitude: 0.005))

    let rms = harness.processor.meterRMS
    XCTAssertEqual(rms.count, 2)
    XCTAssertEqual(rms[0], 0.02, accuracy: 0.0001)
    XCTAssertEqual(rms[1], 0.005, accuracy: 0.0001)
  }

  func testDisplayMeterKeepsHeadroomAboveEndpointThreshold() {
    XCTAssertEqual(
      AppleVoiceProcessingAudioProcessor.endpointRelativeEnergy(fromNormalizedRMS: 0.05),
      1
    )

    let quiet = AppleVoiceProcessingAudioProcessor.meterRelativeEnergy(
      fromNormalizedRMS: 0.005
    )
    let ordinarySpeech = AppleVoiceProcessingAudioProcessor.meterRelativeEnergy(
      fromNormalizedRMS: 0.05
    )
    let loudSpeech = AppleVoiceProcessingAudioProcessor.meterRelativeEnergy(
      fromNormalizedRMS: 0.5
    )

    XCTAssertGreaterThan(quiet, 0)
    XCTAssertLessThan(quiet, ordinarySpeech)
    XCTAssertLessThan(ordinarySpeech, 0.6)
    XCTAssertGreaterThan(loudSpeech, ordinarySpeech)
    XCTAssertLessThan(loudSpeech, 1)
    XCTAssertEqual(
      AppleVoiceProcessingAudioProcessor.meterRelativeEnergy(fromNormalizedRMS: 1),
      1
    )
    XCTAssertEqual(
      AppleVoiceProcessingAudioProcessor.meterRelativeEnergy(fromNormalizedRMS: .nan),
      0
    )
  }

  func testProcessorPropagatesConfigurationFailureAndDoesNotStart() async {
    let session = TestVoiceProcessingAudioEngineSession()
    session.configurationError = AppleVoiceProcessingAudioError.automaticGainControlDidNotActivate
    let processor = AppleVoiceProcessingAudioProcessor(
      sessionFactory: TestVoiceProcessingAudioEngineSessionFactory(session: session)
    )

    let (stream, _) = processor.startStreamingRecordingLive(inputDeviceID: nil)
    do {
      for try await _ in stream {}
      XCTFail("A failed configuration must fail the capture stream.")
    } catch {
      XCTAssertEqual(
        error as? AppleVoiceProcessingAudioError,
        .automaticGainControlDidNotActivate
      )
    }
    XCTAssertEqual(session.events, [.configure, .stop])
  }

  func testProcessorRetainsAndReusesSessionAfterStartFailure() async throws {
    let session = TestVoiceProcessingAudioEngineSession()
    session.startError = TestFailure.activation
    let factory = TestVoiceProcessingAudioEngineSessionFactory(session: session)
    let processor = AppleVoiceProcessingAudioProcessor(sessionFactory: factory)

    let (failedStream, _) = processor.startStreamingRecordingLive(inputDeviceID: nil)
    do {
      for try await _ in failedStream {}
      XCTFail("A failed engine start must fail the capture stream.")
    } catch {}
    XCTAssertEqual(factory.makeCount, 1)
    XCTAssertEqual(session.events, [.configure, .start, .stop])

    session.startError = nil
    let (stream, continuation) = processor.startStreamingRecordingLive(inputDeviceID: nil)

    XCTAssertEqual(factory.makeCount, 1)
    XCTAssertEqual(
      session.events,
      [.configure, .start, .stop, .configure, .start]
    )
    continuation.finish()
    processor.stopRecording()
    withExtendedLifetime(stream) {}
  }

  func testProcessorReconfiguresAndRetriesStaleRetainedGraphWithinOneStart() async throws {
    let session = TestVoiceProcessingAudioEngineSession()
    let factory = TestVoiceProcessingAudioEngineSessionFactory(session: session)
    let processor = AppleVoiceProcessingAudioProcessor(sessionFactory: factory)

    let (firstStream, firstContinuation) =
      processor.startStreamingRecordingLive(inputDeviceID: nil)
    processor.stopRecording()
    firstContinuation.finish()

    session.startErrors = [.voiceProcessingFormatsDidNotRemainMatched]
    let (stream, continuation) = processor.startStreamingRecordingLive(inputDeviceID: nil)
    session.emit([0.25])
    var iterator = stream.makeAsyncIterator()

    XCTAssertEqual(factory.makeCount, 1)
    XCTAssertEqual(
      session.events,
      [.configure, .start, .stop, .configure, .start, .stop, .configure, .start]
    )
    let streamedSamples = try await iterator.next()
    XCTAssertEqual(streamedSamples, [0.25])

    continuation.finish()
    processor.stopRecording()
    withExtendedLifetime(firstStream) {}
  }

  func testProcessorBoundsStaleGraphReconfigurationToOneRetry() async {
    let session = TestVoiceProcessingAudioEngineSession()
    session.startErrors = [
      .voiceProcessingFormatsDidNotRemainMatched,
      .voiceProcessingFormatsDidNotRemainMatched,
    ]
    let processor = AppleVoiceProcessingAudioProcessor(
      sessionFactory: TestVoiceProcessingAudioEngineSessionFactory(session: session)
    )

    let (stream, _) = processor.startStreamingRecordingLive(inputDeviceID: nil)
    do {
      for try await _ in stream {}
      XCTFail("A persistently stale graph must fail after one safe retry.")
    } catch {
      XCTAssertEqual(
        error as? AppleVoiceProcessingAudioError,
        .voiceProcessingFormatsDidNotRemainMatched
      )
    }
    XCTAssertEqual(
      session.events,
      [.configure, .start, .stop, .configure, .start, .stop]
    )
  }

  func testRestartOnAnotherDeviceRejectsRetiredBuffers() async throws {
    let firstSession = TestVoiceProcessingAudioEngineSession()
    firstSession.retainsBufferHandlerAfterStop = true
    let secondSession = TestVoiceProcessingAudioEngineSession()
    let processor = AppleVoiceProcessingAudioProcessor(
      sessionFactory: SequenceVoiceProcessingAudioEngineSessionFactory(
        sessions: [firstSession, secondSession]
      )
    )
    let (firstStream, firstContinuation) =
      processor.startStreamingRecordingLive(inputDeviceID: nil)
    firstSession.emit([0.1])
    var firstIterator = firstStream.makeAsyncIterator()
    let firstStreamedSamples = try await firstIterator.next()
    XCTAssertEqual(firstStreamedSamples, [0.1])

    let (secondStream, secondContinuation) =
      processor.startStreamingRecordingLive(inputDeviceID: AppleVoiceProcessingInputDeviceID(7))
    firstSession.emit([0.9])
    secondSession.emit([0.2])
    var secondIterator = secondStream.makeAsyncIterator()

    let secondStreamedSamples = try await secondIterator.next()
    XCTAssertEqual(secondStreamedSamples, [0.2])
    XCTAssertEqual(processor.retainedMeterSampleCount, 1)
    XCTAssertEqual(firstSession.events, [.configure, .start, .stop])
    XCTAssertEqual(secondSession.events, [.configure, .start])
    firstContinuation.finish()
    secondContinuation.finish()
    processor.stopRecording()
  }

  func testStreamingCaptureSurfacesRuntimeFailureAndRejectsLateBuffers() async throws {
    let session = TestVoiceProcessingAudioEngineSession()
    session.retainsBufferHandlerAfterStop = true
    let processor = AppleVoiceProcessingAudioProcessor(
      sessionFactory: TestVoiceProcessingAudioEngineSessionFactory(session: session)
    )

    let (stream, _) = processor.startStreamingRecordingLive(inputDeviceID: nil)
    session.emit([0.1])
    session.fail(.inputConfigurationChanged)
    session.emit([0.9])

    var received: [[Float]] = []
    do {
      for try await buffer in stream {
        received.append(buffer)
      }
      XCTFail("A runtime microphone failure must fail the live stream.")
    } catch {
      XCTAssertEqual(
        error as? AppleVoiceProcessingAudioError,
        .inputConfigurationChanged
      )
    }
    XCTAssertEqual(received, [[0.1]])
    XCTAssertEqual(session.events.last, .stop)
  }

  func testProcessorFailsClosedExactlyOnceWhenBoundedPCMStreamOverflows() async {
    let session = TestVoiceProcessingAudioEngineSession()
    session.retainsBufferHandlerAfterStop = true
    let processor = AppleVoiceProcessingAudioProcessor(
      sessionFactory: TestVoiceProcessingAudioEngineSessionFactory(session: session)
    )
    let (stream, _) = processor.startStreamingRecordingLive(inputDeviceID: nil)
    let limit = AppleVoiceProcessingAudioProcessor.maximumBufferedPCMChunkCount
    let emittedBeforeFailure = (0...limit).map { [Float($0 + 1) / 1_000] }

    for buffer in emittedBeforeFailure {
      session.emit(buffer)
    }
    session.emit([0.9])

    var received: [[Float]] = []
    do {
      for try await buffer in stream {
        received.append(buffer)
      }
      XCTFail("A full PCM queue must terminate capture instead of losing audio.")
    } catch {
      XCTAssertEqual(
        error as? AppleVoiceProcessingAudioError,
        .streamBufferOverflow
      )
    }

    XCTAssertEqual(received, Array(emittedBeforeFailure.prefix(limit)))
    XCTAssertEqual(session.events.filter { $0 == .stop }.count, 1)
  }

  func testProducerFailureIsVisibleBeforeAConcurrentFinishCanClaimTheRun() async throws {
    let session = TestVoiceProcessingAudioEngineSession()
    let handlerEntered = DispatchSemaphore(value: 0)
    let allowHandlerToReturn = DispatchSemaphore(value: 0)
    let processor = AppleVoiceProcessingAudioProcessor(
      sessionFactory: TestVoiceProcessingAudioEngineSessionFactory(session: session),
      streamOverflowDetectedHook: {
        handlerEntered.signal()
        allowHandlerToReturn.wait()
      }
    )
    let terminalState = AppleVoiceProcessingPCMStreamTerminalState()
    let (stream, _) = processor.startStreamingRecordingLive(
      inputDeviceID: nil,
      terminalState: terminalState
    )
    for index in 0..<AppleVoiceProcessingAudioProcessor.maximumBufferedPCMChunkCount {
      session.emit([Float(index + 1) / 1_000])
    }

    let overflowTask = Task.detached {
      session.emit([0.5])
    }
    XCTAssertEqual(handlerEntered.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(
      terminalState.claimSuccessfulFinish(),
      .streamBufferOverflow
    )
    allowHandlerToReturn.signal()
    await overflowTask.value

    do {
      for try await _ in stream {}
      XCTFail("The overflow must remain the terminal stream result.")
    } catch {
      XCTAssertEqual(
        error as? AppleVoiceProcessingAudioError,
        .streamBufferOverflow
      )
    }
    XCTAssertEqual(session.events.filter { $0 == .stop }.count, 1)
  }

  func testHardwareFailureClaimsTerminalBoundaryBeforeGenerationSeal() async throws {
    let session = TestVoiceProcessingAudioEngineSession()
    let failureClaimed = DispatchSemaphore(value: 0)
    let allowGenerationSeal = DispatchSemaphore(value: 0)
    let processor = AppleVoiceProcessingAudioProcessor(
      sessionFactory: TestVoiceProcessingAudioEngineSessionFactory(session: session),
      producerFailureClaimedHook: {
        failureClaimed.signal()
        allowGenerationSeal.wait()
      }
    )
    let terminalState = AppleVoiceProcessingPCMStreamTerminalState()
    let (stream, _) = processor.startStreamingRecordingLive(
      inputDeviceID: nil,
      terminalState: terminalState
    )

    let failureTask = Task.detached {
      session.fail(.inputConfigurationChanged)
    }
    XCTAssertEqual(failureClaimed.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(
      terminalState.claimSuccessfulFinish(),
      .inputConfigurationChanged
    )
    var endpointOperationRan = false
    XCTAssertFalse(
      terminalState.claimNormalEndpoint {
        endpointOperationRan = true
      }
    )
    XCTAssertFalse(endpointOperationRan)
    allowGenerationSeal.signal()
    await failureTask.value

    do {
      for try await _ in stream {}
      XCTFail("The hardware failure must remain the terminal stream result.")
    } catch {
      XCTAssertEqual(
        error as? AppleVoiceProcessingAudioError,
        .inputConfigurationChanged
      )
    }
    XCTAssertEqual(session.events.filter { $0 == .stop }.count, 1)
  }

  func testRetiredStreamFinishAndCancellationCannotStopReplacementSession() async throws {
    let firstSession = TestVoiceProcessingAudioEngineSession()
    let secondSession = TestVoiceProcessingAudioEngineSession()
    let thirdSession = TestVoiceProcessingAudioEngineSession()
    let terminationHandled = DispatchSemaphore(value: 0)
    let processor = AppleVoiceProcessingAudioProcessor(
      sessionFactory: SequenceVoiceProcessingAudioEngineSessionFactory(
        sessions: [firstSession, secondSession, thirdSession]
      ),
      asynchronousTeardownHook: { reason in
        guard reason == .streamTermination else { return }
        terminationHandled.signal()
      }
    )

    let (firstStream, firstContinuation) =
      processor.startStreamingRecordingLive(inputDeviceID: nil)
    let (secondStream, _) =
      processor.startStreamingRecordingLive(inputDeviceID: AppleVoiceProcessingInputDeviceID(7))

    firstContinuation.finish()
    XCTAssertEqual(terminationHandled.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(secondSession.events.filter { $0 == .stop }.count, 0)

    let secondConsumer = Task {
      do {
        for try await _ in secondStream {}
      } catch {}
    }
    await Task.yield()
    let (thirdStream, thirdContinuation) =
      processor.startStreamingRecordingLive(inputDeviceID: AppleVoiceProcessingInputDeviceID(9))
    secondConsumer.cancel()
    await secondConsumer.value
    XCTAssertEqual(terminationHandled.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(thirdSession.events.filter { $0 == .stop }.count, 0)

    processor.stopRecording()
    thirdContinuation.finish()
    XCTAssertEqual(terminationHandled.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(thirdSession.events.filter { $0 == .stop }.count, 1)
    withExtendedLifetime((firstStream, thirdStream)) {}
  }

  func testDelayedRetiredFailureCannotStopReplacementSession() async throws {
    let retainedSession = TestVoiceProcessingAudioEngineSession()
    let failureTeardownEntered = DispatchSemaphore(value: 0)
    let allowFailureTeardown = DispatchSemaphore(value: 0)
    let processor = AppleVoiceProcessingAudioProcessor(
      sessionFactory: TestVoiceProcessingAudioEngineSessionFactory(session: retainedSession),
      asynchronousTeardownHook: { reason in
        guard reason == .producerFailure else { return }
        failureTeardownEntered.signal()
        allowFailureTeardown.wait()
      }
    )
    let (firstStream, _) = processor.startStreamingRecordingLive(inputDeviceID: nil)

    retainedSession.fail(.inputConfigurationChanged)
    XCTAssertEqual(failureTeardownEntered.wait(timeout: .now() + 2), .success)
    let (secondStream, secondContinuation) =
      processor.startStreamingRecordingLive(inputDeviceID: nil)
    XCTAssertEqual(retainedSession.events.filter { $0 == .stop }.count, 1)
    allowFailureTeardown.signal()

    do {
      for try await _ in firstStream {}
      XCTFail("The retired stream must retain its producer failure.")
    } catch {
      XCTAssertEqual(
        error as? AppleVoiceProcessingAudioError,
        .inputConfigurationChanged
      )
    }
    XCTAssertEqual(retainedSession.events.filter { $0 == .stop }.count, 1)

    retainedSession.emit([0.2])
    var secondIterator = secondStream.makeAsyncIterator()
    let secondSamples = try await secondIterator.next()
    XCTAssertEqual(secondSamples, [0.2])
    processor.stopRecording()
    secondContinuation.finish()
  }

  func testStopIsIdempotentAndRejectsLateBuffers() {
    let session = TestVoiceProcessingAudioEngineSession()
    session.retainsBufferHandlerAfterStop = true
    let processor = AppleVoiceProcessingAudioProcessor(
      sessionFactory: TestVoiceProcessingAudioEngineSessionFactory(session: session)
    )
    let (stream, continuation) = processor.startStreamingRecordingLive(inputDeviceID: nil)
    session.emit([0.1])
    processor.stopRecording()
    processor.stopRecording()
    session.emit([0.9])

    XCTAssertEqual(processor.retainedMeterSampleCount, 1)
    XCTAssertEqual(session.events.filter { $0 == .stop }.count, 1)
    continuation.finish()
    withExtendedLifetime(stream) {}
  }

  private func makeStartedProcessor() -> StartedProcessorHarness {
    StartedProcessorHarness()
  }

  private func constantMeterFrame(amplitude: Float) -> [Float] {
    Array(
      repeating: amplitude,
      count: AppleVoiceProcessingAudioProcessor.meterFrameSampleCount
    )
  }

  private func wait(
    for semaphore: DispatchSemaphore,
    timeout: DispatchTime
  ) async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: semaphore.wait(timeout: timeout) == .success)
      }
    }
  }

}

private final class StartedProcessorHarness {
  let processor: AppleVoiceProcessingAudioProcessor
  let session: TestVoiceProcessingAudioEngineSession
  private let stream: AsyncThrowingStream<[Float], Error>
  private let continuation: AsyncThrowingStream<[Float], Error>.Continuation

  init() {
    let session = TestVoiceProcessingAudioEngineSession()
    self.session = session
    let processor = AppleVoiceProcessingAudioProcessor(
      sessionFactory: TestVoiceProcessingAudioEngineSessionFactory(session: session)
    )
    self.processor = processor
    (stream, continuation) = processor.startStreamingRecordingLive(inputDeviceID: nil)
  }

  deinit {
    continuation.finish()
    processor.stopRecording()
    withExtendedLifetime(stream) {}
  }
}

private final class TestVoiceProcessingConfigurationTarget:
  AppleVoiceProcessingEngineConfigurationTarget
{
  enum Operation: Equatable {
    case setVoiceProcessingEnabled(Bool)
    case minimizeOtherAudioDucking
    case enableRecordingOtherAudioDucking
    case configureInputDevice
    case establishOutputPath(AppleVoiceProcessingIOFormat)
    case setBypassed(Bool)
    case setInputMuted(Bool)
    case setAGCEnabled(Bool)
  }

  var isRunning = false
  private(set) var isInputVoiceProcessingEnabled = false
  private(set) var isOutputVoiceProcessingEnabled = false
  var voiceProcessingInputFormat: AppleVoiceProcessingIOFormat? =
    AppleVoiceProcessingIOFormat(sampleRate: 48_000, channelCount: 1)
  private var bypassed = true
  private var inputMuted = true
  private var agcEnabled = false

  var activationError: Error?
  var activationTakesEffect = true
  var outputPathAvailable = true
  var allowsBypassChange = true
  var allowsInputMuteChange = true
  var allowsAGCChange = true
  private(set) var enableRequests: [Bool] = []
  private(set) var outputPathRequestCount = 0
  private(set) var requestedOutputFormats: [AppleVoiceProcessingIOFormat] = []
  private(set) var operations: [Operation] = []

  var isVoiceProcessingBypassed: Bool {
    get { bypassed }
    set {
      operations.append(.setBypassed(newValue))
      if allowsBypassChange {
        bypassed = newValue
      }
    }
  }

  var isVoiceProcessingInputMuted: Bool {
    get { inputMuted }
    set {
      operations.append(.setInputMuted(newValue))
      if allowsInputMuteChange {
        inputMuted = newValue
      }
    }
  }

  var isVoiceProcessingAGCEnabled: Bool {
    get { agcEnabled }
    set {
      operations.append(.setAGCEnabled(newValue))
      if allowsAGCChange {
        agcEnabled = newValue
      }
    }
  }

  func setVoiceProcessingEnabled(_ isEnabled: Bool) throws {
    operations.append(.setVoiceProcessingEnabled(isEnabled))
    enableRequests.append(isEnabled)
    if let activationError {
      throw activationError
    }
    guard activationTakesEffect else { return }
    isInputVoiceProcessingEnabled = isEnabled
    isOutputVoiceProcessingEnabled = isEnabled
  }

  func minimizeOtherAudioDucking() {
    operations.append(.minimizeOtherAudioDucking)
  }

  func enableRecordingOtherAudioDucking() {
    operations.append(.enableRecordingOtherAudioDucking)
  }

  func configureVoiceProcessingInputDevice() throws {
    operations.append(.configureInputDevice)
  }

  func establishVoiceProcessingOutputPath(
    matching format: AppleVoiceProcessingIOFormat
  ) -> Bool {
    operations.append(.establishOutputPath(format))
    outputPathRequestCount += 1
    requestedOutputFormats.append(format)
    return outputPathAvailable
  }
}

private final class TestVoiceProcessingAudioEngineSession:
  AppleVoiceProcessingAudioEngineSession,
  @unchecked Sendable
{
  enum Event: Equatable {
    case configure
    case start
    case stop
  }

  var configurationError: Error?
  var configurationErrors: [AppleVoiceProcessingAudioError] = []
  var startError: Error?
  var startErrors: [AppleVoiceProcessingAudioError] = []
  var retainsBufferHandlerAfterStop = false
  var emulatesConfigurationReuse = false
  var configureHook: (@Sendable () -> Void)?
  var startHook: (@Sendable () -> Void)?
  var stopHook: (@Sendable () -> Void)?
  private(set) var events: [Event] = []
  private(set) var captureFormat: AppleVoiceProcessingCaptureFormat?
  private var bufferHandler: (@Sendable ([Float]) -> Void)?
  private var failureHandler: (@Sendable (AppleVoiceProcessingAudioError) -> Void)?
  private var isConfigured = false

  func configureVoiceProcessing() throws {
    if emulatesConfigurationReuse, isConfigured { return }
    events.append(.configure)
    configureHook?()
    if !configurationErrors.isEmpty {
      isConfigured = false
      throw configurationErrors.removeFirst()
    }
    if let configurationError {
      isConfigured = false
      throw configurationError
    }
    isConfigured = true
  }

  func start(
    format: AppleVoiceProcessingCaptureFormat,
    bufferHandler: @escaping @Sendable ([Float]) -> Void,
    failureHandler: @escaping @Sendable (AppleVoiceProcessingAudioError) -> Void
  ) throws {
    events.append(.start)
    if !startErrors.isEmpty {
      let error = startErrors.removeFirst()
      if emulatesConfigurationReuse, error.permitsOneStartReconfigurationAttempt {
        isConfigured = false
      }
      throw error
    }
    if let startError {
      if emulatesConfigurationReuse {
        isConfigured = false
      }
      throw startError
    }
    captureFormat = format
    self.bufferHandler = bufferHandler
    self.failureHandler = failureHandler
    startHook?()
  }

  func stop() {
    events.append(.stop)
    stopHook?()
    if !retainsBufferHandlerAfterStop {
      bufferHandler = nil
      failureHandler = nil
    }
  }

  func emit(_ buffer: [Float]) {
    bufferHandler?(buffer)
  }

  func fail(_ error: AppleVoiceProcessingAudioError) {
    failureHandler?(error)
  }
}

private final class TestVoiceProcessingAudioEngineSessionFactory:
  AppleVoiceProcessingAudioEngineSessionFactory,
  @unchecked Sendable
{
  let session: TestVoiceProcessingAudioEngineSession
  private let lock = NSLock()
  private(set) var makeCount = 0

  init(session: TestVoiceProcessingAudioEngineSession) {
    self.session = session
  }

  func makeSession(inputDeviceID: AppleVoiceProcessingInputDeviceID?)
    -> any AppleVoiceProcessingAudioEngineSession
  {
    lock.lock()
    makeCount += 1
    lock.unlock()
    return session
  }
}

private final class SequenceVoiceProcessingAudioEngineSessionFactory:
  AppleVoiceProcessingAudioEngineSessionFactory,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var sessions: [TestVoiceProcessingAudioEngineSession]

  init(sessions: [TestVoiceProcessingAudioEngineSession]) {
    self.sessions = sessions
  }

  func makeSession(inputDeviceID: AppleVoiceProcessingInputDeviceID?)
    -> any AppleVoiceProcessingAudioEngineSession
  {
    lock.lock()
    defer { lock.unlock() }
    precondition(!sessions.isEmpty, "The test engine-session factory was exhausted.")
    return sessions.removeFirst()
  }
}

private enum TestFailure: LocalizedError {
  case activation

  var errorDescription: String? {
    "activation failed"
  }
}
