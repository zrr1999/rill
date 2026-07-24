import AVFoundation
import Darwin
import Foundation
import Testing
import XCTest

@testable import RillSherpaRuntime

@Suite("sherpa-onnx Silero VAD runtime")
struct SherpaVoiceActivityDetectorTests {
  @Test("bundled configuration uses the reviewed Silero defaults")
  func bundledConfigurationDefaults() throws {
    let configuration = try SherpaSileroVADConfiguration.bundled()

    #expect(configuration.modelURL.lastPathComponent == "silero_vad.onnx")
    #expect(
      configuration.expectedModelSHA256
        == "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6"
    )
    #expect(configuration.threshold == 0.25)
    #expect(configuration.minimumSilenceDurationSeconds == 0.1)
    #expect(configuration.minimumSpeechDurationSeconds == 0.1)
    #expect(configuration.maximumSpeechDurationSeconds == 120)
    #expect(configuration.bufferDurationSeconds == 120)
    #expect(configuration.threadCount == 1)
    try configuration.validate()
  }

  @Test("bundled detector passes the caller's speech threshold into native configuration")
  func bundledDetectorUsesRequestedThreshold() throws {
    let lowerThreshold = try SherpaVoiceActivityDetector.bundled(threshold: 0.3)
    let higherThreshold = try SherpaVoiceActivityDetector.bundled(threshold: 0.7)

    #expect(lowerThreshold.configuration.threshold == 0.3)
    #expect(higherThreshold.configuration.threshold == 0.7)
  }

  @Test("bundled model locator checks release-safe roots in order")
  func bundledModelLocatorCandidateOrderAndMissingResult() {
    let resourceRoot = URL(
      fileURLWithPath: "/Applications/Rill.app/Contents/Resources",
      isDirectory: true
    )
    let frameworkRoot = URL(
      fileURLWithPath: "/Applications/Rill.app/Contents/Frameworks",
      isDirectory: true
    )
    let mainBundleRoot = URL(
      fileURLWithPath: "/Applications/Rill.app",
      isDirectory: true
    )
    let searchRoots: [URL?] = [resourceRoot, nil, frameworkRoot, mainBundleRoot]
    let expectedCandidates = [resourceRoot, frameworkRoot, mainBundleRoot].map {
      $0.appendingPathComponent(
        SherpaBundledModelLocator.resourceBundleFilename,
        isDirectory: true
      )
    }

    var visitedCandidates: [URL] = []
    let expectedModelURL = expectedCandidates[1].appendingPathComponent(
      SherpaSileroVADConfiguration.bundledModelFilename
    )
    let locatedModelURL = SherpaBundledModelLocator.locate(
      searchRoots: searchRoots
    ) { bundleURL in
      visitedCandidates.append(bundleURL)
      return bundleURL == expectedCandidates[1] ? expectedModelURL : nil
    }
    #expect(locatedModelURL == expectedModelURL)
    #expect(visitedCandidates == Array(expectedCandidates.prefix(2)))

    visitedCandidates.removeAll()
    let missingModelURL = SherpaBundledModelLocator.locate(
      searchRoots: searchRoots
    ) { bundleURL in
      visitedCandidates.append(bundleURL)
      return nil
    }
    #expect(missingModelURL == nil)
    #expect(visitedCandidates == expectedCandidates)
  }

  @Test("arbitrary chunks produce one observation per complete 512-sample frame")
  func buffersArbitraryChunksAndResetsPendingAudio() throws {
    let detector = try SherpaVoiceActivityDetector.bundled()

    #expect(try detector.accept(samples: Array(repeating: 0, count: 511)).isEmpty)
    let completed = try detector.accept(samples: [0])
    #expect(completed.count == 1)
    #expect(completed.first?.isSpeech == false)
    #expect(
      completed.first?.durationSeconds == SherpaVoiceActivityDetector.frameDurationSeconds
    )
    #expect(completed.first?.normalizedRMS == 0)

    let twoFrames = try detector.accept(samples: Array(repeating: 0, count: 1_024))
    #expect(twoFrames.count == 2)
    #expect(twoFrames.allSatisfy { !$0.isSpeech && $0.normalizedRMS == 0 })

    #expect(try detector.accept(samples: Array(repeating: 0, count: 511)).isEmpty)
    detector.reset()
    #expect(try detector.accept(samples: [0]).isEmpty)
  }

  @Test("non-finite samples fail before mutating the partial frame")
  func rejectsNonFiniteSamplesAtomically() throws {
    let detector = try SherpaVoiceActivityDetector.bundled()
    #expect(try detector.accept(samples: Array(repeating: 0, count: 511)).isEmpty)

    #expect(throws: SherpaVoiceActivityDetectorError.invalidAudioSample(index: 1)) {
      try detector.accept(samples: [0, .nan])
    }
    #expect(throws: SherpaVoiceActivityDetectorError.invalidAudioSample(index: 0)) {
      try detector.accept(samples: [.infinity])
    }

    let completed = try detector.accept(samples: [0])
    #expect(completed.count == 1)
    #expect(completed.first?.isSpeech == false)
  }

  @Test("finite PCM peaks are clamped before native inference and RMS")
  func clampsFinitePCM() throws {
    let detector = try SherpaVoiceActivityDetector.bundled()
    let samples = (0..<SherpaVoiceActivityDetector.frameSize).map {
      $0.isMultiple(of: 2) ? Float(1.2) : -1.2
    }

    let observations = try detector.accept(samples: samples)
    #expect(observations.count == 1)
    #expect(observations.first?.normalizedRMS == 1)
  }

  @Test("deterministic moderate white noise is not classified as speech")
  func rejectsDeterministicWhiteNoise() throws {
    let detector = try SherpaVoiceActivityDetector.bundled()
    let sampleCount = SherpaVoiceActivityDetector.sampleRate * 5 / 2
    var generatorState: UInt32 = 0x6D2B_79F5
    let samples = (0..<sampleCount).map { _ -> Float in
      generatorState ^= generatorState << 13
      generatorState ^= generatorState >> 17
      generatorState ^= generatorState << 5
      let unitSample = Float(generatorState) / Float(UInt32.max)
      return (unitSample * 2 - 1) * 0.05
    }

    let chunkSizes = [137, 997, 53, 2_048, 311, 777]
    var observations: [SherpaVoiceActivityObservation] = []
    var cursor = 0
    var chunkIndex = 0
    while cursor < samples.count {
      let end = min(cursor + chunkSizes[chunkIndex % chunkSizes.count], samples.count)
      observations.append(
        contentsOf: try detector.accept(samples: Array(samples[cursor..<end]))
      )
      cursor = end
      chunkIndex += 1
    }

    #expect(
      observations.count == sampleCount / SherpaVoiceActivityDetector.frameSize
    )
    #expect(observations.allSatisfy { !$0.isSpeech })
  }

  @Test("configuration and model integrity failures are typed")
  func validatesConfigurationAndModelIntegrity() throws {
    var invalidThreshold = try SherpaSileroVADConfiguration.bundled()
    invalidThreshold.threshold = .nan
    #expect(
      throws: SherpaVoiceActivityDetectorError.invalidConfiguration(
        "threshold must be finite and in the interval (0, 1)"
      )
    ) {
      try invalidThreshold.validate()
    }

    var undersizedBuffer = try SherpaSileroVADConfiguration.bundled()
    undersizedBuffer.bufferDurationSeconds = 30
    #expect(
      throws: SherpaVoiceActivityDetectorError.invalidConfiguration(
        "bufferDurationSeconds must be at least maximumSpeechDurationSeconds"
      )
    ) {
      try undersizedBuffer.validate()
    }

    var wrongDigest = try SherpaSileroVADConfiguration.bundled()
    wrongDigest.expectedModelSHA256 = String(repeating: "0", count: 64)
    #expect(
      throws: SherpaVoiceActivityDetectorError.modelIntegrityCheckFailed(
        expected: String(repeating: "0", count: 64),
        actual: SherpaSileroVADConfiguration.bundledModelSHA256
      )
    ) {
      try wrongDigest.validate()
    }
  }

  @Test("model path replacement during native creation fails closed")
  func detectsModelPathReplacementDuringNativeCreation() throws {
    let fixture = try makeTemporaryModelFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
    let replacementURL = fixture.directoryURL.appendingPathComponent("replacement.onnx")
    try FileManager.default.copyItem(
      at: fixture.configuration.modelURL,
      to: replacementURL
    )

    var renameStatus: Int32?
    #expect(
      throws: SherpaVoiceActivityDetectorError.modelChangedDuringLoad(
        fixture.configuration.modelURL
      )
    ) {
      _ = try SherpaVoiceActivityDetector(
        configuration: fixture.configuration,
        afterNativeCreateForTesting: {
          renameStatus = replacementURL.path.withCString { replacementPath in
            fixture.configuration.modelURL.path.withCString { modelPath in
              Darwin.rename(replacementPath, modelPath)
            }
          }
        }
      )
    }
    #expect(renameStatus == 0)
  }

  @Test("same-inode model content drift during native creation fails closed")
  func detectsModelContentDriftDuringNativeCreation() throws {
    let fixture = try makeTemporaryModelFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
    let modelData = try Data(contentsOf: fixture.configuration.modelURL)
    try #require(!modelData.isEmpty)
    var changedByte = modelData[modelData.startIndex] ^ 0xFF
    var writeStatus: Int?

    #expect(
      throws: SherpaVoiceActivityDetectorError.modelChangedDuringLoad(
        fixture.configuration.modelURL
      )
    ) {
      _ = try SherpaVoiceActivityDetector(
        configuration: fixture.configuration,
        afterNativeCreateForTesting: {
          let descriptor = fixture.configuration.modelURL.path.withCString { path in
            Darwin.open(path, O_WRONLY | O_CLOEXEC)
          }
          guard descriptor >= 0 else {
            writeStatus = -1
            return
          }
          writeStatus = withUnsafeBytes(of: &changedByte) { bytes in
            Darwin.pwrite(descriptor, bytes.baseAddress, bytes.count, 0)
          }
          _ = Darwin.fsync(descriptor)
          Darwin.close(descriptor)
        }
      )
    }
    #expect(writeStatus == 1)
  }

  @Test("model validation rejects symbolic and hard links")
  func rejectsLinkedModelTrustMaterial() throws {
    let fixture = try makeTemporaryModelFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

    let symbolicLinkURL = fixture.directoryURL.appendingPathComponent("symbolic.onnx")
    try FileManager.default.createSymbolicLink(
      at: symbolicLinkURL,
      withDestinationURL: fixture.configuration.modelURL
    )
    var symbolicConfiguration = fixture.configuration
    symbolicConfiguration.modelURL = symbolicLinkURL
    #expect(throws: SherpaVoiceActivityDetectorError.missingModel(symbolicLinkURL)) {
      try symbolicConfiguration.validate()
    }

    let hardLinkURL = fixture.directoryURL.appendingPathComponent("hard-link.onnx")
    let linkStatus = fixture.configuration.modelURL.path.withCString { modelPath in
      hardLinkURL.path.withCString { hardLinkPath in
        Darwin.link(modelPath, hardLinkPath)
      }
    }
    try #require(linkStatus == 0)
    #expect(
      throws: SherpaVoiceActivityDetectorError.missingModel(
        fixture.configuration.modelURL
      )
    ) {
      try fixture.configuration.validate()
    }
  }

  private func makeTemporaryModelFixture() throws -> (
    directoryURL: URL,
    configuration: SherpaSileroVADConfiguration
  ) {
    let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-vad-model-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    do {
      var configuration = try SherpaSileroVADConfiguration.bundled()
      let modelURL = directoryURL.appendingPathComponent(
        SherpaSileroVADConfiguration.bundledModelFilename
      )
      try FileManager.default.copyItem(at: configuration.modelURL, to: modelURL)
      configuration.modelURL = modelURL
      return (directoryURL, configuration)
    } catch {
      try? FileManager.default.removeItem(at: directoryURL)
      throw error
    }
  }
}

