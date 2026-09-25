
@testable import RillCore
import XCTest
@testable import RillUI

private enum UserVisibleErrorPrivacySentinel: LocalizedError {
    case backend

    var errorDescription: String? {
        "DO_NOT_LEAK_/Users/private/provider-body_API_KEY_123"
    }
}

private actor UserVisibleErrorPrivacySettingsStore: SettingsStore {
    private var storage: [AppSettingKey: String]
    private let failsBatchRead: Bool
    private let failsAtomicWrite: Bool
    private let failingSetKeys: Set<AppSettingKey>

    init(
        storage: [AppSettingKey: String] = [:],
        failsBatchRead: Bool = false,
        failsAtomicWrite: Bool = false,
        failingSetKeys: Set<AppSettingKey> = []
    ) {
        self.storage = storage
        self.failsBatchRead = failsBatchRead
        self.failsAtomicWrite = failsAtomicWrite
        self.failingSetKeys = failingSetKeys
    }

    func string(forKey key: AppSettingKey) async throws -> String? {
        storage[key]
    }

    func strings(forKeys keys: [AppSettingKey]) async throws -> [AppSettingKey: String] {
        if failsBatchRead {
            throw UserVisibleErrorPrivacySentinel.backend
        }
        return keys.reduce(into: [:]) { values, key in
            values[key] = storage[key]
        }
    }

    func setString(_ value: String, forKey key: AppSettingKey) async throws {
        if failingSetKeys.contains(key) {
            throw UserVisibleErrorPrivacySentinel.backend
        }
        storage[key] = value
    }

    func setStringsAtomically(_ values: [AppSettingKey: String]) async throws {
        if failsAtomicWrite {
            throw UserVisibleErrorPrivacySentinel.backend
        }
        storage.merge(values) { _, newValue in newValue }
    }

    func removeValue(forKey key: AppSettingKey) async throws {
        storage[key] = nil
    }
}

@MainActor
final class UserVisibleErrorPrivacyTests: XCTestCase {
    private let sentinel = "DO_NOT_LEAK_/Users/private/provider-body_API_KEY_123"

    func testSettingsLoadFailureKeepsPrivacyAndRetentionBlockedWithoutLeakingBackendDetail() async {
        let store = UserVisibleErrorPrivacySettingsStore(failsBatchRead: true)
        let source = PrivacyPolicySettingsSource()
        let harness = makeHarness(
            settingsStore: store,
            privacySettingsSource: source
        )

        await harness.model.waitForInitialVoiceConfiguration()

        XCTAssertFalse(harness.model.areHistoryRetentionSettingsAvailable)
        XCTAssertNotNil(harness.model.historyRetentionSettingsError)
        XCTAssertNotNil(harness.model.privacySettingsLoadError)
        XCTAssertThrowsError(try source.currentSettings())
        assertSentinelIsAbsent(from: harness.model)
    }

    func testSingleUnreadablePrivacySettingKeepsOtherSettingsAndFailsClosedWithoutMutation() async {
        let store = UITestSettingsStore(
            storage: [
                .recordHistoryVisibility: RecordHistoryVisibility.all.rawValue,
                .privacyCloudConfirmationRequired: sentinel,
            ],
            unavailableKeys: [.privacyCloudConfirmationRequired]
        )
        let source = PrivacyPolicySettingsSource(initialSettings: .defaults)
        let harness = makeHarness(
            settingsStore: store,
            privacySettingsSource: source
        )

        await harness.model.waitForInitialVoiceConfiguration()

        XCTAssertEqual(harness.model.recordHistoryVisibility, .all)
        XCTAssertFalse(source.hasAvailableSettings)
        XCTAssertNotNil(harness.model.privacySettingsLoadError)
        let activity = await store.activitySnapshot()
        XCTAssertEqual(activity.storage[.privacyCloudConfirmationRequired], sentinel)
        XCTAssertNil(activity.setCounts[.privacyCloudConfirmationRequired])
        XCTAssertNil(activity.removeCounts[.privacyCloudConfirmationRequired])
        assertSentinelIsAbsent(from: harness.model)
    }

