import XCTest

@testable import RillCore
@testable import RillUI

@MainActor
final class AppModelScalarSettingsAvailabilityTests: XCTestCase {
  func testInvalidClosedScalarValuesRemainUnavailableWithoutMutation() async {
    let invalidValues: [AppSettingKey: String] = [
      .interfaceLanguage: "klingon",
      .systemClipboardCaptureEnabled: "maybe",
      .recordHistoryVisibility: "everything",
      .recordPanelHotkey: "unknown",
      .preferredSpeechEngine: "hybrid",
      .localSpeechPrewarm: "later",
      .builtinPushToTalkOutputMode: "teleport",
      .longRecordingModeEnabled: "occasionally",
    ]
    let store = UITestSettingsStore(storage: invalidValues)
    let harness = makeHarness(settingsStore: store)

    await waitUntil { !harness.model.settings.isLoading }

    XCTAssertEqual(
      harness.model.unavailableScalarSettingKeys,
      Set(invalidValues.keys)
    )
    XCTAssertTrue(harness.model.hasUnavailableScalarSettings(in: .interface))
    XCTAssertTrue(harness.model.hasUnavailableScalarSettings(in: .systemClipboard))
    XCTAssertTrue(harness.model.hasUnavailableScalarSettings(in: .speechRoute))
    XCTAssertTrue(harness.model.hasUnavailableScalarSettings(in: .localSpeech))
    XCTAssertTrue(harness.model.hasUnavailableScalarSettings(in: .input))
    let activity = await store.activitySnapshot()
    XCTAssertEqual(activity.storage, invalidValues)
    XCTAssertTrue(activity.setCounts.isEmpty)
    XCTAssertTrue(activity.removeCounts.isEmpty)
  }

  func testUnavailableScalarDidSetCannotOverwriteOriginalRow() async {
    let storedLanguage = AppLanguage.simplifiedChinese.rawValue
    let store = UITestSettingsStore(
      storage: [.interfaceLanguage: storedLanguage],
      unavailableKeys: [.interfaceLanguage]
    )
    let harness = makeHarness(
      settingsStore: store,
      settingsWriteDebounceDuration: .zero
    )
    await waitUntil { !harness.model.settings.isLoading }

    harness.model.language =
      harness.model.language == .english
      ? .simplifiedChinese
      : .english
    await harness.model.flushPendingPersistenceWrites()

    let activity = await store.activitySnapshot()
    XCTAssertEqual(activity.storage[.interfaceLanguage], storedLanguage)
    XCTAssertNil(activity.setCounts[.interfaceLanguage])
    XCTAssertTrue(harness.model.hasUnavailableScalarSettings(in: .interface))
  }

  func testUnavailableProductionScalarCommandsRejectMemoryAndStorageMutation() async {
    let storedValues: [AppSettingKey: String] = [
      .interfaceLanguage: AppLanguage.english.rawValue,
      .systemClipboardCaptureEnabled: "true",
      .preferredSpeechEngine: PreferredSpeechEngine.local.rawValue,
      .builtinPushToTalkOutputMode: BuiltinPushToTalkOutputMode.pasteIntoApp.rawValue,
      .longRecordingModeEnabled: "false",
    ]
    let store = UITestSettingsStore(
      storage: storedValues,
      unavailableKeys: Set(storedValues.keys)
    )
    let harness = makeHarness(
      settingsStore: store,
      settingsWriteDebounceDuration: .zero
    )
    await waitUntil { !harness.model.settings.isLoading }

    let initialLanguage = harness.model.language
    let initialClipboardCaptureEnabled = harness.model.systemClipboardCaptureEnabled
    let initialEngine = harness.model.preferredSpeechEngine
    let initialOutputMode = harness.model.builtinPushToTalkOutputMode
    let initialLongRecordingMode = harness.model.longRecordingModeEnabled

    XCTAssertFalse(harness.model.setInterfaceLanguage(.simplifiedChinese))
    XCTAssertFalse(harness.model.setSystemClipboardCaptureEnabled(!initialClipboardCaptureEnabled))
    XCTAssertFalse(harness.model.setPreferredSpeechEngine(.local))
    XCTAssertFalse(harness.model.setBuiltinPushToTalkOutputMode(.saveToVoiceGroup))
    XCTAssertFalse(harness.model.setLongRecordingModeEnabled(true))
    await harness.model.flushPendingPersistenceWrites()

    XCTAssertEqual(harness.model.language, initialLanguage)
    XCTAssertEqual(harness.model.systemClipboardCaptureEnabled, initialClipboardCaptureEnabled)
    XCTAssertEqual(harness.model.preferredSpeechEngine, initialEngine)
    XCTAssertEqual(harness.model.builtinPushToTalkOutputMode, initialOutputMode)
    XCTAssertEqual(harness.model.longRecordingModeEnabled, initialLongRecordingMode)
    let activity = await store.activitySnapshot()
    XCTAssertEqual(activity.storage, storedValues)
    XCTAssertTrue(activity.setCounts.isEmpty)
    XCTAssertTrue(activity.removeCounts.isEmpty)
  }

