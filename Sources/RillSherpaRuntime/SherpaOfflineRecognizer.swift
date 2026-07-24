import CSherpaOnnx
import Darwin
import Foundation

public struct SherpaQwen3ASRConfiguration: Equatable, Sendable {
  public static let modelID = "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25"
  public static let maximumThreadCount = 16
  public static let maximumTotalLengthLimit = 4_096
  public static let maximumNewTokensLimit = 2_048
  public static let defaultMaximumTotalLength = 512
  public static let defaultMaximumNewTokens = 128
  public static let maximumHotwordCount = 16
  public static let maximumHotwordUTF8ByteCount = 48

  public var convolutionFrontend: URL
  public var encoder: URL
  public var decoder: URL
  public var tokenizerDirectory: URL
  public var threadCount: Int
  public var maximumTotalLength: Int
  public var maximumNewTokens: Int
  public var temperature: Float
  public var topP: Float
  public var seed: Int
  public var hotwords: [String]

  public init(
    convolutionFrontend: URL,
    encoder: URL,
    decoder: URL,
    tokenizerDirectory: URL,
    threadCount: Int = 2,
    maximumTotalLength: Int = Self.defaultMaximumTotalLength,
    maximumNewTokens: Int = Self.defaultMaximumNewTokens,
    temperature: Float = 1e-6,
    topP: Float = 0.8,
    seed: Int = 42,
    hotwords: [String] = []
  ) {
    self.convolutionFrontend = convolutionFrontend
    self.encoder = encoder
    self.decoder = decoder
    self.tokenizerDirectory = tokenizerDirectory
    self.threadCount = threadCount
    self.maximumTotalLength = maximumTotalLength
    self.maximumNewTokens = maximumNewTokens
    self.temperature = temperature
    self.topP = topP
    self.seed = seed
    self.hotwords = hotwords
  }

  public static func validateHotwords(_ hotwords: [String]) throws {
    guard hotwords.count <= maximumHotwordCount else {
      throw SherpaOfflineRecognizerError.invalidConfiguration(
        "Qwen3 hotwords exceed the supported count or UTF-8 byte limit"
      )
    }

    var totalUTF8ByteCount = 0
    for hotword in hotwords {
      guard
        !hotword.isEmpty,
        !hotword.contains(","),
        !hotword.unicodeScalars.contains(where: { scalar in
          CharacterSet.controlCharacters.contains(scalar)
            || CharacterSet.newlines.contains(scalar)
        })
      else {
        throw SherpaOfflineRecognizerError.invalidConfiguration(
          "Qwen3 hotwords must be non-empty and cannot contain commas or control characters"
        )
      }

      let byteCount = hotword.utf8.count
      guard byteCount <= maximumHotwordUTF8ByteCount - totalUTF8ByteCount else {
        throw SherpaOfflineRecognizerError.invalidConfiguration(
          "Qwen3 hotwords exceed the supported count or UTF-8 byte limit"
        )
      }
      totalUTF8ByteCount += byteCount
    }
  }
}

public struct SherpaSenseVoiceConfiguration: Equatable, Sendable {
  public static let modelID =
    "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
  public static let maximumThreadCount = 16
  public static let maximumLanguageUTF8ByteCount = 64

  public var model: URL
  public var tokens: URL
  public var language: String
  public var usesInverseTextNormalization: Bool
  public var threadCount: Int

  public init(
    model: URL,
    tokens: URL,
    language: String = "",
    usesInverseTextNormalization: Bool = true,
    threadCount: Int = 2
  ) {
    self.model = model
    self.tokens = tokens
    self.language = language
    self.usesInverseTextNormalization = usesInverseTextNormalization
    self.threadCount = threadCount
  }
}

public struct SherpaFunASRNanoConfiguration: Equatable, Sendable {
  public static let modelID = "sherpa-onnx-funasr-nano"
  public static let maximumThreadCount = 16
  public static let maximumLanguageUTF8ByteCount = 64

  public var encoderAdaptor: URL
  public var languageModel: URL
  public var embedding: URL
  public var tokenizerDirectory: URL
  public var language: String
  public var usesInverseTextNormalization: Bool
  public var threadCount: Int

