import XCTest
@testable import RillCore
@testable import RillRuntime
@testable import RillUI

@MainActor
extension AppModelTests {
    func testVoiceRunCompletionUpdatesLatestResultHistoryAndPersistence() async throws {
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
            .recognitionCompleted(RecognitionResult(rawText: "draft voice", bestText: "draft voice"))
        )
        await waitForEventProcessing(harness)

        XCTAssertEqual(harness.model.lastCompletedText, "draft voice")

        let correctionSource = RecognitionCorrectionSource(
            preMappingText: "draft voice",
            context: VocabularyRuleContext(
                bundleIdentifier: "com.example.editor",
                locale: "en-US"
            )
        )

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
        XCTAssertEqual(harness.model.lastCompletedText, "final voice")
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
        XCTAssertFalse(harness.model.historyRecords.contains { $0.runID == runID })
        XCTAssertFalse(harness.model.recentVoiceResultRecords.contains { $0.runID == runID })
        XCTAssertNil(harness.model.lastCompletedText)
        XCTAssertFalse(harness.model.eventFeed.contains { entry in
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
        XCTAssertTrue(harness.model.isRunning)
        XCTAssertNotNil(harness.model.pendingRuns[runID])
        XCTAssertEqual(harness.model.pendingResolution?.runID, runID)

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
        XCTAssertFalse(harness.model.isRunning)
        XCTAssertNil(harness.model.activeRunID)
        XCTAssertNil(harness.model.pendingRuns[runID])
        XCTAssertNil(harness.model.pendingResolution)
        XCTAssertEqual(harness.model.workflowAudioRunState, .idle)
        XCTAssertNil(harness.model.lastFailure)
        XCTAssertTrue(storedRecords.isEmpty)
        XCTAssertFalse(harness.model.historyRecords.contains { $0.runID == runID })
        XCTAssertTrue(harness.model.eventFeed.contains { $0.english == "Run cancelled." })
    }

    func testVoiceGroupTargetRunIsShownInRecentVoiceResults() async {
        let workflow = WorkflowDefinition(
            name: "Save to Voice Group",
            pipeline: PipelineDeclaration(
                recognizerID: "ui.test.recognizer",
                outputActions: [OutputActionReference(id: "record.store")],
                deliveryPolicy: DeliveryPolicy(strategy: .collectionFirst)
            ),
            ui: WorkflowUIConfig(symbolName: "tray.and.arrow.down", accentColorName: "purple"),
            metadata: [WorkflowMetadataKey.legacyTargetRecordCollectionID: RecordCollection.voiceInputID.rawValue.uuidString]
        )
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
        let workflow = makeBuiltinPushToTalkWorkflow()
        let harness = makeHarness(
            workflows: [workflow],
            startWorkflowAudioRunAction: { workflow, binding in
                await probe.record(workflow: workflow, binding: binding)
            }
        )
        harness.model.builtinPushToTalkOutputMode = .saveToVoiceGroup

        harness.model.runWorkflow(workflow, initiatedBy: .hotkey)
        await waitForEventProcessing(harness)

        let calls = await probe.snapshot()
        let captured = try XCTUnwrap(calls.first)
        XCTAssertEqual(captured.binding, .hotkey)
        XCTAssertEqual(captured.workflow.pipeline.recognizerID, AppModel.localSpeechRecognizerID)
        XCTAssertEqual(captured.workflow.pipeline.outputActions.first?.id, "record.store")
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
            pipeline: PipelineDeclaration(
                recognizerID: AppModel.localSpeechRecognizerID,
                outputActions: [OutputActionReference(id: "record.store")],
                deliveryPolicy: .init(strategy: .collectionFirst)
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue"),
            metadata: [
                WorkflowMetadataKey.recognizerSelectionMode: "auto",
                WorkflowMetadataKey.languageOverride: "zh-CN",
            ]
        )
        let harness = makeHarness(
            workflows: [workflow],
            startWorkflowAudioRunAction: { workflow, binding in
                await probe.record(workflow: workflow, binding: binding)
            }
        )
        harness.model.runWorkflow(workflow)
        await waitForEventProcessing(harness)

        let calls = await probe.snapshot()
        let captured = try XCTUnwrap(calls.first)
        XCTAssertEqual(captured.workflow.pipeline.recognizerID, AppModel.localSpeechRecognizerID)
        XCTAssertEqual(captured.workflow.metadata[WorkflowMetadataKey.languageOverride], "zh-CN")
    }

    func testSavingAndDeletingCustomWorkflowPersistsLibrary() async throws {
        let settingsStore = UITestSettingsStore()
        let harness = makeHarness(settingsStore: settingsStore)
        await harness.model.waitForInitialVoiceConfiguration()

        await harness.model.saveWorkflowDraft(
            WorkflowEditorDraft(
                name: "Follow-up Draft",
                recognizer: .localSpeech,
                postProcessSteps: [.init(kind: .normalizeWhitespace)],
                destination: .copyToClipboard
            )
        )
        await harness.model.flushPendingPersistenceWrites()

        XCTAssertEqual(harness.model.customWorkflows.count, 1)
        XCTAssertEqual(harness.model.customWorkflows.first?.name, "Follow-up Draft")
        XCTAssertTrue(harness.model.customWorkflows.first?.excludesOutputFromRecordCapture ?? false)

        let storedValue = try await settingsStore.string(forKey: .workflowLibrary)
        let storedData = try XCTUnwrap(storedValue?.data(using: .utf8))
        let storedLibrary = try JSONDecoder().decode(
            WorkflowLibraryDocument.self,
            from: storedData
        )
        XCTAssertEqual(storedLibrary.customWorkflows.count, 1)
        XCTAssertEqual(storedLibrary.customWorkflows.first?.name, "Follow-up Draft")
        XCTAssertTrue(
            storedLibrary.customWorkflows.first?.excludesOutputFromRecordCapture ?? false
        )

        let savedWorkflow = try XCTUnwrap(harness.model.customWorkflows.first)
        await harness.model.deleteCustomWorkflow(savedWorkflow)
        await harness.model.flushPendingPersistenceWrites()

        XCTAssertTrue(harness.model.customWorkflows.isEmpty)
        let removedValue = try await settingsStore.string(forKey: .workflowLibrary)
        let removedData = try XCTUnwrap(removedValue?.data(using: .utf8))
        let removedLibrary = try JSONDecoder().decode(
            WorkflowLibraryDocument.self,
            from: removedData
        )
        XCTAssertTrue(removedLibrary.customWorkflows.isEmpty)
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

        XCTAssertNil(harness.model.workflowEditorError)
        XCTAssertEqual(harness.model.customWorkflows.map(\.name), ["Speech Recognition"])

        await harness.model.saveWorkflowDraft(
            WorkflowEditorDraft(
                name: "Speech Recognition",
                recognizer: .localSpeech,
                postProcessSteps: [.init(kind: .normalizeWhitespace)],
                destination: .copyToClipboard
            )
        )

        XCTAssertNil(harness.model.workflowEditorError)
        XCTAssertEqual(
            harness.model.customWorkflows.map(\.name),
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
            harness.model.workflowEditorError,
            L10n.workflowText(.workflowNameTakenError, language: harness.model.language)
        )
        XCTAssertTrue(harness.model.customWorkflows.isEmpty)
        XCTAssertEqual(harness.model.workflows.map(\.name), ["Alpha", "Beta"])
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

        XCTAssertNil(harness.model.workflowEditorError)
        XCTAssertEqual(harness.model.customWorkflows.map(\.name), ["Speech Recognition"])
    }

    private func makeNamedWorkflow(_ name: String) -> WorkflowDefinition {
        WorkflowDefinition(
            name: name,
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: AppModel.localSpeechRecognizerID,
                postProcessSteps: [PostProcessStep(kind: .normalizeWhitespace)],
                outputActions: [OutputActionReference(id: "system-clipboard.copy")]
            ),
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
        XCTAssertEqual(harness.model.customWorkflows.map(\.id), [savedRecord.workflow.id])

        let storedValue = try await settingsStore.string(forKey: .workflowLibrary)
        let storedData = try XCTUnwrap(storedValue?.data(using: .utf8))
        let storedLibrary = try JSONDecoder().decode(
            WorkflowLibraryDocument.self,
            from: storedData
        )
        XCTAssertTrue(storedLibrary.customWorkflows.isEmpty)

        await harness.model.deleteCustomWorkflow(savedRecord.workflow)
        let remainingRecords = await workflowFileStore.records()
        XCTAssertTrue(remainingRecords.isEmpty)
        XCTAssertTrue(harness.model.customWorkflows.isEmpty)
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
        XCTAssertEqual(savedRecord.workflow.plan.setup.speechRoute?.selection, .fixed)
        XCTAssertFalse(savedRecord.workflow.prefersAutomaticRecognizerSelection)
        XCTAssertEqual(harness.model.customWorkflows.map(\.id), [builtInWorkflow.id])
        XCTAssertTrue(harness.model.userCreatedWorkflows.isEmpty)
        XCTAssertEqual(harness.model.editableBuiltInWorkflows.map(\.name), ["Focused Dictation"])
        XCTAssertEqual(harness.model.workflows.map(\.id), [builtInWorkflow.id])
        XCTAssertTrue(harness.model.canRestoreBuiltInWorkflow(savedRecord.workflow))

        await harness.model.restoreBuiltInWorkflowToDefault(savedRecord.workflow)

        let restoredRecords = await workflowFileStore.records()
        XCTAssertTrue(restoredRecords.isEmpty)
        XCTAssertTrue(harness.model.customWorkflows.isEmpty)
        XCTAssertTrue(harness.model.userCreatedWorkflows.isEmpty)
        XCTAssertEqual(harness.model.editableBuiltInWorkflows.map(\.name), [builtInWorkflow.name])
        XCTAssertEqual(harness.model.workflows.map(\.id), [builtInWorkflow.id])
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
        XCTAssertEqual(harness.model.workflows.map(\.id), [builtInWorkflow.id])

        var draft = harness.model.defaultWorkflowDraft()
        draft.name = "Accurate Transcription"  // English display name of the built-in
        await harness.model.saveWorkflowDraft(draft)

        let custom = try XCTUnwrap(harness.model.customWorkflows.first)
        XCTAssertNotEqual(custom.id, builtInWorkflow.id)
        // The built-in is shadowed everywhere instead of listed twice.
        XCTAssertEqual(harness.model.workflows.map(\.id), [custom.id])
        XCTAssertTrue(harness.model.editableBuiltInWorkflows.isEmpty)
        XCTAssertFalse(harness.model.isBuiltInWorkflow(custom))

        await harness.model.deleteCustomWorkflow(custom)

        XCTAssertEqual(harness.model.workflows.map(\.id), [builtInWorkflow.id])
        XCTAssertEqual(harness.model.editableBuiltInWorkflows.map(\.id), [builtInWorkflow.id])
    }

    func testCustomWorkflowMatchingBuiltInChineseDisplayNameShadowsIt() async throws {
        let builtInWorkflow = makeBuiltinPushToTalkWorkflow()
        let harness = makeHarness(workflows: [builtInWorkflow])
        await harness.model.waitForInitialVoiceConfiguration()

        var draft = harness.model.defaultWorkflowDraft()
        draft.name = "精准转写"  // Simplified Chinese display name of the built-in
        await harness.model.saveWorkflowDraft(draft)

        XCTAssertEqual(harness.model.customWorkflows.count, 1)
        XCTAssertEqual(harness.model.workflows.map(\.name), ["精准转写"])
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
            harness.model.customWorkflows.map(\.name).sorted(),
            ["Accurate Transcription", "Accurate Transcription 2"]
        )
        // The built-in stays shadowed by the first custom.
        XCTAssertEqual(harness.model.workflows.count, 2)
        XCTAssertFalse(harness.model.workflows.contains { $0.id == builtInWorkflow.id })
    }

