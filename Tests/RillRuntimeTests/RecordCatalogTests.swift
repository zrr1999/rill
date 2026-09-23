import Foundation
import SQLite3
import XCTest

@testable import RillCore
@testable import RillPersistence
@testable import RillRuntime

final class RecordCatalogTests: XCTestCase {
  func testCapacityWarnsAtEitherHalfThresholdAndClearsBelowBoth() {
    XCTAssertFalse(RecordCapacity(count: 4_999, byteCount: 256 * 1_024 * 1_024 - 1).isWarning)
    XCTAssertTrue(RecordCapacity(count: 5_000, byteCount: 0).isWarning)
    XCTAssertTrue(RecordCapacity(count: 0, byteCount: 256 * 1_024 * 1_024).isWarning)
    XCTAssertFalse(RecordCapacity(count: 9_999, byteCount: 512 * 1_024 * 1_024 - 1).isFull)
    XCTAssertTrue(RecordCapacity(count: 10_000, byteCount: 0).isFull)
    XCTAssertTrue(RecordCapacity(count: 0, byteCount: 512 * 1_024 * 1_024).isFull)
  }

  func testReuseOfConsumedAndOrphanRecordsNeverConsumesMemberships() async throws {
    let store = RecordStore()
    let queue = try await store.createCollection(name: "Queue", preset: .queue)
    let first = try await store.ingest(draft("reusable"), into: [queue.id])
    let subject = RecordReuseSubject(recordID: first.id, metadataRevision: first.metadata.revision)
    let before = try await store.record(id: first.id)
    for _ in 0..<2 {
      let lease = try await store.beginReuse(subject, sink: .focusedApplication)
      let receipt = try await store.completeDelivery(leaseID: lease.id)
      XCTAssertNil(receipt.membershipID)
    }
    let afterReuse = try await store.record(id: first.id)
    XCTAssertEqual(before?.memberships, afterReuse?.memberships)
    XCTAssertEqual(afterReuse?.activity.useCount, 2)
    let queueLease = try await store.beginDelivery(
      sourceCollectionIDs: [queue.id], sink: .focusedApplication)
    _ = try await store.completeDelivery(leaseID: queueLease.id)
    let consumedLease = try await store.beginReuse(subject, sink: .systemClipboard)
    _ = try await store.completeDelivery(leaseID: consumedLease.id)
    let consumed = try await store.record(id: first.id)
    XCTAssertEqual(consumed?.memberships.first?.state, .consumed)
    let orphan = try await store.ingest(draft("orphan"), into: [])
    let orphanLease = try await store.beginReuse(
      .init(recordID: orphan.id, metadataRevision: orphan.metadata.revision), sink: .systemClipboard
    )
    _ = try await store.completeDelivery(leaseID: orphanLease.id)
    let final = try await store.record(id: orphan.id)
    XCTAssertEqual(final?.memberships, [])
  }

  func testManualCleanupAvailableBeforeWarningAndBindsToExactCandidates() async throws {
    let store = RecordStore()
    let ordinary = try await store.ingest(draft("old"), into: [])
    let plan = try await store.prepareCleanup()
    let capacity = try await store.catalogSnapshot().capacity
    XCTAssertFalse(capacity.isWarning)
    XCTAssertEqual(plan.recordIDs, [ordinary.id])
    let unchanged = try await store.catalogSnapshot()
    XCTAssertEqual(unchanged.records.count, 1)  // Merely reviewing or cancelling has no mutation.
    _ = try await store.ingest(draft("new"), into: [])
    do {
      _ = try await store.confirmCleanup(plan)
      XCTFail("A stale confirmation must not delete either record")
    } catch let error as RecordStoreError { XCTAssertEqual(error, .membershipChanged) }
    let staleResult = try await store.catalogSnapshot()
    XCTAssertEqual(staleResult.records.count, 2)
    let fresh = try await store.prepareCleanup()
    let result = try await store.confirmCleanup(fresh)
    XCTAssertEqual(result.removedCount, 2)
  }

