import XCTest
import RillTestSupport
@testable import RillCore
@testable import RillUI

@MainActor
final class AppModelClipboardCapturePreferenceTests: XCTestCase {
    func testMissingPreferenceKeepsCaptureDisabledWithoutRewritingStore() async {
        let store = UITestSettingsStore()
        var replayedEnabled: Bool?
        var replayedRevision: UInt64?
        let harness = makeHarness(
            settingsStore: store,
            recordInteractionServices: makeRecordInteractionServicesForTesting(
                setCaptureEnabled: { enabled, revision in
                    replayedEnabled = enabled
                    replayedRevision = revision
                },
                ignoreNextExternalChange: {}
            )
        )

        await waitUntilSettingsLoadFinishes(harness.model)

        XCTAssertFalse(harness.model.settings.systemClipboardCaptureEnabled)
        XCTAssertGreaterThan(harness.model.clipboardCapturePreferenceRevision, 0)

        XCTAssertEqual(replayedEnabled, false)
        XCTAssertEqual(replayedRevision, harness.model.clipboardCapturePreferenceRevision)
        let activity = await store.activitySnapshot()
        XCTAssertNil(activity.storage[.systemClipboardCaptureEnabled])
        XCTAssertNil(activity.setCounts[.systemClipboardCaptureEnabled])
    }

    func testStoredFalsePublishesResolvedRevisionEvenWhenInitialValueIsAlreadyFalse() async {
        let store = UITestSettingsStore(storage: [.systemClipboardCaptureEnabled: "false"])
        var replayedEnabled: Bool?
        var replayedRevision: UInt64?
        let harness = makeHarness(
            settingsStore: store,
            recordInteractionServices: makeRecordInteractionServicesForTesting(
                setCaptureEnabled: { enabled, revision in
                    replayedEnabled = enabled
                    replayedRevision = revision
                },
                ignoreNextExternalChange: {}
            )
        )

        await waitUntilSettingsLoadFinishes(harness.model)

        XCTAssertFalse(harness.model.settings.systemClipboardCaptureEnabled)
        XCTAssertGreaterThan(harness.model.clipboardCapturePreferenceRevision, 0)

        XCTAssertEqual(replayedEnabled, false)
        XCTAssertEqual(replayedRevision, harness.model.clipboardCapturePreferenceRevision)
    }

    func testInvalidAndUnavailablePreferencesFailClosedAndLockClipboardDomain() async {
        for store in [
            UITestSettingsStore(storage: [.systemClipboardCaptureEnabled: "sometimes"]),
            UITestSettingsStore(
                storage: [.systemClipboardCaptureEnabled: "true"],
                unavailableKeys: [.systemClipboardCaptureEnabled]
            ),
        ] {
            let harness = makeHarness(settingsStore: store)
            await waitUntilSettingsLoadFinishes(harness.model)

            XCTAssertFalse(harness.model.settings.systemClipboardCaptureEnabled)
            XCTAssertGreaterThan(harness.model.clipboardCapturePreferenceRevision, 0)
            XCTAssertTrue(harness.model.settings.hasUnavailableScalarSettings(in: .systemClipboard))
            XCTAssertFalse(harness.model.setSystemClipboardCaptureEnabled(true))
            let activity = await store.activitySnapshot()
            XCTAssertNil(activity.setCounts[.systemClipboardCaptureEnabled])
        }
    }

    func testMissingSettingsStoreFailsClosedAndLocksClipboardDomain() async {
        let harness = makeHarness(
            settingsStore: nil,
            usesEphemeralSettingsStoreWhenNil: false
        )

        await waitUntilSettingsLoadFinishes(harness.model)

        XCTAssertFalse(harness.model.settings.systemClipboardCaptureEnabled)
        XCTAssertGreaterThan(harness.model.clipboardCapturePreferenceRevision, 0)
        XCTAssertTrue(harness.model.settings.hasUnavailableScalarSettings(in: .systemClipboard))
        XCTAssertFalse(harness.model.setSystemClipboardCaptureEnabled(true))
    }

    func testSettingsBatchFailurePublishesResolvedClosedRevision() async {
        let store = UITestSettingsStore(failBatchReads: true)
        var replayedEnabled: Bool?
        var replayedRevision: UInt64?
        let harness = makeHarness(
            settingsStore: store,
            recordInteractionServices: makeRecordInteractionServicesForTesting(
                setCaptureEnabled: { enabled, revision in
                    replayedEnabled = enabled
                    replayedRevision = revision
                },
                ignoreNextExternalChange: {}
            )
        )

        await waitUntilSettingsLoadFinishes(harness.model)

        XCTAssertFalse(harness.model.settings.systemClipboardCaptureEnabled)
        XCTAssertGreaterThan(harness.model.clipboardCapturePreferenceRevision, 0)
        XCTAssertTrue(harness.model.settings.hasUnavailableScalarSettings(in: .systemClipboard))

        XCTAssertEqual(replayedEnabled, false)
        XCTAssertEqual(replayedRevision, harness.model.clipboardCapturePreferenceRevision)
    }

