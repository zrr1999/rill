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
  /// A live run freezes its local model and language at admission.
  public var modelIdentifier: String?

  public init(
    language: String? = nil,
    hints: RecognitionHints = .empty,
    modelIdentifier: String? = nil
  ) {
    self.language = language
    self.hints = hints
    self.modelIdentifier = modelIdentifier
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
    modeMaximumAudioDurationSeconds: Double?,
    recognizerMaximumAudioDurationSeconds: Double?
  ) -> Double? {
    let validModeMaximum = modeMaximumAudioDurationSeconds.flatMap { value in
      value.isFinite && value > 0 ? value : 0
    }
    let validRecognizerMaximum = recognizerMaximumAudioDurationSeconds.flatMap { value in
      value.isFinite && value > 0 ? value : 0
    }
    switch (validModeMaximum, validRecognizerMaximum) {
    case (.some(let mode), .some(let recognizer)):
      return min(mode, recognizer)
    case (.some(let mode), .none):
      return mode
    case (.none, .some(let recognizer)):
      return recognizer
    case (.none, .none):
      return nil
    }
  }
}