  func testRecoveredScalarDomainsAcceptProductionCommandsAndPersist() async {
    let storedValues: [AppSettingKey: String] = [
      .interfaceLanguage: AppLanguage.english.rawValue,
      .systemClipboardCaptureEnabled: "false",
      .preferredSpeechEngine: PreferredSpeechEngine.local.rawValue,
      .builtinPushToTalkOutputMode: BuiltinPushToTalkOutputMode.pasteIntoApp.rawValue,
      .longRecordingModeEnabled: "false",
    ]
    let store = UITestSettingsStore(
      storage: storedValues,
      unavailableKeys: Set(storedValues.keys)
    )
    let harness = makeHarness(
      settingsStore: store,
      settingsWriteDebounceDuration: .zero
    )
    await waitUntil { !harness.model.settings.isLoading }

    await store.setUnavailableKeys([])
    for domain in [
      ScalarSettingsDomain.interface,
      .systemClipboard,
      .speechRoute,
      .input,
    ] {
      harness.model.retryUnavailableScalarSettings(in: domain)
      await waitUntil {
        !harness.model.isRetryingUnavailableScalarSettings(in: domain)
      }
      XCTAssertFalse(harness.model.hasUnavailableScalarSettings(in: domain))
    }

    XCTAssertTrue(harness.model.setInterfaceLanguage(.simplifiedChinese))
    XCTAssertTrue(harness.model.setSystemClipboardCaptureEnabled(true))
    XCTAssertTrue(harness.model.setBuiltinPushToTalkOutputMode(.saveToVoiceGroup))
    XCTAssertTrue(harness.model.setLongRecordingModeEnabled(true))
    await harness.model.flushPendingPersistenceWrites()

    XCTAssertEqual(harness.model.language, .simplifiedChinese)
    XCTAssertTrue(harness.model.systemClipboardCaptureEnabled)
    XCTAssertEqual(harness.model.preferredSpeechEngine, .local)
    XCTAssertEqual(harness.model.builtinPushToTalkOutputMode, .saveToVoiceGroup)
    XCTAssertTrue(harness.model.longRecordingModeEnabled)
    let activity = await store.activitySnapshot()
    XCTAssertEqual(activity.storage[.interfaceLanguage], AppLanguage.simplifiedChinese.rawValue)
    XCTAssertEqual(activity.storage[.systemClipboardCaptureEnabled], "true")
    XCTAssertEqual(
      activity.storage[.builtinPushToTalkOutputMode],
      BuiltinPushToTalkOutputMode.saveToVoiceGroup.rawValue
    )
    XCTAssertEqual(activity.storage[.longRecordingModeEnabled], "true")
    XCTAssertEqual(activity.setCounts[.interfaceLanguage], 1)
    XCTAssertEqual(activity.setCounts[.systemClipboardCaptureEnabled], 1)
    XCTAssertEqual(activity.setCounts[.builtinPushToTalkOutputMode], 1)
    XCTAssertEqual(activity.setCounts[.longRecordingModeEnabled], 1)
  }

