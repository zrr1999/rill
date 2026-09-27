
@testable import RillCore
@testable import RillWorkflows
import XCTest
@testable import RillUI

@MainActor
final class PrivacySettingsPresentationTests: XCTestCase {
    func testLoadsAndCoalescesPendingPrivacyEditsIntoOneCompleteSnapshot() async throws {
        let ruleID = try XCTUnwrap(UUID(uuidString: "A2F0C099-8E52-4ACD-9B0D-111111111111"))
        let rule = SensitiveAppRule(
            id: ruleID,
            bundleIdentifier: "com.example.vault",
            applicationName: "Vault",
            blocksClipboardHistory: false,
            blocksWorkflowCapture: true,
            blocksSelectedText: false,
            blocksCloudProcessing: true,
            enabled: false
        )
        let rulesData = try JSONEncoder().encode([rule])
        let settingsStore = UITestSettingsStore(
            storage: [
                .privacySensitiveAppRules: String(decoding: rulesData, as: UTF8.self),
                .privacyCloudConfirmationRequired: "false",
                .privacyHistoryPreviewMode: PrivacyHistoryPreviewMode.disabled.rawValue,
                .privacySecureInputConservativeMode: "false",
            ]
        )
        let privacySettingsSource = PrivacyPolicySettingsSource()
        let harness = makeHarness(
            settingsStore: settingsStore,
            privacySettingsSource: privacySettingsSource
        )

        await harness.model.waitForInitialVoiceConfiguration()

        XCTAssertEqual(
            Array(harness.model.settings.privacyPolicySettings.sensitiveAppRules.prefix(SensitiveAppRule.recommendedDefaults.count)),
            SensitiveAppRule.recommendedDefaults
        )
        XCTAssertEqual(
            harness.model.settings.privacyPolicySettings.sensitiveAppRules.first(where: { $0.id == ruleID }),
            rule
        )
        XCTAssertFalse(harness.model.settings.privacyPolicySettings.cloudConfirmationRequired)
        XCTAssertEqual(harness.model.settings.privacyPolicySettings.historyPreviewMode, .disabled)
        XCTAssertFalse(harness.model.settings.privacyPolicySettings.secureInputConservativeMode)
        XCTAssertEqual(try privacySettingsSource.currentSettings(), harness.model.settings.privacyPolicySettings)

        harness.model.setSensitiveAppRuleEnabled(ruleID, isEnabled: true)
        harness.model.setSensitiveAppRuleBlocksClipboardHistory(ruleID, blocks: true)
        harness.model.setPrivacyCloudConfirmationRequired(true)
        harness.model.setPrivacyHistoryPreviewMode(.restricted)
        harness.model.setPrivacySecureInputConservativeMode(true)
        await harness.model.settings.writes.flush()

        let snapshot = await settingsStore.activitySnapshot()
        let storedRules = try JSONDecoder().decode(
            [SensitiveAppRule].self,
            from: Data(try XCTUnwrap(snapshot.storage[.privacySensitiveAppRules]).utf8)
        )
        let storedCustomRule = try XCTUnwrap(storedRules.first(where: { $0.id == ruleID }))
        XCTAssertEqual(storedCustomRule.enabled, true)
        XCTAssertEqual(storedCustomRule.blocksClipboardHistory, true)
        XCTAssertEqual(snapshot.storage[.privacyCloudConfirmationRequired], "true")
        XCTAssertEqual(snapshot.storage[.privacyHistoryPreviewMode], PrivacyHistoryPreviewMode.restricted.rawValue)
        XCTAssertEqual(snapshot.storage[.privacySecureInputConservativeMode], "true")
        XCTAssertEqual(snapshot.atomicWriteCount, 1)
    }

