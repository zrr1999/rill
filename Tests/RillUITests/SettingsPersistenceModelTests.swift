import XCTest

@testable import RillCore
@testable import RillUI

private actor SettingsWriteGate {
  private var entered = false
  private var observers: [CheckedContinuation<Void, Never>] = []
  private var release: CheckedContinuation<Void, Never>?

  func suspend() async {
    entered = true
    observers.forEach { $0.resume() }
    observers.removeAll()
    await withCheckedContinuation { release = $0 }
  }

  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { observers.append($0) }
  }

  func resume() {
    release?.resume()
    release = nil
  }
}

@MainActor
final class SettingsPersistenceModelTests: XCTestCase {
  func testFailedTransactionRetriesWithoutOverwritingNewerUserEdit() async throws {
    let store = UITestSettingsStore()
    let model = SettingsPersistenceModel(store: store, language: .english)
    await store.rejectNextAtomicWrite()
    model.submitAtomically([
      .workflowLibrary: .init(category: .workflows) { "migrated-workflows" },
      .vocabularyLibrary: .init(category: .vocabulary) { "migrated-vocabulary" },
    ], onFailure: {})
    await model.writes.flush()
    XCTAssertTrue(model.hasUnsavedWrites)
    let failed = await store.activitySnapshot()
    XCTAssertTrue(failed.storage.isEmpty)

    model.submit(
      key: .workflowLibrary, category: .workflows, debounce: .zero,
      operation: { try await $0.setString("user-edit", forKey: .workflowLibrary) },
      onFailure: { XCTFail("The user edit should succeed") })
    model.retry(onFailure: { XCTFail("The remaining migration should retry") })
    await model.writes.flush()
    let saved = await store.activitySnapshot()
    XCTAssertEqual(saved.storage[.workflowLibrary], "user-edit")
    XCTAssertEqual(saved.storage[.vocabularyLibrary], "migrated-vocabulary")
    XCTAssertEqual(model.saveState, .saved)
  }

  func testFailedTransactionRetriesAllKeysInOneWrite() async throws {
    let store = UITestSettingsStore()
    let model = SettingsPersistenceModel(store: store, language: .english)
    await store.rejectNextAtomicWrite()
    model.submitAtomically([
      .workflowLibrary: .init(category: .workflows) { "workflows" },
      .vocabularyLibrary: .init(category: .vocabulary) { "vocabulary" },
    ], onFailure: {})
    await model.writes.flush()
    model.retry(onFailure: { XCTFail("Retry should succeed") })
    await model.writes.flush()
    let saved = await store.activitySnapshot()
    XCTAssertEqual(saved.atomicSnapshots, [[
      .workflowLibrary: "workflows", .vocabularyLibrary: "vocabulary",
    ]])
    XCTAssertEqual(model.saveState, .saved)
  }

  func testRetryCannotReplaceNewerInFlightWriteWithOldFailedSnapshot() async throws {
    let store = UITestSettingsStore()
    let model = SettingsPersistenceModel(store: store, language: .english)
    let gate = SettingsWriteGate()
    model.submit(
      key: .interfaceLanguage, category: .interface, debounce: .zero,
      operation: { _ in throw UITestSettingsStoreError.requestedFailure }, onFailure: {})
    await model.writes.flush()
    model.submit(
      key: .interfaceLanguage, category: .interface, debounce: .zero,
      operation: { store in
        await gate.suspend()
        try await store.setString("newest", forKey: .interfaceLanguage)
      }, onFailure: { XCTFail("The replacement write should succeed") })
    await gate.waitUntilEntered()
    model.retry(onFailure: { XCTFail("The failed snapshot must not be retried over a newer write") }
    )
    await gate.resume()
    await model.writes.flush()
    let stored = try await store.string(forKey: .interfaceLanguage)
    XCTAssertEqual(stored, "newest")
    XCTAssertEqual(model.saveState, .saved)
  }
}
