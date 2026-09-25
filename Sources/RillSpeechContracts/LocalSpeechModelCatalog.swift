import Foundation
import RillCore

public typealias LocalSpeechModelBackend = LocalSpeechEngine

public enum LocalSpeechModelSelectionError: Error, LocalizedError, Sendable, Equatable {
  case unsupportedModelIdentifier(String)
  case modelNotEnabled(String)
  case backendUnavailable(LocalSpeechModelBackend)

  public var errorDescription: String? {
    switch self {
    case .unsupportedModelIdentifier(let identifier):
      "The local speech model is not supported: \(identifier)."
    case .modelNotEnabled:
      "The selected local speech model is disabled. Enable it in Settings or select another model."
    case .backendUnavailable(let backend):
      "The local speech backend is unavailable: \(backend.rawValue)."
    }
  }
}

public enum LocalSpeechRecognitionPolicy {
  public static let maximumAudioDurationSeconds =
    Int(LocalSpeechCaptureLimits.maximumRequestedDurationSeconds)
  public static let maximumAcceptedAudioDurationSeconds =
    LocalSpeechCaptureLimits.maximumAcceptedDurationSeconds
  public static let maximumThreadCount = 16
  private static let maximumHotwordCount = 16
  private static let maximumHotwordUTF8ByteCount = 48
  private static let maximumHotwordScalarCount = 128

  public static func resolvedLanguage(
    requestLanguage: String?,
    workflowLanguage: String?,
    configurationLanguage: String?
  ) -> String? {
    normalizedLanguage(requestLanguage)
      ?? normalizedLanguage(workflowLanguage)
      ?? normalizedLanguage(configurationLanguage)
  }

  public static func sanitizedQwenHotwords(_ keyterms: [String]) -> [String] {
    var hotwords: [String] = []
    var seen = Set<String>()
    var totalByteCount = 0
    for keyterm in keyterms {
      let candidate = keyterm.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !candidate.isEmpty,
        candidate.unicodeScalars.count <= maximumHotwordScalarCount,
        !candidate.contains(","),
        !candidate.unicodeScalars.contains(where: {
          CharacterSet.controlCharacters.contains($0)
            || CharacterSet.newlines.contains($0)
        }),
        seen.insert(candidate).inserted
      else { continue }
      let byteCount = candidate.utf8.count
      guard totalByteCount + byteCount <= maximumHotwordUTF8ByteCount else { break }
      hotwords.append(candidate)
      totalByteCount += byteCount
      if hotwords.count == maximumHotwordCount { break }
    }
    return hotwords
  }

  private static func normalizedLanguage(_ language: String?) -> String? {
    let value = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !value.isEmpty,
      !value.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
          || CharacterSet.newlines.contains($0)
      })
    else { return nil }
    return value
  }
}

public enum MLXAudioModelID: String, CaseIterable, Codable, Sendable {
  case qwen3ASR06BInt8 = "qwen3-asr-0.6b-mlx-8bit"
  case qwen3ASR17BInt8 = "qwen3-asr-1.7b-mlx-8bit"
}

public struct MLXAudioModelFile: Codable, Equatable, Sendable {
  public let path: String
  public let byteCount: UInt64
  public let sha256: String

  public init(path: String, byteCount: UInt64, sha256: String) {
    self.path = path
    self.byteCount = byteCount
    self.sha256 = sha256
  }
}

public struct MLXAudioModelDescriptor: Equatable, Sendable {
  public let id: MLXAudioModelID
  public let repository: String
  public let revision: String
  public let approximateDownloadByteCount: UInt64
  public let files: [MLXAudioModelFile]
}

public enum MLXAudioModelCatalog {
  public static let qwen3ASR06BInt8 = MLXAudioModelDescriptor(
    id: .qwen3ASR06BInt8,
    repository: "mlx-community/Qwen3-ASR-0.6B-8bit",
    revision: "89e96d92ba34aca20b3e29fb10cc284097d1219f",
    approximateDownloadByteCount: 1_010_771_234,
    files: [
      .init(
        path: "chat_template.json",
        byteCount: 1_161,
        sha256: "75a8cfca24f00de72d796fbfed6858fc9614ef3dabd8696684cc3bc03a9c58ff"
      ),
      .init(
        path: "config.json",
        byteCount: 7_187,
        sha256: "5d104a945fed08728ab010f12bf3ce5ab4d0794bba276d81bff5bd83ae9d2be0"
      ),
      .init(
        path: "generation_config.json",
        byteCount: 142,
        sha256: "1da527824d81e07118facff437e03f2e24a23311e3bdeb2368973fe77e5f275c"
      ),
      .init(
        path: "merges.txt",
        byteCount: 1_671_853,
        sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"
      ),
      .init(
        path: "model.safetensors",
        byteCount: 1_006_229_426,
        sha256: "b5bfe4abc1b4c6e58b633096682ec2b6297298add1527119936107d211adf0e8"
      ),
      .init(
        path: "model.safetensors.index.json",
        byteCount: 71_815,
        sha256: "caa32ece76c395ba241533eb4aceb0efbc72488ef3d8d2fd3c677ce068dad57d"
      ),
      .init(
        path: "preprocessor_config.json",
        byteCount: 330,
        sha256: "45e120a4eda2c20c5d7f2ea9354e63536bf35e27aa573fb7cdf78017b378770d"
      ),
      .init(
        path: "tokenizer_config.json",
        byteCount: 12_487,
        sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"
      ),
      .init(
        path: "vocab.json",
        byteCount: 2_776_833,
        sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"
      ),
    ]
  )

