import Foundation
import SQLite3
import RillCore

extension SQLitePersistenceStore {
  public func save(_ event: DiagnosticEvent) async throws {
    let generation = try currentRunHistoryWriteGeneration()
    try saveDiagnosticEvent(event, generation: generation)
  }

  public func save(
    _ event: DiagnosticEvent,
    generation: RunHistoryWriteGeneration
  ) async throws {
    try saveDiagnosticEvent(event, generation: generation)
  }

  private func saveDiagnosticEvent(
    _ event: DiagnosticEvent,
    generation: RunHistoryWriteGeneration
  ) throws {
    let event = DiagnosticEventSanitizer.sanitize(event)
    let metadataJSON: String
    do {
      metadataJSON = String(decoding: try encoder.encode(event.metadata), as: UTF8.self)
    } catch {
      throw SQLitePersistenceError.encodingValue(error.localizedDescription)
    }

    try withImmediateTransaction {
      guard try generationIsCurrent(generation) else {
        throw DiagnosticRepositoryError.writeObsoletedByClearBarrier
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
            metadata_json,
            write_generation
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
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
          .int(generation.value),
        ],
        to: statement
      )

      try step(statement, expecting: SQLITE_DONE)
    }
  }

  public func events(matching query: DiagnosticQuery) async throws -> [DiagnosticEvent] {
    if query.limit == 0 { return [] }
    let resultLimit = query.limit.flatMap { $0 >= 0 ? $0 : nil }
    let currentGeneration = try currentRunHistoryWriteGeneration()
    var clauses = ["write_generation = ?"]
    var bindings: [SQLiteBinding] = [.int(currentGeneration.value)]

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

    var events: [DiagnosticEvent] = []
    var scanOffset: Int64 = 0
    var skippedCorruptRowCount = 0
    let scanBatchSize: Int64
    if let resultLimit {
      let clampedLimit = min(max(resultLimit, 1), 128)
      scanBatchSize = Int64(max(32, clampedLimit * 2))
    } else {
      scanBatchSize = 256
    }

    var exhaustedStorage = false
    while !exhaustedStorage,
      resultLimit.map({ events.count < $0 }) ?? true
    {
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
      sql += " ORDER BY timestamp DESC, id ASC LIMIT ? OFFSET ?"

      let statement = try prepare(sql)
      var batchBindings = bindings
      batchBindings.append(.int(scanBatchSize))
      batchBindings.append(.int(scanOffset))
      do {
        try bind(batchBindings, to: statement)
      } catch {
        sqlite3_finalize(statement)
        throw error
      }

      var scannedRowCount: Int64 = 0
      do {
        while true {
          let stepResult = sqlite3_step(statement)
          if stepResult == SQLITE_DONE { break }
          guard stepResult == SQLITE_ROW else {
            throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
          }
          scannedRowCount += 1
          do {
            events.append(try decodeDiagnosticEvent(from: statement))
          } catch {
            skippedCorruptRowCount += 1
            continue
          }
          if let resultLimit, events.count >= resultLimit {
            break
          }
        }
      } catch {
        sqlite3_finalize(statement)
        throw error
      }
      sqlite3_finalize(statement)

      scanOffset += scannedRowCount
      exhaustedStorage = scannedRowCount < scanBatchSize
    }

    Self.reportSkippedCorruptDiagnosticRows(skippedCorruptRowCount)
    return events
  }

  public func deleteEvents(olderThan cutoff: Date) async throws -> Int {
    let statement = try prepare("DELETE FROM diagnostic_events WHERE timestamp < ?;")
    defer { sqlite3_finalize(statement) }
    try bind([.double(cutoff.timeIntervalSince1970)], to: statement)
    try step(statement, expecting: SQLITE_DONE)
    return Int(sqlite3_changes(db))
  }

  public func deleteEvents(through upperBound: Date) async throws -> Int {
    let statement = try prepare(
      "DELETE FROM diagnostic_events WHERE timestamp <= ?;"
    )
    defer { sqlite3_finalize(statement) }
    try bind([.double(upperBound.timeIntervalSince1970)], to: statement)
    try step(statement, expecting: SQLITE_DONE)
    return Int(sqlite3_changes(db))
  }

  public func deleteEvents(
    obsoletedBy transition: RunHistoryClearTransition,
    preservingLegacyRowsAfter legacyUpperBound: Date?
  ) async throws -> Int {
    try deleteRunHistoryRows(
      obsoletedBy: transition,
      from: "diagnostic_events",
      preservingLegacyRowsAfter: legacyUpperBound
    )
  }

  public func deleteAllEvents() async throws -> Int {
    let statement = try prepare("DELETE FROM diagnostic_events;")
    defer { sqlite3_finalize(statement) }
    try step(statement, expecting: SQLITE_DONE)
    return Int(sqlite3_changes(db))
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

}
