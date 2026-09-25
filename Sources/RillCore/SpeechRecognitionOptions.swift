import Foundation

public struct RecognitionHints: Sendable, Equatable {
  public var keyterms: [String]

  public init(keyterms: [String] = []) {
    self.keyterms = keyterms
  }

  public static let empty = RecognitionHints()
}

public struct RecognitionVocabularySnapshot: Sendable, Equatable {
  public let revision: UUID
  public let collections: [VocabularyCollection]

  public init(revision: UUID, collections: [VocabularyCollection]) {
    self.revision = revision
    self.collections = collections
  }
}

public struct SpeechRecognitionRequestOptions: Sendable, Equatable {
  public var modelID: String?
  public var vocabulary: RecognitionVocabularySnapshot?
  public var language: String?
  public var hints: RecognitionHints

  public init(
    modelID: String? = nil,
    vocabulary: RecognitionVocabularySnapshot? = nil,
    language: String? = nil,
    hints: RecognitionHints = .empty
  ) {
    self.modelID = modelID
    self.vocabulary = vocabulary
    self.language = language
    self.hints = hints
  }

  public static let empty = SpeechRecognitionRequestOptions()
}

public enum RecognitionHintApplicationStatus: String, Sendable {
  case notRequested
  case unsupported
  case applied
  case unavailable
}

public enum RecognitionHintKind: String, Codable, Sendable, Hashable {
  case keyterm
}

public struct SpeechRecognizerCapabilities: Sendable, Equatable {
  public var supportedHintKinds: Set<RecognitionHintKind>
  public var streamingSupportedHintKinds: Set<RecognitionHintKind>
  public var maximumAudioDurationSeconds: Double?

  public init(
    supportedHintKinds: Set<RecognitionHintKind> = [],
    streamingSupportedHintKinds: Set<RecognitionHintKind> = [],
    maximumAudioDurationSeconds: Double? = nil
  ) {
    self.supportedHintKinds = supportedHintKinds
    self.streamingSupportedHintKinds = streamingSupportedHintKinds
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
