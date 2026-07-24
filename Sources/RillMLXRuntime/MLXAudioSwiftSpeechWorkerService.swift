import Darwin
import Foundation
import HuggingFace
import MLXAudioCore
import MLXAudioSTT
import RillCore
import RillProviders

public enum MLXAudioSwiftRuntimeError: Error, LocalizedError, Sendable, Equatable {
  case architectureUnsupported
  case unsupportedModel(String)
  case modelUnavailable(String)
  case invalidModelStore
  case invalidAudio
  case modelLoadFailed

  public var errorDescription: String? {
    switch self {
    case .architectureUnsupported:
      "MLX-Audio Swift requires Apple Silicon."
    case .unsupportedModel(let modelID):
      "The MLX-Audio Swift model is unsupported: \(modelID)."
    case .modelUnavailable(let modelID):
      "The MLX-Audio Swift model is unavailable: \(modelID)."
    case .invalidModelStore:
      "The MLX-Audio Swift model store is invalid."
    case .invalidAudio:
      "The captured audio is invalid."
    case .modelLoadFailed:
      "The MLX-Audio Swift model could not be loaded."
    }
  }
}

struct MLXAudioSwiftInferenceOutput: Sendable, Equatable {
  let text: String
  let detectedLanguage: String?
  let processingDurationMillis: Int
}

protocol MLXAudioSwiftInferenceEngine: Sendable {
  func prepare(modelID: String, downloadIfNeeded: Bool) async throws -> String

  func recognize(
    modelID: String,
    audioURL: URL,
    language: String?,
    keyterms: [String],
    downloadIfNeeded: Bool
  ) async throws -> MLXAudioSwiftInferenceOutput
}

public actor MLXAudioSwiftSpeechWorkerService: SpeechWorkerRequestHandling {
  private let engine: any MLXAudioSwiftInferenceEngine

  public init() {
    self.engine = MLXAudioSwiftQwenEngine()
  }

  init(engine: any MLXAudioSwiftInferenceEngine) {
    self.engine = engine
  }

  public func handle(_ request: SpeechWorkerRequest) async -> SpeechWorkerResponse {
    do {
      guard request.protocolVersion == SpeechWorkerProtocol.version else {
        throw SpeechWorkerProtocolError.unsupportedVersion
      }
      switch request.operation {
      case .prepareModel:
        guard request.recognitionPayload == nil,
          let payload = request.modelPreparationPayload
        else {
          throw SpeechWorkerProtocolError.invalidRequest
        }
        let prepared = try await engine.prepare(
          modelID: payload.modelID,
          downloadIfNeeded: payload.downloadIfNeeded
        )
        return .prepared(request: request, modelID: prepared)

      case .recognizeOffline:
        guard request.modelPreparationPayload == nil,
          let payload = request.recognitionPayload
        else {
          throw SpeechWorkerProtocolError.invalidRequest
        }
        try SherpaOnnxRecognizer.validateCapturedAudioDuration(
          payload.audioDurationSeconds
        )
        let audioURL: URL
        do {
          audioURL = try SpeechWorkerInputValidation.validatedManagedAudioURL(
            path: payload.audioFilePath
          )
        } catch {
          throw MLXAudioSwiftRuntimeError.invalidAudio
        }
        let output = try await engine.recognize(
          modelID: payload.modelID,
          audioURL: audioURL,
          language: payload.language,
          keyterms: payload.keyterms,
          downloadIfNeeded: payload.downloadIfNeeded
        )
        var metadata = [
          "provider.kind": LocalSpeechModelBackend.mlxAudioSwift.rawValue,
          "provider.model": payload.modelID,
          "provider.runtime": "mlx-audio-swift-0.1.3",
        ]
        if let detectedLanguage = output.detectedLanguage {
          metadata["provider.detected_language"] = detectedLanguage
        }
        let result = SpeechWorkerRecognitionResult(
          rawText: output.text,
          bestText: output.text,
          metadata: metadata,
          processingDurationMillis: output.processingDurationMillis
        )
        return .success(request: request, result: result)
      }
    } catch {
      return .failure(request: request, code: Self.failureCode(for: error))
    }
  }

  private static func failureCode(for error: Error) -> SpeechWorkerFailureCode {
    if let error = error as? SpeechWorkerProtocolError {
      switch error {
      case .unsupportedVersion:
        return .unsupportedProtocol
      case .frameTooLarge, .unterminatedFrame, .invalidFrame, .invalidRequest, .invalidResponse:
        return .invalidRequest
      }
    }
    if let error = error as? MLXAudioSwiftRuntimeError {
      switch error {
      case .unsupportedModel:
        return .unsupportedModel
      case .modelUnavailable, .invalidModelStore, .modelLoadFailed:
        return .modelUnavailable
      case .invalidAudio:
        return .invalidAudio
      case .architectureUnsupported:
        return .recognitionFailed
      }
    }
    if let error = error as? SherpaOnnxRecognizer.RecognizerError {
      switch error {
      case .audioTooLong, .emptyAudio, .invalidAudioFile, .audioConversionFailed,
        .fileBackedAudioRequired, .missingCapturedAudio, .nonFiniteAudioSample:
        return .invalidAudio
      case .unsupportedModelIdentifier, .invalidThreadCount:
        return .unsupportedModel
      case .modelNotInstalled:
        return .modelUnavailable
      }
    }
    return .recognitionFailed
  }
}

