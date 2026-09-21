import XCTest

@testable import RillCore
@testable import RillRuntime

final class RecordSemanticSearchTests: XCTestCase {
  func testFiltersAndNumericAnchorsApplyBeforeRankingAndCacheTracksTagsAndDeletion() async throws {
    let store = RecordStore()
    let collection = try await store.createCollection(name: "Invoices")
    let desired = try await store.ingest(
      draft("INV-123 paid", app: "editor"), into: [collection.id])
    _ = try await store.updateMetadata(recordID: desired.id, isPinned: true)
    _ = try await store.ingest(draft("INV-1234 paid", app: "editor"), into: [collection.id])
    _ = try await store.ingest(draft("INV-123 paid", app: "other"), into: [])
    let embedder = SemanticTestEmbedder()
    let search = RecordSemanticSearch(store: store, embedder: embedder)
    let query = RecordQuery(
      text: "INV-123 status", collectionID: collection.id, sourceBundleIdentifier: "editor",
      kind: .text,
      pinnedOnly: true)
    let first = try await search.search(query)
    XCTAssertEqual(first.records.map(\.id), [desired.id])
    _ = try await search.search(query)
    let cachedCalls = await embedder.documents
    XCTAssertEqual(cachedCalls.count, 1)
    _ = try await store.updateMetadata(recordID: desired.id, tags: ["reviewed"])
    _ = try await search.search(query)
    let changedCalls = await embedder.documents
    XCTAssertEqual(changedCalls.count, 2)
    XCTAssertTrue(changedCalls.last?.contains("reviewed") == true)
    try await store.deleteRecord(desired.id)
    let afterDelete = try await search.search(query)
    XCTAssertTrue(afterDelete.records.isEmpty)
    await search.shutdown()
  }

  func testNumericNearMatchAndExactAddressesDoNotBecomeSemanticCandidates() async throws {
    let store = RecordStore()
    let desired = try await store.ingest(draft("ticket INV-123", app: "editor"), into: [])
    _ = try await store.ingest(draft("ticket INV-1234", app: "editor"), into: [])
    let embedder = SemanticTestEmbedder()
    let search = RecordSemanticSearch(store: store, embedder: embedder)
    for text in ["INV-123 details", "找INV-123的付款记录"] {
      let result = try await search.search(.init(text: text))
      XCTAssertEqual(result.records.map(\.id), [desired.id])
    }
    let before = await embedder.prepareCount
    for text in ["https://example.com/123", "/tmp/report.txt"] {
      let addressed = try await search.search(.init(text: text))
      XCTAssertTrue(addressed.records.isEmpty)
    }
    let after = await embedder.prepareCount
    XCTAssertEqual(before, after)
    await search.shutdown()
  }

  func testCatalogChangeWhileInferenceIsHeldRejectsStaleCandidates() async throws {
    let store = RecordStore()
    let record = try await store.ingest(draft("old", app: "editor"), into: [])
    let entered = expectation(description: "query inference entered")
    let embedder = SemanticTestEmbedder(held: entered)
    let search = RecordSemanticSearch(store: store, embedder: embedder)
    let task = Task { try await search.search(.init(text: "intent")) }
    await fulfillment(of: [entered], timeout: 2)
    _ = try await store.updateMetadata(recordID: record.id, tags: ["changed"])
    await embedder.resume()
    do {
      _ = try await task.value
      XCTFail("Stale catalog must not be published")
    } catch RecordStoreError.membershipChanged {}
    await search.shutdown()
  }

  func testCancellationCannotPublishAfterUncooperativeInferenceReturns() async throws {
    let store = RecordStore()
    _ = try await store.ingest(draft("record", app: "editor"), into: [])
    let entered = expectation(description: "inference entered")
    let embedder = SemanticTestEmbedder(held: entered)
    let search = RecordSemanticSearch(store: store, embedder: embedder)
    let task = Task { try await search.search(.init(text: "intent")) }
    await fulfillment(of: [entered], timeout: 2)
    task.cancel()
    await embedder.resume()
    do {
      _ = try await task.value
      XCTFail("Cancelled inference must not publish")
    } catch is CancellationError {}
    let documents = await embedder.documents
    XCTAssertTrue(documents.isEmpty)
    await search.shutdown()
  }

  func testLongUnicodeAndEscapedBodiesStayBoundedAndReportPartialCoverage() async throws {
    let store = RecordStore()
    _ = try await store.ingest(draft(String(repeating: "👨‍👩‍👧‍👦", count: 4_000), app: "editor"), into: [])
    _ = try await store.ingest(
      draft(String(repeating: "\u{1}", count: 30_000), app: "editor"), into: [])
    let embedder = SemanticTestEmbedder()
    let search = RecordSemanticSearch(store: store, embedder: embedder)
    let result = try await search.search(.init(text: "intent"))
    XCTAssertEqual(result.limitedRecordCount, 2)
    let inputs = await embedder.documents
    XCTAssertEqual(inputs.count, 2)
    for input in inputs {
      XCTAssertLessThanOrEqual(input.utf8.count, 48 * 1_024)
      XCTAssertLessThan(try JSONEncoder().encode(input).count, 60 * 1_024)
    }
    await search.shutdown()
  }

