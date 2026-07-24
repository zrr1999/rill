import Foundation
import SQLite3
import XCTest

@testable import RillPersistence

final class SQLiteWriterBarrierTests: XCTestCase {
  func testRegisteredConnectionCanWriteWithTrustedSchemaDisabled() throws {
    let database = try makeDatabase()
    defer { sqlite3_close(database) }
    try execute(
      """
      CREATE TABLE history_records (id TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      """,
      on: database
    )
    try SQLiteWriterBarrier.registerCapability(on: database)
    try SQLiteWriterBarrier.installTriggers(
      on: database,
      tableNames: ["history_records", "app_settings"]
    )
    try execute("PRAGMA trusted_schema = OFF;", on: database)
    let registeredFlags = try integerQuery(
      """
      SELECT flags FROM pragma_function_list
      WHERE name = 'rill_writer_capability_v11' AND narg = 0;
      """,
      on: database
    )
    XCTAssertEqual(
      registeredFlags & Int(SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS),
      Int(SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS)
    )

    try execute(
      "INSERT INTO history_records (id, value) VALUES ('record', 'first');",
      on: database
    )
    try execute(
      "UPDATE history_records SET value = 'second' WHERE id = 'record';",
      on: database
    )
    try execute("DELETE FROM history_records WHERE id = 'record';", on: database)

    XCTAssertEqual(try integerQuery("SELECT COUNT(*) FROM history_records;", on: database), 0)
  }

  func testConnectionWithoutCapabilityCannotInsertUpdateOrDelete() throws {
    let databaseURL = try makeDatabaseURL()
    let current = try openDatabase(at: databaseURL)
    defer { sqlite3_close(current) }
    try execute(
      "CREATE TABLE history_records (id TEXT PRIMARY KEY, value TEXT NOT NULL);",
      on: current
    )
    try SQLiteWriterBarrier.registerCapability(on: current)
    try SQLiteWriterBarrier.installTriggers(
      on: current,
      tableNames: ["history_records"]
    )
    try execute(
      "INSERT INTO history_records (id, value) VALUES ('record', 'protected');",
      on: current
    )

    let legacy = try openDatabase(at: databaseURL)
    defer { sqlite3_close(legacy) }
    XCTAssertEqual(sqlite3_exec(legacy, "PRAGMA user_version = 1;", nil, nil, nil), SQLITE_OK)
    XCTAssertEqual(try integerQuery("PRAGMA user_version;", on: legacy), 1)
    XCTAssertNotEqual(
      sqlite3_exec(
        legacy,
        "INSERT INTO history_records (id, value) VALUES ('legacy', 'plaintext');",
        nil,
        nil,
        nil
      ),
      SQLITE_OK
    )
    XCTAssertNotEqual(
      sqlite3_exec(
        legacy,
        "UPDATE history_records SET value = 'plaintext' WHERE id = 'record';",
        nil,
        nil,
        nil
      ),
      SQLITE_OK
    )
    XCTAssertNotEqual(
      sqlite3_exec(
        legacy,
        "DELETE FROM history_records WHERE id = 'record';",
        nil,
        nil,
        nil
      ),
      SQLITE_OK
    )

    XCTAssertEqual(try integerQuery("SELECT COUNT(*) FROM history_records;", on: current), 1)
    XCTAssertEqual(
      try textQuery("SELECT value FROM history_records WHERE id = 'record';", on: current),
      "protected"
    )
  }

  func testNullCapabilityFailsClosed() throws {
    let database = try makeDatabase()
    defer { sqlite3_close(database) }
    try execute("CREATE TABLE history_records (id TEXT PRIMARY KEY);", on: database)
    try SQLiteWriterBarrier.installTriggers(
      on: database,
      tableNames: ["history_records"]
    )
    XCTAssertEqual(
      sqlite3_create_function_v2(
        database,
        SQLiteWriterBarrier.capabilityFunctionName,
        0,
        SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS,
        nil,
        { context, _, _ in sqlite3_result_null(context) },
        nil,
        nil,
        nil
      ),
      SQLITE_OK
    )

    XCTAssertNotEqual(
      sqlite3_exec(
        database,
        "INSERT INTO history_records (id) VALUES ('record');",
        nil,
        nil,
        nil
      ),
      SQLITE_OK
    )
    XCTAssertEqual(try integerQuery("SELECT COUNT(*) FROM history_records;", on: database), 0)
  }

  func testInstallIsIdempotentAndValidationChecksTheExactBarrierSet() throws {
    let database = try makeDatabase()
    defer { sqlite3_close(database) }
    try execute(
      """
      CREATE TABLE history_records (id TEXT PRIMARY KEY);
      CREATE TABLE app_settings (key TEXT PRIMARY KEY);
      """,
      on: database
    )
    let tables = ["history_records", "app_settings"]

    try SQLiteWriterBarrier.installTriggers(on: database, tableNames: tables)
    try SQLiteWriterBarrier.installTriggers(on: database, tableNames: tables.reversed())
    XCTAssertNoThrow(
      try SQLiteWriterBarrier.validateTriggers(on: database, tableNames: tables)
    )
    XCTAssertEqual(
      try integerQuery(
        """
        SELECT COUNT(*) FROM sqlite_schema
        WHERE type = 'trigger'
          AND name GLOB 'rill_writer_barrier_v11_*';
        """,
        on: database
      ),
      6
    )
  }

