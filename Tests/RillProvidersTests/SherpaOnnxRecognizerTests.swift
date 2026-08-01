import AVFoundation
import Foundation
import XCTest

@testable import RillCore
@testable import RillProviders
@testable import RillSherpaRuntime

final class SherpaOnnxRecognizerTests: XCTestCase {
  func testDefaultsSelectQwenAndAutomaticLanguage() {
    let configuration = SherpaOnnxRecognizer.Configuration()

    XCTAssertEqual(
      configuration.modelIdentifier,
      SherpaOnnxModelID.qwen3ASR06BInt8.rawValue
    )
    XCTAssertNil(configuration.language)
    XCTAssertTrue(configuration.downloadIfNeeded)
    XCTAssertFalse(configuration.prewarm)
    XCTAssertEqual(configuration.threadCount, 2)
    XCTAssertEqual(
      SherpaOnnxRecognizer().capabilities.maximumAudioDurationSeconds,
      120
    )
  }

  func testPinnedModelVariantsBuildTheExpectedRuntimeConfigurations() throws {
    let root = URL(fileURLWithPath: "/models/pinned", isDirectory: true)

    for (modelID, expectedLanguageModel) in [
      (SherpaOnnxModelID.funASRNano08BInt8, "llm.int8.onnx"),
      (SherpaOnnxModelID.funASRNano08BFP16, "llm.fp16.onnx"),
    ] {
      let configuration = SherpaOnnxRecognizer.runtimeConfiguration(
        modelID: modelID,
        modelDirectory: root,
        language: "zh",
        keyterms: [],
        threadCount: 4
      )
      guard case .funASRNano(let funASR) = configuration else {
        return XCTFail("Expected Fun-ASR Nano runtime configuration")
      }
      XCTAssertEqual(funASR.languageModel, root.appendingPathComponent(expectedLanguageModel))
      XCTAssertEqual(
        funASR.tokenizerDirectory,
        root.appendingPathComponent("Qwen3-0.6B", isDirectory: true)
      )
      XCTAssertEqual(funASR.language, "zh")
      XCTAssertEqual(funASR.threadCount, 4)
    }

    for modelID in [
      SherpaOnnxModelID.omnilingualASRCTCV2300MInt8,
      .omnilingualASRCTCV21BInt8,
    ] {
      let configuration = SherpaOnnxRecognizer.runtimeConfiguration(
        modelID: modelID,
        modelDirectory: root,
        language: nil,
        keyterms: [],
        threadCount: 3
      )
      guard case .omnilingualCTC(let omnilingual) = configuration else {
        return XCTFail("Expected Omnilingual runtime configuration")
      }
      XCTAssertEqual(omnilingual.model, root.appendingPathComponent("model.int8.onnx"))
      XCTAssertEqual(omnilingual.tokens, root.appendingPathComponent("tokens.txt"))
      XCTAssertEqual(omnilingual.threadCount, 3)
    }

    let cohereConfiguration = SherpaOnnxRecognizer.runtimeConfiguration(
      modelID: .cohereTranscribe2BInt8,
      modelDirectory: root,
      language: "zh",
      keyterms: [],
      threadCount: 2
    )
    guard case .cohereTranscribe(let cohere) = cohereConfiguration else {
      return XCTFail("Expected Cohere Transcribe runtime configuration")
    }
    XCTAssertEqual(cohere.encoder, root.appendingPathComponent("encoder.int8.onnx"))
    XCTAssertEqual(cohere.encoderData, root.appendingPathComponent("encoder.int8.onnx.data"))
    XCTAssertEqual(cohere.decoder, root.appendingPathComponent("decoder.int8.onnx"))
    XCTAssertEqual(cohere.tokens, root.appendingPathComponent("tokens.txt"))
    XCTAssertEqual(cohere.language, "zh")
  }

