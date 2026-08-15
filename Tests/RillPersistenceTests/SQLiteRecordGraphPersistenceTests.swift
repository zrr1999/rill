import Foundation
import SQLite3
import XCTest

@testable import RillCore
@testable import RillPersistence

final class SQLiteRecordGraphPersistenceTests: XCTestCase {
  func testFreshDatabaseInstallsSchema12RecordGraphTables() throws {
    let fixture = try makeFixture(byte: 0x71)
    _ = fixture.store

    XCTAssertEqual(try integerQuery("PRAGMA user_version;", at: fixture.databaseURL), 12)
    XCTAssertEqual(
      try columnNames(in: "record_graph_metadata", at: fixture.databaseURL),
      ["id", "revision", "payload"]
    )
    XCTAssertEqual(
      try columnNames(in: "record_payload_blobs", at: fixture.databaseURL),
      ["blob_id", "record_id", "payload_kind", "payload", "plaintext_size", "state_id"]
    )
  }

  func testRecordGraphRoundTripProtectsGraphAndAllPayloadKinds() async throws {
    let fixture = try makeFixture(byte: 0x72)
    let graph = Data("record-graph-\(UUID().uuidString)".utf8)
    let blobs = [
      makeBlob(kind: .text, payload: Data("text payload".utf8)),
      makeBlob(kind: .image, payload: Data([0x89, 0x50, 0x4E, 0x47])),
      makeBlob(kind: .files, payload: Data("[\"file:///tmp/a\"]".utf8)),
    ]

    let revision = try await fixture.store.replaceRecordGraph(
      with: RecordGraphPersistenceWriteSnapshot(
        expectedRevision: nil,
        graph: graph,
        newPayloadBlobs: blobs,
        retainedPayloadBlobReferences: []
      )
    )

    XCTAssertEqual(revision, 1)
    let loaded = try await fixture.store.loadRecordGraph()
    XCTAssertEqual(
      loaded,
      .current(
        revision: 1,
        graph: graph,
        payloadBlobs: blobs.sorted { $0.reference.blobID.uuidString < $1.reference.blobID.uuidString }
      )
    )
    let rawGraph = try XCTUnwrap(
      try blobQuery("SELECT payload FROM record_graph_metadata WHERE id = 1;", at: fixture.databaseURL)
    )
    XCTAssertNotEqual(rawGraph, graph)
    XCTAssertNil(rawGraph.range(of: graph))
    for blob in blobs {
      let protectedPayload = try XCTUnwrap(
        try blobQuery(
          "SELECT payload FROM record_payload_blobs WHERE blob_id = '\(blob.reference.blobID.uuidString)';",
          at: fixture.databaseURL
        )
      )
      XCTAssertNotEqual(protectedPayload, blob.payload)
      XCTAssertNil(protectedPayload.range(of: blob.payload))
    }
  }

  func testMetadataOnlyUpdateRetainsImmutablePayloadCiphertext() async throws {
    let fixture = try makeFixture(byte: 0x73)
    let blob = makeBlob(kind: .text, payload: Data("immutable".utf8))
    _ = try await fixture.store.replaceRecordGraph(
      with: RecordGraphPersistenceWriteSnapshot(
        expectedRevision: nil,
        graph: Data("graph-1".utf8),
        newPayloadBlobs: [blob],
        retainedPayloadBlobReferences: []
      )
    )
    let before = try blobQuery(
      "SELECT payload FROM record_payload_blobs WHERE blob_id = '\(blob.reference.blobID.uuidString)';",
      at: fixture.databaseURL
    )

    let revision = try await fixture.store.replaceRecordGraph(
      with: RecordGraphPersistenceWriteSnapshot(
        expectedRevision: 1,
        graph: Data("graph-2".utf8),
        newPayloadBlobs: [],
        retainedPayloadBlobReferences: [blob.reference]
      )
    )

    XCTAssertEqual(revision, 2)
    XCTAssertEqual(
      before,
      try blobQuery(
        "SELECT payload FROM record_payload_blobs WHERE blob_id = '\(blob.reference.blobID.uuidString)';",
        at: fixture.databaseURL
      )
    )
  }

