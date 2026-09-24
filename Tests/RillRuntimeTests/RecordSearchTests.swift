import Foundation
import Testing
@testable import RillCore
@testable import RillRuntime

struct RecordSearchTests {
  @Test func fallbackPaginationKeepsMatchingModeAndRejectsChangedCatalogOrQuery() async throws {
    let store = RecordStore()
    for index in 0..<7 { _ = try await store.ingest(draft("剪贴板内容 \(index)"), into: []) }
    let query = RecordQuery(text: "jiantieban")
    let first = try await RecordSearch.page(in: store, query: query, limit: 3)
    let cursor = try #require(first.cursor)
    #expect(cursor.matching == .approximate)
    let second = try await RecordSearch.page(in: store, query: query, after: cursor, limit: 3)
    let third = try await RecordSearch.page(in: store, query: query, after: second.cursor, limit: 3)
    #expect(Set((first.records + second.records + third.records).map(\.id)).count == 7)
    #expect(third.cursor == nil)
    await #expect(throws: RecordStoreError.membershipChanged) {
      try await RecordSearch.page(in: store, query: .init(text: "other"), after: cursor)
    }
    _ = try await store.ingest(draft("new record"), into: [])
    await #expect(throws: RecordStoreError.membershipChanged) {
      try await RecordSearch.page(in: store, query: query, after: cursor)
    }
  }

  @Test func literalWinsEvenWhenItAppearsAfterEmptyScanPages() async throws {
    let store = RecordStore()
    let literal = try await store.ingest(draft("jiantieban literal"), into: [])
    _ = try await store.ingest(draft("剪贴板"), into: [])
    for index in 0..<270 { _ = try await store.ingest(draft("unrelated \(index)"), into: []) }
    let page = try await RecordSearch.page(in: store, query: .init(text: "jiantieban"))
    #expect(page.records.map(\.id) == [literal.id])
    #expect(page.cursor == nil)
  }

  @Test func cancellationBetweenEmptyPagesStopsScanning() async throws {
    let fetch = HeldSearchPage()
    let task = Task {
      try await RecordSearch.page(query: .init(text: "missing"), limit: 20, fetch: fetch.fetch)
    }
    await fetch.waitUntilEntered()
    task.cancel()
    await fetch.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await fetch.calls == 1)
  }

  private func draft(_ text: String) -> RecordDraft {
    .init(payload: .text(text), provenance: .init(source: .init(kind: .systemClipboard)))
  }
}

private actor HeldSearchPage {
  var calls = 0
  private var pending: CheckedContinuation<RecordQueryPage, Never>?
  private var entered: CheckedContinuation<Void, Never>?
  func fetch(_ query: RecordQuery, _ offset: Int, _ limit: Int) async -> RecordQueryPage {
    calls += 1
    return await withCheckedContinuation {
      pending = $0
      entered?.resume(); entered = nil
    }
  }
  func waitUntilEntered() async {
    if pending != nil { return }
    await withCheckedContinuation { entered = $0 }
  }
  func release() { pending?.resume(returning: .init(revision: 1, records: [], nextOffset: 256)); pending = nil }
}
