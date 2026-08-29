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

    XCTAssertFalse(harness.model.benchmarkRecordingArchiveEnabled)

    harness.model.setBenchmarkRecordingArchiveEnabled(true)
    await harness.model.flushPendingPersistenceWrites()
    XCTAssertTrue(harness.model.benchmarkRecordingArchiveEnabled)
    let enabledValue = try await settingsStore.string(
      forKey: .benchmarkRecordingArchiveEnabled
    )
    XCTAssertEqual(enabledValue, "true")

    harness.model.setBenchmarkRecordingArchiveEnabled(false)
    await harness.model.flushPendingPersistenceWrites()
    XCTAssertFalse(harness.model.benchmarkRecordingArchiveEnabled)
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

    XCTAssertTrue(harness.model.benchmarkRecordingArchiveEnabled)
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

    harness.model.setBenchmarkRecordingArchiveEnabled(true)
    await harness.model.flushPendingPersistenceWrites()

    XCTAssertFalse(harness.model.benchmarkRecordingArchiveEnabled)
    XCTAssertNotNil(harness.model.benchmarkRecordingArchiveError)
    let persistedValue = try await settingsStore.string(
      forKey: .benchmarkRecordingArchiveEnabled
    )
    XCTAssertEqual(persistedValue, "false")
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

    harness.model.clearBenchmarkRecordingArchive()
    await harness.model.flushPendingPersistenceWrites()

    let clearCount = await probe.clearCount
    XCTAssertEqual(clearCount, 1)
    XCTAssertTrue(harness.model.benchmarkRecordingArchiveEnabled)
  }
}
