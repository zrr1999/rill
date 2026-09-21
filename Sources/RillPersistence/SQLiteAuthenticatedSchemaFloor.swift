import CryptoKit
import Foundation
import SQLite3
import RillCore

private let schemaFloorSQLiteTransient = unsafeBitCast(
  -1,
  to: sqlite3_destructor_type.self
)

enum SQLiteAuthenticatedSchemaFloorError: Error, Equatable, Sendable {
  case invalidDatabase
  case installationFailed
  case validationFailed
}

/// Authenticates the minimum schema understood by every future database writer.
///
/// Installation deliberately participates in the caller's migration transaction.
/// The row is self-authenticating: both its associated data and plaintext bind the
/// database identity, while the plaintext also binds the format and schema floor.
/// This prevents an older writer from silently lowering `user_version`; because
/// the marker lives in the same file, whole-file snapshot rollback remains a
/// separate threat that would require a monotonic record outside SQLite.
enum SQLiteAuthenticatedSchemaFloor {
  static let installedSchemaFloor = 14
  static let legacySchemaFloor = 11
  static let tableName = "rill_authenticated_schema_floor"

  private static let formatVersion = 2
  private static let maximumVerificationByteCount = 4_096
  private static let schemaFingerprintDomain = Data(
    "rill:sqlite-schema-fingerprint:v1".utf8
  )
  private static let storedTableSQL = """
    CREATE TABLE rill_authenticated_schema_floor (
      id INTEGER NOT NULL PRIMARY KEY CHECK (id = 1),
      database_id TEXT NOT NULL CHECK (
        length(database_id) = 36
        AND database_id = lower(database_id)
        AND substr(database_id, 9, 1) = '-'
        AND substr(database_id, 14, 1) = '-'
        AND substr(database_id, 19, 1) = '-'
        AND substr(database_id, 24, 1) = '-'
        AND length(replace(database_id, '-', '')) = 32
        AND replace(database_id, '-', '') NOT GLOB '*[^0-9a-f]*'
      ),
      schema_floor INTEGER NOT NULL CHECK (schema_floor >= 11),
      verification TEXT NOT NULL CHECK (
        length(verification) BETWEEN 1 AND 4096
      )
    ) STRICT
    """

  /// Installs an authenticated floor. The caller must already own a write transaction.
  static func install(
    on database: OpaquePointer?,
    databaseID: UUID,
    schemaFloor: Int = installedSchemaFloor,
    localDataProtector: any LocalDataProtector
  ) throws {
    guard let database else {
      throw SQLiteAuthenticatedSchemaFloorError.invalidDatabase
    }
    guard sqlite3_get_autocommit(database) == 0,
      schemaFloor >= legacySchemaFloor,
      schemaFloor <= installedSchemaFloor
    else {
      throw SQLiteAuthenticatedSchemaFloorError.installationFailed
    }

    guard sqlite3_exec(database, storedTableSQL + ";", nil, nil, nil) == SQLITE_OK else {
      throw SQLiteAuthenticatedSchemaFloorError.installationFailed
    }

    let canonicalDatabaseID = databaseID.uuidString.lowercased()
    let verification: String
    do {
      let fingerprint = try schemaFingerprint(on: database)
      verification = try localDataProtector.seal(
        verificationPlaintext(
          databaseID: canonicalDatabaseID,
          schemaFloor: schemaFloor,
          schemaFingerprint: fingerprint
        ),
        context: protectionContext(databaseID: canonicalDatabaseID)
      )
    } catch {
      throw SQLiteAuthenticatedSchemaFloorError.installationFailed
    }
    guard verification.utf8.count <= maximumVerificationByteCount else {
      throw SQLiteAuthenticatedSchemaFloorError.installationFailed
    }

    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        """
        INSERT INTO main.rill_authenticated_schema_floor (
          id, database_id, schema_floor, verification
        ) VALUES (1, ?, ?, ?);
        """,
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLiteAuthenticatedSchemaFloorError.installationFailed
    }
    defer { sqlite3_finalize(statement) }