  func testPublicRecognizerRejectsPreviewOnlySenseVoiceConfiguration() async throws {
    let modelRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-public-recognizer-preview-gate-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: modelRoot) }
    let recognizer = SherpaOnnxRecognizer(
      configuration: .init(modelIdentifier: SherpaOnnxModelID.senseVoiceSmallInt8.rawValue),
      modelDirectoryURL: modelRoot
    )

    do {
      _ = try await recognizer.prepareModel()
      XCTFail("The public recognizer must reject preview-only model identities.")
    } catch {
      XCTAssertEqual(
        error as? SherpaOnnxRecognizer.RecognizerError,
        .unsupportedModelIdentifier(SherpaOnnxModelID.senseVoiceSmallInt8.rawValue)
      )
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: modelRoot.path))
  }

  func testThreadCountIsBoundedForProductConfiguration() async throws {
    let harness = makeHarness(
      configuration: .init(threadCount: SherpaOnnxRecognizer.maximumThreadCount + 1)
    )

    await assertRecognizerError(
      .invalidThreadCount(SherpaOnnxRecognizer.maximumThreadCount + 1)
    ) {
      try await harness.recognizer.recognize(try makeRequest())
    }
    let installCallCount = await harness.installer.callCount
    XCTAssertEqual(installCallCount, 0)
  }

  func testRecognizerRequiresCapturedFileAudio() async throws {
    let harness = makeHarness()
    let missingAudioRequest = RecognitionRequest(
      runID: UUID(),
      workflow: makeWorkflow(),
      contextSnapshot: .empty
    )

    await assertRecognizerError(.missingCapturedAudio) {
      try await harness.recognizer.recognize(missingAudioRequest)
    }

    let inlineAudio = try CapturedAudio(
      durationSeconds: 1,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .float32),
      inlineData: Data([0])
    )
    let inlineRequest = RecognitionRequest(
      runID: UUID(),
      workflow: makeWorkflow(),
      contextSnapshot: .empty,
      capturedAudio: inlineAudio
    )

    await assertRecognizerError(.fileBackedAudioRequired) {
      try await harness.recognizer.recognize(inlineRequest)
    }
  }

  func testRecognizerRejectsEmptyAndNonFiniteAudioBeforeInstallingModel() async throws {
    let emptyHarness = makeHarness(samples: [])
    await assertRecognizerError(.emptyAudio) {
      try await emptyHarness.recognizer.recognize(try makeRequest())
    }
    let emptyInstallCallCount = await emptyHarness.installer.callCount
    XCTAssertEqual(emptyInstallCallCount, 0)

    let nonFiniteHarness = makeHarness(samples: [0, .nan])
    await assertRecognizerError(.nonFiniteAudioSample(index: 1)) {
      try await nonFiniteHarness.recognizer.recognize(try makeRequest())
    }
    let nonFiniteInstallCallCount = await nonFiniteHarness.installer.callCount
    XCTAssertEqual(nonFiniteInstallCallCount, 0)
  }

  func testCaptureStartupToleranceAcceptsExactCeilingAndRejectsOneFrameOver() {
    let exactDuration = SherpaOnnxRecognizer.maximumAcceptedAudioDurationSeconds
    let oneFrameDuration = 1 / Double(SherpaOnnxRecognizer.targetSampleRate)

    XCTAssertEqual(SherpaOnnxRecognizer.maximumAudioDurationSeconds, 120)
    XCTAssertEqual(exactDuration, 123.1)
    XCTAssertEqual(SherpaOnnxRecognizer.maximumAudioSampleCount, 1_969_600)

    XCTAssertNoThrow(
      try SherpaOnnxRecognizer.validateCapturedAudioDuration(exactDuration)
    )
    XCTAssertThrowsError(
      try SherpaOnnxRecognizer.validateCapturedAudioDuration(
        exactDuration + oneFrameDuration
      )
    ) { error in
      XCTAssertEqual(
        error as? SherpaOnnxRecognizer.RecognizerError,
        .audioTooLong(
          maximumDurationSeconds: SherpaOnnxRecognizer.maximumAudioDurationSeconds
        )
      )
    }

    XCTAssertNoThrow(
      try SherpaOnnxRecognizer.validateEstimatedAudioSampleCount(
        Double(SherpaOnnxRecognizer.maximumAudioSampleCount)
      )
    )
    XCTAssertThrowsError(
      try SherpaOnnxRecognizer.validateEstimatedAudioSampleCount(
        Double(SherpaOnnxRecognizer.maximumAudioSampleCount + 1)
      )
    ) { error in
      XCTAssertEqual(
        error as? SherpaOnnxRecognizer.RecognizerError,
        .audioTooLong(
          maximumDurationSeconds: SherpaOnnxRecognizer.maximumAudioDurationSeconds
        )
      )
    }
  }

  func testOverlongMetadataFailsBeforeLoadingAudioOrInstallingModel() async throws {
    let harness = makeHarness()

    await assertRecognizerError(.audioTooLong(maximumDurationSeconds: 120)) {
      try await harness.recognizer.recognize(
        try makeRequest(
          durationSeconds: SherpaOnnxRecognizer.maximumAcceptedAudioDurationSeconds
            + 1 / Double(SherpaOnnxRecognizer.targetSampleRate)
        )
      )
    }

    XCTAssertEqual(harness.audioLoader.callCount, 0)
    let installCallCount = await harness.installer.callCount
    XCTAssertEqual(installCallCount, 0)
  }

  func testQwenContextBudgetPreservesDefaultOutputCapacity() {
    XCTAssertEqual(SherpaOnnxRecognizer.qwenMaximumTotalLength, 2_048)
    XCTAssertEqual(SherpaOnnxRecognizer.maximumQwenAudioTokenCount, 1_601)
    XCTAssertEqual(SherpaOnnxRecognizer.maximumQwenHotwordTokenCount, 63)
    XCTAssertEqual(SherpaOnnxRecognizer.maximumQwenInputContextTokenCount, 1_679)
    XCTAssertEqual(SherpaOnnxRecognizer.minimumQwenOutputTokenCapacity, 369)
    XCTAssertGreaterThanOrEqual(
      SherpaOnnxRecognizer.minimumQwenOutputTokenCapacity,
      SherpaQwen3ASRConfiguration.defaultMaximumNewTokens
    )
  }

  func testWorkflowOverrideBuildsSenseVoiceConfigurationAndReturnsMetadata() async throws {
    let result = SherpaOfflineRecognitionResult(
      text: " 你好 Rill ",
      language: "zh",
      emotion: "",
      event: "",
      timestamps: [],
      durations: []
    )
    let harness = makeHarness(result: result)
    var workflow = makeWorkflow()
    workflow.metadata[SherpaOnnxRecognizer.workflowModelOverrideMetadataKey] =
      SherpaOnnxModelID.senseVoiceSmallInt8.rawValue
    workflow.metadata[WorkflowMetadataKey.languageOverride] = " zh-CN "

    let recognition = try await harness.recognizer.recognize(
      try makeRequest(workflow: workflow, requestLanguage: " yue ")
    )

    let installCalls = await harness.installer.calls
    let installCall = try XCTUnwrap(installCalls.first)
    XCTAssertEqual(installCall.modelID, .senseVoiceSmallInt8)
    XCTAssertTrue(installCall.downloadIfNeeded)

    let configuration = try XCTUnwrap(harness.runtimeSpy.configurations.first)
    guard case .senseVoice(let senseVoice) = configuration else {
      return XCTFail("Expected a SenseVoice runtime configuration")
    }
    XCTAssertEqual(
      senseVoice.model,
      harness.modelDirectory.appendingPathComponent("model.int8.onnx")
    )
    XCTAssertEqual(
      senseVoice.tokens,
      harness.modelDirectory.appendingPathComponent("tokens.txt")
    )
    XCTAssertEqual(senseVoice.language, "yue")
    XCTAssertEqual(senseVoice.threadCount, 2)

    XCTAssertEqual(recognition.rawText, "你好 Rill")
    XCTAssertEqual(recognition.bestText, "你好 Rill")
    XCTAssertEqual(recognition.metadata["provider"], "sherpa-onnx.local")
    XCTAssertEqual(recognition.metadata["provider.kind"], "sherpa-onnx")
    XCTAssertEqual(
      recognition.metadata["provider.model"],
      SherpaOnnxModelID.senseVoiceSmallInt8.rawValue
    )
    XCTAssertEqual(recognition.metadata["provider.detected_language"], "zh")
  }

  func testQwenConfigurationSanitizesBoundsAndDeduplicatesHotwords() async throws {
    let accepted = Array("abcdefghijklmnop").map(String.init)
    let keyterms =
      [
        "  Rill  ",
        "Rill",
        "bad,comma",
        "bad\ncontrol",
        "\t",
        String(repeating: "x", count: SherpaOnnxRecognizer.maximumQwenHotwordScalarCount + 1),
      ] + accepted
    let harness = makeHarness()

    _ = try await harness.recognizer.recognize(
      try makeRequest(keyterms: keyterms)
    )

    let factoryConfiguration = try XCTUnwrap(harness.runtimeSpy.configurations.first)
    guard case .qwen3(let qwen) = factoryConfiguration else {
      return XCTFail("Expected a Qwen3 runtime configuration")
    }
    XCTAssertEqual(
      qwen.convolutionFrontend,
      harness.modelDirectory.appendingPathComponent("conv_frontend.onnx")
    )
    XCTAssertEqual(
      qwen.encoder,
      harness.modelDirectory.appendingPathComponent("encoder.int8.onnx")
    )
    XCTAssertEqual(
      qwen.decoder,
      harness.modelDirectory.appendingPathComponent("decoder.int8.onnx")
    )
    XCTAssertEqual(
      qwen.tokenizerDirectory,
      harness.modelDirectory.appendingPathComponent("tokenizer", isDirectory: true)
    )
    XCTAssertTrue(qwen.hotwords.isEmpty)

    let requestHotwords = try XCTUnwrap(harness.runtimeSpy.calls.first?.hotwords)
    XCTAssertEqual(requestHotwords.first, "Rill")
    XCTAssertEqual(requestHotwords.count, SherpaOnnxRecognizer.maximumQwenHotwordCount)
    XCTAssertLessThanOrEqual(
      requestHotwords.reduce(0) { $0 + $1.utf8.count },
      SherpaOnnxRecognizer.maximumQwenHotwordUTF8ByteCount
    )
    XCTAssertFalse(requestHotwords.contains("bad,comma"))
    XCTAssertFalse(requestHotwords.contains("bad\ncontrol"))
  }

  func testRuntimeCachesOnlyTheMostRecentExactConfiguration() async throws {
    let harness = makeHarness()
    let request = try makeRequest()

    _ = try await harness.recognizer.recognize(request)
    _ = try await harness.recognizer.recognize(request)

    XCTAssertEqual(harness.runtimeSpy.factoryCallCount, 1)
    XCTAssertEqual(harness.runtimeSpy.transcriptionCallCount, 2)
    XCTAssertEqual(harness.runtimeSpy.sampleRates, [16_000, 16_000])
  }

  func testQwenHotwordsAreIsolatedPerRequestWithoutRebuildingRecognizer() async throws {
    let runtimeSpy = SherpaRuntimeSpy(result: emptySherpaRecognitionResult)
    let runtime = SherpaOnnxRecognizerRuntime(factory: runtimeSpy.factory)
    let hotwordBatches = [["alpha"], ["beta"], []]

    for hotwords in hotwordBatches {
      _ = try await runtime.transcribe(
        configuration: makeRuntimeConfiguration(
          modelRoot: "/models/shared",
          hotwords: hotwords
        ),
        samples: [0.25],
        sampleRate: 16_000
      )
    }

    XCTAssertEqual(runtimeSpy.factoryCallCount, 1)
    XCTAssertEqual(runtimeSpy.calls.map(\.hotwords), hotwordBatches)
    guard case .qwen3(let factoryQwen) = try XCTUnwrap(runtimeSpy.configurations.first) else {
      return XCTFail("Expected a Qwen3 factory configuration")
    }
    XCTAssertTrue(factoryQwen.hotwords.isEmpty)
  }

  func testRuntimeRejectsInvalidQwenHotwordsBeforeCanonicalizingFactoryConfiguration() async {
    let runtimeSpy = SherpaRuntimeSpy(result: emptySherpaRecognitionResult)
    let runtime = SherpaOnnxRecognizerRuntime(factory: runtimeSpy.factory)

    do {
      try await runtime.prepare(
        configuration: makeRuntimeConfiguration(
          modelRoot: "/models/shared",
          hotwords: ["bad,comma"]
        )
      )
      XCTFail("Expected invalid request hotwords to fail before factory construction")
    } catch {
      XCTAssertEqual(
        error as? SherpaOfflineRecognizerError,
        .invalidConfiguration(
          "Qwen3 hotwords must be non-empty and cannot contain commas or control characters"
        )
      )
    }

    XCTAssertEqual(runtimeSpy.factoryCallCount, 0)
  }

  func testConcurrentQwenRequestsRemainActorSerializedAndDoNotMixHotwords() async throws {
    let runtimeSpy = SherpaRuntimeSpy(
      result: emptySherpaRecognitionResult,
      transcriptionDelay: 0.01
    )
    let runtime = SherpaOnnxRecognizerRuntime(factory: runtimeSpy.factory)
    let requests: [(sample: Float, hotwords: [String])] = [
      (0.1, ["alpha"]),
      (0.2, ["beta"]),
      (0.3, []),
      (0.4, ["delta", "echo"]),
    ]

    try await withThrowingTaskGroup(of: Void.self) { group in
      for request in requests {
        group.addTask {
          _ = try await runtime.transcribe(
            configuration: makeRuntimeConfiguration(
              modelRoot: "/models/shared",
              hotwords: request.hotwords
            ),
            samples: [request.sample],
            sampleRate: 16_000
          )
        }
      }
      try await group.waitForAll()
    }

    XCTAssertEqual(runtimeSpy.factoryCallCount, 1)
    XCTAssertEqual(runtimeSpy.maximumConcurrentTranscriptions, 1)
    XCTAssertEqual(runtimeSpy.calls.count, requests.count)
    for request in requests {
      XCTAssertTrue(
        runtimeSpy.calls.contains {
          $0.samples == [request.sample] && $0.hotwords == request.hotwords
        }
      )
    }
  }

  func testRuntimeReleasesPreviousRecognizerBeforeBuildingReplacement() async throws {
    let lifetime = RuntimeLifetimeProbe()
    let runtime = SherpaOnnxRecognizerRuntime { configuration in
      lifetime.factoryDidStart(for: configuration)
      let token = RuntimeLifetimeToken { lifetime.recognizerWasReleased() }
      return SherpaOnnxRuntimeTranscriber { _, _, _ in
        withExtendedLifetime(token) {}
        return .init(
          text: "",
          language: "",
          emotion: "",
          event: "",
          timestamps: [],
          durations: []
        )
      }
    }
    let first = makeRuntimeConfiguration(modelRoot: "/models/first", hotwords: [])
    let second = makeRuntimeConfiguration(modelRoot: "/models/second", hotwords: [])

    try await runtime.prepare(configuration: first)
    try await runtime.prepare(configuration: second)

    XCTAssertEqual(lifetime.releaseCountObservedAtFactoryStart, [0, 1])
  }

  func testLiveAudioLoaderConvertsStereo48KFileToFinite16KMonoSamples() async throws {
    let audioURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-sherpa-audio-\(UUID().uuidString)")
      .appendingPathExtension("wav")
    defer { try? FileManager.default.removeItem(at: audioURL) }
    try writeStereo48KTestAudio(to: audioURL)

    let modelDirectory = URL(fileURLWithPath: "/unit-test/models", isDirectory: true)
    let installer = SherpaModelDirectoryInstallerSpy(modelDirectory: modelDirectory)
    let runtimeSpy = SherpaRuntimeSpy(
      result: .init(
        text: "converted",
        language: "en",
        emotion: "",
        event: "",
        timestamps: [],
        durations: []
      )
    )
    let recognizer = SherpaOnnxRecognizer(
      modelDirectoryInstaller: installer,
      audioSampleLoader: SherpaOnnxAVAudioSampleLoader(),
      runtime: SherpaOnnxRecognizerRuntime(factory: runtimeSpy.factory)
    )
    let capturedAudio = try CapturedAudio(
      durationSeconds: 0.1,
      format: AudioFormat(sampleRateHz: 48_000, channelCount: 2, encoding: .float32),
      fileURL: audioURL
    )

    _ = try await recognizer.recognize(
      RecognitionRequest(
        runID: UUID(),
        workflow: makeWorkflow(),
        contextSnapshot: .empty,
        capturedAudio: capturedAudio
      )
    )

    let samples = try XCTUnwrap(runtimeSpy.transcribedSamples.first)
    XCTAssertEqual(runtimeSpy.sampleRates, [16_000])
    XCTAssertTrue((1_590...1_610).contains(samples.count))
    XCTAssertTrue(samples.allSatisfy(\.isFinite))
    XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0, 0.05)
  }

  func testPrepareHonorsDownloadPolicyAndPrewarmsConfiguredModel() async throws {
    let configuration = SherpaOnnxRecognizer.Configuration(
      modelIdentifier: SherpaOnnxModelID.senseVoiceSmallInt8.rawValue,
      language: nil,
      downloadIfNeeded: false,
      prewarm: true,
      threadCount: 3
    )
    let harness = makeHarness(configuration: configuration)
    let progress = LockedValues<SherpaOnnxModelInstallationProgress>()

    let preparedModel = try await harness.recognizer.prepareModel { value in
      progress.append(value)
    }

    XCTAssertEqual(preparedModel, SherpaOnnxModelID.senseVoiceSmallInt8.rawValue)
    let installCalls = await harness.installer.calls
    let installCall = try XCTUnwrap(installCalls.first)
    XCTAssertEqual(installCall.modelID, .senseVoiceSmallInt8)
    XCTAssertFalse(installCall.downloadIfNeeded)
    XCTAssertTrue(installCall.hadProgressCallback)
    XCTAssertEqual(progress.values.last?.phase, .complete)
    XCTAssertEqual(harness.runtimeSpy.factoryCallCount, 1)

    let runtimeConfiguration = try XCTUnwrap(harness.runtimeSpy.configurations.first)
    guard case .senseVoice(let senseVoice) = runtimeConfiguration else {
      return XCTFail("Expected a prewarmed SenseVoice runtime")
    }
    XCTAssertEqual(senseVoice.language, "")
    XCTAssertEqual(senseVoice.threadCount, 3)
  }

  func testPrepareWithPrewarmDisabledInstallsWithoutConstructingNativeRuntime() async throws {
    let harness = makeHarness(
      configuration: .init(
        modelIdentifier: SherpaOnnxModelID.qwen3ASR06BInt8.rawValue,
        downloadIfNeeded: false,
        prewarm: false
      )
    )

    let preparedModel = try await harness.recognizer.prepareModel()
    let installCallCount = await harness.installer.callCount

    XCTAssertEqual(preparedModel, SherpaOnnxModelID.qwen3ASR06BInt8.rawValue)
    XCTAssertEqual(installCallCount, 1)
    XCTAssertEqual(harness.runtimeSpy.factoryCallCount, 0)
  }

  func testDisablingRuntimeReleasesCacheAndRejectsLatePreparationLease() async throws {
    let lifetime = RuntimeLifetimeProbe()
    let runtime = SherpaOnnxRecognizerRuntime { configuration in
      lifetime.factoryDidStart(for: configuration)
      let token = RuntimeLifetimeToken { lifetime.recognizerWasReleased() }
      return SherpaOnnxRuntimeTranscriber { _, _, _ in
        withExtendedLifetime(token) {}
        return emptySherpaRecognitionResult
      }
    }
    let configuration = makeRuntimeConfiguration(modelRoot: "/models/retained", hotwords: [])
    let staleLease = try runtime.makeRetentionLease()
    try await runtime.prepare(configuration: configuration, lease: staleLease)

    let disabledGeneration = runtime.setRetentionEnabled(false)
    await runtime.releaseCachedRecognizer(olderThan: disabledGeneration)

    XCTAssertEqual(lifetime.releaseCount, 1)
    do {
      try await runtime.prepare(configuration: configuration, lease: staleLease)
      XCTFail("A preparation lease from before disable must not refill the cache.")
    } catch is CancellationError {
    }
    XCTAssertEqual(lifetime.releaseCountObservedAtFactoryStart.count, 1)

    _ = runtime.setRetentionEnabled(true)
    try await runtime.prepare(configuration: configuration)
    XCTAssertEqual(lifetime.releaseCountObservedAtFactoryStart.count, 2)
  }

  func testReleaseWaitsForActiveTranscriptionThenDropsNativeCache() async throws {
    let lifetime = RuntimeLifetimeProbe()
    let decodeGate = RuntimeDecodeGate()
    let runtime = SherpaOnnxRecognizerRuntime { configuration in
      lifetime.factoryDidStart(for: configuration)
      let token = RuntimeLifetimeToken { lifetime.recognizerWasReleased() }
      return SherpaOnnxRuntimeTranscriber { _, _, _ in
        decodeGate.blockUntilReleased()
        withExtendedLifetime(token) {}
        return emptySherpaRecognitionResult
      }
    }
    let configuration = makeRuntimeConfiguration(modelRoot: "/models/active", hotwords: [])
    let decodeTask = Task {
      try await runtime.transcribe(
        configuration: configuration,
        samples: [0.25],
        sampleRate: 16_000
      )
    }
    await decodeGate.waitUntilStarted()

    let disabledGeneration = runtime.setRetentionEnabled(false)
    let releaseTask = Task {
      await runtime.releaseCachedRecognizer(olderThan: disabledGeneration)
    }
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(lifetime.releaseCount, 0)

    decodeGate.release()
    _ = try await decodeTask.value
    await releaseTask.value
    XCTAssertEqual(lifetime.releaseCount, 1)
  }

  func testStopRuntimeReturnsWhileDecodeIsBlockedThenReleasesNativeCache() async throws {
    let lifetime = RuntimeLifetimeProbe()
    let decodeGate = RuntimeDecodeGate()
    let runtime = SherpaOnnxRecognizerRuntime { configuration in
      lifetime.factoryDidStart(for: configuration)
      let token = RuntimeLifetimeToken { lifetime.recognizerWasReleased() }
      return SherpaOnnxRuntimeTranscriber { _, _, _ in
        decodeGate.blockUntilReleased()
        withExtendedLifetime(token) {}
        return emptySherpaRecognitionResult
      }
    }
    let recognizer = SherpaOnnxRecognizer(
      modelDirectoryInstaller: SherpaModelDirectoryInstallerSpy(
        modelDirectory: URL(fileURLWithPath: "/models/stop-runtime", isDirectory: true)
      ),
      audioSampleLoader: SherpaAudioSampleLoaderSpy(samples: []),
      runtime: runtime
    )
    let configuration = makeRuntimeConfiguration(
      modelRoot: "/models/stop-runtime",
      hotwords: []
    )
    let decodeTask = Task {
      try await runtime.transcribe(
        configuration: configuration,
        samples: [0.25],
        sampleRate: 16_000
      )
    }
    await decodeGate.waitUntilStarted()
    defer { decodeGate.release() }

    let stopped = expectation(description: "stopRuntime returns while native decode is blocked")
    let stopTask = Task {
      await recognizer.stopRuntime()
      stopped.fulfill()
    }
    await fulfillment(of: [stopped], timeout: 1)

    XCTAssertThrowsError(try runtime.makeRetentionLease()) { error in
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(lifetime.releaseCount, 0)

    decodeGate.release()
    _ = try await decodeTask.value
    await stopTask.value
    for _ in 0..<200 where lifetime.releaseCount == 0 {
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertEqual(lifetime.releaseCount, 1)
  }

  func testUnknownWorkflowModelFailsClosedBeforeAudioOrNetworkWork() async throws {
    let harness = makeHarness()
    var workflow = makeWorkflow()
    workflow.metadata[SherpaOnnxRecognizer.workflowModelOverrideMetadataKey] = "unknown"

    await assertRecognizerError(.unsupportedModelIdentifier("unknown")) {
      try await harness.recognizer.recognize(try makeRequest(workflow: workflow))
    }
    let installCallCount = await harness.installer.callCount
    XCTAssertEqual(installCallCount, 0)
    XCTAssertEqual(harness.audioLoader.callCount, 0)
  }
}

final class SherpaOnnxRecognizerDogfoodTests: XCTestCase {
  func testPinnedQwenFixtureThroughProductionRecognizerWhenExplicitlyEnabled() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RILL_RUN_SHERPA_PROVIDER_DOGFOOD"] == "1" else {
      throw XCTSkip(
        "Set RILL_RUN_SHERPA_PROVIDER_DOGFOOD=1 to run the production Qwen fixture."
      )
    }
    guard let modelRootPath = environment["RILL_SHERPA_MODEL_ROOT"],
      let audioPath = environment["RILL_SHERPA_AUDIO"],
      let expectedSubstring = environment["RILL_SHERPA_EXPECTED_SUBSTRING"]?.trimmingCharacters(
        in: .whitespacesAndNewlines
      ),
      !expectedSubstring.isEmpty
    else {
      return XCTFail(
        "RILL_SHERPA_MODEL_ROOT, RILL_SHERPA_AUDIO, and "
          + "RILL_SHERPA_EXPECTED_SUBSTRING are required."
      )
    }
    let hotwords: [String]
    if let hotword = environment["RILL_SHERPA_HOTWORD"]?.trimmingCharacters(
      in: .whitespacesAndNewlines
    ), !hotword.isEmpty {
      hotwords = [hotword]
    } else {
      hotwords = []
    }
    let hotwordBatches =
      environment["RILL_SHERPA_EXERCISE_HOTWORD_SWITCHING"] == "1"
      ? [["Rill"], ["voice"], []]
      : [hotwords]

    let sourceAudioURL = URL(fileURLWithPath: audioPath)
    let sourceAudioFile = try AVAudioFile(forReading: sourceAudioURL)
    var audioURL = sourceAudioURL
    var audioFormat = AudioFormat(
      sampleRateHz: sourceAudioFile.processingFormat.sampleRate,
      channelCount: Int(sourceAudioFile.processingFormat.channelCount),
      encoding: .pcm16
    )
    var durationSeconds =
      Double(sourceAudioFile.length) / sourceAudioFile.processingFormat.sampleRate
    var generatedAudioURL: URL?
    if environment["RILL_SHERPA_EXERCISE_CAPTURE_WRITER"] == "1" {
      let samples = try SherpaOnnxAVAudioSampleLoader().loadSamples(from: sourceAudioURL)
      let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("rill-qwen-writer-dogfood-\(UUID().uuidString)")
        .appendingPathExtension("wav")
      let writer = try LocalSpeechIncrementalWaveWriter(
        fileURL: outputURL,
        maximumFrameCount: samples.count
      )
      var offset = 0
      while offset < samples.count {
        let end = min(offset + LocalSpeechIncrementalWaveWriter.framesPerWrite, samples.count)
        try writer.append(Array(samples[offset..<end]))
        offset = end
      }
      let artifact = try writer.finalize()
      audioURL = artifact.fileURL
      audioFormat = AudioFormat(
        sampleRateHz: LocalSpeechIncrementalWaveWriter.sampleRateHz,
        channelCount: 1,
        encoding: .float32
      )
      durationSeconds =
        Double(artifact.frameCount) / LocalSpeechIncrementalWaveWriter.sampleRateHz
      generatedAudioURL = artifact.fileURL
    }
    defer {
      if let generatedAudioURL {
        try? FileManager.default.removeItem(at: generatedAudioURL)
      }
    }

    let audioFile = try AVAudioFile(forReading: audioURL)
    XCTAssertEqual(
      audioFile.length,
      AVAudioFramePosition((durationSeconds * audioFile.processingFormat.sampleRate).rounded())
    )
    let recognizer = SherpaOnnxRecognizer(
      configuration: .init(downloadIfNeeded: false),
      modelDirectoryURL: URL(fileURLWithPath: modelRootPath, isDirectory: true)
    )
    let capturedAudio = try CapturedAudio(
      durationSeconds: durationSeconds,
      format: audioFormat,
      fileURL: audioURL
    )

    for hotwordBatch in hotwordBatches {
      let result = try await recognizer.recognize(
        RecognitionRequest(
          runID: UUID(),
          workflow: makeWorkflow(),
          contextSnapshot: .empty,
          capturedAudio: capturedAudio,
          options: SpeechRecognitionRequestOptions(
            hints: RecognitionHints(keyterms: hotwordBatch)
          )
        )
      )
      XCTAssertFalse(result.bestText.isEmpty)
      XCTAssertTrue(
        result.bestText.localizedCaseInsensitiveContains(expectedSubstring),
        "Expected the production transcript to contain '\(expectedSubstring)'."
      )
      if environment["RILL_SHERPA_REQUIRE_CJK"] == "1" {
        XCTAssertTrue(
          result.bestText.unicodeScalars.contains { scalar in
            (0x3400...0x9FFF).contains(scalar.value)
          },
          "Expected the production transcript to retain CJK text."
        )
      }
      XCTAssertEqual(result.metadata["provider"], "sherpa-onnx.local")
      XCTAssertEqual(result.metadata["provider.kind"], "sherpa-onnx")
      XCTAssertEqual(
        result.metadata["provider.model"],
        SherpaOnnxModelID.qwen3ASR06BInt8.rawValue
      )
    }
  }
}

