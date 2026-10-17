import Foundation
import GRDB
import RillCore

private struct DiagnosticEventRecord: Decodable, FetchableRecord, Sendable {
  var timestamp: Double
  var runID: String?
  var subsystem: String
  var level: String
  var event: String
  var message: String
  var metadataJSON: String

  enum CodingKeys: String, CodingKey {
    case timestamp
    case runID = "run_id"
    case subsystem
    case level
    case event
    case message
    case metadataJSON = "metadata_json"
  }
}

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
    let record = try DiagnosticEventRecord(row: row)
    guard
      let subsystem = SubsystemTag(rawValue: record.subsystem),
      let level = DiagnosticLevel(rawValue: record.level)
    else {
      throw SQLitePersistenceError.decodingRow("Diagnostic row was missing required values.")
    }

    let metadata: [String: String]
    do {
      metadata = try decoder.decode([String: String].self, from: Data(record.metadataJSON.utf8))
    } catch {
      throw SQLitePersistenceError.decodingRow(error.localizedDescription)
    }

    return DiagnosticEvent(
      timestamp: Date(timeIntervalSince1970: record.timestamp),
      runID: record.runID.flatMap(UUID.init(uuidString:)),
      subsystem: subsystem,
      level: level,
      untrustedEvent: record.event,
      message: record.message,
      metadata: metadata
    )
  }

}
