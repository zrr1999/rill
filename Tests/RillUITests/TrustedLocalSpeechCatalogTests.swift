import XCTest

@testable import RillCore
@testable import RillUI

@MainActor
final class TrustedLocalSpeechCatalogTests: XCTestCase {
  func testLocalSpeechTestWorkflowDerivesFromBuiltinRecognitionAndTargetsVoiceGroup() throws {
    let unrelated = makeDefaultWorkflow()
    let speechRecognition = WorkflowDefinition(
      name: "Speech Recognition",
      trigger: .hotkey,
      pipeline: PipelineDeclaration(
        recognizerID: AppModel.sherpaOnnxRecognizerID,
        outputActions: [OutputActionReference(id: "inject.text")]
      ),
      ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "red"),
      metadata: [
        WorkflowMetadataKey.catalog: BuiltinWorkflowRoutingValue.catalog,
        WorkflowMetadataKey.builtinKind: AppModel.builtinPushToTalkKindValue,
        WorkflowMetadataKey.triggerGesture: BuiltinWorkflowRoutingValue.pushToTalkGesture,
        WorkflowMetadataKey.recognizerSelectionMode: "auto",
      ]
    )
    let harness = makeHarness(workflows: [unrelated, speechRecognition])

    let testWorkflow = try XCTUnwrap(harness.model.localSpeechTestWorkflow)