  func testFailureRetainsValidPartialEmbeddingsForRetry() async throws {
    let store = RecordStore()
    _ = try await store.ingest(draft("first", app: "editor"), into: [])
    _ = try await store.ingest(draft("second", app: "editor"), into: [])
    let embedder = SemanticTestEmbedder(failDocumentCall: 2)
    let search = RecordSemanticSearch(store: store, embedder: embedder)
    do {
      _ = try await search.search(.init(text: "intent"))
      XCTFail("The injected failure must surface")
    } catch RecordEmbeddingError.invalidOutput {}
    let retry = try await search.search(.init(text: "intent"))
    XCTAssertEqual(retry.records.count, 2)
    let documents = await embedder.documents
    XCTAssertEqual(
      documents.count, 3, "Retry should reuse the valid document encoded before failure")
    await search.shutdown()
  }

  func testRejectsMalformedVectorsBeforeRanking() async throws {
    let store = RecordStore()
    _ = try await store.ingest(draft("record", app: "editor"), into: [])
    let search = RecordSemanticSearch(store: store, embedder: SemanticTestEmbedder(malformed: true))
    do {
      _ = try await search.search(.init(text: "intent"))
      XCTFail("Malformed vectors must fail")
    } catch RecordEmbeddingError.invalidOutput {}
    await search.shutdown()
  }

  func testRankingUsesTheBestDocumentWindowAndSignedSimilarity() async throws {
    let store = RecordStore()
    let best = try await store.ingest(draft("best", app: "editor"), into: [])
    let unrelated = try await store.ingest(draft("unrelated", app: "editor"), into: [])
    let opposite = try await store.ingest(draft("opposite", app: "editor"), into: [])
    let search = RecordSemanticSearch(store: store, embedder: RankingEmbedder())
    let result = try await search.search(.init(text: "intent"))
    XCTAssertEqual(result.records.map(\.id), [best.id, unrelated.id, opposite.id])
    await search.shutdown()
  }

  private func draft(_ text: String, app: String) -> RecordDraft {
    .init(
      payload: .text(text),
      provenance: .init(source: .init(kind: .systemClipboard), sourceBundleIdentifier: app))
  }
}

private actor SemanticTestEmbedder: RecordEmbeddingProvider {
  var documents: [String] = []
  var prepareCount = 0
  private let held: XCTestExpectation?
  private let malformed: Bool
  private let failDocumentCall: Int?
  private var continuation: CheckedContinuation<Void, Never>?
  init(held: XCTestExpectation? = nil, malformed: Bool = false, failDocumentCall: Int? = nil) {
    self.held = held
    self.malformed = malformed
    self.failDocumentCall = failDocumentCall
  }
  func prepare(downloadIfNeeded: Bool, progress: @escaping @Sendable (Double) -> Void) {
    prepareCount += 1
  }
  func embed(_ text: String, purpose: RecordEmbeddingPurpose) async throws -> RecordTextEmbedding {
    if purpose == .query, let held {
      await withCheckedContinuation { continuation in
        self.continuation = continuation
        held.fulfill()
      }
    }
    if purpose == .document {
      documents.append(text)
      if documents.count == failDocumentCall { throw RecordEmbeddingError.invalidOutput }
    }
    var vector = [Float](repeating: 0, count: malformed ? 2 : 1_024)
    vector[0] = 1
    return .init(vectors: [vector], coverageLimited: false)
  }
  func resume() {
    continuation?.resume()
    continuation = nil
  }
  func shutdown() { resume() }
}

private struct RankingEmbedder: RecordEmbeddingProvider {
  func prepare(downloadIfNeeded: Bool, progress: @escaping @Sendable (Double) -> Void) {}
  func embed(_ text: String, purpose: RecordEmbeddingPurpose) async throws -> RecordTextEmbedding {
    let positive = [Float](repeating: 1.0 / 32, count: 1_024)
    let negative = positive.map { -$0 }
    let vectors: [[Float]]
    if purpose == .query {
      vectors = [positive]
    } else if text.hasPrefix("best") {
      vectors = [negative, positive]
    } else if text.hasPrefix("unrelated") {
      vectors = [(0..<1_024).map { $0.isMultiple(of: 2) ? positive[$0] : negative[$0] }]
    } else {
      vectors = [negative]
    }
    return .init(vectors: vectors, coverageLimited: false)
  }
  func shutdown() {}
}
