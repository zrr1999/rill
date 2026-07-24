import AVFoundation
import Foundation
import RillCore
import RillSherpaRuntime

/// Offline speech recognition backed by the release-pinned sherpa-onnx runtime.
public struct SherpaOnnxRecognizer: SpeechRecognizer {
  public static let defaultModelDirectoryURL: URL = {
    let fileManager = FileManager.default
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
      .appendingPathComponent("sherpa-onnx", isDirectory: true)
  }()

  public static let workflowModelOverrideMetadataKey =
    WorkflowMetadataKey.localSpeechModelOverride
  public static let maximumAudioDurationSeconds =
    Int(LocalSpeechCaptureLimits.maximumRequestedDurationSeconds)
  public static let maximumThreadCount = 16
  static let targetSampleRate = 16_000
  static let maximumAcceptedAudioDurationSeconds =
    LocalSpeechCaptureLimits.maximumAcceptedDurationSeconds
  static let maximumAudioSampleCount = LocalSpeechCaptureLimits.maximumAcceptedFrameCount
  static let maximumQwenHotwordCount = 16
  static let maximumQwenHotwordUTF8ByteCount = 48
  static let maximumQwenHotwordScalarCount = 128
  static let qwenPromptScaffoldTokenCount = 15
  static let maximumQwenHotwordTokenCount =
    maximumQwenHotwordUTF8ByteCount + maximumQwenHotwordCount - 1
  static let maximumQwenAudioTokenCount = conservativeQwenAudioTokenCount(
    sampleCount: maximumAudioSampleCount
  )
  static let maximumQwenInputContextTokenCount =
    qwenPromptScaffoldTokenCount + maximumQwenAudioTokenCount + maximumQwenHotwordTokenCount
  static let minimumQwenOutputTokenCapacity =
    SherpaQwen3ASRConfiguration.defaultMaximumTotalLength
    - maximumQwenInputContextTokenCount

  public enum RecognizerError: Error, LocalizedError, Equatable, Sendable {
    case missingCapturedAudio
    case fileBackedAudioRequired
    case unsupportedModelIdentifier(String)
    case invalidThreadCount(Int)
    case modelNotInstalled(String)
    case invalidAudioFile
    case emptyAudio
    case audioTooLong(maximumDurationSeconds: Int)
    case nonFiniteAudioSample(index: Int)
    case audioConversionFailed

    public var errorDescription: String? {
      switch self {
      case .missingCapturedAudio:
        "Local speech recognition requires captured audio."
      case .fileBackedAudioRequired:
        "Local speech recognition requires a file-backed audio capture."
      case .unsupportedModelIdentifier(let identifier):
        "The local speech model is not supported: \(identifier)."
      case .invalidThreadCount(let count):
        "The local speech thread count must be in 1...\(SherpaOnnxRecognizer.maximumThreadCount) (received \(count))."
      case .modelNotInstalled(let identifier):
        "The local speech model is not installed and downloads are disabled: \(identifier)."
      case .invalidAudioFile:
        "The captured audio file has an invalid format."
      case .emptyAudio:
        "The captured audio file is empty."
      case .audioTooLong(let maximumDurationSeconds):
        "The captured audio exceeds the \(maximumDurationSeconds)-second local recognition limit."
      case .nonFiniteAudioSample:
        "The captured audio contains a non-finite sample."
      case .audioConversionFailed:
        "The captured audio could not be converted for local recognition."
      }
    }
  }

  public struct Configuration: Equatable, Sendable {
    public var modelIdentifier: String
    public var language: String?
    public var downloadIfNeeded: Bool
    public var prewarm: Bool
    public var threadCount: Int

    public init(
      modelIdentifier: String = SherpaOnnxModelCatalog.defaultModelID.rawValue,
      language: String? = nil,
      downloadIfNeeded: Bool = true,
      prewarm: Bool = false,
      threadCount: Int = 2
    ) {
      self.modelIdentifier = modelIdentifier
      self.language = language
      self.downloadIfNeeded = downloadIfNeeded
      self.prewarm = prewarm
      self.threadCount = threadCount
    }
  }

  public let id: String
  public let capabilities = SpeechRecognizerCapabilities(
    supportedHintKinds: [.keyterm],
    maximumAudioDurationSeconds: Double(maximumAudioDurationSeconds)
  )