    XCTAssertEqual(testWorkflow.id, AppModel.localSpeechTestWorkflowID)
    XCTAssertEqual(testWorkflow.trigger, .manual)
    XCTAssertEqual(testWorkflow.plan.setup.speechRoute?.selection, .fixed)
    XCTAssertEqual(
      testWorkflow.plan.setup.speechRoute?.recognizerID,
      AppModel.sherpaOnnxRecognizerID
    )
    XCTAssertEqual(testWorkflow.plan.output.actions.map(\.id), ["stack.push"])
    XCTAssertEqual(testWorkflow.targetClipboardGroupID, ClipboardGroup.voiceGroupID)
    XCTAssertNil(speechRecognition.targetClipboardGroupID)
    XCTAssertNil(testWorkflow.metadata[WorkflowMetadataKey.catalog])
  }

  func testTrustedCatalogIsTheOnlySelectableSurfaceAndPreparationClearsAmbientSourceState() async {
    let probe = WhisperKitPrepareProbe()
    let models = makeModels()
    let harness = makeHarness(
      trustedLocalSpeechModels: models,
      defaultLocalSpeechModelIdentifier: models[0].id,
      prepareLocalSpeechAction: { settings, _ in
        await probe.recordPreparation(settings: settings)
        return settings.model
      }
    )

    XCTAssertTrue(harness.model.localSpeechTrustMaterialAvailable)
    XCTAssertEqual(harness.model.preferredSpeechEngine, .local)
    XCTAssertEqual(harness.model.workflowSelectableLocalSpeechModels, models.map(\.id))
    XCTAssertEqual(harness.model.localSpeechModel, models[0].id)
    XCTAssertEqual(
      harness.model.localSpeechModelDisplayName(models[1].id, includeStatus: true),
      harness.model.language == .english
        ? models[1].englishName
        : models[1].simplifiedChineseName
    )

    harness.model.legacyWhisperKitModelRepo = "untrusted/repository"
    harness.model.legacyWhisperKitModelToken = "secret-canary"
    harness.model.legacyWhisperKitModelFolder = "/tmp/untrusted"
    harness.model.preferredSpeechEngine = .local
    harness.model.selectTrustedLocalSpeechModel(models[1].id)
    await waitUntil { harness.model.localSpeechPreparationState == .ready }

    let snapshot = await probe.snapshot()
    XCTAssertEqual(snapshot.prepareCount, 1)
    XCTAssertEqual(snapshot.lastSettings?.model, models[1].id)
    XCTAssertEqual(snapshot.lastSettings?.modelRepo, "")
    XCTAssertEqual(snapshot.lastSettings?.modelToken, "")
    XCTAssertEqual(snapshot.lastSettings?.modelFolder, "")
    XCTAssertEqual(harness.model.localSpeechPreparedModelIdentifier, models[1].id)

    harness.model.selectTrustedLocalSpeechModel("unreviewed-model")
    XCTAssertEqual(harness.model.localSpeechModel, models[1].id)
  }

  func testStoredUntrustedModelAndSourceFieldsNormalizeToCatalogDefault() async throws {
    let models = makeModels()
    let downloadedJSON = try String(
      data: JSONEncoder().encode([models[1].id, "stale-unreviewed-model"]),
      encoding: .utf8
    )
    let settingsStore = UITestSettingsStore(storage: [
      .localSpeechModel: "stale-unreviewed-model",
      .localSpeechDownloadedModels: try XCTUnwrap(downloadedJSON),
      .legacyWhisperKitModelRepo: "untrusted/repository",
      .legacyWhisperKitModelFolder: "/tmp/untrusted",
    ])
    let credentialStore = UITestSecureCredentialStore(storage: [
      .legacyWhisperKitModelToken: "secret-canary"
    ])
    let harness = makeHarness(
      settingsStore: settingsStore,
      credentialStore: credentialStore,
      trustedLocalSpeechModels: models,
      defaultLocalSpeechModelIdentifier: models[0].id
    )

    await waitUntil { !harness.model.isLoadingSettings }
    await harness.model.flushPendingPersistenceWrites()

    XCTAssertEqual(harness.model.localSpeechModel, models[0].id)
    XCTAssertEqual(
      Set(harness.model.downloadedLocalSpeechModels),
      Set(models.map(\.id)),
      "The trusted default is prepared automatically when local speech is the product default."
    )
    XCTAssertEqual(harness.model.legacyWhisperKitModelRepo, "")
    XCTAssertEqual(harness.model.legacyWhisperKitModelToken, "")
    XCTAssertEqual(harness.model.legacyWhisperKitModelFolder, "")
    XCTAssertEqual(harness.model.currentLocalSpeechSettings().model, models[0].id)
    let activity = await settingsStore.activitySnapshot()
    XCTAssertEqual(activity.storage[.localSpeechModel], models[0].id)
    XCTAssertEqual(activity.setCounts[.localSpeechModel], 1)
  }

  func testStoredExactSherpaModelIdentifiersRemainSelectedWithoutMigrationWrite() async {
    let models = makeModels()

    for model in models {
      let settingsStore = UITestSettingsStore(storage: [
        .localSpeechModel: model.id
      ])
      let harness = makeHarness(
        settingsStore: settingsStore,
        settingsWriteDebounceDuration: .zero,
        trustedLocalSpeechModels: models,
        defaultLocalSpeechModelIdentifier: models[0].id
      )

      await waitUntil { !harness.model.isLoadingSettings }
      await harness.model.flushPendingPersistenceWrites()

      XCTAssertEqual(harness.model.localSpeechModel, model.id)
      let activity = await settingsStore.activitySnapshot()
      XCTAssertEqual(activity.storage[.localSpeechModel], model.id)
      XCTAssertNil(activity.setCounts[.localSpeechModel])
    }
  }

  func testTrustedModelSelectedDuringInitialReadWinsOverLegacyMigration() async {
    let models = makeModels()
    let settingsStore = UITestSettingsStore(
      storage: [
        .legacyWhisperKitModel: "distil-whisper_distil-large-v3_594MB"
      ],
      suspendBatchReads: true
    )
    let harness = makeHarness(
      settingsStore: settingsStore,
      settingsWriteDebounceDuration: .zero,
      trustedLocalSpeechModels: models,
      defaultLocalSpeechModelIdentifier: models[0].id
    )
    await settingsStore.waitUntilBatchReadIsSuspended()

    harness.model.selectTrustedLocalSpeechModel(models[1].id)
    await harness.model.flushPendingPersistenceWrites()
    await settingsStore.resumeBatchRead()
    await waitUntil { !harness.model.isLoadingSettings }
    await harness.model.flushPendingPersistenceWrites()

    XCTAssertEqual(harness.model.localSpeechModel, models[1].id)
    XCTAssertEqual(harness.model.currentLocalSpeechSettings().model, models[1].id)
    let activity = await settingsStore.activitySnapshot()
    XCTAssertEqual(activity.storage[.localSpeechModel], models[1].id)
    XCTAssertEqual(activity.setCounts[.localSpeechModel], 1)
  }

  func testMalformedTrustedCatalogFailsClosed() {
    let model = makeModels()[0]
    let duplicateHarness = makeHarness(
      trustedLocalSpeechModels: [model, model],
      defaultLocalSpeechModelIdentifier: model.id
    )
    XCTAssertFalse(duplicateHarness.model.localSpeechTrustMaterialAvailable)
    XCTAssertTrue(duplicateHarness.model.trustedLocalSpeechModels.isEmpty)
    XCTAssertEqual(duplicateHarness.model.preferredSpeechEngine, .local)

    let missingDefaultHarness = makeHarness(
      trustedLocalSpeechModels: [model],
      defaultLocalSpeechModelIdentifier: "missing-model"
    )
    XCTAssertFalse(missingDefaultHarness.model.localSpeechTrustMaterialAvailable)
    XCTAssertTrue(missingDefaultHarness.model.trustedLocalSpeechModels.isEmpty)
    XCTAssertEqual(missingDefaultHarness.model.preferredSpeechEngine, .local)
  }

  func testHardwareRecommendationUsesMemoryFitAndModelPriority() throws {
    let models = [
      LocalSpeechModelDescriptor(
        id: "performance-300m-int8",
        englishName: "Performance 300M",
        simplifiedChineseName: "性能 300M",
        category: .performance,
        parameterCountMillions: 300,
        minimumSystemMemoryGiB: 8,
        recommendedSystemMemoryGiB: 8,
        hardwareRecommendationPriority: 10
      ),
      LocalSpeechModelDescriptor(
        id: "intelligent-800m-int8",
        englishName: "Intelligent 800M INT8",
        simplifiedChineseName: "智能 800M INT8",
        category: .intelligent,
        parameterCountMillions: 800,
        minimumSystemMemoryGiB: 12,
        recommendedSystemMemoryGiB: 16,
        hardwareRecommendationPriority: 30
      ),
      LocalSpeechModelDescriptor(
        id: "intelligent-800m-fp16",
        englishName: "Intelligent 800M FP16",
        simplifiedChineseName: "智能 800M FP16",
        category: .intelligent,
        parameterCountMillions: 800,
        quantization: .fp16,
        minimumSystemMemoryGiB: 16,
        recommendedSystemMemoryGiB: 32,
        hardwareRecommendationPriority: 40
      ),
    ]

    for (memory, expectedModel) in [
      (8, models[0].id),
      (16, models[1].id),
      (32, models[2].id),
    ] {
      let harness = makeHarness(
        trustedLocalSpeechModels: models,
        defaultLocalSpeechModelIdentifier: models[0].id,
        localSpeechPhysicalMemoryGiB: memory
      )
      XCTAssertEqual(harness.model.recommendedLocalSpeechModelIdentifier, expectedModel)
      let description = harness.model.localSpeechModelHardwareDescription(
        try XCTUnwrap(models.first { $0.id == expectedModel })
      )
      XCTAssertTrue(description.contains("\(memory) GB"))
    }
  }

  func testTrustedPreparationRejectsMismatchedProviderResult() async {
    let models = makeModels()
    let harness = makeHarness(
      trustedLocalSpeechModels: models,
      defaultLocalSpeechModelIdentifier: models[0].id,
      prepareLocalSpeechAction: { _, _ in "unreviewed-model" }
    )

    harness.model.prepareLocalSpeechModel()
    await waitUntil {
      harness.model.localSpeechPreparationState == .idle
        && harness.model.localSpeechPreparationError != nil
    }

    XCTAssertNil(harness.model.localSpeechPreparedModelIdentifier)
    XCTAssertFalse(harness.model.downloadedLocalSpeechModels.contains("unreviewed-model"))
    XCTAssertEqual(
      harness.model.localSpeechPreparationError,
      L10n.localSpeechPreparationFailure(.trustRoot).string(for: harness.model.language)
    )
  }

  func testTrustedWarmupRejectsMismatchedProviderResult() async {
    let models = makeModels()
    let harness = makeHarness(
      trustedLocalSpeechModels: models,
      defaultLocalSpeechModelIdentifier: models[0].id,
      warmLocalSpeechForCaptureAction: { _, _ in "unreviewed-model" }
    )
    harness.model.preferredSpeechEngine = .local
    harness.model.localSpeechPrewarm = true

    harness.model.queueLocalSpeechReadinessIfNeeded()
    await waitUntil {
      harness.model.localSpeechPreparationState == .idle
        && harness.model.localSpeechPreparationError != nil
    }

    XCTAssertNil(harness.model.localSpeechPreparedModelIdentifier)
    XCTAssertFalse(harness.model.downloadedLocalSpeechModels.contains("unreviewed-model"))
    XCTAssertEqual(
      harness.model.localSpeechPreparationError,
      L10n.localSpeechPreparationFailure(.trustRoot).string(for: harness.model.language)
    )
  }

  private func makeModels() -> [LocalSpeechModelDescriptor] {
    [
      LocalSpeechModelDescriptor(
        id: "qwen3-asr-0.6b-int8",
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

  private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
  ) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition(), clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition())
  }
}
