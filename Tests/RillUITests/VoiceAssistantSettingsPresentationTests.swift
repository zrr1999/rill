import XCTest

@testable import RillCore
@testable import RillUI

final class VoiceAssistantSettingsPresentationTests: XCTestCase {
  @MainActor
  func testTTSSelectionDefaultsToInt8AndReflectsInstalledModels() {
    let int4 = TTSModelOption(
      id: "tts-4bit",
      precision: "INT4",
      approximateDownloadByteCount: 1_694_000_000,
      isDefault: false
    )
    let int8 = TTSModelOption(
      id: "tts-8bit",
      precision: "INT8",
      approximateDownloadByteCount: 1_974_000_000,
      isDefault: true
    )
    let bf16 = TTSModelOption(
      id: "tts-bf16",
      precision: "BF16",
      approximateDownloadByteCount: 2_500_000_000,
      isDefault: false
    )
    let harness = makeHarness(
      ttsModelOptions: [int4, int8, bf16],
      defaultTTSModelIdentifier: int8.id
    )

    harness.model.installVoiceAssistantResourceActions(
      prepareWakeWordModel: { _ in "qwen3-asr-test" },
      prepareTTSModel: { _, _ in },
      selectTTSModel: { _ in },
      downloadedTTSModelIdentifiers: [bf16.id],
      validateWakeWordConfiguration: { _ in },
      stopSpeechPlayback: { false }
    )

    XCTAssertEqual(harness.model.ttsModelIdentifier, int8.id)
    XCTAssertEqual(harness.model.ttsResourceState, .notInstalled)
    XCTAssertTrue(harness.model.setPreferredTTSModel(bf16.id))
    XCTAssertEqual(harness.model.ttsResourceState, .ready)
    XCTAssertFalse(harness.model.setPreferredTTSModel("unreviewed"))
    XCTAssertEqual(harness.model.ttsModelIdentifier, bf16.id)
  }

  @MainActor
  func testTTSSelectionLoadsAndPersistsReviewedModel() async {
    let int4 = TTSModelOption(
      id: "tts-4bit",
      precision: "INT4",
      approximateDownloadByteCount: 1_694_000_000,
      isDefault: false
    )
    let int8 = TTSModelOption(
      id: "tts-8bit",
      precision: "INT8",
      approximateDownloadByteCount: 1_974_000_000,
      isDefault: true
    )
    let bf16 = TTSModelOption(
      id: "tts-bf16",
      precision: "BF16",
      approximateDownloadByteCount: 2_500_000_000,
      isDefault: false
    )
    let store = UITestSettingsStore(storage: [.ttsModel: bf16.id])
    let harness = makeHarness(
      settingsStore: store,
      settingsWriteDebounceDuration: .zero,
      ttsModelOptions: [int4, int8, bf16],
      defaultTTSModelIdentifier: int8.id
    )

    await waitUntil { !harness.model.isLoadingSettings }
    XCTAssertEqual(harness.model.ttsModelIdentifier, bf16.id)

    XCTAssertTrue(harness.model.setPreferredTTSModel(int4.id))
    await harness.model.flushPendingPersistenceWrites()

    let activity = await store.activitySnapshot()
    XCTAssertEqual(activity.storage[.ttsModel], int4.id)
    XCTAssertEqual(activity.setCounts[.ttsModel], 1)
  }

  func testUnavailableAndInactiveResourcesHideInapplicableActions() {
    let visibility = VoiceAssistantSettingsActionVisibility(
      wakeWordState: .unavailable(.distributionLicenseUnverified),
      ttsState: .ready,
      isSpeechPlaybackActive: false
    )

    XCTAssertFalse(visibility.showsWakeWordPreparation)
    XCTAssertFalse(visibility.showsTTSPreparation)
    XCTAssertFalse(visibility.showsStopPlayback)
  }

  func testOnlyCurrentlyAvailableActionsAreShown() {
    let visibility = VoiceAssistantSettingsActionVisibility(
      wakeWordState: .failed("network"),
      ttsState: .notInstalled,
      isSpeechPlaybackActive: true
    )

    XCTAssertTrue(visibility.showsWakeWordPreparation)
    XCTAssertTrue(visibility.showsTTSPreparation)
    XCTAssertTrue(visibility.showsStopPlayback)
  }

  func testPreparationInProgressHidesDuplicateDownloadActions() {
    let visibility = VoiceAssistantSettingsActionVisibility(
      wakeWordState: .preparing(progress: 0.25),
      ttsState: .preparing(progress: nil),
      isSpeechPlaybackActive: false
    )

    XCTAssertFalse(visibility.showsWakeWordPreparation)
    XCTAssertFalse(visibility.showsTTSPreparation)
  }

  @MainActor
  func testWakeWordSettingsCreateAndEnableDefaultDictationWorkflow() async {
    let harness = makeHarness()
    harness.model.installWakeWordConfigurationValidationAction { configuration in
      guard configuration.phrases == ["Hey Rill", "你好 Rill"] else {
        throw WakeWordSettingsTestError.unexpectedConfiguration
      }
    }

    XCTAssertEqual(
      harness.model.wakeWordSettingsSnapshot,
      WakeWordSettingsSnapshot(
        phrases: WakeWordConfiguration.defaultPhrases,
        isEnabled: false,
        workflowName: nil
      )
    )

    let result = await harness.model.updateWakeWordSettings(
      phrases: ["Hey Rill", "你好 Rill"],
      enableListening: true
    )

    XCTAssertEqual(result, .saved)
    guard
      let workflow = harness.model.customWorkflows.first(where: {
        $0.trigger == .wakeWord
      })
    else {
      XCTFail("Expected a saved wake-word workflow")
      return
    }
    XCTAssertEqual(workflow.plan.setup.wakeWord?.phrases, ["Hey Rill", "你好 Rill"])
    XCTAssertTrue(harness.model.isWorkflowEnabled(workflow))
    XCTAssertEqual(
      WorkflowEditorDraft.DestinationChoice(workflow: workflow),
      .pasteIntoApp
    )
  }

