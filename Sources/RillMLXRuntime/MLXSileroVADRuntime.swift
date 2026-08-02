import CryptoKit
import Foundation
import HuggingFace
@preconcurrency import MLX
import MLXAudioVAD
@preconcurrency import MLXNN
import RillProviders

struct MLXSileroVADObservation: Sendable, Equatable {
  let activity: SpeechWorkerVADActivity
  let transition: Transition?

  enum Transition: Sendable, Equatable {
    case speechStarted
    case speechEnded
  }
}

/// Owns the pinned Silero-v6 model and its recurrent state inside the ASR
/// worker. MLX arrays never leave this actor.
actor MLXSileroVADRuntime {
  static let modelID = MLXSileroVADConstants.modelID
  static let chunkSampleCount = MLXSileroVADConstants.chunkSampleCount

  private let store: MLXSileroVADModelStore
  private var model: SileroVAD?
  private struct SessionState {
    var streamingState: SileroVADStreamingState?
    var pendingSamples: [Float] = []
    var processedSampleCount: UInt64 = 0
    var receivedSampleCount: UInt64 = 0
    var speechIsActive = false
  }
  private var sessions: [UUID: SessionState] = [:]

  init(store: MLXSileroVADModelStore = .init()) {
    self.store = store
  }

  func start(sessionID: UUID, downloadIfNeeded: Bool) async throws {
    #if !arch(arm64)
      throw MLXAudioSwiftRuntimeError.architectureUnsupported
    #else
      if model == nil {
        let directory = try await store.modelDirectory(
          downloadIfNeeded: downloadIfNeeded
        )
        // MLX's CPU backend needs JIT execution that Rill's hardened helper
        // intentionally does not authorize. Use the signed Metal runtime and
        // retain the helper's least-privilege entitlement boundary.
        model = try Stream.withNewDefaultStream(device: .gpu) {
          try Self.loadPinned16kModel(from: directory)
        }
      }
      guard let model else { throw MLXAudioSwiftRuntimeError.modelLoadFailed }
      let initialState = try Stream.withNewDefaultStream(device: .gpu) {
        try model.initialState(sampleRate: 16_000)
      }
      sessions[sessionID] = SessionState(streamingState: initialState)
    #endif
  }

  func accept(
    sessionID: UUID,
    samples: [Float]
  ) throws -> [MLXSileroVADObservation] {
    guard let model, var session = sessions[sessionID] else {
      throw MLXAudioSwiftRuntimeError.modelLoadFailed
    }
    guard samples.allSatisfy(\.isFinite) else {
      throw MLXAudioSwiftRuntimeError.invalidAudio
    }
    session.receivedSampleCount += UInt64(samples.count)
    session.pendingSamples.append(contentsOf: samples)
    var observations: [MLXSileroVADObservation] = []
    while session.pendingSamples.count >= Self.chunkSampleCount {
      let chunk = Array(session.pendingSamples.prefix(Self.chunkSampleCount))
      session.pendingSamples.removeFirst(Self.chunkSampleCount)
      session.processedSampleCount += UInt64(Self.chunkSampleCount)
      observations.append(try infer(chunk: chunk, model: model, session: &session))
    }
    sessions[sessionID] = session
    return observations
  }

  func finish(sessionID: UUID) throws -> [MLXSileroVADObservation] {
    guard let model, var session = sessions.removeValue(forKey: sessionID) else {
      return []
    }
    var observations: [MLXSileroVADObservation] = []
    if !session.pendingSamples.isEmpty {
      let actualSampleOffset = session.receivedSampleCount
      let paddingCount = Self.chunkSampleCount - session.pendingSamples.count
      let chunk = session.pendingSamples + Array(repeating: 0, count: paddingCount)
      session.pendingSamples.removeAll(keepingCapacity: false)
      session.processedSampleCount += UInt64(Self.chunkSampleCount)
      var observation = try infer(chunk: chunk, model: model, session: &session)
      observation = MLXSileroVADObservation(
        activity: SpeechWorkerVADActivity(
          probability: observation.activity.probability,
          isSpeech: observation.activity.isSpeech,
          sampleOffset: actualSampleOffset
        ),
        transition: observation.transition
      )
      observations.append(observation)
    }
    return observations
  }

  func cancel(sessionID: UUID) {
    sessions.removeValue(forKey: sessionID)
  }

  private func infer(
    chunk: [Float],
    model: SileroVAD,
    session: inout SessionState
  ) throws -> MLXSileroVADObservation {
    let result: (Float, SileroVADStreamingState) = try Stream.withNewDefaultStream(
      device: .gpu
    ) {
      let (probability, nextState) = try model.feed(
        chunk: MLXArray(chunk),
        state: session.streamingState,
        sampleRate: 16_000
      )
      try checkedEval(probability, nextState.context)
      if let lstmState = nextState.lstmState {
        try checkedEval(lstmState)
      }
      return (probability.item(Float.self), nextState)
    }
    session.streamingState = result.1
    let probability = min(max(result.0, 0), 1)
    let nextSpeechState = session.speechIsActive ? probability >= 0.35 : probability >= 0.5
    let transition: MLXSileroVADObservation.Transition?
    if nextSpeechState == session.speechIsActive {
      transition = nil
    } else {
      session.speechIsActive = nextSpeechState
      transition = nextSpeechState ? .speechStarted : .speechEnded
    }
    return MLXSileroVADObservation(
      activity: SpeechWorkerVADActivity(
        probability: probability,
        isSpeech: nextSpeechState,
        sampleOffset: session.processedSampleCount
      ),
      transition: transition
    )
  }

  /// The pinned v6 publication intentionally contains only the 16 kHz branch
  /// used by the v5 wire format. mlx-audio-swift 0.1.3's convenience loader
  /// verifies the unused 8 kHz branch too, so a valid upstream publication is
  /// rejected as incomplete. Verify every supplied key against the model while
  /// allowing that unused branch to remain uninitialized.
  private static func loadPinned16kModel(
    from directory: URL
  ) throws -> SileroVAD {
    let config = try JSONDecoder().decode(
      SileroVADConfig.self,
      from: Data(contentsOf: directory.appendingPathComponent("config.json"))
    )
    let model = SileroVAD(config)
    let weightFiles = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "safetensors" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var weights: [String: MLXArray] = [:]
    for file in weightFiles {
      for (key, value) in try MLX.loadArrays(url: file) {
        weights[key] = value
      }
    }
    let parameters = ModuleParameters.unflattened(
      SileroVAD.sanitize(weights: weights)
    )
    try model.update(parameters: parameters, verify: .noUnusedKeys)
    try checkedEval(model)
    return model
  }
}

