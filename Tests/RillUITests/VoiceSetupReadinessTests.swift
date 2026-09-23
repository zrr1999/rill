import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
final class VoiceSetupReadinessTests: XCTestCase {
    func testMissingProductionTrustMaterialOverridesHistoryAndCurrentReadyState() async {
        let prepareProbe = SpeechPreparationProbe()
        let harness = makeHarness(
            localSpeechTrustMaterialAvailable: false,
            permissionSnapshot: PermissionSnapshot(accessibility: .granted, microphone: .granted),
            prepareLocalSpeechAction: { settings, _ in
                await prepareProbe.recordPreparation(settings: settings)
                return settings.model
            }
        )
        harness.model.isLoadingSettings = false
        // Production defaults to cloud when trusted local model material is
        // unavailable. Select local explicitly so this test exercises the
        // fail-closed local readiness path rather than the cloud fallback.
        harness.model.preferredSpeechEngine = .local
        harness.model.downloadedLocalSpeechModels = ["qwen3-asr-0.6b-mlx-8bit"]
        harness.model.localSpeechPreparationState = .ready
        harness.model.localSpeechPreparedModelIdentifier = "qwen3-asr-0.6b-mlx-8bit"

        XCTAssertEqual(
            harness.model.voiceSetupReadiness.provider,
            .localUnavailable(.trustMaterialUnavailable)
        )
        XCTAssertFalse(harness.model.voiceSetupReadiness.isComplete)

        harness.model.prepareLocalSpeechModel()
        await waitForEventProcessing(harness)

        let prepareSnapshot = await prepareProbe.snapshot()
        XCTAssertEqual(prepareSnapshot.prepareCount, 0)
        XCTAssertEqual(harness.model.localSpeechPreparationState, .idle)
        XCTAssertNil(harness.model.localSpeechPreparedModelIdentifier)
        XCTAssertEqual(
            harness.model.localSpeechPreparationError,
            UIStrings.text(.localSpeechTrustMaterialUnavailable, language: harness.model.language)
        )
    }

    func testIncompatibleRuntimeRemainsUnavailableWithAccurateProductReason() {
        let harness = makeHarness(
            localSpeechAvailability: .architectureUnsupported,
            permissionSnapshot: PermissionSnapshot(accessibility: .granted, microphone: .granted)
        )
        harness.model.isLoadingSettings = false

        XCTAssertEqual(harness.model.localSpeechAvailability, .architectureUnsupported)
        XCTAssertFalse(harness.model.localSpeechTrustMaterialAvailable)
        XCTAssertFalse(harness.model.setPreferredSpeechEngine(.local))
        XCTAssertEqual(harness.model.preferredSpeechEngine, .local)
        XCTAssertEqual(
            UIStrings.localSpeechAvailabilityDescription(
                harness.model.localSpeechAvailability,
                language: .english
            ),
            "This build does not include a compatible MLX speech worker. Use a supported Rill build."
        )
        XCTAssertEqual(
            UIStrings.localSpeechAvailabilityDescription(
                harness.model.localSpeechAvailability,
                language: .simplifiedChinese
            ),
            "此构建未包含兼容的 MLX 语音 worker，请使用受支持的 Rill 构建。"
        )

        // A historical local preference remains fail-closed and reports the
        // runtime compatibility boundary instead of claiming trust material is missing.
        harness.model.preferredSpeechEngine = .local
        XCTAssertEqual(
            harness.model.voiceSetupReadiness.provider,
            .localUnavailable(.architectureUnsupported)
        )
        harness.model.prepareLocalSpeechModel()
        XCTAssertEqual(
            harness.model.localSpeechPreparationError,
            UIStrings.text(.localSpeechArchitectureUnsupported, language: harness.model.language)
        )
    }

    func testLocalModelLoadedInCurrentSessionCompletesRequiredSetup() {
        let harness = makeHarness(
            permissionSnapshot: PermissionSnapshot(accessibility: .granted, microphone: .granted)
        )
        harness.model.preferredSpeechEngine = .local
        harness.model.localSpeechPreparationState = .ready
        harness.model.localSpeechPreparedModelIdentifier = "qwen3-asr-0.6b-mlx-8bit"

        XCTAssertEqual(harness.model.voiceSetupReadiness.provider, .localReady)
        XCTAssertTrue(harness.model.voiceSetupReadiness.isComplete)
    }

    func testVoiceGroupOutputStillRequiresInstalledGlobalInput() {
        let harness = makeHarness(
            permissionSnapshot: PermissionSnapshot(accessibility: .denied, microphone: .granted),
            globalInputCapability: .permissionRequired
        )
        harness.model.preferredSpeechEngine = .local
        harness.model.builtinPushToTalkOutputMode = .saveToVoiceGroup
        harness.model.localSpeechPreparationState = .ready
        harness.model.localSpeechPreparedModelIdentifier = "qwen3-asr-0.6b-mlx-8bit"

        XCTAssertFalse(harness.model.voiceSetupReadiness.accessibilityRequired)
        XCTAssertFalse(harness.model.voiceSetupReadiness.isComplete)

        harness.model.updateGlobalInputCapability(.available)
        XCTAssertTrue(harness.model.voiceSetupReadiness.isComplete)
    }

