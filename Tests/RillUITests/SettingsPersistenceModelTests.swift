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
  func testRetryCannotReplaceNewerInFlightWriteWithOldFailedSnapshot() async throws {
    let store = UITestSettingsStore()
    let model = SettingsPersistenceModel(store: store)
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
