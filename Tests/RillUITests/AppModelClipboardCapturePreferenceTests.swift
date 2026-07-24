import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
final class AppModelClipboardCapturePreferenceTests: XCTestCase {
    func testMissingPreferenceKeepsCaptureDisabledWithoutRewritingStore() async {
        let store = UITestSettingsStore()
        let harness = makeHarness(settingsStore: store)

        await waitUntilSettingsLoadFinishes(harness.model)

        XCTAssertFalse(harness.model.clipboardCaptureEnabled)
        XCTAssertGreaterThan(harness.model.clipboardCapturePreferenceRevision, 0)
        var replayedEnabled: Bool?
        var replayedRevision: UInt64?
        harness.model.installClipboardCaptureControlActions(
            setEnabled: { enabled, revision in
                replayedEnabled = enabled
                replayedRevision = revision
            },
            ignoreNextExternalChange: {}
        )
        XCTAssertEqual(replayedEnabled, false)
        XCTAssertEqual(replayedRevision, harness.model.clipboardCapturePreferenceRevision)
        let activity = await store.activitySnapshot()
        XCTAssertNil(activity.storage[.clipboardCaptureEnabled])
        XCTAssertNil(activity.setCounts[.clipboardCaptureEnabled])
    }

    func testStoredFalsePublishesResolvedRevisionEvenWhenInitialValueIsAlreadyFalse() async {
        let store = UITestSettingsStore(storage: [.clipboardCaptureEnabled: "false"])
        let harness = makeHarness(settingsStore: store)

        await waitUntilSettingsLoadFinishes(harness.model)

        XCTAssertFalse(harness.model.clipboardCaptureEnabled)
        XCTAssertGreaterThan(harness.model.clipboardCapturePreferenceRevision, 0)
        var replayedEnabled: Bool?
        var replayedRevision: UInt64?
        harness.model.installClipboardCaptureControlActions(
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
            UITestSettingsStore(storage: [.clipboardCaptureEnabled: "sometimes"]),
            UITestSettingsStore(
                storage: [.clipboardCaptureEnabled: "true"],
                unavailableKeys: [.clipboardCaptureEnabled]
            ),
        ] {
            let harness = makeHarness(settingsStore: store)
            await waitUntilSettingsLoadFinishes(harness.model)

            XCTAssertFalse(harness.model.clipboardCaptureEnabled)
            XCTAssertGreaterThan(harness.model.clipboardCapturePreferenceRevision, 0)
            XCTAssertTrue(harness.model.hasUnavailableScalarSettings(in: .clipboard))
            XCTAssertFalse(harness.model.setClipboardCaptureEnabled(true))
            let activity = await store.activitySnapshot()
            XCTAssertNil(activity.setCounts[.clipboardCaptureEnabled])
        }
    }

    func testMissingSettingsStoreFailsClosedAndLocksClipboardDomain() async {
        let harness = makeHarness(
            settingsStore: nil,
            usesEphemeralSettingsStoreWhenNil: false
        )

        await waitUntilSettingsLoadFinishes(harness.model)

        XCTAssertFalse(harness.model.clipboardCaptureEnabled)
        XCTAssertGreaterThan(harness.model.clipboardCapturePreferenceRevision, 0)
        XCTAssertTrue(harness.model.hasUnavailableScalarSettings(in: .clipboard))
        XCTAssertFalse(harness.model.setClipboardCaptureEnabled(true))
    }

