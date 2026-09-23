@testable import RillSpeechContracts
import CryptoKit
import Foundation
import XCTest

@testable import RillCore
@testable import RillMLXRuntime
final class MLXAudioSwiftSpeechWorkerServiceTests: XCTestCase {
  func testTTSInventoryUsesPublishedReceiptAndFileInventory() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let descriptor = SpeechSynthesisModelCatalog.qwen3TTS06BCustomVoiceBF16
    let publication = root
      .appendingPathComponent("tts", isDirectory: true)
      .appendingPathComponent(
        descriptor.id.rawValue + "-" + descriptor.revision.prefix(12),
        isDirectory: true
      )
    try FileManager.default.createDirectory(
      at: publication,
      withIntermediateDirectories: true
    )
    for file in descriptor.files {
      let url = publication.appendingPathComponent(file.path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
      let handle = try FileHandle(forWritingTo: url)
      try handle.truncate(atOffset: file.byteCount)
      try handle.close()
    }
    let receipt: [String: Any] = [
      "schemaVersion": 1,
      "modelID": descriptor.id.rawValue,
      "repository": descriptor.repository,
      "revision": descriptor.revision,
      "files": descriptor.files.map {
        [
          "path": $0.path,
          "byteCount": $0.byteCount,
          "sha256": $0.sha256,
        ] as [String: Any]
      },
    ]
    try JSONSerialization.data(withJSONObject: receipt).write(
      to: publication.appendingPathComponent(".rill-mlx-audio-swift-tts-model.json")
    )
    let store = MLXAudioSwiftTTSModelStore(
      modelRootURL: root,
      hubCacheRootURL: root.appendingPathComponent("cache", isDirectory: true)
    )

    XCTAssertEqual(
      store.installedModelIdentifiers(
        descriptors: SpeechSynthesisModelCatalog.supportedModels
      ),
      [descriptor.id.rawValue]
    )
  }

