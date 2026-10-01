import XCTest

@testable import RillCore
@testable import RillUI

private actor CorpusArchiveActionProbe {
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
final class AppModelCorpusRecordingArchiveTests: XCTestCase {
  func testArchiveIsDefaultOffAndPersistsExplicitChanges() async throws {
    let settingsStore = UITestSettingsStore()
    let probe = CorpusArchiveActionProbe()
    let harness = makeHarness(
      settingsStore: settingsStore,
      refreshCorpusRecordingArchiveAction: { isEnabled in
        await probe.refresh(isEnabled)
      }
    )
    await harness.model.waitForInitialVoiceConfiguration()

    XCTAssertFalse(harness.model.corpusArchive.isEnabled)

    harness.model.corpusArchive.setEnabled(true)
    await harness.model.flushPendingPersistenceWrites()
    XCTAssertTrue(harness.model.corpusArchive.isEnabled)
    let enabledValue = try await settingsStore.string(
      forKey: .corpusRecordingArchiveEnabled
    )
    XCTAssertEqual(enabledValue, "true")

    harness.model.corpusArchive.setEnabled(false)
    await harness.model.flushPendingPersistenceWrites()
    XCTAssertFalse(harness.model.corpusArchive.isEnabled)
    let disabledValue = try await settingsStore.string(
      forKey: .corpusRecordingArchiveEnabled
    )
    XCTAssertEqual(disabledValue, "false")
    let refreshValues = await probe.refreshValues
    XCTAssertEqual(refreshValues, [true, false])
  }

  func testStoredOptInLoadsWithoutRewritingSetting() async {
    let settingsStore = UITestSettingsStore(
      storage: [.corpusRecordingArchiveEnabled: "true"]
    )
    let harness = makeHarness(settingsStore: settingsStore)

    await harness.model.waitForInitialVoiceConfiguration()

    XCTAssertTrue(harness.model.corpusArchive.isEnabled)
    let activity = await settingsStore.activitySnapshot()
    XCTAssertNil(activity.setCounts[.corpusRecordingArchiveEnabled])
  }

  func testEnableFailureRollsBackDurableOptIn() async throws {
    let settingsStore = UITestSettingsStore()
    let harness = makeHarness(
      settingsStore: settingsStore,
      refreshCorpusRecordingArchiveAction: { isEnabled in
        if isEnabled {
          throw CorpusRecordingArchiveError.storageUnavailable
        }
      }
    )
    await harness.model.waitForInitialVoiceConfiguration()

    harness.model.corpusArchive.setEnabled(true)
    await harness.model.flushPendingPersistenceWrites()

    XCTAssertFalse(harness.model.corpusArchive.isEnabled)
    XCTAssertNotNil(harness.model.corpusArchive.error)
    let persistedValue = try await settingsStore.string(
      forKey: .corpusRecordingArchiveEnabled
    )
    XCTAssertEqual(persistedValue, "false")
  }

  func testRollbackWriteFailureKeepsDurablePreferenceVisibleAndAllowsRetry() async throws {
    let settingsStore = RollbackFailingArchiveSettingsStore()
    let probe = CorpusArchiveActionProbe()
    let harness = makeHarness(
      settingsStore: settingsStore,
      refreshCorpusRecordingArchiveAction: { enabled in
        await probe.refresh(enabled)
        if enabled { throw CorpusRecordingArchiveError.storageUnavailable }
      })
    await harness.model.waitForInitialVoiceConfiguration()
    harness.model.setInterfaceLanguage(.english)
    harness.model.corpusArchive.setEnabled(true)
    await harness.model.flushPendingPersistenceWrites()
    XCTAssertTrue(harness.model.corpusArchive.isEnabled)
    let persisted1 = try await settingsStore.string(forKey: .corpusRecordingArchiveEnabled)
    XCTAssertEqual(persisted1, "true")
    XCTAssertTrue(harness.model.corpusArchive.error?.contains("No new corpus audio") == true)
    let disabledRuntime = await probe.refreshValues
    XCTAssertEqual(disabledRuntime.suffix(2), [true, false])
    harness.model.corpusArchive.setEnabled(false)
    await harness.model.flushPendingPersistenceWrites()
    XCTAssertFalse(harness.model.corpusArchive.isEnabled)
    let persisted2 = try await settingsStore.string(forKey: .corpusRecordingArchiveEnabled)
    XCTAssertEqual(persisted2, "false")
    XCTAssertNil(harness.model.corpusArchive.error)
  }

  func testDisableRemainsDurablyOffWhenRuntimeCleanupFails() async throws {
    let settingsStore = UITestSettingsStore(storage: [.corpusRecordingArchiveEnabled: "true"])
    let harness = makeHarness(
      settingsStore: settingsStore,
      refreshCorpusRecordingArchiveAction: { _ in throw CorpusRecordingArchiveError.storageUnavailable })
    await harness.model.waitForInitialVoiceConfiguration()
    harness.model.corpusArchive.setEnabled(false)
    await harness.model.flushPendingPersistenceWrites()
    XCTAssertFalse(harness.model.corpusArchive.isEnabled)
    let persisted3 = try await settingsStore.string(forKey: .corpusRecordingArchiveEnabled)
    XCTAssertEqual(persisted3, "false")
    XCTAssertNotNil(harness.model.corpusArchive.error)
  }

  func testClearRequiresExplicitActionAndKeepsRetentionPreference() async {
    let settingsStore = UITestSettingsStore(
      storage: [.corpusRecordingArchiveEnabled: "true"]
    )
    let probe = CorpusArchiveActionProbe()
    let harness = makeHarness(
      settingsStore: settingsStore,
      clearCorpusRecordingArchiveAction: {
        await probe.clear()
      }
    )
    await harness.model.waitForInitialVoiceConfiguration()

    harness.model.corpusArchive.clear()
    await harness.model.flushPendingPersistenceWrites()

    let clearCount = await probe.clearCount
    XCTAssertEqual(clearCount, 1)
    XCTAssertTrue(harness.model.corpusArchive.isEnabled)
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
    if key == .corpusRecordingArchiveEnabled {
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
