import Foundation
import RillCore
import RillRecords
import Testing
@testable import RillUI

private final class PendingBufferTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date = Date(timeIntervalSince1970: 1_000_000)
  func now() -> Date { lock.withLock { date } }
  func advance() { lock.withLock { date.addTimeInterval(BufferEntry.pendingLifetime) } }
}

@MainActor struct RecordBufferMaintenanceTests {
  private func append(to store: RecordStore) async throws -> BufferEntryID {
    let id = try await store.reserveBufferInput(in: RecordBuffer.speechID)
    _ = try await store.ingest(
      .init(payload: .text("original"), provenance: .init(source: .init(kind: .voiceInput))),
      into: [], fulfilling: id, recognitionText: "original")
    return id
  }

  @Test func periodicMaintenanceExpiresEntriesWithoutOpeningThePanelAndDrainsOnShutdown() async throws {
    let date = PendingBufferTestClock()
    let sleeper = HistoryMaintenanceClock()
    let store = RecordStore(currentDate: date.now)
    let id = try await append(to: store)
    let model = RecordBufferModel(store: store, maintenanceSleep: sleeper.sleep)
    model.start()
    await sleeper.waitUntilSleeping()
    date.advance()
    await sleeper.advance()
    await sleeper.waitUntilSleeping()
    // Reading the draft does not itself trigger expiry.
    #expect(try await store.bufferDraft(for: id) == nil)
    #expect(try await store.snapshot().records.count == 1)
    await model.shutdown()
    #expect(await sleeper.pendingCount == 0)
  }

  @Test func closingWithMarkedTextKeepsExpiryProtectionUntilTheEditIsSavedAndSent() async throws {
    let date = PendingBufferTestClock()
    let store = RecordStore(currentDate: date.now)
    let id = try await append(to: store)
    let model = RecordBufferDraftModel(store: store)
    model.open()
    await model.refresh()
    model.select(id)
    await model.waitForPendingWrites()
    let session = try #require(model.session)
    session.hasMarkedText = true
    model.edit("beijing", sessionID: session.id)
    model.close()
    await model.waitForPendingWrites()
    date.advance()
    try await store.expireBufferEntries()
    #expect(try await store.bufferDraft(for: id)?.text == "original")
    #expect(session.text == "beijing")
    model.open()
    await model.waitForPendingWrites()
    session.hasMarkedText = false
    model.edit("北京", sessionID: session.id)
    model.close()
    await model.waitForPendingWrites()
    try await store.expireBufferEntries()
    #expect(try await store.bufferDraft(for: id)?.text == "北京")
    model.open()
    await model.waitForPendingWrites()
    var sent: BufferEntryID?
    model.sendAction = { sent = $0 }
    model.send()
    await model.waitForPendingWrites()
    #expect(sent == id)
    #expect(try await store.beginBufferOutput(manualEntryID: id).record.payload.textValue == "北京")
    try await store.finishBufferOutput(id)
    await model.shutdown()
  }
}
