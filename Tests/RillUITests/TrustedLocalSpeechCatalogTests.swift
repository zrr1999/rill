import XCTest

@testable import RillCore
@testable import RillUI

private actor ResidentModelSynchronizationProbe {
  private var calls: [(added: Set<String>, removed: Set<String>)] = []

  func record(added: Set<String>, removed: Set<String>) {
    calls.append((added, removed))
  }

  func snapshot() -> [(added: Set<String>, removed: Set<String>)] {
    calls
  }
}

private actor EnabledSpeechModelPreparationProbe {
  private var modelIDs: [String] = []

  func record(_ modelID: String) {
    modelIDs.append(modelID)
  }

  func snapshot() -> [String] {
    modelIDs
  }
}

@MainActor
final class TrustedLocalSpeechCatalogTests: XCTestCase {
  func testEmptyCatalogCannotEnableLocalSpeechThroughAnInjectedAvailabilityFlag() {
    let harness = makeHarness(localSpeechTrustMaterialAvailable: true,
      trustedLocalSpeechModels: [], defaultLocalSpeechModelIdentifier: nil)
    XCTAssertFalse(harness.model.localSpeechTrustMaterialAvailable)
    XCTAssertTrue(harness.model.workflowSelectableLocalSpeechModels.isEmpty)
  }

