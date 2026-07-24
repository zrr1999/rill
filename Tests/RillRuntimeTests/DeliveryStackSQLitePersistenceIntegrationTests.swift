import Foundation
import SQLite3
import XCTest

@testable import RillCore
@testable import RillPersistence
@testable import RillRuntime

private let runtimeTestSQLiteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

final class DeliveryStackSQLitePersistenceIntegrationTests: XCTestCase {
    func testSchemaSevenImageMigratesAtomicallyAndRestoresExactBytes() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try makeStore(databaseURL: databaseURL, keyByte: 0x71)
        let imageData = Data("SQLITE-SCHEMA7-IMAGE-CANARY".utf8)
        let item = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroupID,
            contentKind: .image,
            text: "Copied image",
            imagePNGData: imageData,
            sourceKind: .system,
            tags: ["image"]
        )
        let legacy = LegacyPersistedClipboardState(
            schemaVersion: 7,
            items: [item],
            groups: [],
            groupEntries: [],
            defaultGroupEntries: [],
            defaultGroupMode: .stack,
            appAssignments: []
        )
        let legacyData = try JSONEncoder().encode(legacy)
        try await store.setString(
            String(decoding: legacyData, as: UTF8.self),
            forKey: .clipboardPersistedState
        )

        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: store
        )
        let loaded = await stack.clipboardSnapshot()
        let flushResult = await stack.flushPendingPersistenceWrites()

        XCTAssertEqual(loaded.items.first?.imagePNGData, imageData)
        XCTAssertEqual(flushResult, .persisted)
        let legacyAfterMigration = try await store.string(
            forKey: .clipboardPersistedState
        )
        XCTAssertNil(legacyAfterMigration)

        guard case .current(let revision, let metadata, let blobs) =
            try await store.loadClipboardPersistence()
        else {
            return XCTFail("Expected schema 8 clipboard persistence after migration.")
        }
        XCTAssertEqual(revision, 1)
        XCTAssertEqual(blobs.map(\.payload), [imageData])
        XCTAssertNil(metadata.range(of: imageData))
        XCTAssertFalse(
            String(decoding: metadata, as: UTF8.self).contains(
                imageData.base64EncodedString()
            )
        )

        let restored = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: store
        )
        let restoredSnapshot = await restored.clipboardSnapshot()
        XCTAssertEqual(restoredSnapshot.items.first?.id, item.id)
        XCTAssertEqual(restoredSnapshot.items.first?.imagePNGData, imageData)
        XCTAssertEqual(restoredSnapshot.persistenceAvailability, .available)
    }

    func testConsumedImageHistoryRetainsOneImmutableBlobAcrossMetadataOnlyCommitAndRestart()
        async throws
    {
        let databaseURL = try makeDatabaseURL()
        let store = try makeStore(databaseURL: databaseURL, keyByte: 0x72)
        let imageData = Data("SQLITE-IMMUTABLE-IMAGE-CANARY".utf8)
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: store
        )
        let captureResult = await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(
                plainText: "",
                imagePNGData: imageData,
                changeCount: 1
            ),
            context: ClipboardRouteContext(),
            disposition: .historyAndWorkflows
        )
        XCTAssertTrue(captureResult.wasAccepted)
        let firstFlushResult = await stack.flushPendingPersistenceWrites()
        XCTAssertEqual(firstFlushResult, .persisted)

        let snapshotBeforeUse = await stack.clipboardSnapshot()
        let item = try XCTUnwrap(snapshotBeforeUse.items.first)
        let firstRead = try await store.loadClipboardPersistence()
        let firstBlob = try XCTUnwrap(currentBlobs(in: firstRead).first)
        let firstCiphertext = try rawBlobPayload(
            blobID: firstBlob.reference.blobID,
            databaseURL: databaseURL
        )

        await stack.markUsed(itemID: item.id)
        let secondFlushResult = await stack.flushPendingPersistenceWrites()
        XCTAssertEqual(secondFlushResult, .persisted)
        let secondRead = try await store.loadClipboardPersistence()
        let secondBlob = try XCTUnwrap(currentBlobs(in: secondRead).first)
        let secondCiphertext = try rawBlobPayload(
            blobID: secondBlob.reference.blobID,
            databaseURL: databaseURL
        )

        XCTAssertEqual(secondBlob.reference, firstBlob.reference)
        XCTAssertEqual(secondBlob.payload, imageData)
        XCTAssertEqual(secondCiphertext, firstCiphertext)

        let restored = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: store
        )
        let restoredSnapshot = await restored.clipboardSnapshot()
        XCTAssertEqual(restoredSnapshot.items.first?.imagePNGData, imageData)
        XCTAssertFalse(restoredSnapshot.remainingItemIDs.contains(item.id))
    }

    func testMissingSQLiteImageBlobMakesWholeRuntimeStateUnavailableWithoutOverwrite()
        async throws
    {
        let databaseURL = try makeDatabaseURL()
        let store = try makeStore(databaseURL: databaseURL, keyByte: 0x73)
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: store
        )
        _ = await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(
                plainText: "",
                imagePNGData: Data("SQLITE-MISSING-BLOB-CANARY".utf8),
                changeCount: 1
            ),
            context: ClipboardRouteContext(),
            disposition: .historyAndWorkflows
        )
        let initialFlushResult = await stack.flushPendingPersistenceWrites()
        XCTAssertEqual(initialFlushResult, .persisted)
        let durableBeforeCorruption = try await store.loadClipboardPersistence()
        let blob = try XCTUnwrap(currentBlobs(in: durableBeforeCorruption).first)
        try deleteBlob(blob.reference.blobID, databaseURL: databaseURL)

        let restored = DeliveryStack(
            eventBus: EventBus(),
            clipboardPersistenceStore: store
        )
        let snapshot = await restored.clipboardSnapshot()

        XCTAssertEqual(snapshot.persistenceAvailability, .loadUnavailable)
        XCTAssertTrue(snapshot.items.isEmpty)
        let corruptFlushResult = await restored.flushPendingPersistenceWrites()
        XCTAssertEqual(corruptFlushResult, .loadUnavailable)
        guard case .current(let revision, _, let remainingBlobs) =
            try await store.loadClipboardPersistence()
        else {
            return XCTFail("The corrupt current row must remain authoritative.")
        }
        XCTAssertEqual(revision, 1)
        XCTAssertTrue(remainingBlobs.isEmpty)
    }

    private func makeDatabaseURL() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        return directoryURL.appendingPathComponent("rill.sqlite")
    }

    private func makeStore(
        databaseURL: URL,
        keyByte: UInt8
    ) throws -> SQLitePersistenceStore {
        let protector = try AESGCMDataProtector(
            key: Data(repeating: keyByte, count: AESGCMDataProtector.keyByteCount)
        )
        return try SQLitePersistenceStore(
            databaseURL: databaseURL,
            localDataProtector: protector
        )
    }

    private func currentBlobs(
        in snapshot: ClipboardPersistenceReadSnapshot
    ) -> [ClipboardPersistenceImageBlob] {
        guard case .current(_, _, let blobs) = snapshot else { return [] }
        return blobs
    }

    private func rawBlobPayload(blobID: UUID, databaseURL: URL) throws -> Data {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            throw SQLitePersistenceError.openingDatabase("Could not inspect clipboard blob.")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT payload FROM clipboard_image_blobs WHERE blob_id = ?;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
            let statement else {
            throw SQLitePersistenceError.preparingStatement("Could not inspect clipboard blob.")
        }
        defer { sqlite3_finalize(statement) }
        let bindResult = blobID.uuidString.withCString { value in
            sqlite3_bind_text(
                statement,
                1,
                value,
                -1,
                runtimeTestSQLiteTransient
            )
        }
        guard bindResult == SQLITE_OK else {
            throw SQLitePersistenceError.bindingValue("Could not inspect clipboard blob.")
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLitePersistenceError.decodingRow("Clipboard blob is missing.")
        }
        let byteCount = Int(sqlite3_column_bytes(statement, 0))
        guard byteCount > 0, let bytes = sqlite3_column_blob(statement, 0) else {
            throw SQLitePersistenceError.decodingRow("Clipboard blob is empty.")
        }
        return Data(bytes: bytes, count: byteCount)
    }

    private func deleteBlob(_ blobID: UUID, databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else {
            throw SQLitePersistenceError.openingDatabase("Could not corrupt clipboard fixture.")
        }
        defer { sqlite3_close(database) }
        try SQLiteWriterBarrier.registerCapability(on: database)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "DELETE FROM clipboard_image_blobs WHERE blob_id = ?;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
            let statement else {
            throw SQLitePersistenceError.preparingStatement("Could not corrupt clipboard fixture.")
        }
        defer { sqlite3_finalize(statement) }
        let bindResult = blobID.uuidString.withCString { value in
            sqlite3_bind_text(
                statement,
                1,
                value,
                -1,
                runtimeTestSQLiteTransient
            )
        }
        guard bindResult == SQLITE_OK else {
            throw SQLitePersistenceError.bindingValue("Could not corrupt clipboard fixture.")
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLitePersistenceError.steppingStatement("Could not corrupt clipboard fixture.")
        }
    }
}