final class SherpaVoiceActivityDetectorDogfoodTests: XCTestCase {
  func testLocalMixedLanguageFixtureWhenExplicitlyEnabled() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RILL_RUN_SHERPA_DOGFOOD"] == "1" else {
      throw XCTSkip("Set RILL_RUN_SHERPA_DOGFOOD=1 to run the local VAD fixture.")
    }
    guard let audioPath = environment["RILL_SHERPA_AUDIO"] else {
      XCTFail("RILL_SHERPA_AUDIO is required.")
      return
    }

    let samples = try load16KMonoSamples(at: URL(fileURLWithPath: audioPath))
    let detector = try SherpaVoiceActivityDetector.bundled()
    var observations: [SherpaVoiceActivityObservation] = []
    var cursor = 0
    let chunkSize = 777
    while cursor < samples.count {
      let end = min(cursor + chunkSize, samples.count)
      observations.append(
        contentsOf: try detector.accept(samples: Array(samples[cursor..<end]))
      )
      cursor = end
    }

    XCTAssertFalse(observations.isEmpty)
    XCTAssertTrue(
      observations.contains(where: \.isSpeech),
      "The local mixed-language fixture should contain at least one speech frame."
    )
  }

  private func load16KMonoSamples(at url: URL) throws -> [Float] {
    let audioFile = try AVAudioFile(forReading: url)
    XCTAssertEqual(audioFile.processingFormat.sampleRate, 16_000)
    XCTAssertEqual(audioFile.processingFormat.channelCount, 1)
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(
        pcmFormat: audioFile.processingFormat,
        frameCapacity: AVAudioFrameCount(audioFile.length)
      )
    )
    try audioFile.read(into: buffer)
    return Array(
      UnsafeBufferPointer(
        start: try XCTUnwrap(buffer.floatChannelData?[0]),
        count: Int(buffer.frameLength)
      )
    )
  }
}
