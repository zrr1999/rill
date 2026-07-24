import Foundation
import XCTest

@testable import RillCore
@testable import RillMLXRuntime
@testable import RillProviders

final class MLXAudioSwiftSpeechWorkerServiceTests: XCTestCase {
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

    let prepared = await service.handle(preparation)

    XCTAssertEqual(prepared.status, .success)
    XCTAssertEqual(prepared.preparedModelID, modelID)
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

  func testWorkerRouterSelectsHandlersByReviewedModelIdentity() async {
    let sherpa = RecordingWorkerHandler()
    let mlx = RecordingWorkerHandler()
    let router = RoutedSpeechWorkerService(sherpaOnnx: sherpa, mlxAudioSwift: mlx)

    _ = await router.handle(
      SpeechWorkerRequest(
        requestID: UUID(),
        generation: 1,
        modelPreparationPayload: SpeechWorkerModelPreparationPayload(
          modelID: SherpaOnnxModelCatalog.defaultModelID.rawValue,
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

    let sherpaRequestCount = await sherpa.requestCount()
    let mlxRequestCount = await mlx.requestCount()
    XCTAssertEqual(sherpaRequestCount, 1)
    XCTAssertEqual(mlxRequestCount, 1)
  }

  func testModelStoreAcceptsOnlyExactPinnedReceiptAndRegularFiles() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let descriptor = MLXAudioModelCatalog.descriptor(for: .qwen3ASR17BInt8)
    for name in MLXAudioSwiftModelStore.requiredFileNames {
      XCTAssertTrue(
        FileManager.default.createFile(
          atPath: root.appendingPathComponent(name).path,
          contents: Data(name.utf8)
        )
      )
    }
    let receipt: [String: Any] = [
      "schemaVersion": 1,
      "modelID": descriptor.id.rawValue,
      "repository": descriptor.repository,
      "revision": descriptor.revision,
    ]
    let receiptData = try JSONSerialization.data(withJSONObject: receipt)
    try receiptData.write(
      to: root.appendingPathComponent(MLXAudioSwiftModelStore.receiptFileName)
    )

    XCTAssertTrue(
      try MLXAudioSwiftModelStore.validatePublishedModel(
        at: root,
        descriptor: descriptor
      )
    )

    let wrongReceipt: [String: Any] = [
      "schemaVersion": 1,
      "modelID": descriptor.id.rawValue,
      "repository": descriptor.repository,
      "revision": String(repeating: "0", count: 40),
    ]
    try JSONSerialization.data(withJSONObject: wrongReceipt).write(
      to: root.appendingPathComponent(MLXAudioSwiftModelStore.receiptFileName)
    )
    XCTAssertFalse(
      try MLXAudioSwiftModelStore.validatePublishedModel(
        at: root,
        descriptor: descriptor
      )
    )
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
}

private actor FakeMLXAudioSwiftEngine: MLXAudioSwiftInferenceEngine {
  private var recordedPreparations: [(String, Bool)] = []
  private var recordedRecognitionCount = 0

  func prepare(modelID: String, downloadIfNeeded: Bool) async throws -> String {
    recordedPreparations.append((modelID, downloadIfNeeded))
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

private actor RecordingWorkerHandler: SpeechWorkerRequestHandling {
  private var requests: [SpeechWorkerRequest] = []

  func handle(_ request: SpeechWorkerRequest) async -> SpeechWorkerResponse {
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
