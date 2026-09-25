@testable import RillRecords
import XCTest

@testable import RillCore
@testable import RillUI

@MainActor
final class RecordShutdownTests: XCTestCase {
  func testWorkspaceShutdownDrainsAcceptedMetadataAndRejectsNewEdits() async throws {
    let persistence = SuspendedRecordWrite()
    let store = RecordStore(persistence: persistence)
    let record = try await store.ingest(draft, into: [])
    let model = RecordWorkspaceModel(store: store)
    await model.refresh()
    await persistence.arm()
    let edit = Task { await model.updateMetadata(for: record, isPinned: true) }
    await persistence.waitUntilBlocked()
    model.sealMutations()
    var didBegin = false
    var didFinish = false
    let shutdown = Task {
      didBegin = true
      await model.shutdown()
      didFinish = true
    }
    while !didBegin { await Task.yield() }
    XCTAssertFalse(didFinish)
    await model.createCollection(name: "rejected after seal", preset: .list)
    await persistence.release()
    await edit.value
    await shutdown.value
    let final = try await store.catalogSnapshot()
    XCTAssertTrue(final.records.first?.metadata.isPinned == true)
    XCTAssertFalse(final.collections.contains { $0.name == "rejected after seal" })
  }

  func testWorkspaceShutdownWaitsForConfirmedCollectionDeletion() async throws {
    let persistence = SuspendedRecordWrite()
    let store = RecordStore(persistence: persistence)
    let collection = try await store.createCollection(name: "delete after review")
    let model = RecordWorkspaceModel(store: store)
    await model.requestCollectionDeletion(collection.id)
    await persistence.arm()
    let deletion = Task { await model.confirmCollectionDeletion(collection.id, resolution: nil) }
    await persistence.waitUntilBlocked()
    var didBegin = false
    var didFinish = false
    let shutdown = Task {
      didBegin = true
      await model.shutdown()
      didFinish = true
    }
    while !didBegin { await Task.yield() }
    XCTAssertFalse(didFinish)
    await persistence.release()
    await deletion.value
    await shutdown.value
    let final = try await store.catalogSnapshot()
    XCTAssertFalse(final.collections.contains { $0.id == collection.id })
  }

  func testQuickPanelShutdownDrainsAcceptedPinAndClosesMutationEntry() async throws {
    let persistence = SuspendedRecordWrite()
    let store = RecordStore(persistence: persistence)
    _ = try await store.ingest(draft, into: [])
    let catalog = try await store.catalogSnapshot()
    let item = try XCTUnwrap(catalog.records.first)
    let model = RecordQuickPanelModel(store: store)
    await persistence.arm()
    let pin = Task { await model.togglePin(item) }
    await persistence.waitUntilBlocked()
    var didBegin = false
    var didFinish = false
    let shutdown = Task {
      didBegin = true
      await model.shutdown()
      didFinish = true
    }
    while !didBegin { await Task.yield() }
    XCTAssertFalse(didFinish)
    await persistence.release()
    await pin.value
    await shutdown.value
    let pinned = try await store.catalogSnapshot()
    let updated = try XCTUnwrap(pinned.records.first)
    await model.togglePin(updated)
    let final = try await store.catalogSnapshot()
    XCTAssertTrue(final.records.first?.metadata.isPinned == true)
  }

  private var draft: RecordDraft {
    .init(
      payload: .text("finish accepted work"),
      provenance: .init(source: .init(kind: .systemClipboard)))
  }
}

private actor SuspendedRecordWrite: RecordGraphPersistenceStore {
  private var revision: Int64 = 0
  private var shouldBlock = false
  private var blockedWrite: CheckedContinuation<Void, Never>?
  private var startedWaiters: [CheckedContinuation<Void, Never>] = []

  func arm() { shouldBlock = true }
  func waitUntilBlocked() async {
    guard blockedWrite == nil else { return }
    await withCheckedContinuation { startedWaiters.append($0) }
  }
  func release() {
    blockedWrite?.resume()
    blockedWrite = nil
  }
  func loadRecordGraph() async throws -> RecordGraphPersistenceReadSnapshot { .empty }
  func removeRecordGraph() async throws -> RecordGraphRemovalResult { .removed }
  func replaceRecordGraph(with snapshot: RecordGraphPersistenceWriteSnapshot) async throws -> Int64
  {
    if shouldBlock {
      shouldBlock = false
      await withCheckedContinuation { continuation in
        blockedWrite = continuation
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
      }
    }
    revision += 1
    return revision
  }
}