    func testEmptyTOMLDirectoryMigratesAndVerifiesLegacyWorkflowLibrary() async throws {
        let legacyWorkflow = WorkflowEditorDraft(
            name: "Legacy Workflow",
            recognizer: .localSpeech,
            postProcessSteps: [.init(kind: .normalizeWhitespace)],
            destination: .copyToClipboard
        ).makeWorkflow(
            id: UUID(uuidString: "BBBBBBBB-2222-3333-4444-555555555555")!,
            hotkeyGesture: AppModel.defaultHotkeyGesture
        )
        let legacyDocument = WorkflowLibraryDocument(customWorkflows: [legacyWorkflow])
        let settingsStore = UITestSettingsStore(storage: [
            .workflowLibrary: String(
                decoding: try JSONEncoder().encode(legacyDocument),
                as: UTF8.self
            )
        ])
        let workflowFileStore = UITestWorkflowFileStore()
        let harness = makeHarness(
            settingsStore: settingsStore,
            workflowFileStore: workflowFileStore
        )
        await harness.model.waitForInitialVoiceConfiguration()

        let migratedRecords = await workflowFileStore.records()
        let migrated = try XCTUnwrap(migratedRecords.first)
        XCTAssertEqual(migrated.workflow.id, legacyWorkflow.id)
        XCTAssertEqual(harness.model.customWorkflows.map(\.id), [legacyWorkflow.id])

        let retiredValue = try await settingsStore.string(forKey: .workflowLibrary)
        let retiredData = try XCTUnwrap(retiredValue?.data(using: .utf8))
        let retiredLibrary = try JSONDecoder().decode(
            WorkflowLibraryDocument.self,
            from: retiredData
        )
        XCTAssertTrue(retiredLibrary.customWorkflows.isEmpty)
    }

