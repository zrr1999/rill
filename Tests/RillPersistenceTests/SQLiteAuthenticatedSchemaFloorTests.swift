import Foundation
import SQLite3
import RillCore
import XCTest

@testable import RillPersistence

final class SQLiteAuthenticatedSchemaFloorTests: XCTestCase {
  private let databaseID = try! XCTUnwrap(
    UUID(uuidString: "123e4567-e89b-12d3-a456-426614174000")
  )

  func testInstallAndValidateV14InsideCallerTransaction() throws {
    let database = try makeDatabase()
    defer { sqlite3_close(database) }
    let protector = try makeProtector(byte: 0x11)

    XCTAssertThrowsError(
      try SQLiteAuthenticatedSchemaFloor.install(
        on: database,
        databaseID: databaseID,
        localDataProtector: protector
      )
    ) { error in
      XCTAssertEqual(
        error as? SQLiteAuthenticatedSchemaFloorError,
        .installationFailed
      )
    }

    try execute("BEGIN IMMEDIATE TRANSACTION;", on: database)
    try SQLiteAuthenticatedSchemaFloor.install(
      on: database,
      databaseID: databaseID,
      localDataProtector: protector
    )
    try execute("COMMIT;", on: database)

    XCTAssertEqual(
      try SQLiteAuthenticatedSchemaFloor.readAndValidate(
        on: database,
        localDataProtector: protector
      ),
      14
    )
    XCTAssertEqual(
      try integerQuery(
        """
        SELECT strict FROM pragma_table_list
        WHERE schema = 'main'
          AND name = 'rill_authenticated_schema_floor';
        """,
        on: database
      ),
      1
    )
  }

  func testMissingTableIsTheOnlyNilResult() throws {
    let database = try makeDatabase()
    defer { sqlite3_close(database) }

    XCTAssertNil(
      try SQLiteAuthenticatedSchemaFloor.readAndValidate(
        on: database,
        localDataProtector: makeProtector(byte: 0x22)
      )
    )
  }

  func testWrongKeyAndAllStoredValueTamperingShareStablePrivateFailure() throws {
    for mutation in Mutation.allCases {
      let database = try makeInstalledDatabase()
      defer { sqlite3_close(database) }
      try mutation.apply(to: database)
      let protector = try makeProtector(
        byte: mutation == .wrongKey ? 0x44 : 0x33
      )

      XCTAssertThrowsError(
        try SQLiteAuthenticatedSchemaFloor.readAndValidate(
          on: database,
          localDataProtector: protector
        ),
        "Mutation \(mutation) should fail closed."
      ) { error in
        XCTAssertEqual(
          error as? SQLiteAuthenticatedSchemaFloorError,
          .validationFailed
        )
        XCTAssertEqual(String(describing: error), "validationFailed")
      }
    }
  }

  func testSchemaFingerprintRejectsEveryStructuralMutation() throws {
    for mutation in SchemaMutation.allCases {
      try autoreleasepool {
        let database = try makeInstalledSchemaDatabase()
        defer { sqlite3_close(database) }
        try mutation.apply(to: database)

        XCTAssertThrowsError(
          try SQLiteAuthenticatedSchemaFloor.readAndValidate(
            on: database,
            localDataProtector: makeProtector(byte: 0x55)
          ),
          "Schema mutation \(mutation) should fail authentication."
        ) { error in
          XCTAssertEqual(
            error as? SQLiteAuthenticatedSchemaFloorError,
            .validationFailed
          )
        }
      }
    }
  }

  func testSchemaFingerprintExcludesRowsAndWriterBarrierTriggers() throws {
    let database = try makeInstalledSchemaDatabase()
    defer { sqlite3_close(database) }
    try execute(
      """
      CREATE TRIGGER rill_writer_barrier_v11_schema_records_insert
      BEFORE INSERT ON schema_records
      BEGIN
        SELECT 1;
      END;
      INSERT INTO schema_records (id, value) VALUES ('row', 'not-schema');
      """,
      on: database
    )

    XCTAssertEqual(
      try SQLiteAuthenticatedSchemaFloor.readAndValidate(
        on: database,
        localDataProtector: makeProtector(byte: 0x55)
      ),
      14
    )
  }

  private func makeInstalledDatabase() throws -> OpaquePointer? {
    let database = try makeDatabase()
    do {
      try execute("BEGIN IMMEDIATE TRANSACTION;", on: database)
      try SQLiteAuthenticatedSchemaFloor.install(
        on: database,
        databaseID: databaseID,
        localDataProtector: makeProtector(byte: 0x33)
      )
      try execute("COMMIT;", on: database)
      return database
    } catch {
      sqlite3_close(database)
      throw error
    }
  }