  func testLocalSpeechTestWorkflowDerivesFromBuiltinRecognitionAndTargetsVoiceGroup() throws {
    let unrelated = makeDefaultWorkflow()
    let speechRecognition = WorkflowDefinition(
      name: "Speech Recognition",
      trigger: .hotkey,
      pipeline: PipelineDeclaration(
        recognizerID: AppModel.localSpeechRecognizerID,
        outputActions: [OutputActionReference(id: "focused-application.insert")]
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
      AppModel.localSpeechRecognizerID
    )
    XCTAssertEqual(testWorkflow.plan.output.actions.map(\.id), ["record.store"])
    XCTAssertEqual(testWorkflow.targetRecordCollectionIDs, [RecordCollection.voiceInputID])
    XCTAssertTrue(speechRecognition.targetRecordCollectionIDs.isEmpty)
    XCTAssertNil(testWorkflow.metadata[WorkflowMetadataKey.catalog])
  }

  func testTrustedCatalogIsTheOnlySelectableSurfaceAndPreparationClearsAmbientSourceState() async {
    let probe = SpeechPreparationProbe()
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
    XCTAssertEqual(harness.model.workflowSelectableLocalSpeechModels, [models[0].id])
    XCTAssertEqual(harness.model.localSpeechModel, models[0].id)
    XCTAssertEqual(
      harness.model.localSpeechModelDisplayName(models[1].id, includeStatus: true),
      harness.model.language == .english
        ? models[1].englishName
        : models[1].simplifiedChineseName
    )

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
      Set([models[1].id]),
      "The resident model pool owns startup loading; the legacy readiness path must not invent a completed download."
    )
    XCTAssertEqual(harness.model.currentLocalSpeechSettings().modelRepo, "")
    XCTAssertEqual(harness.model.currentLocalSpeechSettings().modelToken, "")
    XCTAssertEqual(harness.model.currentLocalSpeechSettings().modelFolder, "")
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

  func testSettingsChangesDoNotStartExplicitModelPreparation() async {
    let probe = SpeechPreparationProbe()
    let models = makeModels()
    let harness = makeHarness(
      trustedLocalSpeechModels: models,
      defaultLocalSpeechModelIdentifier: models[0].id,
      prepareLocalSpeechAction: { settings, _ in
        await probe.recordPreparation(settings: settings)
        return "unreviewed-model"
      }
    )
    harness.model.preferredSpeechEngine = .local
    harness.model.localSpeechPrewarm = true

    await harness.model.waitForLocalSpeechPreparation()

    let snapshot = await probe.snapshot()
    XCTAssertEqual(snapshot.prepareCount, 0)
    XCTAssertNil(harness.model.localSpeechPreparedModelIdentifier)
    XCTAssertNil(harness.model.localSpeechPreparationError)
    XCTAssertEqual(harness.model.localSpeechPreparationState, .idle)
  }

  func testResidentModelSynchronizationPreservesRapidSettingChangeOrder() async {
    let models = makeModels()
    let probe = ResidentModelSynchronizationProbe()
    let harness = makeHarness(
      trustedLocalSpeechModels: models,
      defaultLocalSpeechModelIdentifier: models[0].id,
      synchronizeResidentSpeechModelsAction: { added, removed in
        try? await Task.sleep(for: .milliseconds(20))
        guard !Task.isCancelled else { return }
        await probe.record(added: added, removed: removed)
      }
    )

    harness.model.setSpeechModelEnabled(models[1].id, enabled: true)
    harness.model.setSpeechModelResident(models[1].id, resident: true)
    harness.model.setSpeechModelResident(models[0].id, resident: false)

    await waitUntil {
      // The asynchronous probe is checked below; keep yielding until the
      // synchronization chain itself has had time to drain.
      harness.model.residentSpeechModelIDs == [models[1].id]
    }
    try? await Task.sleep(for: .milliseconds(80))

    let calls = await probe.snapshot()
    XCTAssertEqual(calls.count, 2)
    XCTAssertEqual(calls[0].added, [models[1].id])
    XCTAssertTrue(calls[0].removed.isEmpty)
    XCTAssertTrue(calls[1].added.isEmpty)
    XCTAssertEqual(calls[1].removed, [models[0].id])
  }

  func testResidentModelBudgetRequiresExplicitConfirmationAndInvalidatesOnChange() {
    let gib: UInt64 = 1_073_741_824
    let models = [
      LocalSpeechModelDescriptor(
        id: "qwen3-asr-0.6b-mlx-8bit",
        engine: .mlxAudioSwift,
        englishName: "Qwen3-ASR 0.6B",
        simplifiedChineseName: "Qwen3-ASR 0.6B",
        approximateDownloadByteCount: gib,
        conservativeRuntimePeakByteCount: gib
      ),
      LocalSpeechModelDescriptor(
        id: "qwen3-asr-1.7b-mlx-8bit",
        engine: .mlxAudioSwift,
        englishName: "Qwen3-ASR 1.7B",
        simplifiedChineseName: "Qwen3-ASR 1.7B",
        approximateDownloadByteCount: 2 * gib,
        conservativeRuntimePeakByteCount: 2 * gib
      ),
    ]
    let harness = makeHarness(
      trustedLocalSpeechModels: models,
      defaultLocalSpeechModelIdentifier: models[0].id,
      localSpeechPhysicalMemoryGiB: 8
    )

    harness.model.setSpeechModelEnabled(models[1].id, enabled: true)
    harness.model.setSpeechModelResident(models[1].id, resident: true)

    XCTAssertEqual(harness.model.residentSpeechModelIDs, [models[0].id])
    XCTAssertEqual(harness.model.pendingResidentSpeechModelIDs, Set(models.map(\.id)))
    XCTAssertTrue(harness.model.pendingResidentSpeechModelBudget?.requiresConfirmation == true)

    harness.model.confirmPendingResidentSpeechModels()

    XCTAssertEqual(harness.model.residentSpeechModelIDs, Set(models.map(\.id)))
    XCTAssertEqual(
      harness.model.residentSpeechBudgetConfirmation,
      harness.model.residentSpeechModelBudget.confirmationFingerprint
    )

    harness.model.setSpeechModelEnabled(models[1].id, enabled: false)

    XCTAssertEqual(harness.model.residentSpeechModelIDs, [models[0].id])
    XCTAssertNil(harness.model.residentSpeechBudgetConfirmation)
  }

  func testEnablingModelStartsPredownloadWithoutMakingItResident() async {
    let models = makeModels()
    let probe = EnabledSpeechModelPreparationProbe()
    let harness = makeHarness(
      trustedLocalSpeechModels: models,
      defaultLocalSpeechModelIdentifier: models[0].id,
      prepareEnabledSpeechModelAction: { modelID in
        await probe.record(modelID)
      }
    )

    harness.model.setSpeechModelEnabled(models[1].id, enabled: true)
    try? await Task.sleep(for: .milliseconds(20))
    let preparedModelIDs = await probe.snapshot()

    XCTAssertEqual(preparedModelIDs, [models[1].id])
    XCTAssertTrue(harness.model.enabledSpeechModelIDs.contains(models[1].id))
    XCTAssertFalse(harness.model.residentSpeechModelIDs.contains(models[1].id))
  }

  func testMeasuredModelPeakOverridesEstimatePersistsAndInvalidatesConfirmation() async throws {
    let modelID = "qwen3-asr-0.6b-mlx-8bit"
    let model = LocalSpeechModelDescriptor(
      id: modelID,
      engine: .mlxAudioSwift,
      englishName: "Qwen3-ASR 0.6B",
      simplifiedChineseName: "Qwen3-ASR 0.6B",
      approximateDownloadByteCount: 600_000_000,
      conservativeRuntimePeakByteCount: 900_000_000
    )
    let settingsStore = UITestSettingsStore()
    let harness = makeHarness(
      settingsStore: settingsStore,
      trustedLocalSpeechModels: [model],
      defaultLocalSpeechModelIdentifier: modelID
    )
    await waitUntil { !harness.model.isLoadingSettings }
    harness.model.residentSpeechBudgetConfirmation =
      harness.model.residentSpeechModelBudget.confirmationFingerprint

    harness.model.recordMeasuredSpeechModelPeak(
      modelID: modelID,
      peakByteCount: 1_200_000_000
    )
    await harness.model.flushPendingPersistenceWrites()

    XCTAssertEqual(
      harness.model.speechModelResourceCatalog.first?.estimatedPeakByteCount,
      1_200_000_000
    )
    XCTAssertNil(harness.model.residentSpeechBudgetConfirmation)
    let stored = await settingsStore.activitySnapshot().storage[.speechModelMeasuredPeaks]
    let decoded = try XCTUnwrap(stored).data(using: .utf8).map {
      try JSONDecoder().decode([String: UInt64].self, from: $0)
    }
    XCTAssertEqual(decoded, [modelID: 1_200_000_000])

    let restored = makeHarness(
      settingsStore: settingsStore,
      trustedLocalSpeechModels: [model],
      defaultLocalSpeechModelIdentifier: modelID
    )
    await waitUntil { !restored.model.isLoadingSettings }
    XCTAssertEqual(
      restored.model.speechModelResourceCatalog.first?.measuredPeakByteCount,
      1_200_000_000
    )
  }

  private func makeModels() -> [LocalSpeechModelDescriptor] {
    [
      LocalSpeechModelDescriptor(
        id: "qwen3-asr-0.6b-mlx-8bit",
        engine: .mlxAudioSwift,
        englishName: "Qwen3-ASR 0.6B INT8",
        simplifiedChineseName: "Qwen3-ASR 0.6B INT8"
      ),
      LocalSpeechModelDescriptor(
        id: "qwen3-asr-1.7b-mlx-8bit",
        engine: .mlxAudioSwift,
        englishName: "Qwen3-ASR 1.7B INT8",
        simplifiedChineseName: "Qwen3-ASR 1.7B INT8"
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
