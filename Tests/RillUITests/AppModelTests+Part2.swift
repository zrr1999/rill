import RillDomainTestSupport
import RillTestSupport

@testable import RillCore
@testable import RillWorkflows
import XCTest
@testable import RillUI

@MainActor
extension AppModelTests {
  func testPersistedVoiceResultReloadsAndTerminalUpdatesPresentation() async throws {
    let historyRepository = InMemoryHistoryRepository()
    let voiceWorkflow = makeBuiltinPushToTalkWorkflow()
    let harness = makeHarness(workflows: [voiceWorkflow], historyRepository: historyRepository)
    await waitForListenerSetup(harness)
    let runID = UUID()

    await harness.eventBus.publish(
      .runStarted(
        RunSnapshot(
          runID: runID,
          workflowID: voiceWorkflow.id,
          workflow: voiceWorkflow.presentation,
          trigger: .manual
        )
      )
    )
    await harness.eventBus.publish(
      .recognitionCompleted(run: .init(runID: runID), result: RecognitionResult(rawText: "draft voice", bestText: "draft voice"))
    )
    await waitForEventProcessing(harness)

    XCTAssertEqual(harness.model.voice.lastCompletedText, "draft voice")

    let correctionSource = RecognitionCorrectionSource(
      preMappingText: "draft voice",
      context: VocabularyRuleContext(
        bundleIdentifier: "com.example.editor",
        locale: "en-US"
      )
    )

    let record = WorkflowResultRecord(
      id: runID, runID: runID, workflowID: voiceWorkflow.id,
      workflow: voiceWorkflow.presentation, finalText: "final voice", outcome: .completed,
      correctionSource: correctionSource, trigger: .manual
    )
    try await historyRepository.save(record)
    await harness.eventBus.publish(.runHistoryUpdated(.persisted(runID: runID)))

    await harness.eventBus.publish(
      .runCompleted(
        WorkflowRunSummary(
          runID: runID,
          workflowID: voiceWorkflow.id,
          workflow: voiceWorkflow.presentation,
          trigger: .manual,
          finalText: "final voice",
          correctionSource: correctionSource
        )
      )
    )
    await waitForEventProcessing(harness)

    let storedRecords = try await historyRepository.records(matching: HistoryQuery(runID: runID))
    XCTAssertEqual(harness.model.voice.lastCompletedText, "final voice")
    XCTAssertNil(harness.model.lastFailure)
    XCTAssertEqual(harness.model.recentVoiceResultRecords.first?.finalText, "final voice")
    XCTAssertEqual(harness.model.recentVoiceResultRecords.first?.correctionSource, correctionSource)
    XCTAssertEqual(storedRecords.first?.finalText, "final voice")
    XCTAssertEqual(storedRecords.first?.outcome, .completed)
    XCTAssertEqual(storedRecords.first?.correctionSource, correctionSource)
    XCTAssertEqual(storedRecords.first?.trigger, .manual)
  }

  func testClipboardReplayThroughVoiceWorkflowDoesNotPersistOrSurfacePayloadAsVoiceHistory() async throws {
    let historyRepository = InMemoryHistoryRepository()
    let voiceWorkflow = makeBuiltinPushToTalkWorkflow()
    let harness = makeHarness(
      workflows: [voiceWorkflow],
      historyRepository: historyRepository
    )
    await waitForListenerSetup(harness)
    let runID = UUID()
    let payloadCanary = "clipboard-replay-payload-canary"

    await harness.eventBus.publish(
      .runCompleted(
        WorkflowRunSummary(
          runID: runID,
          workflowID: voiceWorkflow.id,
          workflow: voiceWorkflow.presentation,
          trigger: .recordReplay,
          finalText: payloadCanary,
          correctionSource: RecognitionCorrectionSource(
            preMappingText: payloadCanary,
            context: VocabularyRuleContext(locale: "en-US")
          )
        )
      )
    )
    await waitForEventProcessing(harness)

    let storedRecords = try await historyRepository.records(
      matching: HistoryQuery(runID: runID)
    )
    XCTAssertTrue(storedRecords.isEmpty)
    XCTAssertFalse(harness.model.history.historyRecords.contains { $0.runID == runID })
    XCTAssertFalse(harness.model.recentVoiceResultRecords.contains { $0.runID == runID })
    XCTAssertNil(harness.model.voice.lastCompletedText)
    XCTAssertFalse(
      harness.model.history.eventFeed.contains { entry in
        entry.english.contains(payloadCanary)
          || entry.simplifiedChinese.contains(payloadCanary)
      })
  }

  func testRunCancellationClearsActiveStateWithoutCreatingFailureHistory() async throws {
    let historyRepository = InMemoryHistoryRepository()
    let voiceWorkflow = makeBuiltinPushToTalkWorkflow()
    let harness = makeHarness(
      workflows: [voiceWorkflow],
      historyRepository: historyRepository
    )
    await waitForListenerSetup(harness)
    let runID = UUID()

    await harness.eventBus.publish(
      .runStarted(
        RunSnapshot(
          runID: runID,
          workflowID: voiceWorkflow.id,
          workflow: voiceWorkflow.presentation,
          trigger: .manual
        )
      )
    )
    await harness.eventBus.publish(
      .candidateResolutionRequested(
        CandidateResolutionCase(
          runID: runID,
          recognitionResult: RecognitionResult(rawText: "draft", bestText: "draft"),
          policy: UncertaintyPolicy(mode: .blocking)
        )
      )
    )
    await waitForEventProcessing(harness)
    XCTAssertTrue(harness.model.voice.isRunning)
    XCTAssertNotNil(harness.model.pendingRuns[runID])
    XCTAssertEqual(harness.model.voice.pendingResolution?.runID, runID)

    await harness.eventBus.publish(
      .runCancelled(
        WorkflowRunCancelledSummary(
          runID: runID,
          stage: .resolving,
          wasPartiallyCompleted: false
        )
      )
    )
    await waitForEventProcessing(harness)

    let storedRecords = try await historyRepository.records(
      matching: HistoryQuery(runID: runID)
    )
    XCTAssertFalse(harness.model.voice.isRunning)
    XCTAssertNil(harness.model.voice.activeRunID)
    XCTAssertNil(harness.model.pendingRuns[runID])
    XCTAssertNil(harness.model.voice.pendingResolution)
    XCTAssertEqual(harness.model.voice.workflowAudioRunState, .idle)
    XCTAssertNil(harness.model.lastFailure)
    XCTAssertTrue(storedRecords.isEmpty)
    XCTAssertFalse(harness.model.history.historyRecords.contains { $0.runID == runID })
    XCTAssertTrue(harness.model.history.eventFeed.contains { $0.english == "Run cancelled." })
  }

