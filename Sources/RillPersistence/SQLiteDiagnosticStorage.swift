import Foundation
import GRDB
import RillCore

extension SQLitePersistenceSession {
  func save(_ event: DiagnosticEvent) throws {
    let generation = try currentRunHistoryWriteGeneration()
    try saveDiagnosticEvent(event, generation: generation)
  }

  func save(
    _ event: DiagnosticEvent,
    generation: RunHistoryWriteGeneration
  ) throws {
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
      try database.execute(
        sql: """
          INSERT INTO diagnostic_events (
            timestamp, run_id, subsystem, level, level_severity,
            event, message, metadata_json, write_generation
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
          """,
        arguments: [
          event.timestamp.timeIntervalSince1970, event.runID?.uuidString,
          event.subsystem.rawValue, event.level.rawValue, event.level.severity,
          event.event, event.message, metadataJSON, generation.value,
        ])
    }
  }

  func events(matching query: DiagnosticQuery) throws -> [DiagnosticEvent] {
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

      var batchBindings = bindings
      batchBindings.append(.int(scanBatchSize))
      batchBindings.append(.int(scanOffset))
      let rows = try Row.fetchCursor(database, sql: sql, arguments: arguments(batchBindings))
      var scannedRowCount: Int64 = 0
      while let row = try rows.next() {
        scannedRowCount += 1
        do {
          events.append(try decodeDiagnosticEvent(from: row))
        } catch {
          skippedCorruptRowCount += 1
          continue
        }
        if let resultLimit, events.count >= resultLimit { break }
      }

      scanOffset += scannedRowCount
      exhaustedStorage = scannedRowCount < scanBatchSize
    }

    Self.reportSkippedCorruptDiagnosticRows(skippedCorruptRowCount)
    return events
  }

  func deleteEvents(olderThan cutoff: Date) throws -> Int {
    try database.execute(sql: "DELETE FROM diagnostic_events WHERE timestamp < ?;", arguments: [cutoff.timeIntervalSince1970])
    return database.changesCount
  }

  func deleteEvents(through upperBound: Date) throws -> Int {
    try database.execute(sql: "DELETE FROM diagnostic_events WHERE timestamp <= ?;", arguments: [upperBound.timeIntervalSince1970])
    return database.changesCount
  }

  func deleteEvents(
    obsoletedBy transition: RunHistoryClearTransition,
    preservingLegacyRowsAfter legacyUpperBound: Date?
  ) throws -> Int {
    try deleteRunHistoryRows(
      obsoletedBy: transition,
      from: "diagnostic_events",
      preservingLegacyRowsAfter: legacyUpperBound
    )
  }

  func deleteAllEvents() throws -> Int {
    try database.execute(sql: "DELETE FROM diagnostic_events;")
    return database.changesCount
  }

  private func decodeDiagnosticEvent(from row: Row) throws -> DiagnosticEvent {
    guard
      let subsystemText = try row.decode(String?.self, atIndex: 2),
      let subsystem = SubsystemTag(rawValue: subsystemText),
      let levelText = try row.decode(String?.self, atIndex: 3),
      let level = DiagnosticLevel(rawValue: levelText),
      let event = try row.decode(String?.self, atIndex: 4),
      let message = try row.decode(String?.self, atIndex: 5),
      let metadataText = try row.decode(String?.self, atIndex: 6)
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
      timestamp: Date(timeIntervalSince1970: try row.decode(Double.self, atIndex: 0)),
      runID: try row.decode(String?.self, atIndex: 1).flatMap(UUID.init(uuidString:)),
      subsystem: subsystem,
      level: level,
      untrustedEvent: event,
      message: message,
      metadata: metadata
    )
  }

}