private final class RuntimeLifetimeProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var releases = 0
  private var observations: [Int] = []

  var releaseCountObservedAtFactoryStart: [Int] {
    lock.withLock { observations }
  }

  var releaseCount: Int {
    lock.withLock { releases }
  }

  func factoryDidStart(for _: SherpaOfflineModelConfiguration) {
    lock.withLock { observations.append(releases) }
  }

  func recognizerWasReleased() {
    lock.withLock { releases += 1 }
  }
}

private final class RuntimeDecodeGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var started = false
  private var isReleased = false

  func blockUntilReleased() {
    condition.lock()
    started = true
    condition.broadcast()
    while !isReleased {
      condition.wait()
    }
    condition.unlock()
  }

  func waitUntilStarted() async {
    while true {
      if hasStarted() { return }
      await Task.yield()
    }
  }

  private func hasStarted() -> Bool {
    condition.lock()
    defer { condition.unlock() }
    return started
  }

  func release() {
    condition.lock()
    isReleased = true
    condition.broadcast()
    condition.unlock()
  }
}

private final class RuntimeLifetimeToken: @unchecked Sendable {
  private let onDeinit: @Sendable () -> Void

  init(onDeinit: @escaping @Sendable () -> Void) {
    self.onDeinit = onDeinit
  }

