import XCTest

@testable import RillCore
@testable import RillUI

private actor BenchmarkArchiveActionProbe {
  private(set) var refreshValues: [Bool] = []
  private(set) var clearCount = 0

  func refresh(_ isEnabled: Bool) {
    refreshValues.append(isEnabled)
  }

  func clear() {
    clearCount += 1
  }
}

@MainActor
final class AppModelBenchmarkRecordingArchiveTests: XCTestCase {
  func testArchiveIsDefaultOffAndPersistsExplicitChanges() async throws {
    let settingsStore = UITestSettingsStore()
    let probe = BenchmarkArchiveActionProbe()
    let harness = makeHarness(
      settingsStore: settingsStore,
      refreshBenchmarkRecordingArchiveAction: { isEnabled in
        await probe.refresh(isEnabled)
      }
    )
    await harness.model.waitForInitialVoiceConfiguration()

    XCTAssertFalse(harness.model.benchmarkArchive.isEnabled)

    harness.model.benchmarkArchive.setEnabled(true)
    await harness.model.flushPendingPersistenceWrites()
    XCTAssertTrue(harness.model.benchmarkArchive.isEnabled)
    let enabledValue = try await settingsStore.string(
      forKey: .benchmarkRecordingArchiveEnabled
    )
    XCTAssertEqual(enabledValue, "true")

    harness.model.benchmarkArchive.setEnabled(false)
    await harness.model.flushPendingPersistenceWrites()
    XCTAssertFalse(harness.model.benchmarkArchive.isEnabled)
    let disabledValue = try await settingsStore.string(
      forKey: .benchmarkRecordingArchiveEnabled
    )
    XCTAssertEqual(disabledValue, "false")
    let refreshValues = await probe.refreshValues
    XCTAssertEqual(refreshValues, [true, false])
  }

  func testStoredOptInLoadsWithoutRewritingSetting() async {
    let settingsStore = UITestSettingsStore(
      storage: [.benchmarkRecordingArchiveEnabled: "true"]
    )
    let harness = makeHarness(settingsStore: settingsStore)

    await harness.model.waitForInitialVoiceConfiguration()

    XCTAssertTrue(harness.model.benchmarkArchive.isEnabled)
    let activity = await settingsStore.activitySnapshot()
    XCTAssertNil(activity.setCounts[.benchmarkRecordingArchiveEnabled])
  }

  func testEnableFailureRollsBackDurableOptIn() async throws {
    let settingsStore = UITestSettingsStore()
    let harness = makeHarness(
      settingsStore: settingsStore,
      refreshBenchmarkRecordingArchiveAction: { isEnabled in
        if isEnabled {
          throw BenchmarkRecordingArchiveError.storageUnavailable
        }
      }
    )
    await harness.model.waitForInitialVoiceConfiguration()

    harness.model.benchmarkArchive.setEnabled(true)
    await harness.model.flushPendingPersistenceWrites()

    XCTAssertFalse(harness.model.benchmarkArchive.isEnabled)
    XCTAssertNotNil(harness.model.benchmarkArchive.error)
    let persistedValue = try await settingsStore.string(
      forKey: .benchmarkRecordingArchiveEnabled
    )
    XCTAssertEqual(persistedValue, "false")
  }

  func testRollbackWriteFailureKeepsDurablePreferenceVisibleAndAllowsRetry() async throws {
    let settingsStore = RollbackFailingArchiveSettingsStore()
    let probe = BenchmarkArchiveActionProbe()
    let harness = makeHarness(settingsStore: settingsStore,
      refreshBenchmarkRecordingArchiveAction: { enabled in
        await probe.refresh(enabled)
        if enabled { throw BenchmarkRecordingArchiveError.storageUnavailable }
      })
    await harness.model.waitForInitialVoiceConfiguration()
    harness.model.setInterfaceLanguage(.english)
    harness.model.benchmarkArchive.setEnabled(true)
    await harness.model.flushPendingPersistenceWrites()
    XCTAssertTrue(harness.model.benchmarkArchive.isEnabled)
    let persisted1 = try await settingsStore.string(forKey: .benchmarkRecordingArchiveEnabled)
    XCTAssertEqual(persisted1, "true")
    XCTAssertTrue(harness.model.benchmarkArchive.error?.contains("No new benchmark audio") == true)
    let disabledRuntime = await probe.refreshValues
    XCTAssertEqual(disabledRuntime.suffix(2), [true, false])
    harness.model.benchmarkArchive.setEnabled(false)
    await harness.model.flushPendingPersistenceWrites()
    XCTAssertFalse(harness.model.benchmarkArchive.isEnabled)
    let persisted2 = try await settingsStore.string(forKey: .benchmarkRecordingArchiveEnabled)
    XCTAssertEqual(persisted2, "false")
    XCTAssertNil(harness.model.benchmarkArchive.error)
  }

  func testDisableRemainsDurablyOffWhenRuntimeCleanupFails() async throws {
    let settingsStore = UITestSettingsStore(storage: [.benchmarkRecordingArchiveEnabled: "true"])
    let harness = makeHarness(settingsStore: settingsStore,
      refreshBenchmarkRecordingArchiveAction: { _ in throw BenchmarkRecordingArchiveError.storageUnavailable })
    await harness.model.waitForInitialVoiceConfiguration()
    harness.model.benchmarkArchive.setEnabled(false)
    await harness.model.flushPendingPersistenceWrites()
    XCTAssertFalse(harness.model.benchmarkArchive.isEnabled)
    let persisted3 = try await settingsStore.string(forKey: .benchmarkRecordingArchiveEnabled)
    XCTAssertEqual(persisted3, "false")
    XCTAssertNotNil(harness.model.benchmarkArchive.error)
  }

  func testClearRequiresExplicitActionAndKeepsRetentionPreference() async {
    let settingsStore = UITestSettingsStore(
      storage: [.benchmarkRecordingArchiveEnabled: "true"]
    )
    let probe = BenchmarkArchiveActionProbe()
    let harness = makeHarness(
      settingsStore: settingsStore,
      clearBenchmarkRecordingArchiveAction: {
        await probe.clear()
      }
    )
    await harness.model.waitForInitialVoiceConfiguration()

    harness.model.benchmarkArchive.clear()
    await harness.model.flushPendingPersistenceWrites()

    let clearCount = await probe.clearCount
    XCTAssertEqual(clearCount, 1)
    XCTAssertTrue(harness.model.benchmarkArchive.isEnabled)
  }
}

private actor RollbackFailingArchiveSettingsStore: SettingsStore {
  var storage: [AppSettingKey: String] = [:]
  var archiveWrites = 0
  func string(forKey key: AppSettingKey) async throws -> String? { storage[key] }
  func strings(forKeys keys: [AppSettingKey]) async throws -> [AppSettingKey: String] {
    storage.filter { keys.contains($0.key) }
  }
  func setString(_ value: String, forKey key: AppSettingKey) async throws {
    if key == .benchmarkRecordingArchiveEnabled {
      archiveWrites += 1
      if archiveWrites == 2 { throw UITestSettingsStoreError.requestedFailure }
    }
    storage[key] = value
  }
  func setStringsAtomically(_ values: [AppSettingKey: String]) async throws {
    storage.merge(values) { _, latest in latest }
  }
  func removeValue(forKey key: AppSettingKey) async throws { storage.removeValue(forKey: key) }
}
