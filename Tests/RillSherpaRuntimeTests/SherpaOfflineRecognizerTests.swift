import AVFoundation
import Foundation
import Testing
import XCTest

@testable import RillSherpaRuntime

@Suite("sherpa-onnx offline runtime")
struct SherpaOfflineRecognizerTests {
  @Test("vendored runtime reports the pinned version")
  func reportsPinnedRuntimeVersion() {
    #expect(SherpaOfflineRecognizer.runtimeVersion == "1.13.4")
    #expect(!SherpaOfflineRecognizer.runtimeGitSHA1.isEmpty)
  }

  @Test("Qwen3 uses the reviewed offline defaults")
  func qwen3Defaults() {
    let root = URL(fileURLWithPath: "/models/qwen3")
    let configuration = SherpaQwen3ASRConfiguration(
      convolutionFrontend: root.appendingPathComponent("conv_frontend.onnx"),
      encoder: root.appendingPathComponent("encoder.int8.onnx"),
      decoder: root.appendingPathComponent("decoder.int8.onnx"),
      tokenizerDirectory: root.appendingPathComponent("tokenizer")
    )

    #expect(configuration.threadCount == 2)
    #expect(
      configuration.maximumTotalLength == SherpaQwen3ASRConfiguration.defaultMaximumTotalLength
    )
    #expect(
      configuration.maximumNewTokens == SherpaQwen3ASRConfiguration.defaultMaximumNewTokens
    )
    #expect(configuration.temperature == 1e-6)
    #expect(configuration.topP == 0.8)
    #expect(configuration.seed == 42)
    #expect(configuration.hotwords.isEmpty)
    #expect(SherpaQwen3ASRConfiguration.maximumHotwordCount == 16)
    #expect(SherpaQwen3ASRConfiguration.maximumHotwordUTF8ByteCount == 48)
  }

  @Test("SenseVoice defaults to automatic language and ITN")
  func senseVoiceDefaults() {
    let root = URL(fileURLWithPath: "/models/sense-voice")
    let configuration = SherpaSenseVoiceConfiguration(
      model: root.appendingPathComponent("model.int8.onnx"),
      tokens: root.appendingPathComponent("tokens.txt")
    )

    #expect(configuration.language.isEmpty)
    #expect(configuration.usesInverseTextNormalization)
    #expect(configuration.threadCount == 2)
  }

  @Test("new model families use reviewed offline defaults")
  func additionalModelDefaults() {
    let root = URL(fileURLWithPath: "/models/additional")
    let funASR = SherpaFunASRNanoConfiguration(
      encoderAdaptor: root.appendingPathComponent("encoder_adaptor.int8.onnx"),
      languageModel: root.appendingPathComponent("llm.int8.onnx"),
      embedding: root.appendingPathComponent("embedding.int8.onnx"),
      tokenizerDirectory: root.appendingPathComponent("Qwen3-0.6B")
    )
    #expect(funASR.language.isEmpty)
    #expect(funASR.usesInverseTextNormalization)
    #expect(funASR.threadCount == 2)

    let omnilingual = SherpaOmnilingualCTCConfiguration(
      model: root.appendingPathComponent("model.int8.onnx"),
      tokens: root.appendingPathComponent("tokens.txt")
    )
    #expect(omnilingual.threadCount == 2)

    let cohere = SherpaCohereTranscribeConfiguration(
      encoder: root.appendingPathComponent("encoder.int8.onnx"),
      encoderData: root.appendingPathComponent("encoder.int8.onnx.data"),
      decoder: root.appendingPathComponent("decoder.int8.onnx"),
      tokens: root.appendingPathComponent("tokens.txt")
    )
    #expect(cohere.language.isEmpty)
    #expect(cohere.usesPunctuation)
    #expect(cohere.usesInverseTextNormalization)
    #expect(cohere.threadCount == 2)
  }

  @Test("Qwen3 validation requires every tokenizer artifact")
  func qwen3RequiresCompleteTokenizer() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let tokenizer = root.appendingPathComponent("tokenizer", isDirectory: true)
    try FileManager.default.createDirectory(
      at: tokenizer,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    for filename in ["conv_frontend.onnx", "encoder.int8.onnx", "decoder.int8.onnx"] {
      #expect(
        FileManager.default.createFile(
          atPath: root.appendingPathComponent(filename).path,
          contents: Data()
        ))
    }
    for filename in ["merges.txt", "tokenizer_config.json"] {
      #expect(
        FileManager.default.createFile(
          atPath: tokenizer.appendingPathComponent(filename).path,
          contents: Data()
        ))
    }

    let configuration = SherpaOfflineModelConfiguration.qwen3(
      SherpaQwen3ASRConfiguration(
        convolutionFrontend: root.appendingPathComponent("conv_frontend.onnx"),
        encoder: root.appendingPathComponent("encoder.int8.onnx"),
        decoder: root.appendingPathComponent("decoder.int8.onnx"),
        tokenizerDirectory: tokenizer
      )
    )

    #expect(
      throws: SherpaOfflineRecognizerError.missingArtifact(
        tokenizer.appendingPathComponent("vocab.json")
      )
    ) {
      try configuration.validate()
    }
  }

  @Test("Qwen3 rejects ambiguous comma-delimited hotwords")
  func qwen3RejectsAmbiguousHotwords() throws {
    let configuration = SherpaOfflineModelConfiguration.qwen3(
      SherpaQwen3ASRConfiguration(
        convolutionFrontend: URL(fileURLWithPath: "/missing/conv_frontend.onnx"),
        encoder: URL(fileURLWithPath: "/missing/encoder.int8.onnx"),
        decoder: URL(fileURLWithPath: "/missing/decoder.int8.onnx"),
        tokenizerDirectory: URL(fileURLWithPath: "/missing/tokenizer"),
        hotwords: ["Rill,voice"]
      )
    )

    #expect(
      throws: SherpaOfflineRecognizerError.invalidConfiguration(
        "Qwen3 hotwords must be non-empty and cannot contain commas or control characters"
      )
    ) {
      try configuration.validate()
    }
  }

  @Test("Qwen3 per-request hotwords retain the reviewed validation bounds")
  func qwen3PerRequestHotwordValidation() throws {
    let exactByteLimit = String(
      repeating: "x",
      count: SherpaQwen3ASRConfiguration.maximumHotwordUTF8ByteCount
    )
    #expect(throws: Never.self) {
      try SherpaQwen3ASRConfiguration.validateHotwords([])
      try SherpaQwen3ASRConfiguration.validateHotwords([exactByteLimit])
      try SherpaQwen3ASRConfiguration.validateHotwords(
        Array(repeating: "x", count: SherpaQwen3ASRConfiguration.maximumHotwordCount)
      )
    }

    #expect(
      throws: SherpaOfflineRecognizerError.invalidConfiguration(
        "Qwen3 hotwords exceed the supported count or UTF-8 byte limit"
      )
    ) {
      try SherpaQwen3ASRConfiguration.validateHotwords(
        Array(repeating: "x", count: SherpaQwen3ASRConfiguration.maximumHotwordCount + 1)
      )
    }
    #expect(
      throws: SherpaOfflineRecognizerError.invalidConfiguration(
        "Qwen3 hotwords exceed the supported count or UTF-8 byte limit"
      )
    ) {
      try SherpaQwen3ASRConfiguration.validateHotwords([exactByteLimit + "x"])
    }
    #expect(
      throws: SherpaOfflineRecognizerError.invalidConfiguration(
        "Qwen3 hotwords must be non-empty and cannot contain commas or control characters"
      )
    ) {
      try SherpaQwen3ASRConfiguration.validateHotwords(["bad\tcontrol"])
    }
  }

  @Test("runtime validation rejects symlinked model artifacts")
  func rejectsSymlinkedArtifacts() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let target = root.appendingPathComponent("target.onnx")
    let link = root.appendingPathComponent("model.int8.onnx")
    let tokens = root.appendingPathComponent("tokens.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(FileManager.default.createFile(atPath: target.path, contents: Data()))
    #expect(FileManager.default.createFile(atPath: tokens.path, contents: Data()))
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let configuration = SherpaOfflineModelConfiguration.senseVoice(
      SherpaSenseVoiceConfiguration(model: link, tokens: tokens)
    )
    #expect(throws: SherpaOfflineRecognizerError.missingArtifact(link)) {
      try configuration.validate()
    }
  }

  @Test("runtime parameters have product bounds")
  func runtimeParametersAreBounded() throws {
    let configuration = SherpaOfflineModelConfiguration.qwen3(
      SherpaQwen3ASRConfiguration(
        convolutionFrontend: URL(fileURLWithPath: "/missing/conv_frontend.onnx"),
        encoder: URL(fileURLWithPath: "/missing/encoder.int8.onnx"),
        decoder: URL(fileURLWithPath: "/missing/decoder.int8.onnx"),
        tokenizerDirectory: URL(fileURLWithPath: "/missing/tokenizer"),
        threadCount: SherpaQwen3ASRConfiguration.maximumThreadCount + 1
      )
    )
    #expect(
      throws: SherpaOfflineRecognizerError.invalidConfiguration(
        "threadCount must be in 1...\(SherpaQwen3ASRConfiguration.maximumThreadCount)"
      )
    ) {
      try configuration.validate()
    }
  }
}

