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
        await waitForListenerSetup()
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
        await waitForEventProcessing()

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
        await waitForEventProcessing()

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
        await waitForListenerSetup()
        let runID = UUID()
        let payloadCanary = "clipboard-replay-payload-canary"

        await harness.eventBus.publish(
            .runCompleted(
                WorkflowRunSummary(
                    runID: runID,
                    workflowID: voiceWorkflow.id,
                    workflow: voiceWorkflow.presentation,
                    trigger: .clipboardReplay,
                    finalText: payloadCanary,
                    correctionSource: RecognitionCorrectionSource(
                        preMappingText: payloadCanary,
                        context: VocabularyRuleContext(locale: "en-US")
                    )
                )
            )
        )
        await waitForEventProcessing()

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
        await waitForListenerSetup()
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
        await waitForEventProcessing()
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
        await waitForEventProcessing()

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
                outputActions: [OutputActionReference(id: "stack.push")],
                deliveryPolicy: DeliveryPolicy(strategy: .stackFirst)
            ),
            ui: WorkflowUIConfig(symbolName: "tray.and.arrow.down", accentColorName: "purple"),
            metadata: [WorkflowMetadataKey.targetClipboardGroupID: ClipboardGroup.voiceGroupID.uuidString]
        )
        let harness = makeHarness(workflows: [workflow])
        await waitForListenerSetup()
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
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.recentVoiceResultRecords.first?.runID, runID)
        XCTAssertEqual(harness.model.recentVoiceResultRecords.first?.finalText, "saved voice group text")
        XCTAssertEqual(harness.model.recentVoiceResultRecords.first?.isStackRelated, true)
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
        await waitForEventProcessing()

        let calls = await probe.snapshot()
        let captured = try XCTUnwrap(calls.first)
        XCTAssertEqual(captured.binding, .hotkey)
        XCTAssertEqual(captured.workflow.pipeline.recognizerID, AppModel.localSpeechRecognizerID)
        XCTAssertEqual(captured.workflow.pipeline.outputActions.first?.id, "stack.push")
        XCTAssertEqual(
            captured.workflow.metadata[WorkflowMetadataKey.targetClipboardGroupID],
            ClipboardGroup.voiceGroupID.uuidString
        )
    }

    func testAutomaticWorkflowKeepsPerWorkflowASRMetadataWhenResolved() async throws {
        let probe = WorkflowStartProbe()
        let workflow = WorkflowDefinition(
            name: "Auto Cloud Mandarin",
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: AppModel.localSpeechRecognizerID,
                outputActions: [OutputActionReference(id: "stack.push")],
                deliveryPolicy: .init(strategy: .stackFirst)
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
        await waitForEventProcessing()

        let calls = await probe.snapshot()
        let captured = try XCTUnwrap(calls.first)
        XCTAssertEqual(captured.workflow.pipeline.recognizerID, AppModel.localSpeechRecognizerID)
        XCTAssertEqual(captured.workflow.metadata[WorkflowMetadataKey.languageOverride], "zh-CN")
    }

    func testSavingAndDeletingCustomWorkflowPersistsLibrary() async throws {
        let settingsStore = UITestSettingsStore()
        let harness = makeHarness(settingsStore: settingsStore)
        await waitForEventProcessing()

        await harness.model.saveWorkflowDraft(
            WorkflowEditorDraft(
                name: "Follow-up Draft",
                recognizer: .localSpeech,
                postProcessSteps: [.init(kind: .normalizeWhitespace)],
                destination: .copyToClipboard
            )
        )
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.customWorkflows.count, 1)
        XCTAssertEqual(harness.model.customWorkflows.first?.name, "Follow-up Draft")
        XCTAssertTrue(harness.model.customWorkflows.first?.excludesOutputFromWorkflowCapture ?? false)

        let storedValue = try await settingsStore.string(forKey: .workflowLibrary)
        let storedData = try XCTUnwrap(storedValue?.data(using: .utf8))
        let storedLibrary = try JSONDecoder().decode(
            WorkflowLibraryDocument.self,
            from: storedData
        )
        XCTAssertEqual(storedLibrary.customWorkflows.count, 1)
        XCTAssertEqual(storedLibrary.customWorkflows.first?.name, "Follow-up Draft")
        XCTAssertTrue(
            storedLibrary.customWorkflows.first?.excludesOutputFromWorkflowCapture ?? false
        )

        let savedWorkflow = try XCTUnwrap(harness.model.customWorkflows.first)
        await harness.model.deleteCustomWorkflow(savedWorkflow)
        await waitForEventProcessing()

        XCTAssertTrue(harness.model.customWorkflows.isEmpty)
        let removedValue = try await settingsStore.string(forKey: .workflowLibrary)
        let removedData = try XCTUnwrap(removedValue?.data(using: .utf8))
        let removedLibrary = try JSONDecoder().decode(
            WorkflowLibraryDocument.self,
            from: removedData
        )
        XCTAssertTrue(removedLibrary.customWorkflows.isEmpty)
    }

    func testTOMLStoreIsSourceOfTruthForVisualSaveAndDelete() async throws {
        let settingsStore = UITestSettingsStore()
        let workflowFileStore = UITestWorkflowFileStore()
        let harness = makeHarness(
            settingsStore: settingsStore,
            workflowFileStore: workflowFileStore
        )
        await waitForEventProcessing()

        await harness.model.saveWorkflowDraft(
            WorkflowEditorDraft(
                name: "TOML Draft",
                recognizer: .localSpeech,
                postProcessSteps: [.init(kind: .normalizeWhitespace)],
                destination: .copyToClipboard
            )
        )
        await waitForEventProcessing()

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
        await waitForEventProcessing()

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
        await waitForEventProcessing()

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

        harness.model.localSpeechModelOption = .distilLargeV3Compact
        await waitForEventProcessing()

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

        harness.model.prepareLocalSpeechModel()
        await waitForEventProcessing()

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

        harness.model.prepareLocalSpeechModel()
        await waitForEventProcessing()

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

        await waitForEventProcessing()

        XCTAssertTrue(harness.model.isWorkflowEnabled(speechRecognition))
        XCTAssertNil(harness.model.workflowEnabledStates[retiredStreamingID])
    }

    func testSavingWorkflowCanDisableCaptureExclusionAndUseMenuBarTrigger() async throws {
        let settingsStore = UITestSettingsStore()
        let harness = makeHarness(settingsStore: settingsStore)
        await waitForEventProcessing()

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
        await waitForEventProcessing()

        let savedWorkflow = try XCTUnwrap(harness.model.customWorkflows.first)
        XCTAssertEqual(savedWorkflow.trigger, .menuBar)
        XCTAssertFalse(savedWorkflow.excludesOutputFromWorkflowCapture)
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
        await waitForEventProcessing()

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
        await waitForEventProcessing()
        harness.model.language = .english

        harness.model.setWorkflowEnabled(true, for: polish.id)

        XCTAssertTrue(harness.model.isWorkflowEnabled(dictation))
        XCTAssertFalse(harness.model.isWorkflowEnabled(polish))
        XCTAssertEqual(
            harness.model.workflowLibraryError,
            "Clipboard event workflows remain disabled until production actions and execution receipts are available."
        )
    }

    func testLegacyClipboardWorkflowDefaultsDisabledAndGroupEventCannotExecuteIt() async {
        let legacyWorkflow = WorkflowDefinition(
            name: "Legacy Clipboard Automation",
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: "ui.test.recognizer",
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "bolt", accentColorName: "orange"),
            metadata: ["eventType": WorkflowEditorDraft.EventType.groupItemCreated.rawValue]
        )
        let harness = makeHarness(workflows: [legacyWorkflow])
        await waitForListenerSetup()

        await harness.eventBus.publish(
            .clipboardGroupEvent(
                ClipboardGroupEventDescriptor(
                    kind: .itemCreated,
                    groupID: ClipboardGroup.defaultGroupID,
                    itemID: UUID()
                )
            )
        )
        await waitForEventProcessing()

        let actionCount = await harness.actionLog.snapshot()
        XCTAssertFalse(harness.model.isWorkflowEnabled(legacyWorkflow))
        XCTAssertEqual(actionCount, 0)
        XCTAssertFalse(harness.model.eventFeed.contains { $0.english.contains("Event trigger") })
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
        await waitForEventProcessing()
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
        await waitForEventProcessing()
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
        await waitForEventProcessing()
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

        harness.model.localSpeechModelOption = .custom
        harness.model.legacyWhisperKitCustomModel = "openai_whisper-large-v3-v20240930_turbo"
        harness.model.prepareLocalSpeechModel()
        await waitForEventProcessing()

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.prepareCount, 1)
        XCTAssertEqual(snapshot.lastSettings?.model, "openai_whisper-large-v3-v20240930_turbo")
        XCTAssertEqual(snapshot.reportedProgress, [0.6])
        XCTAssertEqual(harness.model.localSpeechPreparationState, .ready)
        XCTAssertEqual(harness.model.localSpeechPreparedModelIdentifier, "openai_whisper-large-v3-v20240930_turbo")
    }

    func testClipboardUpdatedPopulatesClipboardState() async {
        let harness = makeHarness()
        await waitForListenerSetup()
        let group = ClipboardGroup.defaultGroup

        await harness.eventBus.publish(
            .clipboardUpdated(
                ClipboardStoreSnapshot(
                    items: [
                        ClipboardHistoryItem(
                            groupID: group.id,
                            text: "saved item",
                            sourceKind: .system,
                            sourceApplicationName: "Safari",
                            sourceBundleIdentifier: "com.apple.Safari"
                        )
                    ],
                    groups: [],
                    defaultGroup: ClipboardGroupSummary(
                        group: group,
                        count: 1,
                        previewText: "saved item"
                    ),
                    appAssignments: [
                        ClipboardAppAssignment(
                            bundleIdentifier: "com.apple.Safari",
                            applicationName: "Safari",
                            groupID: nil
                        )
                    ]
                )
            )
        )
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.clipboardItems.first?.text, "saved item")
        XCTAssertEqual(harness.model.clipboardDefaultGroup.count, 1)
        XCTAssertEqual(harness.model.clipboardAppAssignments.first?.bundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(harness.model.clipboardHistoryEntries.first?.representativeItem.text, "saved item")
    }

    func testClipboardUpdatedPreservesExplicitGroupSummariesAlongsideDefaultFallback() async {
        let harness = makeHarness()
        await waitForListenerSetup()
        let defaultGroup = ClipboardGroup.defaultGroup
        let explicitGroup = ClipboardGroup(name: "Browser")

        await harness.eventBus.publish(
            .clipboardUpdated(
                ClipboardStoreSnapshot(
                    items: [
                        ClipboardHistoryItem(
                            groupID: defaultGroup.id,
                            text: "default item",
                            sourceKind: .system
                        ),
                        ClipboardHistoryItem(
                            groupID: explicitGroup.id,
                            text: "browser item",
                            sourceKind: .system
                        )
                    ],
                    groups: [
                        ClipboardGroupSummary(
                            group: explicitGroup,
                            count: 1,
                            previewText: "browser item"
                        )
                    ],
                    defaultGroup: ClipboardGroupSummary(
                        group: defaultGroup,
                        count: 1,
                        previewText: "default item"
                    ),
                    appAssignments: []
                )
            )
        )
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.clipboardGroups.first?.group.id, explicitGroup.id)
        XCTAssertEqual(harness.model.clipboardDefaultGroup.count, 1)
    }

    func testClipboardHistoryEntriesDeduplicateCopiesAndPasteCounts() async {
        let harness = makeHarness()
        await waitForListenerSetup()
        let group = ClipboardGroup.defaultGroup
        let now = Date()
        let laterUse = now.addingTimeInterval(120)

        await harness.eventBus.publish(
            .clipboardUpdated(
                ClipboardStoreSnapshot(
                    items: [
                        ClipboardHistoryItem(
                            groupID: group.id,
                            text: "alpha",
                            alternatives: ["A"],
                            createdAt: now,
                            sourceKind: .system,
                            useCount: 1,
                            lastUsedAt: laterUse,
                            tags: ["primary"]
                        ),
                        ClipboardHistoryItem(
                            groupID: group.id,
                            text: "alpha",
                            alternatives: ["B"],
                            createdAt: now.addingTimeInterval(-60),
                            sourceKind: .system,
                            useCount: 2,
                            lastUsedAt: now,
                            tags: ["secondary"]
                        ),
                        ClipboardHistoryItem(
                            groupID: group.id,
                            text: "beta",
                            createdAt: now.addingTimeInterval(-120),
                            sourceKind: .system
                        ),
                    ],
                    groups: [],
                    defaultGroup: ClipboardGroupSummary(
                        group: group,
                        count: 3,
                        previewText: "alpha"
                    ),
                    appAssignments: []
                )
            )
        )
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.clipboardDefaultGroup.count, 3)
        XCTAssertEqual(harness.model.clipboardHistoryEntries.count, 2)
        XCTAssertEqual(harness.model.clipboardHistoryEntries.first?.copyCount, 2)
        XCTAssertEqual(harness.model.clipboardHistoryEntries.first?.pasteCount, 3)
        XCTAssertEqual(harness.model.clipboardHistoryEntries.first?.alternatives, ["A", "B"])
        XCTAssertEqual(harness.model.clipboardHistoryEntries.first?.tags, ["primary", "secondary"])
        XCTAssertEqual(harness.model.clipboardHistoryEntries.first?.lastUsedAt, laterUse)
    }

    func testClipboardHistoryEntriesDoNotMergeSimilarTextWhileFeatureIsDisabled() async {
        let harness = makeHarness()
        await waitForListenerSetup()
        let group = ClipboardGroup.defaultGroup
        let now = Date()

        await harness.eventBus.publish(
            .clipboardUpdated(
                ClipboardStoreSnapshot(
                    items: [
                        ClipboardHistoryItem(
                            groupID: group.id,
                            text: "Hello, world!",
                            createdAt: now,
                            sourceKind: .system
                        ),
                        ClipboardHistoryItem(
                            groupID: group.id,
                            text: "hello world",
                            createdAt: now.addingTimeInterval(-60),
                            sourceKind: .system
                        ),
                        ClipboardHistoryItem(
                            groupID: group.id,
                            text: "Completely different",
                            createdAt: now.addingTimeInterval(-120),
                            sourceKind: .system
                        ),
                    ],
                    groups: [],
                    defaultGroup: ClipboardGroupSummary(
                        group: group,
                        count: 3,
                        previewText: "Hello, world!"
                    ),
                    appAssignments: []
                )
            )
        )
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.clipboardHistoryEntries.count, 3)
        XCTAssertFalse(harness.model.mergeSimilarClipboardItems)
    }

    func testClipboardHistoryEntriesMergeSimilarTextWhenFeatureIsEnabled() async {
        let settingsStore = UITestSettingsStore(
            storage: [.clipboardMergeSimilarItems: "true"]
        )
        let harness = makeHarness(settingsStore: settingsStore)
        await waitForListenerSetup()
        let group = ClipboardGroup.defaultGroup
        let now = Date()

        await harness.eventBus.publish(
            .clipboardUpdated(
                ClipboardStoreSnapshot(
                    items: [
                        ClipboardHistoryItem(
                            groupID: group.id,
                            text: "Hello, world!",
                            createdAt: now,
                            sourceKind: .system
                        ),
                        ClipboardHistoryItem(
                            groupID: group.id,
                            text: "hello world",
                            createdAt: now.addingTimeInterval(-60),
                            sourceKind: .system
                        ),
                        ClipboardHistoryItem(
                            groupID: group.id,
                            text: "Completely different",
                            createdAt: now.addingTimeInterval(-120),
                            sourceKind: .system
                        ),
                    ],
                    groups: [],
                    defaultGroup: ClipboardGroupSummary(
                        group: group,
                        count: 3,
                        previewText: "Hello, world!"
                    ),
                    appAssignments: []
                )
            )
        )
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.clipboardHistoryEntries.count, 2)
        XCTAssertTrue(harness.model.mergeSimilarClipboardItems)
        XCTAssertTrue(harness.model.clipboardHistoryEntries.first?.includesSimilarText == true)
    }

    func testClipboardPanelRequestedOpensClipboardPanel() async {
        let probe = ClipboardPanelProbe()
        let harness = makeHarness(showClipboardPanelAction: {
            await probe.recordShow()
        })
        await waitForListenerSetup()

        await harness.eventBus.publish(.clipboardPanelRequested)
        await waitForEventProcessing()

        let showCount = await probe.snapshot()
        XCTAssertEqual(showCount, 1)
    }

    func testUseClipboardItemInvokesInstalledAction() async {
        let probe = ClipboardUseProbe()
        let harness = makeHarness()
        let item = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroup.id,
            text: "saved item",
            sourceKind: .system
        )

        harness.model.installUseClipboardItemAction { item in
            Task {
                await probe.record(itemID: item.id)
            }
        }
        harness.model.useClipboardItem(item)
        await waitForEventProcessing()

        let usedItemIDs = await probe.snapshot()
        XCTAssertEqual(usedItemIDs, [item.id])
    }

    func testUpdatingClipboardPanelHotkeyPersistsSetting() async throws {
        let settingsStore = UITestSettingsStore()
        let harness = makeHarness(settingsStore: settingsStore)
        let shortcut = KeyboardShortcut(keyCode: 9, modifiers: [.command, .option])

        harness.model.setClipboardPanelHotkeyShortcut(shortcut)
        await waitForEventProcessing()

        let storedValue = try await settingsStore.string(forKey: .clipboardPanelHotkey)
        XCTAssertEqual(storedValue, shortcut.storageString)
    }

    func testUpdatingClipboardPanelHotkeyRejectsUnsafeShortcutBeforePersistence() async throws {
        let settingsStore = UITestSettingsStore()
        let harness = makeHarness(settingsStore: settingsStore)
        let commandQ = KeyboardShortcut(keyCode: 12, modifiers: [.command])

        harness.model.setClipboardPanelHotkeyShortcut(commandQ)
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.clipboardPanelHotkeyBinding, .doubleCommand)
        let storedValue = try await settingsStore.string(forKey: .clipboardPanelHotkey)
        XCTAssertNil(storedValue)
    }

    func testShowRunHistorySelectsUnifiedRunHistory() {
        let harness = makeHarness()

        XCTAssertEqual(harness.model.selectedSidebarSection, .dashboard)

        harness.model.showRunHistory()

        XCTAssertEqual(harness.model.selectedSidebarSection, .history)
        XCTAssertEqual(harness.model.runHistoryScope, .recentRuns)
    }

    func testShowClipboardManagementSelectsClipboardSidebarAndGroup() {
        let harness = makeHarness()
        let groupID = UUID()

        harness.model.showClipboardManagement(groupID: groupID)

        XCTAssertEqual(harness.model.selectedSidebarSection, .clipboard)
        XCTAssertEqual(harness.model.selectedClipboardSidebarGroupID, groupID)

        harness.model.selectSidebarSection(.clipboard)

        XCTAssertEqual(harness.model.selectedSidebarSection, .clipboard)
        XCTAssertNil(harness.model.selectedClipboardSidebarGroupID)

        harness.model.showClipboardManagement(groupID: groupID)
        harness.model.selectSidebarSection(.settings)

        XCTAssertEqual(harness.model.selectedSidebarSection, .settings)
        XCTAssertNil(harness.model.selectedClipboardSidebarGroupID)
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
