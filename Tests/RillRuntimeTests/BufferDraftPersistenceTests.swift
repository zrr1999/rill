import Foundation
import RillCore
import RillPersistence
import RillRecords
import Testing

struct BufferDraftPersistenceTests {
  @Test func serializedDraftLimitRejectsWithoutChangingSavedText() async throws {
    let store = RecordStore()
    let id = try await store.createBufferDraft(text: "keep me")
    let draft = try #require(try await store.bufferDraft(for: id))
    // Control characters fit the text limit but expand sixfold in JSON.
    let escapedText = String(repeating: "\u{0001}", count: 400_000)
    await #expect(throws: RecordStoreError.payloadLimitReached) {
      _ = try await store.saveBufferDraft(id, draftID: draft.id, expectedRevision: 0, text: escapedText)
    }
    #expect(try await store.bufferDraft(for: id)?.text == "keep me")
  }

  @Test func emptyFirstDraftAndEditsRoundTripThroughEncryptedSQLite() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rill-draft-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("records.sqlite")
    let protector = try AESGCMDataProtector(key: Data(repeating: 0x47, count: AESGCMDataProtector.keyByteCount))
    let database = try SQLitePersistenceStore(databaseURL: url, localDataProtector: protector)
    let store = RecordStore(persistence: database)
    let id = try await store.createBufferDraft()
    let restoredEmpty = RecordStore(persistence: database)
    let draft = try #require(try await restoredEmpty.bufferDraft(for: id))
    #expect(draft.text.isEmpty)
    let text = "private-draft-sentinel-\(UUID())"
    _ = try await restoredEmpty.saveBufferDraft(id, draftID: draft.id, expectedRevision: 0, text: text)
    let reopened = RecordStore(persistence: database)
    #expect(try await reopened.bufferDraft(for: id)?.text == text)
    try await reopened.commitBufferDraft(id, draftID: draft.id, expectedRevision: 1)
    #expect(try await RecordStore(persistence: database).bufferDraft(for: id)?.committedRevision == 1)
    for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    where file.lastPathComponent.hasPrefix("records.sqlite") {
      #expect(try Data(contentsOf: file).range(of: Data(text.utf8)) == nil)
    }
  }
}