    func testReloadKeepsLegacyWorkflowsAfterTOMLMigrationFailure() async throws {
        let legacyWorkflow = WorkflowEditorDraft(
            name: "Legacy Recovery Workflow",
            recognizer: .localSpeech,
            postProcessSteps: [],
            destination: .copyToClipboard
        ).makeWorkflow(
            id: UUID(uuidString: "CCCCCCCC-2222-3333-4444-555555555555")!,
            hotkeyGesture: AppModel.defaultHotkeyGesture
        )
        let legacyDocument = WorkflowLibraryDocument(customWorkflows: [legacyWorkflow])
        let settingsStore = UITestSettingsStore(storage: [
            .workflowLibrary: String(
                decoding: try JSONEncoder().encode(legacyDocument),
                as: UTF8.self
            )
        ])
        let workflowFileStore = UITestWorkflowFileStore(rejectsSaves: true)
        let harness = makeHarness(
            settingsStore: settingsStore,
            workflowFileStore: workflowFileStore
        )
        await harness.model.waitForInitialVoiceConfiguration()

        XCTAssertEqual(harness.model.customWorkflows.map(\.id), [legacyWorkflow.id])
        await harness.model.reloadWorkflowFiles()
        XCTAssertEqual(harness.model.customWorkflows.map(\.id), [legacyWorkflow.id])
        let partialRecords = await workflowFileStore.records()
        XCTAssertEqual(partialRecords.count, 1)
    }