  func testVoiceGroupTargetRunIsShownInRecentVoiceResults() async {
    let workflow = WorkflowDefinition(
      name: "Save to Voice Group",
      plan: {
        var plan = WorkflowPlan(
          setup: WorkflowSetupPhase(speechRoute: WorkflowSpeechRoute(recognizerID: "ui.test.recognizer")),
          process: WorkflowProcessPhase(steps: [
            WorkflowProcessStep(kind: .recognizeSpeech), WorkflowProcessStep(kind: .resolveUncertainty, uncertaintyPolicy: .init()),
            WorkflowProcessStep(kind: .applyVocabulary),
          ]), output: WorkflowOutputPhase(actions: [OutputActionReference(id: "record.store")], deliveryPolicy: DeliveryPolicy(strategy: .collectionFirst)))
        for index in plan.output.actions.indices {
          plan.output.actions[index].configuration.collections = (RecordCollection.voiceInputID.rawValue.uuidString).split(separator: ",").compactMap {
            UUID(uuidString: String($0))
          }
        }
        return plan
      }(),
      ui: WorkflowUIConfig(symbolName: "tray.and.arrow.down", accentColorName: "purple"),
      properties: .init())
    let harness = makeHarness(workflows: [workflow])
    await waitForListenerSetup(harness)
    let runID = UUID()

    await harness.eventBus.publish(
      .runStarted(
        RunSnapshot(
          runID: runID,
          workflowID: workflow.id,
          workflow: workflow.presentation,
          trigger: .manual
        )
      )
    )
    await harness.eventBus.publish(
      .runHistoryUpdated(
        .sessionOnly(
          WorkflowResultRecord(
            id: runID, runID: runID, workflowID: workflow.id, workflow: workflow.presentation,
            finalText: "saved voice group text", isRecordRelated: true, outcome: .completed, trigger: .manual
          ))))
    await harness.eventBus.publish(
      .runCompleted(
        WorkflowRunSummary(
          runID: runID,
          workflowID: workflow.id,
          workflow: workflow.presentation,
          trigger: .manual,
          finalText: "saved voice group text"
        )
      )
    )
    await waitForEventProcessing(harness)

    XCTAssertEqual(harness.model.recentVoiceResultRecords.first?.runID, runID)
    XCTAssertEqual(harness.model.recentVoiceResultRecords.first?.finalText, "saved voice group text")
    XCTAssertEqual(harness.model.recentVoiceResultRecords.first?.isRecordRelated, true)
  }

  func testRunWorkflowPassesResolvedAutomaticWorkflowToAudioCapture() async throws {
    let probe = WorkflowStartProbe()
    var workflow = makeBuiltinPushToTalkWorkflow()
    workflow.plan.output.actions = [.init(id: RecordActionID.store, configuration: .init(collections: [RecordCollection.voiceInputID.rawValue]))]
    let harness = makeHarness(
      workflows: [workflow],
      startWorkflowAudioRunAction: { workflow, binding, _ in
        await probe.record(workflow: workflow, binding: binding)
      }
    )

    harness.model.runWorkflow(workflow, initiatedBy: .hotkey)
    await waitForEventProcessing(harness)

    let calls = await probe.snapshot()
    let captured = try XCTUnwrap(calls.first)
    XCTAssertEqual(captured.binding, .hotkey)
    XCTAssertEqual(captured.workflow.plan.setup.speechRoute?.recognizerID, AppModel.localSpeechRecognizerID)
    XCTAssertEqual(captured.workflow.plan.output.actions.first?.id, "record.store")
    XCTAssertEqual(
      captured.workflow.targetRecordCollectionIDs,
      [RecordCollection.voiceInputID]
    )
  }

  func testAutomaticWorkflowKeepsPerWorkflowASRMetadataWhenResolved() async throws {
    let probe = WorkflowStartProbe()
    let workflow = WorkflowDefinition(
      name: "Auto Cloud Mandarin",
      trigger: .manual,
      plan: {
        var plan = WorkflowPlan(
          setup: WorkflowSetupPhase(speechRoute: WorkflowSpeechRoute(recognizerID: AppModel.localSpeechRecognizerID)),
          process: WorkflowProcessPhase(steps: [
            WorkflowProcessStep(kind: .recognizeSpeech), WorkflowProcessStep(kind: .resolveUncertainty, uncertaintyPolicy: .init()),
            WorkflowProcessStep(kind: .applyVocabulary),
          ]), output: WorkflowOutputPhase(actions: [OutputActionReference(id: "record.store")], deliveryPolicy: .init(strategy: .collectionFirst)))
        plan.setup.speechRoute?.selection = .automatic
        plan.setup.speechRoute?.language = "zh-CN"
        return plan
      }(),
      ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue"),
      properties: .init())
    let harness = makeHarness(
      workflows: [workflow],
      startWorkflowAudioRunAction: { workflow, binding, _ in
        await probe.record(workflow: workflow, binding: binding)
      }
    )
    harness.model.runWorkflow(workflow)
    await waitForEventProcessing(harness)

    let calls = await probe.snapshot()
    let captured = try XCTUnwrap(calls.first)
    XCTAssertEqual(captured.workflow.plan.setup.speechRoute?.recognizerID, AppModel.localSpeechRecognizerID)
    XCTAssertEqual(captured.workflow.plan.setup.speechRoute?.language, "zh-CN")
  }