  public init(
    encoderAdaptor: URL,
    languageModel: URL,
    embedding: URL,
    tokenizerDirectory: URL,
    language: String = "",
    usesInverseTextNormalization: Bool = true,
    threadCount: Int = 2
  ) {
    self.encoderAdaptor = encoderAdaptor
    self.languageModel = languageModel
    self.embedding = embedding
    self.tokenizerDirectory = tokenizerDirectory
    self.language = language
    self.usesInverseTextNormalization = usesInverseTextNormalization
    self.threadCount = threadCount
  }
}

public struct SherpaOmnilingualCTCConfiguration: Equatable, Sendable {
  public static let modelID = "sherpa-onnx-omnilingual-asr-ctc"
  public static let maximumThreadCount = 16

  public var model: URL
  public var tokens: URL
  public var threadCount: Int

  public init(
    model: URL,
    tokens: URL,
    threadCount: Int = 2
  ) {
    self.model = model
    self.tokens = tokens
    self.threadCount = threadCount
  }
}

public struct SherpaCohereTranscribeConfiguration: Equatable, Sendable {
  public static let modelID = "sherpa-onnx-cohere-transcribe"
  public static let maximumThreadCount = 16
  public static let maximumLanguageUTF8ByteCount = 64

  public var encoder: URL
  public var encoderData: URL
  public var decoder: URL
  public var tokens: URL
  public var language: String
  public var usesPunctuation: Bool
  public var usesInverseTextNormalization: Bool
  public var threadCount: Int

  public init(
    encoder: URL,
    encoderData: URL,
    decoder: URL,
    tokens: URL,
    language: String = "",
    usesPunctuation: Bool = true,
    usesInverseTextNormalization: Bool = true,
    threadCount: Int = 2
  ) {
    self.encoder = encoder
    self.encoderData = encoderData
    self.decoder = decoder
    self.tokens = tokens
    self.language = language
    self.usesPunctuation = usesPunctuation
    self.usesInverseTextNormalization = usesInverseTextNormalization
    self.threadCount = threadCount
  }
}

public enum SherpaOfflineModelConfiguration: Equatable, Sendable {
  case qwen3(SherpaQwen3ASRConfiguration)
  case funASRNano(SherpaFunASRNanoConfiguration)
  case omnilingualCTC(SherpaOmnilingualCTCConfiguration)
  case cohereTranscribe(SherpaCohereTranscribeConfiguration)
  case senseVoice(SherpaSenseVoiceConfiguration)

  public var modelID: String {
    switch self {
    case .qwen3:
      SherpaQwen3ASRConfiguration.modelID
    case .funASRNano:
      SherpaFunASRNanoConfiguration.modelID
    case .omnilingualCTC:
      SherpaOmnilingualCTCConfiguration.modelID
    case .cohereTranscribe:
      SherpaCohereTranscribeConfiguration.modelID
    case .senseVoice:
      SherpaSenseVoiceConfiguration.modelID
    }
  }

