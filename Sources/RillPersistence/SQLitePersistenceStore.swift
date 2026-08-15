import Darwin
import Foundation
import OSLog
import SQLite3
import RillCore

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
  case protectingLocalData
  case openingProtectedLocalData
  case clipboardPersistenceUnavailable
  case clipboardPersistenceRevisionConflict
  case clipboardPersistenceInvalidWriteSnapshot
  case clipboardPersistenceBlobConflict

  public var errorDescription: String? {
    switch self {
    case .missingApplicationSupportDirectory:
      return "Unable to locate the Application Support directory for Rill."
    case .openingDatabase(let message):
      return "Failed to open the Rill SQLite database: \(message)"
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
    case .protectingLocalData:
      return "Local data could not be protected before persistence."
    case .openingProtectedLocalData:
      return "Protected local data could not be authenticated or decoded."
    case .clipboardPersistenceUnavailable:
      return "Protected clipboard persistence is unavailable."
    case .clipboardPersistenceRevisionConflict:
      return "Protected clipboard persistence changed before the snapshot could be committed."
    case .clipboardPersistenceInvalidWriteSnapshot:
      return "The protected clipboard persistence snapshot is invalid."
    case .clipboardPersistenceBlobConflict:
      return "A protected clipboard image identity conflicts with durable storage."
    }
  }
}

private enum SQLiteBinding {
  case text(String)
  case blob(Data)
  case double(Double)
  case int(Int64)
  case null
}