    func testCustomSensitiveAppRuleCRUDValidationAndRecommendedRestore() async throws {
        let settingsStore = UITestSettingsStore()
        let privacySettingsSource = PrivacyPolicySettingsSource(initialSettings: .defaults)
        let harness = makeHarness(
            settingsStore: settingsStore,
            privacySettingsSource: privacySettingsSource
        )
        await harness.model.waitForInitialVoiceConfiguration()

        try harness.model.addSensitiveAppRule(
            bundleIdentifier: "  com.example.Vault  ",
            applicationName: nil
        )
        let custom = try XCTUnwrap(
            harness.model.settings.privacyPolicySettings.sensitiveAppRules.first {
                $0.normalizedBundleIdentifier == "com.example.vault"
            }
        )
        XCTAssertNil(custom.applicationName)
        let runtimeContext = ContextSnapshot(
            focus: FocusSnapshot(
                applicationName: "Vault",
                bundleIdentifier: "com.example.Vault",
                processIdentifier: nil,
                focusedRole: nil,
                selectedText: "secret",
                secureInput: false
            ),
            clipboard: SystemClipboardSnapshot(plainText: "secret", changeCount: 1)
        )
        let runtimeSettings = try privacySettingsSource.currentSettings()
        let runtimeDecision = PrivacyPolicy.evaluate(
            context: runtimeContext,
            settings: runtimeSettings
        )
        XCTAssertFalse(runtimeDecision.allowsClipboardCapture)
        let runtimeGate = PrivacyRunGate(
            settingsProvider: { try privacySettingsSource.currentSettings() },
            cloudConfirmationProvider: { _, _, _ in true }
        )
        do {
            _ = try await runtimeGate.authorize(
                context: runtimeContext,
                workflow: WorkflowDefinition(
                    name: "Cloud Text Test",
                    pipeline: PipelineDeclaration(
                        recognizerID: "sherpa-onnx.local",
                        postProcessSteps: [
                            PostProcessStep(kind: .llmRewrite, prompt: "Rewrite")
                        ],
                        outputActions: []
                    ),
                    ui: WorkflowUIConfig(symbolName: "cloud", accentColorName: "blue")
                )
            )
            XCTFail("Expected the runtime gate to observe the new sensitive app rule immediately.")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .cloudProcessingBlocked)
        }

        XCTAssertThrowsError(
            try harness.model.addSensitiveAppRule(
                bundleIdentifier: "COM.EXAMPLE.VAULT",
                applicationName: "Duplicate"
            )
        ) { error in
            XCTAssertEqual(error as? SensitiveAppRuleValidationError, .duplicateBundleIdentifier)
        }

        try harness.model.editSensitiveAppRule(
            custom.id,
            bundleIdentifier: "com.example.PrivateVault",
            applicationName: "Private Vault"
        )
        harness.model.setSensitiveAppRuleEnabled(custom.id, isEnabled: false)
        let edited = try XCTUnwrap(
            harness.model.settings.privacyPolicySettings.sensitiveAppRules.first(where: { $0.id == custom.id })
        )
        XCTAssertEqual(edited.bundleIdentifier, "com.example.PrivateVault")
        XCTAssertEqual(edited.applicationName, "Private Vault")
        XCTAssertFalse(edited.enabled)

        let recommendedID = try XCTUnwrap(SensitiveAppRule.recommendedDefaults.first?.id)
        XCTAssertThrowsError(try harness.model.deleteSensitiveAppRule(recommendedID)) { error in
            XCTAssertEqual(error as? SensitiveAppRuleValidationError, .recommendedRuleCannotBeEdited)
        }
        harness.model.setSensitiveAppRuleEnabled(recommendedID, isEnabled: false)
        try harness.model.restoreRecommendedSensitiveAppRules()
        XCTAssertEqual(
            harness.model.settings.privacyPolicySettings.sensitiveAppRules.first(where: { $0.id == recommendedID }),
            SensitiveAppRule.recommendedDefaults.first
        )