  func testTTSModelStoreRemovesOnlySelectedModelsAbandonedTransactions() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let selected = SpeechSynthesisModelID.qwen3TTS06BCustomVoiceInt8
    let stalePartial = root.appendingPathComponent(
      ".\(selected.rawValue).old.partial",
      isDirectory: true
    )
    let otherPartial = root.appendingPathComponent(
      ".\(SpeechSynthesisModelID.qwen3TTS06BCustomVoiceBF16.rawValue).old.partial",
      isDirectory: true
    )
    let published = root.appendingPathComponent(
      "\(selected.rawValue)-published",
      isDirectory: true
    )
    for directory in [stalePartial, otherPartial, published] {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
      )
    }

    try MLXAudioSwiftTTSModelStore.removeAbandonedEntries(
      in: root,
      for: selected
    )

    XCTAssertFalse(FileManager.default.fileExists(atPath: stalePartial.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: otherPartial.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: published.path))
  }

  func testPrepareAndRecognitionUseNativeEngineThroughBoundedProtocol() async throws {
    let engine = FakeMLXAudioSwiftEngine()
    let service = MLXAudioSwiftSpeechWorkerService(engine: engine)
    let modelID = MLXAudioModelID.qwen3ASR17BInt8.rawValue
    let preparation = SpeechWorkerRequest(
      requestID: UUID(),
      generation: 1,
      modelPreparationPayload: SpeechWorkerModelPreparationPayload(
        modelID: modelID,
        downloadIfNeeded: true
      )
    )

    let progress = WorkerProgressRecorder()
    let prepared = await service.handle(
      preparation,
      progress: progress.record
    )

    XCTAssertEqual(prepared.status, .success)
    XCTAssertEqual(prepared.preparedModelID, modelID)
    XCTAssertEqual(
      progress.snapshot(),
      [
        SpeechWorkerProgress(
          phase: .downloading,
          completedUnitCount: 25,
          totalUnitCount: 100
        )
      ]
    )
    let audioURL = try makeManagedAudioFile()
    defer { try? FileManager.default.removeItem(at: audioURL) }
    let recognition = makeRecognitionRequest(modelID: modelID, audioURL: audioURL)

    let recognized = await service.handle(recognition)

    XCTAssertEqual(recognized.status, .success)
    XCTAssertEqual(recognized.result?.bestText, "你好 Rill")
    XCTAssertEqual(
      recognized.result?.metadata["provider.kind"],
      LocalSpeechModelBackend.mlxAudioSwift.rawValue
    )
    XCTAssertEqual(recognized.result?.metadata["provider.runtime"], "mlx-audio-swift-0.1.3")
    let preparations = await engine.preparations()
    let recognitionCount = await engine.recognitionCount()
    XCTAssertEqual(preparations.count, 1)
    XCTAssertEqual(preparations.first?.0, modelID)
    XCTAssertEqual(preparations.first?.1, true)
    XCTAssertEqual(recognitionCount, 1)
  }

  func testRecognitionRejectsAudioOutsideManagedNamespaceWithoutLeakingPath() async throws {
    let request = makeRecognitionRequest(
      modelID: MLXAudioModelID.qwen3ASR17BInt8.rawValue,
      audioURL: URL(fileURLWithPath: "/Users/private/token-must-not-leak.wav")
    )

    let response = await MLXAudioSwiftSpeechWorkerService(
      engine: FakeMLXAudioSwiftEngine()
    ).handle(request)
    let encoded = try SpeechWorkerProtocolCodec.encodeResponseLine(response)
    let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))

    XCTAssertEqual(response.failure, .invalidAudio)
    XCTAssertFalse(text.contains("token-must-not-leak"))
  }

  func testWorkerRouterRejectsRetiredModelAndRoutesReviewedMLXIdentity() async {
    let mlx = RecordingWorkerHandler()
    let router = RoutedSpeechWorkerService(mlxAudioSwift: mlx)

    let retired = await router.handle(
      SpeechWorkerRequest(
        requestID: UUID(),
        generation: 1,
        modelPreparationPayload: SpeechWorkerModelPreparationPayload(
          modelID: "sherpa-onnx-qwen3-asr-0.6b-int8-2026-03-25",
          downloadIfNeeded: false
        )
      )
    )
    _ = await router.handle(
      SpeechWorkerRequest(
        requestID: UUID(),
        generation: 2,
        modelPreparationPayload: SpeechWorkerModelPreparationPayload(
          modelID: MLXAudioModelID.qwen3ASR17BInt8.rawValue,
          downloadIfNeeded: false
        )
      )
    )

    let mlxRequestCount = await mlx.requestCount()
    XCTAssertEqual(retired.failure, .unsupportedModel)
    XCTAssertEqual(mlxRequestCount, 1)
  }

  func testReleasingASRModelClearsMLXMemoryCache() async throws {
    let cacheClearRecorder = CacheClearRecorder()
    let engine = MLXAudioSwiftQwenEngine(
      clearMemoryCache: cacheClearRecorder.record
    )

    try await engine.release(modelID: MLXAudioModelID.qwen3ASR17BInt8.rawValue)

    XCTAssertEqual(cacheClearRecorder.count, 1)
  }

  func testRejectingUnknownASRModelDoesNotClearMLXMemoryCache() async {
    let cacheClearRecorder = CacheClearRecorder()
    let engine = MLXAudioSwiftQwenEngine(
      clearMemoryCache: cacheClearRecorder.record
    )

    do {
      try await engine.release(modelID: "unknown-model")
      XCTFail("Expected the unknown model to be rejected.")
    } catch {
      XCTAssertEqual(
        error as? MLXAudioSwiftRuntimeError,
        .unsupportedModel("unknown-model")
      )
    }
    XCTAssertEqual(cacheClearRecorder.count, 0)
  }

  func testModelStoreAuthenticatesExactPinnedInventoryAndDigests() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = [
      ("config.json", Data("trusted-config".utf8)),
      ("model.safetensors", Data("trusted-weights".utf8)),
      ("tokenizer_config.json", Data("trusted-tokenizer".utf8)),
    ]
    let descriptor = makeTestMLXAudioDescriptor(files: files)
    for (name, contents) in files {
      XCTAssertTrue(
        FileManager.default.createFile(
          atPath: root.appendingPathComponent(name).path,
          contents: contents
        )
      )
    }
    try MLXAudioSwiftModelStore.receiptData(for: descriptor).write(
      to: root.appendingPathComponent(MLXAudioSwiftModelStore.receiptFileName)
    )

    XCTAssertTrue(
      try MLXAudioSwiftModelStore.validatePublishedModel(
        at: root,
        descriptor: descriptor
      )
    )

    let configURL = root.appendingPathComponent("config.json")
    let originalConfig = try Data(contentsOf: configURL)
    try Data(repeating: 0x78, count: originalConfig.count).write(
      to: configURL
    )
    XCTAssertFalse(
      try MLXAudioSwiftModelStore.validatePublishedModel(
        at: root,
        descriptor: descriptor
      ),
      "A same-length model-file substitution must invalidate the publication."
    )
    try originalConfig.write(to: configURL)

    let symlinkTargetURL = root.deletingLastPathComponent().appendingPathComponent(
      "\(root.lastPathComponent)-symlink-target"
    )
    defer { try? FileManager.default.removeItem(at: symlinkTargetURL) }
    try originalConfig.write(to: symlinkTargetURL)
    try FileManager.default.removeItem(at: configURL)
    try FileManager.default.createSymbolicLink(
      at: configURL,
      withDestinationURL: symlinkTargetURL
    )
    XCTAssertFalse(
      try MLXAudioSwiftModelStore.validatePublishedModel(
        at: root,
        descriptor: descriptor
      ),
      "A symlink must not satisfy an authenticated model-file entry."
    )
    try FileManager.default.removeItem(at: configURL)
    try originalConfig.write(to: configURL)

    let unexpectedURL = root.appendingPathComponent("unexpected.json")
    try Data("not-reviewed".utf8).write(to: unexpectedURL)
    XCTAssertFalse(
      try MLXAudioSwiftModelStore.validatePublishedModel(
        at: root,
        descriptor: descriptor
      ),
      "Files outside the authenticated inventory must invalidate the publication."
    )
    try FileManager.default.removeItem(at: unexpectedURL)

    let generatedTokenizerURL = root.appendingPathComponent("tokenizer.json")
    try Data("attacker-controlled".utf8).write(to: generatedTokenizerURL)
    XCTAssertFalse(
      try MLXAudioSwiftModelStore.validatePublishedModel(
        at: root,
        descriptor: descriptor
      )
    )
    try MLXAudioSwiftModelStore.removeGeneratedFiles(at: root)
    XCTAssertTrue(
      try MLXAudioSwiftModelStore.validatePublishedModel(
        at: root,
        descriptor: descriptor
      ),
      "The runtime-generated tokenizer must be removed before native loading."
    )
  }

  func testModelDirectoryAuthenticatesLegacyPublicationBeforeReturning() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = [
      ("config.json", Data("trusted-config".utf8)),
      ("model.safetensors", Data("trusted-weights".utf8)),
    ]
    let descriptor = makeTestMLXAudioDescriptor(files: files)
    let publication = root
      .appendingPathComponent("mlx-audio", isDirectory: true)
      .appendingPathComponent("test_Authenticated-ASR", isDirectory: true)
    try FileManager.default.createDirectory(
      at: publication,
      withIntermediateDirectories: true
    )
    for (name, contents) in files {
      XCTAssertTrue(
        FileManager.default.createFile(
          atPath: publication.appendingPathComponent(name).path,
          contents: contents
        )
      )
    }
    let legacyReceipt: [String: Any] = [
      "schemaVersion": 1,
      "modelID": descriptor.id.rawValue,
      "repository": descriptor.repository,
      "revision": descriptor.revision,
    ]
    try JSONSerialization.data(withJSONObject: legacyReceipt).write(
      to: publication.appendingPathComponent(
        MLXAudioSwiftModelStore.receiptFileName
      )
    )
    try Data("attacker-controlled".utf8).write(
      to: publication.appendingPathComponent("tokenizer.json")
    )
    let store = MLXAudioSwiftModelStore(
      modelRootURL: root,
      hubCacheRootURL: root.appendingPathComponent("cache", isDirectory: true)
    )

    let resolved = try await store.modelDirectory(
      descriptor: descriptor,
      downloadIfNeeded: false
    )

    XCTAssertEqual(resolved, publication)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: publication.appendingPathComponent("tokenizer.json").path
      )
    )
    XCTAssertTrue(
      try MLXAudioSwiftModelStore.validatePublishedModel(
        at: publication,
        descriptor: descriptor
      )
    )
  }

  func testModelStoreRemovesOnlySelectedModelsAbandonedTransactions() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let selected = MLXAudioModelID.qwen3ASR17BInt8
    let stalePartial = root.appendingPathComponent(
      ".\(selected.rawValue).old.partial",
      isDirectory: true
    )
    let staleReplacement = root.appendingPathComponent(
      ".\(selected.rawValue).old.replaced",
      isDirectory: true
    )
    let published = root.appendingPathComponent(
      "mlx-community_Qwen3-ASR-1.7B-8bit",
      isDirectory: true
    )
    for directory in [stalePartial, staleReplacement, published] {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
      )
    }

    try MLXAudioSwiftModelStore.removeAbandonedEntries(
      in: root,
      for: selected
    )

    XCTAssertFalse(FileManager.default.fileExists(atPath: stalePartial.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: staleReplacement.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: published.path))
  }

  func testAutomaticLanguageLeavesDetectionToQwen() {
    XCTAssertNil(MLXAudioSwiftQwenOptions.resolvedLanguage(nil))
    XCTAssertNil(MLXAudioSwiftQwenOptions.resolvedLanguage(" auto "))
    XCTAssertEqual(MLXAudioSwiftQwenOptions.resolvedLanguage("zh-CN"), "Chinese")
    XCTAssertEqual(MLXAudioSwiftQwenOptions.resolvedLanguage("en-GB"), "English")
    XCTAssertEqual(MLXAudioSwiftQwenOptions.resolvedLanguage("yue-HK"), "Cantonese")
  }

  func testKeytermContextReusesBoundedQwenSanitization() {
    XCTAssertEqual(
      MLXAudioSwiftQwenOptions.context(
        from: [" Rill ", "Rill", "中英混合", "contains,comma"]
      ),
      "Keywords: Rill, 中英混合."
    )
    XCTAssertEqual(MLXAudioSwiftQwenOptions.context(from: []), "")
  }

  private func makeRecognitionRequest(
    modelID: String,
    audioURL: URL
  ) -> SpeechWorkerRequest {
    SpeechWorkerRequest(
      requestID: UUID(),
      generation: 1,
      payload: SpeechWorkerRecognitionPayload(
        runID: UUID(),
        modelID: modelID,
        language: "zh-CN",
        keyterms: ["Rill"],
        threadCount: 1,
        audioFilePath: audioURL.path,
        audioDurationSeconds: 1,
        audioFormat: AudioFormat(
          sampleRateHz: 16_000,
          channelCount: 1,
          encoding: .float32
        ),
        downloadIfNeeded: false
      )
    )
  }

  private func makeManagedAudioFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-mlx-swift-test-\(UUID().uuidString).wav"
    )
    guard FileManager.default.createFile(atPath: url.path, contents: Data([0])) else {
      throw CocoaError(.fileWriteUnknown)
    }
    return url
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-mlx-model-store-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: false
    )
    return url
  }

  private func makeTestMLXAudioDescriptor(
    files: [(String, Data)]
  ) -> MLXAudioModelDescriptor {
    MLXAudioModelDescriptor(
      id: .qwen3ASR17BInt8,
      repository: "test/Authenticated-ASR",
      revision: String(repeating: "a", count: 40),
      approximateDownloadByteCount: UInt64(
        files.reduce(0) { $0 + $1.1.count }
      ),
      files: files.map { path, data in
        MLXAudioModelFile(
          path: path,
          byteCount: UInt64(data.count),
          sha256: SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        )
      }
    )
  }
}