  func testSavingAndDeletingCustomWorkflowPersistsOnlyTOML() async throws {
    let settingsStore = UITestSettingsStore()
    let files = UITestWorkflowFileStore()
    let model = makeHarness(settingsStore: settingsStore, workflowFileStore: files).model
    await model.waitForInitialVoiceConfiguration()
    await model.saveWorkflowDraft(
      WorkflowEditorDraft(
        name: "Follow-up Draft", recognizer: .localSpeech,
        postProcessSteps: [.init(kind: .normalizeWhitespace)], destination: .copyToClipboard))
    await model.flushPendingPersistenceWrites()
    let records = await files.records()
    let saved = try XCTUnwrap(records.first)
    XCTAssertEqual(saved.workflow.name, "Follow-up Draft")
    XCTAssertEqual(model.workflowLibrary.customWorkflows.map(\.id), [saved.workflow.id])
    let legacySettings = try await settingsStore.string(forKey: .workflowLibrary)
    XCTAssertNil(legacySettings)
    await model.deleteCustomWorkflow(saved.workflow)
    await model.flushPendingPersistenceWrites()
    let remaining = await files.records()
    XCTAssertTrue(remaining.isEmpty)
    XCTAssertTrue(model.workflowLibrary.customWorkflows.isEmpty)
  }

  func testNewWorkflowWithDuplicateNameGetsNumericSuffix() async throws {
    let harness = makeHarness()
    await harness.model.waitForInitialVoiceConfiguration()

    await harness.model.saveWorkflowDraft(
      WorkflowEditorDraft(
        name: "Speech Recognition",
        recognizer: .localSpeech,
        postProcessSteps: [.init(kind: .normalizeWhitespace)],
        destination: .copyToClipboard
      )
    )

    XCTAssertNil(harness.model.workflowLibrary.workflowEditorError)
    XCTAssertEqual(harness.model.workflowLibrary.customWorkflows.map(\.name), ["Speech Recognition"])

    await harness.model.saveWorkflowDraft(
      WorkflowEditorDraft(
        name: "Speech Recognition",
        recognizer: .localSpeech,
        postProcessSteps: [.init(kind: .normalizeWhitespace)],
        destination: .copyToClipboard
      )
    )

    XCTAssertNil(harness.model.workflowLibrary.workflowEditorError)
    XCTAssertEqual(
      harness.model.workflowLibrary.customWorkflows.map(\.name),
      ["Speech Recognition 2", "Speech Recognition"]
    )
  }

  func testRenamingWorkflowOntoExistingNameReportsError() async throws {
    let alpha = makeNamedWorkflow("Alpha")
    let beta = makeNamedWorkflow("Beta")
    let harness = makeHarness(workflows: [alpha, beta])
    await harness.model.waitForInitialVoiceConfiguration()

    var draft = try XCTUnwrap(WorkflowEditorDraft(workflow: beta))
    draft.name = "Alpha"
    await harness.model.saveWorkflowDraft(draft, editing: beta.id)

    XCTAssertEqual(
      harness.model.workflowLibrary.workflowEditorError,
      L10n.workflowText(.workflowNameTakenError, language: harness.model.settings.language)
    )
    XCTAssertTrue(harness.model.workflowLibrary.customWorkflows.isEmpty)
    XCTAssertEqual(harness.model.workflowLibrary.workflows.map(\.name), ["Alpha", "Beta"])
  }

  func testEditingWorkflowWithoutNameChangeKeepsSaving() async throws {
    let first = makeNamedWorkflow("Speech Recognition")
    let second = makeNamedWorkflow("Speech Recognition")
    let harness = makeHarness(workflows: [first, second])
    await harness.model.waitForInitialVoiceConfiguration()

    // The duplicated name is pre-existing user data; an edit that does
    // not rename the workflow must not be blocked by it.
    var draft = try XCTUnwrap(WorkflowEditorDraft(workflow: second))
    draft.destination = .copyToClipboard
    await harness.model.saveWorkflowDraft(draft, editing: second.id)

    XCTAssertNil(harness.model.workflowLibrary.workflowEditorError)
    XCTAssertEqual(harness.model.workflowLibrary.customWorkflows.map(\.name), ["Speech Recognition"])
  }

  private func makeNamedWorkflow(_ name: String) -> WorkflowDefinition {
    WorkflowDefinition(
      name: name,
      trigger: .manual,
      plan: WorkflowPlan(
        setup: WorkflowSetupPhase(speechRoute: WorkflowSpeechRoute(recognizerID: AppModel.localSpeechRecognizerID)),
        process: WorkflowProcessPhase(
          steps: [
            WorkflowProcessStep(kind: .recognizeSpeech), WorkflowProcessStep(kind: .resolveUncertainty, uncertaintyPolicy: .init()),
            WorkflowProcessStep(kind: .applyVocabulary),
          ] + ([PostProcessStep(kind: .normalizeWhitespace)]).map(WorkflowProcessStep.init)),
        output: WorkflowOutputPhase(actions: [OutputActionReference(id: "system-clipboard.copy")], deliveryPolicy: .init(strategy: .immediate))),
      ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
    )
  }