  deinit {
    onDeinit()
  }
}

private func makeRuntimeConfiguration(
  modelRoot: String,
  hotwords: [String]
) -> SherpaOfflineModelConfiguration {
  let root = URL(fileURLWithPath: modelRoot, isDirectory: true)
  return .qwen3(
    SherpaQwen3ASRConfiguration(
      convolutionFrontend: root.appendingPathComponent("conv_frontend.onnx"),
      encoder: root.appendingPathComponent("encoder.int8.onnx"),
      decoder: root.appendingPathComponent("decoder.int8.onnx"),
      tokenizerDirectory: root.appendingPathComponent("tokenizer", isDirectory: true),
      hotwords: hotwords
    )
  )
}

private struct SherpaRecognizerHarness {
  let recognizer: SherpaOnnxRecognizer
  let installer: SherpaModelDirectoryInstallerSpy
  let audioLoader: SherpaAudioSampleLoaderSpy
  let runtimeSpy: SherpaRuntimeSpy
  let modelDirectory: URL
}

private func makeHarness(
  configuration: SherpaOnnxRecognizer.Configuration = .init(),
  samples: [Float] = [0.1, -0.1, 0.2],
  result: SherpaOfflineRecognitionResult = .init(
    text: "hello",
    language: "",
    emotion: "",
    event: "",
    timestamps: [],
    durations: []
  )
) -> SherpaRecognizerHarness {
  let modelDirectory = URL(fileURLWithPath: "/unit-test/models", isDirectory: true)
  let installer = SherpaModelDirectoryInstallerSpy(modelDirectory: modelDirectory)
  let audioLoader = SherpaAudioSampleLoaderSpy(samples: samples)
  let runtimeSpy = SherpaRuntimeSpy(result: result)
  let runtime = SherpaOnnxRecognizerRuntime(factory: runtimeSpy.factory)
  let recognizer = SherpaOnnxRecognizer(
    configuration: configuration,
    modelDirectoryInstaller: installer,
    audioSampleLoader: audioLoader,
    runtime: runtime
  )
  return SherpaRecognizerHarness(
    recognizer: recognizer,
    installer: installer,
    audioLoader: audioLoader,
    runtimeSpy: runtimeSpy,
    modelDirectory: modelDirectory
  )
}