    func testSelectingWhisperKitModelAutomaticallyPreparesIt() async {
        let probe = WhisperKitPrepareProbe()
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
        harness.model.localSpeechModelOption = .distilLargeV3Compact
        await harness.model.waitForLocalSpeechPreparation()

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.prepareCount, 1)
        XCTAssertEqual(snapshot.lastSettings?.model, "distil-whisper_distil-large-v3_594MB")
        XCTAssertEqual(snapshot.reportedProgress, [0.5])
        XCTAssertEqual(harness.model.localSpeechModelOption, .distilLargeV3Compact)
        XCTAssertEqual(harness.model.localSpeechPreparationState, .ready)
        XCTAssertEqual(harness.model.localSpeechPreparationProgress, 1)
        XCTAssertEqual(harness.model.localSpeechPreparedModelIdentifier, "distil-whisper_distil-large-v3_594MB")
        XCTAssertEqual(harness.model.downloadedLocalSpeechModels, ["distil-whisper_distil-large-v3_594MB"])
        XCTAssertNil(harness.model.localSpeechPreparationError)
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
        await harness.model.waitForLocalSpeechPreparation()

        let expected = L10n.localSpeechPreparationFailure(.generic)
        XCTAssertEqual(harness.model.localSpeechPreparationState, .idle)
        XCTAssertEqual(
            harness.model.localSpeechPreparationError,
            expected.string(for: harness.model.language)
        )
        let event = try XCTUnwrap(
            harness.model.eventFeed.last {
                $0.english == expected.english
                    && $0.simplifiedChinese == expected.simplifiedChinese
            }
        )
        XCTAssertEqual(event.english, expected.english)
        XCTAssertEqual(event.simplifiedChinese, expected.simplifiedChinese)
        let exposedText = ([harness.model.localSpeechPreparationError ?? ""]
            + harness.model.eventFeed.flatMap { [$0.english, $0.simplifiedChinese] })
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
        await harness.model.waitForLocalSpeechPreparation()