  public func validate() throws {
    switch self {
    case .qwen3(let configuration):
      try Self.validateBoundedPositive(
        configuration.threadCount,
        maximum: SherpaQwen3ASRConfiguration.maximumThreadCount,
        named: "threadCount"
      )
      try Self.validateBoundedPositive(
        configuration.maximumTotalLength,
        maximum: SherpaQwen3ASRConfiguration.maximumTotalLengthLimit,
        named: "maximumTotalLength"
      )
      try Self.validateBoundedPositive(
        configuration.maximumNewTokens,
        maximum: min(
          configuration.maximumTotalLength,
          SherpaQwen3ASRConfiguration.maximumNewTokensLimit
        ),
        named: "maximumNewTokens"
      )
      guard configuration.temperature.isFinite, configuration.temperature > 0 else {
        throw SherpaOfflineRecognizerError.invalidConfiguration(
          "temperature must be finite and greater than zero"
        )
      }
      guard configuration.topP.isFinite,
        (0...1).contains(configuration.topP),
        configuration.topP > 0
      else {
        throw SherpaOfflineRecognizerError.invalidConfiguration(
          "topP must be finite and in the interval (0, 1]"
        )
      }
      guard Int32(exactly: configuration.seed) != nil else {
        throw SherpaOfflineRecognizerError.invalidConfiguration(
          "seed must fit in Int32"
        )
      }

      try SherpaQwen3ASRConfiguration.validateHotwords(configuration.hotwords)

      try Self.requireRegularFile(configuration.convolutionFrontend)
      try Self.requireRegularFile(configuration.encoder)
      try Self.requireRegularFile(configuration.decoder)
      try Self.requireDirectory(configuration.tokenizerDirectory)

      for filename in ["merges.txt", "tokenizer_config.json", "vocab.json"] {
        try Self.requireRegularFile(
          configuration.tokenizerDirectory.appendingPathComponent(filename)
        )
      }

    case .funASRNano(let configuration):
      try Self.validateBoundedPositive(
        configuration.threadCount,
        maximum: SherpaFunASRNanoConfiguration.maximumThreadCount,
        named: "threadCount"
      )
      try Self.requireRegularFile(configuration.encoderAdaptor)
      try Self.requireRegularFile(configuration.languageModel)
      try Self.requireRegularFile(configuration.embedding)
      try Self.requireDirectory(configuration.tokenizerDirectory)
      for filename in ["merges.txt", "tokenizer.json", "vocab.json"] {
        try Self.requireRegularFile(
          configuration.tokenizerDirectory.appendingPathComponent(filename)
        )
      }
      try Self.validateLanguage(
        configuration.language,
        maximumUTF8ByteCount: SherpaFunASRNanoConfiguration.maximumLanguageUTF8ByteCount
      )

    case .omnilingualCTC(let configuration):
      try Self.validateBoundedPositive(
        configuration.threadCount,
        maximum: SherpaOmnilingualCTCConfiguration.maximumThreadCount,
        named: "threadCount"
      )
      try Self.requireRegularFile(configuration.model)
      try Self.requireRegularFile(configuration.tokens)

    case .cohereTranscribe(let configuration):
      try Self.validateBoundedPositive(
        configuration.threadCount,
        maximum: SherpaCohereTranscribeConfiguration.maximumThreadCount,
        named: "threadCount"
      )
      try Self.requireRegularFile(configuration.encoder)
      try Self.requireRegularFile(configuration.encoderData)
      try Self.requireRegularFile(configuration.decoder)
      try Self.requireRegularFile(configuration.tokens)
      try Self.validateLanguage(
        configuration.language,
        maximumUTF8ByteCount: SherpaCohereTranscribeConfiguration.maximumLanguageUTF8ByteCount
      )

    case .senseVoice(let configuration):
      try Self.validateBoundedPositive(
        configuration.threadCount,
        maximum: SherpaSenseVoiceConfiguration.maximumThreadCount,
        named: "threadCount"
      )
      try Self.requireRegularFile(configuration.model)
      try Self.requireRegularFile(configuration.tokens)
      try Self.validateLanguage(
        configuration.language,
        maximumUTF8ByteCount: SherpaSenseVoiceConfiguration.maximumLanguageUTF8ByteCount
      )
    }
  }

  private static func validateBoundedPositive(
    _ value: Int,
    maximum: Int,
    named name: String
  ) throws {
    guard value > 0, value <= maximum else {
      throw SherpaOfflineRecognizerError.invalidConfiguration(
        "\(name) must be in 1...\(maximum)"
      )
    }
  }

  private static func validateLanguage(
    _ language: String,
    maximumUTF8ByteCount: Int
  ) throws {
    guard language.utf8.count <= maximumUTF8ByteCount,
      !language.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
          || CharacterSet.newlines.contains($0)
      })
    else {
      throw SherpaOfflineRecognizerError.invalidConfiguration(
        "language cannot contain control characters or exceed the UTF-8 byte limit"
      )
    }
  }

  private static func requireRegularFile(
    _ url: URL
  ) throws {
    var status = stat()
    guard lstat(url.path, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_nlink == 1
    else {
      throw SherpaOfflineRecognizerError.missingArtifact(url)
    }
  }

  private static func requireDirectory(
    _ url: URL
  ) throws {
    var status = stat()
    guard lstat(url.path, &status) == 0,
      status.st_mode & S_IFMT == S_IFDIR
    else {
      throw SherpaOfflineRecognizerError.missingArtifact(url)
    }
  }
}

