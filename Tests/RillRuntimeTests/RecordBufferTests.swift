import Foundation
import Testing

@testable import RillCore
@testable import RillRuntime

struct RecordBufferTests {
  private func draft(_ text: String) -> RecordDraft {
    .init(payload: .text(text), provenance: .init(source: .init(kind: .systemClipboard)))
  }
  private func append(_ text: String, to buffer: RecordBufferID, store: RecordStore) async throws
    -> BufferEntryID
  {
    let id = try await store.reserveBufferInput(in: buffer)
    _ = try await store.ingest(draft(text), into: [], fulfilling: id)
    return id
  }
  private func drain(_ store: RecordStore) async throws -> String {
    var result = ""
    while try await store.bufferSnapshot().next != nil {
      let output = try await store.beginBufferOutput()
      if case .text(let text) = output.record.payload { result += text }
      try await store.finishBufferOutput(output.entry.id)
    }
    return result
  }

  @Test(arguments: [0, 1, 2]) func scheduling(example: Int) async throws {
    let store = RecordStore()
    _ = try await append("A", to: RecordBuffer.clipboardID, store: store)
    _ = try await append("B", to: RecordBuffer.clipboardID, store: store)
    _ = try await append("L", to: RecordBuffer.speechID, store: store)
    _ = try await append("C", to: RecordBuffer.clipboardID, store: store)
    if example == 2 {
      #expect(try await drain(store) == "CLBA")
      return
    }
    _ = try await append("H", to: RecordBuffer.speechID, store: store)
    _ = try await append("I", to: RecordBuffer.speechID, store: store)
    if example == 1 {
      let first = try await store.beginBufferOutput()
      #expect(first.record.payload == .text("L"))
      try await store.finishBufferOutput(first.entry.id)
      _ = try await append("D", to: RecordBuffer.clipboardID, store: store)
      #expect("L" + (try await drain(store)) == "LDHICBA")
    } else {
      #expect(try await drain(store) == "LHICBA")
    }
  }

  @Test func reservationOrdersAsyncCompletionAndCancellation() async throws {
    let store = RecordStore()
    let first = try await store.reserveBufferInput(in: RecordBuffer.speechID)
    let second = try await store.reserveBufferInput(in: RecordBuffer.speechID)
    _ = try await store.ingest(draft("second"), into: [], fulfilling: second)
    await #expect(throws: BufferOutputError.processing) { _ = try await store.beginBufferOutput() }
    #expect(try await store.bufferSnapshot().next?.id == first)
    try await store.cancelBufferInput(first)
    #expect(try await drain(store) == "second")
    let later = try await store.reserveBufferInput(in: RecordBuffer.speechID)
    #expect(later.sequence > second.sequence)
  }

  @Test func exactEntrySurvivesNewInputAndRepeatedShortcut() async throws {
    let store = RecordStore()
    let id = try await append("A", to: RecordBuffer.clipboardID, store: store)
    let output = try await store.beginBufferOutput()
    _ = try await append("B", to: RecordBuffer.clipboardID, store: store)
    await #expect(throws: BufferOutputError.busy) { _ = try await store.beginBufferOutput() }
    try await store.markBufferOutputUnconfirmed(id)
    await #expect(throws: BufferOutputError.busy) { _ = try await store.beginBufferOutput() }
    try await store.finishBufferOutput(output.entry.id)
    #expect(try await drain(store) == "B")
  }

  @Test func repeatedEnqueueAndReusableSetHaveDifferentSemantics() async throws {
    let store = RecordStore()
    let record = try await store.ingest(draft("A"), into: [])
    let a = try await store.enqueueRecord(record.id, in: RecordBuffer.clipboardID)
    let b = try await store.enqueueRecord(record.id, in: RecordBuffer.clipboardID)
    #expect(a != b)
    #expect(try await drain(store) == "AA")
    let set = RecordBuffer(name: "Reusable", policy: .set)
    try await store.updateBuffer(set)
    let first = try await store.enqueueRecord(record.id, in: set.id)
    let duplicate = try await store.enqueueRecord(record.id, in: set.id)
    #expect(first == duplicate)
    #expect(try await store.bufferSnapshot().next == nil)
    let output = try await store.beginBufferOutput(manualEntryID: first)
    try await store.finishBufferOutput(output.entry.id)
    #expect(try await store.entries(in: set.id).count == 1)
  }

