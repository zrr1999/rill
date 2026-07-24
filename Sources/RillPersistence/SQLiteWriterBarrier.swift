import SQLite3

private func sqliteWriterCapabilityV11(
  _ context: OpaquePointer?,
  _ argumentCount: Int32,
  _ arguments: UnsafeMutablePointer<OpaquePointer?>?
) {
  sqlite3_result_int(context, Int32(SQLiteWriterBarrier.schemaVersion))
}

enum SQLiteWriterBarrierError: Error, Equatable, Sendable {
  case invalidDatabase
  case invalidTableSet
  case capabilityRegistrationFailed
  case triggerInstallationFailed
  case triggerValidationFailed
}

enum SQLiteWriterBarrier {
  static let schemaVersion = 11
  static let capabilityFunctionName = "rill_writer_capability_v11"

  private static let triggerPrefix = "rill_writer_barrier_v11_"
  private static let installationSavepoint = "rill_writer_barrier_v11_install"

  private enum Operation: String, CaseIterable {
    case insert = "INSERT"
    case update = "UPDATE"
    case delete = "DELETE"

    var nameComponent: String { rawValue.lowercased() }
  }

  private struct TriggerDefinition: Equatable {
    let name: String
    let tableName: String
    let storedSQL: String

    var installationSQL: String {
      storedSQL.replacingOccurrences(
        of: "CREATE TRIGGER",
        with: "CREATE TRIGGER IF NOT EXISTS",
        options: .anchored
      )
    }
  }

  static func registerCapability(on database: OpaquePointer?) throws {
    guard let database else {
      throw SQLiteWriterBarrierError.invalidDatabase
    }
    let flags = SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS
    guard
      sqlite3_create_function_v2(
        database,
        capabilityFunctionName,
        0,
        flags,
        nil,
        sqliteWriterCapabilityV11,
        nil,
        nil,
        nil
      ) == SQLITE_OK
    else {
      throw SQLiteWriterBarrierError.capabilityRegistrationFailed
    }
    guard registeredCapabilityMatchesSchemaVersion(on: database) else {
      throw SQLiteWriterBarrierError.capabilityRegistrationFailed
    }
  }

  static func installTriggers(
    on database: OpaquePointer?,
    tableNames: [String]
  ) throws {
    guard let database else {
      throw SQLiteWriterBarrierError.invalidDatabase
    }
    let definitions = try triggerDefinitions(for: tableNames)
    guard execute("SAVEPOINT \(installationSavepoint);", on: database) else {
      throw SQLiteWriterBarrierError.triggerInstallationFailed
    }

    do {
      for definition in definitions {
        guard execute(definition.installationSQL, on: database) else {
          throw SQLiteWriterBarrierError.triggerInstallationFailed
        }
      }
      try validateTriggers(on: database, tableNames: tableNames)
      guard execute("RELEASE SAVEPOINT \(installationSavepoint);", on: database) else {
        throw SQLiteWriterBarrierError.triggerInstallationFailed
      }
    } catch {
      let rollbackSucceeded = execute(
        "ROLLBACK TO SAVEPOINT \(installationSavepoint);",
        on: database
      )
      let releaseSucceeded = execute(
        "RELEASE SAVEPOINT \(installationSavepoint);",
        on: database
      )
      guard rollbackSucceeded, releaseSucceeded else {
        throw SQLiteWriterBarrierError.triggerInstallationFailed
      }
      throw error
    }
  }

  static func validateTriggers(
    on database: OpaquePointer?,
    tableNames: [String]
  ) throws {
    guard let database else {
      throw SQLiteWriterBarrierError.invalidDatabase
    }
    let expectedDefinitions = try triggerDefinitions(for: tableNames)
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        """
        SELECT name, tbl_name, sql
        FROM main.sqlite_schema
        WHERE type = 'trigger'
          AND name GLOB 'rill_writer_barrier_v11_*'
        ORDER BY name ASC;
        """,
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLiteWriterBarrierError.triggerValidationFailed
    }
    defer { sqlite3_finalize(statement) }

    var storedDefinitions: [TriggerDefinition] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        guard
          let name = textColumn(statement, index: 0),
          let tableName = textColumn(statement, index: 1),
          let sql = textColumn(statement, index: 2)
        else {
          throw SQLiteWriterBarrierError.triggerValidationFailed
        }
        storedDefinitions.append(
          TriggerDefinition(name: name, tableName: tableName, storedSQL: sql)
        )
      case SQLITE_DONE:
        guard storedDefinitions == expectedDefinitions else {
          throw SQLiteWriterBarrierError.triggerValidationFailed
        }
        return
      default:
        throw SQLiteWriterBarrierError.triggerValidationFailed
      }
    }
  }

  private static func triggerDefinitions(
    for tableNames: [String]
  ) throws -> [TriggerDefinition] {
    guard !tableNames.isEmpty,
      Set(tableNames).count == tableNames.count,
      tableNames.allSatisfy(isValidTableName)
    else {
      throw SQLiteWriterBarrierError.invalidTableSet
    }

    return tableNames.sorted().flatMap { tableName in
      Operation.allCases.map { operation in
        let name = triggerPrefix + tableName + "_" + operation.nameComponent
        let sql = """
          CREATE TRIGGER "\(name)"
          BEFORE \(operation.rawValue) ON "\(tableName)"
          FOR EACH ROW
          WHEN \(capabilityFunctionName)() IS NOT \(schemaVersion)
          BEGIN
            SELECT RAISE(ABORT, 'Rill database requires a compatible writer.');
          END
          """
        return TriggerDefinition(name: name, tableName: tableName, storedSQL: sql)
      }
    }
    .sorted { $0.name < $1.name }
  }

  private static func isValidTableName(_ tableName: String) -> Bool {
    let bytes = Array(tableName.utf8)
    guard !bytes.isEmpty, bytes.count <= 64,
      let first = bytes.first,
      first == 95 || (97...122).contains(first)
    else {
      return false
    }
    return bytes.allSatisfy { byte in
      byte == 95 || (48...57).contains(byte) || (97...122).contains(byte)
    }
  }

  private static func execute(_ sql: String, on database: OpaquePointer?) -> Bool {
    sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
  }

  private static func registeredCapabilityMatchesSchemaVersion(
    on database: OpaquePointer?
  ) -> Bool {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT rill_writer_capability_v11();",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      return false
    }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_ROW
      && sqlite3_column_type(statement, 0) == SQLITE_INTEGER
      && sqlite3_column_int64(statement, 0) == Int64(schemaVersion)
      && sqlite3_step(statement) == SQLITE_DONE
  }

  private static func textColumn(
    _ statement: OpaquePointer?,
    index: Int32
  ) -> String? {
    guard let text = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: text)
  }
}
