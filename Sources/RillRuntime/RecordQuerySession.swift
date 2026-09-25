import RillCore

/// A cursor belongs to one query and one catalog revision. Consumers keep their
/// own result limit and navigation, but never combine pages from different graphs.
public struct RecordQuerySession: Sendable {
  public let query: RecordQuery
  public private(set) var revision: UInt64?
  public private(set) var nextOffset: Int?

  public init(query: RecordQuery, offset: Int = 0, revision: UInt64? = nil) {
    self.query = query
    self.nextOffset = max(0, offset)
    self.revision = revision
  }

  public mutating func next(in store: RecordStore, limit: Int) async throws -> RecordQueryPage? {
    try Task.checkCancellation()
    guard let nextOffset else { return nil }
    let page = try await store.query(query, offset: nextOffset, limit: limit)
    try Task.checkCancellation()
    if let revision, revision != page.revision { throw RecordStoreError.membershipChanged }
    revision = page.revision
    self.nextOffset = page.nextOffset
    return page
  }
}
