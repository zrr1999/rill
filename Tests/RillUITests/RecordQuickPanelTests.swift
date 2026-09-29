@testable import RillRecords
import XCTest

@testable import RillCore
@testable import RillUI

@MainActor
final class RecordQuickPanelTests: XCTestCase {
  func testCollectionScopeFiltersResultsWithoutChangingManagementSelection() async throws {
    let store = RecordStore()
    let collection = try await store.createCollection(name: "Clipboard", preset: .list)
    let inside = try await store.ingest(draft("design notes", app: "editor"), into: [collection.id])
    let outside = try await store.ingest(draft("design outside", app: "editor"), into: [])
    let workspace = RecordWorkspaceModel(store: store)
    await workspace.refresh()
    workspace.selectedRecordID = outside.id
    let panel = workspace.makeQuickPanelModel()
    panel.start(sourceBundleIdentifier: nil)
    await panel.waitForSearch()
    panel.setCollection(collection.id)
    panel.setSearchText("design")
    await panel.waitForSearch()
    XCTAssertEqual(panel.results.map(\.id), [inside.id])
    XCTAssertEqual(panel.selectedID, inside.id)
    XCTAssertEqual(workspace.selectedRecordID, outside.id)
    panel.setCollection(nil)
    await panel.waitForSearch()
    XCTAssertEqual(Set(panel.results.map(\.id)), Set([inside.id, outside.id]))
    XCTAssertEqual(panel.selectedID, inside.id)
    await panel.shutdown()
    await workspace.shutdown()
  }

  func testLiteralMatchBeyondFirstScanBatchWinsOverRecentApproximateMatches() async throws {
    let store = RecordStore()
    let exact = try await store.ingest(draft("jtb exact", app: "editor"), into: [])
    for index in 0..<260 {
      _ = try await store.ingest(draft("剪贴板 \(index)", app: "editor"), into: [])
    }
    let panel = RecordQuickPanelModel(store: store)
    defer { panel.stop() }
    panel.setSearchText("jtb")
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
    panel.setSearchText("jtb worktere")
    await settle(panel)
    XCTAssertEqual(panel.results.map(\.id), Array(ids.reversed().prefix(50)))
    let selected = panel.results[10].id
    panel.select(selected)
    panel.loadMore()
    await settle(panel)
    XCTAssertEqual(panel.results.map(\.id), Array(ids.reversed()))
    XCTAssertEqual(panel.selectedID, selected)
    panel.setSearchText("jtb missing")
    panel.setSearchText("worktree 59")
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
    main.setSearchText("another")
    let panel = main.makeQuickPanelModel()
    panel.start(sourceBundleIdentifier: "com.example.first")
    defer { panel.stop() }
    await settle(panel)
    XCTAssertEqual(panel.results.map(\.id), [second.id, first.id])
    panel.setCurrentAppOnly(true)
    await settle(panel)
    XCTAssertEqual(panel.results.map(\.id), [first.id])
    panel.setSearchText("不存在")
    panel.setSearchText("中文 我")
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

  func testResidentPanelRefreshesSourceWithoutClearingSearch() async throws {
    let store = RecordStore()
    let first = try await store.ingest(draft("shared first", app: "com.example.first"), into: [])
    let second = try await store.ingest(draft("shared second", app: "com.example.second"), into: [])
    let panel = RecordQuickPanelModel(store: store)
    panel.start(sourceBundleIdentifier: nil)
    defer { panel.stop() }
    panel.setSearchText("shared")
    await settle(panel)
    panel.select(first.id)
    panel.updateSourceApplication("com.example.first")
    XCTAssertTrue(panel.canFilterCurrentApp)
    XCTAssertEqual(panel.searchText, "shared")
    XCTAssertEqual(panel.selectedID, first.id)
    panel.setCurrentAppOnly(true)
    await settle(panel)
    XCTAssertEqual(panel.results.map(\.id), [first.id])
    panel.updateSourceApplication("com.example.second")
    await settle(panel)
    XCTAssertEqual(panel.results.map(\.id), [second.id])
    XCTAssertEqual(panel.searchText, "shared")
    panel.updateSourceApplication(nil)
    await settle(panel)
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
    await model.waitForSearch()
  }
}
