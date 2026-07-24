import Foundation
import RillCore

/// Reuses the final hypothesis produced by the fixed streaming preview model.
///
/// Capture owns incremental decoding. This recognizer only converts the sealed
/// capture result into the ordinary workflow pipeline, so output routing stays
/// behind the existing action boundary.
public struct SherpaStreamingCaptureRecognizer: SpeechRecognizer {
  public static let recognizerID = "sherpa-onnx.streaming"
  public static let rawTextMetadataKey = "sherpa-onnx.streaming.raw-text"
  public static let bestTextMetadataKey = "sherpa-onnx.streaming.best-text"
  public static let modelMetadataKey = "sherpa-onnx.streaming.model"

  public enum RecognizerError: Error, LocalizedError, Equatable, Sendable {
    case missingCapturedAudio
    case streamingResultUnavailable

    public var errorDescription: String? {
      switch self {
      case .missingCapturedAudio:
        "Streaming speech recognition requires captured audio."
      case .streamingResultUnavailable:
        "The fixed streaming speech model did not produce a final result."
      }
    }
  }

  public let id = Self.recognizerID
  public let capabilities = SpeechRecognizerCapabilities(
    supportedHintKinds: [],
    maximumAudioDurationSeconds: Double(LocalSpeechCaptureLimits.maximumRequestedDurationSeconds)
  )

  public init() {}

  public func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
    try Task.checkCancellation()
    guard let capturedAudio = request.capturedAudio else {
      throw RecognizerError.missingCapturedAudio
    }
    guard let bestText = capturedAudio.metadata[Self.bestTextMetadataKey]?.trimmedNonEmpty else {
      throw RecognizerError.streamingResultUnavailable
    }
    let rawText = capturedAudio.metadata[Self.rawTextMetadataKey]?.trimmedNonEmpty ?? bestText
    let model =
      capturedAudio.metadata[Self.modelMetadataKey]?.trimmedNonEmpty
      ?? SherpaStreamingPreviewService.modelID

    var metadata = capturedAudio.metadata
    metadata["provider"] = id
    metadata["provider.kind"] = "sherpa-onnx.streaming"
    metadata["provider.model"] = model
    return RecognitionResult(
      rawText: rawText,
      bestText: bestText,
      metadata: metadata,
      processingDurationMillis: 0
    )
  }
}

private extension String {
  var trimmedNonEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