  private let defaultConfiguration: Configuration
  private let configurationProvider: (@Sendable () async throws -> Configuration)?
  private let allowedModelIdentifiers: Set<String>
  private let modelDirectoryInstaller: any SherpaOnnxModelDirectoryInstalling
  private let audioSampleLoader: any SherpaOnnxAudioSampleLoading
  private let runtime: SherpaOnnxRecognizerRuntime

  public init(
    id: String = "sherpa-onnx.local",
    configuration: Configuration = Configuration(),
    configurationProvider: (@Sendable () async throws -> Configuration)? = nil,
    modelDirectoryURL: URL = defaultModelDirectoryURL
  ) {
    let installer = SherpaOnnxModelInstaller(destinationRootURL: modelDirectoryURL)
    self.init(
      id: id,
      configuration: configuration,
      configurationProvider: configurationProvider,
      allowedModelIdentifiers: SherpaOnnxModelCatalog.distributableModelIdentifiers,
      modelDirectoryInstaller: SherpaOnnxLiveModelDirectoryInstaller(installer: installer),
      audioSampleLoader: SherpaOnnxAVAudioSampleLoader(),
      runtime: SherpaOnnxRecognizerRuntime()
    )
  }

  init(
    id: String = "sherpa-onnx.local",
    configuration: Configuration = Configuration(),
    configurationProvider: (@Sendable () async throws -> Configuration)? = nil,
    allowedModelIdentifiers: Set<String> = SherpaOnnxModelCatalog.offlineKnownModelIdentifiers,
    modelDirectoryInstaller: any SherpaOnnxModelDirectoryInstalling,
    audioSampleLoader: any SherpaOnnxAudioSampleLoading,
    runtime: SherpaOnnxRecognizerRuntime
  ) {
    self.id = id
    self.defaultConfiguration = configuration
    self.configurationProvider = configurationProvider
    self.allowedModelIdentifiers = allowedModelIdentifiers
    self.modelDirectoryInstaller = modelDirectoryInstaller
    self.audioSampleLoader = audioSampleLoader
    self.runtime = runtime
  }

  public func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
    try Task.checkCancellation()
    guard let capturedAudio = request.capturedAudio else {
      throw RecognizerError.missingCapturedAudio
    }
    guard let audioFileURL = capturedAudio.fileURL else {
      throw RecognizerError.fileBackedAudioRequired
    }
    try Self.validateCapturedAudioDuration(capturedAudio.durationSeconds)

    let configuration = Self.applyingWorkflowModelOverride(
      to: try await resolvedConfiguration(),
      workflow: request.workflow
    )
    let modelID = try resolveModelID(configuration.modelIdentifier)
    try Self.validateThreadCount(configuration.threadCount)
    let runtimeLease = try runtime.makeRetentionLease()

    let samples = try Self.validatedSamples(
      audioSampleLoader.loadSamples(from: audioFileURL)
    )
    try Task.checkCancellation()
    let descriptor = SherpaOnnxModelCatalog.descriptor(for: modelID)
    let modelDirectory = try await modelDirectoryInstaller.modelDirectory(
      for: descriptor,
      downloadIfNeeded: configuration.downloadIfNeeded,
      progressCallback: nil
    )
    try Task.checkCancellation()
    let language = Self.resolvedLanguage(
      requestLanguage: request.options.language,
      workflowLanguage: request.workflow.metadata[WorkflowMetadataKey.languageOverride],
      configurationLanguage: configuration.language
    )
    let runtimeConfiguration = Self.runtimeConfiguration(
      modelID: modelID,
      modelDirectory: modelDirectory,
      language: language,
      keyterms: request.options.hints.keyterms,
      threadCount: configuration.threadCount
    )

    let startedAt = ContinuousClock.now
    let decoded = try await runtime.transcribe(
      configuration: runtimeConfiguration,
      samples: samples,
      sampleRate: Self.targetSampleRate,
      lease: runtimeLease
    )
    let processingDuration = startedAt.duration(to: .now)
    let durationMillis = max(
      0,
      Int(processingDuration.components.seconds * 1_000)
        + Int(processingDuration.components.attoseconds / 1_000_000_000_000_000)
    )
    let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    var metadata = [
      "provider": id,
      "provider.kind": "sherpa-onnx",
      "provider.model": modelID.rawValue,
    ]
    if let detectedLanguage = decoded.language.trimmedNonEmpty {
      metadata["provider.detected_language"] = detectedLanguage
    }