    func testDirectInsertionRequiresBothGlobalInputAndAccessibility() {
        let harness = makeHarness(
            permissionSnapshot: PermissionSnapshot(accessibility: .denied, microphone: .granted),
            globalInputCapability: .available
        )
        harness.model.preferredSpeechEngine = .local
        harness.model.builtinPushToTalkOutputMode = .pasteIntoApp
        harness.model.localSpeechPreparationState = .ready
        harness.model.localSpeechPreparedModelIdentifier = "qwen3-asr-0.6b-mlx-8bit"

        XCTAssertTrue(harness.model.voiceSetupReadiness.accessibilityRequired)
        XCTAssertFalse(harness.model.voiceSetupReadiness.isComplete)

        harness.model.updatePermissionSnapshot(
            PermissionSnapshot(accessibility: .granted, microphone: .granted)
        )
        XCTAssertTrue(harness.model.voiceSetupReadiness.isComplete)
    }

    func testCursorLivePreviewRequiresAccessibilityEvenWithoutDirectInsertion() {
        let harness = makeHarness(
            permissionSnapshot: PermissionSnapshot(accessibility: .denied, microphone: .granted),
            globalInputCapability: .available
        )
        harness.model.builtinPushToTalkOutputMode = .saveToVoiceGroup
        harness.model.workflows.append(
            WorkflowDefinition(
                name: "Cursor preview",
                trigger: .manual,
                pipeline: PipelineDeclaration(
                    recognizerID: "local-speech",
                    outputActions: [OutputActionReference(id: "record.store")]
                ),
                ui: WorkflowUIConfig(symbolName: "cursorarrow.rays", accentColorName: "blue"),
                metadata: [
                    WorkflowMetadataKey.livePreviewEnabled: "true",
                    WorkflowMetadataKey.livePreviewPlacement: "cursor",
                ]
            )
        )

        XCTAssertTrue(harness.model.voiceSetupReadiness.accessibilityRequired)
    }



