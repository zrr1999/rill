import SQLite3

/// Capabilities remain distinct so older connections cannot write through later migrations.
enum SQLiteSchemaWriterBarrier {
  case catalog
  case memory

  private var version: Int32 { self == .catalog ? 13 : 14 }
  private var name: String { self == .catalog ? "catalog" : "memory" }
  private var rejection: String {
    self == .catalog ? "Catalog writer required" : "Memory writer required"
  }
  private var function: String { "rill_\(name)_writer_v\(version)" }

  func register(on database: OpaquePointer?) throws {
    let result = sqlite3_create_function_v2(
      database, function, 0,
      SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS,
      UnsafeMutableRawPointer(bitPattern: Int(version)),
      { context, _, _ in
        sqlite3_result_int(context, Int32(Int(bitPattern: sqlite3_user_data(context))))
      }, nil, nil, nil
    )
    guard result == SQLITE_OK else { throw SQLiteWriterBarrierError.capabilityRegistrationFailed }
  }

  func install(on database: OpaquePointer?, tables: [String]) throws {
    for table in tables {
      for operation in ["INSERT", "UPDATE", "DELETE"] {
        let sql = """
          CREATE TRIGGER rill_\(name)_v\(version)_\(table)_\(operation.lowercased())
          BEFORE \(operation) ON \(table)
          BEGIN SELECT CASE WHEN \(function)() != \(version) THEN RAISE(ABORT, '\(rejection)') END; END;
          """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
          throw SQLiteWriterBarrierError.triggerInstallationFailed
        }
      }
    }
  }
}
