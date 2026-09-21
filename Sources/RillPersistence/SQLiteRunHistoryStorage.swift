import Foundation
import RillCore
import SQLite3

extension SQLitePersistenceStore: HistoryRepository, WorkflowRunTerminalRepository,
  RunHistoryBrowsing
{
  public func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration {
    try currentRunHistoryWriteGeneration()
  }

  public func save(_ record: WorkflowResultRecord) async throws {
    let generation = try currentRunHistoryWriteGeneration()
    let prepared = try prepareHistoryRecord(record)
    try withImmediateTransaction { try saveHistoryRecord(prepared, generation: generation) }
  }

  public func save(
    _ record: WorkflowResultRecord,
    generation: RunHistoryWriteGeneration
  ) async throws {
    let prepared = try prepareHistoryRecord(record)
    try withImmediateTransaction { try saveHistoryRecord(prepared, generation: generation) }
  }

  private struct PreparedHistoryRecord {
    let record: WorkflowResultRecord
    let fallbackName: String
    let finalText: String?
    let correctionSource: String?
  }

  private func prepareHistoryRecord(_ record: WorkflowResultRecord) throws -> PreparedHistoryRecord {
    let record = HistoryRecordSanitizer.sanitize(record)
    let recordID = record.id.uuidString
    let protectedFallbackName = try protectString(
      record.workflow.fallbackName,
      context: historyProtectionContext(
        recordID: recordID,
        field: "workflow_fallback_name"
      )
    )
    let protectedFinalText = try record.finalText.map { finalText in
      try protectString(
        finalText,
        context: historyProtectionContext(recordID: recordID, field: "final_text")
      )
    }
    let correctionSourceJSON: String?
    do {
      correctionSourceJSON = try record.correctionSource.map { source in
        let encoded = String(decoding: try encoder.encode(source), as: UTF8.self)
        return try protectString(
          encoded,
          context: historyProtectionContext(
            recordID: recordID,
            field: "correction_source_json"
          )
        )
      }
    } catch let error as SQLitePersistenceError {
      throw error
    } catch {
      throw SQLitePersistenceError.encodingValue(error.localizedDescription)
    }
    return PreparedHistoryRecord(record: record, fallbackName: protectedFallbackName,
      finalText: protectedFinalText, correctionSource: correctionSourceJSON)
  }

  private func saveHistoryRecord(_ prepared: PreparedHistoryRecord, generation: RunHistoryWriteGeneration) throws {
    let record = prepared.record
    let recordID = record.id.uuidString
    let protectedFallbackName = prepared.fallbackName
    let protectedFinalText = prepared.finalText
    let correctionSourceJSON = prepared.correctionSource
    guard try generationIsCurrent(generation) else {
      throw HistoryRepositoryError.writeObsoletedByClearBarrier
    }
    if let existingIdentity = try storedHistoryIdentity(recordID: record.id) {
      guard existingIdentity.matches(record, generation: generation) else {
        throw HistoryRepositoryError.conflictingHistoryRecord(recordID: record.id)
      }
      if try historyRecords(sourceID: record.runID ?? record.id).contains(record) { return }
      try updateHistoryRecordContent(
        record,
        protectedFallbackName: protectedFallbackName,
        protectedFinalText: protectedFinalText,
        correctionSourceJSON: correctionSourceJSON
      )
      return
    }
    let writeOrdinal = try nextRunHistoryWriteOrdinal()
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
          outcome,
          correction_source_json,
          trigger_kind,
          write_generation,
          write_ordinal,
          has_nonempty_final_text
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """
    )
    defer { sqlite3_finalize(statement) }

    try bind(
      [
        .text(recordID),
        record.runID.map { .text($0.uuidString) } ?? .null,
        record.workflowID.map { .text($0.uuidString) } ?? .null,
        .text(protectedFallbackName),
        record.workflow.titleKey.map { .text($0.rawValue) } ?? .null,
        protectedFinalText.map(SQLiteBinding.text) ?? .null,
        record.failureMessage.map(SQLiteBinding.text) ?? .null,
        .double(record.timestamp.timeIntervalSince1970),
        .int(record.isRecordRelated ? 1 : 0),
        .text(record.outcome.rawValue),
        correctionSourceJSON.map(SQLiteBinding.text) ?? .null,
        record.trigger.map { .text($0.rawValue) } ?? .null,
        .int(generation.value),
        .int(writeOrdinal),
        .int(Self.hasNonemptyBody(record.finalText) ? 1 : 0),
      ],
      to: statement
    )

    try step(statement, expecting: SQLITE_DONE)
  }

  private struct StoredHistoryIdentity {
    let runID: UUID?
    let workflowID: UUID?
    let timestamp: Date
    let isRecordRelated: Bool
    let outcome: HistoryOutcome
    let trigger: WorkflowRunTriggerKind?
    let generation: RunHistoryWriteGeneration
    let hasNonemptyFinalText: Bool

    func matches(
      _ record: WorkflowResultRecord,
      generation requestedGeneration: RunHistoryWriteGeneration
    ) -> Bool {
      runID == record.runID
        && workflowID == record.workflowID
        && timestamp.timeIntervalSince1970 == record.timestamp.timeIntervalSince1970
        && isRecordRelated == record.isRecordRelated
        && outcome == record.outcome
        && trigger == record.trigger
        && generation == requestedGeneration
        && hasNonemptyFinalText == SQLitePersistenceStore.hasNonemptyBody(record.finalText)
    }
  }

  /// A snapshot freezes membership and ordering, while an intentional body or
  /// correction revision remains visible at its stable row coordinate.
  private func storedHistoryIdentity(recordID: UUID) throws -> StoredHistoryIdentity? {
    let statement = try prepare(
      """
      SELECT run_id, workflow_id, timestamp, is_stack_related, outcome,
             trigger_kind, write_generation, has_nonempty_final_text
      FROM history_records
      WHERE id = ?;
      """
    )
    defer { sqlite3_finalize(statement) }
    try bind([.text(recordID.uuidString)], to: statement)
    switch sqlite3_step(statement) {
    case SQLITE_DONE:
      return nil
    case SQLITE_ROW:
      let runID: UUID?
      if let rawRunID = textColumn(in: statement, index: 0) {
        guard let decoded = UUID(uuidString: rawRunID) else {
          throw SQLitePersistenceError.decodingRow(
            "History identity contained an invalid run coordinate."
          )
        }
        runID = decoded
      } else {
        runID = nil
      }
      let workflowID: UUID?
      if let rawWorkflowID = textColumn(in: statement, index: 1) {
        guard let decoded = UUID(uuidString: rawWorkflowID) else {
          throw SQLitePersistenceError.decodingRow(
            "History identity contained an invalid workflow coordinate."
          )
        }
        workflowID = decoded
      } else {
        workflowID = nil
      }
      guard let outcomeText = textColumn(in: statement, index: 4),
        let outcome = HistoryOutcome(rawValue: outcomeText)
      else {
        throw SQLitePersistenceError.decodingRow(
          "History identity contained an invalid outcome."
        )
      }
      let trigger: WorkflowRunTriggerKind?
      if let triggerText = textColumn(in: statement, index: 5) {
        guard let decoded = WorkflowRunTriggerKind(rawValue: triggerText) else {
          throw SQLitePersistenceError.decodingRow(
            "History identity contained an invalid trigger."
          )
        }
        trigger = decoded
      } else {
        trigger = nil
      }
      let generation: RunHistoryWriteGeneration
      do {
        generation = try RunHistoryWriteGeneration(sqlite3_column_int64(statement, 6))
      } catch {
        throw SQLitePersistenceError.decodingRow(
          "History identity contained an invalid generation."
        )
      }
      return StoredHistoryIdentity(
        runID: runID,
        workflowID: workflowID,
        timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
        isRecordRelated: sqlite3_column_int64(statement, 3) != 0,
        outcome: outcome,
        trigger: trigger,
        generation: generation,
        hasNonemptyFinalText: sqlite3_column_int64(statement, 7) != 0
      )
    default:
      throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
    }
  }

  private func updateHistoryRecordContent(
    _ record: WorkflowResultRecord,
    protectedFallbackName: String,
    protectedFinalText: String?,
    correctionSourceJSON: String?
  ) throws {
    let statement = try prepare(
      """
      UPDATE history_records
      SET workflow_fallback_name = ?, workflow_title_key = ?, final_text = ?,
          failure_message = ?, correction_source_json = ?
      WHERE id = ?;
      """
    )
    defer { sqlite3_finalize(statement) }
    try bind(
      [
        .text(protectedFallbackName),
        record.workflow.titleKey.map { .text($0.rawValue) } ?? .null,
        protectedFinalText.map(SQLiteBinding.text) ?? .null,
        record.failureMessage.map(SQLiteBinding.text) ?? .null,
        correctionSourceJSON.map(SQLiteBinding.text) ?? .null,
        .text(record.id.uuidString),
      ],
      to: statement
    )
    try step(statement, expecting: SQLITE_DONE)
    guard sqlite3_changes(db) == 1 else {
      throw SQLitePersistenceError.steppingStatement(
        "History content revision lost its stable row coordinate."
      )
    }
  }

  public func records(matching query: HistoryQuery) async throws -> [WorkflowResultRecord] {
    if query.limit == 0 { return [] }
    let resultLimit = query.limit.flatMap { $0 >= 0 ? $0 : nil }
    let currentGeneration = try currentRunHistoryWriteGeneration()
    var clauses = ["write_generation = ?"]
    var bindings: [SQLiteBinding] = [.int(currentGeneration.value)]

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

    if let recordRelatedOnly = query.recordRelatedOnly {
      clauses.append("is_stack_related = ?")
      bindings.append(.int(recordRelatedOnly ? 1 : 0))
    }

    var records: [WorkflowResultRecord] = []
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
      resultLimit.map({ records.count < $0 }) ?? true
    {
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
            outcome,
            correction_source_json,
            trigger_kind
        FROM history_records
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
            records.append(try decodeHistoryRecord(from: statement))
          } catch {
            skippedCorruptRowCount += 1
            continue
          }
          if let resultLimit, records.count >= resultLimit {
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

    Self.reportSkippedCorruptHistoryRows(skippedCorruptRowCount)
    return records
  }

  public func insertTerminal(_ receipt: WorkflowRunReceipt) async throws {
    let generation = try currentRunHistoryWriteGeneration()
    try withImmediateTransaction { try insertTerminalReceipt(receipt, generation: generation) }
  }

  public func insertTerminal(
    _ receipt: WorkflowRunReceipt,
    generation: RunHistoryWriteGeneration
  ) async throws {
    try withImmediateTransaction { try insertTerminalReceipt(receipt, generation: generation) }
  }

  public func commitTerminal(
    _ receipt: WorkflowRunReceipt,
    history: WorkflowResultRecord?,
    generation: RunHistoryWriteGeneration
  ) async throws {
    if let history {
      guard history.runID == receipt.runID, history.workflowID == receipt.workflowID,
        history.timestamp == receipt.timestamp, history.trigger == receipt.trigger
      else { throw HistoryRepositoryError.conflictingHistoryRecord(recordID: history.id) }
    }
    let preparedHistory = try history.map(prepareHistoryRecord)
    try withImmediateTransaction {
      try insertTerminalReceipt(receipt, generation: generation)
      if let preparedHistory { try saveHistoryRecord(preparedHistory, generation: generation) }
    }
  }

  private func insertTerminalReceipt(
    _ receipt: WorkflowRunReceipt,
    generation: RunHistoryWriteGeneration
  ) throws {
    let encodedReceipt: String
    do {
      encodedReceipt = String(decoding: try encoder.encode(receipt), as: UTF8.self)
    } catch {
      throw SQLitePersistenceError.encodingValue(error.localizedDescription)
    }
    let runID = receipt.runID.uuidString
    let protectedPayload = try protectString(
      encodedReceipt,
      context: Self.runReceiptProtectionContext(runID: runID)
    )
    guard try generationIsCurrent(generation) else {
      throw WorkflowRunReceiptRepositoryError.writeObsoletedByClearBarrier(
        runID: receipt.runID
      )
    }
    try deleteObsoleteStoredReceipt(
      forRunID: receipt.runID,
      before: generation
    )
    if let existing = try storedReceipt(
      forRunID: receipt.runID,
      generation: generation
    ) {
      guard existing == receipt else {
        throw WorkflowRunReceiptRepositoryError.conflictingTerminalReceipt(
          runID: receipt.runID
        )
      }
      return
    }
    let writeOrdinal = try nextRunHistoryWriteOrdinal()

    let statement = try prepare(
      """
      INSERT INTO workflow_run_receipts (
          run_id, timestamp, payload, write_generation, write_ordinal
      ) VALUES (?, ?, ?, ?, ?);
      """
    )
    defer { sqlite3_finalize(statement) }
    try bind(
      [
        .text(runID),
        .double(receipt.timestamp.timeIntervalSince1970),
        .text(protectedPayload),
        .int(generation.value),
        .int(writeOrdinal),
      ],
      to: statement
    )
    try step(statement, expecting: SQLITE_DONE)
  }

  public func receipts(
    matching query: WorkflowRunReceiptQuery
  ) async throws -> [WorkflowRunReceipt] {
    if query.limit == 0 { return [] }
    let resultLimit = query.limit.flatMap { $0 >= 0 ? $0 : nil }
    let currentGeneration = try currentRunHistoryWriteGeneration()
    if let requestedRunIDs = query.runIDs {
      let exactRunIDs: Set<UUID>
      if let runID = query.runID {
        guard requestedRunIDs.contains(runID) else { return [] }
        exactRunIDs = [runID]
      } else {
        exactRunIDs = requestedRunIDs
      }
      return try receipts(
        forExactRunIDs: exactRunIDs,
        matching: query,
        resultLimit: resultLimit,
        generation: currentGeneration
      )
    }

    var clauses = ["write_generation = ?"]
    var bindings: [SQLiteBinding] = [.int(currentGeneration.value)]
    if let runID = query.runID {
      clauses.append("run_id = ?")
      bindings.append(.text(runID.uuidString))
    }
    if let since = query.since {
      clauses.append("timestamp >= ?")
      bindings.append(.double(since.timeIntervalSince1970))
    }

    var result: [WorkflowRunReceipt] = []
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
      resultLimit.map({ result.count < $0 }) ?? true
    {
      var sql = "SELECT run_id, timestamp, payload FROM workflow_run_receipts"
      if !clauses.isEmpty {
        sql += " WHERE " + clauses.joined(separator: " AND ")
      }
      sql += " ORDER BY timestamp DESC, run_id ASC LIMIT ? OFFSET ?"

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

          let receipt: WorkflowRunReceipt
          do {
            receipt = try decodeRunReceipt(from: statement)
          } catch {
            skippedCorruptRowCount += 1
            continue
          }
          guard query.workflowID == nil || receipt.workflowID == query.workflowID,
            query.trigger == nil || receipt.trigger == query.trigger,
            query.outcome == nil || receipt.outcome == query.outcome
          else {
            continue
          }
          result.append(receipt)
          if let resultLimit, result.count >= resultLimit {
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

    Self.reportSkippedCorruptRunReceiptRows(skippedCorruptRowCount)
    return result
  }

  public func page(_ request: RunHistoryPageRequest) async throws -> RunHistoryPage {
    try validateBrowseLimit(request.limit)
    switch request {
    case .first(let scope, let retentionCutoff, let contentAccess, let limit):
      let session = try captureRunHistoryReadSession(
        scope: scope,
        retentionCutoff: retentionCutoff,
        contentAccess: contentAccess
      )
      return try makeRunHistoryPage(session: session, after: nil, limit: limit)
    case .next(let cursor, let limit):
      return try makeRunHistoryPage(
        session: cursor.session,
        after: cursor.after,
        limit: limit
      )
    }
  }

  public func page(
    containing entryID: UUID,
    in session: RunHistoryReadSession,
    limit: Int
  ) async throws -> RunHistoryPage? {
    try validateBrowseLimit(limit)
    return try runHistoryPageContaining(
      entryID,
      session: session,
      limit: limit
    )
  }

  public func page(
    containing entryID: UUID,
    scope: RunHistoryBrowseScope,
    retentionCutoff: Date?,
    contentAccess: RunHistoryContentAccess,
    limit: Int
  ) async throws -> RunHistoryPage? {
    try validateBrowseLimit(limit)
    let session = try captureRunHistoryReadSession(
      scope: scope,
      retentionCutoff: retentionCutoff,
      contentAccess: contentAccess
    )
    return try runHistoryPageContaining(
      entryID,
      session: session,
      limit: limit
    )
  }

  private struct BrowseCandidate {
    enum Source: Int64 {
      case receipt = 0
      case orphanRecord = 1
    }

    let source: Source
    let key: RunHistorySortKey
    let recordMetadata: RunHistoryRecordMetadata?
    let protectedReceiptPayload: String?
  }

  private func validateBrowseLimit(_ limit: Int) throws {
    guard (1...50).contains(limit) else {
      throw RunHistoryBrowsingError.invalidLimit(limit)
    }
  }

  private func captureRunHistoryReadSession(
    scope: RunHistoryBrowseScope,
    retentionCutoff: Date?,
    contentAccess: RunHistoryContentAccess
  ) throws -> RunHistoryReadSession {
    try RunHistoryReadSession(
      generation: currentRunHistoryWriteGeneration(),
      snapshotWriteOrdinal: currentRunHistoryWriteOrdinal(),
      retentionCutoff: retentionCutoff,
      scope: scope,
      contentAccess: contentAccess
    )
  }

  private func validate(_ session: RunHistoryReadSession) throws {
    let current = try currentRunHistoryWriteGeneration()
    guard current == session.generation else {
      throw RunHistoryBrowsingError.sessionInvalidated(
        expected: session.generation,
        actual: current
      )
    }
  }

  private func makeRunHistoryPage(
    session: RunHistoryReadSession,
    after: RunHistorySortKey?,
    limit: Int
  ) throws -> RunHistoryPage {
    try validateBrowseLimit(limit)
    try validate(session)
    let fetched = try browseRunHistoryEntries(
      session: session,
      after: after,
      maximumCount: limit + 1
    )
    let entries = Array(fetched.prefix(limit))
    let nextCursor: RunHistoryCursor?
    if fetched.count > limit, let last = entries.last {
      nextCursor = RunHistoryCursor(
        session: session,
        after: RunHistorySortKey(timestamp: last.timestamp, entryID: last.id)
      )
    } else {
      nextCursor = nil
    }
    return RunHistoryPage(
      session: session,
      entries: entries,
      nextCursor: nextCursor
    )
  }

  private func runHistoryPageContaining(
    _ entryID: UUID,
    session: RunHistoryReadSession,
    limit: Int
  ) throws -> RunHistoryPage? {
    var cursor: RunHistoryCursor?
    while true {
      let page = try makeRunHistoryPage(
        session: session,
        after: cursor?.after,
        limit: limit
      )
      if page.entries.contains(where: { entry in
        entry.id == entryID
          || (entry.receipt == nil && entry.recordMetadata?.runID == entryID)
          || entry.recordMetadata?.recordID == entryID
      }) {
        return page
      }
      guard let nextCursor = page.nextCursor else { return nil }
      cursor = nextCursor
    }
  }

  private func browseRunHistoryEntries(
    session: RunHistoryReadSession,
    after initialKey: RunHistorySortKey?,
    maximumCount: Int
  ) throws -> [RunHistoryEntry] {
    var entries: [RunHistoryEntry] = []
    var scanAfter = initialKey
    let batchSize = 64
    var skippedCorruptReceiptCount = 0
    var skippedCorruptRecordCount = 0

    while entries.count < maximumCount {
      let candidates = try browseCandidates(
        session: session,
        after: scanAfter,
        limit: batchSize
      )
      guard !candidates.isEmpty else { break }
      for candidate in candidates {
        scanAfter = candidate.key
        switch candidate.source {
        case .receipt:
          guard let protectedPayload = candidate.protectedReceiptPayload else {
            skippedCorruptReceiptCount += 1
            continue
          }
          let receipt: WorkflowRunReceipt
          do {
            receipt = try decodeBrowseReceipt(
              runID: candidate.key.entryID,
              timestamp: candidate.key.timestamp,
              protectedPayload: protectedPayload
            )
          } catch {
            skippedCorruptReceiptCount += 1
            continue
          }
          if session.scope == .voiceResults {
            guard receipt.outcome == .completed, receipt.trigger.isVoiceCapture else {
              continue
            }
          }
          let matchedMetadata =
            receipt.trigger.isVoiceCapture
            ? try matchedRecordMetadata(for: receipt, session: session)
            : nil
          if session.scope == .voiceResults {
            guard let matchedMetadata,
              matchedMetadata.outcome == .completed,
              matchedMetadata.hasNonemptyFinalText
            else {
              continue
            }
          }
          let record = try openedHistoryRecordIfAllowed(
            metadata: matchedMetadata,
            authoritativeTrigger: receipt.trigger,
            session: session,
            bodyRequired: session.scope == .voiceResults,
            corruptCount: &skippedCorruptRecordCount
          )
          if session.scope == .voiceResults,
            session.contentAccess != .metadataOnly,
            record == nil
          {
            continue
          }
          entries.append(
            try RunHistoryEntry(
              id: receipt.runID,
              timestamp: receipt.timestamp,
              recordMetadata: matchedMetadata,
              record: record,
              receipt: receipt
            )
          )
        case .orphanRecord:
          guard let metadata = candidate.recordMetadata else {
            skippedCorruptRecordCount += 1
            continue
          }
          if session.scope == .voiceResults {
            guard metadata.outcome == .completed,
              metadata.trigger?.isVoiceCapture == true,
              metadata.hasNonemptyFinalText
            else {
              continue
            }
          }
          let record = try openedHistoryRecordIfAllowed(
            metadata: metadata,
            authoritativeTrigger: metadata.trigger,
            session: session,
            bodyRequired: session.scope == .voiceResults,
            corruptCount: &skippedCorruptRecordCount
          )
          if session.scope == .voiceResults,
            session.contentAccess != .metadataOnly,
            record == nil
          {
            continue
          }
          if session.scope == .allRuns,
            session.contentAccess != .metadataOnly,
            metadata.trigger?.isVoiceCapture == true,
            record == nil
          {
            // A body-authorized orphan with an unreadable protected projection
            // is a corrupt row, not a metadata result that may consume a slot.
            continue
          }
          entries.append(
            try RunHistoryEntry(
              id: candidate.key.entryID,
              timestamp: metadata.timestamp,
              recordMetadata: metadata,
              record: record
            )
          )
        }
        if entries.count >= maximumCount { break }
      }
      if candidates.count < batchSize { break }
    }

    Self.reportSkippedCorruptRunReceiptRows(skippedCorruptReceiptCount)
    Self.reportSkippedCorruptHistoryRows(skippedCorruptRecordCount)
    return entries
  }

  private func browseCandidates(
    session: RunHistoryReadSession,
    after: RunHistorySortKey?,
    limit: Int
  ) throws -> [BrowseCandidate] {
    func visibilityClause(alias: String?) -> String {
      let prefix = alias.map { "\($0)." } ?? ""
      let cutoffClause =
        session.retentionCutoff == nil
        ? ""
        : " AND \(prefix)timestamp >= ?"
      return "\(prefix)write_generation = ? AND \(prefix)write_ordinal <= ?" + cutoffClause
    }
    let receiptVisibility = visibilityClause(alias: nil)
    let historyVisibility = visibilityClause(alias: "h")
    let joinedReceiptVisibility = visibilityClause(alias: "r")
    let competingHistoryVisibility = visibilityClause(alias: "h2")
    var sql = """
      SELECT source_kind, entry_id, timestamp, write_ordinal,
             record_id, run_id, workflow_id, outcome, trigger_kind,
             is_stack_related, has_nonempty_final_text, protected_payload
      FROM (
          SELECT 0 AS source_kind, run_id AS entry_id, timestamp, write_ordinal,
                 NULL AS record_id, run_id, NULL AS workflow_id,
                 NULL AS outcome, NULL AS trigger_kind,
                 NULL AS is_stack_related, NULL AS has_nonempty_final_text,
                 payload AS protected_payload
          FROM workflow_run_receipts
          WHERE \(receiptVisibility)
          UNION ALL
          SELECT 1 AS source_kind, COALESCE(h.run_id, h.id) AS entry_id,
                 h.timestamp, h.write_ordinal,
                 h.id AS record_id, h.run_id, h.workflow_id, h.outcome,
                 h.trigger_kind, h.is_stack_related, h.has_nonempty_final_text,
                 NULL AS protected_payload
          FROM history_records AS h
          WHERE \(historyVisibility)
            AND NOT EXISTS (
                SELECT 1
                FROM workflow_run_receipts AS r
                WHERE h.run_id IS NOT NULL AND r.run_id = h.run_id
                  AND \(joinedReceiptVisibility)
            )
            AND (
                h.run_id IS NULL
                OR NOT EXISTS (
                    SELECT 1
                    FROM history_records AS h2
                    WHERE h2.run_id = h.run_id
                      AND \(competingHistoryVisibility)
                      AND (
                          h2.timestamp > h.timestamp
                          OR (h2.timestamp = h.timestamp AND h2.id < h.id)
                      )
                )
            )
      ) AS timeline
      """
    var bindings: [SQLiteBinding] = []
    func appendVisibilityBindings() {
      bindings.append(.int(session.generation.value))
      bindings.append(.int(session.snapshotWriteOrdinal))
      if let cutoff = session.retentionCutoff {
        bindings.append(.double(cutoff.timeIntervalSince1970))
      }
    }
    appendVisibilityBindings()
    appendVisibilityBindings()
    appendVisibilityBindings()
    appendVisibilityBindings()
    if let after {
      sql += " WHERE timestamp < ? OR (timestamp = ? AND entry_id > ?)"
      bindings.append(.double(after.timestamp.timeIntervalSince1970))
      bindings.append(.double(after.timestamp.timeIntervalSince1970))
      bindings.append(.text(after.entryID.uuidString))
    }
    sql += " ORDER BY timestamp DESC, entry_id ASC;"

    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    try bind(bindings, to: statement)
    var candidates: [BrowseCandidate] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_DONE:
        return candidates
      case SQLITE_ROW:
        guard
          let source = BrowseCandidate.Source(
            rawValue: sqlite3_column_int64(statement, 0)
          ),
          let entryIDText = textColumn(in: statement, index: 1),
          let entryID = UUID(uuidString: entryIDText)
        else {
          continue
        }
        let key = RunHistorySortKey(
          timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
          entryID: entryID
        )
        let metadata: RunHistoryRecordMetadata?
        if source == .orphanRecord {
          metadata = try? decodeBrowseRecordMetadata(from: statement)
        } else {
          metadata = nil
        }
        candidates.append(
          BrowseCandidate(
            source: source,
            key: key,
            recordMetadata: metadata,
            protectedReceiptPayload: textColumn(in: statement, index: 11)
          )
        )
        if candidates.count >= limit {
          return candidates
        }
      default:
        throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
      }
    }
  }

  private func decodeBrowseRecordMetadata(
    from statement: OpaquePointer?
  ) throws -> RunHistoryRecordMetadata {
    guard let recordIDText = textColumn(in: statement, index: 4),
      let recordID = UUID(uuidString: recordIDText),
      let outcomeText = textColumn(in: statement, index: 7),
      let outcome = HistoryOutcome(rawValue: outcomeText)
    else {
      throw SQLitePersistenceError.decodingRow(
        "A run-history record candidate had invalid metadata."
      )
    }
    let runID = try optionalUUIDColumn(in: statement, index: 5)
    let workflowID = try optionalUUIDColumn(in: statement, index: 6)
    let trigger: WorkflowRunTriggerKind?
    if let rawTrigger = textColumn(in: statement, index: 8) {
      guard let decoded = WorkflowRunTriggerKind(rawValue: rawTrigger) else {
        throw SQLitePersistenceError.decodingRow(
          "A run-history record candidate had an invalid trigger."
        )
      }
      trigger = decoded
    } else {
      trigger = nil
    }
    return RunHistoryRecordMetadata(
      recordID: recordID,
      runID: runID,
      workflowID: workflowID,
      timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
      isRecordRelated: sqlite3_column_int64(statement, 9) != 0,
      outcome: outcome,
      trigger: trigger,
      hasNonemptyFinalText: trigger?.isVoiceCapture == true
        && sqlite3_column_int64(statement, 10) != 0
    )
  }

  private func optionalUUIDColumn(
    in statement: OpaquePointer?,
    index: Int32
  ) throws -> UUID? {
    guard let rawValue = textColumn(in: statement, index: index) else { return nil }
    guard let value = UUID(uuidString: rawValue) else {
      throw SQLitePersistenceError.decodingRow(
        "A run-history candidate had an invalid UUID coordinate."
      )
    }
    return value
  }

  private func decodeBrowseReceipt(
    runID: UUID,
    timestamp: Date,
    protectedPayload: String
  ) throws -> WorkflowRunReceipt {
    let payload = try openString(
      protectedPayload,
      context: Self.runReceiptProtectionContext(runID: runID.uuidString)
    )
    do {
      let receipt = try decoder.decode(
        WorkflowRunReceipt.self,
        from: Data(payload.utf8)
      )
      guard receipt.runID == runID,
        abs(receipt.timestamp.timeIntervalSince(timestamp)) < 0.001
      else {
        throw SQLitePersistenceError.decodingRow(
          "Workflow run receipt index did not match its protected payload."
        )
      }
      return receipt
    } catch let error as SQLitePersistenceError {
      throw error
    } catch {
      throw SQLitePersistenceError.decodingRow(error.localizedDescription)
    }
  }

  private func matchedRecordMetadata(
    for receipt: WorkflowRunReceipt,
    session: RunHistoryReadSession
  ) throws -> RunHistoryRecordMetadata? {
    var sql = """
      SELECT id, run_id, workflow_id, timestamp, is_stack_related, outcome,
             trigger_kind, has_nonempty_final_text
      FROM history_records
      WHERE run_id = ? AND write_generation = ? AND write_ordinal <= ?
        AND trigger_kind = ?
      """
    var bindings: [SQLiteBinding] = [
      .text(receipt.runID.uuidString),
      .int(session.generation.value),
      .int(session.snapshotWriteOrdinal),
      .text(receipt.trigger.rawValue),
    ]
    if let cutoff = session.retentionCutoff {
      sql += " AND timestamp >= ?"
      bindings.append(.double(cutoff.timeIntervalSince1970))
    }
    sql += " ORDER BY timestamp DESC, id ASC;"
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    try bind(bindings, to: statement)
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_DONE:
        return nil
      case SQLITE_ROW:
        do {
          guard let recordIDText = textColumn(in: statement, index: 0),
            let recordID = UUID(uuidString: recordIDText),
            let outcomeText = textColumn(in: statement, index: 5),
            let outcome = HistoryOutcome(rawValue: outcomeText),
            let triggerText = textColumn(in: statement, index: 6),
            let trigger = WorkflowRunTriggerKind(rawValue: triggerText)
          else {
            continue
          }
          return RunHistoryRecordMetadata(
            recordID: recordID,
            runID: try optionalUUIDColumn(in: statement, index: 1),
            workflowID: try optionalUUIDColumn(in: statement, index: 2),
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            isRecordRelated: sqlite3_column_int64(statement, 4) != 0,
            outcome: outcome,
            trigger: trigger,
            hasNonemptyFinalText: sqlite3_column_int64(statement, 7) != 0
          )
        } catch {
          continue
        }
      default:
        throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
      }
    }
  }

  private func openedHistoryRecordIfAllowed(
    metadata: RunHistoryRecordMetadata?,
    authoritativeTrigger: WorkflowRunTriggerKind?,
    session: RunHistoryReadSession,
    bodyRequired: Bool,
    corruptCount: inout Int
  ) throws -> WorkflowResultRecord? {
    guard let metadata,
      authoritativeTrigger?.isVoiceCapture == true,
      metadata.trigger == authoritativeTrigger,
      session.contentAccess != .metadataOnly
    else {
      return nil
    }
    let fullRecord: WorkflowResultRecord
    do {
      guard
        let opened = try openedHistoryRecord(
          recordID: metadata.recordID,
          session: session
        )
      else {
        return nil
      }
      fullRecord = opened
    } catch {
      corruptCount += 1
      return nil
    }
    if bodyRequired, !Self.hasNonemptyBody(fullRecord.finalText) {
      return nil
    }
    guard session.contentAccess == .restrictedPreview else { return fullRecord }
    return WorkflowResultRecord(
      id: fullRecord.id,
      runID: fullRecord.runID,
      workflowID: fullRecord.workflowID,
      workflow: fullRecord.workflow,
      finalText: fullRecord.finalText.map {
        RecordTextFormatting.previewText(
          $0,
          limit: RunHistoryContentAccess.restrictedPreviewCharacterLimit
        )
      },
      failureMessage: fullRecord.failureMessage,
      timestamp: fullRecord.timestamp,
      isRecordRelated: fullRecord.isRecordRelated,
      outcome: fullRecord.outcome,
      correctionSource: fullRecord.correctionSource?.restrictedStepPreview,
      trigger: fullRecord.trigger
    )
  }

  private func openedHistoryRecord(
    recordID: UUID,
    session: RunHistoryReadSession
  ) throws -> WorkflowResultRecord? {
    let correctionProjection =
      session.contentAccess != .metadataOnly
      ? "correction_source_json"
      : "NULL AS correction_source_json"
    var sql = """
      SELECT id, run_id, workflow_id, workflow_fallback_name,
             workflow_title_key, final_text, failure_message, timestamp,
             is_stack_related, outcome, \(correctionProjection), trigger_kind
      FROM history_records
      WHERE id = ? AND write_generation = ? AND write_ordinal <= ?
      """
    var bindings: [SQLiteBinding] = [
      .text(recordID.uuidString),
      .int(session.generation.value),
      .int(session.snapshotWriteOrdinal),
    ]
    if let cutoff = session.retentionCutoff {
      sql += " AND timestamp >= ?"
      bindings.append(.double(cutoff.timeIntervalSince1970))
    }
    sql += ";"
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    try bind(bindings, to: statement)
    switch sqlite3_step(statement) {
    case SQLITE_DONE:
      return nil
    case SQLITE_ROW:
      return try decodeHistoryRecord(from: statement)
    default:
      throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
    }
  }

  public func deleteReceipts(olderThan cutoff: Date) async throws -> Int {
    let statement = try prepare("DELETE FROM workflow_run_receipts WHERE timestamp < ?;")
    defer { sqlite3_finalize(statement) }
    try bind([.double(cutoff.timeIntervalSince1970)], to: statement)
    try step(statement, expecting: SQLITE_DONE)
    return Int(sqlite3_changes(db))
  }

  public func deleteReceipts(through upperBound: Date) async throws -> Int {
    let statement = try prepare(
      "DELETE FROM workflow_run_receipts WHERE timestamp <= ?;"
    )
    defer { sqlite3_finalize(statement) }
    try bind([.double(upperBound.timeIntervalSince1970)], to: statement)
    try step(statement, expecting: SQLITE_DONE)
    return Int(sqlite3_changes(db))
  }

  public func deleteReceipts(
    obsoletedBy transition: RunHistoryClearTransition,
    preservingLegacyRowsAfter legacyUpperBound: Date?
  ) async throws -> Int {
    try deleteRunHistoryRows(
      obsoletedBy: transition,
      from: "workflow_run_receipts",
      preservingLegacyRowsAfter: legacyUpperBound
    )
  }

  public func deleteAllReceipts() async throws -> Int {
    let statement = try prepare("DELETE FROM workflow_run_receipts;")
    defer { sqlite3_finalize(statement) }
    try step(statement, expecting: SQLITE_DONE)
    return Int(sqlite3_changes(db))
  }

  public func deleteRecords(olderThan cutoff: Date) async throws -> Int {
    let statement = try prepare("DELETE FROM history_records WHERE timestamp < ?;")
    defer { sqlite3_finalize(statement) }
    try bind([.double(cutoff.timeIntervalSince1970)], to: statement)
    try step(statement, expecting: SQLITE_DONE)
    return Int(sqlite3_changes(db))
  }

  public func deleteRecords(through upperBound: Date) async throws -> Int {
    let statement = try prepare(
      "DELETE FROM history_records WHERE timestamp <= ?;"
    )
    defer { sqlite3_finalize(statement) }
    try bind([.double(upperBound.timeIntervalSince1970)], to: statement)
    try step(statement, expecting: SQLITE_DONE)
    return Int(sqlite3_changes(db))
  }

  public func deleteRecords(
    obsoletedBy transition: RunHistoryClearTransition,
    preservingLegacyRowsAfter legacyUpperBound: Date?
  ) async throws -> Int {
    try deleteRunHistoryRows(
      obsoletedBy: transition,
      from: "history_records",
      preservingLegacyRowsAfter: legacyUpperBound
    )
  }

  public func deleteAllRecords() async throws -> Int {
    let statement = try prepare("DELETE FROM history_records;")
    defer { sqlite3_finalize(statement) }
    try step(statement, expecting: SQLITE_DONE)
    return Int(sqlite3_changes(db))
  }

}