enum MLXAudioSwiftQwenOptions {
  static func resolvedLanguage(_ language: String?) -> String? {
    let normalized = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    switch normalized.lowercased() {
    case "", "auto":
      return nil
    case "zh", "zh-cn", "zh-hans", "zh-tw", "zh-hant", "cmn":
      return "Chinese"
    case "en", "en-us", "en-gb":
      return "English"
    case "yue", "yue-hk", "yue-hant-hk":
      return "Cantonese"
    default:
      return normalized
    }
  }

  static func context(from keyterms: [String]) -> String {
    let sanitized = SherpaOnnxRecognizer.sanitizedQwenHotwords(keyterms)
    guard !sanitized.isEmpty else { return "" }
    return "Keywords: \(sanitized.joined(separator: ", "))."
  }
}

private actor MLXAudioSwiftQwenEngine: MLXAudioSwiftInferenceEngine {
  private struct LoadedModel {
    let id: MLXAudioModelID
    let model: Qwen3ASRModel
  }

  private let store: MLXAudioSwiftModelStore
  private var loadedModel: LoadedModel?

  init(store: MLXAudioSwiftModelStore = .init()) {
    self.store = store
  }

  func prepare(modelID: String, downloadIfNeeded: Bool) async throws -> String {
    #if !arch(arm64)
      throw MLXAudioSwiftRuntimeError.architectureUnsupported
    #else
      guard let id = MLXAudioModelID(rawValue: modelID),
        MLXAudioModelCatalog.distributableModelIdentifiers.contains(modelID)
      else {
        throw MLXAudioSwiftRuntimeError.unsupportedModel(modelID)
      }
      if loadedModel?.id == id {
        return id.rawValue
      }
      let descriptor = MLXAudioModelCatalog.descriptor(for: id)
      let modelDirectory = try await store.modelDirectory(
        descriptor: descriptor,
        downloadIfNeeded: downloadIfNeeded
      )
      let model: Qwen3ASRModel
      do {
        model = try await Qwen3ASRModel.fromModelDirectory(modelDirectory)
      } catch {
        throw MLXAudioSwiftRuntimeError.modelLoadFailed
      }
      loadedModel = LoadedModel(id: id, model: model)
      return id.rawValue
    #endif
  }

  func recognize(
    modelID: String,
    audioURL: URL,
    language: String?,
    keyterms: [String],
    downloadIfNeeded: Bool
  ) async throws -> MLXAudioSwiftInferenceOutput {
    _ = try await prepare(modelID: modelID, downloadIfNeeded: downloadIfNeeded)
    guard let loadedModel else {
      throw MLXAudioSwiftRuntimeError.modelLoadFailed
    }
    let resolvedLanguage = MLXAudioSwiftQwenOptions.resolvedLanguage(language)
    let context = MLXAudioSwiftQwenOptions.context(from: keyterms)
    let output = try {
      do {
        let (_, audio) = try loadAudioArray(from: audioURL, sampleRate: 16_000)
        return loadedModel.model.generate(
          audio: audio,
          temperature: 0,
          context: context,
          language: resolvedLanguage
        )
      } catch {
        throw MLXAudioSwiftRuntimeError.invalidAudio
      }
    }()
    let durationMillis = max(0, Int(output.totalTime * 1_000))
    return MLXAudioSwiftInferenceOutput(
      text: output.text.trimmingCharacters(in: .whitespacesAndNewlines),
      detectedLanguage: output.language ?? resolvedLanguage,
      processingDurationMillis: durationMillis
    )
  }
}