    return RecognitionResult(
      rawText: text,
      bestText: text,
      metadata: metadata,
      processingDurationMillis: durationMillis
    )
  }

  /// Installs and verifies the configured model. When `prewarm` is enabled,
  /// the native recognizer is also created and retained by the one-entry cache.
  @discardableResult
  public func prepareModel(
    progress: (@Sendable (SherpaOnnxModelInstallationProgress) -> Void)? = nil
  ) async throws -> String {
    try await prepareModel(using: resolvedConfiguration(), progress: progress)
  }

  @discardableResult
  public func prepareModel(
    using configuration: Configuration,
    progress: (@Sendable (SherpaOnnxModelInstallationProgress) -> Void)? = nil
  ) async throws -> String {
    let modelID = try resolveModelID(configuration.modelIdentifier)
    try Self.validateThreadCount(configuration.threadCount)
    let runtimeLease = try configuration.prewarm ? runtime.makeRetentionLease() : nil
    let descriptor = SherpaOnnxModelCatalog.descriptor(for: modelID)
    let modelDirectory = try await modelDirectoryInstaller.modelDirectory(
      for: descriptor,
      downloadIfNeeded: configuration.downloadIfNeeded,
      progressCallback: progress
    )
    if configuration.prewarm {
      let runtimeConfiguration = Self.runtimeConfiguration(
        modelID: modelID,
        modelDirectory: modelDirectory,
        language: Self.normalizedLanguage(configuration.language),
        keyterms: [],
        threadCount: configuration.threadCount
      )
      guard let runtimeLease else { throw CancellationError() }
      try await runtime.prepare(
        configuration: runtimeConfiguration,
        lease: runtimeLease
      )
    }
    return modelID.rawValue
  }

  /// Updates whether new local recognition work may retain or use a native model.
  ///
  /// Disabling is synchronous at the intent boundary. The native cache is then
  /// released on the runtime actor, after any decode already executing there has
  /// returned. A preparation that resumes later carries an obsolete generation
  /// and cannot repopulate the cache.
  public func setRuntimeEnabled(_ isEnabled: Bool) {
    let generation = runtime.setRetentionEnabled(isEnabled)
    guard !isEnabled else { return }
    Task {
      await runtime.releaseCachedRecognizer(olderThan: generation)
    }
  }

  /// Releases the current native model without disabling local speech.
  /// The next recognition request lazily recreates the exact selected runtime.
  public func releaseLoadedModel() {
    let generation = runtime.invalidateRetentionGeneration()
    Task {
      await runtime.releaseCachedRecognizer(olderThan: generation)
    }
  }

  /// Seals local runtime use and schedules retained-model disposal.
  ///
  /// Application shutdown must not wait behind a native decode that has no
  /// cooperative cancellation API. The runtime actor still serializes disposal
  /// after any active decode, so the native recognizer is never destroyed while
  /// it is in use.
  public func stopRuntime() async {
    let generation = runtime.setRetentionEnabled(false)
    let runtime = self.runtime
    Task {
      await runtime.releaseCachedRecognizer(olderThan: generation)
    }
  }

  private func resolvedConfiguration() async throws -> Configuration {
    if let configurationProvider {
      return try await configurationProvider()
    }
    return defaultConfiguration
  }

  static func applyingWorkflowModelOverride(
    to configuration: Configuration,
    workflow: WorkflowDefinition
  ) -> Configuration {
    var configuration = configuration
    if let override = workflow.metadata[WorkflowMetadataKey.localSpeechModelOverride]?
      .trimmedNonEmpty
    {
      configuration.modelIdentifier = override
    }
    return configuration
  }

  private func resolveModelID(_ rawIdentifier: String) throws -> SherpaOnnxModelID {
    let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard allowedModelIdentifiers.contains(identifier),
      let modelID = SherpaOnnxModelID(rawValue: identifier)
    else {
      throw RecognizerError.unsupportedModelIdentifier(identifier)
    }
    return modelID
  }

  static func validateThreadCount(_ threadCount: Int) throws {
    guard (1...maximumThreadCount).contains(threadCount) else {
      throw RecognizerError.invalidThreadCount(threadCount)
    }
  }

  static func resolvedLanguage(
    requestLanguage: String?,
    workflowLanguage: String?,
    configurationLanguage: String?
  ) -> String? {
    normalizedLanguage(requestLanguage)
      ?? normalizedLanguage(workflowLanguage)
      ?? normalizedLanguage(configurationLanguage)
  }

  private static func normalizedLanguage(_ language: String?) -> String? {
    guard let language = language?.trimmedNonEmpty else { return nil }
    guard
      !language.unicodeScalars.contains(where: { scalar in
        CharacterSet.controlCharacters.contains(scalar)
          || CharacterSet.newlines.contains(scalar)
      })
    else {
      return nil
    }
    return language
  }

  package static func sanitizedQwenHotwords(_ keyterms: [String]) -> [String] {
    var hotwords: [String] = []
    var seen = Set<String>()
    var totalByteCount = 0

    for keyterm in keyterms {
      let candidate = keyterm.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !candidate.isEmpty else { continue }
      guard candidate.unicodeScalars.count <= maximumQwenHotwordScalarCount else { continue }
      guard !candidate.contains(",") else { continue }
      guard
        !candidate.unicodeScalars.contains(where: { scalar in
          CharacterSet.controlCharacters.contains(scalar)
            || CharacterSet.newlines.contains(scalar)
        })
      else {
        continue
      }
      guard seen.insert(candidate).inserted else { continue }

      let byteCount = candidate.utf8.count
      guard totalByteCount + byteCount <= maximumQwenHotwordUTF8ByteCount else { break }
      hotwords.append(candidate)
      totalByteCount += byteCount
      if hotwords.count == maximumQwenHotwordCount { break }
    }
    return hotwords
  }

  static func runtimeConfiguration(
    modelID: SherpaOnnxModelID,
    modelDirectory: URL,
    language: String?,
    keyterms: [String],
    threadCount: Int
  ) -> SherpaOfflineModelConfiguration {
    switch modelID {
    case .qwen3ASR06BInt8:
      .qwen3(
        SherpaQwen3ASRConfiguration(
          convolutionFrontend: modelDirectory.appendingPathComponent("conv_frontend.onnx"),
          encoder: modelDirectory.appendingPathComponent("encoder.int8.onnx"),
          decoder: modelDirectory.appendingPathComponent("decoder.int8.onnx"),
          tokenizerDirectory: modelDirectory.appendingPathComponent(
            "tokenizer",
            isDirectory: true
          ),
          threadCount: threadCount,
          hotwords: sanitizedQwenHotwords(keyterms)
        )
      )
    case .funASRNano08BInt8, .funASRNano08BFP16:
      .funASRNano(
        SherpaFunASRNanoConfiguration(
          encoderAdaptor: modelDirectory.appendingPathComponent(
            "encoder_adaptor.int8.onnx"
          ),
          languageModel: modelDirectory.appendingPathComponent(
            modelID == .funASRNano08BInt8 ? "llm.int8.onnx" : "llm.fp16.onnx"
          ),
          embedding: modelDirectory.appendingPathComponent("embedding.int8.onnx"),
          tokenizerDirectory: modelDirectory.appendingPathComponent(
            "Qwen3-0.6B",
            isDirectory: true
          ),
          language: normalizedLanguage(language) ?? "",
          threadCount: threadCount
        )
      )
    case .omnilingualASRCTCV2300MInt8, .omnilingualASRCTCV21BInt8:
      .omnilingualCTC(
        SherpaOmnilingualCTCConfiguration(
          model: modelDirectory.appendingPathComponent("model.int8.onnx"),
          tokens: modelDirectory.appendingPathComponent("tokens.txt"),
          threadCount: threadCount
        )
      )
    case .cohereTranscribe2BInt8:
      .cohereTranscribe(
        SherpaCohereTranscribeConfiguration(
          encoder: modelDirectory.appendingPathComponent("encoder.int8.onnx"),
          encoderData: modelDirectory.appendingPathComponent("encoder.int8.onnx.data"),
          decoder: modelDirectory.appendingPathComponent("decoder.int8.onnx"),
          tokens: modelDirectory.appendingPathComponent("tokens.txt"),
          language: normalizedLanguage(language) ?? "",
          threadCount: threadCount
        )
      )
    case .senseVoiceSmallInt8:
      .senseVoice(
        SherpaSenseVoiceConfiguration(
          model: modelDirectory.appendingPathComponent("model.int8.onnx"),
          tokens: modelDirectory.appendingPathComponent("tokens.txt"),
          language: normalizedLanguage(language) ?? "",
          threadCount: threadCount
        )
      )
    case .streamingZipformerBilingualPreviewInt8:
      preconditionFailure(
        "The fixed streaming preview model cannot enter the offline final-transcription runtime."
      )
    }
  }

  static func validatedSamples(_ samples: [Float]) throws -> [Float] {
    guard !samples.isEmpty else { throw RecognizerError.emptyAudio }
    guard samples.count <= maximumAudioSampleCount else {
      throw RecognizerError.audioTooLong(
        maximumDurationSeconds: maximumAudioDurationSeconds
      )
    }
    if let index = samples.firstIndex(where: { !$0.isFinite }) {
      throw RecognizerError.nonFiniteAudioSample(index: index)
    }
    guard samples.contains(where: { !(-1...1).contains($0) }) else {
      return samples
    }
    var normalized = samples
    for index in normalized.indices {
      normalized[index] = min(1, max(-1, normalized[index]))
    }
    return normalized
  }

  public static func validateCapturedAudioDuration(_ durationSeconds: Double) throws {
    guard durationSeconds.isFinite, durationSeconds >= 0 else {
      throw RecognizerError.invalidAudioFile
    }
    guard durationSeconds <= maximumAcceptedAudioDurationSeconds else {
      throw RecognizerError.audioTooLong(
        maximumDurationSeconds: maximumAudioDurationSeconds
      )
    }
  }

  static func validateEstimatedAudioSampleCount(_ sampleCount: Double) throws {
    guard sampleCount.isFinite, sampleCount >= 1 else {
      throw RecognizerError.invalidAudioFile
    }
    guard sampleCount <= Double(maximumAudioSampleCount) else {
      throw RecognizerError.audioTooLong(
        maximumDurationSeconds: maximumAudioDurationSeconds
      )
    }
  }

  /// Qwen's encoder emits 13 tokens per complete 100-frame block and one
  /// token per remaining 8 frames. Feature frames are conservatively rounded
  /// up from 10 ms windows so this is an upper bound for the accepted capture.
  static func conservativeQwenAudioTokenCount(sampleCount: Int) -> Int {
    guard sampleCount > 0 else { return 0 }
    let featureFrameCount = (sampleCount + 159) / 160
    let completeBlocks = featureFrameCount / 100
    let remainingFrames = featureFrameCount % 100
    return completeBlocks * 13
      + (remainingFrames == 0 ? 0 : (remainingFrames + 7) / 8)
  }
}

