import Foundation
import SQLite3
import VoxTypeCore

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class SQLiteConnectionBox {
    let db: OpaquePointer?

    init(db: OpaquePointer?) {
        self.db = db
    }

    deinit {
        sqlite3_close(db)
    }
}

public enum SQLitePersistenceError: Error, LocalizedError, Equatable {
    case missingApplicationSupportDirectory
    case openingDatabase(String)
    case executingSQL(String)
    case preparingStatement(String)
    case bindingValue(String)
    case steppingStatement(String)
    case decodingRow(String)
    case encodingValue(String)
    case migrationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingApplicationSupportDirectory:
            return "Unable to locate the Application Support directory for VoxType."
        case .openingDatabase(let message):
            return "Failed to open the VoxType SQLite database: \(message)"
        case .executingSQL(let message):
            return "Failed to execute SQLite statement: \(message)"
        case .preparingStatement(let message):
            return "Failed to prepare SQLite statement: \(message)"
        case .bindingValue(let message):
            return "Failed to bind a SQLite value: \(message)"
        case .steppingStatement(let message):
            return "Failed to execute a SQLite step: \(message)"
        case .decodingRow(let message):
            return "Failed to decode a SQLite row: \(message)"
        case .encodingValue(let message):
            return "Failed to encode a SQLite value: \(message)"
        case .migrationFailed(let message):
            return "Schema migration failed: \(message)"
        }
    }
}

private enum SQLiteBinding {
    case text(String)
    case double(Double)
    case int(Int64)
    case null
}