  func testProductionScalarCommandsRejectAfterApplicationShutdown() async {
    let store = UITestSettingsStore()
    let harness = makeHarness(
      settingsStore: store,
      settingsWriteDebounceDuration: .zero
    )
    await waitUntil { !harness.model.settings.isLoading }
    let initialLanguage = harness.model.language
    let initialClipboardCaptureEnabled = harness.model.systemClipboardCaptureEnabled
    let initialEngine = harness.model.preferredSpeechEngine
    let initialOutputMode = harness.model.builtinPushToTalkOutputMode
    let initialLongRecordingMode = harness.model.longRecordingModeEnabled

    await harness.model.stopSettingsReadTasksForApplicationShutdown()

    XCTAssertFalse(
      harness.model.setInterfaceLanguage(
        initialLanguage == .english ? .simplifiedChinese : .english
      )
    )
    XCTAssertFalse(
      harness.model.setSystemClipboardCaptureEnabled(!initialClipboardCaptureEnabled)
    )
    XCTAssertFalse(
      harness.model.setPreferredSpeechEngine(.local)
    )
    XCTAssertFalse(
      harness.model.setBuiltinPushToTalkOutputMode(
        initialOutputMode == .pasteIntoApp ? .saveToVoiceGroup : .pasteIntoApp
      )
    )
    XCTAssertFalse(
      harness.model.setLongRecordingModeEnabled(!initialLongRecordingMode)
    )
    await harness.model.flushPendingPersistenceWrites()

    XCTAssertEqual(harness.model.language, initialLanguage)
    XCTAssertEqual(harness.model.systemClipboardCaptureEnabled, initialClipboardCaptureEnabled)
    XCTAssertEqual(harness.model.preferredSpeechEngine, initialEngine)
    XCTAssertEqual(harness.model.builtinPushToTalkOutputMode, initialOutputMode)
    XCTAssertEqual(harness.model.longRecordingModeEnabled, initialLongRecordingMode)
    let activity = await store.activitySnapshot()
    XCTAssertTrue(activity.setCounts.isEmpty)
    XCTAssertTrue(activity.removeCounts.isEmpty)
  }


  func testLocalSpeechSettingsSourceFailsClosedAndRecoversWithScalarDomain() async throws {
    let store = UITestSettingsStore(
      storage: [.localSpeechModel: "qwen3-asr-1.7b-mlx-8bit"],
      unavailableKeys: [.localSpeechModel]
    )
    let source = LocalSpeechSettingsSource()
    let harness = makeHarness(
      settingsStore: store,
      localSpeechSettingsSource: source
    )
    await waitUntil { !harness.model.settings.isLoading }

    XCTAssertThrowsError(try source.currentSettings()) { error in
      XCTAssertEqual(error as? LocalSpeechSettingsSourceError, .unavailable)
    }

    await store.setUnavailableKeys([])
    harness.model.retryUnavailableScalarSettings(in: .localSpeech)
    await waitUntil {
      !harness.model.isRetryingUnavailableScalarSettings(in: .localSpeech)
    }

    XCTAssertFalse(harness.model.hasUnavailableScalarSettings(in: .localSpeech))
    XCTAssertEqual(try source.currentSettings().model, "qwen3-asr-1.7b-mlx-8bit")
  }

  func testLocalSpeechNewNamespaceWinsLegacyConflictWithoutMigrationWrite() async {
    let store = UITestSettingsStore(
      storage: [
        .localSpeechModel: "qwen3-asr-1.7b-mlx-8bit",
        .legacyWhisperKitModel: "legacy-model",
        .localSpeechPrewarm: "false",
        .legacyWhisperKitPrewarm: "true",
      ]
    )
    let harness = makeHarness(settingsStore: store)

    await waitUntil { !harness.model.settings.isLoading }

    XCTAssertEqual(harness.model.localSpeechModel, "qwen3-asr-1.7b-mlx-8bit")
    XCTAssertFalse(harness.model.localSpeechPrewarm)
    let activity = await store.activitySnapshot()
    XCTAssertTrue(activity.atomicSnapshots.isEmpty)
    XCTAssertNil(activity.setCounts[.legacyWhisperKitModel])
    XCTAssertNil(activity.setCounts[.legacyWhisperKitPrewarm])
  }

