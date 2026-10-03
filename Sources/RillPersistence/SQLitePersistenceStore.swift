import Foundation
import GRDB
import RillCore

/// All repository operations run synchronously on one GRDB connection. A session
/// exists only inside that queue access; transactions never cross an actor suspension.
public actor SQLitePersistenceStore: DiagnosticRepository, DiagnosticHistoryMaintaining,
  ExportMetadataRepository, RecordGraphPersistenceStore, RecordCatalogPersistenceStore,
  SensitiveSettingsStore, ContextMemoryRepository, HistoryRepository, HistoryMaintaining,
  WorkflowRunReceiptMaintaining, WorkflowRunTerminalRepository, RunHistoryBrowsing
{
  public let databaseURL: URL
  private let connection: DatabaseQueue
  private let localDataProtector: any LocalDataProtector
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(localDataProtector: any LocalDataProtector) throws {
    try self.init(databaseURL: Self.defaultDatabaseURL(), localDataProtector: localDataProtector)
  }

  public init(databaseURL: URL, localDataProtector: any LocalDataProtector) throws {
    self.databaseURL = databaseURL
    self.localDataProtector = localDataProtector
    try Self.preparePrivateStorage(at: databaseURL)
    let preexistingStorageMayContainResidue =
      SQLitePersistenceSession.preexistingStorageMayContainResidue(at: databaseURL)
    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    configuration.prepareDatabase { database in
      try SQLiteWriterBarrier.registerCapability(on: database.sqliteConnection)
      try SQLiteSchemaWriterBarrier.catalog.register(on: database.sqliteConnection)
      try SQLiteSchemaWriterBarrier.memory.register(on: database.sqliteConnection)
      try database.execute(
        sql: """
          PRAGMA journal_mode = WAL;
          PRAGMA foreign_keys = ON;
          PRAGMA secure_delete = ON;
          PRAGMA trusted_schema = OFF;
          """)
    }
    do {
      connection = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
    } catch let error as DatabaseError {
      throw SQLitePersistenceError.openingDatabase(error.message ?? "Unable to open protected storage.")
    }
    try Self.preparePrivateStorage(at: databaseURL)
    try connection.writeWithoutTransaction { database in
      let handle = database.sqliteConnection
      let cleanupIsPending = try SQLitePersistenceSession.migrate(
        on: handle, localDataProtector: localDataProtector,
        preexistingStorageMayContainResidue: preexistingStorageMayContainResidue)
      if cleanupIsPending {
        try SQLitePersistenceSession.ensureSecureDeleteEnabled(on: handle)
        try SQLitePersistenceSession.truncateWriteAheadLog(on: handle)
        try database.execute(sql: "VACUUM;")
        try SQLitePersistenceSession.truncateWriteAheadLog(on: handle)
        try SQLitePersistenceSession.markDataProtectionCleanupCompleted(on: handle)
      }
    }
  }

  public static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
    try SQLitePersistenceSession.defaultDatabaseURL(fileManager: fileManager)
  }

  public static func requiresExistingDataProtectionKey(
    databaseURL: URL, fileManager: FileManager = .default
  ) throws -> Bool {
    try SQLitePersistenceSession.requiresExistingDataProtectionKey(
      databaseURL: databaseURL, fileManager: fileManager)
  }

  public static func preparePrivateStorage(
    at databaseURL: URL, fileManager: FileManager = .default
  ) throws {
    try SQLitePersistenceSession.preparePrivateStorage(at: databaseURL, fileManager: fileManager)
  }

  private func access<T>(_ operation: (SQLitePersistenceSession) throws -> T) throws -> T {
    do {
      return try withUnsafeCurrentTask { task in
        try connection.writeWithoutTransaction { database in
          try operation(
            SQLitePersistenceSession(
              database: database, localDataProtector: localDataProtector, encoder: encoder, decoder: decoder,
              checkCancellation: {
                if task?.isCancelled == true { throw CancellationError() }
              }))
        }
      }
    } catch let error as DatabaseError {
      // Keep SQL and bound values out of the public persistence error.
      throw SQLitePersistenceError.executingSQL(error.message ?? "Unable to access protected storage.")
    }
  }

  public func loadRecordGraph() async throws -> RecordGraphPersistenceReadSnapshot {
    try access { try $0.loadRecordGraph() }
  }

  func seedLegacyRecordGraphForMigrationTesting(
    metadata: Data,
    imageBlobs: [LegacyRecordGraphImageBlob]
  ) async throws {
    try access { try $0.seedLegacyRecordGraphForMigrationTesting(metadata: metadata, imageBlobs: imageBlobs) }
  }

  public func replaceRecordGraph(
    with snapshot: RecordGraphPersistenceWriteSnapshot
  ) async throws -> Int64 {
    try access { try $0.replaceRecordGraph(with: snapshot) }
  }

  public func removeRecordGraph() async throws -> RecordGraphRemovalResult {
    try access { try $0.removeRecordGraph() }
  }

  public func purgeSensitiveStorageResidue() async throws {
    try access { try $0.purgeSensitiveStorageResidue() }
  }

  public func save(_ export: ExportMetadata) async throws {
    try access { try $0.save(export) }
  }

  public func exports(limit: Int?) async throws -> [ExportMetadata] {
    try access { try $0.exports(limit: limit) }
  }

  public func setContextAuthorization(_ id: UUID?) async throws {
    try access { try $0.setContextAuthorization(id) }
  }

  public func recordForegroundContextRequest(authorization: ContextReferenceAuthorization, now: Date) async throws {
    try access { try $0.recordForegroundContextRequest(authorization: authorization, now: now) }
  }

  public func memories() async throws -> [LongTermMemory] {
    try access { try $0.memories() }
  }

  public func saveMemory(_ memory: LongTermMemory, expectedRevision: Int64) async throws {
    try access { try $0.saveMemory(memory, expectedRevision: expectedRevision) }
  }

  public func deleteMemory(id: UUID, expectedRevision: Int64) async throws {
    try access { try $0.deleteMemory(id: id, expectedRevision: expectedRevision) }
  }

  public func relevantMemories(scope: ContextMemoryScope, now: Date) async throws -> [LongTermMemory] {
    try access { try $0.relevantMemories(scope: scope, now: now) }
  }

  public func prepareMemoryBatch(authorizationID: UUID, allowedWorkflowIDs: Set<UUID>, excludedApplications: Set<String> = [], now: Date) async throws
    -> MemoryConsolidationBatch?
  {
    try access {
      try $0.prepareMemoryBatch(authorizationID: authorizationID, allowedWorkflowIDs: allowedWorkflowIDs, excludedApplications: excludedApplications, now: now)
    }
  }

  public func commitMemoryBatch(_ batch: MemoryConsolidationBatch, result: MemoryConsolidationResult) async throws {
    try access { try $0.commitMemoryBatch(batch, result: result) }
  }

  public func memoryMaintenanceStatus(now: Date) async throws -> MemoryMaintenanceStatus {
    try access { try $0.memoryMaintenanceStatus(now: now) }
  }

  public func appendScreenSummary(
    _ summary: ScreenReferenceSummary, runID: UUID,
    generation: RunHistoryWriteGeneration, authorization: ContextReferenceAuthorization
  ) async throws {
    try access { try $0.appendScreenSummary(summary, runID: runID, generation: generation, authorization: authorization) }
  }

  public func recordUserCorrection(_ correction: ConfirmedMemoryCorrection, recordID: UUID) async throws {
    try access { try $0.recordUserCorrection(correction, recordID: recordID) }
  }

  public func string(forKey key: AppSettingKey) async throws -> String? {
    try access { try $0.string(forKey: key) }
  }

  public func strings(forKeys keys: [AppSettingKey]) async throws -> [AppSettingKey: String] {
    try access { try $0.strings(forKeys: keys) }
  }

  public func settingsSnapshot(
    forKeys keys: [AppSettingKey]
  ) async throws -> SettingsStoreReadSnapshot {
    try access { try $0.settingsSnapshot(forKeys: keys) }
  }

  public func setString(_ value: String, forKey key: AppSettingKey) async throws {
    try access { try $0.setString(value, forKey: key) }
  }

  public func setStringsAtomically(_ values: [AppSettingKey: String]) async throws {
    try access { try $0.setStringsAtomically(values) }
  }

  public func removeValue(forKey key: AppSettingKey) async throws {
    try access { try $0.removeValue(forKey: key) }
  }

  public func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration {
    try access { try $0.captureRunHistoryWriteGeneration() }
  }

  public func save(_ record: WorkflowResultRecord) async throws {
    try access { try $0.save(record) }
  }

  public func save(
    _ record: WorkflowResultRecord,
    generation: RunHistoryWriteGeneration
  ) async throws {
    try access { try $0.save(record, generation: generation) }
  }

  public func records(matching query: HistoryQuery) async throws -> [WorkflowResultRecord] {
    try access { try $0.records(matching: query) }
  }

  public func insertTerminal(_ receipt: WorkflowRunReceipt) async throws {
    try access { try $0.insertTerminal(receipt) }
  }

  public func insertTerminal(
    _ receipt: WorkflowRunReceipt,
    generation: RunHistoryWriteGeneration
  ) async throws {
    try access { try $0.insertTerminal(receipt, generation: generation) }
  }

  public func commitTerminal(
    _ receipt: WorkflowRunReceipt,
    history: WorkflowResultRecord?,
    generation: RunHistoryWriteGeneration
  ) async throws {
    try access { try $0.commitTerminal(receipt, history: history, generation: generation) }
  }

  public func receipts(
    matching query: WorkflowRunReceiptQuery
  ) async throws -> [WorkflowRunReceipt] {
    try access { try $0.receipts(matching: query) }
  }

  public func page(_ request: RunHistoryPageRequest) async throws -> RunHistoryPage {
    try access { try $0.page(request) }
  }

  public func page(
    containing entryID: UUID,
    in session: RunHistoryReadSession,
    limit: Int
  ) async throws -> RunHistoryPage? {
    try access { try $0.page(containing: entryID, in: session, limit: limit) }
  }

  public func page(
    containing entryID: UUID,
    scope: RunHistoryBrowseScope,
    retentionCutoff: Date?,
    contentAccess: RunHistoryContentAccess,
    limit: Int
  ) async throws -> RunHistoryPage? {
    try access { try $0.page(containing: entryID, scope: scope, retentionCutoff: retentionCutoff, contentAccess: contentAccess, limit: limit) }
  }

  public func deleteReceipts(olderThan cutoff: Date) async throws -> Int {
    try access { try $0.deleteReceipts(olderThan: cutoff) }
  }

  public func deleteReceipts(through upperBound: Date) async throws -> Int {
    try access { try $0.deleteReceipts(through: upperBound) }
  }

  public func deleteReceipts(
    obsoletedBy transition: RunHistoryClearTransition,
    preservingLegacyRowsAfter legacyUpperBound: Date?
  ) async throws -> Int {
    try access { try $0.deleteReceipts(obsoletedBy: transition, preservingLegacyRowsAfter: legacyUpperBound) }
  }

  public func deleteAllReceipts() async throws -> Int {
    try access { try $0.deleteAllReceipts() }
  }

  public func deleteRecords(olderThan cutoff: Date) async throws -> Int {
    try access { try $0.deleteRecords(olderThan: cutoff) }
  }

  public func deleteRecords(through upperBound: Date) async throws -> Int {
    try access { try $0.deleteRecords(through: upperBound) }
  }

  public func deleteRecords(
    obsoletedBy transition: RunHistoryClearTransition,
    preservingLegacyRowsAfter legacyUpperBound: Date?
  ) async throws -> Int {
    try access { try $0.deleteRecords(obsoletedBy: transition, preservingLegacyRowsAfter: legacyUpperBound) }
  }

  public func deleteAllRecords() async throws -> Int {
    try access { try $0.deleteAllRecords() }
  }

  public func save(_ event: DiagnosticEvent) async throws {
    try access { try $0.save(event) }
  }

  public func save(
    _ event: DiagnosticEvent,
    generation: RunHistoryWriteGeneration
  ) async throws {
    try access { try $0.save(event, generation: generation) }
  }

  public func events(matching query: DiagnosticQuery) async throws -> [DiagnosticEvent] {
    try access { try $0.events(matching: query) }
  }

  public func deleteEvents(olderThan cutoff: Date) async throws -> Int {
    try access { try $0.deleteEvents(olderThan: cutoff) }
  }

  public func deleteEvents(through upperBound: Date) async throws -> Int {
    try access { try $0.deleteEvents(through: upperBound) }
  }

  public func deleteEvents(
    obsoletedBy transition: RunHistoryClearTransition,
    preservingLegacyRowsAfter legacyUpperBound: Date?
  ) async throws -> Int {
    try access { try $0.deleteEvents(obsoletedBy: transition, preservingLegacyRowsAfter: legacyUpperBound) }
  }

  public func deleteAllEvents() async throws -> Int {
    try access { try $0.deleteAllEvents() }
  }

  public func loadRecordCatalog() async throws -> RecordCatalogRead? {
    try access { try $0.loadRecordCatalog() }
  }

  public func loadRecordPayload(_ reference: RecordGraphPersistenceBlobReference) async throws
    -> Data
  {
    try access { try $0.loadRecordPayload(reference) }
  }

  public func commitRecordCatalog(_ mutation: RecordCatalogMutation) async throws -> Int64 {
    try access { try $0.commitRecordCatalog(mutation) }
  }
}
