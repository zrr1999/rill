import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
final class AppModelClipboardCapturePreferenceTests: XCTestCase {
    func testMissingPreferenceKeepsCaptureDisabledWithoutRewritingStore() async {
        let store = UITestSettingsStore()
        let harness = makeHarness(settingsStore: store)

        await waitUntilSettingsLoadFinishes(harness.model)

        XCTAssertFalse(harness.model.settings.systemClipboardCaptureEnabled)
        XCTAssertGreaterThan(harness.model.clipboardCapturePreferenceRevision, 0)
        var replayedEnabled: Bool?
        var replayedRevision: UInt64?
        harness.model.installSystemClipboardCaptureControlActions(
            setEnabled: { enabled, revision in
                replayedEnabled = enabled
                replayedRevision = revision
            },
            ignoreNextExternalChange: {}
        )
        XCTAssertEqual(replayedEnabled, false)
        XCTAssertEqual(replayedRevision, harness.model.clipboardCapturePreferenceRevision)
        let activity = await store.activitySnapshot()
        XCTAssertNil(activity.storage[.systemClipboardCaptureEnabled])
        XCTAssertNil(activity.setCounts[.systemClipboardCaptureEnabled])
    }

    func testStoredFalsePublishesResolvedRevisionEvenWhenInitialValueIsAlreadyFalse() async {
        let store = UITestSettingsStore(storage: [.systemClipboardCaptureEnabled: "false"])
        let harness = makeHarness(settingsStore: store)

        await waitUntilSettingsLoadFinishes(harness.model)

        XCTAssertFalse(harness.model.settings.systemClipboardCaptureEnabled)
        XCTAssertGreaterThan(harness.model.clipboardCapturePreferenceRevision, 0)
        var replayedEnabled: Bool?
        var replayedRevision: UInt64?
        harness.model.installSystemClipboardCaptureControlActions(
            setEnabled: { enabled, revision in
                replayedEnabled = enabled
                replayedRevision = revision
            },
            ignoreNextExternalChange: {}
        )
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
        let harness = makeHarness(settingsStore: store)

        await waitUntilSettingsLoadFinishes(harness.model)

        XCTAssertFalse(harness.model.settings.systemClipboardCaptureEnabled)
        XCTAssertGreaterThan(harness.model.clipboardCapturePreferenceRevision, 0)
        XCTAssertTrue(harness.model.settings.hasUnavailableScalarSettings(in: .systemClipboard))
        var replayedEnabled: Bool?
        var replayedRevision: UInt64?
        harness.model.installSystemClipboardCaptureControlActions(
            setEnabled: { enabled, revision in
                replayedEnabled = enabled
                replayedRevision = revision
            },
            ignoreNextExternalChange: {}
        )
        XCTAssertEqual(replayedEnabled, false)
        XCTAssertEqual(replayedRevision, harness.model.clipboardCapturePreferenceRevision)
    }

    func testUserChangePersistsAndPublishesMonotonicPreferenceRevision() async {
        let store = UITestSettingsStore()
        let harness = makeHarness(
            settingsStore: store,
            settingsWriteDebounceDuration: .zero
        )
        await waitUntilSettingsLoadFinishes(harness.model)
        let resolvedRevision = harness.model.clipboardCapturePreferenceRevision
        var publishedEnabled: [Bool] = []
        var publishedRevisions: [UInt64] = []
        harness.model.installSystemClipboardCaptureControlActions(
            setEnabled: { enabled, revision in
                publishedEnabled.append(enabled)
                publishedRevisions.append(revision)
            },
            ignoreNextExternalChange: {}
        )

        XCTAssertTrue(harness.model.setSystemClipboardCaptureEnabled(true))
        await harness.model.flushPendingPersistenceWrites()

        XCTAssertEqual(publishedEnabled, [false, true])
        XCTAssertEqual(publishedRevisions, [resolvedRevision, resolvedRevision + 1])
        let activity = await store.activitySnapshot()
        XCTAssertEqual(activity.storage[.systemClipboardCaptureEnabled], "true")
        XCTAssertEqual(activity.setCounts[.systemClipboardCaptureEnabled], 1)
    }

    func testUserPreferenceChangeWinsOverStaleInitialSnapshot() async {
        let store = UITestSettingsStore(
            storage: [.systemClipboardCaptureEnabled: "false"],
            suspendBatchReads: true
        )
        let harness = makeHarness(
            settingsStore: store,
            settingsWriteDebounceDuration: .zero
        )
        await store.waitUntilBatchReadIsSuspended()
        var publishedEnabled: [Bool] = []
        var publishedRevisions: [UInt64] = []
        harness.model.installSystemClipboardCaptureControlActions(
            setEnabled: { enabled, revision in
                publishedEnabled.append(enabled)
                publishedRevisions.append(revision)
            },
            ignoreNextExternalChange: {}
        )

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
        let harness = makeHarness(settingsStore: store)
        await waitUntilSettingsLoadFinishes(harness.model)
        let failedClosedRevision = harness.model.clipboardCapturePreferenceRevision
        var publishedEnabled: [Bool] = []
        var publishedRevisions: [UInt64] = []
        harness.model.installSystemClipboardCaptureControlActions(
            setEnabled: { enabled, revision in
                publishedEnabled.append(enabled)
                publishedRevisions.append(revision)
            },
            ignoreNextExternalChange: {}
        )

        await store.setUnavailableKeys([])
        harness.model.retryUnavailableScalarSettings(in: .systemClipboard)
        await waitUntil {
            !harness.model.settings.isRetryingUnavailableScalarSettings(in: .systemClipboard)
        }

        XCTAssertTrue(harness.model.settings.systemClipboardCaptureEnabled)
        XCTAssertFalse(harness.model.settings.hasUnavailableScalarSettings(in: .systemClipboard))
        XCTAssertEqual(publishedEnabled, [false, true])
        XCTAssertEqual(publishedRevisions, [failedClosedRevision, failedClosedRevision + 1])
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