    func testPrivacySaveFailureRemainsRecoverableWithoutLeakingBackendDetail() async {
        let store = UserVisibleErrorPrivacySettingsStore(failsAtomicWrite: true)
        let harness = makeHarness(
            settingsStore: store,
            privacySettingsSource: PrivacyPolicySettingsSource(initialSettings: .defaults)
        )
        await harness.model.waitForInitialVoiceConfiguration()

        harness.model.setPrivacyCloudConfirmationRequired(false)
        await harness.model.waitForPendingPrivacySettingsWrite()

        XCTAssertNotNil(harness.model.privacySettingsSaveError)
        XCTAssertFalse(harness.model.isSavingPrivacySettings)
        XCTAssertFalse(harness.model.privacyPolicySettings.cloudConfirmationRequired)
        assertSentinelIsAbsent(from: harness.model)
    }

    func testRetentionWriteFailureDoesNotPruneOrLeakBackendDetail() async {
        let store = UserVisibleErrorPrivacySettingsStore(
            failingSetKeys: [.recordRetentionPeriod]
        )
        let maintenance = UITestLocalHistoryMaintenance()
        let harness = makeHarness(
            settingsStore: store,
            localHistoryMaintenance: maintenance
        )
        await waitForHistoryMaintenance(harness)
        await maintenance.resetCalls()

        harness.model.setRecordRetentionPeriod(.oneWeek)
        await waitForHistoryMaintenance(harness)

        XCTAssertEqual(harness.model.recordRetentionPeriod, .thirtyDays)
        XCTAssertNotNil(harness.model.historyRetentionSettingsError)
        let maintenanceCalls = await maintenance.callSnapshot()
        XCTAssertTrue(maintenanceCalls.isEmpty)
        assertSentinelIsAbsent(from: harness.model)
    }

    func testWorkflowFailuresKeepTypedStageStateWithoutLeakingBackendDetail() async {
        let harness = makeHarness(
            settingsStore: UserVisibleErrorPrivacySettingsStore(),
            credentialStore: UITestSecureCredentialStore(),
            permissionSnapshot: PermissionSnapshot(accessibility: .granted, microphone: .granted),
            authorizeWorkflowRunAction: { _ in throw UserVisibleErrorPrivacySentinel.backend }
        )
        await harness.model.waitForInitialVoiceConfiguration()

        harness.model.runWorkflow(harness.workflow)
        await harness.model.waitForInteractiveWorkflowRun()
        XCTAssertNotNil(harness.model.lastFailure)
        XCTAssertFalse(harness.model.isRunning)
        assertSentinelIsAbsent(from: harness.model)
    }

    func testRuntimeFailureAndActionResultAreSanitizedBeforeReachingUIState() async throws {
        let harness = makeHarness()
        await waitForListenerSetup(harness)

        await harness.eventBus.publish(
            .runFailed(runID: nil, workflow: nil, message: sentinel)
        )
        await waitForEventProcessing(harness)
        let expectedFailure = harness.model.language == .english
            ? HistoryFailureSanitizer.genericMessage
            : "工作流失败。请在诊断中查看安全摘要后重试。"
        XCTAssertEqual(
            harness.model.lastFailure,
            expectedFailure
        )

        await harness.eventBus.publish(
            .actionExecuted(run: .init(runID: UUID()), actionID: "provider.action", result: .failed(sentinel))
        )
        await waitForEventProcessing(harness)

        let entry = try XCTUnwrap(harness.model.eventFeed.last)
        XCTAssertEqual(entry.english, "An output action failed. Open Diagnostics for a safe summary, then retry.")
        assertSentinelIsAbsent(from: harness.model)
    }

    func testNoSpeechFailureKeepsAnActionableBilingualMessage() async {
        let harness = makeHarness()
        await waitForListenerSetup(harness)

        harness.model.language = .english
        await harness.eventBus.publish(
            .runFailed(
                runID: nil,
                workflow: nil,
                message: HistoryFailureSanitizer.noSpeechMessage
            )
        )
        await waitForEventProcessing(harness)
        XCTAssertEqual(harness.model.lastFailure, HistoryFailureSanitizer.noSpeechMessage)

        harness.model.language = .simplifiedChinese
        await harness.eventBus.publish(
            .runFailed(
                runID: nil,
                workflow: nil,
                message: HistoryFailureSanitizer.noSpeechMessage
            )
        )
        await waitForEventProcessing(harness)
        XCTAssertEqual(harness.model.lastFailure, "未检测到语音。请重试。")
    }