  func testLocalSpeechLegacyNamespaceFallsBackAndMigratesThroughNewKeyWriteOwners() async throws {
    let downloadedModels = "[\"legacy-model\"]"
    let store = UITestSettingsStore(
      storage: [
        .legacyWhisperKitModel: "legacy-model",
        .legacyWhisperKitDownloadedModels: downloadedModels,
        .legacyWhisperKitPrewarm: "true",
      ]
    )
    let harness = makeHarness(settingsStore: store)

    await waitUntil { !harness.model.settings.isLoading }
    await harness.model.flushPendingPersistenceWrites()

    XCTAssertEqual(harness.model.localSpeechModel, "qwen3-asr-0.6b-mlx-8bit")
    XCTAssertTrue(harness.model.downloadedLocalSpeechModels.isEmpty)
    XCTAssertTrue(harness.model.localSpeechPrewarm)
    let activity = await store.activitySnapshot()
    XCTAssertEqual(activity.atomicWriteCount, 0)
    XCTAssertEqual(activity.storage[.localSpeechModel], "qwen3-asr-0.6b-mlx-8bit")
    XCTAssertEqual(activity.storage[.localSpeechDownloadedModels], downloadedModels)
    XCTAssertEqual(activity.storage[.localSpeechPrewarm], "true")
    XCTAssertEqual(activity.setCounts[.localSpeechModel], 1)
    XCTAssertEqual(activity.setCounts[.localSpeechDownloadedModels], 1)
    XCTAssertEqual(activity.setCounts[.localSpeechPrewarm], 1)
    XCTAssertNil(activity.setCounts[.legacyWhisperKitModel])
    XCTAssertNil(activity.setCounts[.legacyWhisperKitDownloadedModels])
    XCTAssertNil(activity.setCounts[.legacyWhisperKitPrewarm])
  }

  func testPrewarmChangedDuringInitialReadWinsOverLegacyNamespaceMigration() async {
    let store = UITestSettingsStore(
      storage: [.legacyWhisperKitPrewarm: "false"],
      suspendBatchReads: true
    )
    let harness = makeHarness(
      settingsStore: store,
      settingsWriteDebounceDuration: .zero
    )
    await store.waitUntilBatchReadIsSuspended()

    harness.model.localSpeechPrewarm = true
    await harness.model.flushPendingPersistenceWrites()
    await store.resumeBatchRead()
    await waitUntil { !harness.model.settings.isLoading }
    await harness.model.flushPendingPersistenceWrites()

    XCTAssertTrue(harness.model.localSpeechPrewarm)
    let activity = await store.activitySnapshot()
    XCTAssertEqual(activity.storage[.localSpeechPrewarm], "true")
    XCTAssertEqual(activity.setCounts[.localSpeechPrewarm], 1)
    XCTAssertNil(activity.setCounts[.legacyWhisperKitPrewarm])
  }

  func testUnreadableNewLocalSpeechSettingDoesNotFallBackToLegacyValue() async {
    let store = UITestSettingsStore(
      storage: [
        .localSpeechModel: "protected-new-model",
        .legacyWhisperKitModel: "legacy-model",
      ],
      unavailableKeys: [.localSpeechModel]
    )
    let harness = makeHarness(settingsStore: store)

    await waitUntil { !harness.model.settings.isLoading }

    XCTAssertTrue(harness.model.hasUnavailableScalarSettings(in: .localSpeech))
    let activity = await store.activitySnapshot()
    XCTAssertTrue(activity.atomicSnapshots.isEmpty)
    XCTAssertEqual(activity.storage[.localSpeechModel], "protected-new-model")
  }