protocol SherpaOnnxModelDirectoryInstalling: Sendable {
  func modelDirectory(
    for descriptor: SherpaOnnxModelDescriptor,
    downloadIfNeeded: Bool,
    progressCallback: (@Sendable (SherpaOnnxModelInstallationProgress) -> Void)?
  ) async throws -> URL
}

private actor SherpaOnnxLiveModelDirectoryInstaller: SherpaOnnxModelDirectoryInstalling {
  private struct CacheEntry {
    let descriptor: SherpaOnnxModelDescriptor
    let modelDirectory: URL
  }

  let installer: SherpaOnnxModelInstaller
  private var cacheEntry: CacheEntry?

  init(installer: SherpaOnnxModelInstaller) {
    self.installer = installer
  }

  func modelDirectory(
    for descriptor: SherpaOnnxModelDescriptor,
    downloadIfNeeded: Bool,
    progressCallback: (@Sendable (SherpaOnnxModelInstallationProgress) -> Void)?
  ) async throws -> URL {
    // Installation performs a full receipt and file-digest verification. Keep
    // that verified directory for the process lifetime so every recognition
    // does not re-hash a model approaching 1 GB. A missing directory still
    // invalidates the one-entry cache and falls through to verification.
    if let cacheEntry,
      cacheEntry.descriptor == descriptor,
      Self.isDirectory(cacheEntry.modelDirectory)
    {
      progressCallback?(
        .init(
          phase: .complete,
          completedByteCount: descriptor.archiveByteCount,
          totalByteCount: descriptor.archiveByteCount
        )
      )
      return cacheEntry.modelDirectory
    }

    let modelDirectory: URL
    if downloadIfNeeded {
      modelDirectory = try await installer.install(
        descriptor,
        progressCallback: progressCallback
      )
    } else {
      guard let installedURL = try await installer.existingInstalledURL(for: descriptor) else {
        throw SherpaOnnxRecognizer.RecognizerError.modelNotInstalled(descriptor.id.rawValue)
      }
      progressCallback?(
        .init(
          phase: .complete,
          completedByteCount: descriptor.archiveByteCount,
          totalByteCount: descriptor.archiveByteCount
        )
      )
      modelDirectory = installedURL
    }
    cacheEntry = CacheEntry(descriptor: descriptor, modelDirectory: modelDirectory)
    return modelDirectory
  }

  private static func isDirectory(_ url: URL) -> Bool {
    var isDirectory = ObjCBool(false)
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}

protocol SherpaOnnxAudioSampleLoading: Sendable {
  func loadSamples(from fileURL: URL) throws -> [Float]
}

struct SherpaOnnxAVAudioSampleLoader: SherpaOnnxAudioSampleLoading {
  func loadSamples(from fileURL: URL) throws -> [Float] {
    try SherpaOnnxAudioFileConverter.loadSamples(from: fileURL)
  }
}

struct SherpaOnnxRuntimeTranscriber: Sendable {
  let transcribe: @Sendable ([Float], Int, [String]) throws -> SherpaOfflineRecognitionResult
}

struct SherpaOnnxRuntimeRetentionLease: Sendable, Equatable {
  let generation: UInt64
}

/// A synchronous intent gate paired with the actor-isolated native cache.
///
/// Settings changes must invalidate an in-flight installation before that
/// installation reaches the actor. Keeping this small lock outside the actor
/// makes that invalidation immediate without making native decoding re-entrant.
private final class SherpaOnnxRuntimeRetention: @unchecked Sendable {
  private let lock = NSLock()
  private var isEnabled = true
  private var generation: UInt64 = 0

  func setEnabled(_ enabled: Bool) -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    guard isEnabled != enabled else { return generation }
    generation &+= 1
    isEnabled = enabled
    return generation
  }

  func invalidateKeepingCurrentPolicy() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    generation &+= 1
    return generation
  }

  func makeLease() throws -> SherpaOnnxRuntimeRetentionLease {
    lock.lock()
    defer { lock.unlock() }
    guard isEnabled else { throw CancellationError() }
    return SherpaOnnxRuntimeRetentionLease(generation: generation)
  }

  func accepts(_ lease: SherpaOnnxRuntimeRetentionLease) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return isEnabled && lease.generation == generation
  }
}