private final class CacheClearRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedCount = 0

  var count: Int {
    lock.withLock { recordedCount }
  }

  func record() {
    lock.withLock {
      recordedCount += 1
    }
  }
}

private actor FakeMLXAudioSwiftEngine: MLXAudioSwiftInferenceEngine {
  private var recordedPreparations: [(String, Bool)] = []
  private var recordedRecognitionCount = 0

  func prepare(
    modelID: String,
    downloadIfNeeded: Bool,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void
  ) async throws -> String {
    recordedPreparations.append((modelID, downloadIfNeeded))
    progress(
      SpeechWorkerProgress(
        phase: .downloading,
        completedUnitCount: 25,
        totalUnitCount: 100
      )
    )
    return modelID
  }

  func recognize(
    modelID _: String,
    audioURL _: URL,
    language _: String?,
    keyterms _: [String],
    downloadIfNeeded _: Bool
  ) async throws -> MLXAudioSwiftInferenceOutput {
    recordedRecognitionCount += 1
    return MLXAudioSwiftInferenceOutput(
      text: "你好 Rill",
      detectedLanguage: "Chinese",
      processingDurationMillis: 17
    )
  }

  func preparations() -> [(String, Bool)] {
    recordedPreparations
  }

  func recognitionCount() -> Int {
    recordedRecognitionCount
  }
}

private final class WorkerProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [SpeechWorkerProgress] = []

  func record(_ progress: SpeechWorkerProgress) {
    lock.withLock {
      values.append(progress)
    }
  }

  func snapshot() -> [SpeechWorkerProgress] {
    lock.withLock { values }
  }
}

private actor RecordingWorkerHandler: SpeechWorkerRequestHandling {
  private var requests: [SpeechWorkerRequest] = []

  func handle(
    _ request: SpeechWorkerRequest,
    progress _: @escaping @Sendable (SpeechWorkerProgress) -> Void
  ) async -> SpeechWorkerResponse {
    requests.append(request)
    if let payload = request.modelPreparationPayload {
      return .prepared(request: request, modelID: payload.modelID)
    }
    return .failure(request: request, code: .invalidRequest)
  }

  func requestCount() -> Int {
    requests.count
  }
}