  func testReadableNewLocalSpeechSettingIgnoresUnreadableLegacyValue() async {
    let store = UITestSettingsStore(
      storage: [.localSpeechModel: "qwen3-asr-1.7b-mlx-8bit"],
      unavailableKeys: [.legacyWhisperKitModel]
    )
    let harness = makeHarness(settingsStore: store)

    await waitUntil { !harness.model.settings.isLoading }

    XCTAssertFalse(harness.model.hasUnavailableScalarSettings(in: .localSpeech))
    XCTAssertEqual(harness.model.localSpeechModel, "qwen3-asr-1.7b-mlx-8bit")
    let activity = await store.activitySnapshot()
    XCTAssertTrue(activity.atomicSnapshots.isEmpty)
  }

  func testLocalSpeechRecoveryMigratesRetiredModelToTrustedDefault() async throws {
    let defaultModel = "qwen3-asr-0.6b-int8"
    let store = UITestSettingsStore(
      storage: [.localSpeechModel: "breeze-asr-25"],
      unavailableKeys: [.localSpeechModel]
    )
    let source = LocalSpeechSettingsSource()
    let models = trustedLocalSpeechModels(defaultModel: defaultModel)
    let harness = makeHarness(
      settingsStore: store,
      localSpeechSettingsSource: source,
      settingsWriteDebounceDuration: .zero,
      trustedLocalSpeechModels: models,
      defaultLocalSpeechModelIdentifier: defaultModel
    )
    await waitUntil { !harness.model.settings.isLoading }

    await store.setUnavailableKeys([])
    harness.model.retryUnavailableScalarSettings(in: .localSpeech)
    await waitUntil {
      !harness.model.isRetryingUnavailableScalarSettings(in: .localSpeech)
        && !harness.model.hasUnavailableScalarSettings(in: .localSpeech)
    }
    await harness.model.flushPendingPersistenceWrites()

    XCTAssertEqual(harness.model.localSpeechModel, defaultModel)
    XCTAssertEqual(try source.currentSettings().model, defaultModel)
    let activity = await store.activitySnapshot()
    XCTAssertEqual(activity.storage[.localSpeechModel], defaultModel)
    XCTAssertEqual(activity.setCounts[.localSpeechModel], 1)
  }

  func testLocalSpeechRecoveryPreservesSelectionChangedDuringRead() async throws {
    let defaultModel = "qwen3-asr-0.6b-int8"
    let selectedModel = "sense-voice-small-int8"
    let store = UITestSettingsStore(
      storage: [.legacyWhisperKitModel: "breeze-asr-25"],
      unavailableKeys: [.localSpeechModel]
    )
    let source = LocalSpeechSettingsSource()
    let models = trustedLocalSpeechModels(defaultModel: defaultModel)
    let harness = makeHarness(
      settingsStore: store,
      localSpeechSettingsSource: source,
      settingsWriteDebounceDuration: .zero,
      trustedLocalSpeechModels: models,
      defaultLocalSpeechModelIdentifier: defaultModel
    )
    await waitUntil { !harness.model.settings.isLoading }

    await store.setUnavailableKeys([])
    await store.suspendNextBatchRead()
    harness.model.retryUnavailableScalarSettings(in: .localSpeech)
    await store.waitUntilBatchReadIsSuspended()
    harness.model.localSpeechModel = selectedModel
    await store.resumeBatchRead()
    await waitUntil {
      !harness.model.isRetryingUnavailableScalarSettings(in: .localSpeech)
        && !harness.model.hasUnavailableScalarSettings(in: .localSpeech)
    }
    await harness.model.flushPendingPersistenceWrites()

    XCTAssertEqual(harness.model.localSpeechModel, selectedModel)
    XCTAssertEqual(try source.currentSettings().model, selectedModel)
    let activity = await store.activitySnapshot()
    XCTAssertEqual(activity.storage[.localSpeechModel], selectedModel)
    XCTAssertEqual(activity.setCounts[.localSpeechModel], 1)
  }