actor SherpaOnnxRecognizerRuntime {
  typealias Factory =
    @Sendable (SherpaOfflineModelConfiguration) throws -> SherpaOnnxRuntimeTranscriber

  private struct CacheEntry {
    let generation: UInt64
    let configuration: SherpaOfflineModelConfiguration
    let transcriber: SherpaOnnxRuntimeTranscriber
  }

  private let factory: Factory
  private nonisolated let retention = SherpaOnnxRuntimeRetention()
  private var cacheEntry: CacheEntry?

  init() {
    self.factory = Self.liveFactory
  }

  init(factory: @escaping Factory) {
    self.factory = factory
  }

  nonisolated func makeRetentionLease() throws -> SherpaOnnxRuntimeRetentionLease {
    try retention.makeLease()
  }

  nonisolated func setRetentionEnabled(_ isEnabled: Bool) -> UInt64 {
    retention.setEnabled(isEnabled)
  }

  nonisolated func invalidateRetentionGeneration() -> UInt64 {
    retention.invalidateKeepingCurrentPolicy()
  }

  func releaseCachedRecognizer(olderThan generation: UInt64) {
    guard let cacheEntry, cacheEntry.generation < generation else { return }
    self.cacheEntry = nil
  }

  func prepare(configuration: SherpaOfflineModelConfiguration) throws {
    _ = try transcriber(for: configuration, lease: makeRetentionLease())
  }

  func prepare(
    configuration: SherpaOfflineModelConfiguration,
    lease: SherpaOnnxRuntimeRetentionLease
  ) throws {
    _ = try transcriber(for: configuration, lease: lease)
  }

  func transcribe(
    configuration: SherpaOfflineModelConfiguration,
    samples: [Float],
    sampleRate: Int
  ) throws -> SherpaOfflineRecognitionResult {
    try transcribe(
      configuration: configuration,
      samples: samples,
      sampleRate: sampleRate,
      lease: makeRetentionLease()
    )
  }

  func transcribe(
    configuration: SherpaOfflineModelConfiguration,
    samples: [Float],
    sampleRate: Int,
    lease: SherpaOnnxRuntimeRetentionLease
  ) throws -> SherpaOfflineRecognitionResult {
    let transcriber = try transcriber(for: configuration, lease: lease)
    guard retention.accepts(lease) else { throw CancellationError() }
    return try transcriber.transcribe(
      samples,
      sampleRate,
      Self.requestHotwords(from: configuration)
    )
  }

  private func transcriber(
    for configuration: SherpaOfflineModelConfiguration,
    lease: SherpaOnnxRuntimeRetentionLease
  ) throws -> SherpaOnnxRuntimeTranscriber {
    guard retention.accepts(lease) else { throw CancellationError() }
    if case .qwen3(let qwen) = configuration {
      try SherpaQwen3ASRConfiguration.validateHotwords(qwen.hotwords)
    }
    let cacheConfiguration = Self.cacheConfiguration(for: configuration)
    if let cacheEntry,
      cacheEntry.generation == lease.generation,
      cacheEntry.configuration == cacheConfiguration
    {
      return cacheEntry.transcriber
    }
    // A Qwen recognizer can retain roughly a gigabyte of model state. Drop the
    // previous model-configuration cache before constructing its replacement.
    // Qwen hotwords are request-scoped and must never enter this cache identity.
    cacheEntry = nil
    let transcriber = try factory(cacheConfiguration)
    guard retention.accepts(lease) else { throw CancellationError() }
    cacheEntry = CacheEntry(
      generation: lease.generation,
      configuration: cacheConfiguration,
      transcriber: transcriber
    )
    return transcriber
  }

  private static func cacheConfiguration(
    for configuration: SherpaOfflineModelConfiguration
  ) -> SherpaOfflineModelConfiguration {
    guard case .qwen3(var qwen) = configuration else { return configuration }
    qwen.hotwords = []
    return .qwen3(qwen)
  }

  private static func requestHotwords(
    from configuration: SherpaOfflineModelConfiguration
  ) -> [String] {
    guard case .qwen3(let qwen) = configuration else { return [] }
    return qwen.hotwords
  }

  private static let liveFactory: Factory = { configuration in
    let box = try SherpaOnnxNativeRecognizerBox(configuration: configuration)
    return SherpaOnnxRuntimeTranscriber { samples, sampleRate, hotwords in
      try box.recognizer.transcribe(
        samples: samples,
        sampleRate: sampleRate,
        hotwords: hotwords
      )
    }
  }
}

