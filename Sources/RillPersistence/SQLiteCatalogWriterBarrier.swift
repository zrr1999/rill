import SQLite3

/// A connection opened by schema 12 cannot write after a catalog upgrade,
/// even when it still holds the older v11 writer capability.
enum SQLiteCatalogWriterBarrier {
  static func register(on database: OpaquePointer?) throws {
    let result = sqlite3_create_function_v2(
      database, "rill_catalog_writer_v13", 0,
      SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS,
      nil, { context, _, _ in sqlite3_result_int(context, 13) }, nil, nil, nil
    )
    guard result == SQLITE_OK else { throw SQLiteWriterBarrierError.capabilityRegistrationFailed }
  }

  static func install(on database: OpaquePointer?, tables: [String]) throws {
    for table in tables {
      for operation in ["INSERT", "UPDATE", "DELETE"] {
        let sql = """
          CREATE TRIGGER rill_catalog_v13_\(table)_\(operation.lowercased())
          BEFORE \(operation) ON \(table)
          BEGIN SELECT CASE WHEN rill_catalog_writer_v13() != 13 THEN RAISE(ABORT, 'Catalog writer required') END; END;
          """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
          throw SQLiteWriterBarrierError.triggerInstallationFailed
        }
      }
    }
  }
}