        let expected = L10n.localSpeechPreparationFailure(.integrity)
        XCTAssertEqual(
            harness.model.localSpeechPreparationError,
            expected.string(for: harness.model.language)
        )
        let event = try XCTUnwrap(
            harness.model.eventFeed.last {
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
            pipeline: PipelineDeclaration(
                recognizerID: "ui.test.recognizer",
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "red")
        )
        let hotkeyB = WorkflowDefinition(
            id: UUID(),
            name: "Hotkey B",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "ui.test.recognizer",
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "orange")
        )
        let harness = makeHarness(workflows: [hotkeyA, hotkeyB])

        XCTAssertEqual(harness.model.workflowTriggerConflicts.count, 1)
        XCTAssertEqual(
            Set(harness.model.conflictingWorkflows(for: hotkeyA).map(\.id)),
            Set([hotkeyB.id])
        )

        harness.model.setWorkflowEnabled(false, for: hotkeyB.id)

        XCTAssertTrue(harness.model.workflowTriggerConflicts.isEmpty)
        XCTAssertTrue(harness.model.conflictingWorkflows(for: hotkeyA).isEmpty)
    }

    func testMenuBarWorkflowsDoNotConflict() async {
        let menuBarA = WorkflowDefinition(
            id: UUID(),
            name: "Menu A",
            trigger: .menuBar,
            pipeline: PipelineDeclaration(
                recognizerID: "ui.test.recognizer",
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "menubar.rectangle", accentColorName: "red")
        )
        let menuBarB = WorkflowDefinition(
            id: UUID(),
            name: "Menu B",
            trigger: .menuBar,
            pipeline: PipelineDeclaration(
                recognizerID: "ui.test.recognizer",
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "menubar.rectangle", accentColorName: "orange")
        )
        let harness = makeHarness(workflows: [menuBarA, menuBarB])

        XCTAssertTrue(harness.model.workflowTriggerConflicts.isEmpty)
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
                    actions: [OutputActionReference(id: "ui.test.action")]
                )
            ),
            ui: WorkflowUIConfig(symbolName: "sparkles", accentColorName: "purple"),
            metadata: [WorkflowMetadataKey.defaultEnabled: "false"]
        )

        let harness = makeHarness(workflows: [assistant])

        XCTAssertFalse(harness.model.isWorkflowEnabled(assistant))
    }

    func testRetiredBuiltinPushToTalkSelectionMigratesToSpeechRecognition() async throws {
        let speechRecognitionID = try XCTUnwrap(
            UUID(uuidString: "B9E19A88-F9FB-4AB3-8444-CDBF7E215A88")
        )
        let retiredStreamingID = try XCTUnwrap(
            UUID(uuidString: "A8E19A88-F9FB-4AB3-8444-CDBF7E215A88")
        )
        let speechRecognition = WorkflowDefinition(
            id: speechRecognitionID,
            name: "Speech Recognition",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "ui.test.recognizer",
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "red"),
            metadata: [
                WorkflowMetadataKey.catalog: BuiltinWorkflowRoutingValue.catalog,
                WorkflowMetadataKey.builtinKind: AppModel.builtinPushToTalkKindValue,
                WorkflowMetadataKey.triggerGesture:
                    BuiltinWorkflowRoutingValue.pushToTalkGesture,
            ]
        )
        let payload = try XCTUnwrap(
            String(
                data: JSONEncoder().encode([
                    speechRecognitionID.uuidString: false,
                    retiredStreamingID.uuidString: true,
                ]),
                encoding: .utf8
            )
        )
        let harness = makeHarness(
            workflows: [speechRecognition],
            settingsStore: UITestSettingsStore(
                storage: [.workflowEnabledStates: payload]
            )
        )

        await harness.model.waitForInitialVoiceConfiguration()

        XCTAssertTrue(harness.model.isWorkflowEnabled(speechRecognition))
        XCTAssertNil(harness.model.workflowEnabledStates[retiredStreamingID])
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

        let savedWorkflow = try XCTUnwrap(harness.model.customWorkflows.first)
        XCTAssertEqual(savedWorkflow.trigger, .menuBar)
        XCTAssertFalse(savedWorkflow.excludesOutputFromRecordCapture)
    }

    func testEnablingWorkflowRejectsTriggerConflict() async {
        let hotkeyA = WorkflowDefinition(
            id: UUID(),
            name: "Hotkey A",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "ui.test.recognizer",
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "red")
        )
        let hotkeyB = WorkflowDefinition(
            id: UUID(),
            name: "Hotkey B",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "ui.test.recognizer",
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "orange")
        )
        let disabledPayload = try? String(
            data: JSONEncoder().encode([hotkeyB.id.uuidString: false]),
            encoding: .utf8
        )
        let settingsStore = UITestSettingsStore(
            storage: [.workflowEnabledStates: disabledPayload ?? ""]
        )
        let harness = makeHarness(
            workflows: [hotkeyA, hotkeyB],
            settingsStore: settingsStore
        )
        await harness.model.waitForInitialVoiceConfiguration()

        harness.model.setWorkflowEnabled(true, for: hotkeyB.id)

        XCTAssertFalse(harness.model.isWorkflowEnabled(hotkeyB))
        XCTAssertNotNil(harness.model.workflowLibraryError)
        XCTAssertTrue(harness.model.workflowLibraryError?.contains("Hotkey A") == true)
        XCTAssertTrue(harness.model.workflowTriggerConflicts.isEmpty)
    }

    func testLegacyClipboardWorkflowCannotBeEnabledEvenWhenPersistedStateIsTrue() async {
        let dictation = makeBuiltinPushToTalkWorkflow()
        let polish = makeBuiltinPushToTalkPolishWorkflow()
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
        harness.model.language = .english

        harness.model.setWorkflowEnabled(true, for: polish.id)

        XCTAssertTrue(harness.model.isWorkflowEnabled(dictation))
        XCTAssertFalse(harness.model.isWorkflowEnabled(polish))
        XCTAssertEqual(
            harness.model.workflowLibraryError,
            "Legacy collection-event workflows remain disabled; use record routes for production delivery."
        )
    }

    func testUnknownWorkflowEventTypeCannotBeEnabled() async {
        let workflow = WorkflowDefinition(
            name: "Unknown Event Workflow",
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: "ui.test.recognizer",
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "bolt", accentColorName: "orange"),
            metadata: [WorkflowMetadataKey.legacyEventType: "groupItemCopied"]
        )
        let harness = makeHarness(workflows: [workflow])
        await harness.model.waitForInitialVoiceConfiguration()
        harness.model.language = .english

        harness.model.setWorkflowEnabled(true, for: workflow.id)

        XCTAssertFalse(harness.model.isWorkflowEnabled(workflow))
        XCTAssertEqual(
            harness.model.workflowLibraryError,
            "This workflow declares an invalid event type and remains disabled."
        )
    }

    func testDisabledManualWorkflowCannotRun() async {
        let harness = makeHarness()
        harness.model.language = .simplifiedChinese

        harness.model.setWorkflowEnabled(false, for: harness.workflow.id)
        harness.model.runWorkflow(harness.workflow)

        XCTAssertFalse(harness.model.isRunning)
        XCTAssertFalse(harness.model.canTriggerWorkflow(harness.workflow))
        XCTAssertEqual(harness.model.lastFailure, "请先启用这个工作流再运行。")
    }

    func testUnavailableExplicitLocalSpeechWorkflowFailsBeforeRecording() async {
        let workflow = WorkflowDefinition(
            name: "Unavailable Local Speech",
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: "sherpa-onnx.local",
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "teal")
        )
        let harness = makeHarness(
            workflow: workflow,
            localSpeechTrustMaterialAvailable: false
        )
        await harness.model.waitForInitialVoiceConfiguration()
        harness.model.language = .english

        XCTAssertFalse(harness.model.canTriggerWorkflow(workflow))
        harness.model.runWorkflow(workflow)

        XCTAssertFalse(harness.model.isRunning)
        XCTAssertEqual(harness.model.workflowAudioRunState, .idle)
        XCTAssertEqual(
            harness.model.lastFailure,
            "This workflow cannot run because this build has no reviewed local speech model. Choose Cloud speech and retry."
        )
    }

    func testIncompatibleRuntimeExplicitLocalSpeechWorkflowReportsRuntimeReasonBeforeRecording() async {
        let workflow = WorkflowDefinition(
            name: "Architecture Unsupported Local Speech",
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: "sherpa-onnx.local",
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "teal")
        )
        let harness = makeHarness(
            workflow: workflow,
            localSpeechAvailability: .architectureUnsupported
        )
        await harness.model.waitForInitialVoiceConfiguration()
        harness.model.language = .english

        XCTAssertFalse(harness.model.canTriggerWorkflow(workflow))
        harness.model.runWorkflow(workflow)

        XCTAssertFalse(harness.model.isRunning)
        XCTAssertEqual(harness.model.workflowAudioRunState, .idle)
        XCTAssertEqual(
            harness.model.lastFailure,
            "This workflow cannot run because the compatible local speech worker is unavailable. Enable a supported local model and retry."
        )
        XCTAssertFalse(harness.model.lastFailure?.contains("reviewed local speech model") == true)
    }


    func testSavingLocalWorkflowPersistsSpecificModelOverride() async {
        let harness = makeHarness()
        await harness.model.saveWorkflowDraft(
            WorkflowEditorDraft(
                name: "Local Override",
                recognizer: .localSpeech,
                localSpeechModelOverride: "qwen3-asr-0.6b-mlx-8bit",
                postProcessSteps: [.init(kind: .normalizeWhitespace)],
                destination: .pasteIntoApp
            )
        )

        guard let savedWorkflow = harness.model.customWorkflows.first else {
            XCTFail("Expected saved workflow")
            return
        }
        XCTAssertEqual(
            savedWorkflow.metadata[WorkflowMetadataKey.localSpeechModelOverride],
            "qwen3-asr-0.6b-mlx-8bit"
        )
        XCTAssertEqual(savedWorkflow.metadata["provider"], "local-speech")
        XCTAssertNil(savedWorkflow.metadata[WorkflowMetadataKey.legacyWhisperKitModelOverride])
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

        XCTAssertTrue(unavailableHarness.model.customWorkflows.isEmpty)
        XCTAssertNotNil(unavailableHarness.model.workflowEditorError)

        let readyHarness = makeHarness()
        readyHarness.model.installWakeWordConfigurationValidationAction { configuration in
            guard configuration.phrases == ["Hey Rill"] else {
                throw WakeWordSaveValidationError.unexpectedConfiguration
            }
        }

        await readyHarness.model.saveWorkflowDraft(draft)

        XCTAssertEqual(readyHarness.model.customWorkflows.count, 1)
        XCTAssertEqual(
            readyHarness.model.customWorkflows.first?.plan.setup.wakeWord?.phrases,
            ["Hey Rill"]
        )
    }

    func testLoadingLegacyLocalWorkflowsMigratesRecognizerAndModelOverride() throws {
        let legacyOnlyID = UUID()
        let bothKeysID = UUID()
        let workflows = [
            WorkflowDefinition(
                id: legacyOnlyID,
                name: "Legacy Local",
                trigger: .manual,
                pipeline: PipelineDeclaration(
                    recognizerID: "whisperkit.local",
                    outputActions: []
                ),
                ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue"),
                metadata: [
                    WorkflowMetadataKey.legacyWhisperKitModelOverride: "sense-voice-small-int8"
                ]
            ),
            WorkflowDefinition(
                id: bothKeysID,
                name: "Already Migrated Override",
                trigger: .manual,
                pipeline: PipelineDeclaration(
                    recognizerID: "whisperkit.local",
                    outputActions: []
                ),
                ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue"),
                metadata: [
                    WorkflowMetadataKey.localSpeechModelOverride: "qwen3-asr-0.6b-int8",
                    WorkflowMetadataKey.legacyWhisperKitModelOverride: "sense-voice-small-int8",
                ]
            ),
        ]
        let data = try JSONEncoder().encode(workflows)

        let loaded = try AppModel.loadCustomWorkflows(from: String(decoding: data, as: UTF8.self))

        let legacyOnly = try XCTUnwrap(loaded.first(where: { $0.id == legacyOnlyID }))
        XCTAssertEqual(legacyOnly.pipeline.recognizerID, "local-speech")
        XCTAssertEqual(
            legacyOnly.metadata[WorkflowMetadataKey.localSpeechModelOverride],
            "sense-voice-small-int8"
        )
        XCTAssertNil(legacyOnly.metadata[WorkflowMetadataKey.legacyWhisperKitModelOverride])

        let bothKeys = try XCTUnwrap(loaded.first(where: { $0.id == bothKeysID }))
        XCTAssertEqual(bothKeys.pipeline.recognizerID, "local-speech")
        XCTAssertEqual(
            bothKeys.metadata[WorkflowMetadataKey.localSpeechModelOverride],
            "qwen3-asr-0.6b-int8"
        )
        XCTAssertNil(bothKeys.metadata[WorkflowMetadataKey.legacyWhisperKitModelOverride])
    }

    func testPreparingCustomWhisperKitModelUsesTypedIdentifier() async {
        let probe = WhisperKitPrepareProbe()
        let harness = makeHarness(
            prepareLocalSpeechAction: { settings, progressCallback in
                await probe.recordPreparation(settings: settings)
                let progress = Progress(totalUnitCount: 5)
                progress.completedUnitCount = 3
                progressCallback(progress)
                await probe.recordProgress(progress)
                return settings.model
            }
        )

        await harness.model.waitForInitialVoiceConfiguration()
        harness.model.localSpeechModelOption = .custom
        harness.model.legacyWhisperKitCustomModel = "openai_whisper-large-v3-v20240930_turbo"
        harness.model.prepareLocalSpeechModel()
        await harness.model.waitForLocalSpeechPreparation()

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.prepareCount, 1)
        XCTAssertEqual(snapshot.lastSettings?.model, "openai_whisper-large-v3-v20240930_turbo")
        XCTAssertEqual(snapshot.reportedProgress, [0.6])
        XCTAssertEqual(harness.model.localSpeechPreparationState, .ready)
        XCTAssertEqual(harness.model.localSpeechPreparedModelIdentifier, "openai_whisper-large-v3-v20240930_turbo")
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

        XCTAssertEqual(harness.model.recordPanelHotkeyBinding, .doubleCommand)
        let storedValue = try await settingsStore.string(forKey: .recordPanelHotkey)
        XCTAssertNil(storedValue)
    }

    func testShowRunHistorySelectsStreamSection() {
        let harness = makeHarness()

        XCTAssertEqual(harness.model.selectedSidebarSection, .stream)

        harness.model.showRunHistory()

        XCTAssertEqual(harness.model.selectedSidebarSection, .stream)
        XCTAssertEqual(harness.model.runHistoryScope, .recentRuns)
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
            harness.model.recordWorkspace.snapshot.collections.first?.id
        )

        harness.model.showRecordCollection(collectionID)
        harness.model.selectSidebarSection(.settings)

        XCTAssertEqual(harness.model.selectedSidebarSection, .settings)
        XCTAssertEqual(harness.model.recordWorkspace.selectedCollectionID, collectionID)
    }

    func testShowWorkflowSelectsWorkflowSidebarDestination() throws {
        let harness = makeHarness()
        let workflow = try XCTUnwrap(harness.model.workflows.first)

        harness.model.showWorkflow(workflow.id)

        XCTAssertEqual(harness.model.selectedSidebarSection, .workflows)
        XCTAssertEqual(harness.model.workflowEditorNavigationRequest?.workflowID, workflow.id)
    }
}

private enum FailingSpeechCheckCredentialError: Error {
    case writeRejected
}

private enum WakeWordSaveValidationError: Error {
    case unexpectedConfiguration
}

private actor FailingSpeechCheckCredentialStore: SecureCredentialStore {
    func credential(for key: SecureCredentialKey) async throws -> String? {
        nil
    }

    func setCredential(_ value: String, for key: SecureCredentialKey) async throws {
        throw FailingSpeechCheckCredentialError.writeRejected
    }

    func removeCredential(for key: SecureCredentialKey) async throws {
        throw FailingSpeechCheckCredentialError.writeRejected
    }
}
