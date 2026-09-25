import Darwin
import Foundation
import SQLite3
import RillCore

extension SQLitePersistenceStore {
  static func preexistingStorageMayContainResidue(
    at databaseURL: URL,
    fileManager: FileManager = .default
  ) -> Bool {
    let storageURLs = [
      databaseURL,
      URL(fileURLWithPath: databaseURL.path + "-wal"),
      URL(fileURLWithPath: databaseURL.path + "-journal"),
    ]
    for storageURL in storageURLs where fileManager.fileExists(atPath: storageURL.path) {
      guard let attributes = try? fileManager.attributesOfItem(atPath: storageURL.path),
        let size = attributes[.size] as? NSNumber
      else {
        // Failure to inspect an existing file must not skip a one-time purge.
        return true
      }
      if size.int64Value > 0 {
        return true
      }
    }
    return false
  }

  static func schemaVersion(on handle: OpaquePointer?) throws -> Int {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else {
      throw SQLitePersistenceError.migrationFailed("Failed to read schema version")
    }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else {
      throw SQLitePersistenceError.migrationFailed("Failed to read schema version")
    }
    return Int(sqlite3_column_int(stmt, 0))
  }

  static func setSchemaVersion(_ version: Int, on handle: OpaquePointer?) throws {
    let sql = "PRAGMA user_version = \(version)"
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
      throw SQLitePersistenceError.migrationFailed("Failed to set schema version")
    }
  }

  static let currentSchemaVersion = 14
  static let writerBarrierTableNames = [
    "app_settings",
    "clipboard_image_blobs",
    "clipboard_metadata",
    "diagnostic_events",
    "export_metadata",
    "history_records",
    "local_data_protection",
    "record_catalog_nodes",
    "record_graph_metadata",
    "record_payload_blobs",
    "run_history_generation",
    "run_history_write_sequence",
    SQLiteAuthenticatedSchemaFloor.tableName,
    "workflow_run_receipts",
  ]
  static let inconsistentDataProtectionMetadataMessage =
    "Local data protection metadata is inconsistent with the schema version."
  static let keyVerificationPlaintext = Data("Rill local data key verification v1".utf8)

  static func migrate(
    on handle: OpaquePointer?,
    localDataProtector: any LocalDataProtector,
    preexistingStorageMayContainResidue: Bool
  ) throws -> Bool {
    do {
      try execute("BEGIN IMMEDIATE TRANSACTION;", on: handle)
      let cleanupIsPending = try migrateWithinTransaction(
        on: handle,
        localDataProtector: localDataProtector,
        preexistingStorageMayContainResidue: preexistingStorageMayContainResidue
      )
      try execute("COMMIT;", on: handle)
      return cleanupIsPending
    } catch {
      try? execute("ROLLBACK;", on: handle)
      throw error
    }
  }

  static func migrateWithinTransaction(
    on handle: OpaquePointer?,
    localDataProtector: any LocalDataProtector,
    preexistingStorageMayContainResidue: Bool
  ) throws -> Bool {
    let storedVersion = try schemaVersion(on: handle)
    guard storedVersion <= currentSchemaVersion else {
      throw SQLitePersistenceError.migrationFailed(
        "Database version \(storedVersion) is newer than supported version \(currentSchemaVersion)."
      )
    }
    let authenticatedSchemaFloor = try authenticatedSchemaFloor(
      on: handle,
      localDataProtector: localDataProtector
    )
    if let authenticatedSchemaFloor {
      guard authenticatedSchemaFloor >= SQLiteAuthenticatedSchemaFloor.legacySchemaFloor,
        authenticatedSchemaFloor <= SQLiteAuthenticatedSchemaFloor.installedSchemaFloor,
        authenticatedSchemaFloor <= currentSchemaVersion,
        storedVersion <= currentSchemaVersion
      else {
        throw SQLitePersistenceError.migrationFailed(
          "The stored schema version conflicts with its authenticated floor."
        )
      }
      if authenticatedSchemaFloor == SQLiteAuthenticatedSchemaFloor.legacySchemaFloor {
        guard storedVersion == SQLiteAuthenticatedSchemaFloor.legacySchemaFloor else {
          throw SQLitePersistenceError.migrationFailed(
            "The legacy authenticated schema metadata conflicts with its version."
          )
        }
        let cleanupIsPending = try validateDataProtectionKey(
          on: handle,
          localDataProtector: localDataProtector
        )
        try SQLiteWriterBarrier.validateTriggers(
          on: handle,
          tableNames: writerBarrierTableNames.filter {
            $0 != "record_catalog_nodes" && $0 != "record_graph_metadata" && $0 != "record_payload_blobs"
          }
        )
        try migrateToV12(on: handle, localDataProtector: localDataProtector)
        try requireQuickCheck(on: handle)
        return cleanupIsPending
      }
      if authenticatedSchemaFloor == 12 {
        guard storedVersion <= 12 else {
          throw SQLitePersistenceError.migrationFailed("Schema version conflicts with its authenticated floor.")
        }
        let cleanupIsPending = try validateDataProtectionKey(on: handle, localDataProtector: localDataProtector)
        try setSchemaVersion(12, on: handle)
        try migrateToV13(on: handle, localDataProtector: localDataProtector)
        return cleanupIsPending
      }
      if authenticatedSchemaFloor == 13 {
        guard storedVersion <= 13 else {
          throw SQLitePersistenceError.migrationFailed("Schema version conflicts with its authenticated floor.")
        }
        let cleanupIsPending = try validateDataProtectionKey(on: handle, localDataProtector: localDataProtector)
        try SQLiteWriterBarrier.validateTriggers(on: handle, tableNames: writerBarrierTableNames)
        try setSchemaVersion(13, on: handle)
        try migrateToV14(on: handle, localDataProtector: localDataProtector)
        return cleanupIsPending
      }
      if storedVersion < authenticatedSchemaFloor {
        return try recoverAuthenticatedSchemaFloor(
          authenticatedSchemaFloor,
          on: handle,
          localDataProtector: localDataProtector
        )
      }
      let cleanupIsPending = try validateDataProtectionKey(
        on: handle,
        localDataProtector: localDataProtector
      )
      try validateAuthenticatedStorageBoundary(
        on: handle,
        localDataProtector: localDataProtector
      )
      try requireQuickCheck(on: handle)
      return cleanupIsPending
    }

    guard storedVersion < SQLiteAuthenticatedSchemaFloor.legacySchemaFloor else {
      throw SQLitePersistenceError.migrationFailed(
        "Authenticated schema metadata is unavailable for this schema version."
      )
    }

    var effectiveVersion = storedVersion
    let cleanupIsPending: Bool
    if storedVersion < 4,
      try tableExists("local_data_protection", on: handle)
    {
      cleanupIsPending = try recoverDowngradedV4Database(
        on: handle,
        localDataProtector: localDataProtector
      )
      effectiveVersion = 4
    } else {
      // The baseline DDL is idempotent and also repairs an interrupted v1
      // creation that advanced user_version before every table was present.
      try migrateToV1(on: handle)
      if storedVersion < 2 {
        try migrateToV2(on: handle)
      }
      if storedVersion < 3 {
        try migrateToV3(on: handle)
      }
      if storedVersion < 4 {
        cleanupIsPending = try migrateToV4(
          on: handle,
          localDataProtector: localDataProtector,
          requiresResidueCleanup: storedVersion > 0 || preexistingStorageMayContainResidue
        )
      } else {
        try ensureCleanupPendingColumn(on: handle)
        cleanupIsPending = try validateDataProtectionKey(
          on: handle,
          localDataProtector: localDataProtector
        )
      }
    }
    if effectiveVersion < 5 {
      try migrateToV5(on: handle)
    }
    if effectiveVersion < 6 {
      try migrateToV6(on: handle)
    }
    if effectiveVersion < 7 {
      try migrateToV7(on: handle)
    }
    if effectiveVersion < 8 {
      try migrateToV8(on: handle)
    }
    if effectiveVersion < 9 {
      try migrateToV9(on: handle, localDataProtector: localDataProtector)
    }
    if effectiveVersion < 10 {
      try migrateToV10(on: handle)
    }
    if effectiveVersion < 11 {
      try migrateToV11(
        on: handle,
        localDataProtector: localDataProtector
      )
    }
    if effectiveVersion < 12 {
      try migrateToV12(
        on: handle,
        localDataProtector: localDataProtector
      )
    }
    return cleanupIsPending
  }

  static func migrateToV1(on handle: OpaquePointer?) throws {
    try execute(
      """
      CREATE TABLE IF NOT EXISTS history_records (
          id TEXT PRIMARY KEY,
          run_id TEXT,
          workflow_id TEXT,
          workflow_fallback_name TEXT NOT NULL,
          workflow_title_key TEXT,
          final_text TEXT,
          failure_message TEXT,
          timestamp REAL NOT NULL,
          is_stack_related INTEGER NOT NULL,
          outcome TEXT NOT NULL
      );

      CREATE INDEX IF NOT EXISTS idx_history_records_timestamp
      ON history_records (timestamp DESC);

      CREATE TABLE IF NOT EXISTS diagnostic_events (
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

      CREATE INDEX IF NOT EXISTS idx_diagnostic_events_timestamp
      ON diagnostic_events (timestamp DESC);

      CREATE TABLE IF NOT EXISTS app_settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL,
          updated_at REAL NOT NULL
      );

      CREATE TABLE IF NOT EXISTS export_metadata (
          id TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          destination_path TEXT NOT NULL,
          item_count INTEGER NOT NULL,
          created_at REAL NOT NULL,
          metadata_json TEXT NOT NULL
      );

      CREATE INDEX IF NOT EXISTS idx_export_metadata_created_at
      ON export_metadata (created_at DESC);
      """,
      on: handle
    )
  }

  static func migrateToV2(on handle: OpaquePointer?) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        "UPDATE history_records SET failure_message = ? WHERE failure_message IS NOT NULL;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Failed to prepare history failure sanitization.")
    }
    defer { sqlite3_finalize(statement) }

    let bindResult = HistoryFailureSanitizer.genericMessage.withCString {
      sqlite3_bind_text(statement, 1, $0, -1, sqliteTransient)
    }
    guard bindResult == SQLITE_OK else {
      throw SQLitePersistenceError.migrationFailed("Failed to bind sanitized history failure text.")
    }
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw SQLitePersistenceError.migrationFailed("Failed to sanitize existing history failures.")
    }
  }

  static func migrateToV3(on handle: OpaquePointer?) throws {
    if try historyRecordsHasColumn("correction_source_json", on: handle) {
      return
    }

    do {
      try execute(
        "ALTER TABLE history_records ADD COLUMN correction_source_json TEXT;",
        on: handle
      )
    } catch let error as SQLitePersistenceError {
      throw SQLitePersistenceError.migrationFailed(
        error.errorDescription ?? "Failed to add history correction provenance."
      )
    }
  }

  static func historyRecordsHasColumn(
    _ columnName: String,
    on handle: OpaquePointer?
  ) throws -> Bool {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        "PRAGMA table_info(history_records);",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Failed to inspect history columns before migration."
      )
    }
    defer { sqlite3_finalize(statement) }

    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        guard let rawName = sqlite3_column_text(statement, 1) else { continue }
        if String(cString: rawName) == columnName {
          return true
        }
      case SQLITE_DONE:
        return false
      default:
        throw SQLitePersistenceError.migrationFailed(
          "Failed to inspect history columns before migration."
        )
      }
    }
  }

  static func tableExists(
    _ tableName: String,
    on handle: OpaquePointer?
  ) throws -> Bool {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Failed to inspect local data protection metadata."
      )
    }
    defer { sqlite3_finalize(statement) }
    try bindMigrationValues([.text(tableName)], to: statement, on: handle)
    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      return true
    case SQLITE_DONE:
      return false
    default:
      throw SQLitePersistenceError.migrationFailed(
        "Failed to inspect local data protection metadata."
      )
    }
  }

  static func tableHasColumn(
    tableName: String,
    columnName: String,
    on handle: OpaquePointer?
  ) throws -> Bool {
    let allowedTableNames = Set([
      "local_data_protection",
      "history_records",
      "workflow_run_receipts",
      "diagnostic_events",
    ])
    guard allowedTableNames.contains(tableName) else {
      throw SQLitePersistenceError.migrationFailed(
        "Unsupported table inspection during migration."
      )
    }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        "PRAGMA table_info(\(tableName));",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Failed to inspect local data protection metadata."
      )
    }
    defer { sqlite3_finalize(statement) }
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        if staticTextColumn(in: statement, index: 1) == columnName {
          return true
        }
      case SQLITE_DONE:
        return false
      default:
        throw SQLitePersistenceError.migrationFailed(
          "Failed to inspect local data protection metadata."
        )
      }
    }
  }

  static func ensureCleanupPendingColumn(
    on handle: OpaquePointer?
  ) throws {
    guard try tableExists("local_data_protection", on: handle) else {
      throw SQLitePersistenceError.migrationFailed(
        "Local data protection metadata is unavailable."
      )
    }
    guard
      try !tableHasColumn(
        tableName: "local_data_protection",
        columnName: "cleanup_pending",
        on: handle
      )
    else {
      return
    }
    do {
      // Earlier development builds could commit v4 before this durable
      // cleanup bit existed. Default to pending so residue is purged once.
      try execute(
        """
        ALTER TABLE local_data_protection
        ADD COLUMN cleanup_pending INTEGER NOT NULL DEFAULT 1
        CHECK (cleanup_pending IN (0, 1));
        """,
        on: handle
      )
    } catch {
      throw SQLitePersistenceError.migrationFailed(
        "Local data protection cleanup state could not be repaired."
      )
    }
  }

  struct UnprotectedHistoryRow {
    var id: String
    var workflowFallbackName: String
    var finalText: String?
    var correctionSourceJSON: String?
  }

  struct UnprotectedSettingRow {
    var key: String
    var value: String
  }

  struct UnprotectedExportRow {
    var id: String
    var destinationPath: String
    var metadataJSON: String
  }

  struct LegacyDiagnosticRow {
    var id: Int64
    var eventCode: String
  }

  /// A database whose protection marker survived while `user_version` moved
  /// backwards is recoverable only when it has exactly the schema that v4
  /// owned. This deliberately excludes later tables and columns so changing the
  /// version of a newer database cannot be used to bypass downgrade detection.
  static let exactV4SchemaFingerprint: [String: String] = [
    "table:history_records": """
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
    )
    """,
    "index:idx_history_records_timestamp": """
    CREATE INDEX idx_history_records_timestamp
    ON history_records (timestamp DESC)
    """,
    "table:diagnostic_events": """
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
    )
    """,
    "index:idx_diagnostic_events_timestamp": """
    CREATE INDEX idx_diagnostic_events_timestamp
    ON diagnostic_events (timestamp DESC)
    """,
    "table:app_settings": """
    CREATE TABLE app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at REAL NOT NULL
    )
    """,
    "table:export_metadata": """
    CREATE TABLE export_metadata (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        destination_path TEXT NOT NULL,
        item_count INTEGER NOT NULL,
        created_at REAL NOT NULL,
        metadata_json TEXT NOT NULL
    )
    """,
    "index:idx_export_metadata_created_at": """
    CREATE INDEX idx_export_metadata_created_at
    ON export_metadata (created_at DESC)
    """,
    "table:local_data_protection": """
    CREATE TABLE local_data_protection (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        key_verification TEXT NOT NULL,
        cleanup_pending INTEGER NOT NULL CHECK (cleanup_pending IN (0, 1))
    )
    """,
  ]

  static let canonicalTextEnvelopePrefix =
    "\(AESGCMDataProtector.envelopePrefix):\(AESGCMDataProtector.envelopeVersion):"

  static func recoverDowngradedV4Database(
    on handle: OpaquePointer?,
    localDataProtector: any LocalDataProtector
  ) throws -> Bool {
    do {
      guard try hasExactV4SchemaFingerprint(on: handle) else {
        throw SQLitePersistenceError.migrationFailed(
          inconsistentDataProtectionMetadataMessage
        )
      }
      try validateExactV4ProtectionMarker(
        on: handle,
        localDataProtector: localDataProtector
      )

      let historyRows = try unprotectedHistoryRows(on: handle)
      let settingRows = try unprotectedSettingRows(on: handle)
      let exportRows = try unprotectedExportRows(on: handle)
      for row in historyRows {
        try recoverProtectedHistoryRow(
          row,
          on: handle,
          localDataProtector: localDataProtector
        )
      }
      for row in settingRows {
        try recoverProtectedSettingRow(
          row,
          on: handle,
          localDataProtector: localDataProtector
        )
      }
      for row in exportRows {
        try recoverProtectedExportRow(
          row,
          on: handle,
          localDataProtector: localDataProtector
        )
      }
      // Reuse the established v2 failure-text policy and v4 diagnostic policy;
      // neither legacy field is allowed to retain arbitrary plaintext.
      try migrateToV2(on: handle)
      _ = try sanitizeExistingDiagnostics(on: handle)
      try markDataProtectionCleanupPending(on: handle)
      try setSchemaVersion(4, on: handle)
      return true
    } catch {
      throw SQLitePersistenceError.migrationFailed(
        "Local data protection metadata recovery could not be completed."
      )
    }
  }

  static func hasExactV4SchemaFingerprint(
    on handle: OpaquePointer?
  ) throws -> Bool {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        """
        SELECT type, name, sql
        FROM sqlite_master
        WHERE name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
        ORDER BY type ASC, name ASC;
        """,
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Local data protection schema could not be inspected."
      )
    }
    defer { sqlite3_finalize(statement) }

    var actual: [String: String] = [:]
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        guard let type = staticTextColumn(in: statement, index: 0),
          let name = staticTextColumn(in: statement, index: 1),
          let sql = staticTextColumn(in: statement, index: 2)
        else {
          return false
        }
        actual["\(type):\(name)"] = compactSchemaSQL(sql)
      case SQLITE_DONE:
        return actual == exactV4SchemaFingerprint.mapValues(compactSchemaSQL)
      default:
        throw SQLitePersistenceError.migrationFailed(
          "Local data protection schema could not be inspected."
        )
      }
    }
  }

  static func compactSchemaSQL(_ sql: String) -> String {
    String(sql.lowercased().filter { !$0.isWhitespace })
  }

  static func validateExactV4ProtectionMarker(
    on handle: OpaquePointer?,
    localDataProtector: any LocalDataProtector
  ) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        "SELECT id, key_verification, cleanup_pending FROM local_data_protection ORDER BY id;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Local data protection metadata is unavailable."
      )
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      sqlite3_column_int64(statement, 0) == 1,
      let envelope = staticTextColumn(in: statement, index: 1),
      envelope.hasPrefix(canonicalTextEnvelopePrefix),
      [0, 1].contains(sqlite3_column_int(statement, 2)),
      sqlite3_step(statement) == SQLITE_DONE
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Local data protection metadata is unavailable."
      )
    }
    let plaintext = try localDataProtector.open(
      envelope,
      context: keyVerificationContext
    )
    guard plaintext == keyVerificationPlaintext else {
      throw SQLitePersistenceError.migrationFailed(
        "Local data protection key verification failed."
      )
    }
  }

  static func recoveredProtectedText(
    _ storedValue: String,
    context: LocalDataProtectionContext,
    localDataProtector: any LocalDataProtector
  ) throws -> String {
    if storedValue.hasPrefix(canonicalTextEnvelopePrefix) {
      let plaintext = try localDataProtector.open(
        storedValue,
        context: context
      )
      guard String(data: plaintext, encoding: .utf8) != nil else {
        throw SQLitePersistenceError.migrationFailed(
          "Protected local text was not valid UTF-8."
        )
      }
      return storedValue
    }
    guard !storedValue.hasPrefix("\(AESGCMDataProtector.envelopePrefix):") else {
      throw SQLitePersistenceError.migrationFailed(
        "Protected local text used an unsupported envelope."
      )
    }
    return try localDataProtector.seal(
      Data(storedValue.utf8),
      context: context
    )
  }

  static func recoverProtectedHistoryRow(
    _ row: UnprotectedHistoryRow,
    on handle: OpaquePointer?,
    localDataProtector: any LocalDataProtector
  ) throws {
    let fallbackName = try recoveredProtectedText(
      row.workflowFallbackName,
      context: historyProtectionContext(
        recordID: row.id,
        field: "workflow_fallback_name"
      ),
      localDataProtector: localDataProtector
    )
    let finalText = try row.finalText.map {
      try recoveredProtectedText(
        $0,
        context: historyProtectionContext(recordID: row.id, field: "final_text"),
        localDataProtector: localDataProtector
      )
    }
    let correctionSourceJSON = try row.correctionSourceJSON.map {
      try recoveredProtectedText(
        $0,
        context: historyProtectionContext(
          recordID: row.id,
          field: "correction_source_json"
        ),
        localDataProtector: localDataProtector
      )
    }
    try updateRecoveredHistoryRow(
      id: row.id,
      fallbackName: fallbackName,
      finalText: finalText,
      correctionSourceJSON: correctionSourceJSON,
      on: handle
    )
  }

  static func updateRecoveredHistoryRow(
    id: String,
    fallbackName: String,
    finalText: String?,
    correctionSourceJSON: String?,
    on handle: OpaquePointer?
  ) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        """
        UPDATE history_records
        SET workflow_fallback_name = ?, final_text = ?, correction_source_json = ?
        WHERE id = ?;
        """,
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "History data could not be recovered."
      )
    }
    defer { sqlite3_finalize(statement) }
    try bindMigrationValues(
      [
        .text(fallbackName),
        finalText.map(SQLiteBinding.text) ?? .null,
        correctionSourceJSON.map(SQLiteBinding.text) ?? .null,
        .text(id),
      ],
      to: statement,
      on: handle
    )
    guard sqlite3_step(statement) == SQLITE_DONE,
      sqlite3_changes(handle) == 1
    else {
      throw SQLitePersistenceError.migrationFailed(
        "History data could not be recovered."
      )
    }
  }

  static func recoverProtectedSettingRow(
    _ row: UnprotectedSettingRow,
    on handle: OpaquePointer?,
    localDataProtector: any LocalDataProtector
  ) throws {
    let value = try recoveredProtectedText(
      row.value,
      context: settingsProtectionContext(keyRawValue: row.key),
      localDataProtector: localDataProtector
    )
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        "UPDATE app_settings SET value = ? WHERE key = ?;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Settings data could not be recovered."
      )
    }
    defer { sqlite3_finalize(statement) }
    try bindMigrationValues(
      [.text(value), .text(row.key)],
      to: statement,
      on: handle
    )
    guard sqlite3_step(statement) == SQLITE_DONE,
      sqlite3_changes(handle) == 1
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Settings data could not be recovered."
      )
    }
  }

  static func recoverProtectedExportRow(
    _ row: UnprotectedExportRow,
    on handle: OpaquePointer?,
    localDataProtector: any LocalDataProtector
  ) throws {
    let destinationPath = try recoveredProtectedText(
      row.destinationPath,
      context: exportProtectionContext(recordID: row.id, field: "destination_path"),
      localDataProtector: localDataProtector
    )
    let metadataJSON = try recoveredProtectedText(
      row.metadataJSON,
      context: exportProtectionContext(recordID: row.id, field: "metadata_json"),
      localDataProtector: localDataProtector
    )
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        """
        UPDATE export_metadata
        SET destination_path = ?, metadata_json = ?
        WHERE id = ?;
        """,
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Export metadata could not be recovered."
      )
    }
    defer { sqlite3_finalize(statement) }
    try bindMigrationValues(
      [.text(destinationPath), .text(metadataJSON), .text(row.id)],
      to: statement,
      on: handle
    )
    guard sqlite3_step(statement) == SQLITE_DONE,
      sqlite3_changes(handle) == 1
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Export metadata could not be recovered."
      )
    }
  }

  static func markDataProtectionCleanupPending(
    on handle: OpaquePointer?
  ) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        "UPDATE local_data_protection SET cleanup_pending = 1 WHERE id = 1;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Local data protection cleanup state could not be recovered."
      )
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_DONE,
      sqlite3_changes(handle) == 1
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Local data protection cleanup state could not be recovered."
      )
    }
  }

  static func migrateToV4(
    on handle: OpaquePointer?,
    localDataProtector: any LocalDataProtector,
    requiresResidueCleanup: Bool
  ) throws -> Bool {
    do {
      try execute(
        """
        CREATE TABLE IF NOT EXISTS local_data_protection (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            key_verification TEXT NOT NULL,
            cleanup_pending INTEGER NOT NULL CHECK (cleanup_pending IN (0, 1))
        );
        """,
        on: handle
      )

      let historyRows = try unprotectedHistoryRows(on: handle)
      let settingRows = try unprotectedSettingRows(on: handle)
      let exportRows = try unprotectedExportRows(on: handle)
      let sanitizedDiagnosticCount = try sanitizeExistingDiagnostics(on: handle)
      for row in historyRows {
        try protectHistoryRow(
          row,
          on: handle,
          localDataProtector: localDataProtector
        )
      }
      for row in settingRows {
        try protectSettingRow(
          row,
          on: handle,
          localDataProtector: localDataProtector
        )
      }
      for row in exportRows {
        try protectExportRow(
          row,
          on: handle,
          localDataProtector: localDataProtector
        )
      }

      let cleanupIsPending =
        requiresResidueCleanup
        || !historyRows.isEmpty
        || !settingRows.isEmpty
        || !exportRows.isEmpty
        || sanitizedDiagnosticCount > 0
      let verificationEnvelope = try localDataProtector.seal(
        keyVerificationPlaintext,
        context: keyVerificationContext
      )
      try upsertKeyVerificationEnvelope(
        verificationEnvelope,
        cleanupIsPending: cleanupIsPending,
        on: handle
      )
      try setSchemaVersion(4, on: handle)
      return cleanupIsPending
    } catch {
      throw SQLitePersistenceError.migrationFailed(
        "Local data protection migration could not be completed."
      )
    }
  }

  static func migrateToV5(on handle: OpaquePointer?) throws {
    do {
      try execute(
        """
        CREATE TABLE IF NOT EXISTS workflow_run_receipts (
            run_id TEXT PRIMARY KEY,
            timestamp REAL NOT NULL,
            payload TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_workflow_run_receipts_timestamp
        ON workflow_run_receipts (timestamp DESC);
        """,
        on: handle
      )
      try setSchemaVersion(5, on: handle)
    } catch {
      throw SQLitePersistenceError.migrationFailed(
        "Workflow run receipt storage could not be created."
      )
    }
  }

  static func migrateToV6(on handle: OpaquePointer?) throws {
    do {
      try execute(
        """
        CREATE TABLE IF NOT EXISTS run_history_clear_barrier (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            clear_through REAL NOT NULL
        );
        """,
        on: handle
      )
      try setSchemaVersion(6, on: handle)
    } catch {
      throw SQLitePersistenceError.migrationFailed(
        "Run history clear protection could not be created."
      )
    }
  }

  static func migrateToV7(on handle: OpaquePointer?) throws {
    do {
      if try !historyRecordsHasColumn("trigger_kind", on: handle) {
        try execute(
          "ALTER TABLE history_records ADD COLUMN trigger_kind TEXT;",
          on: handle
        )
      }
      try setSchemaVersion(7, on: handle)
    } catch {
      throw SQLitePersistenceError.migrationFailed(
        "Authoritative run trigger storage could not be created."
      )
    }
  }

  static func migrateToV8(on handle: OpaquePointer?) throws {
    do {
      try execute(
        """
        CREATE TABLE IF NOT EXISTS run_history_generation (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            current_generation INTEGER NOT NULL CHECK (current_generation >= 0),
            last_clear_intent_id TEXT
        );

        INSERT INTO run_history_generation (
            id, current_generation, last_clear_intent_id
        ) VALUES (1, 0, NULL)
        ON CONFLICT(id) DO NOTHING;
        """,
        on: handle
      )
      for tableName in [
        "history_records",
        "workflow_run_receipts",
        "diagnostic_events",
      ]
      where try !tableHasColumn(
        tableName: tableName,
        columnName: "write_generation",
        on: handle
      ) {
        try execute(
          """
          ALTER TABLE \(tableName)
          ADD COLUMN write_generation INTEGER NOT NULL DEFAULT 0
          CHECK (write_generation >= 0);
          """,
          on: handle
        )
      }
      try execute("DROP TABLE IF EXISTS run_history_clear_barrier;", on: handle)
      try setSchemaVersion(8, on: handle)
    } catch {
      throw SQLitePersistenceError.migrationFailed(
        "Run-history logical generation storage could not be created."
      )
    }
  }

  struct LegacyRunHistoryOrdinalRow {
    let tableName: String
    let identifier: String
  }

  static func migrateToV9(
    on handle: OpaquePointer?,
    localDataProtector: any LocalDataProtector
  ) throws {
    do {
      for tableName in ["history_records", "workflow_run_receipts"]
      where try !tableHasColumn(
        tableName: tableName,
        columnName: "write_ordinal",
        on: handle
      ) {
        try execute(
          """
          ALTER TABLE \(tableName)
          ADD COLUMN write_ordinal INTEGER NOT NULL DEFAULT 0
          CHECK (write_ordinal >= 0);
          """,
          on: handle
        )
      }
      if try !tableHasColumn(
        tableName: "history_records",
        columnName: "has_nonempty_final_text",
        on: handle
      ) {
        try execute(
          """
          ALTER TABLE history_records
          ADD COLUMN has_nonempty_final_text INTEGER NOT NULL DEFAULT 0
          CHECK (has_nonempty_final_text IN (0, 1));
          """,
          on: handle
        )
      }
      try execute(
        """
        CREATE TABLE IF NOT EXISTS run_history_write_sequence (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            last_ordinal INTEGER NOT NULL CHECK (last_ordinal >= 0)
        );

        INSERT INTO run_history_write_sequence (id, last_ordinal)
        VALUES (1, 0)
        ON CONFLICT(id) DO NOTHING;
        """,
        on: handle
      )

      try backfillRunHistoryWriteOrdinals(on: handle)
      try backfillNonemptyHistoryBodyMetadata(
        on: handle,
        localDataProtector: localDataProtector
      )
      try execute(
        """
        CREATE INDEX IF NOT EXISTS idx_history_records_browse
        ON history_records (write_generation, timestamp DESC, id ASC, write_ordinal);

        CREATE INDEX IF NOT EXISTS idx_workflow_run_receipts_browse
        ON workflow_run_receipts (write_generation, timestamp DESC, run_id ASC, write_ordinal);
        """,
        on: handle
      )
      try setSchemaVersion(9, on: handle)
    } catch {
      throw SQLitePersistenceError.migrationFailed(
        "Run-history snapshot browsing storage could not be created."
      )
    }
  }

  static func migrateToV10(on handle: OpaquePointer?) throws {
    do {
      try execute(
        """
        CREATE TABLE IF NOT EXISTS clipboard_metadata (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            revision INTEGER NOT NULL CHECK (revision >= 1),
            payload BLOB NOT NULL CHECK (
                typeof(payload) = 'blob'
                AND length(payload) BETWEEN 1 AND 167772160
            )
        );

        CREATE TABLE IF NOT EXISTS clipboard_image_blobs (
            blob_id TEXT PRIMARY KEY,
            item_id TEXT NOT NULL UNIQUE,
            payload BLOB NOT NULL CHECK (
                typeof(payload) = 'blob'
                AND length(payload) BETWEEN 1 AND 67108864
            ),
            plaintext_size INTEGER NOT NULL
                CHECK (plaintext_size > 0 AND plaintext_size <= 33554432),
            state_id INTEGER NOT NULL DEFAULT 1 CHECK (state_id = 1),
            FOREIGN KEY (state_id) REFERENCES clipboard_metadata(id) ON DELETE CASCADE
        );
        """,
        on: handle
      )
      try setSchemaVersion(10, on: handle)
    } catch {
      throw SQLitePersistenceError.migrationFailed(
        "Protected clipboard metadata and image storage could not be created."
      )
    }
  }

  static func migrateToV11(
    on handle: OpaquePointer?,
    localDataProtector: any LocalDataProtector
  ) throws {
    do {
      guard
        try authenticatedSchemaFloor(
          on: handle,
          localDataProtector: localDataProtector
        ) == nil
      else {
        throw SQLitePersistenceError.migrationFailed(
          "Authenticated schema metadata already exists below its schema version."
        )
      }
      try requireQuickCheck(on: handle)
      try SQLiteAuthenticatedSchemaFloor.install(
        on: handle,
        databaseID: UUID(),
        schemaFloor: SQLiteAuthenticatedSchemaFloor.legacySchemaFloor,
        localDataProtector: localDataProtector
      )
      try SQLiteWriterBarrier.installTriggers(
        on: handle,
        tableNames: writerBarrierTableNames.filter {
          $0 != "record_catalog_nodes" && $0 != "record_graph_metadata" && $0 != "record_payload_blobs"
        }
      )
      guard
        try SQLiteAuthenticatedSchemaFloor.readAndValidate(
          on: handle,
          localDataProtector: localDataProtector
        ) == SQLiteAuthenticatedSchemaFloor.legacySchemaFloor
      else {
        throw SQLitePersistenceError.migrationFailed(
          "Authenticated schema metadata could not be verified after installation."
        )
      }
      try setSchemaVersion(11, on: handle)
      try validateLegacyV11StorageBoundary(
        on: handle,
        localDataProtector: localDataProtector
      )
    } catch {
      throw SQLitePersistenceError.migrationFailed(
        "Authenticated schema and writer protection could not be installed."
      )
    }
  }

  static func migrateToV12(
    on handle: OpaquePointer?,
    localDataProtector: any LocalDataProtector
  ) throws {
    do {
      guard try schemaVersion(on: handle) == 11,
        try authenticatedSchemaFloor(
          on: handle,
          localDataProtector: localDataProtector
        ) == SQLiteAuthenticatedSchemaFloor.legacySchemaFloor
      else {
        throw SQLitePersistenceError.migrationFailed(
          "Record graph migration requires an authenticated schema 11 database."
        )
      }
      let databaseID = try SQLiteAuthenticatedSchemaFloor.validatedDatabaseID(
        on: handle,
        localDataProtector: localDataProtector
      )
      try execute(
        """
        CREATE TABLE IF NOT EXISTS record_graph_metadata (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            revision INTEGER NOT NULL CHECK (revision >= 1),
            payload BLOB NOT NULL CHECK (
                typeof(payload) = 'blob'
                AND length(payload) BETWEEN 1 AND 167772160
            )
        );

        CREATE TABLE IF NOT EXISTS record_payload_blobs (
            blob_id TEXT PRIMARY KEY,
            record_id TEXT NOT NULL UNIQUE,
            payload_kind TEXT NOT NULL CHECK (payload_kind IN ('text', 'image', 'files')),
            payload BLOB NOT NULL CHECK (
                typeof(payload) = 'blob'
                AND length(payload) BETWEEN 1 AND 134217728
            ),
            plaintext_size INTEGER NOT NULL
                CHECK (plaintext_size > 0 AND plaintext_size <= 67108864),
            state_id INTEGER NOT NULL DEFAULT 1 CHECK (state_id = 1),
            FOREIGN KEY (state_id) REFERENCES record_graph_metadata(id) ON DELETE CASCADE
        );
        """,
        on: handle
      )
      try SQLiteWriterBarrier.installTriggers(
        on: handle,
        tableNames: writerBarrierTableNames.filter { $0 != "record_catalog_nodes" }
      )
      try SQLiteAuthenticatedSchemaFloor.upgrade(
        on: handle,
        validatedDatabaseID: databaseID,
        localDataProtector: localDataProtector,
        schemaFloor: 12
      )
      try setSchemaVersion(12, on: handle)
      try migrateToV13(on: handle, localDataProtector: localDataProtector)
    } catch {
      throw SQLitePersistenceError.migrationFailed(
        "Record graph storage and authenticated schema 12 could not be installed."
      )
    }
  }

  static func migrateToV13(
    on handle: OpaquePointer?,
    localDataProtector: any LocalDataProtector
  ) throws {
    guard try schemaVersion(on: handle) == 12,
      try authenticatedSchemaFloor(on: handle, localDataProtector: localDataProtector) == 12
    else { throw SQLitePersistenceError.migrationFailed("Catalog migration requires schema 12.") }
    let databaseID = try SQLiteAuthenticatedSchemaFloor.validatedDatabaseID(
      on: handle, localDataProtector: localDataProtector
    )
    try execute("""
      CREATE TABLE record_catalog_nodes (
        key TEXT PRIMARY KEY NOT NULL,
        kind TEXT NOT NULL,
        identifier TEXT NOT NULL,
        payload BLOB NOT NULL CHECK (typeof(payload) = 'blob' AND length(payload) BETWEEN 1 AND 4194304),
        UNIQUE(kind, identifier)
      );
      """, on: handle)
    try SQLiteWriterBarrier.installTriggers(on: handle, tableNames: writerBarrierTableNames)
    try SQLiteSchemaWriterBarrier.catalog.install(on: handle, tables: writerBarrierTableNames)
    try SQLiteAuthenticatedSchemaFloor.upgrade(
      on: handle, validatedDatabaseID: databaseID, localDataProtector: localDataProtector, schemaFloor: 13
    )
    try setSchemaVersion(13, on: handle)
    try migrateToV14(on: handle, localDataProtector: localDataProtector)
  }

  static let memoryTableNames = ["context_memories", "context_memory_sources", "context_memory_exclusions", "context_memory_control"]

  static func migrateToV14(on handle: OpaquePointer?, localDataProtector: any LocalDataProtector) throws {
    let databaseID = try SQLiteAuthenticatedSchemaFloor.validatedDatabaseID(on: handle, localDataProtector: localDataProtector)
    try execute("""
      CREATE TABLE context_memories (id TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL);
      CREATE TABLE context_memory_sources (
        source_id TEXT PRIMARY KEY NOT NULL,
        revision INTEGER NOT NULL CHECK(revision > 0),
        processed_revision INTEGER NOT NULL DEFAULT 0,
        skipped_reason TEXT
      );
      CREATE TABLE context_memory_exclusions (source_id TEXT PRIMARY KEY NOT NULL);
      CREATE TABLE context_memory_control (id INTEGER PRIMARY KEY CHECK(id = 1), payload TEXT NOT NULL);
      INSERT INTO context_memory_sources(source_id, revision)
        SELECT COALESCE(run_id, id), 1 FROM history_records GROUP BY COALESCE(run_id, id);
      CREATE TRIGGER context_source_insert AFTER INSERT ON history_records BEGIN
        INSERT INTO context_memory_sources(source_id, revision) VALUES (COALESCE(NEW.run_id, NEW.id), 1)
          ON CONFLICT(source_id) DO UPDATE SET revision = revision + 1, skipped_reason = NULL;
      END;
      CREATE TRIGGER context_source_update AFTER UPDATE OF final_text, correction_source_json ON history_records BEGIN
        INSERT INTO context_memory_sources(source_id, revision) VALUES (COALESCE(NEW.run_id, NEW.id), 1)
          ON CONFLICT(source_id) DO UPDATE SET revision = revision + 1, skipped_reason = NULL;
      END;
      CREATE TRIGGER context_source_delete AFTER DELETE ON history_records BEGIN
        UPDATE context_memory_sources SET revision = revision + 1 WHERE source_id = COALESCE(OLD.run_id, OLD.id);
      END;
      """, on: handle)
    try SQLiteWriterBarrier.installTriggers(on: handle, tableNames: writerBarrierTableNames + memoryTableNames)
    try SQLiteSchemaWriterBarrier.memory.install(on: handle, tables: writerBarrierTableNames + memoryTableNames)
    try SQLiteAuthenticatedSchemaFloor.upgrade(on: handle, validatedDatabaseID: databaseID,
                                              localDataProtector: localDataProtector, schemaFloor: 14)
    try setSchemaVersion(14, on: handle)
    try validateAuthenticatedStorageBoundary(on: handle, localDataProtector: localDataProtector)
  }

  static func recoverAuthenticatedSchemaFloor(
    _ authenticatedFloor: Int,
    on handle: OpaquePointer?,
    localDataProtector: any LocalDataProtector
  ) throws -> Bool {
    do {
      guard authenticatedFloor == SQLiteAuthenticatedSchemaFloor.installedSchemaFloor,
        authenticatedFloor <= currentSchemaVersion
      else {
        throw SQLitePersistenceError.migrationFailed(
          "The authenticated schema floor is newer than this application."
        )
      }
      let lockedVersion = try schemaVersion(on: handle)
      guard lockedVersion <= authenticatedFloor else {
        throw SQLitePersistenceError.migrationFailed(
          "The stored schema version conflicts with its authenticated floor."
        )
      }
      let cleanupIsPending = try validateDataProtectionKey(
        on: handle,
        localDataProtector: localDataProtector
      )
      try validateAuthenticatedStorageBoundary(
        on: handle,
        localDataProtector: localDataProtector
      )
      try requireQuickCheck(on: handle)
      if lockedVersion < authenticatedFloor {
        try setSchemaVersion(authenticatedFloor, on: handle)
      }
      return cleanupIsPending
    } catch {
      throw SQLitePersistenceError.migrationFailed(
        "Authenticated schema recovery could not be completed."
      )
    }
  }

  static func validateLegacyV11StorageBoundary(
    on handle: OpaquePointer?,
    localDataProtector: any LocalDataProtector
  ) throws {
    guard try authenticatedSchemaFloor(
      on: handle,
      localDataProtector: localDataProtector
    ) == SQLiteAuthenticatedSchemaFloor.legacySchemaFloor else {
      throw SQLitePersistenceError.migrationFailed(
        "Legacy authenticated schema metadata is unavailable."
      )
    }
    try SQLiteWriterBarrier.validateTriggers(
      on: handle,
      tableNames: writerBarrierTableNames.filter {
        $0 != "record_catalog_nodes" && $0 != "record_graph_metadata" && $0 != "record_payload_blobs"
      }
    )
  }

  static func validateAuthenticatedStorageBoundary(
    on handle: OpaquePointer?,
    localDataProtector: any LocalDataProtector
  ) throws {
    guard
      try authenticatedSchemaFloor(
        on: handle,
        localDataProtector: localDataProtector
      ) == currentSchemaVersion
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Authenticated schema metadata is unavailable."
      )
    }
    do {
      try SQLiteWriterBarrier.validateTriggers(
        on: handle,
        tableNames: writerBarrierTableNames + memoryTableNames
      )
    } catch {
      throw SQLitePersistenceError.migrationFailed(
        "The database writer barrier is unavailable."
      )
    }
  }

  static func authenticatedSchemaFloor(
    on handle: OpaquePointer?,
    localDataProtector: any LocalDataProtector
  ) throws -> Int? {
    do {
      return try SQLiteAuthenticatedSchemaFloor.readAndValidate(
        on: handle,
        localDataProtector: localDataProtector
      )
    } catch {
      throw SQLitePersistenceError.migrationFailed(
        "Authenticated schema metadata could not be validated."
      )
    }
  }

  static func requireQuickCheck(on handle: OpaquePointer?) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, "PRAGMA quick_check;", -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.migrationFailed(
        "The database could not be checked before schema recovery."
      )
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      staticTextColumn(in: statement, index: 0) == "ok",
      sqlite3_step(statement) == SQLITE_DONE
    else {
      throw SQLitePersistenceError.migrationFailed(
        "The database failed its integrity check before schema recovery."
      )
    }
  }

  static func legacyRunHistoryRowsForOrdinalBackfill(
    on handle: OpaquePointer?,
    limit: Int64,
    offset: Int64
  ) throws -> [LegacyRunHistoryOrdinalRow] {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        """
        SELECT table_name, identifier
        FROM (
            SELECT 'history_records' AS table_name, id AS identifier,
                   timestamp, 1 AS source_rank
            FROM history_records
            UNION ALL
            SELECT 'workflow_run_receipts' AS table_name, run_id AS identifier,
                   timestamp, 0 AS source_rank
            FROM workflow_run_receipts
        )
        ORDER BY timestamp ASC, source_rank ASC, identifier ASC
        LIMIT ? OFFSET ?;
        """,
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Existing run-history rows could not be ordered for migration."
      )
    }
    defer { sqlite3_finalize(statement) }
    try bindMigrationValues(
      [.int(limit), .int(offset)],
      to: statement,
      on: handle
    )

    var rows: [LegacyRunHistoryOrdinalRow] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        guard let tableName = staticTextColumn(in: statement, index: 0),
          let identifier = staticTextColumn(in: statement, index: 1)
        else {
          throw SQLitePersistenceError.migrationFailed(
            "An existing run-history row was missing its coordinate."
          )
        }
        rows.append(
          LegacyRunHistoryOrdinalRow(tableName: tableName, identifier: identifier)
        )
      case SQLITE_DONE:
        return rows
      default:
        throw SQLitePersistenceError.migrationFailed(
          "Existing run-history rows could not be read for migration."
        )
      }
    }
  }

  static func backfillRunHistoryWriteOrdinals(on handle: OpaquePointer?) throws {
    var historyStatement: OpaquePointer?
    var receiptStatement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        "UPDATE history_records SET write_ordinal = ? WHERE id = ?;",
        -1,
        &historyStatement,
        nil
      ) == SQLITE_OK,
      sqlite3_prepare_v2(
        handle,
        "UPDATE workflow_run_receipts SET write_ordinal = ? WHERE run_id = ?;",
        -1,
        &receiptStatement,
        nil
      ) == SQLITE_OK
    else {
      sqlite3_finalize(historyStatement)
      sqlite3_finalize(receiptStatement)
      throw SQLitePersistenceError.migrationFailed(
        "Run-history write ordinals could not be prepared."
      )
    }
    defer {
      sqlite3_finalize(historyStatement)
      sqlite3_finalize(receiptStatement)
    }

    let batchSize: Int64 = 512
    var scanOffset: Int64 = 0
    var ordinal: Int64 = 0
    while true {
      let rows = try legacyRunHistoryRowsForOrdinalBackfill(
        on: handle,
        limit: batchSize,
        offset: scanOffset
      )
      guard !rows.isEmpty else { break }
      for row in rows {
        guard ordinal < Int64.max else {
          throw SQLitePersistenceError.migrationFailed(
            "Run-history write ordinals were exhausted during migration."
          )
        }
        ordinal += 1
        let statement =
          row.tableName == "history_records"
          ? historyStatement
          : receiptStatement
        guard sqlite3_reset(statement) == SQLITE_OK,
          sqlite3_clear_bindings(statement) == SQLITE_OK
        else {
          throw SQLitePersistenceError.migrationFailed(
            "Run-history write ordinals could not be reset."
          )
        }
        try bindMigrationValues(
          [.int(ordinal), .text(row.identifier)],
          to: statement,
          on: handle
        )
        guard sqlite3_step(statement) == SQLITE_DONE else {
          throw SQLitePersistenceError.migrationFailed(
            "A run-history write ordinal could not be stored."
          )
        }
      }
      scanOffset += Int64(rows.count)
    }

    var sequenceStatement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        "UPDATE run_history_write_sequence SET last_ordinal = ? WHERE id = 1;",
        -1,
        &sequenceStatement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Run-history write sequence could not be prepared."
      )
    }
    defer { sqlite3_finalize(sequenceStatement) }
    try bindMigrationValues(
      [.int(ordinal)],
      to: sequenceStatement,
      on: handle
    )
    guard sqlite3_step(sequenceStatement) == SQLITE_DONE else {
      throw SQLitePersistenceError.migrationFailed(
        "Run-history write sequence could not be stored."
      )
    }
  }

  static func backfillNonemptyHistoryBodyMetadata(
    on handle: OpaquePointer?,
    localDataProtector: any LocalDataProtector
  ) throws {
    var updateStatement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        "UPDATE history_records SET has_nonempty_final_text = ? WHERE id = ?;",
        -1,
        &updateStatement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "History body-presence metadata could not be prepared."
      )
    }
    defer { sqlite3_finalize(updateStatement) }
    var afterIdentifier = ""
    while true {
      var readStatement: OpaquePointer?
      guard
        sqlite3_prepare_v2(
          handle,
          """
          SELECT id, final_text
          FROM history_records
          WHERE id > ?
          ORDER BY id ASC
          LIMIT 512;
          """,
          -1,
          &readStatement,
          nil
        ) == SQLITE_OK
      else {
        throw SQLitePersistenceError.migrationFailed(
          "History body-presence metadata could not be read."
        )
      }
      do {
        try bindMigrationValues(
          [.text(afterIdentifier)],
          to: readStatement,
          on: handle
        )
      } catch {
        sqlite3_finalize(readStatement)
        throw error
      }
      var rows: [(String, Bool)] = []
      readRows: while true {
        switch sqlite3_step(readStatement) {
        case SQLITE_ROW:
          guard let identifier = staticTextColumn(in: readStatement, index: 0) else {
            sqlite3_finalize(readStatement)
            throw SQLitePersistenceError.migrationFailed(
              "A history row was missing its identifier."
            )
          }
          let hasNonemptyBody: Bool
          if let envelope = staticTextColumn(in: readStatement, index: 1) {
            let data: Data
            do {
              data = try localDataProtector.open(
                envelope,
                context: historyProtectionContext(recordID: identifier, field: "final_text")
              )
            } catch {
              sqlite3_finalize(readStatement)
              throw SQLitePersistenceError.migrationFailed(
                "History body-presence metadata could not authenticate protected text."
              )
            }
            guard let text = String(data: data, encoding: .utf8) else {
              sqlite3_finalize(readStatement)
              throw SQLitePersistenceError.migrationFailed(
                "History body-presence metadata was not valid UTF-8."
              )
            }
            hasNonemptyBody = Self.hasNonemptyBody(text)
          } else {
            hasNonemptyBody = false
          }
          rows.append((identifier, hasNonemptyBody))
        case SQLITE_DONE:
          break readRows
        default:
          sqlite3_finalize(readStatement)
          throw SQLitePersistenceError.migrationFailed(
            "History body-presence metadata could not be scanned."
          )
        }
      }
      sqlite3_finalize(readStatement)
      guard !rows.isEmpty else { break }
      for (identifier, hasNonemptyBody) in rows {
        guard sqlite3_reset(updateStatement) == SQLITE_OK,
          sqlite3_clear_bindings(updateStatement) == SQLITE_OK
        else {
          throw SQLitePersistenceError.migrationFailed(
            "History body-presence metadata could not be reset."
          )
        }
        try bindMigrationValues(
          [.int(hasNonemptyBody ? 1 : 0), .text(identifier)],
          to: updateStatement,
          on: handle
        )
        guard sqlite3_step(updateStatement) == SQLITE_DONE else {
          throw SQLitePersistenceError.migrationFailed(
            "History body-presence metadata could not be stored."
          )
        }
      }
      afterIdentifier = rows[rows.count - 1].0
    }
  }

  static func validateDataProtectionKey(
    on handle: OpaquePointer?,
    localDataProtector: any LocalDataProtector
  ) throws -> Bool {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        "SELECT key_verification, cleanup_pending FROM local_data_protection WHERE id = 1;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Local data protection metadata is unavailable."
      )
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      let envelope = staticTextColumn(in: statement, index: 0)
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Local data protection metadata is unavailable."
      )
    }

    do {
      let plaintext = try localDataProtector.open(
        envelope,
        context: keyVerificationContext
      )
      guard plaintext == keyVerificationPlaintext else {
        throw SQLitePersistenceError.migrationFailed(
          "Local data protection key verification failed."
        )
      }
    } catch let error as SQLitePersistenceError {
      throw error
    } catch {
      throw SQLitePersistenceError.migrationFailed(
        "Local data protection key verification failed."
      )
    }
    return sqlite3_column_int(statement, 1) != 0
  }

  static func unprotectedHistoryRows(
    on handle: OpaquePointer?
  ) throws -> [UnprotectedHistoryRow] {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        """
        SELECT id, workflow_fallback_name, final_text, correction_source_json
        FROM history_records;
        """,
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "History data could not be prepared for protection."
      )
    }
    defer { sqlite3_finalize(statement) }

    var rows: [UnprotectedHistoryRow] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        guard let id = staticTextColumn(in: statement, index: 0),
          let fallbackName = staticTextColumn(in: statement, index: 1)
        else {
          throw SQLitePersistenceError.migrationFailed(
            "History data could not be prepared for protection."
          )
        }
        rows.append(
          UnprotectedHistoryRow(
            id: id,
            workflowFallbackName: fallbackName,
            finalText: staticTextColumn(in: statement, index: 2),
            correctionSourceJSON: staticTextColumn(in: statement, index: 3)
          )
        )
      case SQLITE_DONE:
        return rows
      default:
        throw SQLitePersistenceError.migrationFailed(
          "History data could not be prepared for protection."
        )
      }
    }
  }

  static func unprotectedSettingRows(
    on handle: OpaquePointer?
  ) throws -> [UnprotectedSettingRow] {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        "SELECT key, value FROM app_settings;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Settings data could not be prepared for protection."
      )
    }
    defer { sqlite3_finalize(statement) }

    var rows: [UnprotectedSettingRow] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        guard let key = staticTextColumn(in: statement, index: 0),
          let value = staticTextColumn(in: statement, index: 1)
        else {
          throw SQLitePersistenceError.migrationFailed(
            "Settings data could not be prepared for protection."
          )
        }
        rows.append(UnprotectedSettingRow(key: key, value: value))
      case SQLITE_DONE:
        return rows
      default:
        throw SQLitePersistenceError.migrationFailed(
          "Settings data could not be prepared for protection."
        )
      }
    }
  }

  static func unprotectedExportRows(
    on handle: OpaquePointer?
  ) throws -> [UnprotectedExportRow] {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        "SELECT id, destination_path, metadata_json FROM export_metadata;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Export metadata could not be prepared for protection."
      )
    }
    defer { sqlite3_finalize(statement) }

    var rows: [UnprotectedExportRow] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        guard let id = staticTextColumn(in: statement, index: 0),
          let destinationPath = staticTextColumn(in: statement, index: 1),
          let metadataJSON = staticTextColumn(in: statement, index: 2)
        else {
          throw SQLitePersistenceError.migrationFailed(
            "Export metadata could not be prepared for protection."
          )
        }
        rows.append(
          UnprotectedExportRow(
            id: id,
            destinationPath: destinationPath,
            metadataJSON: metadataJSON
          )
        )
      case SQLITE_DONE:
        return rows
      default:
        throw SQLitePersistenceError.migrationFailed(
          "Export metadata could not be prepared for protection."
        )
      }
    }
  }

  static func sanitizeExistingDiagnostics(
    on handle: OpaquePointer?
  ) throws -> Int {
    let rows = try legacyDiagnosticRows(on: handle)
    guard !rows.isEmpty else { return 0 }

    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        """
        UPDATE diagnostic_events
        SET event = ?, message = ?, metadata_json = '{}'
        WHERE id = ?;
        """,
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Legacy diagnostics could not be sanitized."
      )
    }
    defer { sqlite3_finalize(statement) }
    for row in rows {
      guard sqlite3_reset(statement) == SQLITE_OK,
        sqlite3_clear_bindings(statement) == SQLITE_OK
      else {
        throw SQLitePersistenceError.migrationFailed(
          "Legacy diagnostics could not be sanitized."
        )
      }
      try bindMigrationValues(
        [
          .text(DiagnosticEventSanitizer.sanitizeEventCode(row.eventCode)),
          .text(DiagnosticEventSanitizer.sanitizedMessage),
          .int(row.id),
        ],
        to: statement,
        on: handle
      )
      guard sqlite3_step(statement) == SQLITE_DONE else {
        throw SQLitePersistenceError.migrationFailed(
          "Legacy diagnostics could not be sanitized."
        )
      }
    }
    return rows.count
  }

  static func legacyDiagnosticRows(
    on handle: OpaquePointer?
  ) throws -> [LegacyDiagnosticRow] {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        "SELECT id, event FROM diagnostic_events;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Legacy diagnostics could not be sanitized."
      )
    }
    defer { sqlite3_finalize(statement) }

    var rows: [LegacyDiagnosticRow] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        guard let eventCode = staticTextColumn(in: statement, index: 1) else {
          throw SQLitePersistenceError.migrationFailed(
            "Legacy diagnostics could not be sanitized."
          )
        }
        rows.append(
          LegacyDiagnosticRow(
            id: sqlite3_column_int64(statement, 0),
            eventCode: eventCode
          )
        )
      case SQLITE_DONE:
        return rows
      default:
        throw SQLitePersistenceError.migrationFailed(
          "Legacy diagnostics could not be sanitized."
        )
      }
    }
  }

  static func protectHistoryRow(
    _ row: UnprotectedHistoryRow,
    on handle: OpaquePointer?,
    localDataProtector: any LocalDataProtector
  ) throws {
    let fallbackName = try localDataProtector.seal(
      Data(row.workflowFallbackName.utf8),
      context: historyProtectionContext(
        recordID: row.id,
        field: "workflow_fallback_name"
      )
    )
    let finalText = try row.finalText.map { value in
      try localDataProtector.seal(
        Data(value.utf8),
        context: historyProtectionContext(recordID: row.id, field: "final_text")
      )
    }
    let correctionSourceJSON = try row.correctionSourceJSON.map { value in
      try localDataProtector.seal(
        Data(value.utf8),
        context: historyProtectionContext(
          recordID: row.id,
          field: "correction_source_json"
        )
      )
    }

    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        """
        UPDATE history_records
        SET workflow_fallback_name = ?, final_text = ?, correction_source_json = ?
        WHERE id = ?;
        """,
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "History data could not be protected."
      )
    }
    defer { sqlite3_finalize(statement) }
    try bindMigrationValues(
      [
        .text(fallbackName),
        finalText.map(SQLiteBinding.text) ?? .null,
        correctionSourceJSON.map(SQLiteBinding.text) ?? .null,
        .text(row.id),
      ],
      to: statement,
      on: handle
    )
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw SQLitePersistenceError.migrationFailed(
        "History data could not be protected."
      )
    }
  }

  static func protectSettingRow(
    _ row: UnprotectedSettingRow,
    on handle: OpaquePointer?,
    localDataProtector: any LocalDataProtector
  ) throws {
    let protectedValue = try localDataProtector.seal(
      Data(row.value.utf8),
      context: settingsProtectionContext(keyRawValue: row.key)
    )
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        "UPDATE app_settings SET value = ? WHERE key = ?;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Settings data could not be protected."
      )
    }
    defer { sqlite3_finalize(statement) }
    try bindMigrationValues(
      [.text(protectedValue), .text(row.key)],
      to: statement,
      on: handle
    )
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw SQLitePersistenceError.migrationFailed(
        "Settings data could not be protected."
      )
    }
  }

  static func protectExportRow(
    _ row: UnprotectedExportRow,
    on handle: OpaquePointer?,
    localDataProtector: any LocalDataProtector
  ) throws {
    let protectedDestinationPath = try localDataProtector.seal(
      Data(row.destinationPath.utf8),
      context: exportProtectionContext(recordID: row.id, field: "destination_path")
    )
    let protectedMetadataJSON = try localDataProtector.seal(
      Data(row.metadataJSON.utf8),
      context: exportProtectionContext(recordID: row.id, field: "metadata_json")
    )
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        """
        UPDATE export_metadata
        SET destination_path = ?, metadata_json = ?
        WHERE id = ?;
        """,
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Export metadata could not be protected."
      )
    }
    defer { sqlite3_finalize(statement) }
    try bindMigrationValues(
      [
        .text(protectedDestinationPath),
        .text(protectedMetadataJSON),
        .text(row.id),
      ],
      to: statement,
      on: handle
    )
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw SQLitePersistenceError.migrationFailed(
        "Export metadata could not be protected."
      )
    }
  }

  static func upsertKeyVerificationEnvelope(
    _ envelope: String,
    cleanupIsPending: Bool,
    on handle: OpaquePointer?
  ) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        """
        INSERT INTO local_data_protection (id, key_verification, cleanup_pending)
        VALUES (1, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            key_verification = excluded.key_verification,
            cleanup_pending = excluded.cleanup_pending;
        """,
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.migrationFailed(
        "Local data protection metadata could not be stored."
      )
    }
    defer { sqlite3_finalize(statement) }
    try bindMigrationValues(
      [.text(envelope), .int(cleanupIsPending ? 1 : 0)],
      to: statement,
      on: handle
    )
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw SQLitePersistenceError.migrationFailed(
        "Local data protection metadata could not be stored."
      )
    }
  }

  static func bindMigrationValues(
    _ bindings: [SQLiteBinding],
    to statement: OpaquePointer?,
    on handle: OpaquePointer?
  ) throws {
    for (offset, binding) in bindings.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch binding {
      case .text(let value):
        result = value.withCString {
          sqlite3_bind_text(statement, index, $0, -1, sqliteTransient)
        }
      case .blob(let value):
        guard value.count <= Int(Int32.max) else {
          throw SQLitePersistenceError.migrationFailed(
            "Protected data was too large to bind during migration."
          )
        }
        result = value.withUnsafeBytes { bytes in
          sqlite3_bind_blob(
            statement,
            index,
            bytes.baseAddress,
            Int32(bytes.count),
            sqliteTransient
          )
        }
      case .double(let value):
        result = sqlite3_bind_double(statement, index, value)
      case .int(let value):
        result = sqlite3_bind_int64(statement, index, value)
      case .null:
        result = sqlite3_bind_null(statement, index)
      }
      guard result == SQLITE_OK else {
        throw SQLitePersistenceError.migrationFailed(
          "Protected data could not be bound during migration: \(lastErrorMessage(from: handle))"
        )
      }
    }
  }

  static var keyVerificationContext: LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: "local_data_protection",
      recordID: "1",
      field: "key_verification"
    )
  }

  static func historyProtectionContext(
    recordID: String,
    field: String
  ) -> LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: "history_records",
      recordID: recordID,
      field: field
    )
  }

  static func runReceiptProtectionContext(
    runID: String
  ) -> LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: "workflow_run_receipts",
      recordID: runID,
      field: "payload"
    )
  }

  static func settingsProtectionContext(
    keyRawValue: String
  ) -> LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: "app_settings",
      recordID: keyRawValue,
      field: "value"
    )
  }

  static func exportProtectionContext(
    recordID: String,
    field: String
  ) -> LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: "export_metadata",
      recordID: recordID,
      field: field
    )
  }

  static var clipboardMetadataProtectionContext: LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: "clipboard_metadata",
      recordID: "1",
      field: "payload"
    )
  }

  static func clipboardBlobProtectionContext(
    reference: LegacyRecordGraphBlobReference
  ) -> LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: "clipboard_image_blobs",
      recordID: reference.blobID.uuidString,
      field: "item:\(reference.itemID.uuidString):payload"
    )
  }

  static var recordGraphProtectionContext: LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: "record_graph_metadata",
      recordID: "1",
      field: "payload"
    )
  }

  static func recordPayloadProtectionContext(
    reference: RecordGraphPersistenceBlobReference
  ) -> LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: "record_payload_blobs",
      recordID: reference.blobID.uuidString,
      field: "record:\(reference.recordID.rawValue.uuidString):\(reference.kind.rawValue):payload"
    )
  }

  static func staticTextColumn(
    in statement: OpaquePointer?,
    index: Int32
  ) -> String? {
    guard let cString = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: cString)
  }

}
