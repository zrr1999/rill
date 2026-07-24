import Foundation
import SQLite3
import XCTest

@testable import RillCore
@testable import RillPersistence

extension SQLitePersistenceStoreTests {
  func testV9MigrationCreatesV11ClipboardTablesWithoutFabricatingState() async throws {
    let databaseURL = try makeClipboardDatabaseURL()
    let protector = try makeClipboardProtector(byte: 0x61)
    do {
      let store = try SQLitePersistenceStore(
        databaseURL: databaseURL,
        localDataProtector: protector
      )
      XCTAssertEqual(try clipboardSchemaVersion(at: databaseURL), 11)
      let initialSnapshot = try await store.loadClipboardPersistence()
      XCTAssertEqual(initialSnapshot, .empty)
    }

    try simulateV9DatabaseByRemovingClipboardStorage(at: databaseURL)
    XCTAssertEqual(try clipboardSchemaVersion(at: databaseURL), 9)
    XCTAssertFalse(try clipboardTableExists("clipboard_metadata", at: databaseURL))
    XCTAssertFalse(try clipboardTableExists("clipboard_image_blobs", at: databaseURL))

    let migrated = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: protector
    )

    XCTAssertEqual(try clipboardSchemaVersion(at: databaseURL), 11)
    XCTAssertEqual(
      try clipboardColumnNames(in: "clipboard_metadata", at: databaseURL),
      ["id", "revision", "payload"]
    )
    XCTAssertEqual(
      try clipboardColumnNames(in: "clipboard_image_blobs", at: databaseURL),
      ["blob_id", "item_id", "payload", "plaintext_size", "state_id"]
    )
    let migratedSnapshot = try await migrated.loadClipboardPersistence()
    XCTAssertEqual(migratedSnapshot, .empty)
  }

  func testClipboardPersistenceEmptyAndCurrentRoundTripUsesProtectedBinaryBLOBs() async throws {
    let databaseURL = try makeClipboardDatabaseURL()
    let store = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: makeClipboardProtector(byte: 0x62)
    )
    let initialSnapshot = try await store.loadClipboardPersistence()
    XCTAssertEqual(initialSnapshot, .empty)

    let metadata = Data("clipboard-metadata-\(UUID().uuidString)".utf8)
    let blob = makeClipboardBlob(label: "round-trip")
    let revision = try await store.replaceClipboardPersistence(
      with: ClipboardPersistenceWriteSnapshot(
        expectedRevision: nil,
        metadata: metadata,
        newImageBlobs: [blob],
        retainedImageBlobReferences: []
      )
    )

    XCTAssertEqual(revision, 1)
    let loadedSnapshot = try await store.loadClipboardPersistence()
    XCTAssertEqual(
      loadedSnapshot,
      .current(revision: 1, metadata: metadata, imageBlobs: [blob])
    )

    let rawMetadata = try XCTUnwrap(rawClipboardMetadataPayload(at: databaseURL))
    let rawImage = try XCTUnwrap(
      rawClipboardImagePayload(blobID: blob.reference.blobID, at: databaseURL)
    )
    XCTAssertEqual(rawMetadata.storageClass, SQLITE_BLOB)
    XCTAssertEqual(rawImage.storageClass, SQLITE_BLOB)
    XCTAssertNotEqual(rawMetadata.data, metadata)
    XCTAssertNotEqual(rawImage.data, blob.payload)
    XCTAssertNil(rawMetadata.data.range(of: metadata))
    XCTAssertNil(rawImage.data.range(of: blob.payload))
  }

  func testClipboardPersistenceLoadRejectsMetadataAndBlobTotalAboveProductBudgetBeforeBlobOpen()
    async throws
  {
    let databaseURL = try makeClipboardDatabaseURL()
    let limits = ClipboardStorageLimits.productDefault
    let protector = try ClipboardBudgetTestProtector(
      metadataByteCount: limits.maximumPersistedStateUTF8ByteCount
        - limits.maximumTotalEncodedItemByteCount + 1
    )
    let store = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: protector
    )
    let blobByteCount = limits.maximumImageByteCount
    try executeClipboardFixtureSQL(
      """
      INSERT INTO clipboard_metadata (id, revision, payload)
      VALUES (1, 1, X'4D');
      INSERT INTO clipboard_image_blobs (
          blob_id, item_id, payload, plaintext_size, state_id
      ) VALUES (
          '00000000-0000-0000-0000-000000000001',
          '10000000-0000-0000-0000-000000000001',
          X'41', \(blobByteCount), 1
      );
      INSERT INTO clipboard_image_blobs (
          blob_id, item_id, payload, plaintext_size, state_id
      ) VALUES (
          '00000000-0000-0000-0000-000000000002',
          '10000000-0000-0000-0000-000000000002',
          X'42', \(blobByteCount), 1
      );
      """,
      at: databaseURL
    )

    do {
      _ = try await store.loadClipboardPersistence()
      XCTFail("Expected the combined clipboard plaintext budget to fail closed.")
    } catch let error as SQLitePersistenceError {
      XCTAssertEqual(error, .clipboardPersistenceUnavailable)
    }
    XCTAssertEqual(
      protector.clipboardBlobOpenCount,
      0,
      "The declared graph must be rejected before any blob payload is opened."
    )
  }

  func testClipboardPersistenceRevisionCASRejectsStaleWriterWithoutMutation() async throws {
    let databaseURL = try makeClipboardDatabaseURL()
    let store = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: makeClipboardProtector(byte: 0x63)
    )
    let firstMetadata = Data("revision-one".utf8)
    let secondMetadata = Data("revision-two".utf8)

    let firstRevision = try await store.replaceClipboardPersistence(
      with: ClipboardPersistenceWriteSnapshot(
        expectedRevision: nil,
        metadata: firstMetadata,
        newImageBlobs: [],
        retainedImageBlobReferences: []
      )
    )
    let secondRevision = try await store.replaceClipboardPersistence(
      with: ClipboardPersistenceWriteSnapshot(
        expectedRevision: firstRevision,
        metadata: secondMetadata,
        newImageBlobs: [],
        retainedImageBlobReferences: []
      )
    )

    XCTAssertEqual(firstRevision, 1)
    XCTAssertEqual(secondRevision, 2)
    do {
      _ = try await store.replaceClipboardPersistence(
        with: ClipboardPersistenceWriteSnapshot(
          expectedRevision: firstRevision,
          metadata: Data("stale-writer".utf8),
          newImageBlobs: [],
          retainedImageBlobReferences: []
        )
      )
      XCTFail("Expected a stale clipboard writer to lose the revision CAS.")
    } catch let error as SQLitePersistenceError {
      XCTAssertEqual(error, .clipboardPersistenceRevisionConflict)
    }
    let loadedSnapshot = try await store.loadClipboardPersistence()
    XCTAssertEqual(
      loadedSnapshot,
      .current(revision: 2, metadata: secondMetadata, imageBlobs: [])
    )
  }

  func testClipboardPersistenceRetainsExistingBlobAddsNewBlobAndDeletesStaleBlob() async throws {
    let databaseURL = try makeClipboardDatabaseURL()
    let store = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: makeClipboardProtector(byte: 0x64)
    )
    let retained = makeClipboardBlob(label: "retained")
    let stale = makeClipboardBlob(label: "stale")
    let added = makeClipboardBlob(label: "added")

    let firstRevision = try await store.replaceClipboardPersistence(
      with: ClipboardPersistenceWriteSnapshot(
        expectedRevision: nil,
        metadata: Data("first-graph".utf8),
        newImageBlobs: [retained, stale],
        retainedImageBlobReferences: []
      )
    )
    let retainedCiphertext = try XCTUnwrap(
      rawClipboardImagePayload(blobID: retained.reference.blobID, at: databaseURL)
    ).data

    let secondMetadata = Data("second-graph".utf8)
    let secondRevision = try await store.replaceClipboardPersistence(
      with: ClipboardPersistenceWriteSnapshot(
        expectedRevision: firstRevision,
        metadata: secondMetadata,
        newImageBlobs: [added],
        retainedImageBlobReferences: [retained.reference]
      )
    )

    XCTAssertEqual(secondRevision, 2)
    guard
      case .current(let revision, let metadata, let imageBlobs) =
        try await store.loadClipboardPersistence()
    else {
      return XCTFail("Expected a current clipboard snapshot after replacement.")
    }
    XCTAssertEqual(revision, 2)
    XCTAssertEqual(metadata, secondMetadata)
    XCTAssertEqual(Set(imageBlobs.map(\.reference)), [retained.reference, added.reference])
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: imageBlobs.map { ($0.reference.blobID, $0.payload) }),
      [
        retained.reference.blobID: retained.payload,
        added.reference.blobID: added.payload,
      ]
    )
    XCTAssertEqual(
      try XCTUnwrap(
        rawClipboardImagePayload(blobID: retained.reference.blobID, at: databaseURL)
      ).data,
      retainedCiphertext,
      "Retaining an immutable image must not reseal it."
    )
    let stalePayload = try rawClipboardImagePayload(
      blobID: stale.reference.blobID,
      at: databaseURL
    )
    let addedPayload = try rawClipboardImagePayload(
      blobID: added.reference.blobID,
      at: databaseURL
    )
    XCTAssertNil(stalePayload)
    XCTAssertNotNil(addedPayload)
    XCTAssertEqual(
      try clipboardBlobIDs(at: databaseURL),
      [retained.reference.blobID, added.reference.blobID]
    )
  }

  func testClipboardPersistenceSwappedBlobCiphertextsFailAADAuthentication() async throws {
    let databaseURL = try makeClipboardDatabaseURL()
    let store = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: makeClipboardProtector(byte: 0x67)
    )
    let first = makeClipboardBlob(label: "aad-first")
    let second = makeClipboardBlob(label: "aad-second")
    _ = try await store.replaceClipboardPersistence(
      with: ClipboardPersistenceWriteSnapshot(
        expectedRevision: nil,
        metadata: Data("aad-graph".utf8),
        newImageBlobs: [first, second],
        retainedImageBlobReferences: []
      )
    )

    try executeClipboardFixtureSQL(
      """
      CREATE TEMP TABLE clipboard_payload_swap (blob_id TEXT PRIMARY KEY, payload BLOB);
      INSERT INTO clipboard_payload_swap (blob_id, payload)
      SELECT blob_id, payload FROM clipboard_image_blobs;
      UPDATE clipboard_image_blobs
      SET payload = CASE blob_id
          WHEN '\(first.reference.blobID.uuidString)' THEN (
              SELECT payload FROM clipboard_payload_swap
              WHERE blob_id = '\(second.reference.blobID.uuidString)'
          )
          WHEN '\(second.reference.blobID.uuidString)' THEN (
              SELECT payload FROM clipboard_payload_swap
              WHERE blob_id = '\(first.reference.blobID.uuidString)'
          )
          ELSE payload
      END;
      DROP TABLE clipboard_payload_swap;
      """,
      at: databaseURL
    )

    do {
      _ = try await store.loadClipboardPersistence()
      XCTFail("Expected swapped clipboard ciphertexts to fail authentication.")
    } catch let error as SQLitePersistenceError {
      XCTAssertEqual(error, .clipboardPersistenceUnavailable)
    }
  }

  func testClipboardPersistenceResetPurgesCommittedCiphertextFromDatabaseAndWAL() async throws {
    let databaseURL = try makeClipboardDatabaseURL()
    let store = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: makeClipboardProtector(byte: 0x68)
    )
    let blob = makeClipboardBlob(label: "purge")
    _ = try await store.replaceClipboardPersistence(
      with: ClipboardPersistenceWriteSnapshot(
        expectedRevision: nil,
        metadata: Data("metadata-to-purge".utf8),
        newImageBlobs: [blob],
        retainedImageBlobReferences: []
      )
    )
    let metadataCiphertext = try XCTUnwrap(
      rawClipboardMetadataPayload(at: databaseURL)
    ).data
    let imageCiphertext = try XCTUnwrap(
      rawClipboardImagePayload(blobID: blob.reference.blobID, at: databaseURL)
    ).data

    let removalResult = try await store.removeClipboardPersistence()

    XCTAssertEqual(removalResult, .removed)
    for storageURL in [
      databaseURL,
      URL(fileURLWithPath: databaseURL.path + "-wal"),
    ] where FileManager.default.fileExists(atPath: storageURL.path) {
      let storageBytes = try Data(contentsOf: storageURL)
      XCTAssertNil(storageBytes.range(of: metadataCiphertext))
      XCTAssertNil(storageBytes.range(of: imageCiphertext))
    }
  }

  func testClipboardPersistenceLegacySnapshotMigratesOnlyAfterCurrentCommit() async throws {
    let databaseURL = try makeClipboardDatabaseURL()
    let store = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: makeClipboardProtector(byte: 0x65)
    )
    let legacy = "legacy-schema-seven-\(UUID().uuidString)"
    try await store.setString(legacy, forKey: .clipboardPersistedState)

    let legacySnapshot = try await store.loadClipboardPersistence()
    XCTAssertEqual(
      legacySnapshot,
      .legacy(metadata: Data(legacy.utf8))
    )

    let currentMetadata = Data("schema-eight".utf8)
    let revision = try await store.replaceClipboardPersistence(
      with: ClipboardPersistenceWriteSnapshot(
        expectedRevision: nil,
        metadata: currentMetadata,
        newImageBlobs: [],
        retainedImageBlobReferences: []
      )
    )

    XCTAssertEqual(revision, 1)
    let legacyValue = try await store.string(forKey: .clipboardPersistedState)
    XCTAssertNil(legacyValue)
    let currentSnapshot = try await store.loadClipboardPersistence()
    XCTAssertEqual(
      currentSnapshot,
      .current(revision: 1, metadata: currentMetadata, imageBlobs: [])
    )
  }

  func testClipboardPersistenceLegacyCurrentConflictFailsClosedAndResetRemovesBothGraphs()
    async throws
  {
    let databaseURL = try makeClipboardDatabaseURL()
    let store = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: makeClipboardProtector(byte: 0x66)
    )
    let blob = makeClipboardBlob(label: "reset")
    _ = try await store.replaceClipboardPersistence(
      with: ClipboardPersistenceWriteSnapshot(
        expectedRevision: nil,
        metadata: Data("current-before-conflict".utf8),
        newImageBlobs: [blob],
        retainedImageBlobReferences: []
      )
    )
    try await store.setString(
      "conflicting-legacy-state",
      forKey: .clipboardPersistedState
    )

    do {
      _ = try await store.loadClipboardPersistence()
      XCTFail("Expected coexisting legacy and current clipboard graphs to fail closed.")
    } catch let error as SQLitePersistenceError {
      XCTAssertEqual(error, .clipboardPersistenceUnavailable)
    }

    let removalResult = try await store.removeClipboardPersistence()
    let emptySnapshot = try await store.loadClipboardPersistence()
    let legacyValue = try await store.string(forKey: .clipboardPersistedState)
    XCTAssertEqual(removalResult, .removed)
    XCTAssertEqual(emptySnapshot, .empty)
    XCTAssertNil(legacyValue)
    XCTAssertEqual(try clipboardRowCount(in: "clipboard_metadata", at: databaseURL), 0)
    XCTAssertEqual(try clipboardRowCount(in: "clipboard_image_blobs", at: databaseURL), 0)
  }

  func testClipboardPersistenceResetRemovesOrphanBlobAndAllowsFreshPersistence() async throws {
    let databaseURL = try makeClipboardDatabaseURL()
    let store = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: makeClipboardProtector(byte: 0x6A)
    )
    try executeClipboardFixtureSQL(
      """
      INSERT INTO clipboard_image_blobs (
          blob_id, item_id, payload, plaintext_size, state_id
      ) VALUES (
          '00000000-0000-0000-0000-0000000000AA',
          '10000000-0000-0000-0000-0000000000AA',
          X'41', 1, 1
      );
      """,
      at: databaseURL
    )

    do {
      _ = try await store.loadClipboardPersistence()
      XCTFail("Expected an orphan clipboard image blob to fail closed.")
    } catch let error as SQLitePersistenceError {
      XCTAssertEqual(error, .clipboardPersistenceUnavailable)
    }

    let removalResult = try await store.removeClipboardPersistence()
    XCTAssertEqual(removalResult, .removed)
    XCTAssertEqual(try clipboardRowCount(in: "clipboard_metadata", at: databaseURL), 0)
    XCTAssertEqual(try clipboardRowCount(in: "clipboard_image_blobs", at: databaseURL), 0)

    let freshMetadata = Data("fresh-after-orphan-reset".utf8)
    let freshBlob = makeClipboardBlob(label: "fresh-after-orphan-reset")
    let revision = try await store.replaceClipboardPersistence(
      with: ClipboardPersistenceWriteSnapshot(
        expectedRevision: nil,
        metadata: freshMetadata,
        newImageBlobs: [freshBlob],
        retainedImageBlobReferences: []
      )
    )
    let freshSnapshot = try await store.loadClipboardPersistence()
    XCTAssertEqual(revision, 1)
    XCTAssertEqual(
      freshSnapshot,
      .current(revision: 1, metadata: freshMetadata, imageBlobs: [freshBlob])
    )
  }

  private struct RawClipboardPayload {
    let storageClass: Int32
    let data: Data
  }

  private func makeClipboardDatabaseURL() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directoryURL)
    }
    return directoryURL.appendingPathComponent("rill-clipboard-test.sqlite")
  }

  private func makeClipboardProtector(byte: UInt8) throws -> AESGCMDataProtector {
    try AESGCMDataProtector(
      key: Data(repeating: byte, count: AESGCMDataProtector.keyByteCount)
    )
  }

  private func makeClipboardBlob(label: String) -> ClipboardPersistenceImageBlob {
    let payload = Data("image-\(label)-\(UUID().uuidString)".utf8)
    return ClipboardPersistenceImageBlob(
      reference: ClipboardPersistenceBlobReference(
        blobID: UUID(),
        itemID: UUID(),
        byteCount: payload.count
      ),
      payload: payload
    )
  }

  private func executeClipboardFixtureSQL(_ sql: String, at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to open a clipboard test fixture.")
    }
    defer { sqlite3_close(database) }
    try SQLiteWriterBarrier.registerCapability(on: database)
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw SQLitePersistenceError.executingSQL(
        String(cString: sqlite3_errmsg(database))
      )
    }
  }

  private func simulateV9DatabaseByRemovingClipboardStorage(at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase(
        "Failed to create the v9 clipboard migration fixture."
      )
    }
    defer { sqlite3_close(database) }
    try SQLiteWriterBarrier.registerCapability(on: database)
    try removeClipboardV11StorageBoundary(on: database)
    guard
      sqlite3_exec(
        database,
        """
        DROP TABLE clipboard_image_blobs;
        DROP TABLE clipboard_metadata;
        PRAGMA user_version = 9;
        """,
        nil,
        nil,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.executingSQL(
        "Failed to create the v9 clipboard migration fixture."
      )
    }
  }

  private func removeClipboardV11StorageBoundary(on database: OpaquePointer?) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        """
        SELECT name
        FROM sqlite_schema
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
      throw SQLitePersistenceError.preparingStatement(
        "Failed to inspect the v11 clipboard writer boundary."
      )
    }
    var triggerNames: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let name = sqlite3_column_text(statement, 0) else {
        sqlite3_finalize(statement)
        throw SQLitePersistenceError.decodingRow(
          "Failed to decode the v11 clipboard writer boundary."
        )
      }
      triggerNames.append(String(cString: name))
    }
    sqlite3_finalize(statement)

    for triggerName in triggerNames {
      guard
        !triggerName.isEmpty,
        triggerName.utf8.allSatisfy({
          $0 == 95 || (48...57).contains($0) || (97...122).contains($0)
        }),
        sqlite3_exec(database, "DROP TRIGGER \(triggerName);", nil, nil, nil) == SQLITE_OK
      else {
        throw SQLitePersistenceError.executingSQL(
          "Failed to remove the v11 clipboard writer boundary."
        )
      }
    }
    guard
      sqlite3_exec(
        database,
        "DROP TABLE rill_authenticated_schema_floor;",
        nil,
        nil,
        nil
      ) == SQLITE_OK
    else {
      throw SQLitePersistenceError.executingSQL(
        "Failed to remove the v11 clipboard schema floor."
      )
    }
  }

  private func clipboardSchemaVersion(at databaseURL: URL) throws -> Int {
    try clipboardIntegerQuery("PRAGMA user_version;", at: databaseURL)
  }

  private func clipboardTableExists(_ tableName: String, at databaseURL: URL) throws -> Bool {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to inspect clipboard tables.")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement("Failed to inspect clipboard tables.")
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let binding = tableName.withCString {
      sqlite3_bind_text(statement, 1, $0, -1, transient)
    }
    guard binding == SQLITE_OK else {
      throw SQLitePersistenceError.bindingValue("Failed to bind a clipboard table name.")
    }
    return sqlite3_step(statement) == SQLITE_ROW
  }

  private func clipboardColumnNames(in tableName: String, at databaseURL: URL) throws
    -> Set<String>
  {
    let allowedTableNames = Set(["clipboard_metadata", "clipboard_image_blobs"])
    guard allowedTableNames.contains(tableName) else {
      throw SQLitePersistenceError.executingSQL("Unsupported clipboard test table.")
    }
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to inspect clipboard columns.")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "PRAGMA table_info(\(tableName));",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement("Failed to inspect clipboard columns.")
    }
    defer { sqlite3_finalize(statement) }
    var names: Set<String> = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let name = sqlite3_column_text(statement, 1) else { continue }
      names.insert(String(cString: name))
    }
    return names
  }

  private func rawClipboardMetadataPayload(at databaseURL: URL) throws -> RawClipboardPayload? {
    try rawClipboardPayload(
      sql: "SELECT payload FROM clipboard_metadata WHERE id = 1;",
      binding: nil,
      at: databaseURL
    )
  }

  private func rawClipboardImagePayload(blobID: UUID, at databaseURL: URL) throws
    -> RawClipboardPayload?
  {
    try rawClipboardPayload(
      sql: "SELECT payload FROM clipboard_image_blobs WHERE blob_id = ?;",
      binding: blobID.uuidString,
      at: databaseURL
    )
  }

  private func rawClipboardPayload(
    sql: String,
    binding: String?,
    at databaseURL: URL
  ) throws -> RawClipboardPayload? {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to inspect clipboard payloads.")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement("Failed to inspect clipboard payloads.")
    }
    defer { sqlite3_finalize(statement) }
    if let binding {
      let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      let result = binding.withCString {
        sqlite3_bind_text(statement, 1, $0, -1, transient)
      }
      guard result == SQLITE_OK else {
        throw SQLitePersistenceError.bindingValue("Failed to bind a clipboard blob identity.")
      }
    }
    switch sqlite3_step(statement) {
    case SQLITE_DONE:
      return nil
    case SQLITE_ROW:
      let storageClass = sqlite3_column_type(statement, 0)
      let byteCount = Int(sqlite3_column_bytes(statement, 0))
      guard byteCount > 0, let bytes = sqlite3_column_blob(statement, 0) else {
        throw SQLitePersistenceError.decodingRow("A clipboard payload was empty.")
      }
      let payload = Data(bytes: bytes, count: byteCount)
      guard sqlite3_step(statement) == SQLITE_DONE else {
        throw SQLitePersistenceError.decodingRow("A clipboard payload identity was duplicated.")
      }
      return RawClipboardPayload(storageClass: storageClass, data: payload)
    default:
      throw SQLitePersistenceError.steppingStatement("Failed to inspect a clipboard payload.")
    }
  }

  private func clipboardBlobIDs(at databaseURL: URL) throws -> Set<UUID> {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to inspect clipboard blob identities.")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT blob_id FROM clipboard_image_blobs;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement(
        "Failed to inspect clipboard blob identities."
      )
    }
    defer { sqlite3_finalize(statement) }
    var blobIDs: Set<UUID> = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let text = sqlite3_column_text(statement, 0),
        let blobID = UUID(uuidString: String(cString: text))
      else {
        throw SQLitePersistenceError.decodingRow("A clipboard blob identity was malformed.")
      }
      blobIDs.insert(blobID)
    }
    return blobIDs
  }

  private func clipboardRowCount(in tableName: String, at databaseURL: URL) throws -> Int {
    let allowedTableNames = Set(["clipboard_metadata", "clipboard_image_blobs"])
    guard allowedTableNames.contains(tableName) else {
      throw SQLitePersistenceError.executingSQL("Unsupported clipboard test table.")
    }
    return try clipboardIntegerQuery("SELECT COUNT(*) FROM \(tableName);", at: databaseURL)
  }

  private func clipboardIntegerQuery(_ sql: String, at databaseURL: URL) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      throw SQLitePersistenceError.openingDatabase("Failed to inspect clipboard storage.")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw SQLitePersistenceError.preparingStatement("Failed to inspect clipboard storage.")
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw SQLitePersistenceError.steppingStatement("Failed to inspect clipboard storage.")
    }
    return Int(sqlite3_column_int64(statement, 0))
  }
}

private final class ClipboardBudgetTestProtector: LocalDataProtector, @unchecked Sendable {
  private let base: AESGCMDataProtector
  private let metadataByteCount: Int
  private let lock = NSLock()
  private var blobOpenCount = 0

  init(metadataByteCount: Int) throws {
    self.metadataByteCount = metadataByteCount
    self.base = try AESGCMDataProtector(
      key: Data(repeating: 0x69, count: AESGCMDataProtector.keyByteCount)
    )
  }

  var clipboardBlobOpenCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return blobOpenCount
  }

  func seal(_ plaintext: Data, context: LocalDataProtectionContext) throws -> String {
    try base.seal(plaintext, context: context)
  }

  func open(_ envelope: String, context: LocalDataProtectionContext) throws -> Data {
    try base.open(envelope, context: context)
  }

  func sealBinary(_ plaintext: Data, context: LocalDataProtectionContext) throws -> Data {
    try base.sealBinary(plaintext, context: context)
  }

  func openBinary(_ envelope: Data, context: LocalDataProtectionContext) throws -> Data {
    switch context.namespace {
    case "clipboard_metadata":
      return Data(repeating: 0x4D, count: metadataByteCount)
    case "clipboard_image_blobs":
      lock.lock()
      blobOpenCount += 1
      lock.unlock()
      return Data(
        repeating: 0x42,
        count: ClipboardStorageLimits.productDefault.maximumImageByteCount
      )
    default:
      return try base.openBinary(envelope, context: context)
    }
  }
}
