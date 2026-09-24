import Foundation
import RillCore

/// A cursor is tied to the query, matching mode and catalog that produced it.
public struct RecordSearchCursor: Sendable, Equatable {
  public let query: RecordQuery
  public let matching: RecordQueryMatching
  public let revision: UInt64
  public let offset: Int

  public init(query: RecordQuery, matching: RecordQueryMatching, revision: UInt64, offset: Int) {
    self.query = query
    self.matching = matching
    self.revision = revision
    self.offset = offset
  }
}

public struct RecordSearchPage: Sendable {
  public let revision: UInt64
  public let records: [RecordSummary]
  public let cursor: RecordSearchCursor?
  public var nextOffset: Int? { cursor?.offset }

  public init(revision: UInt64, records: [RecordSummary], cursor: RecordSearchCursor?) {
    self.revision = revision
    self.records = records
    self.cursor = cursor
  }
}

/// Shared by global search and the quick panel; RecordStore owns all content and matching.
public enum RecordSearch {
  public static func page(
    in store: RecordStore, query: RecordQuery, after cursor: RecordSearchCursor? = nil,
    limit: Int = 50
  ) async throws -> RecordSearchPage {
    try await page(query: query, after: cursor, limit: limit) { query, offset, limit in
      try await store.query(query, offset: offset, limit: limit)
    }
  }

  static func page(
    query: RecordQuery, after cursor: RecordSearchCursor? = nil, limit: Int,
    fetch: @Sendable (RecordQuery, Int, Int) async throws -> RecordQueryPage
  ) async throws -> RecordSearchPage {
    guard limit > 0, cursor == nil || cursor?.query == query else {
      throw RecordStoreError.membershipChanged
    }
    var scanQuery = query
    scanQuery.matching = cursor?.matching ?? .literal
    var offset = cursor?.offset ?? 0
    var revision = cursor?.revision
    var matches: [RecordSummary] = []
    while true {
      try Task.checkCancellation()
      let page = try await fetch(scanQuery, offset, limit - matches.count)
      try Task.checkCancellation()
      if let revision, revision != page.revision { throw RecordStoreError.membershipChanged }
      revision = page.revision
      matches.append(contentsOf: page.records)
      if let next = page.nextOffset {
        if matches.count < limit { offset = next; continue }
        return RecordSearchPage(revision: page.revision, records: matches,
          cursor: .init(query: query, matching: scanQuery.matching, revision: page.revision, offset: next))
      }
      if cursor == nil, matches.isEmpty, scanQuery.matching == .literal,
        !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        scanQuery.matching = .approximate
        offset = 0
        continue
      }
      return RecordSearchPage(revision: page.revision, records: matches, cursor: nil)
    }
  }
}