private actor SherpaModelDirectoryInstallerSpy: SherpaOnnxModelDirectoryInstalling {
  struct Call: Sendable {
    let modelID: SherpaOnnxModelID
    let downloadIfNeeded: Bool
    let hadProgressCallback: Bool
  }

  let modelDirectory: URL
  private(set) var calls: [Call] = []

  init(modelDirectory: URL) {
    self.modelDirectory = modelDirectory
  }

  var callCount: Int { calls.count }

  func modelDirectory(
    for descriptor: SherpaOnnxModelDescriptor,
    downloadIfNeeded: Bool,
    progressCallback: (@Sendable (SherpaOnnxModelInstallationProgress) -> Void)?
  ) async throws -> URL {
    calls.append(
      Call(
        modelID: descriptor.id,
        downloadIfNeeded: downloadIfNeeded,
        hadProgressCallback: progressCallback != nil
      )
    )
    progressCallback?(
      .init(
        phase: .complete,
        completedByteCount: descriptor.archiveByteCount,
        totalByteCount: descriptor.archiveByteCount
      )
    )
    return modelDirectory
  }
}

private final class SherpaAudioSampleLoaderSpy: SherpaOnnxAudioSampleLoading, @unchecked Sendable {
  private let lock = NSLock()
  private let samples: [Float]
  private var storedCallCount = 0