  func testCleanupProtectsPinnedTaggedOrganizedAndInFlightRecords() async throws {
    let store = RecordStore()
    let collection = try await store.createCollection(name: "Keep")
    let pinned = try await store.ingest(draft("pinned"), into: [])
    _ = try await store.updateMetadata(recordID: pinned.id, isPinned: true)
    let tagged = try await store.ingest(draft("tagged"), into: [])
    _ = try await store.updateMetadata(recordID: tagged.id, tags: ["keep"])
    _ = try await store.ingest(draft("organized"), into: [collection.id])
    let inFlight = try await store.ingest(draft("in-flight"), into: [])
    let earlyPlan = try await store.prepareCleanup()
    let lease = try await store.beginReuse(
      .init(recordID: inFlight.id, metadataRevision: inFlight.metadata.revision),
      sink: .focusedApplication)
    do {
      _ = try await store.confirmCleanup(earlyPlan)
      XCTFail("A lease acquired after review must protect the record")
    } catch let error as RecordStoreError { XCTAssertEqual(error, .membershipChanged) }
    let protected = try await store.prepareCleanup()
    XCTAssertTrue(protected.recordIDs.isEmpty)
    XCTAssertEqual(protected.protectedCount, 4)
    try await store.cancelDelivery(leaseID: lease.id)
    let available = try await store.prepareCleanup()
    XCTAssertEqual(available.recordIDs, [inFlight.id])
  }

  func testHardCapacityRejectsWithoutEvictionAndCleanupRestoresAdmission() async throws {
    var limits = RecordStorageLimits.productDefault
    limits.maximumRecordCount = 2
    limits.maximumTotalPayloadByteCount = 8
    let store = RecordStore(storageLimits: limits)
    _ = try await store.ingest(draft("12345"), into: [])
    do {
      _ = try await store.ingest(draft("6789"), into: [])
      XCTFail("Encoded bytes exceed remaining capacity")
    } catch let error as RecordStoreError { XCTAssertEqual(error, .totalPayloadLimitReached) }
    let limited = try await store.catalogSnapshot()
    XCTAssertEqual(limited.records.count, 1)
    XCTAssertTrue(limited.capacity.isCaptureLimited)
    XCTAssertFalse(limited.capacity.isFull)
    let plan = try await store.prepareCleanup()
    _ = try await store.confirmCleanup(plan)
    let cleared = try await store.catalogSnapshot()
    XCTAssertFalse(cleared.capacity.isWarning)
    XCTAssertFalse(cleared.capacity.isCaptureLimited)
    _ = try await store.ingest(draft("a"), into: [])
    _ = try await store.ingest(draft("b"), into: [])
    do {
      _ = try await store.ingest(draft("c"), into: [])
      XCTFail("Count limit reached")
    } catch let error as RecordStoreError { XCTAssertEqual(error, .recordLimitReached) }
    let full = try await store.catalogSnapshot()
    XCTAssertEqual(full.records.count, 2)
    XCTAssertTrue(full.capacity.isFull)
  }

  func testRetentionAndLegacyPendingCleanupOnlySuggest() async throws {
    let store = RecordStore()
    let item = try await store.ingest(draft("expired"), into: [])
    let prune = try await store.pruneHistory(olderThan: .distantFuture)
    let clear = try await store.clearHistory(through: .distantFuture)
    XCTAssertEqual(prune.removedCount, 0)
    XCTAssertEqual(clear.removedCount, 0)
    let plan = try await store.prepareCleanup()
    XCTAssertEqual(plan.recordIDs, [item.id])
  }

  func testSearchMatchesChineseMultipleKeywordsFileNamesSourceAndTags() async throws {
    let store = RecordStore()
    let text = try await store.ingest(
      draft(String(repeating: "prefix ", count: 100) + "中文剪贴板全文"), into: [])
    _ = try await store.updateMetadata(recordID: text.id, tags: ["重要"])
    let files = try await store.ingest(
      RecordDraft(payload: .files([URL(fileURLWithPath: "/tmp/报告.pdf")]), provenance: provenance),
      into: [])
    let textResults = try await store.query(.init(text: "全文 editor 重要"))
    XCTAssertEqual(textResults.records.map(\.id), [text.id])
    let fileResults = try await store.query(.init(text: "报告", kind: .files))
    XCTAssertEqual(fileResults.records.map(\.id), [files.id])
    let noResults = try await store.query(.init(text: "不存在"))
    XCTAssertTrue(noResults.records.isEmpty)
  }