  @Test func restartDoesNotReplayUncertainDelivery() async throws {
    let persistence = BufferCatalogFake()
    let store = RecordStore(persistence: persistence)
    let id = try await append("pending", to: RecordBuffer.clipboardID, store: store)
    _ = try await store.beginBufferOutput()
    let restored = RecordStore(persistence: persistence)
    #expect(try await restored.bufferSnapshot().active?.state == .awaitingConfirmation)
    await #expect(throws: BufferOutputError.busy) { _ = try await restored.beginBufferOutput() }
    try await restored.finishBufferOutput(id)
    let twice = RecordStore(persistence: persistence)
    #expect(try await twice.bufferSnapshot().next == nil)
  }

  @Test func failedCommitRollsBackAndSettlementNeverRedelivers() async throws {
    let persistence = BufferCatalogFake()
    let store = RecordStore(persistence: persistence)
    let id = try await store.reserveBufferInput(in: RecordBuffer.clipboardID)
    await persistence.rejectNext()
    await #expect(throws: RecordStoreError.persistenceUnavailable) {
      _ = try await store.ingest(draft("retry"), into: [], fulfilling: id)
    }
    #expect(try await store.catalogSnapshot().records.isEmpty)
    #expect(try await store.bufferSnapshot().next?.state == .preparing)
    _ = try await store.ingest(draft("retry"), into: [], fulfilling: id)
    _ = try await store.beginBufferOutput()
    await persistence.rejectNext()
    await #expect(throws: RecordStoreError.persistenceUnavailable) {
      try await store.finishBufferOutput(id)
    }
    #expect(try await store.bufferSnapshot().active?.state == .delivered)
    await #expect(throws: BufferOutputError.busy) { _ = try await store.beginBufferOutput() }
    await #expect(throws: BufferOutputError.unavailable) { try await store.retryBufferOutput(id) }
    try await store.finishBufferOutput(id)
    #expect(try await store.bufferSnapshot().remainingCount == 0)
    let mutations = await persistence.mutations
    #expect(
      mutations.filter(\.preservesManifest).allSatisfy {
        $0.newPayloadBlobs.isEmpty && $0.upserts.count <= 2
      })
  }

  @Test func migrationRetainsOnlyUnconsumedLegacyEntriesAndIsAtomic() async throws {
    let persistence = BufferCatalogFake()
    let original = RecordStore(persistence: persistence)
    let queue = try await original.createCollection(name: "Old queue", preset: .queue)
    _ = try await original.ingest(draft("consumed"), into: [queue.id])
    _ = try await original.ingest(draft("remaining"), into: [queue.id])
    let lease = try await original.beginDelivery(
      sourceCollectionIDs: [queue.id], sink: .focusedApplication)
    _ = try await original.completeDelivery(leaseID: lease.id)
    try await persistence.makeLegacy()
    await persistence.rejectNext()
    await #expect(throws: RecordStoreError.persistenceUnavailable) {
      _ = try await RecordStore(persistence: persistence).bufferSnapshot()
    }
    #expect(await persistence.manifest?.schemaVersion == 2)
    let migrated = RecordStore(persistence: persistence)
    let snapshot = try await migrated.bufferSnapshot()
    #expect(snapshot.remainingCount == 0)
    let legacy = try #require(snapshot.buffers.first { $0.buffer.legacyCollectionID == queue.id })
    #expect(legacy.count == 1)
    #expect(!legacy.buffer.isEnabled)
    var enabled = legacy.buffer
    enabled.isEnabled = true
    try await migrated.updateBuffer(enabled)
    #expect(try await drain(migrated) == "remaining")
    #expect(try await migrated.catalogSnapshot().records.count == 2)
  }

  @Test func explicitDeletionClearsBufferReferencesAtomicallyAndProtectsActiveOutput() async throws
  {
    let persistence = BufferCatalogFake()
    let store = RecordStore(persistence: persistence)
    let record = try await store.ingest(draft("delete deliberately"), into: [])
    let set = RecordBuffer(name: "Saved", policy: .set)
    try await store.updateBuffer(set)
    let reusable = try await store.enqueueRecord(record.id, in: set.id)
    _ = try await store.enqueueRecord(record.id, in: RecordBuffer.clipboardID)
    _ = try await store.enqueueRecord(record.id, in: RecordBuffer.clipboardID)
    #expect(try await store.prepareCleanup(olderThan: .distantFuture).recordIDs.isEmpty)
    let plan = try await store.prepareCleanup(scope: .record(record.id))
    await persistence.rejectNext()
    await #expect(throws: RecordStoreError.persistenceUnavailable) {
      _ = try await store.confirmCleanup(plan)
    }
    #expect(try await store.entries(in: set.id).count == 1)
    #expect(try await store.bufferSnapshot().remainingCount == 2)
    _ = try await store.beginBufferOutput(manualEntryID: reusable)
    await #expect(throws: RecordStoreError.membershipAlreadyInUse) {
      try await store.deleteRecord(record.id)
    }
    try await store.retryBufferOutput(reusable)
    _ = try await store.confirmCleanup(store.prepareCleanup(scope: .record(record.id)))
    let restored = RecordStore(persistence: persistence)
    #expect(try await restored.catalogSnapshot().records.isEmpty)
    #expect(try await restored.bufferSnapshot().remainingCount == 0)
    #expect(try await restored.entries(in: set.id).isEmpty)
  }
}