  @MainActor
  func testWakeWordSettingsPreserveExistingWorkflowPipeline() async throws {
    let harness = makeHarness()
    harness.model.installWakeWordConfigurationValidationAction { _ in }
    await harness.model.saveWorkflowDraft(
      WorkflowEditorDraft(
        name: "Assistant",
        eventType: .wakeWord,
        wakePhrasesText: "Hey Rill",
        postProcessSteps: [.init(kind: .normalizeWhitespace)],
        destination: .copyToClipboard
      )
    )
    let before = try XCTUnwrap(harness.model.customWorkflows.first)

    let result = await harness.model.updateWakeWordSettings(
      phrases: ["你好 Rill"],
      enableListening: true
    )

    XCTAssertEqual(result, .saved)
    let after = try XCTUnwrap(
      harness.model.customWorkflows.first(where: { $0.id == before.id })
    )
    XCTAssertEqual(after.plan.setup.wakeWord?.phrases, ["你好 Rill"])
    XCTAssertEqual(after.plan.process, before.plan.process)
    XCTAssertEqual(after.plan.output, before.plan.output)
    XCTAssertEqual(after.metadata, before.metadata)
  }

  @MainActor
  func testWakeWordSettingsCustomizeBuiltinVoiceAssistantWithoutLosingLLMOrTTS() async throws {
    let builtinAssistant = WorkflowDefinition(
      name: "Voice Assistant",
      titleKey: .voiceAssistant,
      trigger: .wakeWord,
      plan: WorkflowPlan(
        setup: WorkflowSetupPhase(
          speechRoute: WorkflowSpeechRoute(
            selection: .automatic,
            recognizerID: AppModel.sherpaOnnxRecognizerID
          ),
          vocabularyBindings: [
            VocabularyCollectionBinding(
              collectionID: VocabularyCollection.personalID
            )
          ],
          wakeWord: WakeWordConfiguration(phrases: ["Hey Rill"])
        ),
        process: WorkflowProcessPhase(steps: [
          WorkflowProcessStep(kind: .recognizeSpeech),
          WorkflowProcessStep(kind: .applyVocabulary),
          WorkflowProcessStep(kind: .normalizeWhitespace),
          WorkflowProcessStep(
            kind: .llmRewrite,
            prompt: "Answer briefly for speech."
          ),
        ]),
        output: WorkflowOutputPhase(
          actions: [
            OutputActionReference(
              id: SpeechOutputActionID.speak,
              configuration: [
                SpeechOutputActionConfigurationKey.provider:
                  SpeechSynthesisProvider.automatic.rawValue,
                SpeechOutputActionConfigurationKey.voice:
                  Qwen3TTSVoice.vivian.rawValue,
              ]
            )
          ]
        )
      ),
      ui: WorkflowUIConfig(symbolName: "sparkles", accentColorName: "purple"),
      metadata: [
        WorkflowMetadataKey.catalog: BuiltinWorkflowRoutingValue.catalog,
        WorkflowMetadataKey.defaultEnabled: "false",
      ]
    )
    let harness = makeHarness(
      workflows: [builtinAssistant],
      credentialStore: UITestSecureCredentialStore(
        storage: [.openAIAPIKey: "test-openai-key"]
      )
    )
    harness.model.installWakeWordConfigurationValidationAction { _ in }
    await waitUntil {
      !harness.model.isLoadingSettings
        && harness.model.openAICredentialAvailability == .available
    }

    let result = await harness.model.updateWakeWordSettings(
      phrases: ["你好 Rill"],
      enableListening: true
    )

    XCTAssertEqual(result, .saved)
    let customized = try XCTUnwrap(harness.model.customWorkflows.first)
    XCTAssertEqual(customized.plan.setup.wakeWord?.phrases, ["你好 Rill"])
    XCTAssertEqual(customized.plan.process, builtinAssistant.plan.process)
    XCTAssertEqual(customized.plan.output, builtinAssistant.plan.output)
    XCTAssertTrue(harness.model.isWorkflowEnabled(customized))
    XCTAssertFalse(harness.model.isWorkflowEnabled(builtinAssistant))
  }

  @MainActor
  func testWakeWordSettingsRejectInvalidPhraseWithoutCreatingWorkflow() async {
    let harness = makeHarness()
    harness.model.installWakeWordConfigurationValidationAction { _ in }

    let result = await harness.model.updateWakeWordSettings(
      phrases: [],
      enableListening: true
    )

    guard case .failed = result else {
      XCTFail("Expected invalid wake-word settings to fail")
      return
    }
    XCTAssertTrue(harness.model.customWorkflows.isEmpty)
  }

  @MainActor
  private func waitUntil(
    timeout: Duration = .seconds(1),
    predicate: @escaping @MainActor () -> Bool
  ) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !predicate() && clock.now < deadline {
      await Task.yield()
    }
    XCTAssertTrue(predicate())
  }
}

private enum WakeWordSettingsTestError: Error {
  case unexpectedConfiguration
}