  func testCatalogRoundTripAndMetadataUpdateDoNotReadOrRewriteBodies() async throws {
    let fixture = try fixture()
    let store = RecordStore(persistence: fixture.persistence)
    let first = try await store.ingest(draft("unchanged body"), into: [])
    let initialRead = try await fixture.persistence.loadRecordCatalog()
    let originalCatalog = try XCTUnwrap(initialRead)
    let before = try rawBlobs(at: fixture.url)
    _ = try await store.updateMetadata(recordID: first.id, tags: ["updated"])
    XCTAssertEqual(try rawBlobs(at: fixture.url), before)
    let updatedRead = try await fixture.persistence.loadRecordCatalog()
    let updatedCatalog = try XCTUnwrap(updatedRead)
    XCTAssertEqual(originalCatalog.references, updatedCatalog.references)
    let changedKeys = zip(originalCatalog.nodes, updatedCatalog.nodes).filter {
      $0.0.value != $0.1.value
    }.map { $0.0.key }
    XCTAssertEqual(changedKeys, ["metadata/\(first.id)"])
    let restarted = RecordStore(persistence: fixture.persistence)
    let summary = try await restarted.catalogSnapshot()
    XCTAssertEqual(summary.records.first?.metadata.tags, ["updated"])
    let loaded = try await restarted.record(id: first.id)
    XCTAssertEqual(loaded?.record.payload, .text("unchanged body"))
  }

  func testCatalogStaleRevisionRollsBackWithoutChangingCiphertext() async throws {
    let fixture = try fixture()
    let firstStore = RecordStore(persistence: fixture.persistence)
    _ = try await firstStore.ingest(draft("first"), into: [])
    let staleStore = RecordStore(persistence: fixture.persistence)
    _ = try await staleStore.catalogSnapshot()
    _ = try await firstStore.ingest(draft("second"), into: [])
    let before = try rawBlobs(at: fixture.url)
    do {
      _ = try await staleStore.ingest(draft("stale"), into: [])
      XCTFail("Expected CAS failure")
    } catch let error as RecordStoreError { XCTAssertEqual(error, .persistenceUnavailable) }
    XCTAssertEqual(try rawBlobs(at: fixture.url), before)
    let restarted = RecordStore(persistence: fixture.persistence)
    let records = try await restarted.catalogSnapshot().records
    XCTAssertEqual(records.count, 2)
  }

  func testV1MigrationPreservesIdentityOrderMembershipsRoutesAndBodies() async throws {
    let fixture = try fixture()
    let oldWriter = LegacyCatalogTestWriter(store: fixture.persistence)
    let oldStore = RecordStore(persistence: oldWriter)
    let collection = try await oldStore.createCollection(name: "Saved", preset: .queue)
    let first = try await oldStore.ingest(draft("中文 original"), into: [collection.id])
    _ = try await oldStore.updateMetadata(recordID: first.id, tags: ["kept"], isPinned: true)
    _ = try await oldStore.ingest(draft("newer"), into: [])
    let before = try await oldStore.snapshot()
    let ciphertext = try rawBlobs(at: fixture.url)
    let migrated = RecordStore(persistence: fixture.persistence)
    let after = try await migrated.snapshot()
    XCTAssertEqual(before.records, after.records)
    XCTAssertEqual(before.collections, after.collections)
    XCTAssertEqual(before.captureRules, after.captureRules)
    XCTAssertEqual(before.deliveryRules, after.deliveryRules)
    XCTAssertEqual(try rawBlobs(at: fixture.url), ciphertext)
    let catalog = try await fixture.persistence.loadRecordCatalog()
    XCTAssertEqual(catalog?.manifest.schemaVersion, 2)
    do {
      _ = try await oldStore.ingest(draft("obsolete writer"), into: [])
      XCTFail("Old graph API must reject a catalog")
    } catch let error as RecordStoreError { XCTAssertEqual(error, .persistenceUnavailable) }
  }

  func testCollectionConfirmationCannotExpandAfterMembershipChange() async throws {
    let store = RecordStore()
    let collection = try await store.createCollection(name: "Delete me")
    let first = try await store.ingest(draft("retained"), into: [collection.id])
    let plan = try await store.prepareCleanup(scope: .collection(collection.id))
    XCTAssertEqual(plan.membershipIDs, first.memberships.map(\.id))
    XCTAssertEqual(plan.byteCount, 0)
    _ = try await store.ingest(draft("added later"), into: [collection.id])
    do {
      _ = try await store.confirmCleanup(plan)
      XCTFail("Memberships changed after review")
    } catch let error as RecordStoreError { XCTAssertEqual(error, .membershipChanged) }
    let fresh = try await store.prepareCleanup(scope: .collection(collection.id))
    _ = try await store.confirmCleanup(fresh)
    let snapshot = try await store.catalogSnapshot()
    XCTAssertEqual(snapshot.records.count, 2)
    XCTAssertTrue(snapshot.records.allSatisfy { $0.memberships.isEmpty })
  }

