import Foundation
import RillCore
import RillRecords
import Testing

struct RecordBufferDraftTests {
  private func capture(_ text: String, runID: UUID? = nil) -> RecordDraft {
    .init(payload: .text(text), provenance: .init(source: .init(kind: .workflow), workflowRunID: runID))
  }

  @Test func newDraftReservesItsSequenceBeforeSlowPersistence() async throws {
    let persistence = BufferCatalogFake()
    let store = RecordStore(persistence: persistence)
    _ = try await store.ingest(capture("history"), into: [])
    let started = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    defer { release.continuation.finish() }
    await persistence.beforeNextCommit {
      started.continuation.finish()
      for await _ in release.stream {}
    }
    let creating = Task { try await store.createBufferDraft(text: "manual draft") }
    for await _ in started.stream {}
    let speech = try await store.observeBufferInput(in: RecordBuffer.speechID)
    release.continuation.finish()
    let id = try await creating.value
    try await speech.committed.value
    #expect(id.sequence < speech.id.sequence)
    _ = try await store.ingest(capture("new speech"), into: [], fulfilling: speech.id)
    let restored = RecordStore(persistence: persistence)
    #expect(try await restored.entries(in: RecordBuffer.speechID).map(\.id) == [id, speech.id])
    #expect(try await restored.bufferDraft(for: id)?.text == "manual draft")
  }