public struct SherpaOfflineRecognitionResult: Equatable, Sendable {
  public var text: String
  public var language: String
  public var emotion: String
  public var event: String
  public var timestamps: [Float]
  public var durations: [Float]

  public init(
    text: String,
    language: String,
    emotion: String,
    event: String,
    timestamps: [Float],
    durations: [Float]
  ) {
    self.text = text
    self.language = language
    self.emotion = emotion
    self.event = event
    self.timestamps = timestamps
    self.durations = durations
  }
}

public enum SherpaOfflineRecognizerError: Error, Equatable, Sendable {
  case invalidConfiguration(String)
  case missingArtifact(URL)
  case failedToCreateRecognizer(modelID: String)
  case emptyAudio
  case invalidAudioSample(index: Int)
  case audioTooLong(sampleCount: Int)
  case invalidSampleRate(Int)
  case decodingFailed
}

public final class SherpaOfflineRecognizer {
  public static var runtimeVersion: String {
    String(cString: RillSherpaOnnxVersion())
  }

  public static var runtimeGitSHA1: String {
    String(cString: RillSherpaOnnxGitSHA1())
  }

  public let configuration: SherpaOfflineModelConfiguration

  private let handle: OpaquePointer
  private let lock = NSLock()

  public init(configuration: SherpaOfflineModelConfiguration) throws {
    try configuration.validate()
    self.configuration = configuration

    let createdHandle: OpaquePointer? =
      switch configuration {
      case .qwen3(let configuration):
        Self.createQwen3Recognizer(configuration)
      case .funASRNano(let configuration):
        Self.createFunASRNanoRecognizer(configuration)
      case .omnilingualCTC(let configuration):
        Self.createOmnilingualRecognizer(configuration)
      case .cohereTranscribe(let configuration):
        Self.createCohereTranscribeRecognizer(configuration)
      case .senseVoice(let configuration):
        Self.createSenseVoiceRecognizer(configuration)
      }

    guard let createdHandle else {
      throw SherpaOfflineRecognizerError.failedToCreateRecognizer(
        modelID: configuration.modelID
      )
    }
    handle = createdHandle
  }

  deinit {
    RillSherpaDestroyOfflineRecognizer(handle)
  }

  public func transcribe(
    samples: [Float],
    sampleRate: Int = 16_000,
    hotwords: [String] = []
  ) throws -> SherpaOfflineRecognitionResult {
    if !hotwords.isEmpty {
      guard case .qwen3 = configuration else {
        throw SherpaOfflineRecognizerError.invalidConfiguration(
          "Per-request hotwords are supported only by Qwen3"
        )
      }
      try SherpaQwen3ASRConfiguration.validateHotwords(hotwords)
    }
    guard !samples.isEmpty else {
      throw SherpaOfflineRecognizerError.emptyAudio
    }
    guard samples.count <= Int(Int32.max) else {
      throw SherpaOfflineRecognizerError.audioTooLong(sampleCount: samples.count)
    }
    guard sampleRate > 0, sampleRate <= Int(Int32.max) else {
      throw SherpaOfflineRecognizerError.invalidSampleRate(sampleRate)
    }
    if let invalidIndex = samples.firstIndex(where: { !$0.isFinite || !(-1...1).contains($0) }) {
      throw SherpaOfflineRecognizerError.invalidAudioSample(index: invalidIndex)
    }

    lock.lock()
    defer { lock.unlock() }

    let rawResult = samples.withUnsafeBufferPointer { buffer in
      guard !hotwords.isEmpty else {
        // Keep the original no-options decode path source- and ABI-compatible.
        return RillSherpaDecodeOffline(
          handle,
          buffer.baseAddress,
          Int32(buffer.count),
          Int32(sampleRate)
        )
      }

      return hotwords.joined(separator: ",").withCString { hotwordsCSV in
        RillSherpaDecodeOfflineWithHotwords(
          handle,
          buffer.baseAddress,
          Int32(buffer.count),
          Int32(sampleRate),
          hotwordsCSV
        )
      }
    }
    guard let rawResult else {
      throw SherpaOfflineRecognizerError.decodingFailed
    }
    defer { RillSherpaDestroyOfflineResult(rawResult) }

    let value = rawResult.pointee
    let count = max(0, Int(value.count))
    let timestamps =
      value.timestamps.map {
        Array(UnsafeBufferPointer(start: $0, count: count))
      } ?? []
    let durations =
      value.durations.map {
        Array(UnsafeBufferPointer(start: $0, count: count))
      } ?? []

    return SherpaOfflineRecognitionResult(
      text: Self.string(value.text),
      language: Self.string(value.language),
      emotion: Self.string(value.emotion),
      event: Self.string(value.event),
      timestamps: timestamps,
      durations: durations
    )
  }

