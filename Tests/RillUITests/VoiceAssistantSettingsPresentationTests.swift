import RillTestSupport
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
      defaultTTSModelIdentifier: int8.id,
      voiceResourceServices: makeVoiceResourceServicesForTesting(
        prepareWakeWordModel: { _ in "qwen3-asr-test" },
        selectTTSModel: { _ in },
        downloadedTTSModelIdentifiers: [bf16.id],
        validateWakeWordConfiguration: { _ in },
        stopSpeechPlayback: { false }
      )
    )

    XCTAssertEqual(harness.model.settings.ttsModelIdentifier, int8.id)
    XCTAssertEqual(harness.model.voice.ttsResourceState, .notInstalled)
    XCTAssertTrue(harness.model.setPreferredTTSModel(bf16.id))
    XCTAssertEqual(harness.model.voice.ttsResourceState, .ready)
    XCTAssertFalse(harness.model.setPreferredTTSModel("unreviewed"))
    XCTAssertEqual(harness.model.settings.ttsModelIdentifier, bf16.id)
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

    await waitUntil { !harness.model.settings.isLoading }
    XCTAssertEqual(harness.model.settings.ttsModelIdentifier, bf16.id)

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
    let harness = makeHarness(
      permissionSnapshot: PermissionSnapshot(
        accessibility: .granted,
        microphone: .granted
      ),
      voiceResourceServices: makeVoiceResourceServicesForTesting(validateWakeWordConfiguration: {
        configuration in
        guard configuration.phrases == ["Hey Rill", "你好 Rill"] else {
          throw WakeWordSettingsTestError.unexpectedConfiguration
        }
      }))
    harness.model.updateWakeWordResourceState(.ready)

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
      let workflow = harness.model.workflowLibrary.customWorkflows.first(where: {
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
    let harness = makeHarness(
      permissionSnapshot: PermissionSnapshot(
        accessibility: .granted,
        microphone: .granted
      ),
      voiceResourceServices: makeVoiceResourceServicesForTesting(validateWakeWordConfiguration: {
        _ in
      }))
    harness.model.updateWakeWordResourceState(.ready)

    await harness.model.saveWorkflowDraft(
      WorkflowEditorDraft(
        name: "Assistant",
        eventType: .wakeWord,
        wakePhrasesText: "Hey Rill",
        postProcessSteps: [.init(kind: .normalizeWhitespace)],
        destination: .copyToClipboard
      )
    )
    let before = try XCTUnwrap(harness.model.workflowLibrary.customWorkflows.first)

    let result = await harness.model.updateWakeWordSettings(
      phrases: ["你好 Rill"],
      enableListening: true
    )

    XCTAssertEqual(result, .saved)
    let after = try XCTUnwrap(
      harness.model.workflowLibrary.customWorkflows.first(where: { $0.id == before.id })
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
            recognizerID: AppModel.localSpeechRecognizerID
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
      ),
      permissionSnapshot: PermissionSnapshot(
        accessibility: .granted,
        microphone: .granted
      ),
      voiceResourceServices: makeVoiceResourceServicesForTesting(validateWakeWordConfiguration: {
        _ in
      }))

    await waitUntil {
      !harness.model.settings.isLoading
        && harness.model.settings.openAICredentialAvailability == .available
    }
    harness.model.updateWakeWordResourceState(.ready)

    let result = await harness.model.updateWakeWordSettings(
      phrases: ["你好 Rill"],
      enableListening: true
    )

    XCTAssertEqual(result, .saved)
    let customized = try XCTUnwrap(harness.model.workflowLibrary.customWorkflows.first)
    XCTAssertEqual(customized.id, builtinAssistant.id)
    XCTAssertEqual(customized.plan.setup.wakeWord?.phrases, ["你好 Rill"])
    XCTAssertEqual(customized.plan.process, builtinAssistant.plan.process)
    XCTAssertEqual(customized.plan.output, builtinAssistant.plan.output)
    XCTAssertTrue(harness.model.isWorkflowEnabled(customized))
    XCTAssertTrue(harness.model.isWorkflowEnabled(builtinAssistant))
    XCTAssertEqual(harness.model.workflowLibrary.workflows.map(\.id), [builtinAssistant.id])
  }

  @MainActor
  func testVoiceAssistantReadinessAllowsConfiguredLLMAndSystemVoiceFallback() async {
    let assistant = makeAssistantWorkflow()
    let harness = makeHarness(
      workflows: [assistant],
      credentialStore: UITestSecureCredentialStore(
        storage: [.openAIAPIKey: "test-openai-key"]
      ),
      permissionSnapshot: PermissionSnapshot(
        accessibility: .granted,
        microphone: .granted
      )
    )
    await waitUntil {
      !harness.model.settings.isLoading
        && harness.model.settings.openAICredentialAvailability == .available
    }
    harness.model.updateWakeWordResourceState(.ready)

    XCTAssertEqual(harness.model.voiceAssistantReadiness.llm, .configured)
    XCTAssertEqual(
      harness.model.voiceAssistantReadiness.speechOutput,
      .systemFallback
    )
    XCTAssertTrue(harness.model.voiceAssistantReadiness.canEnableListening)
  }

  @MainActor
  func testVoiceAssistantReadinessBlocksKnownInvalidOrFailedLLMConfiguration() async {
    let assistant = makeAssistantWorkflow()
    let harness = makeHarness(
      workflows: [assistant],
      credentialStore: UITestSecureCredentialStore(
        storage: [.openAIAPIKey: "test-openai-key"]
      ),
      permissionSnapshot: PermissionSnapshot(
        accessibility: .granted,
        microphone: .granted
      )
    )
    await waitUntil {
      !harness.model.settings.isLoading
        && harness.model.settings.openAICredentialAvailability == .available
    }
    harness.model.updateWakeWordResourceState(.ready)
    harness.model.applyLanguage(.english)

    harness.model.applyOpenAIBaseURL("http://not-a-loopback.example")
    XCTAssertEqual(
      harness.model.voiceAssistantReadiness.llm,
      .configurationInvalid
    )
    XCTAssertFalse(harness.model.voiceAssistantReadiness.canEnableListening)

    harness.model.applyOpenAIBaseURL(OpenAISettings.defaultBaseURL)
    harness.model.setWorkflowEnabled(true, for: assistant.id)
    XCTAssertEqual(
      harness.model.enabledWorkflows(for: .wakeWord).map(\.id),
      [assistant.id]
    )

    harness.model.settings.openAIConfigurationVerificationState = .failed
    harness.model.settings.openAIVerificationFailure = .authenticationFailed
    XCTAssertEqual(
      harness.model.voiceAssistantReadiness.llm,
      .verificationFailed(.authenticationFailed)
    )
    XCTAssertFalse(harness.model.voiceAssistantReadiness.canEnableListening)
    XCTAssertTrue(harness.model.isWorkflowEnabled(assistant))
    XCTAssertTrue(harness.model.enabledWorkflows(for: .wakeWord).isEmpty)

    harness.model.setWorkflowEnabled(false, for: assistant.id)
    harness.model.setWorkflowEnabled(true, for: assistant.id)
    XCTAssertFalse(harness.model.isWorkflowEnabled(assistant))
    XCTAssertEqual(
      harness.model.workflowLibrary.workflowLibraryError,
      "The current LLM configuration failed verification. Fix it or verify it again before enabling this workflow."
    )
  }

  @MainActor
  func testVoiceAssistantActivationRequiresMicrophoneAndPreparedLocalASR() async {
    let assistant = makeAssistantWorkflow()
    let harness = makeHarness(
      workflows: [assistant],
      credentialStore: UITestSecureCredentialStore(
        storage: [.openAIAPIKey: "test-openai-key"]
      ),
      permissionSnapshot: PermissionSnapshot(
        accessibility: .granted,
        microphone: .denied
      )
    )
    await waitUntil {
      !harness.model.settings.isLoading
        && harness.model.settings.openAICredentialAvailability == .available
    }
    harness.model.applyLanguage(.english)

    harness.model.setWorkflowEnabled(true, for: assistant.id)
    XCTAssertEqual(
      harness.model.workflowLibrary.workflowLibraryError,
      "Grant microphone access before enabling wake-word listening."
    )

    harness.model.updatePermissionSnapshot(
      PermissionSnapshot(accessibility: .granted, microphone: .granted)
    )
    harness.model.setWorkflowEnabled(true, for: assistant.id)
    XCTAssertEqual(
      harness.model.workflowLibrary.workflowLibraryError,
      "Prepare the selected local ASR model before enabling wake-word listening."
    )

    harness.model.updateWakeWordResourceState(.ready)
    harness.model.setWorkflowEnabled(true, for: assistant.id)
    XCTAssertTrue(harness.model.isWorkflowEnabled(assistant))
    XCTAssertNil(harness.model.workflowLibrary.workflowLibraryError)
  }

  @MainActor
  func testWakeWordSettingsRejectInvalidPhraseWithoutCreatingWorkflow() async {
    let harness = makeHarness(
      voiceResourceServices: makeVoiceResourceServicesForTesting(validateWakeWordConfiguration: {
        _ in
      }))

    let result = await harness.model.updateWakeWordSettings(
      phrases: [],
      enableListening: true
    )

    guard case .failed = result else {
      XCTFail("Expected invalid wake-word settings to fail")
      return
    }
    XCTAssertTrue(harness.model.workflowLibrary.customWorkflows.isEmpty)
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

  private func makeAssistantWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
      name: "Voice Assistant",
      titleKey: .voiceAssistant,
      trigger: .wakeWord,
      plan: WorkflowPlan(
        setup: WorkflowSetupPhase(
          speechRoute: WorkflowSpeechRoute(
            selection: .automatic,
            recognizerID: AppModel.localSpeechRecognizerID
          ),
          wakeWord: WakeWordConfiguration(phrases: ["Hey Rill"])
        ),
        process: WorkflowProcessPhase(steps: [
          WorkflowProcessStep(kind: .recognizeSpeech),
          WorkflowProcessStep(kind: .llmRewrite, prompt: "Answer briefly."),
        ]),
        output: WorkflowOutputPhase(actions: [
          OutputActionReference(id: SpeechOutputActionID.speak)
        ])
      ),
      ui: WorkflowUIConfig(symbolName: "sparkles", accentColorName: "purple"),
      metadata: [WorkflowMetadataKey.defaultEnabled: "false"]
    )
  }
}

private enum WakeWordSettingsTestError: Error {
  case unexpectedConfiguration
}
