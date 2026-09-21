import SQLite3

/// Prevents an older writer from changing source revisions after the memory migration.
enum SQLiteMemoryWriterBarrier {
  static func register(on database: OpaquePointer?) throws {
    let result = sqlite3_create_function_v2(
      database, "rill_memory_writer_v14", 0,
      SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS,
      nil, { context, _, _ in sqlite3_result_int(context, 14) }, nil, nil, nil
    )
    guard result == SQLITE_OK else { throw SQLiteWriterBarrierError.capabilityRegistrationFailed }
  }

  static func install(on database: OpaquePointer?, tables: [String]) throws {
    for table in tables {
      for operation in ["INSERT", "UPDATE", "DELETE"] {
        let sql = """
          CREATE TRIGGER rill_memory_v14_\(table)_\(operation.lowercased())
          BEFORE \(operation) ON \(table)
          BEGIN SELECT CASE WHEN rill_memory_writer_v14() != 14 THEN RAISE(ABORT, 'Memory writer required') END; END;
          """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
          throw SQLiteWriterBarrierError.triggerInstallationFailed
        }
      }
    }
  }
}
