import XCTest

@testable import RillCore
@testable import RillMLXRuntime
@testable import RillSpeechContracts

final class Qwen3RecordEmbedderTests: XCTestCase {
  func testDocumentWindowPlanPreservesAllStartsWithinTheLimit() {
    for tokenCount in [1, 192, 193, 3_072] {
      let plan = Qwen3RecordEmbedder.documentWindowPlan(tokenCount: tokenCount)
      XCTAssertEqual(plan.starts, Array(stride(from: 0, to: tokenCount, by: 192)))
      XCTAssertFalse(plan.coverageLimited)
    }
  }

  func testDocumentWindowPlanSamplesTheEntireDocumentWithoutDuplicates() {
    for windowCount in [17, 33, 201, 513] {
      let tokenCount = (windowCount - 1) * 192 + 1
      let plan = Qwen3RecordEmbedder.documentWindowPlan(tokenCount: tokenCount)
      XCTAssertTrue(plan.coverageLimited)
      XCTAssertEqual(plan.starts.count, 16)
      XCTAssertEqual(Set(plan.starts).count, 16)
      XCTAssertEqual(plan.starts.first, 0)
      XCTAssertEqual(plan.starts.last, (windowCount - 1) * 192)
      XCTAssertEqual(plan.starts, plan.starts.sorted())
      XCTAssertTrue(plan.starts.allSatisfy { $0.isMultiple(of: 192) && $0 < tokenCount })
      let indices = plan.starts.map { $0 / 192 }
      let gaps = zip(indices, indices.dropFirst()).map { $0.1 - $0.0 }
      XCTAssertTrue(gaps.allSatisfy { ((windowCount - 1) / 15...(windowCount + 13) / 15).contains($0) })
      XCTAssertTrue(indices.contains { abs($0 - (windowCount - 1) / 2) <= (windowCount + 13) / 15 })
    }
  }

  func testRejectsEmptyAndOversizeInputBeforeLoadingModel() async throws {
    let embedder = Qwen3RecordEmbedder(directory: URL(fileURLWithPath: "/unavailable-model"))
    for text in [" \n", String(repeating: "a", count: 48 * 1_024 + 1)] {
      do {
        _ = try await embedder.embed(text, purpose: .document)
        XCTFail("Invalid input must not load a model")
      } catch RecordEmbeddingError.invalidInput {}
    }
  }

  func testExplicitModelDownloadPublishesOnlyVerifiedFiles() async throws {
    guard ProcessInfo.processInfo.environment["RILL_TEST_EMBEDDING_DOWNLOAD"] == "1" else {
      throw XCTSkip(
        "Set RILL_TEST_EMBEDDING_DOWNLOAD=1 to download the public 1.2 GB model into a temporary store."
      )
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-embedding-download-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RecordEmbeddingModelStore(root: root)
    do {
      _ = try await store.directory(downloadIfNeeded: false, progress: { _ in })
      XCTFail("Download must be explicit")
    } catch MLXAudioSwiftRuntimeError.modelUnavailable {}
    let directory = try await store.directory(downloadIfNeeded: true, progress: { _ in })
    XCTAssertTrue(try store.validate(directory))
    let reused = try await store.directory(downloadIfNeeded: false, progress: { _ in })
    XCTAssertEqual(reused, directory)
  }

  func testVerifiedModelStoreAndWorkerHandlerWithOfflineWeights() async throws {
    guard let path = ProcessInfo.processInfo.environment["RILL_EMBEDDING_MODEL_DIR"] else {
      throw XCTSkip("Set RILL_EMBEDDING_MODEL_DIR to validate the pinned offline weights.")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-embedding-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let published = root.appendingPathComponent(RecordEmbeddingModelCatalog.revision)
    for file in RecordEmbeddingModelCatalog.files {
      let destination = published.appendingPathComponent(file.path)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(
        at: URL(fileURLWithPath: path).appendingPathComponent(file.path).resolvingSymlinksInPath(),
        to: destination)
    }
    let store = RecordEmbeddingModelStore(root: root)
    XCTAssertTrue(try store.validate(published))
    let worker = RecordEmbeddingWorkerService(store: store)
    let prepare = SpeechWorkerRequest(
      requestID: UUID(), generation: 1,
      payload: .prepareEmbeddingModel(
        .init(modelID: RecordEmbeddingModelCatalog.modelID, downloadIfNeeded: false)))
    let preparation = await worker.handle(prepare, progress: { _ in })
    XCTAssertEqual(preparation.preparedModelID, RecordEmbeddingModelCatalog.modelID)
    let request = SpeechWorkerRequest(
      requestID: UUID(), generation: 1,
      payload: .embedText(
        .init(modelID: RecordEmbeddingModelCatalog.modelID, text: "撤销上次提交但保留代码改动", purpose: .query))
    )
    let decoded = try SpeechWorkerProtocolCodec.decodeRequestLine(
      SpeechWorkerProtocolCodec.encodeRequestLine(request).dropLast())
    let response = await worker.handle(decoded, progress: { _ in })
    let result = try SpeechWorkerProtocolCodec.decodeResponseLine(
      SpeechWorkerProtocolCodec.encodeResponseLine(response).dropLast())
    XCTAssertEqual(result.embeddingResult?.vectors.first?.count, 1_024)
    // Unexpected weights and linked subdirectories cannot change what the loader reads.
    let unexpected = published.appendingPathComponent("extra.safetensors")
    try Data().write(to: unexpected)
    XCTAssertFalse(try store.validate(published))
    try FileManager.default.removeItem(at: unexpected)
    let pooling = published.appendingPathComponent("1_Pooling")
    let moved = root.appendingPathComponent("pooling")
    try FileManager.default.moveItem(at: pooling, to: moved)
    try FileManager.default.createSymbolicLink(at: pooling, withDestinationURL: moved)
    XCTAssertFalse(try store.validate(published))
  }

  func testRealLocalModelRetrievesChineseIntentAndProducesNormalizedVectors() async throws {
    guard let path = ProcessInfo.processInfo.environment["RILL_EMBEDDING_MODEL_DIR"] else {
      throw XCTSkip("Set RILL_EMBEDDING_MODEL_DIR to an offline Qwen3-Embedding-0.6B snapshot.")
    }
    let embedder = Qwen3RecordEmbedder(directory: URL(fileURLWithPath: path))
    let query = try await embedder.embed("撤销上次提交但保留代码改动", purpose: .query)
    let desired = try await embedder.embed("git reset --soft HEAD~1", purpose: .document)
    let distractor = try await embedder.embed("docker compose logs --follow", purpose: .document)
    XCTAssertEqual(query.vectors.count, 1)
    XCTAssertFalse(query.coverageLimited)
    let vector = try XCTUnwrap(query.vectors.first)
    XCTAssertEqual(vector.count, 1_024)
    let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }
    XCTAssertEqual(norm, 1, accuracy: 0.005)
    let good = zip(vector, try XCTUnwrap(desired.vectors.first)).reduce(Float(0)) {
      $0 + $1.0 * $1.1
    }
    let bad = zip(vector, try XCTUnwrap(distractor.vectors.first)).reduce(Float(0)) {
      $0 + $1.0 * $1.1
    }
    XCTAssertGreaterThan(good, bad)
    print("RECORD_EMBEDDING_SMOKE desired=\(good) distractor=\(bad)")
    await embedder.release()
  }
}