        try harness.model.deleteSensitiveAppRule(custom.id)
        XCTAssertFalse(harness.model.settings.privacyPolicySettings.sensitiveAppRules.contains { $0.id == custom.id })
        await harness.model.settings.writes.flush()
        XCTAssertNil(harness.model.settings.privacySettingsSaveError)
    }

    func testPrivacyWritesAreStrictlySerializedAndCommitWholeSnapshots() async throws {
        let settingsStore = ControlledPrivacySettingsStore(blocksFirstAtomicWrite: true)
        let privacySettingsSource = PrivacyPolicySettingsSource(initialSettings: .defaults)
        let harness = makeHarness(
            settingsStore: settingsStore,
            privacySettingsSource: privacySettingsSource
        )
        await harness.model.waitForInitialVoiceConfiguration()

        harness.model.setPrivacyCloudConfirmationRequired(false)
        XCTAssertFalse(try privacySettingsSource.currentSettings().cloudConfirmationRequired)
        await settingsStore.waitForFirstAtomicWrite()
        harness.model.setPrivacyCloudConfirmationRequired(true)
        XCTAssertTrue(try privacySettingsSource.currentSettings().cloudConfirmationRequired)
        let callCountBeforeRelease = await settingsStore.atomicWriteCallCount()
        XCTAssertEqual(callCountBeforeRelease, 1)
        await settingsStore.releaseFirstAtomicWrite()
        await harness.model.settings.writes.flush()

        let snapshot = await settingsStore.snapshot()
        XCTAssertEqual(snapshot.atomicSnapshots.count, 2)
        XCTAssertEqual(snapshot.atomicSnapshots[0][.privacyCloudConfirmationRequired], "false")
        XCTAssertEqual(snapshot.atomicSnapshots[1][.privacyCloudConfirmationRequired], "true")
        XCTAssertTrue(snapshot.atomicSnapshots.allSatisfy { $0.count == 5 })
        XCTAssertEqual(snapshot.storage[.privacyCloudConfirmationRequired], "true")
    }

    func testLoadsPersistsAndRevokesCloudProcessingAuthorizations() async throws {
        let authorization = CloudProcessingAuthorization(
            id: UUID(uuidString: "C6270EA5-475C-4803-A970-7B541448350B")!,
            workflowID: UUID(uuidString: "87378403-E9DC-4071-B900-D30DFBC9BC9D")!,
            workflowName: "Voice Assistant",
            scopeFingerprint: String(repeating: "a", count: 64),
            grantedAt: Date(timeIntervalSince1970: 1_000)
        )
        let encoded = try JSONEncoder().encode([authorization])
        let settingsStore = UITestSettingsStore(
            storage: [
                .privacyCloudProcessingAuthorizations: String(decoding: encoded, as: UTF8.self)
            ]
        )
        let privacySettingsSource = PrivacyPolicySettingsSource()
        let harness = makeHarness(
            settingsStore: settingsStore,
            privacySettingsSource: privacySettingsSource
        )

        await harness.model.waitForInitialVoiceConfiguration()

        XCTAssertEqual(
            harness.model.settings.privacyPolicySettings.cloudProcessingAuthorizations,
            [authorization]
        )
        harness.model.revokeCloudProcessingAuthorization(authorization.id)
        await harness.model.settings.writes.flush()

        let afterRevoke = await settingsStore.activitySnapshot()
        let storedAfterRevoke = try JSONDecoder().decode(
            [CloudProcessingAuthorization].self,
            from: Data(
                try XCTUnwrap(
                    afterRevoke.storage[.privacyCloudProcessingAuthorizations]
                ).utf8
            )
        )
        XCTAssertTrue(storedAfterRevoke.isEmpty)

        XCTAssertTrue(harness.model.grantCloudProcessingAuthorization(authorization))
        await harness.model.settings.writes.flush()
        XCTAssertEqual(
            try privacySettingsSource.currentSettings().cloudProcessingAuthorizations,
            [authorization]
        )
    }

    func testPrivacySaveFailureStaysVisibleUntilRetrySucceeds() async throws {
        let settingsStore = ControlledPrivacySettingsStore(failingAtomicWriteCount: 1)
        let privacySettingsSource = PrivacyPolicySettingsSource(initialSettings: .defaults)
        let harness = makeHarness(
            settingsStore: settingsStore,
            privacySettingsSource: privacySettingsSource
        )
        await harness.model.waitForInitialVoiceConfiguration()

        harness.model.setPrivacyCloudConfirmationRequired(false)
        await harness.model.settings.writes.flush()

        XCTAssertNotNil(harness.model.settings.privacySettingsSaveError)
        XCTAssertFalse(harness.model.settings.isSavingPrivacySettings)
        XCTAssertFalse(try privacySettingsSource.currentSettings().cloudConfirmationRequired)
        let failedSnapshot = await settingsStore.snapshot()
        XCTAssertNil(failedSnapshot.storage[.privacyCloudConfirmationRequired])

        harness.model.retryPrivacySettingsSave()
        await harness.model.settings.writes.flush()

        XCTAssertNil(harness.model.settings.privacySettingsSaveError)
        XCTAssertFalse(harness.model.settings.isSavingPrivacySettings)
        let successfulSnapshot = await settingsStore.snapshot()
        XCTAssertEqual(successfulSnapshot.storage[.privacyCloudConfirmationRequired], "false")
    }

    func testShutdownRetriesFailedPrivacySnapshotAfterClosingMutationAdmission() async throws {
        for failsWithCancellation in [false, true] {
            let store = ControlledPrivacySettingsStore(
                failingAtomicWriteCount: 1, failsWithCancellation: failsWithCancellation)
            let source = PrivacyPolicySettingsSource(initialSettings: .defaults)
            let harness = makeHarness(settingsStore: store, privacySettingsSource: source)
            await harness.model.waitForInitialVoiceConfiguration()
            harness.model.setPrivacyCloudConfirmationRequired(false)
            harness.model.setPrivacyHistoryPreviewMode(.disabled)
            await harness.model.flushPendingPersistenceWrites()
            XCTAssertEqual(harness.model.settingsSaveState.unsavedSummary?.categories, [.privacy])
            XCTAssertNotNil(harness.model.settings.privacySettingsSaveError)

            harness.model.beginApplicationShutdown()
            harness.model.setPrivacyCloudConfirmationRequired(true)
            await harness.model.drainPendingSettingsWritesForApplicationShutdown { _ in
                XCTFail("A recovered store must not enter retry backoff.")
            }

            let snapshot = await store.snapshot()
            XCTAssertEqual(snapshot.atomicSnapshots.count, 1)
            XCTAssertEqual(snapshot.atomicSnapshots[0].count, 5)
            XCTAssertEqual(snapshot.storage[.privacyCloudConfirmationRequired], "false")
            XCTAssertEqual(snapshot.storage[.privacyHistoryPreviewMode], PrivacyHistoryPreviewMode.disabled.rawValue)
            XCTAssertFalse(try source.currentSettings().cloudConfirmationRequired)
            XCTAssertEqual(harness.model.settingsSaveState, .saved)
            XCTAssertNil(harness.model.settings.privacySettingsSaveError)
            XCTAssertFalse(harness.model.settings.isSavingPrivacySettings)
        }
    }

    func testCorruptPrivacyRulesKeepSafeDefaultsAndExposeLoadFailure() async {
        let settingsStore = UITestSettingsStore(
            storage: [
                .interfaceLanguage: AppLanguage.simplifiedChinese.rawValue,
                .preferredSpeechEngine: PreferredSpeechEngine.local.rawValue,
                .privacySensitiveAppRules: "{not-json",
            ]
        )
        let privacySettingsSource = PrivacyPolicySettingsSource(initialSettings: .defaults)
        let harness = makeHarness(
            settingsStore: settingsStore,
            privacySettingsSource: privacySettingsSource
        )

        await harness.model.waitForInitialVoiceConfiguration()

        XCTAssertEqual(harness.model.settings.privacyPolicySettings, .defaults)
        XCTAssertEqual(harness.model.settings.language, .simplifiedChinese)
        XCTAssertEqual(harness.model.settings.preferredSpeechEngine, .local)
        XCTAssertNotNil(harness.model.settings.privacySettingsLoadError)
        XCTAssertNil(harness.model.settings.privacySettingsSaveError)
        XCTAssertThrowsError(try privacySettingsSource.currentSettings()) { error in
            guard let sourceError = error as? PrivacyPolicySettingsSourceError,
                  case .unavailable = sourceError else {
                return XCTFail("Expected unavailable privacy settings source, got \(error)")
            }
        }
        let activity = await settingsStore.activitySnapshot()
        XCTAssertEqual(activity.atomicWriteCount, 0)

        harness.model.resetPrivacySettingsToSafeDefaults()
        await harness.model.settings.writes.flush()
        XCTAssertNil(harness.model.settings.privacySettingsLoadError)
        let recoveredSettings = try? privacySettingsSource.currentSettings()
        XCTAssertEqual(recoveredSettings, PrivacyPolicySettings.defaults)
    }

    func testCredentialLoadFailureDoesNotCloseValidPrivacySettingsSource() async throws {
        let settingsStore = UITestSettingsStore()
        let privacySettingsSource = PrivacyPolicySettingsSource()
        let harness = makeHarness(
            settingsStore: settingsStore,
            credentialStore: FailingPrivacyTestCredentialStore(),
            privacySettingsSource: privacySettingsSource
        )

        await harness.model.waitForInitialVoiceConfiguration()

        XCTAssertNil(harness.model.settings.privacySettingsLoadError)
        XCTAssertEqual(try privacySettingsSource.currentSettings(), .defaults)
        XCTAssertTrue(
            harness.model.history.eventFeed.contains {
                $0.english == "The LLM Provider credential could not be read from secure storage."
            }
        )
    }

    func testMissingPersistentSettingsStoreKeepsRuntimePrivacyClosed() async {
        let privacySettingsSource = PrivacyPolicySettingsSource()
        let harness = makeHarness(
            usesEphemeralSettingsStoreWhenNil: false,
            credentialStore: UITestSecureCredentialStore(),
            privacySettingsSource: privacySettingsSource
        )

        await harness.model.waitForInitialVoiceConfiguration()

        XCTAssertNotNil(harness.model.settings.privacySettingsLoadError)
        XCTAssertThrowsError(try privacySettingsSource.currentSettings()) { error in
            guard let sourceError = error as? PrivacyPolicySettingsSourceError,
                  case .unavailable = sourceError else {
                return XCTFail("Expected unavailable privacy settings source, got \(error)")
            }
        }
    }

    func testPrivacyRouteHintsUseUnifiedLocalization() {
        XCTAssertEqual(
            L10n.privacySettingsSpeechRouteHint(.localSpeech, language: .english),
            "Local route: recognition stays on this Mac."
        )
        XCTAssertEqual(
            L10n.privacySettingsHistoryPreviewMode(.restricted, language: .simplifiedChinese),
            "受限预览"
        )
    }

    func testWorkflowDetailIncludesLocalSpeechPrivacyRouteHint() {
        let workflow = WorkflowDefinition(
            name: "Local Dictation with Cloud Text Rewrite",
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: "sherpa-onnx.local",
                postProcessSteps: [
                    PostProcessStep(kind: .llmRewrite, prompt: "Rewrite")
                ],
                outputActions: [OutputActionReference(id: "system-clipboard.copy")]
            ),
            ui: WorkflowUIConfig(symbolName: "cloud", accentColorName: "blue")
        )

        let detail = VoiceWorkflowPresentation(workflow: workflow).detail(language: .english)

        XCTAssertTrue(detail.contains("Privacy: Stays on this Mac"))
    }
}