  func testTOMLStoreIsSourceOfTruthForVisualSaveAndDelete() async throws {
    let settingsStore = UITestSettingsStore()
    let workflowFileStore = UITestWorkflowFileStore()
    let harness = makeHarness(
      settingsStore: settingsStore,
      workflowFileStore: workflowFileStore
    )
    await harness.model.waitForInitialVoiceConfiguration()

    await harness.model.saveWorkflowDraft(
      WorkflowEditorDraft(
        name: "TOML Draft",
        recognizer: .localSpeech,
        postProcessSteps: [.init(kind: .normalizeWhitespace)],
        destination: .copyToClipboard
      )
    )
    await harness.model.flushPendingPersistenceWrites()

    let savedRecords = await workflowFileStore.records()
    let savedRecord = try XCTUnwrap(savedRecords.first)
    XCTAssertEqual(savedRecord.workflow.name, "TOML Draft")
    XCTAssertEqual(harness.model.workflowLibrary.customWorkflows.map(\.id), [savedRecord.workflow.id])

    let storedValue = try await settingsStore.string(forKey: .workflowLibrary)
    XCTAssertNil(storedValue)

    await harness.model.deleteCustomWorkflow(savedRecord.workflow)
    let remainingRecords = await workflowFileStore.records()
    XCTAssertTrue(remainingRecords.isEmpty)
    XCTAssertTrue(harness.model.workflowLibrary.customWorkflows.isEmpty)
  }

  func testBuiltInWorkflowSaveUsesSameIdentityAndRestoreDeletesOverride() async throws {
    let builtInWorkflow = makeBuiltinPushToTalkWorkflow()
    let workflowFileStore = UITestWorkflowFileStore()
    let harness = makeHarness(
      workflows: [builtInWorkflow],
      workflowFileStore: workflowFileStore
    )
    await harness.model.waitForInitialVoiceConfiguration()

    var draft = try XCTUnwrap(WorkflowEditorDraft(workflow: builtInWorkflow))
    draft.name = "Focused Dictation"
    draft.destination = .copyToClipboard
    await harness.model.saveWorkflowDraft(draft, editing: builtInWorkflow.id)

    let savedRecords = await workflowFileStore.records()
    let savedRecord = try XCTUnwrap(savedRecords.first)
    XCTAssertEqual(savedRecord.workflow.id, builtInWorkflow.id)
    XCTAssertEqual(savedRecord.workflow.name, "Focused Dictation")
    XCTAssertEqual(savedRecord.workflow.plan.setup.speechRoute?.selection, .automatic)
    XCTAssertTrue(savedRecord.workflow.prefersAutomaticRecognizerSelection)
    XCTAssertEqual(harness.model.workflowLibrary.customWorkflows.map(\.id), [builtInWorkflow.id])
    XCTAssertTrue(harness.model.userCreatedWorkflows.isEmpty)
    XCTAssertEqual(harness.model.editableBuiltInWorkflows.map(\.name), ["Focused Dictation"])
    XCTAssertEqual(harness.model.workflowLibrary.workflows.map(\.id), [builtInWorkflow.id])
    XCTAssertTrue(harness.model.canRestoreBuiltInWorkflow(savedRecord.workflow))

    await harness.model.restoreBuiltInWorkflowToDefault(savedRecord.workflow)

    let restoredRecords = await workflowFileStore.records()
    XCTAssertTrue(restoredRecords.isEmpty)
    XCTAssertTrue(harness.model.workflowLibrary.customWorkflows.isEmpty)
    XCTAssertTrue(harness.model.userCreatedWorkflows.isEmpty)
    XCTAssertEqual(harness.model.editableBuiltInWorkflows.map(\.name), [builtInWorkflow.name])
    XCTAssertEqual(harness.model.workflowLibrary.workflows.map(\.id), [builtInWorkflow.id])
    XCTAssertFalse(harness.model.canRestoreBuiltInWorkflow(builtInWorkflow))
  }

  func testCustomWorkflowSharingBuiltInNameShadowsBuiltInUntilDeleted() async throws {
    let builtInWorkflow = makeBuiltinPushToTalkWorkflow()
    let workflowFileStore = UITestWorkflowFileStore()
    let harness = makeHarness(
      workflows: [builtInWorkflow],
      workflowFileStore: workflowFileStore
    )
    await harness.model.waitForInitialVoiceConfiguration()
    XCTAssertEqual(harness.model.workflowLibrary.workflows.map(\.id), [builtInWorkflow.id])

    var draft = harness.model.defaultWorkflowDraft()
    draft.name = "Accurate Transcription"  // English display name of the built-in
    await harness.model.saveWorkflowDraft(draft)

    let custom = try XCTUnwrap(harness.model.workflowLibrary.customWorkflows.first)
    XCTAssertNotEqual(custom.id, builtInWorkflow.id)
    // The built-in is shadowed everywhere instead of listed twice.
    XCTAssertEqual(harness.model.workflowLibrary.workflows.map(\.id), [custom.id])
    XCTAssertTrue(harness.model.editableBuiltInWorkflows.isEmpty)
    XCTAssertFalse(harness.model.isBuiltInWorkflow(custom))

    await harness.model.deleteCustomWorkflow(custom)

    XCTAssertEqual(harness.model.workflowLibrary.workflows.map(\.id), [builtInWorkflow.id])
    XCTAssertEqual(harness.model.editableBuiltInWorkflows.map(\.id), [builtInWorkflow.id])
  }

  func testCustomWorkflowMatchingBuiltInChineseDisplayNameShadowsIt() async throws {
    let builtInWorkflow = makeBuiltinPushToTalkWorkflow()
    let harness = makeHarness(workflows: [builtInWorkflow])
    await harness.model.waitForInitialVoiceConfiguration()

    var draft = harness.model.defaultWorkflowDraft()
    draft.name = "精准转写"  // Simplified Chinese display name of the built-in
    await harness.model.saveWorkflowDraft(draft)

    XCTAssertEqual(harness.model.workflowLibrary.customWorkflows.count, 1)
    XCTAssertEqual(harness.model.workflowLibrary.workflows.map(\.name), ["精准转写"])
  }