  func testValidationRejectsMissingModifiedAndUnexpectedBarrierTriggers() throws {
    for mutation in BarrierMutation.allCases {
      let database = try makeDatabase()
      try execute(
        """
        CREATE TABLE history_records (id TEXT PRIMARY KEY);
        CREATE TABLE app_settings (key TEXT PRIMARY KEY);
        """,
        on: database
      )
      let tables = ["history_records", "app_settings"]
      try SQLiteWriterBarrier.installTriggers(on: database, tableNames: tables)
      try mutation.apply(to: database)

      XCTAssertThrowsError(
        try SQLiteWriterBarrier.validateTriggers(on: database, tableNames: tables)
      ) { error in
        XCTAssertEqual(error as? SQLiteWriterBarrierError, .triggerValidationFailed)
      }
      sqlite3_close(database)
    }
  }

  func testFailedInstallRollsBackTriggersCreatedBeforeTheFailure() throws {
    let database = try makeDatabase()
    defer { sqlite3_close(database) }
    try execute("CREATE TABLE history_records (id TEXT PRIMARY KEY);", on: database)

    XCTAssertThrowsError(
      try SQLiteWriterBarrier.installTriggers(
        on: database,
        tableNames: ["history_records", "missing_table"]
      )
    ) { error in
      XCTAssertEqual(error as? SQLiteWriterBarrierError, .triggerInstallationFailed)
    }
    XCTAssertEqual(
      try integerQuery(
        """
        SELECT COUNT(*) FROM sqlite_schema
        WHERE type = 'trigger'
          AND name GLOB 'rill_writer_barrier_v11_*';
        """,
        on: database
      ),
      0
    )
  }

  func testInvalidTableSetsFailWithoutExecutingInjectedSQL() throws {
    let database = try makeDatabase()
    defer { sqlite3_close(database) }
    try execute("CREATE TABLE history_records (id TEXT PRIMARY KEY);", on: database)

    for tables in [
      [],
      ["history_records", "history_records"],
      ["history_records; DROP TABLE history_records"],
      ["HistoryRecords"],
    ] {
      XCTAssertThrowsError(
        try SQLiteWriterBarrier.installTriggers(on: database, tableNames: tables)
      ) { error in
        XCTAssertEqual(error as? SQLiteWriterBarrierError, .invalidTableSet)
      }
    }

    XCTAssertEqual(
      try integerQuery(
        "SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table' AND name = 'history_records';",
        on: database
      ),
      1
    )
  }

  func testNilDatabaseErrorsDoNotCarrySQLiteDetails() {
    XCTAssertThrowsError(try SQLiteWriterBarrier.registerCapability(on: nil)) { error in
      XCTAssertEqual(error as? SQLiteWriterBarrierError, .invalidDatabase)
    }
    XCTAssertThrowsError(
      try SQLiteWriterBarrier.installTriggers(on: nil, tableNames: ["history_records"])
    ) { error in
      XCTAssertEqual(error as? SQLiteWriterBarrierError, .invalidDatabase)
    }
    XCTAssertThrowsError(
      try SQLiteWriterBarrier.validateTriggers(on: nil, tableNames: ["history_records"])
    ) { error in
      XCTAssertEqual(error as? SQLiteWriterBarrierError, .invalidDatabase)
    }
  }

  private func makeDatabase() throws -> OpaquePointer? {
    try openDatabase(at: makeDatabaseURL())
  }

  private func makeDatabaseURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-writer-barrier-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directory)
    }
    return directory.appendingPathComponent("barrier.sqlite", isDirectory: false)
  }
}

private enum BarrierMutation: CaseIterable {
  case missing
  case modified
  case unexpected

  func apply(to database: OpaquePointer?) throws {
    let triggerName = "rill_writer_barrier_v11_history_records_insert"
    switch self {
    case .missing:
      try execute("DROP TRIGGER \"\(triggerName)\";", on: database)
    case .modified:
      try execute(
        """
        DROP TRIGGER "\(triggerName)";
        CREATE TRIGGER "\(triggerName)"
        BEFORE INSERT ON "history_records"
        BEGIN
          SELECT 1;
        END;
        """,
        on: database
      )
    case .unexpected:
      try execute(
        """
        CREATE TRIGGER "rill_writer_barrier_v11_unexpected_insert"
        BEFORE INSERT ON "history_records"
        BEGIN
          SELECT 1;
        END;
        """,
        on: database
      )
    }
  }
}

private func openDatabase(at databaseURL: URL) throws -> OpaquePointer? {
  var database: OpaquePointer?
  let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
  guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
    let database
  else {
    if let database {
      sqlite3_close(database)
    }
    throw SQLiteWriterBarrierTestError.openFailed
  }
  return database
}

private func execute(_ sql: String, on database: OpaquePointer?) throws {
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw SQLiteWriterBarrierTestError.executionFailed
  }
}

private func integerQuery(_ sql: String, on database: OpaquePointer?) throws -> Int {
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
    let statement
  else {
    throw SQLiteWriterBarrierTestError.queryFailed
  }
  defer { sqlite3_finalize(statement) }
  guard sqlite3_step(statement) == SQLITE_ROW else {
    throw SQLiteWriterBarrierTestError.queryFailed
  }
  return Int(sqlite3_column_int64(statement, 0))
}

private func textQuery(_ sql: String, on database: OpaquePointer?) throws -> String? {
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
    let statement
  else {
    throw SQLiteWriterBarrierTestError.queryFailed
  }
  defer { sqlite3_finalize(statement) }
  guard sqlite3_step(statement) == SQLITE_ROW,
    let text = sqlite3_column_text(statement, 0)
  else {
    throw SQLiteWriterBarrierTestError.queryFailed
  }
  return String(cString: text)
}

private enum SQLiteWriterBarrierTestError: Error {
  case openFailed
  case executionFailed
  case queryFailed
}
