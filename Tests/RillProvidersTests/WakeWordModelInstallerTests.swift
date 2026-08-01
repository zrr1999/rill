@preconcurrency import AVFoundation
import Foundation
import RillCore
import RillSherpaRuntime
import XCTest

@testable import RillProviders

final class WakeWordModelInstallerTests: XCTestCase {
  func testSharedDownloaderAllowsOnlyReviewedASRAndKWSReleaseNamespaces() {
    XCTAssertTrue(
      SherpaOnnxURLSessionArchiveDownloader.isAllowedSourceURL(
        WakeWordModelCatalog.defaultModel.archiveURL
      )
    )
    XCTAssertTrue(
      SherpaOnnxURLSessionArchiveDownloader.isAllowedSourceURL(
        URL(
          string:
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/model.tar.bz2"
        )!
      )
    )
    for rejectedURL in [
      "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/model.tar.bz2",
      "https://github.com/other/sherpa-onnx/releases/download/kws-models/model.tar.bz2",
      "https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/model.tar.bz2?x=1",
    ] {
      XCTAssertFalse(
        SherpaOnnxURLSessionArchiveDownloader.isAllowedSourceURL(
          URL(string: rejectedURL)!
        )
      )
    }
  }

  func testCatalogPinsExactArchiveInventoryAndLicenseEvidence() throws {
    let descriptor = WakeWordModelCatalog.defaultModel

    XCTAssertEqual(
      descriptor.archiveURL.absoluteString,
      "https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/"
        + "sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20.tar.bz2"
    )
    XCTAssertEqual(descriptor.archiveByteCount, 32_885_699)
    XCTAssertEqual(
      descriptor.archiveSHA256,
      "68447f4fbc67e70eee3a93961f36e81e98f47aef73ce7e7ca00885c6cd3616a6"
    )
    XCTAssertEqual(
      descriptor.archiveRootDirectoryName,
      "sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20"
    )
    XCTAssertEqual(
      descriptor.retainedFiles.map(\.sourceRelativePath),
      [
        "encoder-epoch-13-avg-2-chunk-8-left-64.int8.onnx",
        "decoder-epoch-13-avg-2-chunk-8-left-64.onnx",
        "joiner-epoch-13-avg-2-chunk-8-left-64.int8.onnx",
        "tokens.txt",
        "en.phone",
      ]
    )
    XCTAssertEqual(
      descriptor.retainedFiles.map(\.byteCount),
      [4_600_657, 759_829, 86_629, 1_928, 3_330_061]
    )
    XCTAssertEqual(
      descriptor.retainedFiles.map(\.sha256),
      [
        "2ca84d6bfe73e1ea3c9c49f600f7cad1c9ddd423c53c906b8bfe802444dd78d5",
        "63a22dd60f40fff082ac3e09afa507f6787da36df76ded2fbe145fa233e22c21",
        "190d4067b4cc20b72a42a1916e69d92052000fb7051a427ebb1bc72a69207dc1",
        "2d3f32311f9b692b964da3c90e830258d3e78e013cb0c992dbfb15cd5a1a71b0",
        "f7000ec3a90544c0c7c16090d8951779c2b322e14dad5006290f498567d439ea",
      ]
    )

    XCTAssertTrue(descriptor.distributionLicenseVerified)
    let evidence = try XCTUnwrap(descriptor.distributionLicenseEvidence)
    XCTAssertEqual(evidence.licenseExpression, "Apache-2.0")
    XCTAssertEqual(
      evidence.sourceURL.absoluteString,
      "https://modelscope.cn/models/pkufool/"
        + "icefall-kws-zipformer-zh-en-3M-2025-12-20/resolve/"
        + "541d04e28be57efc6fdf46a341da09e043a37b52/README.md"
    )
    XCTAssertEqual(
      evidence.sourceRevision,
      "541d04e28be57efc6fdf46a341da09e043a37b52"
    )
    XCTAssertEqual(
      evidence.sourceSHA256,
      "34d92bb4dc9fb259efb67f329d2cd68f6e0a6226121a694a3b6b4c748378559c"
    )
    XCTAssertEqual(evidence.upstreamNotice, .notProvidedByPublisher)
  }

  func testMalformedLicenseEvidenceDoesNotEnableDistribution() throws {
    let reviewed = WakeWordModelCatalog.defaultModel
    let reviewedEvidence = try XCTUnwrap(reviewed.distributionLicenseEvidence)
    let malformedEvidence = WakeWordModelLicenseEvidence(
      licenseExpression: "Apache-2.0",
      sourceURL: reviewedEvidence.sourceURL,
      sourceRevision: reviewedEvidence.sourceRevision,
      sourceSHA256: "not-a-sha256",
      upstreamNotice: .notProvidedByPublisher
    )
    let descriptor = WakeWordModelDescriptor(
      id: reviewed.id,
      archiveURL: reviewed.archiveURL,
      archiveByteCount: reviewed.archiveByteCount,
      archiveSHA256: reviewed.archiveSHA256,
      archiveRootDirectoryName: reviewed.archiveRootDirectoryName,
      retainedFiles: reviewed.retainedFiles,
      distributionLicenseEvidence: malformedEvidence
    )

    XCTAssertFalse(malformedEvidence.isValid)
    XCTAssertFalse(descriptor.distributionLicenseVerified)
  }

