import CryptoKit
import Darwin
import Foundation
import HuggingFace
import MLXAudioCore
import MLXAudioSTT
import MLXAudioTTS
import RillCore
import RillProviders

public enum MLXAudioSwiftRuntimeError: Error, LocalizedError, Sendable, Equatable {
  case architectureUnsupported
  case unsupportedModel(String)
  case modelUnavailable(String)
  case invalidModelStore
  case invalidAudio
  case modelLoadFailed
  case invalidText
  case synthesisFailed

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
    case .invalidText:
      "The speech synthesis request is invalid."
    case .synthesisFailed:
      "MLX-Audio Swift speech synthesis failed."
    }
  }
}

struct MLXAudioSwiftInferenceOutput: Sendable, Equatable {
  let text: String
  let detectedLanguage: String?
  let processingDurationMillis: Int
}

protocol MLXAudioSwiftInferenceEngine: Sendable {
  func prepare(
    modelID: String,
    downloadIfNeeded: Bool,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void
  ) async throws -> String

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
  private let ttsEngine: any MLXAudioSwiftTTSInferenceEngine

  public init() {
    self.engine = MLXAudioSwiftQwenEngine()
    self.ttsEngine = MLXAudioSwiftQwenTTSEngine()
  }

  init(
    engine: any MLXAudioSwiftInferenceEngine,
    ttsEngine: any MLXAudioSwiftTTSInferenceEngine = MLXAudioSwiftQwenTTSEngine()
  ) {
    self.engine = engine
    self.ttsEngine = ttsEngine
  }

  public func handle(
    _ request: SpeechWorkerRequest,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void
  ) async -> SpeechWorkerResponse {
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
          downloadIfNeeded: payload.downloadIfNeeded,
          progress: progress
        )
        return .prepared(request: request, modelID: prepared)

      case .recognizeOffline:
        guard request.modelPreparationPayload == nil,
          let payload = request.recognitionPayload
        else {
          throw SpeechWorkerProtocolError.invalidRequest
        }
        guard payload.audioDurationSeconds.isFinite,
          payload.audioDurationSeconds >= 0
        else {
          throw MLXAudioSwiftRuntimeError.invalidAudio
        }
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
      case .prepareTTSModel:
        guard request.recognitionPayload == nil,
          request.synthesisPayload == nil,
          let payload = request.modelPreparationPayload
        else {
          throw SpeechWorkerProtocolError.invalidRequest
        }
        let prepared = try await ttsEngine.prepareTTS(
          modelID: payload.modelID,
          downloadIfNeeded: payload.downloadIfNeeded,
          progress: progress
        )
        return .prepared(request: request, modelID: prepared)
      case .synthesizeSpeech:
        guard request.recognitionPayload == nil,
          request.modelPreparationPayload == nil,
          let payload = request.synthesisPayload
        else {
          throw SpeechWorkerProtocolError.invalidRequest
        }
        let output = try await ttsEngine.synthesize(payload: payload)
        return .synthesized(
          request: request,
          result: SpeechWorkerSynthesisResult(
            audioFilePath: output.audioFileURL.path,
            sampleRate: output.sampleRate,
            channelCount: output.channelCount,
            durationSeconds: output.durationSeconds
          )
        )
      case .releaseTTSModel:
        guard request.recognitionPayload == nil,
          request.synthesisPayload == nil,
          let payload = request.modelPreparationPayload
        else {
          throw SpeechWorkerProtocolError.invalidRequest
        }
        try await ttsEngine.releaseTTS(modelID: payload.modelID)
        return .released(request: request, modelID: payload.modelID)
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
      case .invalidText:
        return .invalidText
      case .synthesisFailed:
        return .synthesisFailed
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

  func prepare(
    modelID: String,
    downloadIfNeeded: Bool,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void
  ) async throws -> String {
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
        downloadIfNeeded: downloadIfNeeded,
        progress: progress
      )
      progress(
        SpeechWorkerProgress(
          phase: .loading,
          completedUnitCount: 0,
          totalUnitCount: 1
        )
      )
      let model: Qwen3ASRModel
      do {
        model = try await Qwen3ASRModel.fromModelDirectory(modelDirectory)
      } catch {
        throw MLXAudioSwiftRuntimeError.modelLoadFailed
      }
      loadedModel = LoadedModel(id: id, model: model)
      progress(
        SpeechWorkerProgress(
          phase: .loading,
          completedUnitCount: 1,
          totalUnitCount: 1
        )
      )
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
    _ = try await prepare(
      modelID: modelID,
      downloadIfNeeded: downloadIfNeeded,
      progress: { _ in }
    )
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
  let files: [MLXAudioModelFile]
}

