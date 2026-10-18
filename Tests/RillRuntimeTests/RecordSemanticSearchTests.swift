import XCTest

@testable import RillCore
@testable import RillWorkflows
@testable import RillRecords
@testable import RillKnowledge

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
    let combiningGrapheme = "a" + String(repeating: "\u{301}", count: 30_000)
    XCTAssertEqual(combiningGrapheme.count, 1)
    _ = try await store.ingest(draft(combiningGrapheme, app: "editor"), into: [])
    _ = try await store.ingest(
      draft(String(repeating: "\u{1}", count: 30_000), app: "editor"), into: [])
    let embedder = SemanticTestEmbedder()
    let search = RecordSemanticSearch(store: store, embedder: embedder)
    let result = try await search.search(.init(text: "intent"))
    XCTAssertEqual(result.limitedRecordCount, 3)
    let inputs = await embedder.documents
    XCTAssertEqual(inputs.count, 3)
    XCTAssertTrue(inputs.contains { $0.unicodeScalars.contains("\u{301}") })
    for input in inputs {
      XCTAssertLessThanOrEqual(input.utf8.count, 40 * 1_024)
      XCTAssertLessThanOrEqual(try JSONEncoder().encode(input).count, 48 * 1_024)
      XCTAssertFalse(input.unicodeScalars.contains("\u{FFFD}"))
    }
    await search.shutdown()
  }

  func testShortAndExactBudgetDocumentsReachTheEmbedderUnchanged() async throws {
    // searchableText appends two newlines and the six-byte bundle ID below.
    for body in ["Keep \"quoted\" text\n中文🙂 and \\paths", String(repeating: "a", count: 40 * 1_024 - 8)] {
      let store = RecordStore()
      _ = try await store.ingest(draft(body, app: "editor"), into: [])
      let embedder = SemanticTestEmbedder()
      let search = RecordSemanticSearch(store: store, embedder: embedder)
      let result = try await search.search(.init(text: "intent"))
      let inputs = await embedder.documents
      XCTAssertEqual(inputs, [body + "\n\neditor"])
      XCTAssertEqual(result.limitedRecordCount, 0)
      await search.shutdown()
    }
  }

  func testHeadCenterAndTailRemainSearchableAfterRawAndJSONSampling() async throws {
    for (filler, count, jsonLimited) in [("a", 45_000, false), ("\u{1}", 15_000, true), ("\u{1}", 45_000, true)] {
      let padding = String(repeating: filler, count: count)
      let body = "HEAD_MARK\n" + padding + "\nMIDDLE_MARK\n" + padding + "\nTAIL_MARK"
      let store = RecordStore()
      let desired = try await store.ingest(draft(body, app: "editor"), into: [])
      _ = try await store.ingest(draft("unrelated record", app: "editor"), into: [])
      let embedder = CoverageTestEmbedder()
      let search = RecordSemanticSearch(store: store, embedder: embedder)
      for query in ["middle", "tail"] {
        let result = try await search.search(.init(text: query))
        XCTAssertEqual(result.records.first?.id, desired.id)
        XCTAssertEqual(result.limitedRecordCount, 1)
      }
      let inputs = await embedder.documents
      XCTAssertEqual(inputs.count, 2, "The second query must reuse both document embeddings")
      let input = try XCTUnwrap(inputs.first { $0.hasPrefix("HEAD_MARK") })
      XCTAssertTrue(input.contains("MIDDLE_MARK"))
      XCTAssertTrue(input.contains("TAIL_MARK"))
      XCTAssertLessThanOrEqual(input.utf8.count, jsonLimited ? 8_191 : 40 * 1_024)
      XCTAssertLessThanOrEqual(try JSONEncoder().encode(input).count, 48 * 1_024)
      XCTAssertFalse(input.unicodeScalars.contains("\u{FFFD}"))
      await search.shutdown()
    }
  }

  func testSamplingAndProviderCoverageFlagsSurviveWarmCache() async throws {
    for sampled in [false, true] {
      for providerLimited in [false, true] {
        let store = RecordStore()
        let body = sampled ? String(repeating: "a", count: 40 * 1_024 + 1) : "short"
        _ = try await store.ingest(draft(body, app: "editor"), into: [])
        let embedder = SemanticTestEmbedder(coverageLimited: providerLimited)
        let search = RecordSemanticSearch(store: store, embedder: embedder)
        for _ in 0..<2 {
          let result = try await search.search(.init(text: "intent"))
          XCTAssertEqual(result.limitedRecordCount, sampled || providerLimited ? 1 : 0)
        }
        let inputs = await embedder.documents
        XCTAssertEqual(inputs.count, 1)
        await search.shutdown()
      }
    }
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
  private let coverageLimited: Bool
  private var continuation: CheckedContinuation<Void, Never>?
  init(held: XCTestExpectation? = nil, malformed: Bool = false, failDocumentCall: Int? = nil, coverageLimited: Bool = false) {
    self.held = held
    self.malformed = malformed
    self.failDocumentCall = failDocumentCall
    self.coverageLimited = coverageLimited
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
    return .init(vectors: [vector], coverageLimited: purpose == .document && coverageLimited)
  }
  func resume() {
    continuation?.resume()
    continuation = nil
  }
  func shutdown() { resume() }
}

private actor CoverageTestEmbedder: RecordEmbeddingProvider {
  var documents: [String] = []
  func prepare(downloadIfNeeded: Bool, progress: @escaping @Sendable (Double) -> Void) {}
  func embed(_ text: String, purpose: RecordEmbeddingPurpose) async throws -> RecordTextEmbedding {
    func vector(_ index: Int) -> [Float] {
      var value = [Float](repeating: 0, count: 1_024)
      value[index] = 1
      return value
    }
    if purpose == .query {
      return .init(vectors: [vector(text == "middle" ? 1 : 2)], coverageLimited: false)
    }
    documents.append(text)
    let matches = ["MIDDLE_MARK", "TAIL_MARK"].enumerated().compactMap { index, marker in
      text.contains(marker) ? vector(index + 1) : nil
    }
    return .init(vectors: matches.isEmpty ? [vector(0)] : matches, coverageLimited: false)
  }
  func shutdown() {}
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
