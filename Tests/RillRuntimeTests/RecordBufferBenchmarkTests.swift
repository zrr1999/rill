import Darwin
import Foundation
import SQLite3
import Testing

@testable import RillCore
@testable import RillPersistence
@testable import RillRuntime

struct RecordBufferBenchmarkTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["RILL_BUFFER_BENCHMARK"] == "1"))
  func tenThousandEncryptedEntries() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-buffer-benchmark-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLitePersistenceStore(
      databaseURL: directory.appendingPathComponent("data.sqlite"),
      localDataProtector: AESGCMDataProtector(
        key: Data(repeating: 0x45, count: AESGCMDataProtector.keyByteCount)))
    let ids = try await seed(repository)
    let store = RecordStore(persistence: repository)
    _ = try await store.bufferSnapshot()
    let beforeMemory = residentBytes()
    let beforeBytes = try diskBytes(directory)
    var enqueue: [Double] = []
    var select: [Double] = []
    var commit: [Double] = []
    var prepare: [Double] = []
    for id in ids {
      let start = ContinuousClock.now
      _ = try await store.enqueueRecord(id, in: RecordBuffer.clipboardID)
      enqueue.append(milliseconds(start.duration(to: .now)))
    }
    let afterMemory = residentBytes()
    let afterBytes = try diskBytes(directory)
    #expect(try await store.bufferSnapshot().remainingCount == 10_000)
    let restored = RecordStore(persistence: repository)
    #expect(try await restored.bufferSnapshot().remainingCount == 10_000)
    for _ in ids {
      var start = ContinuousClock.now
      _ = try await store.bufferSnapshot()
      select.append(milliseconds(start.duration(to: .now)))
      start = .now
      let output = try await store.beginBufferOutput()
      prepare.append(milliseconds(start.duration(to: .now)))
      start = .now
      try await store.finishBufferOutput(output.entry.id)
      commit.append(milliseconds(start.duration(to: .now)))
    }
    #expect(try await store.bufferSnapshot().remainingCount == 0)
    print(
      "BUFFER_BENCHMARK count=10000 enqueue_ms=\(percentiles(enqueue)) select_ms=\(percentiles(select)) prepare_ms=\(percentiles(prepare)) commit_ms=\(percentiles(commit)) resident_delta_bytes=\(Int64(afterMemory)-Int64(beforeMemory)) encrypted_database_delta_bytes=\(afterBytes-beforeBytes)"
    )
  }

  private func seed(_ repository: SQLitePersistenceStore) async throws -> [RecordID] {
    let encoder = JSONEncoder()
    var nodes: [RecordCatalogNode] = []
    var blobs: [RecordGraphPersistenceBlob] = []
    func node<T: Encodable>(_ kind: RecordCatalogNode.Kind, _ id: String, _ value: T) throws {
      nodes.append(.init(kind: kind, id: id, value: try encoder.encode(value)))
    }
    let collections = [RecordCollection.inbox, .voiceInput]
    for collection in collections { try node(.collection, collection.id.description, collection) }
    for buffer in RecordBuffer.defaults { try node(.buffer, buffer.id.description, buffer) }
    try node(.bufferClock, "input-sequence", UInt64(1))
    var ids: [RecordID] = []
    for index in 0..<10_000 {
      let text = "Benchmark 中文 🙂 \(index)"
      let data = Data(text.utf8)
      let record = Record(
        payload: .text(text), provenance: .init(source: .init(kind: .systemClipboard)))
      ids.append(record.id)
      try node(.record, record.id.description, RecordHeader(record: record, byteCount: data.count))
      try node(.metadata, record.id.description, RecordMetadata(recordID: record.id))
      try node(.activity, record.id.description, RecordActivity(recordID: record.id))
      blobs.append(
        .init(
          reference: .init(blobID: UUID(), recordID: record.id, kind: .text, byteCount: data.count),
          payload: data))
    }
    _ = try await repository.commitRecordCatalog(
      .init(
        expectedRevision: nil,
        manifest: .init(
          nextMembershipOrdinal: 1, recordOrder: ids, collectionOrder: collections.map(\.id)),
        upserts: nodes, removedKeys: [], newPayloadBlobs: blobs, removedPayloadBlobIDs: []))
    return ids
  }

  private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
  }
  private func percentiles(_ values: [Double]) -> String {
    let sorted = values.sorted()
    return [0.50, 0.95, 0.99].map {
      String(format: "%.3f", sorted[Int(Double(sorted.count - 1) * $0)])
    }.joined(separator: "/")
  }
  private func diskBytes(_ directory: URL) throws -> Int {
    var db: OpaquePointer?
    #expect(sqlite3_open(directory.appendingPathComponent("data.sqlite").path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    #expect(sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil) == SQLITE_OK)
    return try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.fileSizeKey]
    ).reduce(0) {
      try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
  }
  private func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? info.resident_size : 0
  }
}
