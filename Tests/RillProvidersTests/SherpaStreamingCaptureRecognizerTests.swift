import Foundation
import XCTest

@testable import RillCore
@testable import RillProviders

final class SherpaStreamingCaptureRecognizerTests: XCTestCase {
  func testRecognizerReusesSealedStreamingResultWithoutOfflineDecode() async throws {
    let capturedAudio = try CapturedAudio(
      durationSeconds: 1,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .float32),
      inlineData: Data([0]),
      metadata: [
        SherpaStreamingCaptureRecognizer.rawTextMetadataKey: " raw hypothesis ",
        SherpaStreamingCaptureRecognizer.bestTextMetadataKey: " final hypothesis ",
        SherpaStreamingCaptureRecognizer.modelMetadataKey: "fixed-streaming-model",
      ]
    )
    let result = try await SherpaStreamingCaptureRecognizer().recognize(
      RecognitionRequest(
        runID: UUID(),
        workflow: Self.workflow,
        contextSnapshot: .empty,
        capturedAudio: capturedAudio
      )
    )

    XCTAssertEqual(result.rawText, "raw hypothesis")
    XCTAssertEqual(result.bestText, "final hypothesis")
    XCTAssertEqual(result.processingDurationMillis, 0)
    XCTAssertEqual(result.metadata["provider"], "sherpa-onnx.streaming")
    XCTAssertEqual(result.metadata["provider.kind"], "sherpa-onnx.streaming")
    XCTAssertEqual(result.metadata["provider.model"], "fixed-streaming-model")
  }

  func testRecognizerFailsClosedWhenCaptureHasNoStreamingResult() async throws {
    let capturedAudio = try CapturedAudio(
      durationSeconds: 1,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .float32),
      inlineData: Data([0])
    )

    do {
      _ = try await SherpaStreamingCaptureRecognizer().recognize(
        RecognitionRequest(
          runID: UUID(),
          workflow: Self.workflow,
          contextSnapshot: .empty,
          capturedAudio: capturedAudio
        )
      )
      XCTFail("A streaming-direct run must not silently fall back to offline recognition.")
    } catch {
      XCTAssertEqual(
        error as? SherpaStreamingCaptureRecognizer.RecognizerError,
        .streamingResultUnavailable
      )
    }
  }

  func testRecognizerRequiresCapturedAudio() async {
    do {
      _ = try await SherpaStreamingCaptureRecognizer().recognize(
        RecognitionRequest(
          runID: UUID(),
          workflow: Self.workflow,
          contextSnapshot: .empty
        )
      )
      XCTFail("Expected missing captured audio to fail.")
    } catch {
      XCTAssertEqual(
        error as? SherpaStreamingCaptureRecognizer.RecognizerError,
        .missingCapturedAudio
      )
    }
  }

  private static let workflow = WorkflowDefinition(
    name: "Streaming Direct",
    pipeline: PipelineDeclaration(
      recognizerID: SherpaStreamingCaptureRecognizer.recognizerID,
      outputActions: [OutputActionReference(id: "inject.text")]
    ),
    ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "orange")
  )
}