  init(samples: [Float]) {
    self.samples = samples
  }

  var callCount: Int {
    lock.withLock { storedCallCount }
  }

  func loadSamples(from _: URL) throws -> [Float] {
    lock.withLock { storedCallCount += 1 }
    return samples
  }
}

private final class SherpaRuntimeSpy: @unchecked Sendable {
  struct Call: Equatable, Sendable {
    let samples: [Float]
    let sampleRate: Int
    let hotwords: [String]
  }

  private let lock = NSLock()
  private let result: SherpaOfflineRecognitionResult
  private let transcriptionDelay: TimeInterval
  private var storedConfigurations: [SherpaOfflineModelConfiguration] = []
  private var storedFactoryCallCount = 0
  private var storedCalls: [Call] = []
  private var activeTranscriptionCount = 0
  private var storedMaximumConcurrentTranscriptions = 0

  init(
    result: SherpaOfflineRecognitionResult,
    transcriptionDelay: TimeInterval = 0
  ) {
    self.result = result
    self.transcriptionDelay = transcriptionDelay
  }

  var configurations: [SherpaOfflineModelConfiguration] {
    lock.withLock { storedConfigurations }
  }

  var factoryCallCount: Int {
    lock.withLock { storedFactoryCallCount }
  }

  var transcriptionCallCount: Int {
    lock.withLock { storedCalls.count }
  }

