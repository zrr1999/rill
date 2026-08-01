import Foundation
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioTTS
import RillCore
import RillProviders

struct MLXAudioSwiftTTSOutput: Sendable, Equatable {
  let audioFileURL: URL
  let sampleRate: Double
  let channelCount: Int
  let durationSeconds: Double
}

protocol MLXAudioSwiftTTSInferenceEngine: Sendable {
  func prepareTTS(
    modelID: String,
    downloadIfNeeded: Bool,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void
  ) async throws -> String

  func synthesize(
    payload: SpeechWorkerSynthesisPayload
  ) async throws -> MLXAudioSwiftTTSOutput

  func releaseTTS(modelID: String) async throws
}

actor MLXAudioSwiftQwenTTSEngine: MLXAudioSwiftTTSInferenceEngine {
  private struct LoadedModel {
    let id: SpeechSynthesisModelID
    let model: Qwen3TTSModel
  }

  private let store: MLXAudioSwiftTTSModelStore
  private var loadedModel: LoadedModel?

  init(store: MLXAudioSwiftTTSModelStore = .init()) {
    self.store = store
  }

  func prepareTTS(
    modelID: String,
    downloadIfNeeded: Bool,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void
  ) async throws -> String {
    #if !arch(arm64)
      throw MLXAudioSwiftRuntimeError.architectureUnsupported
    #else
      guard
        let id = SpeechSynthesisModelID(rawValue: modelID),
        SpeechSynthesisModelCatalog.supportedModelIdentifiers.contains(id.rawValue)
      else {
        throw MLXAudioSwiftRuntimeError.unsupportedModel(modelID)
      }
      if loadedModel?.id == id {
        return id.rawValue
      }
      if loadedModel != nil {
        loadedModel = nil
        Memory.clearCache()
      }
      let descriptor = SpeechSynthesisModelCatalog.descriptor(for: id)
      let modelDirectory = try await store.modelDirectory(
        descriptor: descriptor,
        downloadIfNeeded: downloadIfNeeded,
        progress: progress
      )
      progress(.init(phase: .loading, completedUnitCount: 0, totalUnitCount: 1))
      let model: Qwen3TTSModel
      do {
        model = try await Qwen3TTSModel.fromModelDirectory(modelDirectory)
      } catch {
        throw MLXAudioSwiftRuntimeError.modelLoadFailed
      }
      loadedModel = LoadedModel(id: id, model: model)
      progress(.init(phase: .loading, completedUnitCount: 1, totalUnitCount: 1))
      return id.rawValue
    #endif
  }

  func synthesize(
    payload: SpeechWorkerSynthesisPayload
  ) async throws -> MLXAudioSwiftTTSOutput {
    _ = try await prepareTTS(
      modelID: payload.modelID,
      downloadIfNeeded: payload.downloadIfNeeded,
      progress: { _ in }
    )
    guard let loadedModel else {
      throw MLXAudioSwiftRuntimeError.modelLoadFailed
    }
    guard
      let voice = Qwen3TTSVoice(rawValue: payload.voice),
      SpeechSynthesisRequest(
        runID: payload.runID,
        text: payload.text,
        provider: .qwen3,
        voice: voice.rawValue,
        language: payload.language
      ).isValid
    else {
      throw MLXAudioSwiftRuntimeError.invalidText
    }
    let language = Self.resolvedLanguage(payload.language, text: payload.text)
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-speech-\(payload.runID.uuidString.lowercased())-\(UUID().uuidString.lowercased()).wav"
    )
    do {
      let audio = try await loadedModel.model.generate(
        text: payload.text,
        voice: voice.rawValue,
        refAudio: nil,
        refText: nil,
        language: language,
        generationParameters: loadedModel.model.defaultGenerationParameters
      )
      try Task.checkCancellation()
      let samples = audio.asArray(Float.self)
      guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else {
        throw MLXAudioSwiftRuntimeError.synthesisFailed
      }
      try AudioUtils.writeWavFile(
        samples: samples,
        sampleRate: loadedModel.model.sampleRate,
        fileURL: outputURL
      )
      return MLXAudioSwiftTTSOutput(
        audioFileURL: outputURL,
        sampleRate: Double(loadedModel.model.sampleRate),
        channelCount: 1,
        durationSeconds: Double(samples.count) / Double(loadedModel.model.sampleRate)
      )
    } catch is CancellationError {
      try? FileManager.default.removeItem(at: outputURL)
      throw CancellationError()
    } catch {
      try? FileManager.default.removeItem(at: outputURL)
      if let runtimeError = error as? MLXAudioSwiftRuntimeError {
        throw runtimeError
      }
      throw MLXAudioSwiftRuntimeError.synthesisFailed
    }
  }

  func releaseTTS(modelID: String) async throws {
    guard
      SpeechSynthesisModelCatalog.supportedModelIdentifiers.contains(modelID)
    else {
      throw MLXAudioSwiftRuntimeError.unsupportedModel(modelID)
    }
    loadedModel = nil
    Memory.clearCache()
  }

  private static func resolvedLanguage(_ language: String?, text: String) -> String {
    switch language?.lowercased() {
    case "zh", "zh-cn", "zh-hans", "cmn":
      return "Chinese"
    case "en", "en-us", "en-gb":
      return "English"
    case "ja", "ja-jp":
      return "Japanese"
    case "ko", "ko-kr":
      return "Korean"
    case let value? where !value.isEmpty && value != "auto":
      return value
    default:
      return text.unicodeScalars.contains(where: {
        (0x3400...0x4DBF).contains($0.value)
          || (0x4E00...0x9FFF).contains($0.value)
      }) ? "Chinese" : "English"
    }
  }
}