    func testUserChangePersistsAndPublishesMonotonicPreferenceRevision() async {
        let store = UITestSettingsStore()
        var publishedEnabled: [Bool] = []
        var publishedRevisions: [UInt64] = []
        let harness = makeHarness(
            settingsStore: store,
            settingsWriteDebounceDuration: .zero,
            recordInteractionServices: makeRecordInteractionServicesForTesting(
                setCaptureEnabled: { enabled, revision in
                    publishedEnabled.append(enabled)
                    publishedRevisions.append(revision)
                },
                ignoreNextExternalChange: {}
            )
        )
        await waitUntilSettingsLoadFinishes(harness.model)
        let resolvedRevision = harness.model.clipboardCapturePreferenceRevision

        XCTAssertTrue(harness.model.setSystemClipboardCaptureEnabled(true))
        await harness.model.flushPendingPersistenceWrites()

        XCTAssertEqual(publishedEnabled, [false, false, true])
        XCTAssertEqual(publishedRevisions, [0, resolvedRevision, resolvedRevision + 1])
        let activity = await store.activitySnapshot()
        XCTAssertEqual(activity.storage[.systemClipboardCaptureEnabled], "true")
        XCTAssertEqual(activity.setCounts[.systemClipboardCaptureEnabled], 1)
    }

    func testUserPreferenceChangeWinsOverStaleInitialSnapshot() async {
        let store = UITestSettingsStore(
            storage: [.systemClipboardCaptureEnabled: "false"],
            suspendBatchReads: true
        )
        var publishedEnabled: [Bool] = []
        var publishedRevisions: [UInt64] = []
        let harness = makeHarness(
            settingsStore: store,
            settingsWriteDebounceDuration: .zero,
            recordInteractionServices: makeRecordInteractionServicesForTesting(
                setCaptureEnabled: { enabled, revision in
                    publishedEnabled.append(enabled)
                    publishedRevisions.append(revision)
                },
                ignoreNextExternalChange: {}
            )
        )
        await store.waitUntilBatchReadIsSuspended()

        XCTAssertTrue(harness.model.setSystemClipboardCaptureEnabled(true))
        await harness.model.flushPendingPersistenceWrites()
        await store.resumeBatchRead()
        await waitUntilSettingsLoadFinishes(harness.model)

        XCTAssertTrue(harness.model.settings.systemClipboardCaptureEnabled)
        XCTAssertEqual(publishedEnabled, [false, true])
        XCTAssertEqual(publishedRevisions, [0, 1])
        let activity = await store.activitySnapshot()
        XCTAssertEqual(activity.storage[.systemClipboardCaptureEnabled], "true")
        XCTAssertEqual(activity.setCounts[.systemClipboardCaptureEnabled], 1)
    }

    func testClipboardDomainRecoveryReplaysRecoveredPreferenceWithoutRewrite() async {
        let store = UITestSettingsStore(
            storage: [.systemClipboardCaptureEnabled: "true"],
            unavailableKeys: [.systemClipboardCaptureEnabled]
        )
        var publishedEnabled: [Bool] = []
        var publishedRevisions: [UInt64] = []
        let harness = makeHarness(
            settingsStore: store,
            recordInteractionServices: makeRecordInteractionServicesForTesting(
                setCaptureEnabled: { enabled, revision in
                    publishedEnabled.append(enabled)
                    publishedRevisions.append(revision)
                },
                ignoreNextExternalChange: {}
            )
        )
        await waitUntilSettingsLoadFinishes(harness.model)
        let failedClosedRevision = harness.model.clipboardCapturePreferenceRevision

        await store.setUnavailableKeys([])
        harness.model.retryUnavailableScalarSettings(in: .systemClipboard)
        await waitUntil {
            !harness.model.settings.isRetryingUnavailableScalarSettings(in: .systemClipboard)
        }

        XCTAssertTrue(harness.model.settings.systemClipboardCaptureEnabled)
        XCTAssertFalse(harness.model.settings.hasUnavailableScalarSettings(in: .systemClipboard))
        XCTAssertEqual(publishedEnabled, [false, false, true])
        XCTAssertEqual(publishedRevisions, [0, failedClosedRevision, failedClosedRevision + 1])
        let activity = await store.activitySnapshot()
        XCTAssertNil(activity.setCounts[.systemClipboardCaptureEnabled])
    }

    func testClipboardPreferenceWriteFailureUsesClipboardSaveCategory() async {
        let store = UITestSettingsStore(failingSetKeys: [.systemClipboardCaptureEnabled])
        let harness = makeHarness(
            settingsStore: store,
            settingsWriteDebounceDuration: .zero
        )
        await waitUntilSettingsLoadFinishes(harness.model)

        XCTAssertTrue(harness.model.setSystemClipboardCaptureEnabled(true))
        await harness.model.flushPendingPersistenceWrites()

        XCTAssertEqual(
            harness.model.settingsSaveState,
            .unsaved(
                UnsavedSettingsSummary(
                    affectedChangeCount: 1,
                    categories: [.systemClipboard]
                )
            )
        )
    }

    private func waitUntilSettingsLoadFinishes(_ model: AppModel) async {
        await waitUntil { !model.settings.isLoading }
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<300 {
            if predicate() { return }
            await Task.yield()
        }
        XCTAssertTrue(predicate())
    }
}