  func testRecordGraphCASRejectsStaleWriterWithoutMutation() async throws {
    let fixture = try makeFixture(byte: 0x74)
    let blob = makeBlob(kind: .text, payload: Data("payload".utf8))
    _ = try await fixture.store.replaceRecordGraph(
      with: RecordGraphPersistenceWriteSnapshot(
        expectedRevision: nil,
        graph: Data("first".utf8),
        newPayloadBlobs: [blob],
        retainedPayloadBlobReferences: []
      )
    )
    _ = try await fixture.store.replaceRecordGraph(
      with: RecordGraphPersistenceWriteSnapshot(
        expectedRevision: 1,
        graph: Data("second".utf8),
        newPayloadBlobs: [],
        retainedPayloadBlobReferences: [blob.reference]
      )
    )

    await XCTAssertThrowsErrorAsync {
      _ = try await fixture.store.replaceRecordGraph(
        with: RecordGraphPersistenceWriteSnapshot(
          expectedRevision: 1,
          graph: Data("stale".utf8),
          newPayloadBlobs: [],
          retainedPayloadBlobReferences: [blob.reference]
        )
      )
    }
    let loaded = try await fixture.store.loadRecordGraph()
    XCTAssertEqual(
      loaded,
      .current(revision: 2, graph: Data("second".utf8), payloadBlobs: [blob])
    )
  }

  func testFirstRecordCommitAtomicallyRemovesLegacyClipboardGraph() async throws {
    let fixture = try makeFixture(byte: 0x75)
    let legacyBlob = LegacyRecordGraphImageBlob(
      reference: LegacyRecordGraphBlobReference(
        blobID: UUID(),
        itemID: UUID(),
        byteCount: 4
      ),
      payload: Data([1, 2, 3, 4])
    )
    try await fixture.store.seedLegacyRecordGraphForMigrationTesting(
      metadata: Data("legacy graph".utf8),
      imageBlobs: [legacyBlob]
    )
    let legacy = try await fixture.store.loadRecordGraph()
    XCTAssertEqual(
      legacy,
      .legacyClipboard(metadata: Data("legacy graph".utf8), imageBlobs: [legacyBlob])
    )
    let recordBlob = makeBlob(kind: .image, payload: legacyBlob.payload)

    _ = try await fixture.store.replaceRecordGraph(
      with: RecordGraphPersistenceWriteSnapshot(
        expectedRevision: nil,
        graph: Data("record graph".utf8),
        newPayloadBlobs: [recordBlob],
        retainedPayloadBlobReferences: []
      )
    )

    XCTAssertEqual(try integerQuery("SELECT COUNT(*) FROM clipboard_metadata;", at: fixture.databaseURL), 0)
    XCTAssertEqual(try integerQuery("SELECT COUNT(*) FROM clipboard_image_blobs;", at: fixture.databaseURL), 0)
    let current = try await fixture.store.loadRecordGraph()
    XCTAssertEqual(
      current,
      .current(revision: 1, graph: Data("record graph".utf8), payloadBlobs: [recordBlob])
    )
  }

  private struct Fixture {
    let databaseURL: URL
    let store: SQLitePersistenceStore
  }

  private func makeFixture(byte: UInt8) throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-record-graph-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("records.sqlite")
    let protector = try AESGCMDataProtector(
      key: Data(repeating: byte, count: AESGCMDataProtector.keyByteCount)
    )
    return Fixture(
      databaseURL: databaseURL,
      store: try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: protector
      )
    )
  }

  private func makeBlob(
    kind: RecordPayloadKind,
    payload: Data
  ) -> RecordGraphPersistenceBlob {
    let recordID = RecordID()
    return RecordGraphPersistenceBlob(
      reference: RecordGraphPersistenceBlobReference(
        blobID: UUID(),
        recordID: recordID,
        kind: kind,
        byteCount: payload.count
      ),
      payload: payload
    )
  }

  private func integerQuery(_ sql: String, at databaseURL: URL) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else { throw RecordGraphTestError.openFailed }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement,
      sqlite3_step(statement) == SQLITE_ROW
    else { throw RecordGraphTestError.queryFailed }
    defer { sqlite3_finalize(statement) }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func columnNames(in table: String, at databaseURL: URL) throws -> [String] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else { throw RecordGraphTestError.openFailed }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw RecordGraphTestError.queryFailed }
    defer { sqlite3_finalize(statement) }
    var names: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let text = sqlite3_column_text(statement, 1) else {
        throw RecordGraphTestError.queryFailed
      }
      names.append(String(cString: text))
    }
    return names
  }

  private func blobQuery(_ sql: String, at databaseURL: URL) throws -> Data? {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else { throw RecordGraphTestError.openFailed }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw RecordGraphTestError.queryFailed }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    let count = Int(sqlite3_column_bytes(statement, 0))
    guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
    return Data(bytes: bytes, count: count)
  }
}

private enum RecordGraphTestError: Error {
  case openFailed
  case queryFailed
}

private func XCTAssertThrowsErrorAsync(
  _ expression: () async throws -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    try await expression()
    XCTFail("Expected expression to throw", file: file, line: line)
  } catch {}
}