struct MLXAudioSwiftModelStore: Sendable {
  static let receiptFileName = ".rill-mlx-audio-swift-model.json"
  static let generatedFileNames = ["tokenizer.json"]

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
    downloadIfNeeded: Bool,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void = { _ in }
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
    if FileManager.default.fileExists(atPath: publicationParentURL.path) {
      try Self.preparePrivateDirectory(publicationParentURL)
      try Self.removeAbandonedEntries(
        in: publicationParentURL,
        for: descriptor.id
      )
    }
    if Self.isRegularDirectory(publicationURL) {
      try Self.removeGeneratedFiles(at: publicationURL)
      if try Self.validatePublishedModel(at: publicationURL, descriptor: descriptor) {
        return publicationURL
      }
      if try Self.repairReceiptForAuthenticatedFiles(
        at: publicationURL,
        descriptor: descriptor
      ) {
        return publicationURL
      }
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
    progress(
      SpeechWorkerProgress(
        phase: .downloading,
        completedUnitCount: 0,
        totalUnitCount: Int64(descriptor.approximateDownloadByteCount)
      )
    )
    do {
      _ = try await client.downloadSnapshot(
        of: repository,
        kind: .model,
        to: stagingURL,
        revision: descriptor.revision,
        matching: descriptor.files.map(\.path),
        localFilesOnly: false,
        maxConcurrentDownloads: 4,
        progressHandler: { hubProgress in
          let total = max(hubProgress.totalUnitCount, 1)
          progress(
            SpeechWorkerProgress(
              phase: .downloading,
              completedUnitCount: min(max(hubProgress.completedUnitCount, 0), total),
              totalUnitCount: total
            )
          )
        }
      )
    } catch {
      throw MLXAudioSwiftRuntimeError.modelUnavailable(descriptor.id.rawValue)
    }

    try Self.receiptData(for: descriptor).write(
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

  static func removeAbandonedEntries(
    in publicationParentURL: URL,
    for modelID: MLXAudioModelID
  ) throws {
    let prefixes = [
      ".\(modelID.rawValue).",
    ]
    let suffixes = [".partial", ".replaced"]
    let entries = try FileManager.default.contentsOfDirectory(
      at: publicationParentURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: []
    )
    for entry in entries {
      let name = entry.lastPathComponent
      guard prefixes.contains(where: name.hasPrefix),
        suffixes.contains(where: name.hasSuffix)
      else {
        continue
      }
      try FileManager.default.removeItem(at: entry)
    }
  }

  static func validatePublishedModel(
    at directory: URL,
    descriptor: MLXAudioModelDescriptor,
    verifyDigests: Bool = true
  ) throws -> Bool {
    guard isRegularDirectory(directory) else {
      return false
    }
    let receiptURL = directory.appendingPathComponent(receiptFileName)
    let receiptValues = try? receiptURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    )
    guard receiptValues?.isRegularFile == true,
      receiptValues?.isSymbolicLink != true,
      let receiptSize = receiptValues?.fileSize,
      receiptSize > 0,
      receiptSize <= 32 * 1_024
    else {
      return false
    }
    guard let receipt = try? JSONDecoder().decode(
      MLXAudioSwiftModelReceipt.self,
      from: Data(contentsOf: receiptURL)
    ), receipt == Self.receipt(for: descriptor)
    else {
      return false
    }
    return try validateFileInventory(
      at: directory,
      descriptor: descriptor,
      verifyDigests: verifyDigests
    )
  }

  static func receiptData(
    for descriptor: MLXAudioModelDescriptor
  ) throws -> Data {
    try JSONEncoder().encode(receipt(for: descriptor))
  }

  static func repairReceiptForAuthenticatedFiles(
    at directory: URL,
    descriptor: MLXAudioModelDescriptor
  ) throws -> Bool {
    guard try validateFileInventory(
      at: directory,
      descriptor: descriptor,
      verifyDigests: true
    ) else {
      return false
    }
    try receiptData(for: descriptor).write(
      to: directory.appendingPathComponent(receiptFileName),
      options: .atomic
    )
    return try validatePublishedModel(
      at: directory,
      descriptor: descriptor,
      verifyDigests: false
    )
  }

  static func removeGeneratedFiles(at directory: URL) throws {
    guard isRegularDirectory(directory) else { return }
    let generatedNames = Set(generatedFileNames)
    let entries = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: []
    )
    for entry in entries where generatedNames.contains(entry.lastPathComponent) {
      let values = try entry.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
      )
      guard values.isRegularFile == true || values.isSymbolicLink == true else {
        continue
      }
      try FileManager.default.removeItem(at: entry)
    }
  }

  private static func receipt(
    for descriptor: MLXAudioModelDescriptor
  ) -> MLXAudioSwiftModelReceipt {
    MLXAudioSwiftModelReceipt(
      schemaVersion: 2,
      modelID: descriptor.id.rawValue,
      repository: descriptor.repository,
      revision: descriptor.revision,
      files: descriptor.files
    )
  }

  private static func validateFileInventory(
    at directory: URL,
    descriptor: MLXAudioModelDescriptor,
    verifyDigests: Bool
  ) throws -> Bool {
    guard isRegularDirectory(directory) else { return false }
    let fileNames = descriptor.files.map(\.path)
    guard
      !fileNames.isEmpty,
      Set(fileNames).count == fileNames.count,
      fileNames.allSatisfy({
        !$0.isEmpty
          && !$0.contains("/")
          && !$0.contains("\\")
          && $0 != receiptFileName
          && !generatedFileNames.contains($0)
      })
    else {
      return false
    }

    let entries = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: []
    )
    let expectedNames = Set(fileNames + [receiptFileName])
    guard entries.count == expectedNames.count,
      Set(entries.map(\.lastPathComponent)) == expectedNames
    else {
      return false
    }

    for file in descriptor.files {
      let fileURL = directory.appendingPathComponent(file.path)
      let values = try fileURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
      )
      guard
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        let fileSize = values.fileSize,
        fileSize >= 0,
        UInt64(fileSize) == file.byteCount
      else {
        return false
      }
      if verifyDigests,
        try sha256(fileURL) != file.sha256.lowercased()
      {
        return false
      }
    }

    let receiptValues = try directory.appendingPathComponent(receiptFileName)
      .resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
      )
    return receiptValues.isRegularFile == true
      && receiptValues.isSymbolicLink != true
      && (receiptValues.fileSize ?? 0) > 0
      && (receiptValues.fileSize ?? 0) <= 32 * 1_024
  }

  private static func isRegularDirectory(_ directory: URL) -> Bool {
    let values = try? directory.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    )
    return values?.isDirectory == true && values?.isSymbolicLink != true
  }

  private static func sha256(_ fileURL: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