  private func makeInstalledSchemaDatabase() throws -> OpaquePointer? {
    let database = try makeDatabase()
    do {
      try execute(
        """
        CREATE TABLE schema_records (
          id TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        CREATE INDEX idx_schema_records_value
        ON schema_records (value);
        CREATE VIEW schema_record_values AS
        SELECT value FROM schema_records;
        CREATE TRIGGER schema_records_audit
        AFTER UPDATE ON schema_records
        BEGIN
          SELECT NEW.value;
        END;
        """,
        on: database
      )
      try execute("BEGIN IMMEDIATE TRANSACTION;", on: database)
      try SQLiteAuthenticatedSchemaFloor.install(
        on: database,
        databaseID: databaseID,
        localDataProtector: makeProtector(byte: 0x55)
      )
      try execute("COMMIT;", on: database)
      return database
    } catch {
      sqlite3_close(database)
      throw error
    }
  }
}

private enum Mutation: CaseIterable {
  case wrongKey
  case databaseID
  case schemaFloor
  case envelope
  case extraRow
  case malformedUUID

  func apply(to database: OpaquePointer?) throws {
    switch self {
    case .wrongKey:
      return
    case .databaseID:
      try execute(
        """
        UPDATE rill_authenticated_schema_floor
        SET database_id = '123e4567-e89b-12d3-a456-426614174001';
        """,
        on: database
      )
    case .schemaFloor:
      try execute(
        "UPDATE rill_authenticated_schema_floor SET schema_floor = 11;",
        on: database
      )
    case .envelope:
      try execute(
        """
        UPDATE rill_authenticated_schema_floor
        SET verification = 'rill:v1:AAAA';
        """,
        on: database
      )
    case .extraRow:
      try execute("PRAGMA ignore_check_constraints = ON;", on: database)
      try execute(
        """
        INSERT INTO rill_authenticated_schema_floor (
          id, database_id, schema_floor, verification
        )
        SELECT 2, database_id, schema_floor, verification
        FROM rill_authenticated_schema_floor WHERE id = 1;
        """,
        on: database
      )
    case .malformedUUID:
      try execute("PRAGMA ignore_check_constraints = ON;", on: database)
      try execute(
        """
        UPDATE rill_authenticated_schema_floor
        SET database_id = 'not-a-canonical-uuid';
        """,
        on: database
      )
    }
  }
}

private enum SchemaMutation: CaseIterable {
  case extraTable
  case addedColumn
  case missingIndex
  case changedViewDefinition
  case changedTriggerDefinition

  func apply(to database: OpaquePointer?) throws {
    switch self {
    case .extraTable:
      try execute("CREATE TABLE unexpected_table (id INTEGER);", on: database)
    case .addedColumn:
      try execute(
        "ALTER TABLE schema_records ADD COLUMN note TEXT;",
        on: database
      )
    case .missingIndex:
      try execute("DROP INDEX idx_schema_records_value;", on: database)
    case .changedViewDefinition:
      try execute(
        """
        DROP VIEW schema_record_values;
        CREATE VIEW schema_record_values AS
        SELECT id, value FROM schema_records;
        """,
        on: database
      )
    case .changedTriggerDefinition:
      try execute(
        """
        DROP TRIGGER schema_records_audit;
        CREATE TRIGGER schema_records_audit
        AFTER UPDATE ON schema_records
        BEGIN
          SELECT OLD.value;
        END;
        """,
        on: database
      )
    }
  }
}

private func makeProtector(byte: UInt8) throws -> AESGCMDataProtector {
  try AESGCMDataProtector(
    key: Data(repeating: byte, count: AESGCMDataProtector.keyByteCount)
  )
}

private func makeDatabase() throws -> OpaquePointer? {
  var database: OpaquePointer?
  guard sqlite3_open(":memory:", &database) == SQLITE_OK, let database else {
    if let database { sqlite3_close(database) }
    throw SchemaFloorTestError.openFailed
  }
  return database
}

private func execute(_ sql: String, on database: OpaquePointer?) throws {
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw SchemaFloorTestError.executionFailed
  }
}

private func integerQuery(
  _ sql: String,
  on database: OpaquePointer?
) throws -> Int {
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
    let statement
  else {
    throw SchemaFloorTestError.queryFailed
  }
  defer { sqlite3_finalize(statement) }
  guard sqlite3_step(statement) == SQLITE_ROW else {
    throw SchemaFloorTestError.queryFailed
  }
  return Int(sqlite3_column_int64(statement, 0))
}

private enum SchemaFloorTestError: Error {
  case openFailed
  case executionFailed
  case queryFailed
}