    guard bindText(canonicalDatabaseID, at: 1, in: statement),
      sqlite3_bind_int64(statement, 2, Int64(schemaFloor)) == SQLITE_OK,
      bindText(verification, at: 3, in: statement),
      sqlite3_step(statement) == SQLITE_DONE
    else {
      throw SQLiteAuthenticatedSchemaFloorError.installationFailed
    }
  }

  /// Returns `nil` only when the table is absent, allowing one explicit legacy
  /// recovery branch. Any present-but-invalid representation fails closed.
  static func readAndValidate(
    on database: OpaquePointer?,
    localDataProtector: any LocalDataProtector
  ) throws -> Int? {
    guard let database else {
      throw SQLiteAuthenticatedSchemaFloorError.invalidDatabase
    }
    guard let tableSQL = try installedTableSQL(on: database) else { return nil }
    guard tableSQL == storedTableSQL else {
      throw SQLiteAuthenticatedSchemaFloorError.validationFailed
    }

    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        """
        SELECT id, database_id, schema_floor, verification
        FROM main.rill_authenticated_schema_floor
        ORDER BY id ASC;
        """,
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLiteAuthenticatedSchemaFloorError.validationFailed
    }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_step(statement) == SQLITE_ROW,
      sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
      sqlite3_column_int64(statement, 0) == 1,
      sqlite3_column_type(statement, 1) == SQLITE_TEXT,
      let databaseID = textColumn(statement, index: 1),
      isCanonicalDatabaseID(databaseID),
      sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
      let schemaFloor = Int(exactly: sqlite3_column_int64(statement, 2)),
      schemaFloor >= legacySchemaFloor,
      schemaFloor <= installedSchemaFloor,
      sqlite3_column_type(statement, 3) == SQLITE_TEXT,
      sqlite3_column_bytes(statement, 3) <= maximumVerificationByteCount,
      let verification = textColumn(statement, index: 3),
      !verification.isEmpty,
      sqlite3_step(statement) == SQLITE_DONE
    else {
      throw SQLiteAuthenticatedSchemaFloorError.validationFailed
    }

    do {
      let fingerprint = try schemaFingerprint(on: database)
      let plaintext = try localDataProtector.open(
        verification,
        context: protectionContext(databaseID: databaseID)
      )
      guard
        plaintext
          == verificationPlaintext(
            databaseID: databaseID,
            schemaFloor: schemaFloor,
            schemaFingerprint: fingerprint
          )
      else {
        throw SQLiteAuthenticatedSchemaFloorError.validationFailed
      }
    } catch {
      throw SQLiteAuthenticatedSchemaFloorError.validationFailed
    }
    return schemaFloor
  }

  /// Captures the authenticated database identity before a schema-changing
  /// transaction updates the fingerprint.
  static func validatedDatabaseID(
    on database: OpaquePointer?,
    localDataProtector: any LocalDataProtector
  ) throws -> UUID {
    _ = try readAndValidate(on: database, localDataProtector: localDataProtector)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
      database,
      "SELECT database_id FROM main.rill_authenticated_schema_floor WHERE id = 1;",
      -1,
      &statement,
      nil
    ) == SQLITE_OK, let statement else {
      throw SQLiteAuthenticatedSchemaFloorError.validationFailed
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      let rawID = textColumn(statement, index: 0),
      let databaseID = UUID(uuidString: rawID),
      databaseID.uuidString.lowercased() == rawID,
      sqlite3_step(statement) == SQLITE_DONE
    else {
      throw SQLiteAuthenticatedSchemaFloorError.validationFailed
    }
    return databaseID
  }

  /// Re-signs the schema floor after DDL has changed the authenticated
  /// fingerprint. The database ID must have been validated earlier in the same
  /// write transaction.
  static func upgrade(
    on database: OpaquePointer?,
    validatedDatabaseID databaseID: UUID,
    localDataProtector: any LocalDataProtector,
    schemaFloor: Int = installedSchemaFloor
  ) throws {
    guard let database, sqlite3_get_autocommit(database) == 0 else {
      throw SQLiteAuthenticatedSchemaFloorError.installationFailed
    }
    let canonicalDatabaseID = databaseID.uuidString.lowercased()
    let verification: String
    do {
      verification = try localDataProtector.seal(
        verificationPlaintext(
          databaseID: canonicalDatabaseID,
          schemaFloor: schemaFloor,
          schemaFingerprint: try schemaFingerprint(on: database)
        ),
        context: protectionContext(databaseID: canonicalDatabaseID)
      )
    } catch {
      throw SQLiteAuthenticatedSchemaFloorError.installationFailed
    }
    guard verification.utf8.count <= maximumVerificationByteCount else {
      throw SQLiteAuthenticatedSchemaFloorError.installationFailed
    }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
      database,
      "UPDATE main.rill_authenticated_schema_floor SET schema_floor = ?, verification = ? WHERE id = 1 AND database_id = ?;",
      -1,
      &statement,
      nil
    ) == SQLITE_OK, let statement else {
      throw SQLiteAuthenticatedSchemaFloorError.installationFailed
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_bind_int64(statement, 1, Int64(schemaFloor)) == SQLITE_OK,
      bindText(verification, at: 2, in: statement),
      bindText(canonicalDatabaseID, at: 3, in: statement),
      sqlite3_step(statement) == SQLITE_DONE,
      sqlite3_changes(database) == 1
    else {
      throw SQLiteAuthenticatedSchemaFloorError.installationFailed
    }
  }

  private static func installedTableSQL(on database: OpaquePointer?) throws -> String? {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        """
        SELECT type, sql
        FROM main.sqlite_schema
        WHERE name = 'rill_authenticated_schema_floor';
        """,
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLiteAuthenticatedSchemaFloorError.validationFailed
    }
    defer { sqlite3_finalize(statement) }

    switch sqlite3_step(statement) {
    case SQLITE_DONE:
      return nil
    case SQLITE_ROW:
      guard textColumn(statement, index: 0) == "table",
        let sql = textColumn(statement, index: 1),
        sqlite3_step(statement) == SQLITE_DONE
      else {
        throw SQLiteAuthenticatedSchemaFloorError.validationFailed
      }
      return sql
    default:
      throw SQLiteAuthenticatedSchemaFloorError.validationFailed
    }
  }

  private static func protectionContext(
    databaseID: String
  ) -> LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: "rill.sqlite.authenticated-schema-floor",
      recordID: databaseID,
      field: "verification.v2"
    )
  }

  private static func verificationPlaintext(
    databaseID: String,
    schemaFloor: Int,
    schemaFingerprint: Data
  ) -> Data {
    Data(
      """
      rill:sqlite-authenticated-schema-floor
      format-version:\(formatVersion)
      database-id:\(databaseID)
      schema-floor:\(schemaFloor)
      schema-fingerprint-sha256:\(schemaFingerprint.hexadecimalString())
      """.utf8
    )
  }

  private static func schemaFingerprint(on database: OpaquePointer?) throws -> Data {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        """
        SELECT type, name, tbl_name, sql
        FROM main.sqlite_schema
        WHERE type IN ('table', 'index', 'view', 'trigger')
          AND name NOT GLOB 'sqlite_*'
          AND NOT (
            type = 'trigger'
            AND name GLOB 'rill_writer_barrier_v11_*'
          )
        ORDER BY
          type COLLATE BINARY ASC,
          name COLLATE BINARY ASC,
          tbl_name COLLATE BINARY ASC,
          sql COLLATE BINARY ASC;
        """,
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLiteAuthenticatedSchemaFloorError.validationFailed
    }
    defer { sqlite3_finalize(statement) }

    var hasher = SHA256()
    updateFingerprint(schemaFingerprintDomain, hasher: &hasher)
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        guard
          let type = textColumn(statement, index: 0),
          let name = textColumn(statement, index: 1),
          let tableName = textColumn(statement, index: 2),
          let sql = textColumn(statement, index: 3)
        else {
          throw SQLiteAuthenticatedSchemaFloorError.validationFailed
        }
        for component in [type, name, tableName, sql] {
          updateFingerprint(Data(component.utf8), hasher: &hasher)
        }
      case SQLITE_DONE:
        return Data(hasher.finalize())
      default:
        throw SQLiteAuthenticatedSchemaFloorError.validationFailed
      }
    }
  }

  private static func updateFingerprint(
    _ component: Data,
    hasher: inout SHA256
  ) {
    var length = UInt64(component.count).bigEndian
    withUnsafeBytes(of: &length) { bytes in
      hasher.update(data: Data(bytes))
    }
    hasher.update(data: component)
  }

  private static func isCanonicalDatabaseID(_ databaseID: String) -> Bool {
    guard let uuid = UUID(uuidString: databaseID) else { return false }
    return uuid.uuidString.lowercased() == databaseID
  }

  private static func bindText(
    _ value: String,
    at index: Int32,
    in statement: OpaquePointer?
  ) -> Bool {
    value.withCString { pointer in
      sqlite3_bind_text(
        statement,
        index,
        pointer,
        -1,
        schemaFloorSQLiteTransient
      ) == SQLITE_OK
    }
  }

  private static func textColumn(
    _ statement: OpaquePointer?,
    index: Int32
  ) -> String? {
    let byteCount = Int(sqlite3_column_bytes(statement, index))
    guard byteCount >= 0,
      let bytes = sqlite3_column_text(statement, index)
    else { return nil }
    return String(
      data: Data(bytes: bytes, count: byteCount),
      encoding: .utf8
    )
  }
}

extension Data {
  fileprivate func hexadecimalString() -> String {
    map { String(format: "%02x", $0) }.joined()
  }
}
