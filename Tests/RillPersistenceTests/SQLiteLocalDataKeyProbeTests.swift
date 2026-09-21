import Foundation
import SQLite3
import RillCore
import XCTest

@testable import RillPersistence

final class SQLiteLocalDataKeyProbeTests: XCTestCase {
  func testFreshV0ThroughV3AreUnboundWithoutTouchingSQLiteFiles() throws {
    for version in 0...3 {
      let databaseURL = try makeDatabaseURL()
      defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
      try createUnboundDatabase(at: databaseURL, version: version)
      let before = try storageSnapshot(at: databaseURL)

      XCTAssertEqual(
        try SQLiteLocalDataKeyProbe.probe(
          databaseURL: databaseURL,
          localDataProtector: makeProtector(byte: 0x11)
        ),
        .unbound
      )
      XCTAssertEqual(try storageSnapshot(at: databaseURL), before)
    }
  }

  func testDowngradedV4MarkerAcceptsOnlyItsExistingKeyWithoutWrites() throws {
    let databaseURL = try makeDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let protector = try makeProtector(byte: 0x22)
    try createDowngradedV4Database(at: databaseURL, protector: protector)

    var before = try storageSnapshot(at: databaseURL)
    XCTAssertEqual(
      try SQLiteLocalDataKeyProbe.probe(
        databaseURL: databaseURL,
        localDataProtector: protector
      ),
      .boundAndValid
    )
    XCTAssertEqual(try storageSnapshot(at: databaseURL), before)

    before = try storageSnapshot(at: databaseURL)
    assertValidationFailure(databaseURL: databaseURL, protectorByte: 0x23)
    XCTAssertEqual(try storageSnapshot(at: databaseURL), before)
  }

  func testV11AcceptsOnlyItsExistingKeyAndTamperedFloorFailsWithoutWrites() throws {
    let databaseURL = try makeDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let protector = try makeProtector(byte: 0x33)
    try createV11Database(at: databaseURL, protector: protector)

    var before = try storageSnapshot(at: databaseURL)
    XCTAssertEqual(
      try SQLiteLocalDataKeyProbe.probe(
        databaseURL: databaseURL,
        localDataProtector: protector
      ),
      .boundAndValid
    )
    XCTAssertEqual(try storageSnapshot(at: databaseURL), before)

    before = try storageSnapshot(at: databaseURL)
    assertValidationFailure(databaseURL: databaseURL, protectorByte: 0x34)
    XCTAssertEqual(try storageSnapshot(at: databaseURL), before)

    try tamperAuthenticatedFloor(at: databaseURL)
    before = try storageSnapshot(at: databaseURL)
    assertValidationFailure(databaseURL: databaseURL, protectorByte: 0x33)
    XCTAssertEqual(try storageSnapshot(at: databaseURL), before)
  }

  func testVersionWithoutRequiredMarkerOrFloorFailsClosedWithoutWrites() throws {
    for version in [4, 11] {
      let databaseURL = try makeDatabaseURL()
      defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
      try createUnboundDatabase(at: databaseURL, version: version)
      let before = try storageSnapshot(at: databaseURL)

      assertValidationFailure(databaseURL: databaseURL, protectorByte: 0x44)
      XCTAssertEqual(try storageSnapshot(at: databaseURL), before)
    }
  }

  func testFloorAndMarkerMustAuthenticateWithTheSameKeyWithoutWrites() throws {
    let databaseURL = try makeDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let floorProtector = try makeProtector(byte: 0x55)
    try createV11Database(at: databaseURL, protector: floorProtector)
    try replaceMarker(
      at: databaseURL,
      envelope: try markerEnvelope(protector: makeProtector(byte: 0x56))
    )

    for byte: UInt8 in [0x55, 0x56] {
      let before = try storageSnapshot(at: databaseURL)
      assertValidationFailure(databaseURL: databaseURL, protectorByte: byte)
      XCTAssertEqual(try storageSnapshot(at: databaseURL), before)
    }
  }

  private func assertValidationFailure(
    databaseURL: URL,
    protectorByte: UInt8,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try SQLiteLocalDataKeyProbe.probe(
        databaseURL: databaseURL,
        localDataProtector: makeProtector(byte: protectorByte)
      ),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual(
        error as? SQLiteLocalDataKeyProbeError,
        .validationFailed,
        file: file,
        line: line
      )
      XCTAssertFalse(String(describing: error).contains(databaseURL.path))
    }
  }
}