private struct MLXAudioSwiftModelReceipt: Codable, Equatable {
  let schemaVersion: Int
  let modelID: String
  let repository: String
  let revision: String
}

struct MLXAudioSwiftModelStore: Sendable {
  static let receiptFileName = ".rill-mlx-audio-swift-model.json"
  static let requiredFileNames = [
    "config.json",
    "model.safetensors",
    "model.safetensors.index.json",
    "preprocessor_config.json",
    "tokenizer_config.json",
    "vocab.json",
    "merges.txt",
  ]

  let modelRootURL: URL
  let hubCacheRootURL: URL

  init(
    modelRootURL: URL = Self.defaultModelRootURL(),
    hubCacheRootURL: URL = Self.defaultHubCacheRootURL()
  ) {
    self.modelRootURL = modelRootURL
    self.hubCacheRootURL = hubCacheRootURL
  }

  func modelDirectory(
    descriptor: MLXAudioModelDescriptor,
    downloadIfNeeded: Bool
  ) async throws -> URL {
    // Keep a Rill-owned, exact-revision publication directory. The
    // mlx-audio-swift 0.1.3 loader consumes it directly without re-resolving the
    // repository name or contacting a moving branch.
    let publicationParentURL =
      modelRootURL.appendingPathComponent("mlx-audio", isDirectory: true)
    let publicationURL = publicationParentURL.appendingPathComponent(
      descriptor.repository.replacingOccurrences(of: "/", with: "_"),
      isDirectory: true
    )
    if try Self.validatePublishedModel(at: publicationURL, descriptor: descriptor) {
      return publicationURL
    }
    guard downloadIfNeeded else {
      throw MLXAudioSwiftRuntimeError.modelUnavailable(descriptor.id.rawValue)
    }

    try Self.preparePrivateDirectory(modelRootURL)
    try Self.preparePrivateDirectory(publicationParentURL)
    try Self.preparePrivateDirectory(hubCacheRootURL)
    let stagingURL = publicationParentURL.appendingPathComponent(
      ".\(descriptor.id.rawValue).\(UUID().uuidString.lowercased()).partial",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: stagingURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    var shouldRemoveStaging = true
    defer {
      if shouldRemoveStaging {
        try? FileManager.default.removeItem(at: stagingURL)
      }
    }

    guard let repository = Repo.ID(rawValue: descriptor.repository) else {
      throw MLXAudioSwiftRuntimeError.invalidModelStore
    }
    let cache = HubCache(cacheDirectory: hubCacheRootURL)
    let client = HubClient(cache: cache)
    do {
      _ = try await client.downloadSnapshot(
        of: repository,
        kind: .model,
        to: stagingURL,
        revision: descriptor.revision,
        matching: [
          "*.json",
          "*.safetensors",
          "*.txt",
          "*.model",
          "*.tiktoken",
          "*.jinja",
          "*.jsonl",
          "*.yaml",
          "*.npz",
        ],
        localFilesOnly: false,
        maxConcurrentDownloads: 4,
        progressHandler: nil
      )
    } catch {
      throw MLXAudioSwiftRuntimeError.modelUnavailable(descriptor.id.rawValue)
    }

    let receipt = MLXAudioSwiftModelReceipt(
      schemaVersion: 1,
      modelID: descriptor.id.rawValue,
      repository: descriptor.repository,
      revision: descriptor.revision
    )
    let receiptData = try JSONEncoder().encode(receipt)
    try receiptData.write(
      to: stagingURL.appendingPathComponent(Self.receiptFileName),
      options: .atomic
    )
    guard try Self.validatePublishedModel(at: stagingURL, descriptor: descriptor) else {
      throw MLXAudioSwiftRuntimeError.invalidModelStore
    }

    let quarantineURL = publicationParentURL.appendingPathComponent(
      ".\(descriptor.id.rawValue).\(UUID().uuidString.lowercased()).replaced",
      isDirectory: true
    )
    if FileManager.default.fileExists(atPath: publicationURL.path) {
      try FileManager.default.moveItem(at: publicationURL, to: quarantineURL)
    }
    do {
      try FileManager.default.moveItem(at: stagingURL, to: publicationURL)
      shouldRemoveStaging = false
      try? FileManager.default.removeItem(at: quarantineURL)
    } catch {
      if FileManager.default.fileExists(atPath: quarantineURL.path),
        !FileManager.default.fileExists(atPath: publicationURL.path)
      {
        try? FileManager.default.moveItem(at: quarantineURL, to: publicationURL)
      }
      throw MLXAudioSwiftRuntimeError.invalidModelStore
    }
    return publicationURL
  }

  static func validatePublishedModel(
    at directory: URL,
    descriptor: MLXAudioModelDescriptor
  ) throws -> Bool {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
      atPath: directory.path,
      isDirectory: &isDirectory
    ), isDirectory.boolValue
    else {
      return false
    }
    let values = try directory.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    )
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      return false
    }
    for fileName in requiredFileNames {
      let fileURL = directory.appendingPathComponent(fileName)
      let fileValues = try fileURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
      )
      guard fileValues.isRegularFile == true,
        fileValues.isSymbolicLink != true,
        (fileValues.fileSize ?? 0) > 0
      else {
        return false
      }
    }
    let receiptURL = directory.appendingPathComponent(receiptFileName)
    let receiptValues = try receiptURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    )
    guard receiptValues.isRegularFile == true,
      receiptValues.isSymbolicLink != true,
      let receiptSize = receiptValues.fileSize,
      receiptSize > 0,
      receiptSize <= 16 * 1_024
    else {
      return false
    }
    let receipt = try JSONDecoder().decode(
      MLXAudioSwiftModelReceipt.self,
      from: Data(contentsOf: receiptURL)
    )
    return receipt
      == MLXAudioSwiftModelReceipt(
        schemaVersion: 1,
        modelID: descriptor.id.rawValue,
        repository: descriptor.repository,
        revision: descriptor.revision
      )
  }

  private static func preparePrivateDirectory(_ directory: URL) throws {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let values = try directory.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    )
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw MLXAudioSwiftRuntimeError.invalidModelStore
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o700)],
      ofItemAtPath: directory.path
    )
  }

  private static func defaultModelRootURL(
    fileManager: FileManager = .default
  ) -> URL {
    let applicationSupport =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support",
        isDirectory: true
      )
    return
      applicationSupport
      .appendingPathComponent("Rill", isDirectory: true)
      .appendingPathComponent("Models", isDirectory: true)
      .appendingPathComponent("mlx-audio-swift", isDirectory: true)
  }

  private static func defaultHubCacheRootURL(
    fileManager: FileManager = .default
  ) -> URL {
    let caches =
      fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Caches",
        isDirectory: true
      )
    return
      caches
      .appendingPathComponent("Rill", isDirectory: true)
      .appendingPathComponent("huggingface", isDirectory: true)
      .appendingPathComponent("hub", isDirectory: true)
  }
}