public actor SQLitePersistenceStore: HistoryRepository, WorkflowRunReceiptRepository,
  RunHistoryBrowsing,
  DiagnosticRepository,
  SensitiveSettingsStore, ExportMetadataRepository,
  RecordGraphPersistenceStore
{
  private static let logger = Logger(
    subsystem: "dev.zrr.Rill",
    category: "persistence"
  )

  public let databaseURL: URL

  private let connection: SQLiteConnectionBox
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let localDataProtector: any LocalDataProtector

  private static let clipboardStorageLimits = SystemClipboardStorageLimits.productDefault
  private static let maximumClipboardBlobCount =
    clipboardStorageLimits.maximumActiveItemCount
    + clipboardStorageLimits.maximumHistoryOnlyItemCount
  private static let maximumProtectedClipboardMetadataByteCount =
    clipboardStorageLimits.maximumPersistedStateUTF8ByteCount * 2
  private static let maximumProtectedClipboardImageByteCount =
    clipboardStorageLimits.maximumImageByteCount * 2

  public init(localDataProtector: any LocalDataProtector) throws {
    try self.init(
      databaseURL: Self.defaultDatabaseURL(),
      localDataProtector: localDataProtector
    )
  }

  public init(
    databaseURL: URL,
    localDataProtector: any LocalDataProtector
  ) throws {
    self.databaseURL = databaseURL
    self.localDataProtector = localDataProtector
    try Self.preparePrivateStorage(at: databaseURL)
    let preexistingStorageMayContainResidue =
      Self
      .preexistingStorageMayContainResidue(at: databaseURL)

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
    try SQLiteWriterBarrier.registerCapability(on: handle)
    try Self.execute(
      """
      PRAGMA journal_mode = WAL;
      PRAGMA foreign_keys = ON;
      PRAGMA secure_delete = ON;
      PRAGMA busy_timeout = 5000;
      PRAGMA trusted_schema = OFF;
      """,
      on: handle
    )
    try Self.preparePrivateStorage(at: databaseURL)
    let dataProtectionCleanupIsPending = try Self.migrate(
      on: handle,
      localDataProtector: localDataProtector,
      preexistingStorageMayContainResidue: preexistingStorageMayContainResidue
    )
    if dataProtectionCleanupIsPending {
      try Self.ensureSecureDeleteEnabled(on: handle)
      try Self.truncateWriteAheadLog(on: handle)
      try Self.execute("VACUUM;", on: handle)
      try Self.truncateWriteAheadLog(on: handle)
      try Self.markDataProtectionCleanupCompleted(on: handle)
    }
  }

  public static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
    guard
      let appSupportURL = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      throw SQLitePersistenceError.missingApplicationSupportDirectory
    }

    return
      appSupportURL
      .appendingPathComponent("Rill", isDirectory: true)
      .appendingPathComponent("rill.sqlite", isDirectory: false)
  }

  /// Existing v4 databases are cryptographically bound to their original
  /// Keychain root key. Orphaned SQLite sidecars and unsafe filesystem entries
  /// are also treated as potentially bound storage. Callers must not generate
  /// a replacement key for any of these states.
  public static func requiresExistingDataProtectionKey(
    databaseURL: URL,
    fileManager: FileManager = .default
  ) throws -> Bool {
    let mainStorageState = keyPreflightStorageState(
      at: databaseURL,
      fileManager: fileManager
    )
    let sidecarStorageStates = ["-wal", "-shm", "-journal"].map { suffix in
      keyPreflightStorageState(
        at: URL(fileURLWithPath: databaseURL.path + suffix, isDirectory: false),
        fileManager: fileManager
      )
    }

    switch mainStorageState {
    case .missing:
      // A sidecar can contain database pages even after the main file is lost.
      // Conservatively retain the existing root-key requirement for every
      // filesystem object, including dangling symlinks and unusual file types.
      return sidecarStorageStates.contains { $0 != .missing }
    case .unsafeOrUninspectable:
      return true
    case .regularFile:
      // Never let SQLite follow an unsafe sidecar while deciding whether a new
      // root key may be generated.
      guard !sidecarStorageStates.contains(.unsafeOrUninspectable) else {
        return true
      }
    }

    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
      let handle
    else {
      let message = Self.lastErrorMessage(from: handle)
      if let handle {
        sqlite3_close(handle)
      }
      throw SQLitePersistenceError.openingDatabase(message)
    }
    defer { sqlite3_close(handle) }
    let version = try schemaVersion(on: handle)
    let hasProtectionMarker = try tableExists(
      "local_data_protection",
      on: handle
    )
    let hasAuthenticatedSchemaFloor = try tableExists(
      SQLiteAuthenticatedSchemaFloor.tableName,
      on: handle
    )
    // A protection marker below v4 can only be opened with the pre-existing
    // root key. Returning true is deliberately conservative: callers must not
    // generate a replacement key before the authenticated recovery path has a
    // chance to inspect the database.
    return version >= 4 || hasProtectionMarker || hasAuthenticatedSchemaFloor
  }

  private enum KeyPreflightStorageState: Equatable {
    case missing
    case regularFile
    case unsafeOrUninspectable
  }

  private static func keyPreflightStorageState(
    at storageURL: URL,
    fileManager: FileManager
  ) -> KeyPreflightStorageState {
    var metadata = stat()
    let result = lstat(
      fileManager.fileSystemRepresentation(withPath: storageURL.path),
      &metadata
    )
    guard result == 0 else {
      return errno == ENOENT ? .missing : .unsafeOrUninspectable
    }
    return metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
      ? .regularFile
      : .unsafeOrUninspectable
  }


  public func loadRecordGraph() async throws -> RecordGraphPersistenceReadSnapshot {
    do {
      return try withDeferredTransaction {
        let current = try storedRecordGraphMetadata()
        let legacyCurrent = try storedClipboardMetadata()
        let legacyEnvelope = try storedLegacyClipboardEnvelope()
        let legacySourceCount = [
          current != nil,
          legacyCurrent != nil,
          legacyEnvelope != nil,
        ].filter { $0 }.count
        guard legacySourceCount <= 1 else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }

        if let current {
          let graph = try localDataProtector.openBinary(
            current.protectedGraph,
            context: Self.recordGraphProtectionContext
          )
          guard !graph.isEmpty,
            graph.count <= Self.clipboardStorageLimits.maximumPersistedStateUTF8ByteCount
          else {
            throw SQLitePersistenceError.clipboardPersistenceUnavailable
          }
          return .current(
            revision: current.revision,
            graph: graph,
            payloadBlobs: try storedRecordPayloadBlobs(
              maximumTotalPlaintextByteCount:
                Self.clipboardStorageLimits.maximumPersistedStateUTF8ByteCount - graph.count
            )
          )
        }

        guard try storedRecordPayloadBlobCoordinates().isEmpty else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        if let legacyCurrent {
          let metadata = try localDataProtector.openBinary(
            legacyCurrent.protectedMetadata,
            context: Self.clipboardMetadataProtectionContext
          )
          guard !metadata.isEmpty else {
            throw SQLitePersistenceError.clipboardPersistenceUnavailable
          }
          return .legacyClipboard(
            metadata: metadata,
            imageBlobs: try storedClipboardImageBlobs(
              maximumTotalPlaintextByteCount:
                Self.clipboardStorageLimits.maximumPersistedStateUTF8ByteCount - metadata.count
            )
          )
        }
        guard (try storedClipboardBlobCoordinates()).isEmpty else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        guard let legacyEnvelope else { return .empty }
        let metadata = try localDataProtector.open(
          legacyEnvelope,
          context: Self.settingsProtectionContext(
            keyRawValue: AppSettingKey.legacyClipboardPersistedState.rawValue
          )
        )
        guard !metadata.isEmpty,
          metadata.count <= Self.clipboardStorageLimits.maximumPersistedStateUTF8ByteCount
        else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        return .legacyClipboard(metadata: metadata, imageBlobs: [])
      }
    } catch let error as SQLitePersistenceError {
      switch error {
      case .clipboardPersistenceUnavailable:
        throw error
      default:
        throw SQLitePersistenceError.clipboardPersistenceUnavailable
      }
    } catch {
      throw SQLitePersistenceError.clipboardPersistenceUnavailable
    }
  }

  /// Seeds the immediately previous encrypted graph shape for migration
  /// fixtures. Product code never writes this representation.
  func seedLegacyRecordGraphForMigrationTesting(
    metadata: Data,
    imageBlobs: [LegacyRecordGraphImageBlob]
  ) async throws {
    try withImmediateTransaction {
      guard try storedRecordGraphMetadata() == nil,
        try storedClipboardMetadata() == nil,
        try storedLegacyClipboardEnvelope() == nil
      else {
        throw SQLitePersistenceError.clipboardPersistenceRevisionConflict
      }
      let protectedMetadata = try localDataProtector.sealBinary(
        metadata,
        context: Self.clipboardMetadataProtectionContext
      )
      try upsertClipboardMetadata(protectedMetadata: protectedMetadata, revision: 1)
      for blob in imageBlobs {
        let protectedPayload = try localDataProtector.sealBinary(
          blob.payload,
          context: Self.clipboardBlobProtectionContext(reference: blob.reference)
        )
        let statement = try prepare(
          """
          INSERT INTO clipboard_image_blobs (
              blob_id, item_id, payload, plaintext_size, state_id
          ) VALUES (?, ?, ?, ?, 1);
          """
        )
        defer { sqlite3_finalize(statement) }
        try bind(
          [
            .text(blob.reference.blobID.uuidString),
            .text(blob.reference.itemID.uuidString),
            .blob(protectedPayload),
            .int(Int64(blob.reference.byteCount)),
          ],
          to: statement
        )
        try step(statement, expecting: SQLITE_DONE)
      }
    }
  }

  public func replaceRecordGraph(
    with snapshot: RecordGraphPersistenceWriteSnapshot
  ) async throws -> Int64 {
    let prepared = try prepareRecordGraphWrite(snapshot)
    do {
      return try withImmediateTransaction {
        let storedRevision = try storedRecordGraphRevision()
        let hasLegacyCurrent = try storedClipboardRevision() != nil
        let hasLegacySettings = try legacyClipboardRowExists()
        guard !(hasLegacyCurrent && hasLegacySettings),
          storedRevision == nil || (!hasLegacyCurrent && !hasLegacySettings)
        else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        switch (snapshot.expectedRevision, storedRevision) {
        case (nil, nil):
          break
        case (.some(let expected), .some(let stored)) where expected == stored:
          break
        default:
          throw SQLitePersistenceError.clipboardPersistenceRevisionConflict
        }

        let nextRevision: Int64
        if let expected = snapshot.expectedRevision {
          guard expected < .max else {
            throw SQLitePersistenceError.clipboardPersistenceRevisionConflict
          }
          nextRevision = expected + 1
        } else {
          nextRevision = 1
        }
        let storedCoordinates = try storedRecordPayloadBlobCoordinates()
        if storedRevision == nil, !storedCoordinates.isEmpty {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        let storedByBlobID = Dictionary(
          uniqueKeysWithValues: storedCoordinates.map { ($0.blobID, $0) }
        )
        for blob in prepared.newBlobs where storedByBlobID[blob.reference.blobID] != nil {
          throw SQLitePersistenceError.clipboardPersistenceBlobConflict
        }
        for reference in snapshot.retainedPayloadBlobReferences {
          guard storedByBlobID[reference.blobID] == StoredRecordPayloadBlobCoordinate(reference)
          else {
            throw SQLitePersistenceError.clipboardPersistenceBlobConflict
          }
        }

        try upsertRecordGraphMetadata(
          protectedGraph: prepared.protectedGraph,
          revision: nextRevision
        )
        for coordinate in storedCoordinates
        where !prepared.expectedBlobIDs.contains(coordinate.blobID) {
          try deleteRecordPayloadBlob(blobID: coordinate.blobID)
        }
        for blob in prepared.newBlobs { try insertRecordPayloadBlob(blob) }
        guard Set(try storedRecordPayloadBlobCoordinates()) == prepared.expectedCoordinates else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }

        // Read the protected graph and every payload back through the normal
        // decryption path before removing the legacy graph. Any key, reference,
        // size, or ciphertext problem aborts this transaction and leaves the
        // old representation authoritative.
        guard let readbackMetadata = try storedRecordGraphMetadata(),
          readbackMetadata.revision == nextRevision,
          try localDataProtector.openBinary(
            readbackMetadata.protectedGraph,
            context: Self.recordGraphProtectionContext
          ) == snapshot.graph
        else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        let readbackBlobs = try storedRecordPayloadBlobs(
          maximumTotalPlaintextByteCount:
            Self.clipboardStorageLimits.maximumPersistedStateUTF8ByteCount - snapshot.graph.count
        )
        guard Set(readbackBlobs.map { StoredRecordPayloadBlobCoordinate($0.reference) })
                == prepared.expectedCoordinates
        else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        let readbackByBlobID = Dictionary(
          uniqueKeysWithValues: readbackBlobs.map { ($0.reference.blobID, $0) }
        )
        guard snapshot.newPayloadBlobs.allSatisfy({ blob in
          readbackByBlobID[blob.reference.blobID] == blob
        }) else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }

        // The validated Record graph becomes authoritative in the same commit
        // that removes every legacy clipboard representation.
        try execute("DELETE FROM clipboard_image_blobs;")
        try execute("DELETE FROM clipboard_metadata WHERE id = 1;")
        try deleteLegacyClipboardRow()
        return nextRevision
      }
    } catch let error as SQLitePersistenceError {
      switch error {
      case .clipboardPersistenceUnavailable,
        .clipboardPersistenceRevisionConflict,
        .clipboardPersistenceInvalidWriteSnapshot,
        .clipboardPersistenceBlobConflict:
        throw error
      default:
        throw SQLitePersistenceError.clipboardPersistenceUnavailable
      }
    } catch {
      throw SQLitePersistenceError.clipboardPersistenceUnavailable
    }
  }

  public func removeRecordGraph() async throws -> RecordGraphRemovalResult {
    do {
      try withImmediateTransaction {
        try execute("DELETE FROM record_payload_blobs;")
        try execute("DELETE FROM record_graph_metadata WHERE id = 1;")
        try execute("DELETE FROM clipboard_image_blobs;")
        try execute("DELETE FROM clipboard_metadata WHERE id = 1;")
        try deleteLegacyClipboardRow()
        try markDataProtectionCleanupPending()
      }
    } catch {
      throw SQLitePersistenceError.clipboardPersistenceUnavailable
    }
    do {
      try ensureSecureDeleteEnabled()
      try truncateWriteAheadLog()
      try execute("VACUUM;")
      try truncateWriteAheadLog()
      try Self.markDataProtectionCleanupCompleted(on: db)
      return .removed
    } catch {
      return .removedCleanupPending
    }
  }

  public func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration {
    try currentRunHistoryWriteGeneration()
  }

  public func save(_ record: WorkflowResultRecord) async throws {
    let generation = try currentRunHistoryWriteGeneration()
    try saveHistoryRecord(record, generation: generation)
  }

  public func save(
    _ record: WorkflowResultRecord,
    generation: RunHistoryWriteGeneration
  ) async throws {
    try saveHistoryRecord(record, generation: generation)
  }

  private func saveHistoryRecord(
    _ record: WorkflowResultRecord,
    generation: RunHistoryWriteGeneration
  ) throws {
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
    try withImmediateTransaction {
      guard try generationIsCurrent(generation) else {
        throw HistoryRepositoryError.writeObsoletedByClearBarrier
      }
      if let existingIdentity = try storedHistoryIdentity(recordID: record.id) {
        guard existingIdentity.matches(record, generation: generation) else {
          throw HistoryRepositoryError.conflictingHistoryRecord(recordID: record.id)
        }
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
        && timestamp == record.timestamp
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
    try insertTerminalReceipt(receipt, generation: generation)
  }

  public func insertTerminal(
    _ receipt: WorkflowRunReceipt,
    generation: RunHistoryWriteGeneration
  ) async throws {
    try insertTerminalReceipt(receipt, generation: generation)
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
    try withImmediateTransaction {
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
      correctionSource: nil,
      trigger: fullRecord.trigger
    )
  }

  private func openedHistoryRecord(
    recordID: UUID,
    session: RunHistoryReadSession
  ) throws -> WorkflowResultRecord? {
    let correctionProjection =
      session.contentAccess == .full
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

  /// Advances one replayable clear transition and deletes only older-generation
  /// rows in the same transaction. A schema-4 bridge first promotes rows whose
  /// timestamps prove that they were written after the legacy intent.
  private func deleteRunHistoryRows(
    obsoletedBy transition: RunHistoryClearTransition,
    from tableName: String,
    preservingLegacyRowsAfter legacyUpperBound: Date?
  ) throws -> Int {
    let allowedTableNames = Set([
      "history_records",
      "workflow_run_receipts",
      "diagnostic_events",
    ])
    guard allowedTableNames.contains(tableName) else {
      throw SQLitePersistenceError.executingSQL("Unsupported run-history generation table.")
    }
    try execute("BEGIN IMMEDIATE TRANSACTION;")
    do {
      try validateAndAdvanceRunHistoryGeneration(transition)
      if let legacyUpperBound {
        let statement = try prepare(
          """
          UPDATE \(tableName)
          SET write_generation = ?
          WHERE write_generation < ? AND timestamp > ?;
          """
        )
        defer { sqlite3_finalize(statement) }
        try bind(
          [
            .int(transition.nextGeneration.value),
            .int(transition.nextGeneration.value),
            .double(legacyUpperBound.timeIntervalSince1970),
          ],
          to: statement
        )
        try step(statement, expecting: SQLITE_DONE)
      }
      let statement = try prepare(
        "DELETE FROM \(tableName) WHERE write_generation < ?;"
      )
      defer { sqlite3_finalize(statement) }
      try bind([.int(transition.nextGeneration.value)], to: statement)
      try step(statement, expecting: SQLITE_DONE)
      let removedCount = Int(sqlite3_changes(db))
      try execute("COMMIT;")
      return removedCount
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  private struct StoredClipboardMetadata {
    let revision: Int64
    let protectedMetadata: Data
  }

  private struct StoredClipboardBlobCoordinate: Hashable {
    let blobID: UUID
    let itemID: UUID
    let byteCount: Int

    init(blobID: UUID, itemID: UUID, byteCount: Int) {
      self.blobID = blobID
      self.itemID = itemID
      self.byteCount = byteCount
    }

    init(_ reference: LegacyRecordGraphBlobReference) {
      self.init(
        blobID: reference.blobID,
        itemID: reference.itemID,
        byteCount: reference.byteCount
      )
    }
  }


  private func storedClipboardMetadata() throws -> StoredClipboardMetadata? {
    let statement = try prepare(
      "SELECT revision, payload FROM clipboard_metadata WHERE id = 1;"
    )
    defer { sqlite3_finalize(statement) }
    switch sqlite3_step(statement) {
    case SQLITE_DONE:
      return nil
    case SQLITE_ROW:
      let revision = sqlite3_column_int64(statement, 0)
      guard revision >= 1,
        let protectedMetadata = try dataColumn(
          in: statement,
          index: 1,
          maximumByteCount: Self.maximumProtectedClipboardMetadataByteCount
        ),
        sqlite3_step(statement) == SQLITE_DONE
      else {
        throw SQLitePersistenceError.clipboardPersistenceUnavailable
      }
      return StoredClipboardMetadata(
        revision: revision,
        protectedMetadata: protectedMetadata
      )
    default:
      throw SQLitePersistenceError.clipboardPersistenceUnavailable
    }
  }

  private func storedClipboardRevision() throws -> Int64? {
    let statement = try prepare("SELECT revision FROM clipboard_metadata WHERE id = 1;")
    defer { sqlite3_finalize(statement) }
    switch sqlite3_step(statement) {
    case SQLITE_DONE:
      return nil
    case SQLITE_ROW:
      let revision = sqlite3_column_int64(statement, 0)
      guard revision >= 1, sqlite3_step(statement) == SQLITE_DONE else {
        throw SQLitePersistenceError.clipboardPersistenceUnavailable
      }
      return revision
    default:
      throw SQLitePersistenceError.clipboardPersistenceUnavailable
    }
  }

  private func storedLegacyClipboardEnvelope() throws -> String? {
    let statement = try prepare("SELECT value FROM app_settings WHERE key = ?;")
    defer { sqlite3_finalize(statement) }
    try bind([.text(AppSettingKey.legacyClipboardPersistedState.rawValue)], to: statement)
    switch sqlite3_step(statement) {
    case SQLITE_DONE:
      return nil
    case SQLITE_ROW:
      let byteCount = Int(sqlite3_column_bytes(statement, 0))
      guard byteCount > 0,
        byteCount <= Self.maximumProtectedClipboardMetadataByteCount,
        let envelope = textColumn(in: statement, index: 0),
        sqlite3_step(statement) == SQLITE_DONE
      else {
        throw SQLitePersistenceError.clipboardPersistenceUnavailable
      }
      return envelope
    default:
      throw SQLitePersistenceError.clipboardPersistenceUnavailable
    }
  }

  private func legacyClipboardRowExists() throws -> Bool {
    let statement = try prepare("SELECT 1 FROM app_settings WHERE key = ?;")
    defer { sqlite3_finalize(statement) }
    try bind([.text(AppSettingKey.legacyClipboardPersistedState.rawValue)], to: statement)
    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      guard sqlite3_step(statement) == SQLITE_DONE else {
        throw SQLitePersistenceError.clipboardPersistenceUnavailable
      }
      return true
    case SQLITE_DONE:
      return false
    default:
      throw SQLitePersistenceError.clipboardPersistenceUnavailable
    }
  }

  private func storedClipboardBlobCoordinates() throws -> [StoredClipboardBlobCoordinate] {
    try storedClipboardBlobCoordinates(
      maximumTotalPlaintextByteCount: Self.clipboardStorageLimits
        .maximumTotalEncodedItemByteCount
    )
  }

  private func storedClipboardBlobCoordinates(
    maximumTotalPlaintextByteCount: Int
  ) throws -> [StoredClipboardBlobCoordinate] {
    let statement = try prepare(
      """
      SELECT blob_id, item_id, plaintext_size
      FROM clipboard_image_blobs
      ORDER BY blob_id ASC;
      """
    )
    defer { sqlite3_finalize(statement) }
    var coordinates: [StoredClipboardBlobCoordinate] = []
    var itemIDs: Set<UUID> = []
    var totalByteCount = 0
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_DONE:
        return coordinates
      case SQLITE_ROW:
        guard coordinates.count < Self.maximumClipboardBlobCount,
          let blobText = textColumn(in: statement, index: 0),
          let blobID = UUID(uuidString: blobText),
          let itemText = textColumn(in: statement, index: 1),
          let itemID = UUID(uuidString: itemText),
          itemIDs.insert(itemID).inserted
        else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        let byteCount64 = sqlite3_column_int64(statement, 2)
        guard byteCount64 > 0,
          byteCount64 <= Int64(Self.clipboardStorageLimits.maximumImageByteCount)
        else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        let byteCount = Int(byteCount64)
        let (nextTotal, overflowed) = totalByteCount.addingReportingOverflow(byteCount)
        guard !overflowed,
          nextTotal <= Self.clipboardStorageLimits.maximumTotalEncodedItemByteCount,
          nextTotal <= maximumTotalPlaintextByteCount
        else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        totalByteCount = nextTotal
        coordinates.append(
          StoredClipboardBlobCoordinate(
            blobID: blobID,
            itemID: itemID,
            byteCount: byteCount
          )
        )
      default:
        throw SQLitePersistenceError.clipboardPersistenceUnavailable
      }
    }
  }

  private func storedClipboardImageBlobs(
    maximumTotalPlaintextByteCount: Int
  ) throws -> [LegacyRecordGraphImageBlob] {
    // Validate the complete declared graph before copying or opening any blob
    // payload. This keeps a corrupt snapshot from exceeding the repository's
    // metadata-plus-image plaintext budget during materialization.
    _ = try storedClipboardBlobCoordinates(
      maximumTotalPlaintextByteCount: maximumTotalPlaintextByteCount
    )
    let statement = try prepare(
      """
      SELECT blob_id, item_id, payload, plaintext_size
      FROM clipboard_image_blobs
      ORDER BY blob_id ASC;
      """
    )
    defer { sqlite3_finalize(statement) }
    var blobs: [LegacyRecordGraphImageBlob] = []
    var itemIDs: Set<UUID> = []
    var totalByteCount = 0
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_DONE:
        return blobs
      case SQLITE_ROW:
        guard blobs.count < Self.maximumClipboardBlobCount,
          let blobText = textColumn(in: statement, index: 0),
          let blobID = UUID(uuidString: blobText),
          let itemText = textColumn(in: statement, index: 1),
          let itemID = UUID(uuidString: itemText),
          itemIDs.insert(itemID).inserted
        else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        let byteCount64 = sqlite3_column_int64(statement, 3)
        guard byteCount64 > 0,
          byteCount64 <= Int64(Self.clipboardStorageLimits.maximumImageByteCount),
          let protectedPayload = try dataColumn(
            in: statement,
            index: 2,
            maximumByteCount: Self.maximumProtectedClipboardImageByteCount
          )
        else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        let reference = LegacyRecordGraphBlobReference(
          blobID: blobID,
          itemID: itemID,
          byteCount: Int(byteCount64)
        )
        let payload = try localDataProtector.openBinary(
          protectedPayload,
          context: Self.clipboardBlobProtectionContext(reference: reference)
        )
        guard payload.count == reference.byteCount else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        let (nextTotal, overflowed) = totalByteCount.addingReportingOverflow(payload.count)
        guard !overflowed,
          nextTotal <= Self.clipboardStorageLimits.maximumTotalEncodedItemByteCount,
          nextTotal <= maximumTotalPlaintextByteCount
        else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        totalByteCount = nextTotal
        blobs.append(LegacyRecordGraphImageBlob(reference: reference, payload: payload))
      default:
        throw SQLitePersistenceError.clipboardPersistenceUnavailable
      }
    }
  }

  private func upsertClipboardMetadata(
    protectedMetadata: Data,
    revision: Int64
  ) throws {
    let statement = try prepare(
      """
      INSERT INTO clipboard_metadata (id, revision, payload)
      VALUES (1, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
          revision = excluded.revision,
          payload = excluded.payload;
      """
    )
    defer { sqlite3_finalize(statement) }
    try bind([.int(revision), .blob(protectedMetadata)], to: statement)
    try step(statement, expecting: SQLITE_DONE)
  }

  private func deleteClipboardBlob(blobID: UUID) throws {
    let statement = try prepare("DELETE FROM clipboard_image_blobs WHERE blob_id = ?;")
    defer { sqlite3_finalize(statement) }
    try bind([.text(blobID.uuidString)], to: statement)
    try step(statement, expecting: SQLITE_DONE)
  }

  private func deleteLegacyClipboardRow() throws {
    let statement = try prepare("DELETE FROM app_settings WHERE key = ?;")
    defer { sqlite3_finalize(statement) }
    try bind([.text(AppSettingKey.legacyClipboardPersistedState.rawValue)], to: statement)
    try step(statement, expecting: SQLITE_DONE)
  }

  private struct StoredRecordGraphMetadata {
    let revision: Int64
    let protectedGraph: Data
  }

  private struct StoredRecordPayloadBlobCoordinate: Hashable {
    let blobID: UUID
    let recordID: RecordID
    let kind: RecordPayloadKind
    let byteCount: Int

    init(
      blobID: UUID,
      recordID: RecordID,
      kind: RecordPayloadKind,
      byteCount: Int
    ) {
      self.blobID = blobID
      self.recordID = recordID
      self.kind = kind
      self.byteCount = byteCount
    }

    init(_ reference: RecordGraphPersistenceBlobReference) {
      self.init(
        blobID: reference.blobID,
        recordID: reference.recordID,
        kind: reference.kind,
        byteCount: reference.byteCount
      )
    }
  }

  private struct PreparedRecordPayloadBlob {
    let reference: RecordGraphPersistenceBlobReference
    let protectedPayload: Data
  }

  private struct PreparedRecordGraphWrite {
    let protectedGraph: Data
    let newBlobs: [PreparedRecordPayloadBlob]
    let expectedCoordinates: Set<StoredRecordPayloadBlobCoordinate>

    var expectedBlobIDs: Set<UUID> {
      Set(expectedCoordinates.map(\.blobID))
    }
  }

  private func prepareRecordGraphWrite(
    _ snapshot: RecordGraphPersistenceWriteSnapshot
  ) throws -> PreparedRecordGraphWrite {
    guard snapshot.expectedRevision.map({ $0 >= 1 }) ?? true,
      !snapshot.graph.isEmpty,
      snapshot.graph.count <= Self.clipboardStorageLimits.maximumPersistedStateUTF8ByteCount
    else {
      throw SQLitePersistenceError.clipboardPersistenceInvalidWriteSnapshot
    }
    let allReferences = snapshot.newPayloadBlobs.map(\.reference)
      + snapshot.retainedPayloadBlobReferences
    guard allReferences.count <= Self.maximumClipboardBlobCount else {
      throw SQLitePersistenceError.clipboardPersistenceInvalidWriteSnapshot
    }
    var blobIDs: Set<UUID> = []
    var recordIDs: Set<RecordID> = []
    var totalByteCount = 0
    for reference in allReferences {
      guard reference.byteCount > 0,
        reference.byteCount <= maximumRecordPayloadByteCount(for: reference.kind),
        blobIDs.insert(reference.blobID).inserted,
        recordIDs.insert(reference.recordID).inserted
      else {
        throw SQLitePersistenceError.clipboardPersistenceInvalidWriteSnapshot
      }
      let (nextTotal, overflowed) = totalByteCount.addingReportingOverflow(reference.byteCount)
      guard !overflowed,
        nextTotal <= Self.clipboardStorageLimits.maximumTotalEncodedItemByteCount
      else {
        throw SQLitePersistenceError.clipboardPersistenceInvalidWriteSnapshot
      }
      totalByteCount = nextTotal
    }
    let (totalStoredPlaintext, overflowed) = snapshot.graph.count.addingReportingOverflow(
      totalByteCount
    )
    guard !overflowed,
      totalStoredPlaintext <= Self.clipboardStorageLimits.maximumPersistedStateUTF8ByteCount,
      snapshot.newPayloadBlobs.allSatisfy({ $0.payload.count == $0.reference.byteCount })
    else {
      throw SQLitePersistenceError.clipboardPersistenceInvalidWriteSnapshot
    }

    let protectedGraph = try localDataProtector.sealBinary(
      snapshot.graph,
      context: Self.recordGraphProtectionContext
    )
    guard !protectedGraph.isEmpty,
      protectedGraph.count <= Self.maximumProtectedClipboardMetadataByteCount
    else {
      throw SQLitePersistenceError.clipboardPersistenceUnavailable
    }
    let newBlobs = try snapshot.newPayloadBlobs.map { blob in
      let protectedPayload = try localDataProtector.sealBinary(
        blob.payload,
        context: Self.recordPayloadProtectionContext(reference: blob.reference)
      )
      guard !protectedPayload.isEmpty,
        protectedPayload.count <= Self.clipboardStorageLimits.maximumTotalEncodedItemByteCount * 2
      else {
        throw SQLitePersistenceError.clipboardPersistenceUnavailable
      }
      return PreparedRecordPayloadBlob(
        reference: blob.reference,
        protectedPayload: protectedPayload
      )
    }
    return PreparedRecordGraphWrite(
      protectedGraph: protectedGraph,
      newBlobs: newBlobs,
      expectedCoordinates: Set(allReferences.map(StoredRecordPayloadBlobCoordinate.init))
    )
  }

  private func storedRecordGraphMetadata() throws -> StoredRecordGraphMetadata? {
    let statement = try prepare(
      "SELECT revision, payload FROM record_graph_metadata WHERE id = 1;"
    )
    defer { sqlite3_finalize(statement) }
    switch sqlite3_step(statement) {
    case SQLITE_DONE:
      return nil
    case SQLITE_ROW:
      let revision = sqlite3_column_int64(statement, 0)
      guard revision >= 1,
        let protectedGraph = try dataColumn(
          in: statement,
          index: 1,
          maximumByteCount: Self.maximumProtectedClipboardMetadataByteCount
        ),
        sqlite3_step(statement) == SQLITE_DONE
      else {
        throw SQLitePersistenceError.clipboardPersistenceUnavailable
      }
      return StoredRecordGraphMetadata(revision: revision, protectedGraph: protectedGraph)
    default:
      throw SQLitePersistenceError.clipboardPersistenceUnavailable
    }
  }

  private func storedRecordGraphRevision() throws -> Int64? {
    let statement = try prepare("SELECT revision FROM record_graph_metadata WHERE id = 1;")
    defer { sqlite3_finalize(statement) }
    switch sqlite3_step(statement) {
    case SQLITE_DONE:
      return nil
    case SQLITE_ROW:
      let revision = sqlite3_column_int64(statement, 0)
      guard revision >= 1, sqlite3_step(statement) == SQLITE_DONE else {
        throw SQLitePersistenceError.clipboardPersistenceUnavailable
      }
      return revision
    default:
      throw SQLitePersistenceError.clipboardPersistenceUnavailable
    }
  }

  private func storedRecordPayloadBlobCoordinates(
    maximumTotalPlaintextByteCount: Int? = nil
  ) throws -> [StoredRecordPayloadBlobCoordinate] {
    let maximumTotal = maximumTotalPlaintextByteCount
      ?? Self.clipboardStorageLimits.maximumTotalEncodedItemByteCount
    let statement = try prepare(
      """
      SELECT blob_id, record_id, payload_kind, plaintext_size
      FROM record_payload_blobs
      ORDER BY blob_id ASC;
      """
    )
    defer { sqlite3_finalize(statement) }
    var coordinates: [StoredRecordPayloadBlobCoordinate] = []
    var recordIDs: Set<RecordID> = []
    var totalByteCount = 0
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_DONE:
        return coordinates
      case SQLITE_ROW:
        guard coordinates.count < Self.maximumClipboardBlobCount,
          let blobText = textColumn(in: statement, index: 0),
          let blobID = UUID(uuidString: blobText),
          let recordText = textColumn(in: statement, index: 1),
          let rawRecordID = UUID(uuidString: recordText),
          let kindText = textColumn(in: statement, index: 2),
          let kind = RecordPayloadKind(rawValue: kindText)
        else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        let recordID = RecordID(rawRecordID)
        guard recordIDs.insert(recordID).inserted else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        let byteCount64 = sqlite3_column_int64(statement, 3)
        guard byteCount64 > 0,
          byteCount64 <= Int64(maximumRecordPayloadByteCount(for: kind))
        else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        let byteCount = Int(byteCount64)
        let (nextTotal, overflowed) = totalByteCount.addingReportingOverflow(byteCount)
        guard !overflowed,
          nextTotal <= Self.clipboardStorageLimits.maximumTotalEncodedItemByteCount,
          nextTotal <= maximumTotal
        else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        totalByteCount = nextTotal
        coordinates.append(
          StoredRecordPayloadBlobCoordinate(
            blobID: blobID,
            recordID: recordID,
            kind: kind,
            byteCount: byteCount
          )
        )
      default:
        throw SQLitePersistenceError.clipboardPersistenceUnavailable
      }
    }
  }

  private func storedRecordPayloadBlobs(
    maximumTotalPlaintextByteCount: Int
  ) throws -> [RecordGraphPersistenceBlob] {
    _ = try storedRecordPayloadBlobCoordinates(
      maximumTotalPlaintextByteCount: maximumTotalPlaintextByteCount
    )
    let statement = try prepare(
      """
      SELECT blob_id, record_id, payload_kind, payload, plaintext_size
      FROM record_payload_blobs
      ORDER BY blob_id ASC;
      """
    )
    defer { sqlite3_finalize(statement) }
    var blobs: [RecordGraphPersistenceBlob] = []
    var totalByteCount = 0
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_DONE:
        return blobs
      case SQLITE_ROW:
        guard blobs.count < Self.maximumClipboardBlobCount,
          let blobText = textColumn(in: statement, index: 0),
          let blobID = UUID(uuidString: blobText),
          let recordText = textColumn(in: statement, index: 1),
          let rawRecordID = UUID(uuidString: recordText),
          let kindText = textColumn(in: statement, index: 2),
          let kind = RecordPayloadKind(rawValue: kindText)
        else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        let byteCount64 = sqlite3_column_int64(statement, 4)
        guard byteCount64 > 0,
          byteCount64 <= Int64(maximumRecordPayloadByteCount(for: kind)),
          let protectedPayload = try dataColumn(
            in: statement,
            index: 3,
            maximumByteCount: Self.clipboardStorageLimits.maximumTotalEncodedItemByteCount * 2
          )
        else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        let reference = RecordGraphPersistenceBlobReference(
          blobID: blobID,
          recordID: RecordID(rawRecordID),
          kind: kind,
          byteCount: Int(byteCount64)
        )
        let payload = try localDataProtector.openBinary(
          protectedPayload,
          context: Self.recordPayloadProtectionContext(reference: reference)
        )
        guard payload.count == reference.byteCount else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        let (nextTotal, overflowed) = totalByteCount.addingReportingOverflow(payload.count)
        guard !overflowed,
          nextTotal <= Self.clipboardStorageLimits.maximumTotalEncodedItemByteCount,
          nextTotal <= maximumTotalPlaintextByteCount
        else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        totalByteCount = nextTotal
        blobs.append(RecordGraphPersistenceBlob(reference: reference, payload: payload))
      default:
        throw SQLitePersistenceError.clipboardPersistenceUnavailable
      }
    }
  }

  private func upsertRecordGraphMetadata(
    protectedGraph: Data,
    revision: Int64
  ) throws {
    let statement = try prepare(
      """
      INSERT INTO record_graph_metadata (id, revision, payload)
      VALUES (1, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
          revision = excluded.revision,
          payload = excluded.payload;
      """
    )
    defer { sqlite3_finalize(statement) }
    try bind([.int(revision), .blob(protectedGraph)], to: statement)
    try step(statement, expecting: SQLITE_DONE)
  }

  private func insertRecordPayloadBlob(_ blob: PreparedRecordPayloadBlob) throws {
    let statement = try prepare(
      """
      INSERT INTO record_payload_blobs (
          blob_id, record_id, payload_kind, payload, plaintext_size, state_id
      ) VALUES (?, ?, ?, ?, ?, 1);
      """
    )
    defer { sqlite3_finalize(statement) }
    try bind(
      [
        .text(blob.reference.blobID.uuidString),
        .text(blob.reference.recordID.rawValue.uuidString),
        .text(blob.reference.kind.rawValue),
        .blob(blob.protectedPayload),
        .int(Int64(blob.reference.byteCount)),
      ],
      to: statement
    )
    do {
      try step(statement, expecting: SQLITE_DONE)
    } catch {
      throw SQLitePersistenceError.clipboardPersistenceBlobConflict
    }
  }

  private func deleteRecordPayloadBlob(blobID: UUID) throws {
    let statement = try prepare("DELETE FROM record_payload_blobs WHERE blob_id = ?;")
    defer { sqlite3_finalize(statement) }
    try bind([.text(blobID.uuidString)], to: statement)
    try step(statement, expecting: SQLITE_DONE)
  }

  private func maximumRecordPayloadByteCount(for kind: RecordPayloadKind) -> Int {
    switch kind {
    case .text:
      Self.clipboardStorageLimits.maximumTextUTF8ByteCount
    case .image:
      Self.clipboardStorageLimits.maximumImageByteCount
    case .files:
      Self.clipboardStorageLimits.maximumTotalFileURLUTF8ByteCount
    }
  }

  private func markDataProtectionCleanupPending() throws {
    let statement = try prepare(
      "UPDATE local_data_protection SET cleanup_pending = 1 WHERE id = 1;"
    )
    defer { sqlite3_finalize(statement) }
    try step(statement, expecting: SQLITE_DONE)
    guard sqlite3_changes(db) == 1 else {
      throw SQLitePersistenceError.clipboardPersistenceUnavailable
    }
  }

  private func withDeferredTransaction<T>(_ operation: () throws -> T) throws -> T {
    try execute("BEGIN TRANSACTION;")
    do {
      let result = try operation()
      try execute("COMMIT;")
      return result
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  private func withImmediateTransaction<T>(_ operation: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE TRANSACTION;")
    do {
      let result = try operation()
      try execute("COMMIT;")
      return result
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  private func currentRunHistoryWriteGeneration() throws -> RunHistoryWriteGeneration {
    let statement = try prepare(
      "SELECT current_generation FROM run_history_generation WHERE id = 1;"
    )
    defer { sqlite3_finalize(statement) }
    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      let rawGeneration = sqlite3_column_int64(statement, 0)
      guard sqlite3_step(statement) == SQLITE_DONE else {
        throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
      }
      do {
        return try RunHistoryWriteGeneration(rawGeneration)
      } catch {
        throw SQLitePersistenceError.decodingRow("Run-history generation is invalid.")
      }
    case SQLITE_DONE:
      throw SQLitePersistenceError.decodingRow("Run-history generation is unavailable.")
    default:
      throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
    }
  }

  private func currentRunHistoryWriteOrdinal() throws -> Int64 {
    let statement = try prepare(
      "SELECT last_ordinal FROM run_history_write_sequence WHERE id = 1;"
    )
    defer { sqlite3_finalize(statement) }
    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      let ordinal = sqlite3_column_int64(statement, 0)
      guard ordinal >= 0, sqlite3_step(statement) == SQLITE_DONE else {
        throw SQLitePersistenceError.decodingRow(
          "Run-history write sequence is invalid."
        )
      }
      return ordinal
    case SQLITE_DONE:
      throw SQLitePersistenceError.decodingRow(
        "Run-history write sequence is unavailable."
      )
    default:
      throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
    }
  }

  /// Called only from an immediate transaction, so the read/increment pair is
  /// one shared monotonic coordinate across records and receipts.
  private func nextRunHistoryWriteOrdinal() throws -> Int64 {
    let current = try currentRunHistoryWriteOrdinal()
    guard current < Int64.max else {
      throw RunHistoryBrowsingError.writeOrdinalExhausted
    }
    let next = current + 1
    let statement = try prepare(
      """
      UPDATE run_history_write_sequence
      SET last_ordinal = ?
      WHERE id = 1 AND last_ordinal = ?;
      """
    )
    defer { sqlite3_finalize(statement) }
    try bind([.int(next), .int(current)], to: statement)
    try step(statement, expecting: SQLITE_DONE)
    guard sqlite3_changes(db) == 1 else {
      throw SQLitePersistenceError.steppingStatement(
        "Run-history write sequence changed concurrently."
      )
    }
    return next
  }

  private static func hasNonemptyBody(_ value: String?) -> Bool {
    guard let value else { return false }
    return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func generationIsCurrent(_ generation: RunHistoryWriteGeneration) throws -> Bool {
    try currentRunHistoryWriteGeneration() == generation
  }

  private func validateAndAdvanceRunHistoryGeneration(
    _ transition: RunHistoryClearTransition
  ) throws {
    let statement = try prepare(
      """
      SELECT current_generation, last_clear_intent_id
      FROM run_history_generation
      WHERE id = 1;
      """
    )
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw SQLitePersistenceError.decodingRow("Run-history generation is unavailable.")
    }
    let current = sqlite3_column_int64(statement, 0)
    let lastIntentID = textColumn(in: statement, index: 1).flatMap(UUID.init(uuidString:))
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
    }

    if current == transition.nextGeneration.value,
      lastIntentID == transition.intentID
    {
      return
    }
    guard current == transition.previousGeneration.value else {
      throw RunHistoryGenerationError.clearTransitionConflict
    }

    let update = try prepare(
      """
      UPDATE run_history_generation
      SET current_generation = ?, last_clear_intent_id = ?
      WHERE id = 1 AND current_generation = ?;
      """
    )
    defer { sqlite3_finalize(update) }
    try bind(
      [
        .int(transition.nextGeneration.value),
        .text(transition.intentID.uuidString),
        .int(transition.previousGeneration.value),
      ],
      to: update
    )
    try step(update, expecting: SQLITE_DONE)
    guard sqlite3_changes(db) == 1 else {
      throw RunHistoryGenerationError.clearTransitionConflict
    }
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

    guard let protectedValue = textColumn(in: statement, index: 0) else {
      throw SQLitePersistenceError.decodingRow("A setting row was missing its value.")
    }
    return try openString(
      protectedValue,
      context: settingsProtectionContext(keyRawValue: key.rawValue)
    )
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
        let protectedValue = textColumn(in: statement, index: 1)
      else {
        continue
      }

      values[key] = try openString(
        protectedValue,
        context: settingsProtectionContext(keyRawValue: key.rawValue)
      )
    }

    return values
  }

  public func settingsSnapshot(
    forKeys keys: [AppSettingKey]
  ) async throws -> SettingsStoreReadSnapshot {
    let uniqueKeys = Array(Set(keys)).sorted { $0.rawValue < $1.rawValue }
    guard !uniqueKeys.isEmpty else { return .empty }

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
    var unavailableKeys: Set<AppSettingKey> = []
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
        let key = AppSettingKey(rawValue: keyText)
      else {
        continue
      }
      guard let protectedValue = textColumn(in: statement, index: 1) else {
        unavailableKeys.insert(key)
        continue
      }

      do {
        values[key] = try openString(
          protectedValue,
          context: settingsProtectionContext(keyRawValue: key.rawValue)
        )
      } catch {
        unavailableKeys.insert(key)
      }
    }

    return SettingsStoreReadSnapshot(
      values: values,
      unavailableKeys: unavailableKeys
    )
  }

  public func setString(_ value: String, forKey key: AppSettingKey) async throws {
    try upsertString(value, forKey: key, updatedAt: Date().timeIntervalSince1970)
  }

  public func setStringsAtomically(_ values: [AppSettingKey: String]) async throws {
    guard !values.isEmpty else { return }
    try execute("BEGIN IMMEDIATE TRANSACTION;")
    do {
      let updatedAt = Date().timeIntervalSince1970
      for key in values.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
        guard let value = values[key] else { continue }
        try upsertString(value, forKey: key, updatedAt: updatedAt)
      }
      try execute("COMMIT;")
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  private func upsertString(
    _ value: String,
    forKey key: AppSettingKey,
    updatedAt: TimeInterval
  ) throws {
    let protectedValue = try protectString(
      value,
      context: settingsProtectionContext(keyRawValue: key.rawValue)
    )
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
        .text(protectedValue),
        .double(updatedAt),
      ],
      to: statement
    )

    try step(statement, expecting: SQLITE_DONE)
  }

  public func removeValue(forKey key: AppSettingKey) async throws {
    do {
      let statement = try prepare("DELETE FROM app_settings WHERE key = ?;")
      defer { sqlite3_finalize(statement) }
      try bind([.text(key.rawValue)], to: statement)
      try step(statement, expecting: SQLITE_DONE)
    }

    if key == .openAIAPIKey || key == .legacyWhisperKitModelToken
    {
      // Legacy credentials may still exist in an older WAL frame. Apply the
      // secure deletion to the main database, then truncate those frames.
      try truncateWriteAheadLog()
    }
  }

  public func purgeSensitiveStorageResidue() async throws {
    try ensureSecureDeleteEnabled()
    try truncateWriteAheadLog()
    try execute("VACUUM;")
    try truncateWriteAheadLog()
  }

  public func save(_ export: ExportMetadata) async throws {
    let recordID = export.id.uuidString
    let protectedDestinationPath = try protectString(
      export.destinationPath,
      context: exportProtectionContext(recordID: recordID, field: "destination_path")
    )
    let metadataJSON: String
    do {
      let encoded = String(decoding: try encoder.encode(export.metadata), as: UTF8.self)
      metadataJSON = try protectString(
        encoded,
        context: exportProtectionContext(recordID: recordID, field: "metadata_json")
      )
    } catch let error as SQLitePersistenceError {
      throw error
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
        .text(recordID),
        .text(export.kind.rawValue),
        .text(protectedDestinationPath),
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

  private static func preexistingStorageMayContainResidue(
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

  private static let currentSchemaVersion = 12
  private static let writerBarrierTableNames = [
    "app_settings",
    "clipboard_image_blobs",
    "clipboard_metadata",
    "diagnostic_events",
    "export_metadata",
    "history_records",
    "local_data_protection",
    "record_graph_metadata",
    "record_payload_blobs",
    "run_history_generation",
    "run_history_write_sequence",
    SQLiteAuthenticatedSchemaFloor.tableName,
    "workflow_run_receipts",
  ]
  private static let inconsistentDataProtectionMetadataMessage =
    "Local data protection metadata is inconsistent with the schema version."
  private static let keyVerificationPlaintext = Data("Rill local data key verification v1".utf8)

  private static func migrate(
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

  private static func migrateWithinTransaction(
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
            $0 != "record_graph_metadata" && $0 != "record_payload_blobs"
          }
        )
        try migrateToV12(on: handle, localDataProtector: localDataProtector)
        try requireQuickCheck(on: handle)
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

    guard storedVersion < SQLiteAuthenticatedSchemaFloor.installedSchemaFloor else {
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

  private static func migrateToV2(on handle: OpaquePointer?) throws {
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

  private static func migrateToV3(on handle: OpaquePointer?) throws {
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

  private static func historyRecordsHasColumn(
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

  private static func tableExists(
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

  private static func tableHasColumn(
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

  private static func ensureCleanupPendingColumn(
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

  private struct UnprotectedHistoryRow {
    var id: String
    var workflowFallbackName: String
    var finalText: String?
    var correctionSourceJSON: String?
  }

  private struct UnprotectedSettingRow {
    var key: String
    var value: String
  }

  private struct UnprotectedExportRow {
    var id: String
    var destinationPath: String
    var metadataJSON: String
  }

  private struct LegacyDiagnosticRow {
    var id: Int64
    var eventCode: String
  }

  /// A database whose protection marker survived while `user_version` moved
  /// backwards is recoverable only when it has exactly the schema that v4
  /// owned. This deliberately excludes later tables and columns so changing the
  /// version of a newer database cannot be used to bypass downgrade detection.
  private static let exactV4SchemaFingerprint: [String: String] = [
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

  private static let canonicalTextEnvelopePrefix =
    "\(AESGCMDataProtector.envelopePrefix):\(AESGCMDataProtector.envelopeVersion):"

  private static func recoverDowngradedV4Database(
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

  private static func hasExactV4SchemaFingerprint(
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

  private static func compactSchemaSQL(_ sql: String) -> String {
    String(sql.lowercased().filter { !$0.isWhitespace })
  }

  private static func validateExactV4ProtectionMarker(
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

  private static func recoveredProtectedText(
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

  private static func recoverProtectedHistoryRow(
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

  private static func updateRecoveredHistoryRow(
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

  private static func recoverProtectedSettingRow(
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

  private static func recoverProtectedExportRow(
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

  private static func markDataProtectionCleanupPending(
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

  private static func migrateToV4(
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

  private static func migrateToV5(on handle: OpaquePointer?) throws {
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

  private static func migrateToV6(on handle: OpaquePointer?) throws {
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

  private static func migrateToV7(on handle: OpaquePointer?) throws {
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

  private static func migrateToV8(on handle: OpaquePointer?) throws {
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

  private struct LegacyRunHistoryOrdinalRow {
    let tableName: String
    let identifier: String
  }

  private static func migrateToV9(
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

  private static func migrateToV10(on handle: OpaquePointer?) throws {
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

  private static func migrateToV11(
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
          $0 != "record_graph_metadata" && $0 != "record_payload_blobs"
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

  private static func migrateToV12(
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
        tableNames: writerBarrierTableNames
      )
      try SQLiteAuthenticatedSchemaFloor.upgrade(
        on: handle,
        validatedDatabaseID: databaseID,
        localDataProtector: localDataProtector
      )
      try setSchemaVersion(12, on: handle)
      try validateAuthenticatedStorageBoundary(
        on: handle,
        localDataProtector: localDataProtector
      )
    } catch {
      throw SQLitePersistenceError.migrationFailed(
        "Record graph storage and authenticated schema 12 could not be installed."
      )
    }
  }

  private static func recoverAuthenticatedSchemaFloor(
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

  private static func validateLegacyV11StorageBoundary(
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
        $0 != "record_graph_metadata" && $0 != "record_payload_blobs"
      }
    )
  }

  private static func validateAuthenticatedStorageBoundary(
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
        tableNames: writerBarrierTableNames
      )
    } catch {
      throw SQLitePersistenceError.migrationFailed(
        "The database writer barrier is unavailable."
      )
    }
  }

  private static func authenticatedSchemaFloor(
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

  private static func requireQuickCheck(on handle: OpaquePointer?) throws {
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

  private static func legacyRunHistoryRowsForOrdinalBackfill(
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

  private static func backfillRunHistoryWriteOrdinals(on handle: OpaquePointer?) throws {
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

  private static func backfillNonemptyHistoryBodyMetadata(
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

  private static func validateDataProtectionKey(
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

  private static func unprotectedHistoryRows(
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

  private static func unprotectedSettingRows(
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

  private static func unprotectedExportRows(
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

  private static func sanitizeExistingDiagnostics(
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

  private static func legacyDiagnosticRows(
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

  private static func protectHistoryRow(
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

  private static func protectSettingRow(
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

  private static func protectExportRow(
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

  private static func upsertKeyVerificationEnvelope(
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

  private static func bindMigrationValues(
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

  private static var keyVerificationContext: LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: "local_data_protection",
      recordID: "1",
      field: "key_verification"
    )
  }

  private static func historyProtectionContext(
    recordID: String,
    field: String
  ) -> LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: "history_records",
      recordID: recordID,
      field: field
    )
  }

  private static func runReceiptProtectionContext(
    runID: String
  ) -> LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: "workflow_run_receipts",
      recordID: runID,
      field: "payload"
    )
  }

  private static func settingsProtectionContext(
    keyRawValue: String
  ) -> LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: "app_settings",
      recordID: keyRawValue,
      field: "value"
    )
  }

  private static func exportProtectionContext(
    recordID: String,
    field: String
  ) -> LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: "export_metadata",
      recordID: recordID,
      field: field
    )
  }

  private static var clipboardMetadataProtectionContext: LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: "clipboard_metadata",
      recordID: "1",
      field: "payload"
    )
  }

  private static func clipboardBlobProtectionContext(
    reference: LegacyRecordGraphBlobReference
  ) -> LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: "clipboard_image_blobs",
      recordID: reference.blobID.uuidString,
      field: "item:\(reference.itemID.uuidString):payload"
    )
  }

  private static var recordGraphProtectionContext: LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: "record_graph_metadata",
      recordID: "1",
      field: "payload"
    )
  }

  private static func recordPayloadProtectionContext(
    reference: RecordGraphPersistenceBlobReference
  ) -> LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: "record_payload_blobs",
      recordID: reference.blobID.uuidString,
      field: "record:\(reference.recordID.rawValue.uuidString):\(reference.kind.rawValue):payload"
    )
  }

  private static func staticTextColumn(
    in statement: OpaquePointer?,
    index: Int32
  ) -> String? {
    guard let cString = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: cString)
  }

  private func execute(_ sql: String) throws {
    try Self.execute(sql, on: db)
  }

  private func ensureSecureDeleteEnabled() throws {
    try Self.ensureSecureDeleteEnabled(on: db)
  }

  private func truncateWriteAheadLog() throws {
    try Self.truncateWriteAheadLog(on: db)
  }

  private static func ensureSecureDeleteEnabled(on handle: OpaquePointer?) throws {
    try execute("PRAGMA secure_delete = ON;", on: handle)
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        "PRAGMA secure_delete;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.executingSQL(
        "Failed to verify that secure_delete is enabled."
      )
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw SQLitePersistenceError.executingSQL(
        "Failed to verify that secure_delete is enabled."
      )
    }
    guard sqlite3_column_int(statement, 0) == 1 else {
      throw SQLitePersistenceError.executingSQL(
        "SQLite did not enable secure_delete before purging sensitive storage."
      )
    }
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw SQLitePersistenceError.executingSQL(
        "Failed to finish verifying secure_delete."
      )
    }
  }

  private static func markDataProtectionCleanupCompleted(
    on handle: OpaquePointer?
  ) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        "UPDATE local_data_protection SET cleanup_pending = 0 WHERE id = 1;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.executingSQL(
        "Local data protection cleanup state could not be completed."
      )
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_DONE,
      sqlite3_changes(handle) == 1
    else {
      throw SQLitePersistenceError.executingSQL(
        "Local data protection cleanup state could not be completed."
      )
    }
  }

  private static func truncateWriteAheadLog(on handle: OpaquePointer?) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        "PRAGMA wal_checkpoint(TRUNCATE);",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.executingSQL(
        "Failed to prepare a truncating WAL checkpoint."
      )
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw SQLitePersistenceError.executingSQL(
        "Failed to run a truncating WAL checkpoint: \(lastErrorMessage(from: handle))"
      )
    }
    guard sqlite3_column_int(statement, 0) == 0 else {
      throw SQLitePersistenceError.executingSQL(
        "The truncating WAL checkpoint could not complete because the database was busy."
      )
    }
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw SQLitePersistenceError.executingSQL(
        "Failed to finish a truncating WAL checkpoint."
      )
    }
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
      case .blob(let value):
        guard value.count <= Int(Int32.max) else {
          throw SQLitePersistenceError.bindingValue("A BLOB value was too large.")
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

  private func decodeHistoryRecord(from statement: OpaquePointer?) throws -> WorkflowResultRecord {
    guard
      let idText = textColumn(in: statement, index: 0),
      let id = UUID(uuidString: idText),
      let protectedFallbackName = textColumn(in: statement, index: 3),
      let outcomeText = textColumn(in: statement, index: 9),
      let outcome = HistoryOutcome(rawValue: outcomeText)
    else {
      throw SQLitePersistenceError.decodingRow("History row was missing required values.")
    }

    let runID = textColumn(in: statement, index: 1).flatMap(UUID.init(uuidString:))
    let workflowID = textColumn(in: statement, index: 2).flatMap(UUID.init(uuidString:))
    let titleKey = textColumn(in: statement, index: 4).flatMap(WorkflowTitleKey.init(rawValue:))
    let fallbackName = try openString(
      protectedFallbackName,
      context: historyProtectionContext(
        recordID: idText,
        field: "workflow_fallback_name"
      )
    )
    let finalText = try textColumn(in: statement, index: 5).map { protectedFinalText in
      try openString(
        protectedFinalText,
        context: historyProtectionContext(recordID: idText, field: "final_text")
      )
    }
    let failureMessage = HistoryFailureSanitizer.sanitize(textColumn(in: statement, index: 6))
    let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
    let isRecordRelated = sqlite3_column_int64(statement, 8) != 0
    let trigger: WorkflowRunTriggerKind?
    if let triggerText = textColumn(in: statement, index: 11) {
      guard let decodedTrigger = WorkflowRunTriggerKind(rawValue: triggerText) else {
        throw SQLitePersistenceError.decodingRow(
          "History row contained an invalid run trigger."
        )
      }
      trigger = decodedTrigger
    } else {
      trigger = nil
    }
    let correctionSource: RecognitionCorrectionSource?
    if let protectedCorrectionSourceJSON = textColumn(in: statement, index: 10) {
      do {
        let correctionSourceJSON = try openString(
          protectedCorrectionSourceJSON,
          context: historyProtectionContext(
            recordID: idText,
            field: "correction_source_json"
          )
        )
        correctionSource = try decoder.decode(
          RecognitionCorrectionSource.self,
          from: Data(correctionSourceJSON.utf8)
        )
      } catch let error as SQLitePersistenceError {
        throw error
      } catch {
        throw SQLitePersistenceError.decodingRow(error.localizedDescription)
      }
    } else {
      correctionSource = nil
    }

    return WorkflowResultRecord(
      id: id,
      runID: runID,
      workflowID: workflowID,
      workflow: WorkflowPresentation(fallbackName: fallbackName, titleKey: titleKey),
      finalText: finalText,
      failureMessage: failureMessage,
      timestamp: timestamp,
      isRecordRelated: isRecordRelated,
      outcome: outcome,
      correctionSource: correctionSource,
      trigger: trigger
    )
  }

  private func receipts(
    forExactRunIDs runIDs: Set<UUID>,
    matching query: WorkflowRunReceiptQuery,
    resultLimit: Int?,
    generation: RunHistoryWriteGeneration
  ) throws -> [WorkflowRunReceipt] {
    guard !runIDs.isEmpty else { return [] }
    let statement = try prepare(
      """
      SELECT run_id, timestamp, payload
      FROM workflow_run_receipts
      WHERE run_id = ? AND write_generation = ?;
      """
    )
    defer { sqlite3_finalize(statement) }

    var result: [WorkflowRunReceipt] = []
    var skippedCorruptRowCount = 0
    for runID in runIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard sqlite3_reset(statement) == SQLITE_OK,
        sqlite3_clear_bindings(statement) == SQLITE_OK
      else {
        throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
      }
      try bind(
        [.text(runID.uuidString), .int(generation.value)],
        to: statement
      )

      let stepResult = sqlite3_step(statement)
      if stepResult == SQLITE_DONE { continue }
      guard stepResult == SQLITE_ROW else {
        throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
      }

      let receipt: WorkflowRunReceipt?
      do {
        receipt = try decodeRunReceipt(from: statement)
      } catch {
        skippedCorruptRowCount += 1
        receipt = nil
      }
      guard sqlite3_step(statement) == SQLITE_DONE else {
        throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
      }

      guard let receipt else { continue }
      if let since = query.since, receipt.timestamp < since { continue }
      guard query.workflowID == nil || receipt.workflowID == query.workflowID,
        query.trigger == nil || receipt.trigger == query.trigger,
        query.outcome == nil || receipt.outcome == query.outcome
      else {
        continue
      }
      result.append(receipt)
    }

    result.sort {
      if $0.timestamp == $1.timestamp {
        return $0.runID.uuidString < $1.runID.uuidString
      }
      return $0.timestamp > $1.timestamp
    }
    if let resultLimit {
      result = Array(result.prefix(resultLimit))
    }
    Self.reportSkippedCorruptRunReceiptRows(skippedCorruptRowCount)
    return result
  }

  private static func reportSkippedCorruptRunReceiptRows(_ count: Int) {
    guard count > 0 else { return }
    // Receipt failures are reported only as an aggregate count. Never
    // include row coordinates, protected payloads, or decoder errors.
    logger.error(
      "Skipped \(count, privacy: .public) invalid workflow run receipt rows."
    )
  }

  private static func reportSkippedCorruptHistoryRows(_ count: Int) {
    guard count > 0 else { return }
    // History failures are reported only as an aggregate count. Never include
    // row coordinates, protected payloads, or decoder errors.
    logger.error(
      "Skipped \(count, privacy: .public) invalid history rows."
    )
  }

  private static func reportSkippedCorruptDiagnosticRows(_ count: Int) {
    guard count > 0 else { return }
    // Diagnostic failures are reported only as an aggregate count. Never
    // include row coordinates, stored values, or decoder errors.
    logger.error(
      "Skipped \(count, privacy: .public) invalid diagnostic rows."
    )
  }

  private func deleteObsoleteStoredReceipt(
    forRunID runID: UUID,
    before generation: RunHistoryWriteGeneration
  ) throws {
    let statement = try prepare(
      """
      DELETE FROM workflow_run_receipts
      WHERE run_id = ? AND write_generation < ?;
      """
    )
    defer { sqlite3_finalize(statement) }
    try bind(
      [.text(runID.uuidString), .int(generation.value)],
      to: statement
    )
    try step(statement, expecting: SQLITE_DONE)
  }

  private func storedReceipt(
    forRunID runID: UUID,
    generation: RunHistoryWriteGeneration
  ) throws -> WorkflowRunReceipt? {
    let statement = try prepare(
      """
      SELECT run_id, timestamp, payload
      FROM workflow_run_receipts
      WHERE run_id = ? AND write_generation = ?;
      """
    )
    defer { sqlite3_finalize(statement) }
    try bind(
      [.text(runID.uuidString), .int(generation.value)],
      to: statement
    )
    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      return try decodeRunReceipt(from: statement)
    case SQLITE_DONE:
      return nil
    default:
      throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
    }
  }

  private func decodeRunReceipt(from statement: OpaquePointer?) throws -> WorkflowRunReceipt {
    guard let runIDText = textColumn(in: statement, index: 0),
      let runID = UUID(uuidString: runIDText),
      let protectedPayload = textColumn(in: statement, index: 2)
    else {
      throw SQLitePersistenceError.decodingRow(
        "Workflow run receipt row was missing required values."
      )
    }

    do {
      let payload = try openString(
        protectedPayload,
        context: Self.runReceiptProtectionContext(runID: runIDText)
      )
      let receipt = try decoder.decode(
        WorkflowRunReceipt.self,
        from: Data(payload.utf8)
      )
      let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
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
      let protectedDestinationPath = textColumn(in: statement, index: 2),
      let protectedMetadataText = textColumn(in: statement, index: 5)
    else {
      throw SQLitePersistenceError.decodingRow("Export metadata row was missing required values.")
    }

    let destinationPath = try openString(
      protectedDestinationPath,
      context: exportProtectionContext(recordID: idText, field: "destination_path")
    )
    let metadataText = try openString(
      protectedMetadataText,
      context: exportProtectionContext(recordID: idText, field: "metadata_json")
    )

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

  private func protectString(
    _ value: String,
    context: LocalDataProtectionContext
  ) throws -> String {
    do {
      return try localDataProtector.seal(Data(value.utf8), context: context)
    } catch {
      throw SQLitePersistenceError.protectingLocalData
    }
  }

  private func openString(
    _ envelope: String,
    context: LocalDataProtectionContext
  ) throws -> String {
    do {
      let data = try localDataProtector.open(envelope, context: context)
      guard let value = String(data: data, encoding: .utf8) else {
        throw SQLitePersistenceError.openingProtectedLocalData
      }
      return value
    } catch let error as SQLitePersistenceError {
      throw error
    } catch {
      throw SQLitePersistenceError.openingProtectedLocalData
    }
  }

  private func historyProtectionContext(
    recordID: String,
    field: String
  ) -> LocalDataProtectionContext {
    Self.historyProtectionContext(recordID: recordID, field: field)
  }

  private func settingsProtectionContext(
    keyRawValue: String
  ) -> LocalDataProtectionContext {
    Self.settingsProtectionContext(keyRawValue: keyRawValue)
  }

  private func exportProtectionContext(
    recordID: String,
    field: String
  ) -> LocalDataProtectionContext {
    Self.exportProtectionContext(recordID: recordID, field: field)
  }

  private func dataColumn(
    in statement: OpaquePointer?,
    index: Int32,
    maximumByteCount: Int
  ) throws -> Data? {
    let columnType = sqlite3_column_type(statement, index)
    guard columnType != SQLITE_NULL else { return nil }
    guard columnType == SQLITE_BLOB else {
      throw SQLitePersistenceError.clipboardPersistenceUnavailable
    }
    let byteCount = Int(sqlite3_column_bytes(statement, index))
    guard byteCount >= 0, byteCount <= maximumByteCount else {
      throw SQLitePersistenceError.clipboardPersistenceUnavailable
    }
    guard byteCount > 0 else { return Data() }
    guard let bytes = sqlite3_column_blob(statement, index) else {
      throw SQLitePersistenceError.clipboardPersistenceUnavailable
    }
    return Data(bytes: bytes, count: byteCount)
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