struct MLXSileroVADModelStore: Sendable {
  private struct FileDescriptor: Codable, Sendable, Equatable {
    let path: String
    let byteCount: UInt64
    let sha256: String
  }

  private struct Receipt: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let repository: String
    let revision: String
    let files: [FileDescriptor]
  }

  private static let repository = "mlx-community/silero-vad-v6"
  private static let revision = "2ebf4a5e10726a2e78ddd4d70eedfb6f1c33eb06"
  private static let receiptFileName = ".rill-silero-vad-model.json"
  private static let files = [
    FileDescriptor(
      path: "config.json",
      byteCount: 463,
      sha256: "9fe1befb9692a0d4135adadc33f8075ef6d350bd2391b88d750f2c233f97fa0b"
    ),
    FileDescriptor(
      path: "model.safetensors",
      byteCount: 1_237_860,
      sha256: "65b6c5f0293cbc44d109e58bef78b474d9c65dedbee814cf0b90ef5f0d9150ff"
    ),
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

  func modelDirectory(downloadIfNeeded: Bool) async throws -> URL {
    let publicationParent = modelRootURL.appendingPathComponent("vad", isDirectory: true)
    let publication = publicationParent.appendingPathComponent(
      Self.repository.replacingOccurrences(of: "/", with: "_"),
      isDirectory: true
    )
    if try Self.validate(publication) {
      return publication
    }
    guard downloadIfNeeded else {
      throw MLXAudioSwiftRuntimeError.modelUnavailable(Self.repository)
    }

    try Self.preparePrivateDirectory(modelRootURL)
    try Self.preparePrivateDirectory(publicationParent)
    try Self.preparePrivateDirectory(hubCacheRootURL)
    let staging = publicationParent.appendingPathComponent(
      ".silero-vad-v6.\(UUID().uuidString.lowercased()).partial",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: staging,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    var removeStaging = true
    defer {
      if removeStaging { try? FileManager.default.removeItem(at: staging) }
    }

    guard let repositoryID = Repo.ID(rawValue: Self.repository) else {
      throw MLXAudioSwiftRuntimeError.invalidModelStore
    }
    do {
      _ = try await HubClient(cache: HubCache(cacheDirectory: hubCacheRootURL))
        .downloadSnapshot(
          of: repositoryID,
          kind: .model,
          to: staging,
          revision: Self.revision,
          matching: Self.files.map(\.path),
          localFilesOnly: false,
          maxConcurrentDownloads: 2
        )
    } catch {
      throw MLXAudioSwiftRuntimeError.modelUnavailable(Self.repository)
    }
    try JSONEncoder().encode(Self.expectedReceipt).write(
      to: staging.appendingPathComponent(Self.receiptFileName),
      options: .atomic
    )
    guard try Self.validate(staging) else {
      throw MLXAudioSwiftRuntimeError.invalidModelStore
    }

    let quarantine = publicationParent.appendingPathComponent(
      ".silero-vad-v6.\(UUID().uuidString.lowercased()).replaced",
      isDirectory: true
    )
    if FileManager.default.fileExists(atPath: publication.path) {
      try FileManager.default.moveItem(at: publication, to: quarantine)
    }
    do {
      try FileManager.default.moveItem(at: staging, to: publication)
      removeStaging = false
      try? FileManager.default.removeItem(at: quarantine)
    } catch {
      if FileManager.default.fileExists(atPath: quarantine.path),
        !FileManager.default.fileExists(atPath: publication.path)
      {
        try? FileManager.default.moveItem(at: quarantine, to: publication)
      }
      throw MLXAudioSwiftRuntimeError.invalidModelStore
    }
    return publication
  }

  private static var expectedReceipt: Receipt {
    Receipt(
      schemaVersion: 1,
      repository: repository,
      revision: revision,
      files: files
    )
  }

  private static func validate(_ directory: URL) throws -> Bool {
    let directoryValues = try? directory.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    )
    guard directoryValues?.isDirectory == true,
      directoryValues?.isSymbolicLink != true
    else { return false }
    let entries = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    let expectedNames = Set(files.map(\.path) + [receiptFileName])
    guard entries.count == expectedNames.count,
      Set(entries.map(\.lastPathComponent)) == expectedNames,
      let receipt = try? JSONDecoder().decode(
        Receipt.self,
        from: Data(contentsOf: directory.appendingPathComponent(receiptFileName))
      ),
      receipt == expectedReceipt
    else { return false }
    for file in files {
      let url = directory.appendingPathComponent(file.path)
      let values = try url.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
      )
      guard values.isRegularFile == true,
        values.isSymbolicLink != true,
        UInt64(values.fileSize ?? -1) == file.byteCount,
        try sha256(url) == file.sha256
      else { return false }
    }
    return true
  }

  private static func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
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
    let root = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support",
      isDirectory: true
    )
    return root.appendingPathComponent("Rill/Models/mlx-audio-swift", isDirectory: true)
  }

  private static func defaultHubCacheRootURL(
    fileManager: FileManager = .default
  ) -> URL {
    let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Caches",
        isDirectory: true
      )
    return root.appendingPathComponent("Rill/huggingface/hub", isDirectory: true)
  }
}