  var sampleRates: [Int] {
    lock.withLock { storedCalls.map(\.sampleRate) }
  }

  var transcribedSamples: [[Float]] {
    lock.withLock { storedCalls.map(\.samples) }
  }

  var calls: [Call] {
    lock.withLock { storedCalls }
  }

  var maximumConcurrentTranscriptions: Int {
    lock.withLock { storedMaximumConcurrentTranscriptions }
  }

  var factory: SherpaOnnxRecognizerRuntime.Factory {
    { [self] configuration in
      lock.withLock {
        storedConfigurations.append(configuration)
        storedFactoryCallCount += 1
      }
      return SherpaOnnxRuntimeTranscriber { [self] samples, sampleRate, hotwords in
        lock.withLock {
          activeTranscriptionCount += 1
          storedMaximumConcurrentTranscriptions = max(
            storedMaximumConcurrentTranscriptions,
            activeTranscriptionCount
          )
        }
        if transcriptionDelay > 0 {
          Thread.sleep(forTimeInterval: transcriptionDelay)
        }
        lock.withLock {
          storedCalls.append(
            Call(samples: samples, sampleRate: sampleRate, hotwords: hotwords)
          )
          activeTranscriptionCount -= 1
        }
        return result
      }
    }
  }
}

private let emptySherpaRecognitionResult = SherpaOfflineRecognitionResult(
  text: "",
  language: "",
  emotion: "",
  event: "",
  timestamps: [],
  durations: []
)