  private static func createQwen3Recognizer(
    _ configuration: SherpaQwen3ASRConfiguration
  ) -> OpaquePointer? {
    configuration.convolutionFrontend.path.withCString { convolutionFrontend in
      configuration.encoder.path.withCString { encoder in
        configuration.decoder.path.withCString { decoder in
          configuration.tokenizerDirectory.path.withCString { tokenizer in
            configuration.hotwords.joined(separator: ",").withCString { hotwords in
              RillSherpaCreateQwen3Recognizer(
                convolutionFrontend,
                encoder,
                decoder,
                tokenizer,
                Int32(configuration.threadCount),
                Int32(configuration.maximumTotalLength),
                Int32(configuration.maximumNewTokens),
                configuration.temperature,
                configuration.topP,
                Int32(configuration.seed),
                hotwords
              )
            }
          }
        }
      }
    }
  }

  private static func createSenseVoiceRecognizer(
    _ configuration: SherpaSenseVoiceConfiguration
  ) -> OpaquePointer? {
    configuration.model.path.withCString { model in
      configuration.tokens.path.withCString { tokens in
        configuration.language.withCString { language in
          RillSherpaCreateSenseVoiceRecognizer(
            model,
            tokens,
            language,
            configuration.usesInverseTextNormalization ? 1 : 0,
            Int32(configuration.threadCount)
          )
        }
      }
    }
  }

  private static func createFunASRNanoRecognizer(
    _ configuration: SherpaFunASRNanoConfiguration
  ) -> OpaquePointer? {
    configuration.encoderAdaptor.path.withCString { encoderAdaptor in
      configuration.languageModel.path.withCString { languageModel in
        configuration.embedding.path.withCString { embedding in
          configuration.tokenizerDirectory.path.withCString { tokenizer in
            configuration.language.withCString { language in
              RillSherpaCreateFunASRNanoRecognizer(
                encoderAdaptor,
                languageModel,
                embedding,
                tokenizer,
                language,
                configuration.usesInverseTextNormalization ? 1 : 0,
                Int32(configuration.threadCount),
                ""
              )
            }
          }
        }
      }
    }
  }

  private static func createOmnilingualRecognizer(
    _ configuration: SherpaOmnilingualCTCConfiguration
  ) -> OpaquePointer? {
    configuration.model.path.withCString { model in
      configuration.tokens.path.withCString { tokens in
        RillSherpaCreateOmnilingualRecognizer(
          model,
          tokens,
          Int32(configuration.threadCount)
        )
      }
    }
  }

  private static func createCohereTranscribeRecognizer(
    _ configuration: SherpaCohereTranscribeConfiguration
  ) -> OpaquePointer? {
    configuration.encoder.path.withCString { encoder in
      configuration.decoder.path.withCString { decoder in
        configuration.tokens.path.withCString { tokens in
          configuration.language.withCString { language in
            RillSherpaCreateCohereTranscribeRecognizer(
              encoder,
              decoder,
              tokens,
              language,
              configuration.usesPunctuation ? 1 : 0,
              configuration.usesInverseTextNormalization ? 1 : 0,
              Int32(configuration.threadCount)
            )
          }
        }
      }
    }
  }

  private static func string(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
    pointer.map { String(cString: $0) } ?? ""
  }
}
