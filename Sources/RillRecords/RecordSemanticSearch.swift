import Foundation
import RillCore

public struct RecordSemanticSearchResult: Sendable {
  public let records: [RecordSummary]
  public let limitedRecordCount: Int
}

public enum RecordSemanticSearchProgress: Sendable {
  case preparing(Double)
  case indexing(completed: Int, total: Int)
}

/// Derived vectors never become an authority for membership, filtering, or deletion.
public actor RecordSemanticSearch {
  private struct Cached: Sendable {
    let tags: [String]
    let embedding: RecordTextEmbedding
    var byteCount: Int { embedding.vectors.count * 1_024 * MemoryLayout<Float>.size }
  }
  private let store: RecordStore
  private let embedder: any RecordEmbeddingProvider
  private var cache: [RecordID: Cached] = [:]
  private var cacheOrder: [RecordID] = []
  private var cacheBytes = 0
  private var isClosed = false
  private var observationTask: Task<Void, Never>?
  private var activeSearchID: UUID?
  private var activeSearchTask: Task<RecordSemanticSearchResult, Error>?

  public init(store: RecordStore, embedder: any RecordEmbeddingProvider) {
    self.store = store
    self.embedder = embedder
  }

  public func search(
    _ query: RecordQuery, downloadIfNeeded: Bool = false,
    progress: @escaping @Sendable (RecordSemanticSearchProgress) -> Void = { _ in }
  ) async throws -> RecordSemanticSearchResult {
    guard !isClosed else { throw RecordEmbeddingError.unavailable }
    let previous = activeSearchTask
    previous?.cancel()
    let id = UUID()
    let task = Task { [weak self] in
      _ = await previous?.result
      try Task.checkCancellation()
      guard let self else { throw RecordEmbeddingError.unavailable }
      do {
        return try await self.performSearch(
          query, downloadIfNeeded: downloadIfNeeded, progress: progress)
      } catch {
        // An in-flight encode can finish after the catalog observer has pruned a deletion.
        // Reconcile those vectors without discarding the rest of a warm index.
        await self.pruneAfterFailure()
        throw error
      }
    }
    activeSearchID = id
    activeSearchTask = task
    defer {
      if activeSearchID == id {
        activeSearchID = nil
        activeSearchTask = nil
      }
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func performSearch(
    _ query: RecordQuery, downloadIfNeeded: Bool,
    progress: @escaping @Sendable (RecordSemanticSearchProgress) -> Void
  ) async throws -> RecordSemanticSearchResult {
    guard !isClosed else { throw RecordEmbeddingError.unavailable }
    let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.utf8.count <= 4_096 else { throw RecordEmbeddingError.invalidInput }
    // Exact resource addresses belong to the literal search path.
    if !text.contains(where: \.isWhitespace), text.hasPrefix("/") || text.contains("://") {
      return .init(records: [], limitedRecordCount: 0)
    }
    if observationTask == nil {
      observationTask = Task { [weak self, store] in
        do {
          for await snapshot in try await store.catalogStream() {
            guard !Task.isCancelled else { return }
            await self?.prune(snapshot)
          }
        } catch { await self?.clearCache() }
      }
    }
    let snapshot = try await store.catalogSnapshot()
    prune(snapshot)
    let records = snapshot.records.filter { record in
      record.header.kind != .image
        && (!query.pinnedOnly || record.metadata.isPinned)
        && (query.kind == nil || record.header.kind == query.kind)
        && (query.sourceBundleIdentifier == nil
          || record.header.provenance.sourceBundleIdentifier == query.sourceBundleIdentifier)
        && (query.collectionID == nil
          || record.memberships.contains { $0.collectionID == query.collectionID })
    }
    guard !records.isEmpty else { return .init(records: [], limitedRecordCount: 0) }
    try await embedder.prepare(downloadIfNeeded: downloadIfNeeded) { progress(.preparing($0)) }
    try check()
    let queryEmbedding = try await embedder.embed(text, purpose: .query)
    try check()
    guard let queryVector = queryEmbedding.vectors.first, valid(queryEmbedding) else {
      throw RecordEmbeddingError.invalidOutput
    }
    let anchors = identifierAnchors(text)
    var ranked: [(record: RecordSummary, score: Float, ordinal: Int)] = []
    var limitedCount = 0
    // Score resident entries before new admissions can evict them. Otherwise a history just
    // larger than the cache continually evicts the next entry and re-encodes every document.
    let resident = records.indices.filter { cache[records[$0].id] != nil }
    let missing = records.indices.filter { cache[records[$0].id] == nil }
    for (position, index) in (resident + missing).enumerated() {
      let record = records[index]
      try check()
      if position.isMultiple(of: 32) {
        await Task.yield()
        try check()
      }
      var document: String?
      if !anchors.isEmpty {
        document = try await searchableText(record)
        try check()
        guard let document, anchors.isSubset(of: Set(identifierAnchors(document))) else {
          reportProgress(position + 1, total: records.count, progress: progress)
          continue
        }
      }
      let embedding: RecordTextEmbedding
      if let cached = cache[record.id], cached.tags == record.metadata.tags {
        embedding = cached.embedding
      } else {
        if document == nil { document = try await searchableText(record) }
        try check()
        guard let document else { throw RecordStoreError.membershipChanged }
        let bytes = document.utf8
        let clipped = bytes.count > 40 * 1_024
        // UTF-8 decoding replaces a split boundary scalar; the request still fits the worker frame.
        var input =
          clipped
          ? String(decoding: bytes.prefix(30 * 1_024), as: UTF8.self) + "\n…\n"
            + String(decoding: bytes.suffix(10 * 1_024), as: UTF8.self)
          : document
        var frameLimited = false
        if try JSONEncoder().encode(input).count > 48 * 1_024 {
          input =
            String(decoding: input.utf8.prefix(6 * 1_024), as: UTF8.self) + "\n…\n"
            + String(decoding: input.utf8.suffix(2 * 1_024), as: UTF8.self)
          frameLimited = true
        }
        let value = try await embedder.embed(input, purpose: .document)
        try check()
        guard valid(value) else { throw RecordEmbeddingError.invalidOutput }
        embedding = .init(
          vectors: value.vectors, coverageLimited: clipped || frameLimited || value.coverageLimited)
        cacheEmbedding(embedding, for: record)
      }
      if embedding.coverageLimited { limitedCount += 1 }
      let score =
        embedding.vectors.map { vector -> Float in
          var products = SIMD4<Float>(repeating: 0)
          // Both vectors have already passed the fixed 1,024-dimension contract.
          for offset in stride(from: 0, to: queryVector.count, by: 4) {
            products += SIMD4(queryVector[offset], queryVector[offset + 1], queryVector[offset + 2], queryVector[offset + 3])
              * SIMD4(vector[offset], vector[offset + 1], vector[offset + 2], vector[offset + 3])
          }
          return products.sum()
        }.max() ?? -.infinity
      ranked.append((record, score, index))
      reportProgress(position + 1, total: records.count, progress: progress)
    }
    try check()
    let current = try await store.catalogSnapshot()
    try check()
    guard current.revision == snapshot.revision else {
      throw RecordStoreError.membershipChanged
    }
    ranked.sort { $0.score == $1.score ? $0.ordinal < $1.ordinal : $0.score > $1.score }
    return .init(records: ranked.prefix(10).map(\.record), limitedRecordCount: limitedCount)
  }

  public func shutdown() async {
    isClosed = true
    activeSearchTask?.cancel()
    await embedder.shutdown()
    _ = await activeSearchTask?.result
    observationTask?.cancel()
    await observationTask?.value
    observationTask = nil
    clearCache()
  }

  deinit {
    observationTask?.cancel()
    activeSearchTask?.cancel()
  }

  private func clearCache() {
    cache.removeAll()
    cacheOrder.removeAll()
    cacheBytes = 0
  }

  private func pruneAfterFailure() async {
    guard !isClosed else {
      clearCache()
      return
    }
    do {
      let snapshot = try await store.catalogSnapshot()
      guard !isClosed else {
        clearCache()
        return
      }
      prune(snapshot)
    } catch { clearCache() }
  }

  private func prune(_ snapshot: RecordCatalogSnapshot) {
    let tags = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.id, $0.metadata.tags) })
    for id in cache.keys.filter({ tags[$0] != cache[$0]?.tags }) { removeCached(id) }
    cacheOrder.removeAll { cache[$0] == nil }
  }

  private func reportProgress(
    _ completed: Int, total: Int,
    progress: @Sendable (RecordSemanticSearchProgress) -> Void
  ) {
    if completed == 1 || completed == total || completed.isMultiple(of: 32) {
      progress(.indexing(completed: completed, total: total))
    }
  }

  private func check() throws {
    try Task.checkCancellation()
    guard !isClosed else { throw CancellationError() }
  }

  private func searchableText(_ summary: RecordSummary) async throws -> String {
    guard let projection = try await store.record(id: summary.id) else {
      throw RecordStoreError.membershipChanged
    }
    let payload: String
    switch projection.record.payload {
    case .text(let text): payload = text
    case .files(let urls): payload = urls.map(\.lastPathComponent).joined(separator: "\n")
    case .image: payload = ""
    }
    return
      ([
        payload, summary.header.provenance.sourceApplicationName ?? "",
        summary.header.provenance.sourceBundleIdentifier ?? "",
      ] + summary.metadata.tags).joined(separator: "\n")
  }

  private func identifierAnchors(_ text: String) -> Set<String> {
    let folded = text.lowercased()
    let tokens = folded.split {
      $0.asciiValue == nil || (!$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_")
    }
    return Set(
      tokens.filter { $0.range(of: "[0-9]{3,}", options: .regularExpression) != nil }.map(
        String.init))
  }

  private func valid(_ embedding: RecordTextEmbedding) -> Bool {
    (1...16).contains(embedding.vectors.count)
      && embedding.vectors.allSatisfy {
        $0.count == 1_024 && $0.allSatisfy(\.isFinite)
      }
  }

  private func removeCached(_ id: RecordID) {
    cacheBytes -= cache.removeValue(forKey: id)?.byteCount ?? 0
  }

  private func cacheEmbedding(_ embedding: RecordTextEmbedding, for record: RecordSummary) {
    if cache[record.id] != nil {
      removeCached(record.id)
      cacheOrder.removeAll { $0 == record.id }
    }
    let item = Cached(tags: record.metadata.tags, embedding: embedding)
    while cacheBytes + item.byteCount > 128 * 1_024 * 1_024, !cacheOrder.isEmpty {
      removeCached(cacheOrder.removeFirst())
    }
    cache[record.id] = item
    cacheOrder.append(record.id)
    cacheBytes += item.byteCount
  }
}