  func testOpenAISettingsPersistCustomEndpointModelAndCredentialInCorrectStores() async {
    let store = UITestSettingsStore(
      storage: [
        .openAIBaseURL: "https://gateway.example.com/openai/v1",
        .openAIModel: "vendor/custom-model",
      ]
    )
    let credentials = UITestSecureCredentialStore(
      storage: [.openAIAPIKey: "stored-openai-key"]
    )
    let harness = makeHarness(
      settingsStore: store,
      credentialStore: credentials,
      settingsWriteDebounceDuration: .zero
    )
    await waitUntil { !harness.model.settings.isLoading }

    XCTAssertEqual(harness.model.openAIAPIKey, "stored-openai-key")
    XCTAssertEqual(harness.model.openAIBaseURL, "https://gateway.example.com/openai/v1")
    XCTAssertEqual(harness.model.openAIModel, "vendor/custom-model")
    XCTAssertEqual(harness.model.openAICredentialAvailability, .available)

    harness.model.openAIAPIKey = "replacement-openai-key"
    harness.model.openAIBaseURL = "http://localhost:11434/v1"
    harness.model.openAIModel = "local-model"
    await harness.model.flushPendingPersistenceWrites()
    await waitUntil { harness.model.openAICredentialAvailability == .available }

    let settingsActivity = await store.activitySnapshot()
    XCTAssertEqual(settingsActivity.storage[.openAIBaseURL], "http://localhost:11434/v1")
    XCTAssertEqual(settingsActivity.storage[.openAIModel], "local-model")
    XCTAssertNil(settingsActivity.storage[.openAIAPIKey])
    let credentialActivity = await credentials.activitySnapshot()
    XCTAssertEqual(credentialActivity.storage[.openAIAPIKey], "replacement-openai-key")
  }

  func testOpenAIVerificationUsesCurrentCustomSettingsAndRejectsInvalidURL() async {
    let probe = OpenAIVerificationProbe()
    let store = UITestSettingsStore(
      storage: [
        .openAIBaseURL: "https://gateway.example.com/v1",
        .openAIModel: "vendor/verification-model",
      ]
    )
    let credentials = UITestSecureCredentialStore(
      storage: [.openAIAPIKey: "verification-key"]
    )
    let harness = makeHarness(
      settingsStore: store,
      credentialStore: credentials,
      verifyOpenAIConfigurationAction: { settings in
        await probe.record(settings)
      }
    )
    await waitUntil {
      !harness.model.settings.isLoading
        && harness.model.openAICredentialAvailability == .available
    }

    harness.model.verifyOpenAIConfiguration()
    await waitUntil {
      harness.model.openAIConfigurationVerificationState == .verified
    }

    let settings = await probe.lastSettings()
    XCTAssertEqual(
      settings,
      OpenAISettings(
        apiKey: "verification-key",
        baseURL: "https://gateway.example.com/v1",
        model: "vendor/verification-model"
      )
    )

    harness.model.openAIBaseURL = "http://public.example.com/v1"
    XCTAssertFalse(harness.model.canVerifyOpenAIConfiguration)
  }

  func testOpenAIVerificationPreservesSafeFailureCategoryUntilSettingsChange() async {
    let store = UITestSettingsStore(
      storage: [
        .openAIBaseURL: "https://gateway.example.com/v1",
        .openAIModel: "missing-model",
      ]
    )
    let credentials = UITestSecureCredentialStore(
      storage: [.openAIAPIKey: "verification-key"]
    )
    let harness = makeHarness(
      settingsStore: store,
      credentialStore: credentials,
      verifyOpenAIConfigurationAction: { _ in
        throw UITestOpenAIVerificationError(failure: .configurationInvalid)
      }
    )
    await waitUntil {
      !harness.model.settings.isLoading
        && harness.model.openAICredentialAvailability == .available
    }

    harness.model.verifyOpenAIConfiguration()
    await waitUntil {
      harness.model.openAIConfigurationVerificationState == .failed
    }

    XCTAssertEqual(harness.model.openAIVerificationFailure, .configurationInvalid)

    harness.model.openAIModel = "available-model"

    XCTAssertEqual(harness.model.openAIConfigurationVerificationState, .idle)
    XCTAssertNil(harness.model.openAIVerificationFailure)
  }