private let probeMarkerPlaintext = Data("Rill local data key verification v1".utf8)
private let probeMarkerContext = LocalDataProtectionContext(
  namespace: "local_data_protection",
  recordID: "1",
  field: "key_verification"
)

private func makeProtector(byte: UInt8) throws -> AESGCMDataProtector {
  try AESGCMDataProtector(
    key: Data(repeating: byte, count: AESGCMDataProtector.keyByteCount)
  )
}

private func makeDatabaseURL() throws -> URL {
  let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
    "rill-key-probe-tests-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
  return directoryURL.appendingPathComponent("rill.sqlite", isDirectory: false)
}

private func createUnboundDatabase(at databaseURL: URL, version: Int) throws {
  let database = try openReadWriteDatabase(at: databaseURL)
  defer { sqlite3_close(database) }
  try execute(
    """
    PRAGMA journal_mode = WAL;
    PRAGMA wal_autocheckpoint = 0;
    CREATE TABLE legacy_unbound (id INTEGER PRIMARY KEY, value TEXT);
    INSERT INTO legacy_unbound (value) VALUES ('fixture');
    PRAGMA user_version = \(version);
    """,
    on: database
  )
  try persistWAL(on: database)
}

private func createDowngradedV4Database(
  at databaseURL: URL,
  protector: any LocalDataProtector
) throws {
  let database = try openReadWriteDatabase(at: databaseURL)
  defer { sqlite3_close(database) }
  try execute(
    """
    PRAGMA journal_mode = WAL;
    PRAGMA wal_autocheckpoint = 0;
    CREATE TABLE history_records (
      id TEXT PRIMARY KEY,
      run_id TEXT,
      workflow_id TEXT,
      workflow_fallback_name TEXT NOT NULL,
      workflow_title_key TEXT,
      final_text TEXT,
      failure_message TEXT,
      timestamp REAL NOT NULL,
      is_stack_related INTEGER NOT NULL,
      outcome TEXT NOT NULL,
      correction_source_json TEXT
    );
    CREATE INDEX idx_history_records_timestamp
    ON history_records (timestamp DESC);
    CREATE TABLE diagnostic_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      timestamp REAL NOT NULL,
      run_id TEXT,
      subsystem TEXT NOT NULL,
      level TEXT NOT NULL,
      level_severity INTEGER NOT NULL,
      event TEXT NOT NULL,
      message TEXT NOT NULL,
      metadata_json TEXT NOT NULL
    );
    CREATE INDEX idx_diagnostic_events_timestamp
    ON diagnostic_events (timestamp DESC);
    CREATE TABLE app_settings (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL,
      updated_at REAL NOT NULL
    );
    CREATE TABLE export_metadata (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      destination_path TEXT NOT NULL,
      item_count INTEGER NOT NULL,
      created_at REAL NOT NULL,
      metadata_json TEXT NOT NULL
    );
    CREATE INDEX idx_export_metadata_created_at
    ON export_metadata (created_at DESC);
    CREATE TABLE local_data_protection (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      key_verification TEXT NOT NULL,
      cleanup_pending INTEGER NOT NULL CHECK (cleanup_pending IN (0, 1))
    );
    PRAGMA user_version = 1;
    """,
    on: database
  )
  try insertMarker(
    envelope: try markerEnvelope(protector: protector),
    into: database
  )
  try persistWAL(on: database)
}

private func createV11Database(
  at databaseURL: URL,
  protector: any LocalDataProtector
) throws {
  try autoreleasepool {
    _ = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: protector
    )
  }
  let database = try openReadWriteDatabase(at: databaseURL)
  defer { sqlite3_close(database) }
  try SQLiteWriterBarrier.registerCapability(on: database)
  try SQLiteSchemaWriterBarrier.catalog.register(on: database)
  try SQLiteSchemaWriterBarrier.memory.register(on: database)
  try execute(
    """
    PRAGMA journal_mode = WAL;
    PRAGMA wal_autocheckpoint = 0;
    UPDATE local_data_protection
    SET cleanup_pending = cleanup_pending
    WHERE id = 1;
    """,
    on: database
  )
  try persistWAL(on: database)
}