  @Test func catalogUpgradeAndFirstDraftCommitAreAtomic() async throws {
    let persistence = BufferCatalogFake()
    let original = RecordStore(persistence: persistence)
    let record = try await original.ingest(capture("old pending text"), into: [])
    let id = try await original.enqueueRecord(record.id, in: RecordBuffer.speechID)
    try await persistence.setCatalogVersion(3)
    let store = RecordStore(persistence: persistence)
    await persistence.rejectNext()
    await #expect(throws: RecordStoreError.persistenceUnavailable) {
      _ = try await store.openBufferDraft(id, editingSessionID: UUID())
    }
    #expect(await persistence.manifest?.schemaVersion == 3)
    #expect(try await store.bufferDraft(for: id) == nil)
    let draft = try await store.openBufferDraft(id, editingSessionID: UUID())
    #expect(await persistence.manifest?.schemaVersion == 4)
    #expect(try await RecordStore(persistence: persistence).bufferDraft(for: id) == draft)
  }

  @Test func committingAfterColdReadPreservesNewSpeechSuggestions() async throws {
    let persistence = BufferCatalogFake()
    let original = RecordStore(persistence: persistence)
    let id = try await original.reserveBufferInput(in: RecordBuffer.speechID)
    _ = try await original.ingest(capture("original"), into: [], fulfilling: id, recognitionText: "original")
    let draft = try #require(try await original.bufferDraft(for: id))
    _ = try await original.saveBufferDraft(id, draftID: draft.id, expectedRevision: 0, text: "edited")
    let store = RecordStore(persistence: persistence)
    let started = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    defer { release.continuation.finish() }
    await persistence.beforeNextPayloadRead {
      started.continuation.finish()
      for await _ in release.stream {}
    }
    let commit = Task { try await store.commitBufferDraft(id, draftID: draft.id, expectedRevision: 1) }
    for await _ in started.stream {}
    let runID = UUID()
    _ = try await store.ingestBufferDictation(
      capture("late speech", runID: runID),
      recognitionText: "late speech",
      for: .init(
        entryID: id, draftID: draft.id, revision: 1,
        selection: .init(location: 0), editingSessionID: UUID()))
    release.continuation.finish()
    try await commit.value
    let committed = try #require(try await store.bufferDraft(for: id))
    #expect(committed.text == "edited")
    #expect(committed.suggestions.map(\.id) == [runID])
    #expect(committed.receivedInputIDs == [runID])
    #expect(committed.committedRevision == 1)
  }

  @Test func editsSurviveRestartAndReplaceOnlyTheirExactBufferPosition() async throws {
    let persistence = BufferCatalogFake()
    let store = RecordStore(persistence: persistence)
    let entry = try await store.reserveBufferInput(in: RecordBuffer.speechID)
    let original = try await store.ingest(
      capture("去北京开会"), into: [RecordCollection.voiceInputID],
      fulfilling: entry, recognitionText: "去背景开会")
    let second = try await store.reserveBufferInput(in: RecordBuffer.speechID)
    _ = try await store.ingest(capture("下一条"), into: [], fulfilling: second)
    let editing = UUID()
    let draft = try await store.openBufferDraft(entry, editingSessionID: editing)
    let updated = try await store.saveBufferDraft(
      entry, draftID: draft.id,
      expectedRevision: draft.revision, text: "去上海开会\n明天出发")
    await #expect(throws: BufferOutputError.editing) { _ = try await store.beginBufferOutput() }
    await store.closeBufferEditingSession(editing)
    let restored = RecordStore(persistence: persistence)
    #expect(try await restored.bufferDraft(for: entry)?.text == updated.text)
    #expect(try await restored.bufferDraft(for: entry)?.recognitionText == "去背景开会")
    try await restored.commitBufferDraft(entry, draftID: draft.id, expectedRevision: updated.revision)
    let entries = try await restored.entries(in: RecordBuffer.speechID)
    #expect(entries.map(\.id) == [entry, second])
    #expect(entries.first?.recordID != original.id)
    #expect(try await restored.record(id: original.id)?.record.payload.textValue == "去北京开会")
    #expect(try await restored.record(id: original.id)?.memberships == original.memberships)
    let output = try await restored.beginBufferOutput()
    #expect(output.entry.id == entry)
    #expect(output.record.payload.textValue == updated.text)
    #expect(output.record.provenance.derivedFrom == original.id)
    #expect(try await restored.record(id: output.record.id)?.memberships.isEmpty == true)
    try await restored.finishBufferOutput(entry)
    #expect(try await restored.bufferSnapshot().next?.id == second)
  }

  @Test func saveAndDerivationFailuresRollBackBothTextAndGraph() async throws {
    let persistence = BufferCatalogFake()
    let store = RecordStore(persistence: persistence)
    let id = try await store.createBufferDraft()
    let draft = try #require(try await store.bufferDraft(for: id))
    await persistence.rejectNext()
    await #expect(throws: RecordStoreError.persistenceUnavailable) {
      _ = try await store.saveBufferDraft(id, draftID: draft.id, expectedRevision: 0, text: "修改")
    }
    #expect(try await store.bufferDraft(for: id)?.text == "")
    let saved = try await store.saveBufferDraft(id, draftID: draft.id, expectedRevision: 0, text: "修改")
    await persistence.rejectNext()
    await #expect(throws: RecordStoreError.persistenceUnavailable) {
      try await store.commitBufferDraft(id, draftID: draft.id, expectedRevision: saved.revision)
    }
    #expect(try await store.catalogSnapshot().records.isEmpty)
    #expect(try await store.bufferDraft(for: id)?.needsCommit == true)
    #expect(try await store.entries(in: RecordBuffer.speechID).first?.recordID == nil)
    let restored = RecordStore(persistence: persistence)
    try await restored.commitBufferDraft(id, draftID: draft.id, expectedRevision: saved.revision)
    try await restored.commitBufferDraft(id, draftID: draft.id, expectedRevision: saved.revision)
    #expect(try await restored.catalogSnapshot().records.count == 1)
  }

  @Test func inputIntentKeepsItsDestinationAndLateResultIsReviewable() async throws {
    let persistence = BufferCatalogFake()
    let store = RecordStore(persistence: persistence)
    let first = try await store.createBufferDraft()
    let session = UUID()
    let draft = try await store.openBufferDraft(first, editingSessionID: session)
    let saved = try await store.saveBufferDraft(first, draftID: draft.id, expectedRevision: 0, text: "去北京")
    let intent = BufferDraftInputIntent(
      entryID: first, draftID: draft.id, revision: saved.revision,
      selection: .init(location: 1, length: 2), editingSessionID: session)
    _ = try await store.saveBufferDraft(first, draftID: draft.id, expectedRevision: saved.revision, text: "去南京")
    let second = try await store.createBufferDraft()
    _ = try await store.openBufferDraft(second, editingSessionID: UUID())
    let runID = UUID()
    let recognition = capture("上海", runID: runID)
    let result = try await store.ingestBufferDictation(recognition, recognitionText: "伤害", for: intent)
    let pending = try #require(try await store.bufferDraft(for: first))
    #expect(pending.text == "去南京")
    #expect(pending.suggestions.first?.text == "上海")
    #expect(pending.suggestions.first?.recognitionText == "伤害")
    #expect(try await store.bufferDraft(for: second)?.text == "")
    #expect(try await store.bufferItems().count == 2)
    #expect(result.memberships.isEmpty)
    let duplicate = try await store.ingestBufferDictation(recognition, recognitionText: "伤害", for: intent)
    #expect(duplicate.id == result.id)
    let restored = RecordStore(persistence: persistence)
    let applied = try await restored.resolveBufferSuggestion(
      runID, in: first, draftID: draft.id,
      expectedRevision: pending.revision, insertingAt: .init(location: 1, length: 2))
    #expect(applied.text == "去上海")
    #expect(applied.suggestions.isEmpty)
    #expect(try await restored.entries(in: RecordBuffer.speechID).map(\.id) == [first, second])
  }

  @Test func dictatedRecordAndSuggestionAreAtomicAndRemovedDraftCannotResurrect() async throws {
    let persistence = BufferCatalogFake()
    let store = RecordStore(persistence: persistence)
    let id = try await store.createBufferDraft()
    let draft = try #require(try await store.bufferDraft(for: id))
    let intent = BufferDraftInputIntent(
      entryID: id, draftID: draft.id, revision: 0,
      selection: .init(location: 0), editingSessionID: UUID())
    await persistence.rejectNext()
    await #expect(throws: RecordStoreError.persistenceUnavailable) {
      _ = try await store.ingestBufferDictation(capture("speech", runID: UUID()), recognitionText: "speech", for: intent)
    }
    #expect(try await store.catalogSnapshot().records.isEmpty)
    #expect(try await store.bufferDraft(for: id)?.suggestions.isEmpty == true)
    try await store.discardBufferEntry(id)
    await #expect(throws: BufferDraftError.changed) {
      _ = try await store.ingestBufferDictation(capture("late", runID: UUID()), recognitionText: "late", for: intent)
    }
    #expect(try await RecordStore(persistence: persistence).bufferItems().isEmpty)
  }

  @Test func staleWritesAndActiveDeliveryCannotChangeOutput() async throws {
    let store = RecordStore()
    let id = try await store.createBufferDraft()
    let draft = try #require(try await store.bufferDraft(for: id))
    _ = try await store.saveBufferDraft(id, draftID: draft.id, expectedRevision: 0, text: "fixed")
    await #expect(throws: BufferDraftError.changed) {
      _ = try await store.saveBufferDraft(id, draftID: draft.id, expectedRevision: 0, text: "stale")
    }
    try await store.commitBufferDraft(id, draftID: draft.id, expectedRevision: 1)
    _ = try await store.beginBufferOutput()
    await #expect(throws: BufferDraftError.changed) {
      _ = try await store.saveBufferDraft(id, draftID: draft.id, expectedRevision: 1, text: "racing")
    }
    await #expect(throws: BufferOutputError.busy) { try await store.discardBufferEntry(id) }
    #expect(try await store.bufferDraft(for: id)?.text == "fixed")
  }
}
