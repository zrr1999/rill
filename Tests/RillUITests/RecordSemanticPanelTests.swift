import XCTest

@testable import RillCore
@testable import RillWorkflows
@testable import RillRecords
@testable import RillKnowledge
@testable import RillUI

@MainActor
final class RecordSemanticPanelTests: XCTestCase {
  func testLateCandidatesKeepSelectionAndJoinKeyboardNavigation() async throws {
    let (store, first, second) = try await fixture()
    let entered = expectation(description: "semantic query entered")
    let embedder = PanelEmbeddingFixture(held: entered)
    let search = RecordSemanticSearch(store: store, embedder: embedder)
    let panel = RecordQuickPanelModel(store: store, semanticSearch: search)
    panel.setSearchText("keyword")
    await settle { !panel.isSearching }
    XCTAssertEqual(panel.selectedID, first)
    panel.searchByMeaning()
    await fulfillment(of: [entered], timeout: 2)
    XCTAssertEqual(panel.results.map(\.id), [first])
    await embedder.resume()
    await settle { panel.semanticState == .ready }
    XCTAssertEqual(panel.selectedID, first)
    XCTAssertEqual(panel.additionalSemanticResults.map(\.id), [second])
    panel.moveSelection(1)
    XCTAssertEqual(panel.selectedID, second)
    XCTAssertEqual(panel.subject(at: 1)?.recordID, second)
    panel.setSearchText("unrelated")
    XCTAssertTrue(panel.semanticResults.isEmpty)
    await panel.shutdown()
    await search.shutdown()
  }

  func testDownloadRequiresExplicitSecondRequest() async throws {
    let (store, _, _) = try await fixture()
    let embedder = PanelEmbeddingFixture(missing: true)
    let search = RecordSemanticSearch(store: store, embedder: embedder)
    let panel = RecordQuickPanelModel(store: store, semanticSearch: search)
    panel.setSearchText("intent")
    await settle { !panel.isSearching }
    panel.searchByMeaning()
    await settle { panel.semanticState == .needsModel }
    let before = await embedder.downloadFlags
    XCTAssertEqual(before, [false])
    panel.searchByMeaning(downloadIfNeeded: true)
    await settle { panel.semanticState == .ready }
    let after = await embedder.downloadFlags
    XCTAssertEqual(after, [false, true])
    await panel.shutdown()
    await search.shutdown()
  }

  func testQueryChangeAndShutdownDrainLateInferenceWithoutPublishing() async throws {
    let (store, _, _) = try await fixture()
    let entered = expectation(description: "semantic query entered")
    let embedder = PanelEmbeddingFixture(held: entered)
    let search = RecordSemanticSearch(store: store, embedder: embedder)
    let panel = RecordQuickPanelModel(store: store, semanticSearch: search)
    panel.setSearchText("intent")
    await settle { !panel.isSearching }
    panel.searchByMeaning()
    await fulfillment(of: [entered], timeout: 2)
    panel.setSearchText("unrelated")
    var didShutDown = false
    let started = expectation(description: "shutdown started")
    let shutdown = Task {
      started.fulfill()
      await panel.shutdown()
      didShutDown = true
    }
    await fulfillment(of: [started], timeout: 2)
    XCTAssertFalse(didShutDown)
    await embedder.resume()
    await shutdown.value
    XCTAssertTrue(didShutDown)
    XCTAssertTrue(panel.semanticResults.isEmpty)
    XCTAssertEqual(panel.semanticState, .idle)
    await search.shutdown()
  }

  private func fixture() async throws -> (RecordStore, RecordID, RecordID) {
    let store = RecordStore()
    let first = try await store.ingest(
      .init(
        payload: .text("keyword"),
        provenance: .init(source: .init(kind: .systemClipboard))), into: [])
    let second = try await store.ingest(
      .init(
        payload: .text("unrelated"),
        provenance: .init(source: .init(kind: .systemClipboard))), into: [])
    return (store, first.id, second.id)
  }

  private func settle(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    XCTAssertTrue(condition())
  }
}

actor PanelEmbeddingFixture: RecordEmbeddingProvider {
  var downloadFlags: [Bool] = []
  private let held: XCTestExpectation?
  private var missing: Bool
  private var continuation: CheckedContinuation<Void, Never>?
  init(held: XCTestExpectation? = nil, missing: Bool = false) {
    self.held = held
    self.missing = missing
  }
  func prepare(downloadIfNeeded: Bool, progress: @escaping @Sendable (Double) -> Void) throws {
    downloadFlags.append(downloadIfNeeded)
    if missing && !downloadIfNeeded { throw RecordEmbeddingError.modelUnavailable }
    missing = false
  }
  func embed(_ text: String, purpose: RecordEmbeddingPurpose) async -> RecordTextEmbedding {
    if purpose == .query, let held {
      await withCheckedContinuation { continuation in
        self.continuation = continuation
        held.fulfill()
      }
    }
    var vector = [Float](repeating: 0, count: 1_024)
    vector[0] = 1
    return .init(vectors: [vector], coverageLimited: false)
  }
  func resume() {
    continuation?.resume()
    continuation = nil
  }
  func shutdown() { resume() }
}