private final class SherpaOnnxNativeRecognizerBox: @unchecked Sendable {
  let recognizer: SherpaOfflineRecognizer

  init(configuration: SherpaOfflineModelConfiguration) throws {
    self.recognizer = try SherpaOfflineRecognizer(configuration: configuration)
  }
}

private enum SherpaOnnxAudioFileConverter {
  private static let inputFrameCapacity: AVAudioFrameCount = 8_192

  static func loadSamples(from fileURL: URL) throws -> [Float] {
    guard fileURL.isFileURL else {
      throw SherpaOnnxRecognizer.RecognizerError.invalidAudioFile
    }

    let audioFile: AVAudioFile
    do {
      audioFile = try AVAudioFile(forReading: fileURL)
    } catch {
      throw SherpaOnnxRecognizer.RecognizerError.invalidAudioFile
    }
    let sourceFormat = audioFile.processingFormat
    guard sourceFormat.sampleRate.isFinite, sourceFormat.sampleRate > 0,
      sourceFormat.channelCount > 0,
      audioFile.length > 0
    else {
      throw SherpaOnnxRecognizer.RecognizerError.emptyAudio
    }

    let estimatedOutputFrameCount =
      Double(audioFile.length) * Double(SherpaOnnxRecognizer.targetSampleRate)
      / sourceFormat.sampleRate
    try SherpaOnnxRecognizer.validateEstimatedAudioSampleCount(estimatedOutputFrameCount)
    guard
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(SherpaOnnxRecognizer.targetSampleRate),
        channels: 1,
        interleaved: false
      ),
      let converter = AVAudioConverter(from: sourceFormat, to: outputFormat)
    else {
      throw SherpaOnnxRecognizer.RecognizerError.audioConversionFailed
    }