final class SherpaOfflineRecognizerDogfoodTests: XCTestCase {
  func testQwenMixedLanguageFixtureWhenExplicitlyEnabled() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RILL_RUN_SHERPA_DOGFOOD"] == "1" else {
      throw XCTSkip("Set RILL_RUN_SHERPA_DOGFOOD=1 to run the local Qwen fixture.")
    }
    guard let modelPath = environment["RILL_SHERPA_MODEL_DIR"],
      let audioPath = environment["RILL_SHERPA_AUDIO"]
    else {
      XCTFail("RILL_SHERPA_MODEL_DIR and RILL_SHERPA_AUDIO are required.")
      return
    }

    let modelDirectory = URL(fileURLWithPath: modelPath, isDirectory: true)
    let recognizer = try SherpaOfflineRecognizer(
      configuration: .qwen3(
        SherpaQwen3ASRConfiguration(
          convolutionFrontend: modelDirectory.appendingPathComponent("conv_frontend.onnx"),
          encoder: modelDirectory.appendingPathComponent("encoder.int8.onnx"),
          decoder: modelDirectory.appendingPathComponent("decoder.int8.onnx"),
          tokenizerDirectory: modelDirectory.appendingPathComponent(
            "tokenizer",
            isDirectory: true
          )
        )
      )
    )
    let samples = try load16KMonoSamples(at: URL(fileURLWithPath: audioPath))

    let result = try recognizer.transcribe(samples: samples)
    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertFalse(text.isEmpty)
    XCTAssertTrue(text.lowercased().contains("princess"))
    XCTAssertTrue(
      text.unicodeScalars.contains { scalar in
        (0x3400...0x9FFF).contains(scalar.value)
      },
      "The mixed-language fixture should retain CJK text."
    )
  }

  func testSenseVoiceChineseFixtureWhenExplicitlyEnabled() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RILL_RUN_SHERPA_SENSEVOICE_DOGFOOD"] == "1" else {
      throw XCTSkip(
        "Set RILL_RUN_SHERPA_SENSEVOICE_DOGFOOD=1 to run the local SenseVoice fixture."
      )
    }
    guard let modelPath = environment["RILL_SHERPA_MODEL_DIR"],
      let audioPath = environment["RILL_SHERPA_AUDIO"]
    else {
      XCTFail("RILL_SHERPA_MODEL_DIR and RILL_SHERPA_AUDIO are required.")
      return
    }

    let modelDirectory = URL(fileURLWithPath: modelPath, isDirectory: true)
    let recognizer = try SherpaOfflineRecognizer(
      configuration: .senseVoice(
        SherpaSenseVoiceConfiguration(
          model: modelDirectory.appendingPathComponent("model.int8.onnx"),
          tokens: modelDirectory.appendingPathComponent("tokens.txt")
        )
      )
    )
    let result = try recognizer.transcribe(
      samples: load16KMonoSamples(at: URL(fileURLWithPath: audioPath))
    )
    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertFalse(text.isEmpty)
    XCTAssertTrue(
      text.unicodeScalars.contains { scalar in
        (0x3400...0x9FFF).contains(scalar.value)
      },
      "The Chinese fixture should retain CJK text."
    )
  }

  func testFunASRNanoFixtureWhenExplicitlyEnabled() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RILL_RUN_SHERPA_FUNASR_DOGFOOD"] == "1" else {
      throw XCTSkip("Set RILL_RUN_SHERPA_FUNASR_DOGFOOD=1 to run the Fun-ASR fixture.")
    }
    let (modelDirectory, audioURL) = try dogfoodInputs(environment: environment)
    let languageModelName = environment["RILL_SHERPA_FUNASR_LLM"] ?? "llm.int8.onnx"
    let recognizer = try SherpaOfflineRecognizer(
      configuration: .funASRNano(
        SherpaFunASRNanoConfiguration(
          encoderAdaptor: modelDirectory.appendingPathComponent("encoder_adaptor.int8.onnx"),
          languageModel: modelDirectory.appendingPathComponent(languageModelName),
          embedding: modelDirectory.appendingPathComponent("embedding.int8.onnx"),
          tokenizerDirectory: modelDirectory.appendingPathComponent(
            "Qwen3-0.6B",
            isDirectory: true
          )
        )
      )
    )
    let result = try recognizer.transcribe(samples: load16KMonoSamples(at: audioURL))
    XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  func testOmnilingualFixtureWhenExplicitlyEnabled() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RILL_RUN_SHERPA_OMNILINGUAL_DOGFOOD"] == "1" else {
      throw XCTSkip(
        "Set RILL_RUN_SHERPA_OMNILINGUAL_DOGFOOD=1 to run the Omnilingual fixture."
      )
    }
    let (modelDirectory, audioURL) = try dogfoodInputs(environment: environment)
    let recognizer = try SherpaOfflineRecognizer(
      configuration: .omnilingualCTC(
        SherpaOmnilingualCTCConfiguration(
          model: modelDirectory.appendingPathComponent("model.int8.onnx"),
          tokens: modelDirectory.appendingPathComponent("tokens.txt")
        )
      )
    )
    let result = try recognizer.transcribe(samples: load16KMonoSamples(at: audioURL))
    XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  func testCohereTranscribeFixtureWhenExplicitlyEnabled() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RILL_RUN_SHERPA_COHERE_DOGFOOD"] == "1" else {
      throw XCTSkip("Set RILL_RUN_SHERPA_COHERE_DOGFOOD=1 to run the Cohere fixture.")
    }
    let (modelDirectory, audioURL) = try dogfoodInputs(environment: environment)
    let recognizer = try SherpaOfflineRecognizer(
      configuration: .cohereTranscribe(
        SherpaCohereTranscribeConfiguration(
          encoder: modelDirectory.appendingPathComponent("encoder.int8.onnx"),
          encoderData: modelDirectory.appendingPathComponent("encoder.int8.onnx.data"),
          decoder: modelDirectory.appendingPathComponent("decoder.int8.onnx"),
          tokens: modelDirectory.appendingPathComponent("tokens.txt"),
          language: environment["RILL_SHERPA_LANGUAGE"] ?? ""
        )
      )
    )
    let result = try recognizer.transcribe(samples: load16KMonoSamples(at: audioURL))
    XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  private func dogfoodInputs(
    environment: [String: String]
  ) throws -> (URL, URL) {
    guard let modelPath = environment["RILL_SHERPA_MODEL_DIR"],
      let audioPath = environment["RILL_SHERPA_AUDIO"]
    else {
      XCTFail("RILL_SHERPA_MODEL_DIR and RILL_SHERPA_AUDIO are required.")
      throw CocoaError(.fileNoSuchFile)
    }
    return (
      URL(fileURLWithPath: modelPath, isDirectory: true),
      URL(fileURLWithPath: audioPath)
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
