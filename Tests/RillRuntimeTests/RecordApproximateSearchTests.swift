import XCTest

@testable import RillCore
@testable import RillWorkflows
@testable import RillRecords
@testable import RillKnowledge

final class RecordApproximateSearchTests: XCTestCase {
  func testFallbackPreservesFiltersAndReadsFreshMetadata() async throws {
    let store = RecordStore()
    let collection = try await store.createCollection(name: "Selected")
    let selected = try await store.ingest(draft("剪贴板 worktree"), into: [collection.id])
    _ = try await store.updateMetadata(recordID: selected.id, tags: ["重要"], isPinned: true)
    _ = try await store.ingest(draft("剪贴板 worktree", app: "other"), into: [collection.id])
    _ = try await store.ingest(draft("剪贴板 worktree outside"), into: [])
    let literal = try await store.query(.init(text: "jtb"))
    XCTAssertTrue(literal.records.isEmpty)
    let query = RecordQuery(
      text: "jtb worktere zhongyao", collectionID: collection.id,
      sourceBundleIdentifier: "editor", kind: .text, pinnedOnly: true, matching: .approximate)
    let result = try await store.query(query)
    XCTAssertEqual(result.records.map(\.id), [selected.id])
    _ = try await store.updateMetadata(recordID: selected.id, tags: ["其他"])
    let afterTagChange = try await store.query(query)
    XCTAssertTrue(afterTagChange.records.isEmpty)
    let imageFilter = try await store.query(.init(text: "jtb", kind: .image, matching: .approximate))
    XCTAssertTrue(imageFilter.records.isEmpty)
    _ = try await store.updateMetadata(recordID: selected.id, isPinned: false)
    let pinFilter = try await store.query(.init(text: "jtb", pinnedOnly: true, matching: .approximate))
    XCTAssertTrue(pinFilter.records.isEmpty)
  }

  func testCachedPayloadDoesNotOutliveRecordAndFileNamesAreSearchable() async throws {
    let store = RecordStore()
    let file = try await store.ingest(
      .init(payload: .files([URL(fileURLWithPath: "/tmp/剪贴板报告.pdf")]),
        provenance: .init(source: .init(kind: .systemClipboard))), into: [])
    let query = RecordQuery(text: "jiantieban", kind: .files, matching: .approximate)
    let before = try await store.query(query)
    XCTAssertEqual(before.records.map(\.id), [file.id])
    let plan = try await store.prepareCleanup(scope: .record(file.id))
    _ = try await store.confirmCleanup(plan)
    let after = try await store.query(query)
    XCTAssertTrue(after.records.isEmpty)
    let replacement = try await store.ingest(draft("https://example.com/reference"), into: [])
    let exact = try await store.query(.init(text: "https://example.com/reference", matching: .approximate))
    XCTAssertEqual(exact.records.map(\.id), [replacement.id])
  }

  private func draft(_ text: String, app: String = "editor") -> RecordDraft {
    .init(payload: .text(text),
      provenance: .init(source: .init(kind: .systemClipboard), sourceBundleIdentifier: app))
  }
}