  func testCatalogTransactionRollsBackAfterPartialDeletion() async throws {
    let fixture = try fixture()
    let store = RecordStore(persistence: fixture.persistence)
    _ = try await store.ingest(draft("must survive"), into: [])
    let read = try await fixture.persistence.loadRecordCatalog()
    let catalog = try XCTUnwrap(read)
    let reference = try XCTUnwrap(catalog.references.first)
    let before = try rawBlobs(at: fixture.url)
    do {
      _ = try await fixture.persistence.commitRecordCatalog(
        .init(
          expectedRevision: catalog.revision,
          manifest: catalog.manifest, upserts: [], removedKeys: [], newPayloadBlobs: [],
          removedPayloadBlobIDs: [reference.blobID]))
      XCTFail("Manifest and retained bodies must agree before commit")
    } catch {}
    XCTAssertEqual(try rawBlobs(at: fixture.url), before)
    let after = try await fixture.persistence.loadRecordCatalog()
    XCTAssertEqual(after?.revision, catalog.revision)
    let body = try await fixture.persistence.loadRecordPayload(reference)
    XCTAssertEqual(body, Data("must survive".utf8))
  }

  func testCorruptBodyIsRejectedOnDemandWithoutDeletingItsSummary() async throws {
    let fixture = try fixture()
    let store = RecordStore(persistence: fixture.persistence)
    let item = try await store.ingest(draft("protected"), into: [])
    var database: OpaquePointer?
    guard sqlite3_open_v2(fixture.url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK
    else { throw TestError.sqlite }
    defer { sqlite3_close(database) }
    try SQLiteWriterBarrier.registerCapability(on: database)
    try SQLiteSchemaWriterBarrier.catalog.register(on: database)
    try SQLiteSchemaWriterBarrier.memory.register(on: database)
    guard
      sqlite3_exec(
        database, "UPDATE record_payload_blobs SET payload = zeroblob(length(payload));", nil, nil,
        nil) == SQLITE_OK
    else { throw TestError.sqlite }
    let reopened = RecordStore(persistence: fixture.persistence)
    let catalog = try await reopened.catalogSnapshot()
    XCTAssertEqual(catalog.records.map(\.id), [item.id])
    do {
      _ = try await reopened.record(id: item.id)
      XCTFail("An unauthenticated body must never be delivered")
    } catch {}
    let unchanged = try await reopened.catalogSnapshot()
    XCTAssertEqual(unchanged.records.count, 1)
  }

  private var provenance: RecordProvenance {
    .init(
      source: .init(kind: .systemClipboard), sourceApplicationName: "Editor",
      sourceBundleIdentifier: "com.example.editor")
  }
  private func draft(_ text: String) -> RecordDraft {
    .init(payload: .text(text), provenance: provenance)
  }
  private func fixture() throws -> (url: URL, persistence: SQLitePersistenceStore) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "record-catalog-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("data.sqlite")
    let protector = try AESGCMDataProtector(
      key: Data(repeating: 0x52, count: AESGCMDataProtector.keyByteCount))
    return (url, try SQLitePersistenceStore(databaseURL: url, localDataProtector: protector))
  }
  private func rawBlobs(at url: URL) throws -> [Data] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      throw TestError.sqlite
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database, "SELECT payload FROM record_payload_blobs ORDER BY blob_id;", -1, &statement, nil)
        == SQLITE_OK
    else { throw TestError.sqlite }
    defer { sqlite3_finalize(statement) }
    var values: [Data] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let data = sqlite3_column_blob(statement, 0) else { throw TestError.sqlite }
      values.append(Data(bytes: data, count: Int(sqlite3_column_bytes(statement, 0))))
    }
    return values
  }
  private enum TestError: Error { case sqlite }
}

private struct LegacyCatalogTestWriter: RecordGraphPersistenceStore {
  let store: SQLitePersistenceStore
  func loadRecordGraph() async throws -> RecordGraphPersistenceReadSnapshot {
    try await store.loadRecordGraph()
  }
  func replaceRecordGraph(with snapshot: RecordGraphPersistenceWriteSnapshot) async throws -> Int64
  { try await store.replaceRecordGraph(with: snapshot) }
  func removeRecordGraph() async throws -> RecordGraphRemovalResult {
    try await store.removeRecordGraph()
  }
}