struct MLXAudioSwiftTTSModelStore: Sendable {
  let modelRootURL: URL
  let hubCacheRootURL: URL

  init(
    modelRootURL: URL = SpeechSynthesisModelInventory.defaultModelRootURL(),
    hubCacheRootURL: URL = Self.defaultHubCacheRootURL()
  ) {
    self.modelRootURL = modelRootURL
    self.hubCacheRootURL = hubCacheRootURL
  }

  func installedModelIdentifiers(
    descriptors: [SpeechSynthesisModelDescriptor]
  ) -> Set<String> {
    SpeechSynthesisModelInventory.installedModelIdentifiers(
      descriptors: descriptors,
      modelRootURL: modelRootURL
    )
  }

  func modelDirectory(
    descriptor: SpeechSynthesisModelDescriptor,
    downloadIfNeeded: Bool,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void
  ) async throws -> URL {
    let parent = modelRootURL.appendingPathComponent("tts", isDirectory: true)
    let publicationURL = SpeechSynthesisModelInventory.publicationURL(
      for: descriptor,
      modelRootURL: modelRootURL
    )
    if FileManager.default.fileExists(atPath: parent.path) {
      try Self.preparePrivateDirectory(parent)
      try Self.removeAbandonedEntries(
        in: parent,
        for: descriptor.id
      )
    }
    if try SpeechSynthesisModelInventory.validatePublication(
      publicationURL,
      descriptor: descriptor,
      verifyDigests: false
    ) {
      return publicationURL
    }
    guard downloadIfNeeded else {
      throw MLXAudioSwiftRuntimeError.modelUnavailable(descriptor.id.rawValue)
    }

    try Self.preparePrivateDirectory(parent)
    try Self.preparePrivateDirectory(hubCacheRootURL)
    let stagingURL = parent.appendingPathComponent(
      ".\(descriptor.id.rawValue).\(UUID().uuidString.lowercased()).partial",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: stagingURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    defer { try? FileManager.default.removeItem(at: stagingURL) }

    guard let repository = Repo.ID(rawValue: descriptor.repository) else {
      throw MLXAudioSwiftRuntimeError.invalidModelStore
    }
    let sessionConfiguration = URLSessionConfiguration.default
    sessionConfiguration.waitsForConnectivity = true
    sessionConfiguration.timeoutIntervalForRequest = 120
    sessionConfiguration.timeoutIntervalForResource = 3_600
    let client = HubClient(
      session: URLSession(configuration: sessionConfiguration),
      cache: HubCache(cacheDirectory: hubCacheRootURL)
    )
    progress(
      .init(
        phase: .downloading,
        completedUnitCount: 0,
        totalUnitCount: Int64(descriptor.approximateDownloadByteCount)
      )
    )
    var lastDownloadError: Error?
    for attempt in 1...3 {
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
              .init(
                phase: .downloading,
                completedUnitCount: min(max(hubProgress.completedUnitCount, 0), total),
                totalUnitCount: total
              )
            )
          }
        )
        lastDownloadError = nil
        break
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        lastDownloadError = error
        guard attempt < 3 else { break }
        try await Task.sleep(for: .seconds(attempt * 2))
      }
    }
    if lastDownloadError != nil {
      throw MLXAudioSwiftRuntimeError.modelUnavailable(descriptor.id.rawValue)
    }

    let receiptData = try SpeechSynthesisModelInventory.receiptData(
      for: descriptor
    )
    try receiptData.write(
      to: stagingURL.appendingPathComponent(
        SpeechSynthesisModelInventory.receiptFileName
      ),
      options: .atomic
    )
    guard try SpeechSynthesisModelInventory.validatePublication(
      stagingURL,
      descriptor: descriptor,
      verifyDigests: true
    ) else {
      throw MLXAudioSwiftRuntimeError.invalidModelStore
    }
    if FileManager.default.fileExists(atPath: publicationURL.path) {
      try FileManager.default.removeItem(at: publicationURL)
    }
    try FileManager.default.moveItem(at: stagingURL, to: publicationURL)
    return publicationURL
  }

  static func removeAbandonedEntries(
    in parent: URL,
    for modelID: SpeechSynthesisModelID
  ) throws {
    let prefix = ".\(modelID.rawValue)."
    let entries = try FileManager.default.contentsOfDirectory(
      at: parent,
      includingPropertiesForKeys: nil,
      options: []
    )
    for entry in entries {
      let name = entry.lastPathComponent
      guard name.hasPrefix(prefix), name.hasSuffix(".partial") else {
        continue
      }
      try FileManager.default.removeItem(at: entry)
    }
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

  private static func defaultHubCacheRootURL(
    fileManager: FileManager = .default
  ) -> URL {
    let caches =
      fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Caches",
        isDirectory: true
      )
    return caches.appendingPathComponent(
      "Rill/huggingface/hub",
      isDirectory: true
    )
  }
}
