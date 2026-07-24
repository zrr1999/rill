import AVFoundation
import Foundation
import Testing
import XCTest

@testable import RillSherpaRuntime

@Suite("sherpa-onnx streaming runtime")
struct SherpaStreamingRecognizerTests {
  @Test("streaming configuration rejects missing artifacts")
  func rejectsMissingArtifacts() {
    let root = URL(fileURLWithPath: "/missing/streaming-preview", isDirectory: true)
    let configuration = SherpaStreamingTransducerConfiguration(
      encoder: root.appendingPathComponent("encoder.int8.onnx"),
      decoder: root.appendingPathComponent("decoder.int8.onnx"),
      joiner: root.appendingPathComponent("joiner.int8.onnx"),
      tokens: root.appendingPathComponent("tokens.txt")
    )

    #expect(
      throws: SherpaStreamingRecognizerError.missingArtifact(configuration.encoder)
    ) {
      try SherpaStreamingRecognizer(configuration: configuration)
    }
  }

  @Test("streaming configuration bounds native threads")
  func boundsThreads() {
    let root = URL(fileURLWithPath: "/missing/streaming-preview", isDirectory: true)
    let configuration = SherpaStreamingTransducerConfiguration(
      encoder: root.appendingPathComponent("encoder.int8.onnx"),
      decoder: root.appendingPathComponent("decoder.int8.onnx"),
      joiner: root.appendingPathComponent("joiner.int8.onnx"),
      tokens: root.appendingPathComponent("tokens.txt"),
      threadCount: SherpaStreamingTransducerConfiguration.maximumThreadCount + 1
    )

    #expect(
      throws: SherpaStreamingRecognizerError.invalidThreadCount(
        SherpaStreamingTransducerConfiguration.maximumThreadCount + 1
      )
    ) {
      try SherpaStreamingRecognizer(configuration: configuration)
    }
  }
}

final class SherpaStreamingRecognizerDogfoodTests: XCTestCase {
  func testBilingualFixtureWhenExplicitlyEnabled() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RILL_RUN_SHERPA_STREAMING_DOGFOOD"] == "1" else {
      throw XCTSkip(
        "Set RILL_RUN_SHERPA_STREAMING_DOGFOOD=1 to run the streaming fixture."
      )
    }
    guard let modelPath = environment["RILL_SHERPA_STREAMING_MODEL_DIR"],
      let audioPath = environment["RILL_SHERPA_STREAMING_AUDIO"]
    else {
      XCTFail(
        "RILL_SHERPA_STREAMING_MODEL_DIR and RILL_SHERPA_STREAMING_AUDIO are required."
      )
      return
    }

    let modelDirectory = URL(fileURLWithPath: modelPath, isDirectory: true)
    let recognizer = try SherpaStreamingRecognizer(
      configuration: SherpaStreamingTransducerConfiguration(
        encoder: modelDirectory.appendingPathComponent(
          "encoder-epoch-99-avg-1.int8.onnx"
        ),
        decoder: modelDirectory.appendingPathComponent(
          "decoder-epoch-99-avg-1.int8.onnx"
        ),
        joiner: modelDirectory.appendingPathComponent(
          "joiner-epoch-99-avg-1.int8.onnx"
        ),
        tokens: modelDirectory.appendingPathComponent("tokens.txt")
      )
    )
    let stream = try recognizer.makeStream()
    let samples = try load16KMonoSamples(at: URL(fileURLWithPath: audioPath))

    var hypothesis = ""
    for offset in stride(from: 0, to: samples.count, by: 3_200) {
      let end = min(offset + 3_200, samples.count)
      hypothesis = try stream.accept(samples: Array(samples[offset..<end]))
    }
    let finalText = try stream.finish().trimmingCharacters(in: .whitespacesAndNewlines)

    XCTAssertFalse(hypothesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    XCTAssertFalse(finalText.isEmpty)
  }

  private func load16KMonoSamples(at url: URL) throws -> [Float] {
    let audioFile = try AVAudioFile(forReading: url)
    XCTAssertEqual(audioFile.processingFormat.sampleRate, 16_000)
    XCTAssertEqual(audioFile.processingFormat.channelCount, 1)
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: audioFile.processingFormat,
        frameCapacity: AVAudioFrameCount(audioFile.length)
      )
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    try audioFile.read(into: buffer)
    guard let channel = buffer.floatChannelData?[0] else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
  }
}