  func testReleaseInstallerRejectsDescriptorWithoutLicenseEvidenceBeforeNetwork() async throws {
    let reviewed = WakeWordModelCatalog.defaultModel
    let unverified = WakeWordModelDescriptor(
      id: reviewed.id,
      archiveURL: reviewed.archiveURL,
      archiveByteCount: reviewed.archiveByteCount,
      archiveSHA256: reviewed.archiveSHA256,
      archiveRootDirectoryName: reviewed.archiveRootDirectoryName,
      retainedFiles: reviewed.retainedFiles,
      distributionLicenseEvidence: nil
    )
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-kws-license-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: destination) }
    let installer = WakeWordModelInstaller(
      destinationRootURL: destination,
      descriptor: unverified,
      allowsUnverifiedModelLicense: false
    )

    do {
      _ = try await installer.install()
      XCTFail("Expected an unverified model to be rejected before download.")
    } catch let error as WakeWordModelInstallationError {
      XCTAssertEqual(error, .distributionLicenseUnverified)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  func testPinnedArchiveInstallsAndInitializesProductionKWSWhenExplicitlyEnabled() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RILL_RUN_WAKE_WORD_INSTALL_DOGFOOD"] == "1" else {
      throw XCTSkip(
        "Set RILL_RUN_WAKE_WORD_INSTALL_DOGFOOD=1 to download, install, and initialize KWS."
      )
    }

    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-kws-install-dogfood-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: destination) }
    let installer = WakeWordModelInstaller(
      destinationRootURL: destination,
      allowsUnverifiedModelLicense: false
    )

    let installation = try await installer.install()
    let tokenizer = try WakePhraseTokenizer(
      tokensURL: installation.tokens,
      englishLexiconURL: installation.englishLexicon
    )
    let phrases = environment["RILL_WAKE_WORD_PHRASES"]?
      .split(whereSeparator: \.isNewline)
      .map(String.init) ?? [environment["RILL_WAKE_WORD_PHRASE"] ?? "Hey Rill"]
    let encoded = try tokenizer.encode(WakeWordConfiguration(phrases: phrases))
    let keywordDefinitions: String
    if let rawKeywords = environment["RILL_WAKE_WORD_RAW_KEYWORDS"] {
      keywordDefinitions = rawKeywords
    } else if
      let scoreText = environment["RILL_WAKE_WORD_KEYWORD_SCORE"],
      let thresholdText = environment["RILL_WAKE_WORD_KEYWORD_THRESHOLD"],
      let score = Float(scoreText),
      let threshold = Float(thresholdText)
    {
      keywordDefinitions = encoded.map { phrase in
        let label = phrase.phrase.replacingOccurrences(of: " ", with: "_")
        return "\(phrase.tokens.joined(separator: " ")) "
          + ":\(score) #\(threshold) @\(label)"
      }.joined(separator: "\n")
    } else {
      keywordDefinitions = encoded.map(\.keywordDefinition).joined(separator: "\n")
    }
    let spotter = try SherpaKeywordSpotter(
      configuration: SherpaKeywordSpotterConfiguration(
        encoder: installation.encoder,
        decoder: installation.decoder,
        joiner: installation.joiner,
        tokens: installation.tokens,
        keywords: keywordDefinitions
      )
    )
    try spotter.reset()

    if let audioPath = environment["RILL_WAKE_WORD_AUDIO"] {
      var samples = try SherpaOnnxAVAudioSampleLoader().loadSamples(
        from: URL(fileURLWithPath: audioPath)
      )
      samples.append(contentsOf: repeatElement(0, count: 16_000))
      var detection: SherpaKeywordDetection?
      for offset in stride(from: 0, to: samples.count, by: 1_600) {
        let end = min(offset + 1_600, samples.count)
        let rawSamples = Array(samples[offset..<end])
        let keywordSamples =
          environment["RILL_WAKE_WORD_DISABLE_CONDITIONER"] == "1"
          ? rawSamples
          : WakeWordAudioConditioner.prepare(rawSamples)
        if let result = try spotter.accept(samples: keywordSamples) {
          detection = result
          break
        }
      }
      XCTAssertNotNil(
        detection,
        "Expected the pinned KWS fixture to trigger one of \(phrases)."
      )
    }

    let receiptURL = installation.modelDirectory
      .appendingPathComponent(".rill-wake-word-model.json")
    let receiptData = try Data(contentsOf: receiptURL)
    let receipt = try XCTUnwrap(
      JSONSerialization.jsonObject(with: receiptData) as? [String: Any]
    )
    XCTAssertEqual(receipt["schemaVersion"] as? Int, 2)
    let evidence = try XCTUnwrap(
      receipt["distributionLicenseEvidence"] as? [String: Any]
    )
    XCTAssertEqual(evidence["licenseExpression"] as? String, "Apache-2.0")
    XCTAssertEqual(
      evidence["sourceSHA256"] as? String,
      "34d92bb4dc9fb259efb67f329d2cd68f6e0a6226121a694a3b6b4c748378559c"
    )
  }

  func testRawMicrophoneFrontendTriggersProductionKWSWhenExplicitlyEnabled() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RILL_RUN_RAW_MIC_KWS_DOGFOOD"] == "1" else {
      throw XCTSkip(
        "Set RILL_RUN_RAW_MIC_KWS_DOGFOOD=1 to play a local phrase and exercise the real microphone frontend."
      )
    }

    let applicationSupport = try XCTUnwrap(
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    )
    let installer = WakeWordModelInstaller(
      destinationRootURL:
        applicationSupport
        .appendingPathComponent("Rill", isDirectory: true)
        .appendingPathComponent("Models", isDirectory: true)
        .appendingPathComponent("wake-word", isDirectory: true),
      allowsUnverifiedModelLicense: false
    )
    let installedModel = try await installer.installedModel()
    let installation = try XCTUnwrap(
      installedModel,
      "Install the pinned KWS model in Rill before running hardware dogfood."
    )
    let tokenizer = try WakePhraseTokenizer(
      tokensURL: installation.tokens,
      englishLexiconURL: installation.englishLexicon
    )
    let phrases = environment["RILL_WAKE_WORD_PHRASES"]?
      .split(whereSeparator: \.isNewline)
      .map(String.init) ?? ["Hey Rill", "你好瑞尔"]
    let encoded = try tokenizer.encode(WakeWordConfiguration(phrases: phrases))
    let spotter = try SherpaKeywordSpotter(
      configuration: SherpaKeywordSpotterConfiguration(
        encoder: installation.encoder,
        decoder: installation.decoder,
        joiner: installation.joiner,
        tokens: installation.tokens,
        keywords: encoded.map(\.keywordDefinition).joined(separator: "\n")
      )
    )
    let processor = AppleVoiceProcessingAudioProcessor(
      sessionFactory: LiveRawMicrophoneAudioEngineSessionFactory()
    )
    let (stream, continuation) = processor.startStreamingRecordingLive(
      inputDeviceID: nil
    )
    defer {
      continuation.finish()
      processor.stopRecording()
    }

    let speechTask = Task {
      try await Task.sleep(for: .milliseconds(750))
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
      process.arguments = ["-v", "Samantha", "Hey Rill"]
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw CocoaError(.executableRuntimeMismatch)
      }
    }

    var observedSampleCount = 0
    var detection: SherpaKeywordDetection?
    var capturedSamples: [Float] = []
    capturedSamples.reserveCapacity(16_000 * 8)
    for try await samples in stream {
      observedSampleCount += samples.count
      capturedSamples.append(contentsOf: samples)
      if let result = try spotter.accept(
        samples: WakeWordAudioConditioner.prepare(samples)
      ) {
        detection = result
        break
      }
      if observedSampleCount >= 16_000 * 8 {
        break
      }
    }
    try await speechTask.value

    if let capturePath = environment["RILL_RAW_MIC_KWS_CAPTURE"] {
      try Self.writeDiagnosticWAV(
        capturedSamples,
        to: URL(fileURLWithPath: capturePath)
      )
    }

    try spotter.reset()
    var rechunkedDetection: SherpaKeywordDetection?
    for offset in stride(from: 0, to: capturedSamples.count, by: 1_600) {
      let end = min(offset + 1_600, capturedSamples.count)
      if let result = try spotter.accept(
        samples: WakeWordAudioConditioner.prepare(
          Array(capturedSamples[offset..<end])
        )
      ) {
        rechunkedDetection = result
        break
      }
    }
    let peak = capturedSamples.reduce(Float.zero) {
      max($0, abs($1.isFinite ? $1 : 0))
    }
    let squaredSum = capturedSamples.reduce(0.0) {
      $0 + Double($1) * Double($1)
    }
    let rms = capturedSamples.isEmpty
      ? 0
      : sqrt(squaredSum / Double(capturedSamples.count))

    XCTAssertNotNil(
      detection,
      "Expected live chunks to detect the locally played wake phrase; rechunkedDetection=\(rechunkedDetection != nil), sampleCount=\(capturedSamples.count), peak=\(peak), rms=\(rms)."
    )
  }

  private static func writeDiagnosticWAV(
    _ samples: [Float],
    to url: URL
  ) throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
      )
    )
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(samples.count)
      )
    )
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let destination = try XCTUnwrap(buffer.floatChannelData?[0])
    destination.update(from: samples, count: samples.count)
    let file = try AVAudioFile(
      forWriting: url,
      settings: format.settings
    )
    try file.write(from: buffer)
  }
}