  func testCustomWorkflowSharingNameWithAnotherCustomStillGetsNumericSuffix() async throws {
    let builtInWorkflow = makeBuiltinPushToTalkWorkflow()
    let harness = makeHarness(workflows: [builtInWorkflow])
    await harness.model.waitForInitialVoiceConfiguration()

    var first = harness.model.defaultWorkflowDraft()
    first.name = "Accurate Transcription"
    await harness.model.saveWorkflowDraft(first)
    var second = harness.model.defaultWorkflowDraft()
    second.name = "Accurate Transcription"
    await harness.model.saveWorkflowDraft(second)

    XCTAssertEqual(
      harness.model.workflowLibrary.customWorkflows.map(\.name).sorted(),
      ["Accurate Transcription", "Accurate Transcription 2"]
    )
    // The built-in stays shadowed by the first custom.
    XCTAssertEqual(harness.model.workflowLibrary.workflows.count, 2)
    XCTAssertFalse(harness.model.workflowLibrary.workflows.contains { $0.id == builtInWorkflow.id })
  }

  func testSelectingTrustedModelAutomaticallyPreparesIt() async {
    let probe = SpeechPreparationProbe()
    let harness = makeHarness(
      prepareLocalSpeechAction: { settings, progressCallback in
        await probe.recordPreparation(settings: settings)
        let progress = Progress(totalUnitCount: 4)
        progress.completedUnitCount = 2
        progressCallback(progress)
        await probe.recordProgress(progress)
        return settings.model
      }
    )

    await harness.model.waitForInitialVoiceConfiguration()
    harness.model.selectTrustedLocalSpeechModel(appModelTestTrustedLocalSpeechModels()[1].id)
    await harness.model.voice.waitForLocalSpeechPreparation()

    let snapshot = await probe.snapshot()
    XCTAssertEqual(snapshot.prepareCount, 1)
    XCTAssertEqual(snapshot.lastSettings?.model, appModelTestTrustedLocalSpeechModels()[1].id)
    XCTAssertEqual(snapshot.reportedProgress, [0.5])
    XCTAssertEqual(harness.model.settings.localSpeechModel, appModelTestTrustedLocalSpeechModels()[1].id)
    XCTAssertEqual(harness.model.voice.localSpeechPreparationState, .ready)
    XCTAssertEqual(harness.model.voice.localSpeechPreparationProgress, 1)
    XCTAssertEqual(harness.model.voice.localSpeechPreparedModelIdentifier, appModelTestTrustedLocalSpeechModels()[1].id)
    XCTAssertEqual(harness.model.voice.downloadedLocalSpeechModels, [appModelTestTrustedLocalSpeechModels()[1].id])
    XCTAssertNil(harness.model.voice.localSpeechPreparationError)
  }

  func testManualLocalSpeechPreparationFailureDoesNotExposeProviderPayload() async throws {
    let providerCanary =
      "path=/Users/private/manual-model token=manual-secret digest=1234567890abcdef"
    let harness = makeHarness(
      prepareLocalSpeechAction: { _, _ in
        throw NSError(
          domain: "AppModelTests.manual-whisperkit",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: providerCanary]
        )
      }
    )

    await harness.model.waitForInitialVoiceConfiguration()
    harness.model.prepareLocalSpeechModel()
    await harness.model.voice.waitForLocalSpeechPreparation()