    func testSelectingRecordedLocalModelRunsPreparationAndDoesNotFabricateReadyOnFailure() async {
        let probe = SpeechPreparationProbe()
        let expectedError = NSError(
            domain: "VoiceSetupReadinessTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "model cache is unavailable"]
        )
        let harness = makeHarness(
            permissionSnapshot: PermissionSnapshot(accessibility: .granted, microphone: .granted),
            prepareLocalSpeechAction: { settings, _ in
                await probe.recordPreparation(settings: settings)
                throw expectedError
            }
        )
        harness.model.preferredSpeechEngine = .local
        harness.model.downloadedLocalSpeechModels = ["qwen3-asr-0.6b-mlx-8bit"]

        harness.model.useDownloadedLocalSpeechModel("qwen3-asr-0.6b-mlx-8bit")
        await waitForEventProcessing(harness)

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.prepareCount, 1)
        XCTAssertEqual(snapshot.lastSettings?.model, "qwen3-asr-0.6b-mlx-8bit")
        XCTAssertEqual(harness.model.localSpeechPreparationState, .idle)
        XCTAssertEqual(harness.model.voiceSetupReadiness.provider, .localPreparationFailed)
        XCTAssertFalse(harness.model.voiceSetupReadiness.isComplete)
    }

    func testExplicitPreparationFailureIsVisibleInReadiness() async {
        let providerCanary =
            "path=/Users/private/background-model token=background-secret digest=abcdef0123456789"
        let settingsStore = UITestSettingsStore(
            storage: [
                .preferredSpeechEngine: PreferredSpeechEngine.local.rawValue,
                .localSpeechModel: "qwen3-asr-0.6b-mlx-8bit",
                .localSpeechPrewarm: "true",
            ]
        )
        let harness = makeHarness(
            settingsStore: settingsStore,
            permissionSnapshot: PermissionSnapshot(accessibility: .granted, microphone: .granted),
            prepareLocalSpeechAction: { _, _ in
                throw NSError(
                    domain: "VoiceSetupReadinessTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: providerCanary]
                )
            }
        )

        await harness.model.waitForInitialVoiceConfiguration()
        harness.model.prepareLocalSpeechModel()
        await harness.model.waitForLocalSpeechPreparation()

        XCTAssertEqual(harness.model.localSpeechPreparationState, .idle)
        let expected = L10n.localSpeechPreparationFailure(.generic)
        XCTAssertEqual(
            harness.model.localSpeechPreparationError,
            expected.string(for: harness.model.language)
        )
        XCTAssertEqual(harness.model.voiceSetupReadiness.provider, .localPreparationFailed)
        XCTAssertFalse(harness.model.voiceSetupReadiness.isComplete)
        let event = harness.model.eventFeed.last {
            $0.english == expected.english && $0.simplifiedChinese == expected.simplifiedChinese
        }
        XCTAssertNotNil(event)
        let exposedText = ([harness.model.localSpeechPreparationError ?? ""]
            + harness.model.eventFeed.flatMap { [$0.english, $0.simplifiedChinese] })
            .joined(separator: " ")
        XCTAssertFalse(exposedText.contains("/Users/private/background-model"))
        XCTAssertFalse(exposedText.contains("background-secret"))
        XCTAssertFalse(exposedText.contains("abcdef0123456789"))
    }
    func testTrustedPoolModelEnabledAndRecordedIsReadyAfterRelaunch() {
        let descriptor = LocalSpeechModelDescriptor(
            id: "qwen3-asr-0.6b-mlx-8bit",
            englishName: "Qwen3-ASR 0.6B",
            simplifiedChineseName: "Qwen3-ASR 0.6B"
        )
        let harness = makeHarness(
            trustedLocalSpeechModels: [descriptor],
            defaultLocalSpeechModelIdentifier: descriptor.id,
            permissionSnapshot: PermissionSnapshot(accessibility: .granted, microphone: .granted)
        )
        harness.model.preferredSpeechEngine = .local
        harness.model.localSpeechModel = descriptor.id
        harness.model.enabledSpeechModelIDs = [descriptor.id]
        harness.model.downloadedLocalSpeechModels = [descriptor.id]

        XCTAssertEqual(harness.model.localSpeechPreparationState, .idle)
        XCTAssertEqual(harness.model.voiceSetupReadiness.provider, .localReady)
        XCTAssertTrue(harness.model.voiceSetupReadiness.isComplete)
    }

    func testTrustedPoolModelEnabledWithoutRecordStillNeedsPreparation() {
        let descriptor = LocalSpeechModelDescriptor(
            id: "qwen3-asr-0.6b-mlx-8bit",
            englishName: "Qwen3-ASR 0.6B",
            simplifiedChineseName: "Qwen3-ASR 0.6B"
        )
        let harness = makeHarness(
            trustedLocalSpeechModels: [descriptor],
            defaultLocalSpeechModelIdentifier: descriptor.id,
            permissionSnapshot: PermissionSnapshot(accessibility: .granted, microphone: .granted)
        )
        harness.model.preferredSpeechEngine = .local
        harness.model.localSpeechModel = descriptor.id
        harness.model.enabledSpeechModelIDs = [descriptor.id]

        XCTAssertEqual(
            harness.model.voiceSetupReadiness.provider,
            .localNeedsPreparation(downloadIfNeeded: true)
        )
    }

    func testTrustedPoolModelRecordedButNotEnabledStillNeedsPreparation() {
        let descriptor = LocalSpeechModelDescriptor(
            id: "qwen3-asr-0.6b-mlx-8bit",
            englishName: "Qwen3-ASR 0.6B",
            simplifiedChineseName: "Qwen3-ASR 0.6B"
        )
        let harness = makeHarness(
            trustedLocalSpeechModels: [descriptor],
            defaultLocalSpeechModelIdentifier: descriptor.id,
            permissionSnapshot: PermissionSnapshot(accessibility: .granted, microphone: .granted)
        )
        harness.model.preferredSpeechEngine = .local
        harness.model.localSpeechModel = descriptor.id
        harness.model.enabledSpeechModelIDs = []
        harness.model.downloadedLocalSpeechModels = [descriptor.id]

        XCTAssertEqual(
            harness.model.voiceSetupReadiness.provider,
            .localNeedsPreparation(downloadIfNeeded: true)
        )
    }

    func testTrustedPoolModelReportsLegacyPreparingAndFailureStates() {
        let descriptor = LocalSpeechModelDescriptor(
            id: "qwen3-asr-0.6b-mlx-8bit",
            englishName: "Qwen3-ASR 0.6B",
            simplifiedChineseName: "Qwen3-ASR 0.6B"
        )
        let harness = makeHarness(
            trustedLocalSpeechModels: [descriptor],
            defaultLocalSpeechModelIdentifier: descriptor.id,
            permissionSnapshot: PermissionSnapshot(accessibility: .granted, microphone: .granted)
        )
        harness.model.preferredSpeechEngine = .local
        harness.model.localSpeechModel = descriptor.id
        harness.model.enabledSpeechModelIDs = [descriptor.id]
        harness.model.downloadedLocalSpeechModels = [descriptor.id]

        harness.model.localSpeechPreparationState = .preparing
        XCTAssertEqual(harness.model.voiceSetupReadiness.provider, .localPreparing(progress: 0))

        harness.model.localSpeechPreparationState = .idle
        harness.model.localSpeechPreparationError = "failed"
        XCTAssertEqual(harness.model.voiceSetupReadiness.provider, .localPreparationFailed)
    }

}