public actor SQLitePersistenceStore: HistoryRepository, DiagnosticRepository, SettingsStore, ExportMetadataRepository {
    public let databaseURL: URL

    private let connection: SQLiteConnectionBox
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() throws {
        try self.init(databaseURL: Self.defaultDatabaseURL())
    }

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try Self.ensureParentDirectoryExists(for: databaseURL)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = Self.lastErrorMessage(from: handle)
            if let handle {
                sqlite3_close(handle)
            }
            throw SQLitePersistenceError.openingDatabase(message)
        }

        self.connection = SQLiteConnectionBox(db: handle)
        try Self.execute(
            """
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;
            """,
            on: handle
        )
        try Self.migrate(on: handle)
    }

    public static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        guard let appSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw SQLitePersistenceError.missingApplicationSupportDirectory
        }

        return appSupportURL
            .appendingPathComponent("VoxType", isDirectory: true)
            .appendingPathComponent("voxtype.sqlite", isDirectory: false)
    }

    public func save(_ record: HistoryRecord) async throws {
        let statement = try prepare(
            """
            INSERT INTO history_records (
                id,
                run_id,
                workflow_id,
                workflow_fallback_name,
                workflow_title_key,
                final_text,
                failure_message,
                timestamp,
                is_stack_related,
                outcome
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                run_id = excluded.run_id,
                workflow_id = excluded.workflow_id,
                workflow_fallback_name = excluded.workflow_fallback_name,
                workflow_title_key = excluded.workflow_title_key,
                final_text = excluded.final_text,
                failure_message = excluded.failure_message,
                timestamp = excluded.timestamp,
                is_stack_related = excluded.is_stack_related,
                outcome = excluded.outcome;
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(
            [
                .text(record.id.uuidString),
                record.runID.map { .text($0.uuidString) } ?? .null,
                record.workflowID.map { .text($0.uuidString) } ?? .null,
                .text(record.workflow.fallbackName),
                record.workflow.titleKey.map { .text($0.rawValue) } ?? .null,
                record.finalText.map(SQLiteBinding.text) ?? .null,
                record.failureMessage.map(SQLiteBinding.text) ?? .null,
                .double(record.timestamp.timeIntervalSince1970),
                .int(record.isStackRelated ? 1 : 0),
                .text(record.outcome.rawValue),
            ],
            to: statement
        )

        try step(statement, expecting: SQLITE_DONE)
    }

    public func records(matching query: HistoryQuery) async throws -> [HistoryRecord] {
        var clauses: [String] = []
        var bindings: [SQLiteBinding] = []

        if let runID = query.runID {
            clauses.append("run_id = ?")
            bindings.append(.text(runID.uuidString))
        }

        if let workflowID = query.workflowID {
            clauses.append("workflow_id = ?")
            bindings.append(.text(workflowID.uuidString))
        }

        if let outcome = query.outcome {
            clauses.append("outcome = ?")
            bindings.append(.text(outcome.rawValue))
        }

        if let since = query.since {
            clauses.append("timestamp >= ?")
            bindings.append(.double(since.timeIntervalSince1970))
        }

        if let stackRelatedOnly = query.stackRelatedOnly {
            clauses.append("is_stack_related = ?")
            bindings.append(.int(stackRelatedOnly ? 1 : 0))
        }

        var sql = """
        SELECT
            id,
            run_id,
            workflow_id,
            workflow_fallback_name,
            workflow_title_key,
            final_text,
            failure_message,
            timestamp,
            is_stack_related,
            outcome
        FROM history_records
        """

        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }

        sql += " ORDER BY timestamp DESC"

        if let limit = query.limit, limit >= 0 {
            sql += " LIMIT ?"
            bindings.append(.int(Int64(limit)))
        }

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var records: [HistoryRecord] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE {
                break
            }
            guard rc == SQLITE_ROW else {
                throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
            }

            records.append(try decodeHistoryRecord(from: statement))
        }

        return records
    }

    public func save(_ event: DiagnosticEvent) async throws {
        let metadataJSON: String
        do {
            metadataJSON = String(decoding: try encoder.encode(event.metadata), as: UTF8.self)
        } catch {
            throw SQLitePersistenceError.encodingValue(error.localizedDescription)
        }

        let statement = try prepare(
            """
            INSERT INTO diagnostic_events (
                timestamp,
                run_id,
                subsystem,
                level,
                level_severity,
                event,
                message,
                metadata_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(
            [
                .double(event.timestamp.timeIntervalSince1970),
                event.runID.map { .text($0.uuidString) } ?? .null,
                .text(event.subsystem.rawValue),
                .text(event.level.rawValue),
                .int(Int64(event.level.severity)),
                .text(event.event),
                .text(event.message),
                .text(metadataJSON),
            ],
            to: statement
        )

        try step(statement, expecting: SQLITE_DONE)
    }

    public func events(matching query: DiagnosticQuery) async throws -> [DiagnosticEvent] {
        var clauses: [String] = []
        var bindings: [SQLiteBinding] = []

        if let runID = query.runID {
            clauses.append("run_id = ?")
            bindings.append(.text(runID.uuidString))
        }

        if let subsystem = query.subsystem {
            clauses.append("subsystem = ?")
            bindings.append(.text(subsystem.rawValue))
        }

        if let minimumLevel = query.minimumLevel {
            clauses.append("level_severity >= ?")
            bindings.append(.int(Int64(minimumLevel.severity)))
        }

        if let since = query.since {
            clauses.append("timestamp >= ?")
            bindings.append(.double(since.timeIntervalSince1970))
        }

        var sql = """
        SELECT
            timestamp,
            run_id,
            subsystem,
            level,
            event,
            message,
            metadata_json
        FROM diagnostic_events
        """

        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }

        sql += " ORDER BY timestamp DESC"

        if let limit = query.limit, limit >= 0 {
            sql += " LIMIT ?"
            bindings.append(.int(Int64(limit)))
        }

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var events: [DiagnosticEvent] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE {
                break
            }
            guard rc == SQLITE_ROW else {
                throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
            }

            events.append(try decodeDiagnosticEvent(from: statement))
        }

        return events
    }

    public func string(forKey key: AppSettingKey) async throws -> String? {
        let statement = try prepare(
            """
            SELECT value
            FROM app_settings
            WHERE key = ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(key.rawValue)], to: statement)

        let rc = sqlite3_step(statement)
        if rc == SQLITE_DONE {
            return nil
        }
        guard rc == SQLITE_ROW else {
            throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
        }

        return textColumn(in: statement, index: 0)
    }

    public func strings(forKeys keys: [AppSettingKey]) async throws -> [AppSettingKey: String] {
        let uniqueKeys = Array(Set(keys))
        guard !uniqueKeys.isEmpty else { return [:] }

        let placeholders = Array(repeating: "?", count: uniqueKeys.count).joined(separator: ", ")
        let statement = try prepare(
            """
            SELECT key, value
            FROM app_settings
            WHERE key IN (\(placeholders));
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(uniqueKeys.map { .text($0.rawValue) }, to: statement)

        var values: [AppSettingKey: String] = [:]
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE {
                break
            }
            guard rc == SQLITE_ROW else {
                throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
            }

            guard
                let keyText = textColumn(in: statement, index: 0),
                let key = AppSettingKey(rawValue: keyText),
                let value = textColumn(in: statement, index: 1)
            else {
                continue
            }

            values[key] = value
        }

        return values
    }

    public func setString(_ value: String, forKey key: AppSettingKey) async throws {
        let statement = try prepare(
            """
            INSERT INTO app_settings (key, value, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                updated_at = excluded.updated_at;
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(
            [
                .text(key.rawValue),
                .text(value),
                .double(Date().timeIntervalSince1970),
            ],
            to: statement
        )

        try step(statement, expecting: SQLITE_DONE)
    }

    public func removeValue(forKey key: AppSettingKey) async throws {
        let statement = try prepare("DELETE FROM app_settings WHERE key = ?;")
        defer { sqlite3_finalize(statement) }
        try bind([.text(key.rawValue)], to: statement)
        try step(statement, expecting: SQLITE_DONE)
    }

    public func save(_ export: ExportMetadata) async throws {
        let metadataJSON: String
        do {
            metadataJSON = String(decoding: try encoder.encode(export.metadata), as: UTF8.self)
        } catch {
            throw SQLitePersistenceError.encodingValue(error.localizedDescription)
        }

        let statement = try prepare(
            """
            INSERT INTO export_metadata (
                id,
                kind,
                destination_path,
                item_count,
                created_at,
                metadata_json
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                kind = excluded.kind,
                destination_path = excluded.destination_path,
                item_count = excluded.item_count,
                created_at = excluded.created_at,
                metadata_json = excluded.metadata_json;
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(
            [
                .text(export.id.uuidString),
                .text(export.kind.rawValue),
                .text(export.destinationPath),
                .int(Int64(export.itemCount)),
                .double(export.createdAt.timeIntervalSince1970),
                .text(metadataJSON),
            ],
            to: statement
        )

        try step(statement, expecting: SQLITE_DONE)
    }

    public func exports(limit: Int?) async throws -> [ExportMetadata] {
        var sql = """
        SELECT
            id,
            kind,
            destination_path,
            item_count,
            created_at,
            metadata_json
        FROM export_metadata
        ORDER BY created_at DESC
        """
        var bindings: [SQLiteBinding] = []

        if let limit, limit >= 0 {
            sql += " LIMIT ?"
            bindings.append(.int(Int64(limit)))
        }

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var exports: [ExportMetadata] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE {
                break
            }
            guard rc == SQLITE_ROW else {
                throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
            }

            exports.append(try decodeExportMetadata(from: statement))
        }

        return exports
    }

    private static func ensureParentDirectoryExists(for databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private static func schemaVersion(on handle: OpaquePointer?) throws -> Int {
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

    private static func setSchemaVersion(_ version: Int, on handle: OpaquePointer?) throws {
        let sql = "PRAGMA user_version = \(version)"
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLitePersistenceError.migrationFailed("Failed to set schema version")
        }
    }

    private static let currentSchemaVersion = 1

    private static func migrate(on handle: OpaquePointer?) throws {
        let version = try schemaVersion(on: handle)
        if version < 1 {
            try migrateToV1(on: handle)
        }
        // Future migrations: if version < 2 { try migrateToV2(on: handle) }
        try setSchemaVersion(currentSchemaVersion, on: handle)
    }

    private static func migrateToV1(on handle: OpaquePointer?) throws {
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

    private func execute(_ sql: String) throws {
        try Self.execute(sql, on: db)
    }

    private static func execute(_ sql: String, on handle: OpaquePointer?) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage(from: handle)
            if let errorMessage {
                sqlite3_free(errorMessage)
            }
            throw SQLitePersistenceError.executingSQL(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLitePersistenceError.preparingStatement(lastErrorMessage())
        }
        return statement
    }

    private func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer?) throws {
        guard let statement else {
            throw SQLitePersistenceError.preparingStatement("Missing SQLite statement.")
        }

        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32

            switch binding {
            case .text(let value):
                result = value.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) }
            case .double(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .int(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }

            guard result == SQLITE_OK else {
                throw SQLitePersistenceError.bindingValue(lastErrorMessage())
            }
        }
    }

    private func step(_ statement: OpaquePointer?, expecting expectedResult: Int32) throws {
        let rc = sqlite3_step(statement)
        guard rc == expectedResult else {
            throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
        }
    }

    private func decodeHistoryRecord(from statement: OpaquePointer?) throws -> HistoryRecord {
        guard
            let idText = textColumn(in: statement, index: 0),
            let id = UUID(uuidString: idText),
            let fallbackName = textColumn(in: statement, index: 3),
            let outcomeText = textColumn(in: statement, index: 9),
            let outcome = HistoryOutcome(rawValue: outcomeText)
        else {
            throw SQLitePersistenceError.decodingRow("History row was missing required values.")
        }

        let runID = textColumn(in: statement, index: 1).flatMap(UUID.init(uuidString:))
        let workflowID = textColumn(in: statement, index: 2).flatMap(UUID.init(uuidString:))
        let titleKey = textColumn(in: statement, index: 4).flatMap(WorkflowTitleKey.init(rawValue:))
        let finalText = textColumn(in: statement, index: 5)
        let failureMessage = textColumn(in: statement, index: 6)
        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
        let isStackRelated = sqlite3_column_int64(statement, 8) != 0

        return HistoryRecord(
            id: id,
            runID: runID,
            workflowID: workflowID,
            workflow: WorkflowPresentation(fallbackName: fallbackName, titleKey: titleKey),
            finalText: finalText,
            failureMessage: failureMessage,
            timestamp: timestamp,
            isStackRelated: isStackRelated,
            outcome: outcome
        )
    }

    private func decodeDiagnosticEvent(from statement: OpaquePointer?) throws -> DiagnosticEvent {
        guard
            let subsystemText = textColumn(in: statement, index: 2),
            let subsystem = SubsystemTag(rawValue: subsystemText),
            let levelText = textColumn(in: statement, index: 3),
            let level = DiagnosticLevel(rawValue: levelText),
            let event = textColumn(in: statement, index: 4),
            let message = textColumn(in: statement, index: 5),
            let metadataText = textColumn(in: statement, index: 6)
        else {
            throw SQLitePersistenceError.decodingRow("Diagnostic row was missing required values.")
        }

        let metadata: [String: String]
        do {
            metadata = try decoder.decode([String: String].self, from: Data(metadataText.utf8))
        } catch {
            throw SQLitePersistenceError.decodingRow(error.localizedDescription)
        }

        return DiagnosticEvent(
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
            runID: textColumn(in: statement, index: 1).flatMap(UUID.init(uuidString:)),
            subsystem: subsystem,
            level: level,
            event: event,
            message: message,
            metadata: metadata
        )
    }

    private func decodeExportMetadata(from statement: OpaquePointer?) throws -> ExportMetadata {
        guard
            let idText = textColumn(in: statement, index: 0),
            let id = UUID(uuidString: idText),
            let kindText = textColumn(in: statement, index: 1),
            let kind = ExportKind(rawValue: kindText),
            let destinationPath = textColumn(in: statement, index: 2),
            let metadataText = textColumn(in: statement, index: 5)
        else {
            throw SQLitePersistenceError.decodingRow("Export metadata row was missing required values.")
        }

        let metadata: [String: String]
        do {
            metadata = try decoder.decode([String: String].self, from: Data(metadataText.utf8))
        } catch {
            throw SQLitePersistenceError.decodingRow(error.localizedDescription)
        }

        return ExportMetadata(
            id: id,
            kind: kind,
            destinationPath: destinationPath,
            itemCount: Int(sqlite3_column_int64(statement, 3)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            metadata: metadata
        )
    }

    private func textColumn(in statement: OpaquePointer?, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: cString)
    }

    private func lastErrorMessage() -> String {
        Self.lastErrorMessage(from: db)
    }

    private var db: OpaquePointer? {
        connection.db
    }

    private static func lastErrorMessage(from handle: OpaquePointer?) -> String {
        if let handle, let cString = sqlite3_errmsg(handle) {
            return String(cString: cString)
        }
        return "Unknown SQLite error"
    }
}