    func testSettingsBatchFailurePublishesResolvedClosedRevision() async {
        let store = UITestSettingsStore(failBatchReads: true)
        let harness = makeHarness(settingsStore: store)

        await waitUntilSettingsLoadFinishes(harness.model)

        XCTAssertFalse(harness.model.clipboardCaptureEnabled)
        XCTAssertGreaterThan(harness.model.clipboardCapturePreferenceRevision, 0)
        XCTAssertTrue(harness.model.hasUnavailableScalarSettings(in: .clipboard))
        var replayedEnabled: Bool?
        var replayedRevision: UInt64?
        harness.model.installClipboardCaptureControlActions(
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
        harness.model.installClipboardCaptureControlActions(
            setEnabled: { enabled, revision in
                publishedEnabled.append(enabled)
                publishedRevisions.append(revision)
            },
            ignoreNextExternalChange: {}
        )

        XCTAssertTrue(harness.model.setClipboardCaptureEnabled(true))
        await harness.model.flushPendingPersistenceWrites()

        XCTAssertEqual(publishedEnabled, [false, true])
        XCTAssertEqual(publishedRevisions, [resolvedRevision, resolvedRevision + 1])
        let activity = await store.activitySnapshot()
        XCTAssertEqual(activity.storage[.clipboardCaptureEnabled], "true")
        XCTAssertEqual(activity.setCounts[.clipboardCaptureEnabled], 1)
    }

    func testUserPreferenceChangeWinsOverStaleInitialSnapshot() async {
        let store = UITestSettingsStore(
            storage: [.clipboardCaptureEnabled: "false"],
            suspendBatchReads: true
        )
        let harness = makeHarness(
            settingsStore: store,
            settingsWriteDebounceDuration: .zero
        )
        await store.waitUntilBatchReadIsSuspended()
        var publishedEnabled: [Bool] = []
        var publishedRevisions: [UInt64] = []
        harness.model.installClipboardCaptureControlActions(
            setEnabled: { enabled, revision in
                publishedEnabled.append(enabled)
                publishedRevisions.append(revision)
            },
            ignoreNextExternalChange: {}
        )

        XCTAssertTrue(harness.model.setClipboardCaptureEnabled(true))
        await harness.model.flushPendingPersistenceWrites()
        await store.resumeBatchRead()
        await waitUntilSettingsLoadFinishes(harness.model)

        XCTAssertTrue(harness.model.clipboardCaptureEnabled)
        XCTAssertEqual(publishedEnabled, [false, true])
        XCTAssertEqual(publishedRevisions, [0, 1])
        let activity = await store.activitySnapshot()
        XCTAssertEqual(activity.storage[.clipboardCaptureEnabled], "true")
        XCTAssertEqual(activity.setCounts[.clipboardCaptureEnabled], 1)
    }

    func testClipboardDomainRecoveryReplaysRecoveredPreferenceWithoutRewrite() async {
        let store = UITestSettingsStore(
            storage: [.clipboardCaptureEnabled: "true"],
            unavailableKeys: [.clipboardCaptureEnabled]
        )
        let harness = makeHarness(settingsStore: store)
        await waitUntilSettingsLoadFinishes(harness.model)
        let failedClosedRevision = harness.model.clipboardCapturePreferenceRevision
        var publishedEnabled: [Bool] = []
        var publishedRevisions: [UInt64] = []
        harness.model.installClipboardCaptureControlActions(
            setEnabled: { enabled, revision in
                publishedEnabled.append(enabled)
                publishedRevisions.append(revision)
            },
            ignoreNextExternalChange: {}
        )

        await store.setUnavailableKeys([])
        harness.model.retryUnavailableScalarSettings(in: .clipboard)
        await waitUntil {
            !harness.model.isRetryingUnavailableScalarSettings(in: .clipboard)
        }

        XCTAssertTrue(harness.model.clipboardCaptureEnabled)
        XCTAssertFalse(harness.model.hasUnavailableScalarSettings(in: .clipboard))
        XCTAssertEqual(publishedEnabled, [false, true])
        XCTAssertEqual(publishedRevisions, [failedClosedRevision, failedClosedRevision + 1])
        let activity = await store.activitySnapshot()
        XCTAssertNil(activity.setCounts[.clipboardCaptureEnabled])
    }

    func testClipboardPreferenceWriteFailureUsesClipboardSaveCategory() async {
        let store = UITestSettingsStore(failingSetKeys: [.clipboardCaptureEnabled])
        let harness = makeHarness(
            settingsStore: store,
            settingsWriteDebounceDuration: .zero
        )
        await waitUntilSettingsLoadFinishes(harness.model)

        XCTAssertTrue(harness.model.setClipboardCaptureEnabled(true))
        await harness.model.flushPendingPersistenceWrites()

        XCTAssertEqual(
            harness.model.settingsSaveState,
            .unsaved(
                UnsavedSettingsSummary(
                    affectedChangeCount: 1,
                    categories: [.clipboard]
                )
            )
        )
    }

    private func waitUntilSettingsLoadFinishes(_ model: AppModel) async {
        await waitUntil { !model.isLoadingSettings }
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<300 {
            if predicate() { return }
            await Task.yield()
        }
        XCTAssertTrue(predicate())
    }
}