private func writeStereo48KTestAudio(to url: URL) throws {
  let format = try XCTUnwrap(
    AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 48_000,
      channels: 2,
      interleaved: false
    )
  )
  let frameCount: AVAudioFrameCount = 4_800
  let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
  buffer.frameLength = frameCount
  let channels = try XCTUnwrap(buffer.floatChannelData)
  for frame in 0..<Int(frameCount) {
    let sample = Float(sin(2 * Double.pi * 440 * Double(frame) / 48_000)) * 0.25
    channels[0][frame] = sample
    channels[1][frame] = sample * 0.5
  }
  var fileSettings = format.settings
  fileSettings[AVLinearPCMIsNonInterleaved] = false
  let file = try AVAudioFile(forWriting: url, settings: fileSettings)
  try file.write(from: buffer)
}

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValues: [Value] = []

  var values: [Value] {
    lock.withLock { storedValues }
  }

  func append(_ value: Value) {
    lock.withLock { storedValues.append(value) }
  }
}

private func makeRequest(
  workflow: WorkflowDefinition = makeWorkflow(),
  requestLanguage: String? = nil,
  keyterms: [String] = [],
  durationSeconds: Double = 1
) throws -> RecognitionRequest {
  let capturedAudio = try CapturedAudio(
    durationSeconds: durationSeconds,
    format: AudioFormat(sampleRateHz: 48_000, channelCount: 2, encoding: .float32),
    fileURL: URL(fileURLWithPath: "/unit-test/audio.wav")
  )
  return RecognitionRequest(
    runID: UUID(),
    workflow: workflow,
    contextSnapshot: .empty,
    capturedAudio: capturedAudio,
    options: SpeechRecognitionRequestOptions(
      language: requestLanguage,
      hints: RecognitionHints(keyterms: keyterms)
    )
  )
}

private func makeWorkflow() -> WorkflowDefinition {
  WorkflowDefinition(
    name: "Sherpa test",
    pipeline: PipelineDeclaration(
      recognizerID: "sherpa-onnx.local",
      outputActions: []
    ),
    ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "teal")
  )
}

private func assertRecognizerError(
  _ expected: SherpaOnnxRecognizer.RecognizerError,
  operation: () async throws -> RecognitionResult,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await operation()
    XCTFail("Expected \(expected)", file: file, line: line)
  } catch let error as SherpaOnnxRecognizer.RecognizerError {
    XCTAssertEqual(error, expected, file: file, line: line)
  } catch {
    XCTFail("Unexpected error: \(error)", file: file, line: line)
  }
}