    func testGlobalInputUnavailableFailureKeepsABilingualMessage() async {
        let harness = makeHarness()
        await waitForListenerSetup(harness)

        harness.model.language = .english
        await harness.eventBus.publish(
            .runFailed(
                runID: UUID(),
                workflow: nil,
                message: HistoryFailureSanitizer.globalInputUnavailableMessage
            )
        )
        await waitForEventProcessing(harness)
        XCTAssertEqual(
            harness.model.lastFailure,
            HistoryFailureSanitizer.globalInputUnavailableMessage
        )

        harness.model.language = .simplifiedChinese
        await harness.eventBus.publish(
            .runFailed(
                runID: UUID(),
                workflow: nil,
                message: HistoryFailureSanitizer.globalInputUnavailableMessage
            )
        )
        await waitForEventProcessing(harness)
        XCTAssertEqual(harness.model.lastFailure, "全局键盘输入不可用，语音录制已停止。")
    }

    func testRecognitionTimeoutFailureKeepsAnActionableBilingualMessage() async {
        let harness = makeHarness()
        await waitForListenerSetup(harness)

        harness.model.language = .english
        await harness.eventBus.publish(
            .runFailed(
                runID: UUID(),
                workflow: nil,
                message: HistoryFailureSanitizer.recognitionTimeoutMessage
            )
        )
        await waitForEventProcessing(harness)
        XCTAssertEqual(
            harness.model.lastFailure,
            HistoryFailureSanitizer.recognitionTimeoutMessage
        )

        harness.model.language = .simplifiedChinese
        await harness.eventBus.publish(
            .runFailed(
                runID: UUID(),
                workflow: nil,
                message: HistoryFailureSanitizer.recognitionTimeoutMessage
            )
        )
        await waitForEventProcessing(harness)
        XCTAssertEqual(
            harness.model.lastFailure,
            "语音识别耗时过长，本次运行已停止。请重试。"
        )
    }

    func testRecognitionRecoveryPendingFailureKeepsAnActionableBilingualMessage() async {
        let harness = makeHarness()
        await waitForListenerSetup(harness)

        harness.model.language = .english
        await harness.eventBus.publish(
            .runFailed(
                runID: UUID(),
                workflow: nil,
                message: HistoryFailureSanitizer.recognitionRecoveryPendingMessage
            )
        )
        await waitForEventProcessing(harness)
        XCTAssertEqual(
            harness.model.lastFailure,
            HistoryFailureSanitizer.recognitionRecoveryPendingMessage
        )

        harness.model.language = .simplifiedChinese
        await harness.eventBus.publish(
            .runFailed(
                runID: UUID(),
                workflow: nil,
                message: HistoryFailureSanitizer.recognitionRecoveryPendingMessage
            )
        )
        await waitForEventProcessing(harness)
        XCTAssertEqual(
            harness.model.lastFailure,
            "上次识别操作仍在结束中。请稍候，或切换识别引擎。"
        )
    }

    func testUnknownFailedAudioRecoveryErrorUsesFixedBilingualCopy() {
        let harness = makeHarness()

        harness.model.language = .english
        let english = harness.model.localizedRecoveryErrorDetail(
            UserVisibleErrorPrivacySentinel.backend
        )
        harness.model.language = .simplifiedChinese
        let simplifiedChinese = harness.model.localizedRecoveryErrorDetail(
            UserVisibleErrorPrivacySentinel.backend
        )

        XCTAssertEqual(
            english,
            "Failed recording recovery is temporarily unavailable. Retry the operation."
        )
        XCTAssertEqual(simplifiedChinese, "失败录音恢复暂时不可用。请重试此操作。")
        XCTAssertFalse(english.contains(sentinel))
        XCTAssertFalse(simplifiedChinese.contains(sentinel))
    }

    private func assertSentinelIsAbsent(
        from model: AppModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let visibleText = [
            model.lastFailure,
            model.privacySettingsLoadError,
            model.privacySettingsSaveError,
            model.historyRetentionSettingsError,
        ]
        .compactMap { $0 }
        + model.eventFeed.flatMap { [$0.english, $0.simplifiedChinese] }

        XCTAssertFalse(
            visibleText.contains { $0.contains(sentinel) },
            "Untrusted backend detail crossed into user-visible UI state.",
            file: file,
            line: line
        )
    }
}
