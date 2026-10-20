import Foundation
import Testing

@testable import RillCore
@testable import RillRecords

private final class BufferDateClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date
  init(_ date: Date) { self.date = date }
  func now() -> Date { lock.withLock { date } }
  func advance(_ interval: TimeInterval) { lock.withLock { date.addTimeInterval(interval) } }
}

struct RecordBufferExpirationTests {
  private let start = Date(timeIntervalSince1970: 1_000_000)

  private func append(_ text: String, store: RecordStore) async throws -> BufferEntryID {
    let id = try await store.reserveBufferInput(in: RecordBuffer.speechID)
    _ = try await store.ingest(
      .init(payload: .text(text), provenance: .init(source: .init(kind: .voiceInput))),
      into: [RecordCollection.voiceInputID], fulfilling: id, recognitionText: text)
    return id
  }

  @Test func expiresAt24HoursAndPreservesRecordAndMemberships() async throws {
    let clock = BufferDateClock(start)
    let persistence = BufferCatalogFake()
    let store = RecordStore(persistence: persistence, currentDate: clock.now)
    let id = try await append("pending", store: store)
    let record = try #require(try await store.snapshot().records.first)
    clock.advance(BufferEntry.pendingLifetime - 1)
    #expect(try await store.bufferSnapshot().next?.id == id)
    clock.advance(1)
    #expect(try await store.bufferSnapshot().remainingCount == 0)
    #expect(try await store.record(id: record.id) == record)
    #expect(try await RecordStore(persistence: persistence, currentDate: clock.now).bufferItems().isEmpty)
    await #expect(throws: BufferOutputError.unavailable) {
      _ = try await store.beginBufferOutput(manualEntryID: id)
    }
  }

  @Test func inputTimeSurvivesSlowRecognitionDeduplicationAndRestart() async throws {
    let clock = BufferDateClock(start)
    let persistence = BufferCatalogFake()
    let store = RecordStore(persistence: persistence, currentDate: clock.now)
    let first = try await store.reserveBufferInput(in: RecordBuffer.speechID)
    clock.advance(60 * 60)
    let record = try await store.ingest(
      .init(payload: .text("same"), provenance: .init(source: .init(kind: .voiceInput))),
      into: [], fulfilling: first)
    let second = try await store.enqueueRecord(record.id, in: RecordBuffer.clipboardID)
    let entries = try await store.entries(in: RecordBuffer.speechID)
    #expect(entries.first?.enqueuedAt == start)
    clock.advance(BufferEntry.pendingLifetime - 60 * 60)
    let restored = RecordStore(persistence: persistence, currentDate: clock.now)
    #expect(try await restored.entries(in: RecordBuffer.speechID).isEmpty)
    #expect(try await restored.entries(in: RecordBuffer.clipboardID).map(\.id) == [second])
    #expect(try await restored.snapshot().records.count == 1)
  }

  @Test func failedExpiryRetainsCommittedStateForRetry() async throws {
    let clock = BufferDateClock(start)
    let persistence = BufferCatalogFake()
    let store = RecordStore(persistence: persistence, currentDate: clock.now)
    let id = try await append("keep on failure", store: store)
    let before = try await store.bufferSnapshot()
    let nodes = await persistence.nodes
    clock.advance(BufferEntry.pendingLifetime)
    await persistence.rejectNext()
    await #expect(throws: RecordStoreError.persistenceUnavailable) {
      try await store.expireBufferEntries()
    }
    #expect(await persistence.nodes == nodes)
    #expect(try await store.bufferDraft(for: id)?.text == "keep on failure")
    clock.advance(-1)
    #expect(try await store.bufferSnapshot() == before)
    clock.advance(1)
    try await store.expireBufferEntries()
    #expect(try await store.bufferSnapshot().remainingCount == 0)
  }

  @Test func bufferSubscriptionSurvivesFailedExpiryAndReceivesRecovery() async throws {
    let clock = BufferDateClock(start)
    let persistence = BufferCatalogFake()
    let store = RecordStore(persistence: persistence, currentDate: clock.now)
    let id = try await append("keep on failure", store: store)
    clock.advance(BufferEntry.pendingLifetime)
    await persistence.rejectNext()

    let stream = try await store.bufferStream()
    var snapshots = stream.makeAsyncIterator()
    #expect(await snapshots.next()?.next?.id == id)
    await #expect(throws: RecordStoreError.persistenceUnavailable) {
      try await store.expireBufferEntries()
    }
    #expect(try await store.bufferDraft(for: id)?.text == "keep on failure")

    try await store.expireBufferEntries()
    #expect(await snapshots.next()?.remainingCount == 0)
    #expect(try await store.snapshot().records.count == 1)
    let replacement = try await append("new capture", store: store)
    #expect(await snapshots.next()?.next?.id == replacement)
  }

  @Test func activeEditingUnsentChangesAndUncertainDeliveryAreProtected() async throws {
    let clock = BufferDateClock(start)
    let store = RecordStore(currentDate: clock.now)
    let editing = try await append("editing", store: store)
    let edited = try await append("edited", store: store)
    let delivering = try await append("delivering", store: store)
    let expires = try await append("expires", store: store)
    let preparing = try await store.reserveBufferInput(in: RecordBuffer.speechID)
    let editedSession = UUID()
    let draft = try await store.openBufferDraft(edited, editingSessionID: editedSession)
    _ = try await store.saveBufferDraft(edited, draftID: draft.id, expectedRevision: draft.revision, text: "unsent edit")
    await store.closeBufferEditingSession(editedSession)
    let editingSession = UUID()
    _ = try await store.openBufferDraft(editing, editingSessionID: editingSession)
    _ = try await store.beginBufferOutput(manualEntryID: delivering)
    try await store.markBufferOutputUnconfirmed(delivering)
    clock.advance(BufferEntry.pendingLifetime)
    try await store.expireBufferEntries()
    #expect(Set(try await store.bufferItems().map(\.id)) == [editing, edited, delivering, preparing])
    #expect(try await store.bufferSnapshot().active?.id == delivering)
    #expect(try await store.bufferDraft(for: expires) == nil)
    await store.closeBufferEditingSession(editingSession)
    try await store.expireBufferEntries()
    #expect(try await store.bufferDraft(for: editing) == nil)
    #expect(try await store.bufferDraft(for: edited)?.text == "unsent edit")
    try await store.retryBufferOutput(delivering)
    try await store.expireBufferEntries()
    #expect(Set(try await store.bufferItems().map(\.id)) == [edited, preparing])
  }

  @Test func oldCatalogGetsOnePersistedGracePeriodAndFailedUpgradeDoesNotResetIt() async throws {
    let clock = BufferDateClock(start)
    let persistence = BufferCatalogFake()
    let store = RecordStore(persistence: persistence, currentDate: clock.now)
    let id = try await append("legacy pending", store: store)
    try await persistence.removeBufferInputTimestamps()
    clock.advance(10 * BufferEntry.pendingLifetime)
    let upgradeDate = clock.now()
    await persistence.rejectNext()
    await #expect(throws: RecordStoreError.persistenceUnavailable) {
      _ = try await RecordStore(persistence: persistence, currentDate: clock.now).bufferSnapshot()
    }
    let upgraded = RecordStore(persistence: persistence, currentDate: clock.now)
    #expect(try await upgraded.entries(in: RecordBuffer.speechID).first?.enqueuedAt == upgradeDate)
    clock.advance(BufferEntry.pendingLifetime - 1)
    let reopened = RecordStore(persistence: persistence, currentDate: clock.now)
    #expect(try await reopened.bufferSnapshot().next?.id == id)
    clock.advance(1)
    #expect(try await reopened.bufferItems().isEmpty)
  }

  @Test(arguments: [BufferEntry.pendingLifetime - 1, BufferEntry.pendingLifetime])
  func explicitSendRenewsADraftBeforeReleasingItsEditor(age: TimeInterval) async throws {
    let clock = BufferDateClock(start)
    let persistence = BufferCatalogFake()
    let store = RecordStore(persistence: persistence, currentDate: clock.now)
    let id = try await append("send this", store: store)
    let session = UUID()
    let draft = try await store.openBufferDraft(id, editingSessionID: session)
    clock.advance(age)
    try await store.expireBufferEntries()
    await persistence.rejectNext()
    await #expect(throws: RecordStoreError.persistenceUnavailable) {
      try await store.commitBufferDraft(id, draftID: draft.id, expectedRevision: draft.revision)
    }
    #expect(try await store.entries(in: id.bufferID).first?.enqueuedAt == start)
    try await store.commitBufferDraft(id, draftID: draft.id, expectedRevision: draft.revision)
    await store.closeBufferEditingSession(session)
    clock.advance(1)
    #expect(try await store.beginBufferOutput(manualEntryID: id).record.payload.textValue == "send this")
    try await store.finishBufferOutput(id)
    #expect(try await store.bufferItems().isEmpty)
  }

  @Test func retryPinSurvivesExpiryAndReleasingItRestoresExpiry() async throws {
    let clock = BufferDateClock(start)
    let store = RecordStore(currentDate: clock.now)
    let first = try await append("retry", store: store)
    _ = try await store.beginBufferOutput()
    clock.advance(BufferEntry.pendingLifetime)
    try await store.retryBufferOutput(first, keepSelected: true)
    try await store.expireBufferEntries()
    #expect(try await store.bufferSnapshot().next?.id == first)
    let second = try await append("new selection", store: store)
    try await store.requestBufferEntry(second)
    try await store.expireBufferEntries()
    #expect(try await store.bufferDraft(for: first) == nil)
    #expect(try await store.bufferSnapshot().next?.id == second)
  }

  @Test func reenqueuingAnExpiredSetEntryCreatesANewPendingLifetime() async throws {
    let clock = BufferDateClock(start)
    let store = RecordStore(currentDate: clock.now)
    let reusable = RecordBuffer(name: "Reusable", policy: .set)
    try await store.updateBuffer(reusable)
    let record = try await store.ingest(
      .init(payload: .text("reuse"), provenance: .init(source: .init(kind: .user))), into: [])
    let first = try await store.enqueueRecord(record.id, in: reusable.id)
    #expect(try await store.enqueueRecord(record.id, in: reusable.id) == first)
    clock.advance(BufferEntry.pendingLifetime)
    let second = try await store.enqueueRecord(record.id, in: reusable.id)
    #expect(second != first)
    let entries = try await store.entries(in: reusable.id)
    #expect(entries.map(\.id) == [second])
    #expect(entries.first?.enqueuedAt == clock.now())
    #expect(try await store.beginBufferOutput(manualEntryID: second).record.id == record.id)
  }

  @Test(arguments: [true, false]) func settlingAnotherManualOutputReleasesAnOverdueRetryPin(finishes: Bool) async throws {
    let clock = BufferDateClock(start)
    let store = RecordStore(currentDate: clock.now)
    let pinned = try await append("selected", store: store)
    let manual = try await append("manual output", store: store)
    try await store.requestBufferEntry(pinned)
    _ = try await store.beginBufferOutput(manualEntryID: manual)
    clock.advance(BufferEntry.pendingLifetime)
    try await store.expireBufferEntries()
    if finishes { try await store.finishBufferOutput(manual) } else { try await store.retryBufferOutput(manual) }
    try await store.expireBufferEntries()
    #expect(try await store.bufferItems().isEmpty)
  }

  @Test func switchingEditorsAndFinishingReusableOutputReleasesExpiryProtection() async throws {
    let clock = BufferDateClock(start)
    let store = RecordStore(currentDate: clock.now)
    let first = try await append("first editor", store: store)
    _ = try await store.openBufferDraft(first, editingSessionID: UUID())
    let reusable = RecordBuffer(name: "Reusable", policy: .set)
    try await store.updateBuffer(reusable)
    let record = try #require(try await store.snapshot().records.first)
    let retained = try await store.enqueueRecord(record.id, in: reusable.id)
    _ = try await store.beginBufferOutput(manualEntryID: retained)
    clock.advance(BufferEntry.pendingLifetime)
    try await store.expireBufferEntries()
    let second = try await append("second editor", store: store)
    _ = try await store.openBufferDraft(second, editingSessionID: UUID())
    try await store.finishBufferOutput(retained)
    try await store.expireBufferEntries()
    #expect(Set(try await store.bufferItems().map(\.id)) == [second])
    #expect(try await store.record(id: record.id)?.activity.useCount == 1)
  }
}
