import XCTest

@testable import RillCore
@testable import RillWorkflows
@testable import RillRecords
@testable import RillKnowledge

final class RecordSemanticCacheBudgetTests: XCTestCase {
  func testWarmPassReusesResidentVectorsWhenHistoryJustExceedsCacheBudget() async throws {
    let store = RecordStore()
    for index in 0..<2_050 {
      _ = try await store.ingest(draft("long record \(index)"), into: [])
    }
    let embedder = CacheBudgetEmbedder(documentWindowCount: 16)
    let search = RecordSemanticSearch(store: store, embedder: embedder)
    let expected = try await store.catalogSnapshot().records.prefix(10).map(\.id)
    let first = try await search.search(.init(text: "intent"))
    let coldCalls = await embedder.documentCalls
    XCTAssertEqual(coldCalls, 2_050)
    XCTAssertEqual(first.records.map(\.id), expected)
    for _ in 0..<2 {
      let before = await embedder.documentCalls
      let next = try await search.search(.init(text: "intent"))
      let after = await embedder.documentCalls
      print(
        "SEMANTIC_CACHE_BUDGET additional_document_encodes=\(after - before) resident_limit=2048 records=2050"
      )
      XCTAssertEqual(
        after - before, 2,
        "Score resident vectors before admitting missing records; avoid cyclic FIFO eviction")
      XCTAssertEqual(
        next.records.map(\.id), expected,
        "Cache evaluation order must not change recency tie-breaking")
    }
    await search.shutdown()
  }

  func testCancellingAQueryKeepsValidVectorsForTheNextQuery() async throws {
    let store = RecordStore()
    for index in 0..<12 { _ = try await store.ingest(draft("record \(index)"), into: []) }
    let embedder = CacheBudgetEmbedder(documentWindowCount: 1)
    let search = RecordSemanticSearch(store: store, embedder: embedder)
    _ = try await search.search(.init(text: "first"))
    let entered = expectation(description: "query encode held")
    await embedder.holdNextQuery(entered)
    let cancelled = Task { try await search.search(.init(text: "second")) }
    await fulfillment(of: [entered], timeout: 2)
    cancelled.cancel()
    await embedder.resume()
    do {
      _ = try await cancelled.value
      XCTFail("Cancelled query must not publish")
    } catch is CancellationError {}
    _ = try await search.search(.init(text: "third"))
    let calls = await embedder.documentCalls
    print("SEMANTIC_CANCEL_REUSE document_encodes=\(calls) records=12")
    XCTAssertEqual(calls, 12, "Cancelling query inference must not force a full history re-encode")
    await search.shutdown()
  }

  private func draft(_ text: String) -> RecordDraft {
    .init(payload: .text(text), provenance: .init(source: .init(kind: .systemClipboard)))
  }
}

private actor CacheBudgetEmbedder: RecordEmbeddingProvider {
  var documentCalls = 0
  private let documentWindowCount: Int
  private var entered: XCTestExpectation?
  private var gate: CheckedContinuation<Void, Never>?
  init(documentWindowCount: Int) { self.documentWindowCount = documentWindowCount }
  func prepare(downloadIfNeeded: Bool, progress: @escaping @Sendable (Double) -> Void) {}
  func embed(_ text: String, purpose: RecordEmbeddingPurpose) async -> RecordTextEmbedding {
    if purpose == .query, let entered {
      self.entered = nil
      await withCheckedContinuation { gate in
        self.gate = gate
        entered.fulfill()
      }
    }
    if purpose == .document { documentCalls += 1 }
    var vector = [Float](repeating: 0, count: 1_024)
    vector[0] = 1
    return .init(
      vectors: Array(repeating: vector, count: purpose == .query ? 1 : documentWindowCount),
      coverageLimited: false)
  }
  func holdNextQuery(_ entered: XCTestExpectation) { self.entered = entered }
  func resume() {
    gate?.resume()
    gate = nil
  }
  func shutdown() { resume() }
}
