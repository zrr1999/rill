import Foundation

public struct RecognitionHints: Sendable, Equatable {
  public var keyterms: [String]

  public init(keyterms: [String] = []) {
    self.keyterms = keyterms
  }

  public static let empty = RecognitionHints()
}

public struct SpeechRecognitionRequestOptions: Sendable, Equatable {
  public var language: String?
  public var hints: RecognitionHints

  public init(
    language: String? = nil,
    hints: RecognitionHints = .empty
  ) {
    self.language = language
    self.hints = hints
  }

  public static let empty = SpeechRecognitionRequestOptions()
}

public enum RecognitionHintKind: String, Codable, Sendable, Hashable {
  case keyterm
}

public struct SpeechRecognizerCapabilities: Sendable, Equatable {
  public var supportedHintKinds: Set<RecognitionHintKind>
  public var maximumAudioDurationSeconds: Double?

  public init(
    supportedHintKinds: Set<RecognitionHintKind> = [],
    maximumAudioDurationSeconds: Double? = nil
  ) {
    self.supportedHintKinds = supportedHintKinds
    self.maximumAudioDurationSeconds = maximumAudioDurationSeconds
  }

  public static let none = SpeechRecognizerCapabilities()

  public func supports(_ hintKind: RecognitionHintKind) -> Bool {
    supportedHintKinds.contains(hintKind)
  }

  /// Applies the provider limit without allowing invalid configuration to
  /// accidentally widen the capture window.
  public static func effectiveMaximumAudioDurationSeconds(
    modeMaximumAudioDurationSeconds: Double,
    recognizerMaximumAudioDurationSeconds: Double?
  ) -> Double {
    guard modeMaximumAudioDurationSeconds.isFinite,
      modeMaximumAudioDurationSeconds > 0
    else {
      return 0
    }
    guard let recognizerMaximumAudioDurationSeconds else {
      return modeMaximumAudioDurationSeconds
    }
    guard recognizerMaximumAudioDurationSeconds.isFinite,
      recognizerMaximumAudioDurationSeconds > 0
    else {
      return 0
    }
    return min(modeMaximumAudioDurationSeconds, recognizerMaximumAudioDurationSeconds)
  }
}