private func tamperAuthenticatedFloor(at databaseURL: URL) throws {
  let database = try openReadWriteDatabase(at: databaseURL)
  defer { sqlite3_close(database) }
  try SQLiteWriterBarrier.registerCapability(on: database)
  try SQLiteSchemaWriterBarrier.catalog.register(on: database)
  try SQLiteSchemaWriterBarrier.memory.register(on: database)
  try execute(
    """
    UPDATE rill_authenticated_schema_floor
    SET verification = 'rill:v1:AAAA'
    WHERE id = 1;
    """,
    on: database
  )
}

private func replaceMarker(at databaseURL: URL, envelope: String) throws {
  let database = try openReadWriteDatabase(at: databaseURL)
  defer { sqlite3_close(database) }
  try SQLiteWriterBarrier.registerCapability(on: database)
  try SQLiteSchemaWriterBarrier.catalog.register(on: database)
  try SQLiteSchemaWriterBarrier.memory.register(on: database)
  var statement: OpaquePointer?
  guard
    sqlite3_prepare_v2(
      database,
      "UPDATE local_data_protection SET key_verification = ? WHERE id = 1;",
      -1,
      &statement,
      nil
    ) == SQLITE_OK,
    let statement
  else {
    throw ProbeTestError.sqlFailed
  }
  defer { sqlite3_finalize(statement) }
  let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  guard
    envelope.withCString({
      sqlite3_bind_text(statement, 1, $0, -1, transient)
    }) == SQLITE_OK,
    sqlite3_step(statement) == SQLITE_DONE
  else {
    throw ProbeTestError.sqlFailed
  }
}

private func markerEnvelope(protector: any LocalDataProtector) throws -> String {
  try protector.seal(probeMarkerPlaintext, context: probeMarkerContext)
}

private func insertMarker(envelope: String, into database: OpaquePointer?) throws {
  var statement: OpaquePointer?
  guard
    sqlite3_prepare_v2(
      database,
      """
      INSERT INTO local_data_protection (
        id, key_verification, cleanup_pending
      ) VALUES (1, ?, 0);
      """,
      -1,
      &statement,
      nil
    ) == SQLITE_OK,
    let statement
  else {
    throw ProbeTestError.sqlFailed
  }
  defer { sqlite3_finalize(statement) }
  let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  guard
    envelope.withCString({
      sqlite3_bind_text(statement, 1, $0, -1, transient)
    }) == SQLITE_OK,
    sqlite3_step(statement) == SQLITE_DONE
  else {
    throw ProbeTestError.sqlFailed
  }
}

private func persistWAL(on database: OpaquePointer?) throws {
  var enabled: Int32 = 1
  guard
    sqlite3_file_control(
      database,
      nil,
      SQLITE_FCNTL_PERSIST_WAL,
      &enabled
    ) == SQLITE_OK
  else {
    throw ProbeTestError.sqlFailed
  }
}

private func openReadWriteDatabase(at databaseURL: URL) throws -> OpaquePointer? {
  var database: OpaquePointer?
  let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
  guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
    let database
  else {
    if let database { sqlite3_close(database) }
    throw ProbeTestError.openFailed
  }
  return database
}

private func execute(_ sql: String, on database: OpaquePointer?) throws {
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw ProbeTestError.sqlFailed
  }
}

private struct StorageFileSnapshot: Equatable {
  let bytes: Data
  let modificationDate: Date
}

private func storageSnapshot(at databaseURL: URL) throws -> [String: StorageFileSnapshot] {
  let fileManager = FileManager.default
  var result: [String: StorageFileSnapshot] = [:]
  for suffix in ["", "-wal", "-shm"] {
    let url = URL(fileURLWithPath: databaseURL.path + suffix)
    guard fileManager.fileExists(atPath: url.path) else { continue }
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    result[suffix] = StorageFileSnapshot(
      bytes: try Data(contentsOf: url),
      modificationDate: try XCTUnwrap(attributes[.modificationDate] as? Date)
    )
  }
  return result
}

private enum ProbeTestError: Error {
  case openFailed
  case sqlFailed
}
