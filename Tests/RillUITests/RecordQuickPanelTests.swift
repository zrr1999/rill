import XCTest

@testable import RillCore
@testable import RillRuntime
@testable import RillUI

@MainActor
final class RecordQuickPanelTests: XCTestCase {
  func testLiteralMatchBeyondFirstScanBatchWinsOverRecentApproximateMatches() async throws {
    let store = RecordStore()
    let exact = try await store.ingest(draft("jtb exact", app: "editor"), into: [])
    for index in 0..<260 {
      _ = try await store.ingest(draft("剪贴板 \(index)", app: "editor"), into: [])
    }
    let panel = RecordQuickPanelModel(store: store)
    defer { panel.stop() }
    panel.searchText = "jtb"
    await settle(panel)
    XCTAssertEqual(panel.results.map(\.id), [exact.id])
    XCTAssertEqual(panel.selectedID, exact.id)
  }

  func testApproximatePaginationKeepsModeAndSelection() async throws {
    let store = RecordStore()
    var ids: [RecordID] = []
    for index in 0..<60 {
      let record = try await store.ingest(draft("剪贴板 worktree \(index)", app: "editor"), into: [])
      ids.append(record.id)
    }
    let panel = RecordQuickPanelModel(store: store)
    defer { panel.stop() }
    panel.searchText = "jtb worktere"
    await settle(panel)
    XCTAssertEqual(panel.results.map(\.id), Array(ids.reversed().prefix(50)))
    let selected = panel.results[10].id
    panel.selectedID = selected
    panel.loadMore()
    await settle(panel)
    XCTAssertEqual(panel.results.map(\.id), Array(ids.reversed()))
    XCTAssertEqual(panel.selectedID, selected)
    panel.searchText = "jtb missing"
    panel.searchText = "worktree 59"
    await settle(panel)
    XCTAssertEqual(panel.results.map(\.id), [ids[59]])
    XCTAssertEqual(panel.selectedID, ids[59])
  }

  func testQuickPanelSearchSelectionAndFiltersAreIndependentFromManagement() async throws {
    let store = RecordStore()
    let first = try await store.ingest(draft("中文 找到我", app: "com.example.first"), into: [])
    let second = try await store.ingest(
      draft("another record", app: "com.example.second"), into: [])
    let main = RecordWorkspaceModel(store: store)
    await main.refresh()
    main.selectedRecordID = second.id
    main.searchText = "another"
    let panel = main.makeQuickPanelModel()
    panel.start(sourceBundleIdentifier: "com.example.first")
    defer { panel.stop() }
    await settle(panel)
    XCTAssertEqual(panel.results.map(\.id), [second.id, first.id])
    panel.currentAppOnly = true
    await settle(panel)
    XCTAssertEqual(panel.results.map(\.id), [first.id])
    panel.searchText = "不存在"
    panel.searchText = "中文 我"
    await settle(panel)
    XCTAssertEqual(panel.selectedID, first.id)
    XCTAssertEqual(main.selectedRecordID, second.id)
    XCTAssertEqual(main.searchText, "another")
    panel.stop()
    panel.start(sourceBundleIdentifier: nil)
    await settle(panel)
    XCTAssertEqual(panel.searchText, "")
    XCTAssertFalse(panel.currentAppOnly)
    XCTAssertEqual(panel.results.count, 2)
  }

  func testCleanupCancelAndStaleConfirmationKeepRecordsUntilNewConfirmation() async throws {
    let store = RecordStore()
    let first = try await store.ingest(draft("first", app: "editor"), into: [])
    let cleanup = RecordCleanupModel(store: store)
    await cleanup.request()
    XCTAssertEqual(cleanup.plan?.recordIDs, [first.id])
    cleanup.cancel()
    let cancelled = try await store.catalogSnapshot()
    XCTAssertEqual(cancelled.records.count, 1)
    await cleanup.request()
    let second = try await store.ingest(draft("second", app: "editor"), into: [])
    await cleanup.confirm()
    XCTAssertEqual(cleanup.message, .cleanupChanged)
    let unchanged = try await store.catalogSnapshot()
    XCTAssertEqual(unchanged.records.count, 2)
    XCTAssertEqual(cleanup.plan?.recordIDs, [first.id])
    XCTAssertEqual(cleanup.plan?.protectedCount, 1)
    await cleanup.confirm()
    let confirmed = try await store.catalogSnapshot()
    XCTAssertEqual(confirmed.records.map(\.id), [second.id])
    XCTAssertNil(cleanup.plan)
  }

  func testInFlightDeletionReportsWhyNoConfirmationCanBeOpened() async throws {
    let store = RecordStore()
    let record = try await store.ingest(draft("being delivered", app: "editor"), into: [])
    let lease = try await store.beginReuse(
      .init(recordID: record.id, metadataRevision: record.metadata.revision),
      sink: .focusedApplication)
    let cleanup = RecordCleanupModel(store: store)
    await cleanup.request(scope: .record(record.id))
    XCTAssertNil(cleanup.plan)
    XCTAssertEqual(cleanup.message, .recordInUse)
    try await store.cancelDelivery(leaseID: lease.id)
    await cleanup.request(scope: .record(record.id))
    XCTAssertNotNil(cleanup.plan)
    XCTAssertNil(cleanup.message)
  }

  func testShutdownSealRejectsConfirmingAPreviouslyReviewedPlan() async throws {
    let store = RecordStore()
    let record = try await store.ingest(draft("keep through shutdown", app: "editor"), into: [])
    let cleanup = RecordCleanupModel(store: store)
    await cleanup.request()
    cleanup.seal()
    await cleanup.confirm()
    await cleanup.shutdown()
    let retained = try await store.catalogSnapshot()
    XCTAssertEqual(retained.records.map(\.id), [record.id])
  }

  private func draft(_ text: String, app: String) -> RecordDraft {
    .init(
      payload: .text(text),
      provenance: .init(source: .init(kind: .systemClipboard), sourceBundleIdentifier: app))
  }
  private func settle(_ model: RecordQuickPanelModel) async {
    // Startup has an observation hop before it schedules its first query.
    try? await Task.sleep(for: .milliseconds(20))
    for _ in 0..<100 {
      if !model.isSearching { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("The quick panel did not finish its bounded query")
  }
}