actor BufferCatalogFake: RecordCatalogPersistenceStore {
  var manifest: RecordCatalogManifest?
  var nodes: [String: RecordCatalogNode] = [:]
  var blobs: [RecordID: RecordGraphPersistenceBlob] = [:]
  var revision: Int64?
  var mutations: [RecordCatalogMutation] = []
  var rejects = false
  func rejectNext() { rejects = true }
  func makeLegacy() throws {
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
    object["schemaVersion"] = 2
    manifest = try JSONDecoder().decode(
      RecordCatalogManifest.self, from: JSONSerialization.data(withJSONObject: object))
    nodes = nodes.filter { ![.buffer, .bufferEntry, .bufferClock].contains($0.value.kind) }
  }
  func loadRecordCatalog() async throws -> RecordCatalogRead? {
    guard let manifest, let revision else { return nil }
    return .init(
      revision: revision, manifest: manifest, nodes: Array(nodes.values),
      references: blobs.values.map(\.reference))
  }
  func commitRecordCatalog(_ mutation: RecordCatalogMutation) async throws -> Int64 {
    if rejects {
      rejects = false
      throw RecordStoreError.persistenceUnavailable
    }
    guard revision == mutation.expectedRevision else {
      throw RecordStoreError.persistenceUnavailable
    }
    if !mutation.preservesManifest { manifest = mutation.manifest }
    for node in mutation.upserts { nodes[node.key] = node }
    for key in mutation.removedKeys { nodes.removeValue(forKey: key) }
    for blob in mutation.newPayloadBlobs { blobs[blob.reference.recordID] = blob }
    blobs = blobs.filter { !mutation.removedPayloadBlobIDs.contains($0.value.reference.blobID) }
    revision = (revision ?? 0) + 1
    mutations.append(mutation)
    return revision!
  }
  func loadRecordPayload(_ reference: RecordGraphPersistenceBlobReference) async throws -> Data {
    try #require(blobs[reference.recordID]?.payload)
  }
  func loadRecordGraph() async throws -> RecordGraphPersistenceReadSnapshot { .empty }
  func replaceRecordGraph(with snapshot: RecordGraphPersistenceWriteSnapshot) async throws -> Int64
  { throw RecordStoreError.persistenceUnavailable }
  func removeRecordGraph() async throws -> RecordGraphRemovalResult {
    throw RecordStoreError.persistenceUnavailable
  }
}