    let expected = L10n.localSpeechPreparationFailure(.generic)
    XCTAssertEqual(harness.model.voice.localSpeechPreparationState, .idle)
    XCTAssertEqual(
      harness.model.voice.localSpeechPreparationError,
      expected.string(for: harness.model.settings.language)
    )
    let event = try XCTUnwrap(
      harness.model.history.eventFeed.last {
        $0.english == expected.english
          && $0.simplifiedChinese == expected.simplifiedChinese
      }
    )
    XCTAssertEqual(event.english, expected.english)
    XCTAssertEqual(event.simplifiedChinese, expected.simplifiedChinese)
    let exposedText =
      ([harness.model.voice.localSpeechPreparationError ?? ""]
      + harness.model.history.eventFeed.flatMap { [$0.english, $0.simplifiedChinese] })
      .joined(separator: " ")
    XCTAssertFalse(exposedText.contains("/Users/private/manual-model"))
    XCTAssertFalse(exposedText.contains("manual-secret"))
    XCTAssertFalse(exposedText.contains("1234567890abcdef"))
  }

  func testManualLocalSpeechPreparationPreservesAllowlistedTrustedStage() async throws {
    let harness = makeHarness(
      prepareLocalSpeechAction: { _, _ in
        throw LocalSpeechPreparationFailure(stage: .integrity)
      }
    )

    await harness.model.waitForInitialVoiceConfiguration()
    harness.model.prepareLocalSpeechModel()
    await harness.model.voice.waitForLocalSpeechPreparation()

    let expected = L10n.localSpeechPreparationFailure(.integrity)
    XCTAssertEqual(
      harness.model.voice.localSpeechPreparationError,
      expected.string(for: harness.model.settings.language)
    )
    let event = try XCTUnwrap(
      harness.model.history.eventFeed.last {
        $0.english == expected.english
          && $0.simplifiedChinese == expected.simplifiedChinese
      }
    )
    XCTAssertEqual(event.english, expected.english)
    XCTAssertEqual(event.simplifiedChinese, expected.simplifiedChinese)
  }

  func testWorkflowConflictsTrackSharedEnabledTrigger() async {
    let hotkeyA = WorkflowDefinition(
      id: UUID(),
      name: "Hotkey A",
      trigger: .hotkey,
      plan: makeTestAudioPlan(recognizerID: "ui.test.recognizer", actions: [OutputActionReference(id: "system-clipboard.copy")]),
      ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "red")
    )
    let hotkeyB = WorkflowDefinition(
      id: UUID(),
      name: "Hotkey B",
      trigger: .hotkey,
      plan: makeTestAudioPlan(recognizerID: "ui.test.recognizer", actions: [OutputActionReference(id: "system-clipboard.copy")]),
      ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "orange")
    )
    let harness = makeHarness(workflows: [hotkeyA, hotkeyB])

    XCTAssertEqual(harness.model.workflowLibrary.workflowTriggerConflicts.count, 1)
    XCTAssertEqual(
      Set(harness.model.conflictingWorkflows(for: hotkeyA).map(\.id)),
      Set([hotkeyB.id])
    )

    harness.model.setWorkflowEnabled(false, for: hotkeyB.id)
    await harness.model.flushPendingPersistenceWrites()

    XCTAssertTrue(harness.model.workflowLibrary.workflowTriggerConflicts.isEmpty)
    XCTAssertTrue(harness.model.conflictingWorkflows(for: hotkeyA).isEmpty)
  }

  func testMenuBarWorkflowsDoNotConflict() async {
    let menuBarA = WorkflowDefinition(
      id: UUID(),
      name: "Menu A",
      trigger: .menuBar,
      plan: makeTestAudioPlan(recognizerID: "ui.test.recognizer", actions: [OutputActionReference(id: "system-clipboard.copy")]),
      ui: WorkflowUIConfig(symbolName: "menubar.rectangle", accentColorName: "red")
    )
    let menuBarB = WorkflowDefinition(
      id: UUID(),
      name: "Menu B",
      trigger: .menuBar,
      plan: makeTestAudioPlan(recognizerID: "ui.test.recognizer", actions: [OutputActionReference(id: "system-clipboard.copy")]),
      ui: WorkflowUIConfig(symbolName: "menubar.rectangle", accentColorName: "orange")
    )
    let harness = makeHarness(workflows: [menuBarA, menuBarB])

    XCTAssertTrue(harness.model.workflowLibrary.workflowTriggerConflicts.isEmpty)
    XCTAssertTrue(harness.model.conflictingWorkflows(for: menuBarA).isEmpty)
  }

  func testWakeWordWorkflowRespectsDefaultDisabledMetadata() {
    let assistant = WorkflowDefinition(
      name: "Voice Assistant",
      trigger: .wakeWord,
      plan: WorkflowPlan(
        setup: WorkflowSetupPhase(
          speechRoute: WorkflowSpeechRoute(
            recognizerID: "ui.test.recognizer"
          ),
          wakeWord: WakeWordConfiguration(phrases: ["Hey Rill"])
        ),
        process: WorkflowProcessPhase(steps: [
          WorkflowProcessStep(kind: .recognizeSpeech)
        ]),
        output: WorkflowOutputPhase(
          actions: [OutputActionReference(id: "system-clipboard.copy")]
        )
      ),
      ui: WorkflowUIConfig(symbolName: "sparkles", accentColorName: "purple"),
      properties: .init(defaultEnabled: false))

    let harness = makeHarness(workflows: [assistant])

    XCTAssertFalse(harness.model.isWorkflowEnabled(assistant))
  }

  func testSavingWorkflowCanDisableCaptureExclusionAndUseMenuBarTrigger() async throws {
    let settingsStore = UITestSettingsStore()
    let harness = makeHarness(settingsStore: settingsStore)
    await harness.model.waitForInitialVoiceConfiguration()

    await harness.model.saveWorkflowDraft(
      WorkflowEditorDraft(
        name: "Chainable Menu Workflow",
        eventType: .menuBar,
        recognizer: .localSpeech,
        postProcessSteps: [.init(kind: .normalizeWhitespace)],
        destination: .copyToClipboard,
        excludeFromWorkflowCapture: false
      )
    )
    await harness.model.flushPendingPersistenceWrites()

    let savedWorkflow = try XCTUnwrap(harness.model.workflowLibrary.customWorkflows.first)
    XCTAssertEqual(savedWorkflow.trigger, .menuBar)
    XCTAssertFalse(savedWorkflow.excludesOutputFromRecordCapture)
  }

  func testEnablingWorkflowRejectsTriggerConflict() async {
    let hotkeyA = WorkflowDefinition(
      id: UUID(),
      name: "Hotkey A",
      trigger: .hotkey,
      plan: makeTestAudioPlan(recognizerID: "ui.test.recognizer", actions: [OutputActionReference(id: "system-clipboard.copy")]),
      ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "red")
    )
    var hotkeyB = WorkflowDefinition(
      id: UUID(),
      name: "Hotkey B",
      trigger: .hotkey,
      plan: makeTestAudioPlan(recognizerID: "ui.test.recognizer", actions: [OutputActionReference(id: "system-clipboard.copy")]),
      ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "orange")
    )
    hotkeyB.properties.defaultEnabled = false
    let settingsStore = UITestSettingsStore()
    let harness = makeHarness(
      workflows: [hotkeyA, hotkeyB],
      settingsStore: settingsStore
    )
    await harness.model.waitForInitialVoiceConfiguration()

    harness.model.setWorkflowEnabled(true, for: hotkeyB.id)

    XCTAssertFalse(harness.model.isWorkflowEnabled(hotkeyB))
    XCTAssertNotNil(harness.model.workflowLibrary.workflowLibraryError)
    XCTAssertTrue(harness.model.workflowLibrary.workflowLibraryError?.contains("Hotkey A") == true)
    XCTAssertTrue(harness.model.workflowLibrary.workflowTriggerConflicts.isEmpty)
  }

  func testLegacyClipboardWorkflowCannotBeEnabledEvenWhenPersistedStateIsTrue() async {
    let dictation = makeBuiltinPushToTalkWorkflow()
    var polish = makeBuiltinPushToTalkPolishWorkflow()
    polish.properties.automation = .init(rule: .init(eventKind: .recordCreated), actionKind: .editRecord)
    let enabledPayload = try? String(
      data: JSONEncoder().encode([polish.id.uuidString: true]),
      encoding: .utf8
    )
    let settingsStore = UITestSettingsStore(
      storage: [.workflowEnabledStates: enabledPayload ?? ""]
    )
    let harness = makeHarness(
      workflows: [dictation, polish],
      settingsStore: settingsStore
    )
    await harness.model.waitForInitialVoiceConfiguration()
    harness.model.applyLanguage(.english)

    harness.model.setWorkflowEnabled(true, for: polish.id)

    XCTAssertTrue(harness.model.isWorkflowEnabled(dictation))
    XCTAssertFalse(harness.model.isWorkflowEnabled(polish))
    XCTAssertEqual(
      harness.model.workflowLibrary.workflowLibraryError,
      "Legacy collection-event workflows remain disabled; use record routes for production delivery."
    )
  }

  func testInvalidWakeDeclarationCannotBeEnabled() async {
    let workflow = WorkflowDefinition(
      name: "Unknown Event Workflow",
      trigger: .wakeWord,
      plan: makeTestAudioPlan(recognizerID: "ui.test.recognizer", actions: [OutputActionReference(id: "system-clipboard.copy")]),
      ui: WorkflowUIConfig(symbolName: "bolt", accentColorName: "orange"),
      properties: .init())
    let harness = makeHarness(workflows: [workflow])
    await harness.model.waitForInitialVoiceConfiguration()
    harness.model.applyLanguage(.english)

    harness.model.setWorkflowEnabled(true, for: workflow.id)

    XCTAssertFalse(harness.model.isWorkflowEnabled(workflow))
    XCTAssertEqual(
      harness.model.workflowLibrary.workflowLibraryError,
      "This workflow declaration is invalid and remains disabled."
    )
  }

  func testDisabledManualWorkflowCannotRun() async {
    let harness = makeHarness()
    harness.model.applyLanguage(.simplifiedChinese)

    harness.model.setWorkflowEnabled(false, for: harness.workflow.id)
    await harness.model.flushPendingPersistenceWrites()
    harness.model.runWorkflow(harness.workflow)

    XCTAssertFalse(harness.model.voice.isRunning)
    XCTAssertFalse(harness.model.canTriggerWorkflow(harness.workflow))
    XCTAssertEqual(harness.model.lastFailure, "请先启用这个工作流再运行。")
  }

  func testUnavailableExplicitLocalSpeechWorkflowFailsBeforeRecording() async {
    let workflow = WorkflowDefinition(
      name: "Unavailable Local Speech",
      trigger: .manual,
      plan: makeTestAudioPlan(recognizerID: "sherpa-onnx.local", actions: [OutputActionReference(id: "system-clipboard.copy")]),
      ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "teal")
    )
    let harness = makeHarness(
      workflow: workflow,
      localSpeechTrustMaterialAvailable: false
    )
    await harness.model.waitForInitialVoiceConfiguration()
    harness.model.applyLanguage(.english)

    XCTAssertFalse(harness.model.canTriggerWorkflow(workflow))
    harness.model.runWorkflow(workflow)

    XCTAssertFalse(harness.model.voice.isRunning)
    XCTAssertEqual(harness.model.voice.workflowAudioRunState, .idle)
    XCTAssertEqual(
      harness.model.lastFailure,
      "This workflow cannot run because this build has no reviewed local speech model. Choose Cloud speech and retry."
    )
  }

  func testIncompatibleRuntimeExplicitLocalSpeechWorkflowReportsRuntimeReasonBeforeRecording() async {
    let workflow = WorkflowDefinition(
      name: "Architecture Unsupported Local Speech",
      trigger: .manual,
      plan: makeTestAudioPlan(recognizerID: "sherpa-onnx.local", actions: [OutputActionReference(id: "system-clipboard.copy")]),
      ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "teal")
    )
    let harness = makeHarness(
      workflow: workflow,
      localSpeechAvailability: .architectureUnsupported
    )
    await harness.model.waitForInitialVoiceConfiguration()
    harness.model.applyLanguage(.english)

    XCTAssertFalse(harness.model.canTriggerWorkflow(workflow))
    harness.model.runWorkflow(workflow)

    XCTAssertFalse(harness.model.voice.isRunning)
    XCTAssertEqual(harness.model.voice.workflowAudioRunState, .idle)
    XCTAssertEqual(
      harness.model.lastFailure,
      "This workflow cannot run because the compatible local speech worker is unavailable. Enable a supported local model and retry."
    )
    XCTAssertFalse(harness.model.lastFailure?.contains("reviewed local speech model") == true)
  }

  func testSavingLocalWorkflowUsesGlobalASR() async {
    let harness = makeHarness()
    await harness.model.saveWorkflowDraft(
      WorkflowEditorDraft(
        name: "Local Override",
        recognizer: .localSpeech,
        postProcessSteps: [.init(kind: .normalizeWhitespace)],
        destination: .pasteIntoApp
      )
    )

    guard let savedWorkflow = harness.model.workflowLibrary.customWorkflows.first else {
      XCTFail("Expected saved workflow")
      return
    }

    XCTAssertEqual(savedWorkflow.plan.setup.speechRoute?.selection, .automatic)

  }

  func testSavingWakeWordWorkflowRequiresExactModelVocabularyValidation() async {
    let unavailableHarness = makeHarness()
    let draft = WorkflowEditorDraft(
      name: "Wake Assistant",
      eventType: .wakeWord,
      wakePhrasesText: "Hey Rill",
      destination: .copyToClipboard
    )

    await unavailableHarness.model.saveWorkflowDraft(draft)

    XCTAssertTrue(unavailableHarness.model.workflowLibrary.customWorkflows.isEmpty)
    XCTAssertNotNil(unavailableHarness.model.workflowLibrary.workflowEditorError)

    let readyHarness = makeHarness(
      voiceResourceServices: makeVoiceResourceServicesForTesting(validateWakeWordConfiguration: { configuration in
        guard configuration.phrases == ["Hey Rill"] else {
          throw WakeWordSaveValidationError.unexpectedConfiguration
        }
      }))

    await readyHarness.model.saveWorkflowDraft(draft)

    XCTAssertEqual(readyHarness.model.workflowLibrary.customWorkflows.count, 1)
    XCTAssertEqual(
      readyHarness.model.workflowLibrary.customWorkflows.first?.plan.setup.wakeWord?.phrases,
      ["Hey Rill"]
    )
  }

  func testUnsupportedModelSelectionCannotStartPreparation() async {
    let probe = SpeechPreparationProbe()
    let harness = makeHarness(prepareLocalSpeechAction: { settings, _ in
      await probe.recordPreparation(settings: settings)
      return settings.model
    })
    await harness.model.waitForInitialVoiceConfiguration()
    harness.model.selectTrustedLocalSpeechModel("untrusted-custom-model")
    await harness.model.voice.waitForLocalSpeechPreparation()
    let snapshot = await probe.snapshot()
    XCTAssertEqual(snapshot.prepareCount, 0)
    XCTAssertEqual(harness.model.settings.localSpeechModel, appModelTestTrustedLocalSpeechModels()[0].id)
  }

  func testRecordPanelRequestedOpensRecordPanel() async {
    let probe = RecordPanelProbe()
    let harness = makeHarness(showRecordPanelAction: {
      await probe.recordShow()
    })
    await waitForListenerSetup(harness)

    await harness.eventBus.publish(.recordPanelRequested)
    await waitForEventProcessing(harness)

    let showCount = await probe.snapshot()
    XCTAssertEqual(showCount, 1)
  }

  func testUpdatingRecordPanelHotkeyPersistsSetting() async throws {
    let settingsStore = UITestSettingsStore()
    let harness = makeHarness(settingsStore: settingsStore)
    let shortcut = KeyboardShortcut(keyCode: 9, modifiers: [.command, .option])

    await harness.model.waitForInitialVoiceConfiguration()
    harness.model.setRecordPanelHotkeyShortcut(shortcut)
    await harness.model.flushPendingPersistenceWrites()

    let storedValue = try await settingsStore.string(forKey: .recordPanelHotkey)
    XCTAssertEqual(storedValue, shortcut.storageString)
  }

  func testUpdatingRecordPanelHotkeyRejectsUnsafeShortcutBeforePersistence() async throws {
    let settingsStore = UITestSettingsStore()
    let harness = makeHarness(settingsStore: settingsStore)
    let commandQ = KeyboardShortcut(keyCode: 12, modifiers: [.command])

    await harness.model.waitForInitialVoiceConfiguration()
    harness.model.setRecordPanelHotkeyShortcut(commandQ)
    await harness.model.flushPendingPersistenceWrites()

    XCTAssertEqual(harness.model.settings.recordPanelHotkeyBinding, .doubleCommand)
    let storedValue = try await settingsStore.string(forKey: .recordPanelHotkey)
    XCTAssertNil(storedValue)
  }

  func testShowRunHistorySelectsStreamSection() {
    let harness = makeHarness()

    XCTAssertEqual(harness.model.selectedSidebarSection, .records)

    harness.model.showRunHistory()

    XCTAssertEqual(harness.model.selectedSidebarSection, .stream)
    XCTAssertEqual(harness.model.history.runHistoryScope, .recentRuns)
  }

  func testShowRecordCollectionSelectsRecordsSidebarAndCollection() {
    let harness = makeHarness()
    let collectionID = RecordCollectionID()

    harness.model.showRecordCollection(collectionID)

    XCTAssertEqual(harness.model.selectedSidebarSection, .records)
    XCTAssertEqual(harness.model.recordWorkspace.selectedCollectionID, collectionID)

    harness.model.selectSidebarSection(.records)

    XCTAssertEqual(harness.model.selectedSidebarSection, .records)
    XCTAssertEqual(
      harness.model.recordWorkspace.selectedCollectionID,
      nil
    )

    harness.model.showRecordCollection(collectionID)
    harness.model.presentSettings()

    XCTAssertTrue(harness.model.isShowingSettings)
    XCTAssertEqual(harness.model.selectedSidebarSection, .records)
    XCTAssertEqual(harness.model.recordWorkspace.selectedCollectionID, collectionID)
    harness.model.dismissSettings()
    XCTAssertFalse(harness.model.isShowingSettings)
    XCTAssertEqual(harness.model.selectedSidebarSection, .records)
    XCTAssertEqual(harness.model.recordWorkspace.selectedCollectionID, collectionID)
  }

  func testDismissSettingsRestoresSidebarFocusButContentNavigationDoesNot() {
    let harness = makeHarness()
    harness.model.presentSettings()
    XCTAssertEqual(harness.model.settingsSidebarFocusRestoreGeneration, 0)
    harness.model.dismissSettings()
    XCTAssertEqual(harness.model.settingsSidebarFocusRestoreGeneration, 1)
    harness.model.presentSettings()
    harness.model.selectSidebarSection(.stream)
    XCTAssertFalse(harness.model.isShowingSettings)
    XCTAssertEqual(harness.model.settingsSidebarFocusRestoreGeneration, 1)
  }

  func testShowWorkflowSelectsWorkflowSidebarDestination() throws {
    let harness = makeHarness()
    let workflow = try XCTUnwrap(harness.model.workflowLibrary.workflows.first)

    harness.model.showWorkflow(workflow.id)

    XCTAssertEqual(harness.model.selectedSidebarSection, .workflows)
    XCTAssertEqual(harness.model.workflowEditorNavigationRequest?.workflowID, workflow.id)
  }
}

private enum WakeWordSaveValidationError: Error {
  case unexpectedConfiguration
}