  private func trustedLocalSpeechModels(
    defaultModel: String
  ) -> [LocalSpeechModelDescriptor] {
    [
      LocalSpeechModelDescriptor(
        id: defaultModel,
        englishName: "Qwen3-ASR 0.6B INT8",
        simplifiedChineseName: "Qwen3-ASR 0.6B INT8"
      ),
      LocalSpeechModelDescriptor(
        id: "sense-voice-small-int8",
        englishName: "SenseVoiceSmall INT8",
        simplifiedChineseName: "SenseVoiceSmall INT8"
      ),
    ]
  }

  func testSecureStoreWithoutSettingsStoreKeepsAllStoredDomainsUnavailable() async {
    let credentials = UITestSecureCredentialStore(
      storage: [.openAIAPIKey: "keychain-only-key"]
    )
    let whisperWorkflow = providerWorkflow(
      name: "Local",
      recognizerID: AppModel.localSpeechRecognizerID
    )
    let harness = makeHarness(
      workflow: whisperWorkflow,
      settingsStore: nil,
      usesEphemeralSettingsStoreWhenNil: false,
      credentialStore: credentials
    )
    await waitUntil { !harness.model.settings.isLoading }

    XCTAssertEqual(harness.model.unavailableScalarSettingKeys, AppModel.scalarSettingsKeys)
    XCTAssertEqual(harness.model.workflowLibrary.workflowLibraryAvailability, .unavailable)
    XCTAssertEqual(harness.model.downloadedLocalSpeechModelsAvailability, .unavailable)
    XCTAssertEqual(harness.model.vocabulary.availability, .unavailable)
    XCTAssertEqual(harness.model.openAIAPIKey, "keychain-only-key")
    XCTAssertEqual(harness.model.openAICredentialAvailability, .inaccessible)

    // Local speech uses the process-wide session source rather than
    // forcing a durable write before every run. The source remains typed
    // unavailable, so shared runtime preflight still blocks capture.
    try? await harness.model.persistProviderSettingsForRun(whisperWorkflow)
    XCTAssertThrowsError(try harness.model.localSpeechSettingsSource.currentSettings()) {
      XCTAssertEqual($0 as? LocalSpeechSettingsSourceError, .unavailable)
    }
  }

  func testUnavailableWarningsAreFixedAndBilingual() {
    XCTAssertEqual(
      ScalarSettingsDomain.interface.unavailableWarning(language: .english),
      "Some saved interface settings could not be read. These controls are locked to preserve the original stored values."
    )
    XCTAssertEqual(
      ScalarSettingsDomain.speechRoute.unavailableWarning(language: .simplifiedChinese),
      "部分已保存的语音路由设置无法读取。相关控件已锁定，以保留原始存储值。"
    )
    XCTAssertEqual(
      ScalarSettingsDomain.input.unavailableWarning(language: .simplifiedChinese),
      "部分已保存的输入设置无法读取。相关控件已锁定，以保留原始存储值。"
    )
  }

  private func providerWorkflow(
    name: String,
    recognizerID: String
  ) -> WorkflowDefinition {
    WorkflowDefinition(
      name: name,
      trigger: .manual,
      pipeline: PipelineDeclaration(
        recognizerID: recognizerID,
        outputActions: [OutputActionReference(id: "ui.test.action")]
      ),
      ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
    )
  }

  private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0..<200 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out waiting for scalar settings state.", file: file, line: line)
  }
}

private struct UITestOpenAIVerificationError: OpenAIVerificationFailureProviding {
  let failure: OpenAIVerificationFailure

  var openAIVerificationFailure: OpenAIVerificationFailure { failure }
}

private actor OpenAIVerificationProbe {
  private var settings: OpenAISettings?

  func record(_ settings: OpenAISettings) {
    self.settings = settings
  }

  func lastSettings() -> OpenAISettings? {
    settings
  }
}