    var samples: [Float] = []
    samples.reserveCapacity(Int(estimatedOutputFrameCount.rounded(.up)))
    while audioFile.framePosition < audioFile.length {
      guard
        let inputBuffer = AVAudioPCMBuffer(
          pcmFormat: sourceFormat,
          frameCapacity: inputFrameCapacity
        )
      else {
        throw SherpaOnnxRecognizer.RecognizerError.audioConversionFailed
      }
      do {
        try audioFile.read(into: inputBuffer, frameCount: inputFrameCapacity)
      } catch {
        throw SherpaOnnxRecognizer.RecognizerError.audioConversionFailed
      }
      guard inputBuffer.frameLength > 0 else { break }

      let inputState = SherpaOnnxAudioChunkInputState(
        buffer: inputBuffer,
        isFinalInput: audioFile.framePosition >= audioFile.length
      )
      var conversionStatus: AVAudioConverterOutputStatus
      repeat {
        let frameCapacity = try outputFrameCapacity(
          inputFrameCount: inputBuffer.frameLength,
          inputSampleRate: sourceFormat.sampleRate
        )
        guard
          let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: frameCapacity
          )
        else {
          throw SherpaOnnxRecognizer.RecognizerError.audioConversionFailed
        }
        var conversionError: NSError?
        conversionStatus = converter.convert(
          to: outputBuffer,
          error: &conversionError,
          withInputFrom: inputState.nextBuffer
        )
        guard conversionError == nil, conversionStatus != .error else {
          throw SherpaOnnxRecognizer.RecognizerError.audioConversionFailed
        }

        let frameCount = Int(outputBuffer.frameLength)
        if frameCount > 0 {
          guard let channel = outputBuffer.floatChannelData?[0] else {
            throw SherpaOnnxRecognizer.RecognizerError.audioConversionFailed
          }
          samples.append(
            contentsOf: UnsafeBufferPointer(start: channel, count: frameCount)
          )
          guard samples.count <= SherpaOnnxRecognizer.maximumAudioSampleCount else {
            throw SherpaOnnxRecognizer.RecognizerError.audioTooLong(
              maximumDurationSeconds: SherpaOnnxRecognizer.maximumAudioDurationSeconds
            )
          }
        }
      } while conversionStatus == .haveData
    }
    return try SherpaOnnxRecognizer.validatedSamples(samples)
  }

  private static func outputFrameCapacity(
    inputFrameCount: AVAudioFrameCount,
    inputSampleRate: Double
  ) throws -> AVAudioFrameCount {
    let expected =
      ceil(
        Double(inputFrameCount) * Double(SherpaOnnxRecognizer.targetSampleRate)
          / inputSampleRate
      ) + 256
    guard expected.isFinite, expected > 0, expected <= Double(UInt32.max) else {
      throw SherpaOnnxRecognizer.RecognizerError.audioConversionFailed
    }
    return AVAudioFrameCount(expected)
  }
}

private final class SherpaOnnxAudioChunkInputState: @unchecked Sendable {
  private let buffer: AVAudioPCMBuffer
  private let isFinalInput: Bool
  private var didProvideInput = false

  init(buffer: AVAudioPCMBuffer, isFinalInput: Bool) {
    self.buffer = buffer
    self.isFinalInput = isFinalInput
  }

  lazy var nextBuffer: AVAudioConverterInputBlock = { [self] _, status in
    guard !didProvideInput else {
      status.pointee = isFinalInput ? .endOfStream : .noDataNow
      return nil
    }
    didProvideInput = true
    status.pointee = .haveData
    return buffer
  }
}

extension String {
  fileprivate var trimmedNonEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