  public static let qwen3ASR17BInt8 = MLXAudioModelDescriptor(
    id: .qwen3ASR17BInt8,
    repository: "mlx-community/Qwen3-ASR-1.7B-8bit",
    revision: "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
    approximateDownloadByteCount: 2_468_000_000,
    files: [
      .init(
        path: "chat_template.json",
        byteCount: 1_161,
        sha256: "75a8cfca24f00de72d796fbfed6858fc9614ef3dabd8696684cc3bc03a9c58ff"
      ),
      .init(
        path: "config.json",
        byteCount: 7_188,
        sha256: "1b76b3b6c655fc54595da025f7a96474ad9fa86363303fbdd61a7d8483ccfaf7"
      ),
      .init(
        path: "generation_config.json",
        byteCount: 142,
        sha256: "1da527824d81e07118facff437e03f2e24a23311e3bdeb2368973fe77e5f275c"
      ),
      .init(
        path: "merges.txt",
        byteCount: 1_671_853,
        sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"
      ),
      .init(
        path: "model.safetensors",
        byteCount: 2_463_307_541,
        sha256: "bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c"
      ),
      .init(
        path: "model.safetensors.index.json",
        byteCount: 78_968,
        sha256: "0a5d0ec11188602242ff81a9969883d0fdeb98cd5d85cd1413089d897c201af5"
      ),
      .init(
        path: "preprocessor_config.json",
        byteCount: 330,
        sha256: "45e120a4eda2c20c5d7f2ea9354e63536bf35e27aa573fb7cdf78017b378770d"
      ),
      .init(
        path: "tokenizer_config.json",
        byteCount: 12_487,
        sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"
      ),
      .init(
        path: "vocab.json",
        byteCount: 2_776_833,
        sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"
      ),
    ]
  )

  public static let distributable = [qwen3ASR06BInt8, qwen3ASR17BInt8]

  public static let distributableModelIdentifiers = Set(
    distributable.map { $0.id.rawValue }
  )

  public static func descriptor(for id: MLXAudioModelID) -> MLXAudioModelDescriptor {
    switch id {
    case .qwen3ASR06BInt8:
      qwen3ASR06BInt8
    case .qwen3ASR17BInt8:
      qwen3ASR17BInt8
    }
  }
}

public enum LocalSpeechModelCatalog {
  public static func recognitionOptions(
    settings: LocalSpeechSettings, workflow: WorkflowDefinition
  ) -> SpeechRecognitionRequestOptions {
    SpeechRecognitionRequestOptions(
      modelID: effectiveModelIdentifier(settings: settings, workflow: workflow),
      language: LocalSpeechRecognitionPolicy.resolvedLanguage(
        requestLanguage: workflow.plan.setup.speechRoute?.language,
        workflowLanguage: workflow.metadata[WorkflowMetadataKey.languageOverride],
        configurationLanguage: settings.language))
  }

  public static let defaultModelIdentifier = MLXAudioModelID.qwen3ASR06BInt8.rawValue

  public static let distributableModelIdentifiers =
    MLXAudioModelCatalog.distributableModelIdentifiers

  public static func backend(
    for modelIdentifier: String
  ) throws -> LocalSpeechModelBackend {
    if MLXAudioModelCatalog.distributableModelIdentifiers.contains(modelIdentifier) {
      return .mlxAudioSwift
    }
    throw LocalSpeechModelSelectionError.unsupportedModelIdentifier(modelIdentifier)
  }

  public static func effectiveModelIdentifier(
    settings: LocalSpeechSettings,
    workflow: WorkflowDefinition? = nil
  ) -> String {
    if let workflow,
      let override =
        (workflow.metadata[WorkflowMetadataKey.localSpeechModelOverride]
        ?? workflow.metadata[WorkflowMetadataKey.legacyWhisperKitModelOverride])?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !override.isEmpty
    {
      return normalizedLegacyModelID(override)
    }
    let configured = normalizedLegacyModelID(
      settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    guard distributableModelIdentifiers.contains(configured),
      !settings.enabledModelIDs.contains(configured)
    else { return configured }
    return MLXAudioModelCatalog.distributable.first {
      settings.enabledModelIDs.contains($0.id.rawValue)
    }?.id.rawValue ?? configured
  }

  public static func normalizedLegacyModelID(_ modelID: String) -> String {
    let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    switch normalized.lowercased() {
    case "", "auto", "sherpa-onnx.local", "sherpa-onnx.streaming",
      "sherpa-onnx-qwen3-asr-0.6b-int8-2026-03-25":
      return defaultModelIdentifier
    default:
      return normalized
    }
  }
}