private enum ControlledPrivacySettingsStoreError: Error {
    case requestedFailure
}

private actor FailingPrivacyTestCredentialStore: SecureCredentialStore {
    func credential(for key: SecureCredentialKey) async throws -> String? {
        throw ControlledPrivacySettingsStoreError.requestedFailure
    }

    func setCredential(_ value: String, for key: SecureCredentialKey) async throws {
        throw ControlledPrivacySettingsStoreError.requestedFailure
    }

    func removeCredential(for key: SecureCredentialKey) async throws {
        throw ControlledPrivacySettingsStoreError.requestedFailure
    }
}

private actor ControlledPrivacySettingsStore: SettingsStore {
    struct Snapshot: Sendable {
        let storage: [AppSettingKey: String]
        let atomicSnapshots: [[AppSettingKey: String]]
    }

    private var storage: [AppSettingKey: String] = [:]
    private var atomicSnapshots: [[AppSettingKey: String]] = []
    private var atomicWriteCount = 0
    private var failingAtomicWriteCount: Int
    private let blocksFirstAtomicWrite: Bool
    private let failsWithCancellation: Bool
    private var firstWriteWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstWriteRelease: CheckedContinuation<Void, Never>?

    init(
        blocksFirstAtomicWrite: Bool = false,
        failingAtomicWriteCount: Int = 0,
        failsWithCancellation: Bool = false
    ) {
        self.blocksFirstAtomicWrite = blocksFirstAtomicWrite
        self.failsWithCancellation = failsWithCancellation
        self.failingAtomicWriteCount = failingAtomicWriteCount
    }

    func string(forKey key: AppSettingKey) async throws -> String? {
        storage[key]
    }

    func strings(forKeys keys: [AppSettingKey]) async throws -> [AppSettingKey: String] {
        keys.reduce(into: [:]) { values, key in
            values[key] = storage[key]
        }
    }

    func setString(_ value: String, forKey key: AppSettingKey) async throws {
        storage[key] = value
    }

    func setStringsAtomically(_ values: [AppSettingKey: String]) async throws {
        atomicWriteCount += 1
        let writeNumber = atomicWriteCount
        if writeNumber == 1 {
            let waiters = firstWriteWaiters
            firstWriteWaiters = []
            waiters.forEach { $0.resume() }
        }
        if blocksFirstAtomicWrite, writeNumber == 1 {
            await withCheckedContinuation { continuation in
                firstWriteRelease = continuation
            }
        }
        if failingAtomicWriteCount > 0 {
            failingAtomicWriteCount -= 1
            if failsWithCancellation { throw CancellationError() }
            throw ControlledPrivacySettingsStoreError.requestedFailure
        }
        storage.merge(values) { _, newValue in newValue }
        atomicSnapshots.append(values)
    }

    func removeValue(forKey key: AppSettingKey) async throws {
        storage.removeValue(forKey: key)
    }

    func waitForFirstAtomicWrite() async {
        guard atomicWriteCount == 0 else { return }
        await withCheckedContinuation { continuation in
            firstWriteWaiters.append(continuation)
        }
    }

    func releaseFirstAtomicWrite() {
        firstWriteRelease?.resume()
        firstWriteRelease = nil
    }

    func atomicWriteCallCount() -> Int {
        atomicWriteCount
    }

    func snapshot() -> Snapshot {
        Snapshot(storage: storage, atomicSnapshots: atomicSnapshots)
    }
}
