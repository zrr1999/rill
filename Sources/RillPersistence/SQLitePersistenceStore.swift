import Darwin
import Foundation
import OSLog
import RillCore
import SQLite3

let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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

enum SQLiteBinding {
  case text(String)
  case blob(Data)
  case double(Double)
  case int(Int64)
  case null
}

public actor SQLitePersistenceStore: DiagnosticRepository, DiagnosticHistoryMaintaining,
  ExportMetadataRepository,
  RecordGraphPersistenceStore
{
  static let logger = Logger(
    subsystem: "dev.zrr.Rill",
    category: "persistence"
  )

  public let databaseURL: URL

  private let connection: SQLiteConnectionBox
  let encoder = JSONEncoder()
  let decoder = JSONDecoder()
  let localDataProtector: any LocalDataProtector

  static let clipboardStorageLimits = SystemClipboardStorageLimits.productDefault
  static let maximumClipboardBlobCount =
    clipboardStorageLimits.maximumActiveItemCount
    + clipboardStorageLimits.maximumHistoryOnlyItemCount
  static let maximumProtectedClipboardMetadataByteCount =
    clipboardStorageLimits.maximumPersistedStateUTF8ByteCount * 2
  static let maximumProtectedClipboardImageByteCount =
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
      try SQLiteSchemaWriterBarrier.catalog.register(on: handle)
      try SQLiteSchemaWriterBarrier.memory.register(on: handle)
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
        if let stored = try storedRecordGraphMetadata() {
          let data = try localDataProtector.openBinary(
            stored.protectedGraph, context: Self.recordGraphProtectionContext)
          if (try? JSONDecoder().decode(RecordCatalogManifest.self, from: data).schemaVersion) == 2
          {
            throw SQLitePersistenceError.clipboardPersistenceInvalidWriteSnapshot
          }
        }
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
        guard
          Set(readbackBlobs.map { StoredRecordPayloadBlobCoordinate($0.reference) })
            == prepared.expectedCoordinates
        else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        let readbackByBlobID = Dictionary(
          uniqueKeysWithValues: readbackBlobs.map { ($0.reference.blobID, $0) }
        )
        guard
          snapshot.newPayloadBlobs.allSatisfy({ blob in
            readbackByBlobID[blob.reference.blobID] == blob
          })
        else {
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
        try execute("DELETE FROM record_catalog_nodes;")
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

  /// Advances one replayable clear transition and deletes only older-generation
  /// rows in the same transaction. A schema-4 bridge first promotes rows whose
  /// timestamps prove that they were written after the legacy intent.
  func deleteRunHistoryRows(
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

  func deleteLegacyClipboardRow() throws {
    let statement = try prepare("DELETE FROM app_settings WHERE key = ?;")
    defer { sqlite3_finalize(statement) }
    try bind([.text(AppSettingKey.legacyClipboardPersistedState.rawValue)], to: statement)
    try step(statement, expecting: SQLITE_DONE)
  }

  struct StoredRecordGraphMetadata {
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

  struct PreparedRecordPayloadBlob {
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
    let allReferences =
      snapshot.newPayloadBlobs.map(\.reference)
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

  func storedRecordGraphMetadata() throws -> StoredRecordGraphMetadata? {
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

  func storedRecordGraphRevision() throws -> Int64? {
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
    let maximumTotal =
      maximumTotalPlaintextByteCount
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

  func upsertRecordGraphMetadata(
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

  func insertRecordPayloadBlob(_ blob: PreparedRecordPayloadBlob) throws {
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

  func deleteRecordPayloadBlob(blobID: UUID) throws {
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

  func withDeferredTransaction<T>(_ operation: () throws -> T) throws -> T {
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

  func withImmediateTransaction<T>(authorization: ContextReferenceAuthorization? = nil, _ operation: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE TRANSACTION;")
    do {
      if authorization?.isValid == false { throw ContextCorrectionError.authorizationChanged }
      let result = try operation()
      if let authorization {
        try authorization.whileAuthorized {
          try Task.checkCancellation()
          try execute("COMMIT;")
        }
      } else { try execute("COMMIT;") }
      return result
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  func currentRunHistoryWriteGeneration() throws -> RunHistoryWriteGeneration {
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

  func currentRunHistoryWriteOrdinal() throws -> Int64 {
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
  func nextRunHistoryWriteOrdinal() throws -> Int64 {
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

  static func hasNonemptyBody(_ value: String?) -> Bool {
    guard let value else { return false }
    return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func generationIsCurrent(_ generation: RunHistoryWriteGeneration) throws -> Bool {
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

  func execute(_ sql: String) throws {
    try Self.execute(sql, on: db)
  }

  private func ensureSecureDeleteEnabled() throws {
    try Self.ensureSecureDeleteEnabled(on: db)
  }

  func truncateWriteAheadLog() throws {
    try Self.truncateWriteAheadLog(on: db)
  }

  static func ensureSecureDeleteEnabled(on handle: OpaquePointer?) throws {
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

  static func markDataProtectionCleanupCompleted(
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

  static func truncateWriteAheadLog(on handle: OpaquePointer?) throws {
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

  static func execute(_ sql: String, on handle: OpaquePointer?) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage(from: handle)
      if let errorMessage {
        sqlite3_free(errorMessage)
      }
      throw SQLitePersistenceError.executingSQL(message)
    }
  }

  func prepare(_ sql: String) throws -> OpaquePointer? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw SQLitePersistenceError.preparingStatement(lastErrorMessage())
    }
    return statement
  }

  func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer?) throws {
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

  func step(_ statement: OpaquePointer?, expecting expectedResult: Int32) throws {
    let rc = sqlite3_step(statement)
    guard rc == expectedResult else {
      throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
    }
  }

  func decodeHistoryRecord(from statement: OpaquePointer?) throws -> WorkflowResultRecord {
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

  func receipts(
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

  static func reportSkippedCorruptRunReceiptRows(_ count: Int) {
    guard count > 0 else { return }
    // Receipt failures are reported only as an aggregate count. Never
    // include row coordinates, protected payloads, or decoder errors.
    logger.error(
      "Skipped \(count, privacy: .public) invalid workflow run receipt rows."
    )
  }

  static func reportSkippedCorruptHistoryRows(_ count: Int) {
    guard count > 0 else { return }
    // History failures are reported only as an aggregate count. Never include
    // row coordinates, protected payloads, or decoder errors.
    logger.error(
      "Skipped \(count, privacy: .public) invalid history rows."
    )
  }

  static func reportSkippedCorruptDiagnosticRows(_ count: Int) {
    guard count > 0 else { return }
    // Diagnostic failures are reported only as an aggregate count. Never
    // include row coordinates, stored values, or decoder errors.
    logger.error(
      "Skipped \(count, privacy: .public) invalid diagnostic rows."
    )
  }

  func deleteObsoleteStoredReceipt(
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

  func storedReceipt(
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

  func decodeRunReceipt(from statement: OpaquePointer?) throws -> WorkflowRunReceipt {
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

  func protectString(
    _ value: String,
    context: LocalDataProtectionContext
  ) throws -> String {
    do {
      return try localDataProtector.seal(Data(value.utf8), context: context)
    } catch {
      throw SQLitePersistenceError.protectingLocalData
    }
  }

  func openString(
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

  func historyProtectionContext(
    recordID: String,
    field: String
  ) -> LocalDataProtectionContext {
    Self.historyProtectionContext(recordID: recordID, field: field)
  }

  func settingsProtectionContext(
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

  func dataColumn(
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

  func textColumn(in statement: OpaquePointer?, index: Int32) -> String? {
    guard let cString = sqlite3_column_text(statement, index) else {
      return nil
    }
    return String(cString: cString)
  }

  func lastErrorMessage() -> String {
    Self.lastErrorMessage(from: db)
  }

  var db: OpaquePointer? {
    connection.db
  }

  static func lastErrorMessage(from handle: OpaquePointer?) -> String {
    if let handle, let cString = sqlite3_errmsg(handle) {
      return String(cString: cString)
    }
    return "Unknown SQLite error"
  }
}
