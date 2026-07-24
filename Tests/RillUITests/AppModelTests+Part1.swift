import XCTest
@testable import RillCore
@testable import RillRuntime
@testable import RillUI

private actor FailThenSucceedDiagnosticRepository: DiagnosticRepository {
    private enum ReadFailure: Error {
        case unavailable
    }

    private let recoveredEvents: [DiagnosticEvent]
    private var reads = 0

    init(recoveredEvents: [DiagnosticEvent]) {
        self.recoveredEvents = recoveredEvents
    }

    func save(_ event: DiagnosticEvent) async throws {}

    func events(matching query: DiagnosticQuery) async throws -> [DiagnosticEvent] {
        reads += 1
        guard reads > 1 else { throw ReadFailure.unavailable }
        return recoveredEvents
    }

    func readCount() -> Int {
        reads
    }
}

private func appModelTestTrustedLocalSpeechModels() -> [LocalSpeechModelDescriptor] {
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

@MainActor
extension AppModelTests {
    func testNonAudioWorkflowAuthorizationFailureDoesNotReachCoordinatorOrAction() async {
        struct AuthorizationDenied: Error, LocalizedError {
            var errorDescription: String? { "Privacy authorization denied." }
        }
        let harness = makeHarness(
            authorizeWorkflowRunAction: { _ in throw AuthorizationDenied() }
        )

        harness.model.runWorkflow(harness.workflow)
        for _ in 0..<20 where harness.model.isRunning {
            await Task.yield()
        }

        let actionCount = await harness.actionLog.snapshot()
        let coordinatorState = await harness.model.sessionCoordinator.currentState()
        XCTAssertFalse(harness.model.isRunning)
        XCTAssertEqual(
            harness.model.lastFailure,
            harness.model.language == .english
                ? "Workflow could not start. Review Privacy and provider settings, then retry."
                : "工作流无法启动。请检查隐私与服务商设置后重试。"
        )
        XCTAssertEqual(actionCount, 0)
        XCTAssertEqual(coordinatorState, .idle)
    }

    func testClipboardReplayUsesDedicatedAuthorizationBoundary() async {
        struct GenericAuthorizationReached: Error {}
        let genericAuthorizationProbe = ProbeActionLog()
        let clipboardAuthorizationProbe = ProbeActionLog()
        let harness = makeHarness(
            authorizeWorkflowRunAction: { _ in
                await genericAuthorizationProbe.increment()
                throw GenericAuthorizationReached()
            },
            authorizeClipboardItemRunAction: { itemID, itemVersion, operation, workflow in
                await clipboardAuthorizationProbe.increment()
                let subject = ClipboardItemDryRunSubject(
                    itemID: itemID,
                    itemVersion: itemVersion,
                    groupID: ClipboardGroup.defaultGroupID,
                    contentKind: .text,
                    hasTransferableContent: true
                )
                return AuthorizedWorkflowRunContext(
                    workflow: workflow,
                    contextSnapshot: .empty,
                    recognitionOptions: .empty,
                    invocation: .clipboardItem(subject: subject, operation: operation)
                )
            }
        )
        let item = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroup.id,
            text: "replay source",
            sourceKind: .system
        )

        harness.model.replayClipboardItem(item, with: harness.workflow)
        for _ in 0..<100 where harness.model.isRunning {
            await Task.yield()
        }

        let genericAuthorizationCount = await genericAuthorizationProbe.snapshot()
        let clipboardAuthorizationCount = await clipboardAuthorizationProbe.snapshot()
        XCTAssertEqual(genericAuthorizationCount, 0)
        XCTAssertEqual(clipboardAuthorizationCount, 1)
    }

    func testClipboardReplayAuthorizationFailureDoesNotReachCoordinatorOrAction() async {
        struct AuthorizationDenied: Error, LocalizedError {
            var errorDescription: String? { "Replay privacy authorization denied." }
        }
        let harness = makeHarness(
            authorizeClipboardItemRunAction: { _, _, _, _ in throw AuthorizationDenied() }
        )
        let item = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroup.id,
            text: "CANARY-REPLAY-TEXT",
            sourceKind: .system
        )

        harness.model.replayClipboardItem(item, with: harness.workflow)
        for _ in 0..<20 where harness.model.isRunning {
            await Task.yield()
        }

        let actionCount = await harness.actionLog.snapshot()
        let coordinatorState = await harness.model.sessionCoordinator.currentState()
        XCTAssertFalse(harness.model.isRunning)
        XCTAssertEqual(
            harness.model.lastFailure,
            harness.model.language == .english
                ? "The clipboard item could not be replayed. Review Privacy and workflow settings, then retry."
                : "无法重新运行这个剪贴板项目。请检查隐私与工作流设置后重试。"
        )
        XCTAssertEqual(actionCount, 0)
        XCTAssertEqual(coordinatorState, .idle)
    }

    func testRunFailedWithoutRunIDDoesNotClearActiveRunOrCreateHistory() async {
        let harness = makeHarness()
        await waitForListenerSetup()
        let runID = UUID()
        let started = RunSnapshot(
            runID: runID,
            workflowID: harness.workflow.id,
            workflow: harness.workflow.presentation,
            trigger: .manual
        )

        await harness.eventBus.publish(.runStarted(started))
        await waitForEventProcessing()
        await harness.eventBus.publish(.runFailed(runID: nil, workflow: nil, message: "Stack injection failed"))
        await waitForEventProcessing()

        XCTAssertTrue(harness.model.isRunning)
        XCTAssertEqual(harness.model.historyRecords.count, 0)
        XCTAssertEqual(
            harness.model.lastFailure,
            harness.model.language == .english
                ? HistoryFailureSanitizer.genericMessage
                : "工作流失败。请在诊断中查看安全摘要后重试。"
        )
    }

    func testNewRunAndSuccessClearStaleFailure() async {
        let harness = makeHarness()
        await waitForListenerSetup()
        let runID = UUID()

        await harness.eventBus.publish(.runFailed(runID: nil, workflow: nil, message: "Old failure"))
        await waitForEventProcessing()
        XCTAssertEqual(
            harness.model.lastFailure,
            harness.model.language == .english
                ? HistoryFailureSanitizer.genericMessage
                : "工作流失败。请在诊断中查看安全摘要后重试。"
        )

        await harness.eventBus.publish(
            .runStarted(
                RunSnapshot(
                    runID: runID,
                    workflowID: harness.workflow.id,
                    workflow: harness.workflow.presentation,
                    trigger: .manual
                )
            )
        )
        await waitForEventProcessing()
        XCTAssertNil(harness.model.lastFailure)

        await harness.eventBus.publish(
            .runCompleted(
                WorkflowRunSummary(
                    runID: runID,
                    workflowID: harness.workflow.id,
                    workflow: harness.workflow.presentation,
                    trigger: .manual,
                    finalText: "Done"
                )
            )
        )
        await waitForEventProcessing()

        XCTAssertFalse(harness.model.isRunning)
        XCTAssertNil(harness.model.lastFailure)
        XCTAssertEqual(harness.model.historyRecords.first?.outcome, .completed)
    }

    func testRunWorkflowGuardsAgainstDoubleClickBeforeEventsArrive() async {
        let harness = makeHarness(delay: .milliseconds(150))
        await waitForListenerSetup()
        let stream = await harness.eventBus.stream()
        let collector = Task { () -> [RillEvent] in
            var events: [RillEvent] = []
            for await event in stream {
                events.append(event)
                if case .runCompleted = event {
                    break
                }
            }
            return events
        }

        harness.model.runWorkflow(harness.workflow)
        harness.model.runWorkflow(harness.workflow)

        let events = await collector.value
        let failures = events.compactMap { event -> String? in
            if case .runFailed(_, _, let message) = event {
                return message
            }
            return nil
        }
        let actionCount = await harness.actionLog.snapshot()

        XCTAssertEqual(actionCount, 1)
        XCTAssertTrue(events.contains { event in
            if case .runStarted = event { return true }
            return false
        })
        XCTAssertTrue(failures.isEmpty)
    }

    func testManualAudioWorkflowUsesRecordThenTranscribeFlow() async {
        let probe = WorkflowAudioRunProbe()
        let eventBusHolder = EventBusHolder()
        let workflow = WorkflowDefinition(
            name: "Local Dictation",
            titleKey: .rewriteDemoStack,
            pipeline: PipelineDeclaration(
                recognizerID: "sherpa-onnx.local",
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "purple")
        )
        let harness = makeHarness(
            workflow: workflow,
            startWorkflowAudioRunAction: { workflow, binding in
                await probe.recordStart(workflowID: workflow.id, binding: binding)
            },
            finishWorkflowAudioRunAction: {
                await probe.recordFinish()
                guard let eventBus = await eventBusHolder.get() else { return }
                let runID = UUID()
                await eventBus.publish(
                    .runStarted(
                        RunSnapshot(
                            runID: runID,
                            workflowID: workflow.id,
                            workflow: workflow.presentation,
                            trigger: .manual
                        )
                    )
                )
                await eventBus.publish(
                    .runCompleted(
                        WorkflowRunSummary(
                            runID: runID,
                            workflowID: workflow.id,
                            workflow: workflow.presentation,
                            trigger: .manual,
                            finalText: "dictated"
                        )
                    )
                )
            }
        )
        await eventBusHolder.set(harness.eventBus)

        harness.model.runWorkflow(workflow)
        await waitForEventProcessing()

        let startedSnapshot = await probe.snapshot()
        XCTAssertEqual(startedSnapshot.startCalls.count, 1)
        XCTAssertEqual(startedSnapshot.startCalls.first?.workflowID, workflow.id)
        XCTAssertEqual(startedSnapshot.startCalls.first?.binding, .manual)
        XCTAssertTrue(harness.model.isRunning)
        XCTAssertEqual(
            harness.model.workflowRunButtonTitle(for: workflow),
            UIStrings.text(.workflowStopAndTranscribe, language: harness.model.language)
        )
        XCTAssertTrue(harness.model.canTriggerWorkflow(workflow))

        harness.model.runWorkflow(workflow)
        await waitForEventProcessing()

        let finishedSnapshot = await probe.snapshot()
        XCTAssertEqual(finishedSnapshot.finishCount, 1)
        XCTAssertFalse(harness.model.isRunning)
        XCTAssertEqual(harness.model.lastCompletedText, "dictated")
    }

    func testAudioWorkflowStaysPreparingUntilCaptureStartsAndIgnoresSecondClick() async {
        let startGate = WorkflowAudioStartGate()
        let probe = WorkflowAudioRunProbe()
        let workflow = WorkflowDefinition(
            name: "Local Dictation",
            titleKey: .rewriteDemoStack,
            pipeline: PipelineDeclaration(
                recognizerID: "sherpa-onnx.local",
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "purple")
        )
        let harness = makeHarness(
            workflow: workflow,
            startWorkflowAudioRunAction: { _, _ in
                try await startGate.suspendStart()
            },
            finishWorkflowAudioRunAction: {
                await probe.recordFinish()
            }
        )

        harness.model.runWorkflow(workflow)

        XCTAssertEqual(harness.model.workflowAudioRunState, .preparing(workflowID: workflow.id))
        XCTAssertEqual(
            harness.model.workflowRunButtonTitle(for: workflow),
            UIStrings.text(.workflowPreparingAudio, language: harness.model.language)
        )
        XCTAssertFalse(harness.model.canTriggerWorkflow(workflow))

        harness.model.runWorkflow(workflow)
        await startGate.waitUntilStarted()

        let preparingSnapshot = await probe.snapshot()
        XCTAssertEqual(harness.model.workflowAudioRunState, .preparing(workflowID: workflow.id))
        XCTAssertEqual(preparingSnapshot.finishCount, 0)

        await startGate.succeed()
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.workflowAudioRunState, .recording(workflowID: workflow.id))
        XCTAssertEqual(
            harness.model.workflowRunButtonTitle(for: workflow),
            UIStrings.text(.workflowStopAndTranscribe, language: harness.model.language)
        )
        XCTAssertTrue(harness.model.canTriggerWorkflow(workflow))
    }

    func testAudioWorkflowStartFailureResetsPreparingState() async {
        let startGate = WorkflowAudioStartGate()
        let workflow = WorkflowDefinition(
            name: "Cloud Dictation",
            titleKey: .rewriteDemoStack,
            pipeline: PipelineDeclaration(
                recognizerID: "deepgram.prerecorded",
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "cyan")
        )
        let harness = makeHarness(
            workflow: workflow,
            startWorkflowAudioRunAction: { _, _ in
                try await startGate.suspendStart()
            }
        )
        harness.model.deepgramAPIKey = "test-deepgram-key"
        await harness.model.flushPendingPersistenceWrites()

        harness.model.runWorkflow(workflow)
        await startGate.waitUntilStarted()

        XCTAssertEqual(harness.model.workflowAudioRunState, .preparing(workflowID: workflow.id))

        await startGate.fail(message: "Microphone unavailable")
        await waitForEventProcessing()

        XCTAssertFalse(harness.model.isRunning)
        XCTAssertEqual(harness.model.workflowAudioRunState, .idle)
        XCTAssertEqual(
            harness.model.lastFailure,
            harness.model.language == .english
                ? "Workflow recording could not start. Check microphone access and provider settings, then retry."
                : "无法开始工作流录音。请检查麦克风权限与服务商设置后重试。"
        )
        XCTAssertEqual(
            harness.model.workflowRunButtonTitle(for: workflow),
            UIStrings.text(.workflowRecordAndRun, language: harness.model.language)
        )
    }

    func testWorkflowLocalizationUsesTypedKeyInsteadOfRawName() {
        let harness = makeHarness(
            workflow: WorkflowDefinition(
                name: "Internal Name Changed",
                titleKey: .ambiguousDemoStack,
                pipeline: PipelineDeclaration(
                    recognizerID: "ui.test.recognizer",
                    outputActions: [OutputActionReference(id: "ui.test.action")]
                ),
                ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
            )
        )
        harness.model.language = .simplifiedChinese

        XCTAssertEqual(harness.model.localizedWorkflowName(for: harness.workflow), "确认后保存")
    }

    func testStackDeliveryFailureWithRunIDRecordsHistory() async {
        let harness = makeHarness()
        await waitForListenerSetup()
        let stackWorkflow = WorkflowPresentation(fallbackName: "Stack Delivery", titleKey: .stackDelivery)

        await harness.eventBus.publish(
            .runFailed(
                runID: UUID(),
                workflow: stackWorkflow,
                message: "Accessibility permission is required for text injection."
            )
        )
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.historyRecords.count, 1)
        XCTAssertEqual(harness.model.historyRecords.first?.outcome, .failed)
        XCTAssertTrue(harness.model.historyRecords.first?.isStackRelated == true)
    }

    func testLoadsPersistedLanguageWhileIgnoringLegacyWorkflowSelection() async {
        let secondaryWorkflow = WorkflowDefinition(
            name: "Secondary Workflow",
            titleKey: .rewriteDemoStack,
            pipeline: PipelineDeclaration(
                recognizerID: "ui.test.recognizer",
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "purple")
        )
        let settingsStore = UITestSettingsStore(
            storage: [
                .interfaceLanguage: AppLanguage.simplifiedChinese.rawValue,
                .selectedWorkflowID: secondaryWorkflow.id.uuidString,
            ]
        )
        let harness = makeHarness(
            workflows: [makeDefaultWorkflow(), secondaryWorkflow],
            settingsStore: settingsStore
        )

        await waitForEventProcessing()

        XCTAssertEqual(harness.model.language, .simplifiedChinese)
        XCTAssertEqual(harness.model.enabledManualWorkflows.map(\.id), [harness.workflow.id, secondaryWorkflow.id])
    }

    func testLoadSettingsUsesBatchFetchWithoutRestoreWrites() async {
        let secondaryWorkflow = WorkflowDefinition(
            name: "Secondary Workflow",
            titleKey: .rewriteDemoStack,
            pipeline: PipelineDeclaration(
                recognizerID: "ui.test.recognizer",
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "purple")
        )
        let settingsStore = UITestSettingsStore(
            storage: [
                .interfaceLanguage: AppLanguage.simplifiedChinese.rawValue,
                .selectedWorkflowID: secondaryWorkflow.id.uuidString,
                .deepgramAPIKey: "legacy-plaintext-must-not-load",
            ]
        )
        let credentialStore = UITestSecureCredentialStore(
            storage: [.deepgramAPIKey: "persisted-key"]
        )
        let harness = makeHarness(
            workflows: [makeDefaultWorkflow(), secondaryWorkflow],
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            settingsWriteDebounceDuration: .milliseconds(5)
        )

        await waitForEventProcessing()
        try? await Task.sleep(for: .milliseconds(30))

        let activity = await settingsStore.activitySnapshot()

        XCTAssertEqual(harness.model.language, .simplifiedChinese)
        XCTAssertEqual(harness.model.deepgramAPIKey, "persisted-key")
        XCTAssertEqual(activity.batchReadCount, 1)
        XCTAssertEqual(activity.singleReadCount, 0)
        XCTAssertTrue(activity.setCounts.isEmpty)
        XCTAssertTrue(activity.removeCounts.isEmpty)
    }

    func testUserSettingsMutationsDuringInitialReadWinPerKeyOverStaleSnapshot() async {
        let trustedModels = appModelTestTrustedLocalSpeechModels()
        let initialLanguage = AppLanguage.preferred
        let userLanguage: AppLanguage = initialLanguage == .english
            ? .simplifiedChinese
            : .english
        let settingsStore = UITestSettingsStore(
            storage: [
                .interfaceLanguage: initialLanguage.rawValue,
                .preferredSpeechEngine: PreferredSpeechEngine.cloud.rawValue,
                .legacyWhisperKitLanguage: "stale-language",
            ],
            suspendBatchReads: true
        )
        let harness = makeHarness(
            settingsStore: settingsStore,
            settingsWriteDebounceDuration: .zero,
            trustedLocalSpeechModels: trustedModels,
            defaultLocalSpeechModelIdentifier: trustedModels[0].id
        )
        await settingsStore.waitUntilBatchReadIsSuspended()
        XCTAssertTrue(harness.model.isLoadingSettings)

        XCTAssertTrue(harness.model.setInterfaceLanguage(userLanguage))
        harness.model.legacyWhisperKitLanguage = "user-language"
        await harness.model.flushPendingPersistenceWrites()

        var activity = await settingsStore.activitySnapshot()
        XCTAssertEqual(activity.storage[.interfaceLanguage], userLanguage.rawValue)
        XCTAssertEqual(activity.storage[.legacyWhisperKitLanguage], "stale-language")
        XCTAssertNil(activity.setCounts[.legacyWhisperKitLanguage])

        await settingsStore.resumeBatchRead()
        await waitForEventProcessing()

        activity = await settingsStore.activitySnapshot()
        XCTAssertFalse(harness.model.isLoadingSettings)
        XCTAssertEqual(harness.model.language, userLanguage)
        XCTAssertEqual(harness.model.legacyWhisperKitLanguage, "user-language")
        XCTAssertEqual(harness.model.currentLocalSpeechSettings().language, "")
        XCTAssertEqual(harness.model.preferredSpeechEngine, .cloud)
        XCTAssertEqual(activity.storage[.interfaceLanguage], userLanguage.rawValue)
        XCTAssertEqual(activity.storage[.legacyWhisperKitLanguage], "stale-language")
        XCTAssertNil(activity.setCounts[.legacyWhisperKitLanguage])
        XCTAssertTrue(harness.model.settingsKeysModifiedDuringInitialLoad.isEmpty)
    }

    func testLocalSpeechRuntimeStaysNotReadyUntilInitialReadPublishesTrustedSnapshot() async throws {
        let trustedModels = appModelTestTrustedLocalSpeechModels()
        let source = LocalSpeechSettingsSource()
        let settingsStore = UITestSettingsStore(
            storage: [
                .localSpeechModel: trustedModels[0].id,
                .legacyWhisperKitLanguage: "yue",
                .legacyWhisperKitDownloadIfNeeded: "false",
                .localSpeechPrewarm: "true",
            ],
            suspendBatchReads: true
        )
        let harness = makeHarness(
            settingsStore: settingsStore,
            localSpeechSettingsSource: source,
            settingsWriteDebounceDuration: .seconds(3_600),
            trustedLocalSpeechModels: trustedModels,
            defaultLocalSpeechModelIdentifier: trustedModels[0].id
        )
        await settingsStore.waitUntilBatchReadIsSuspended()

        XCTAssertThrowsError(try source.currentSettings()) { error in
            XCTAssertEqual(error as? LocalSpeechSettingsSourceError, .notReady)
        }

        // A session edit made while the persisted snapshot is in flight wins
        // for its key, but must not expose a partially restored configuration.
        harness.model.localSpeechModel = trustedModels[1].id
        XCTAssertEqual(harness.model.localSpeechModel, trustedModels[1].id)
        XCTAssertThrowsError(try source.currentSettings()) { error in
            XCTAssertEqual(error as? LocalSpeechSettingsSourceError, .notReady)
        }

        await settingsStore.resumeBatchRead()
        await waitForEventProcessing()

        XCTAssertFalse(harness.model.isLoadingSettings)
        XCTAssertEqual(
            try source.currentSettings(),
            LocalSpeechSettings(
                model: trustedModels[1].id,
                prewarm: true
            )
        )
    }

    func testCustomWhisperKitSelectionDuringInitialReadSurvivesAndReplacesStaleStorage() async {
        let settingsStore = UITestSettingsStore(
            storage: [
                .localSpeechModel: LegacyWhisperModelOption.distilLargeV3Compact.rawValue,
            ],
            suspendBatchReads: true
        )
        let harness = makeHarness(
            settingsStore: settingsStore,
            settingsWriteDebounceDuration: .zero
        )
        await settingsStore.waitUntilBatchReadIsSuspended()

        harness.model.localSpeechModelOption = .custom
        await harness.model.flushPendingPersistenceWrites()

        var activity = await settingsStore.activitySnapshot()
        XCTAssertEqual(activity.storage[.localSpeechModel], "")
        XCTAssertEqual(activity.setCounts[.localSpeechModel], 1)

        await settingsStore.resumeBatchRead()
        await waitForEventProcessing()

        activity = await settingsStore.activitySnapshot()
        XCTAssertEqual(harness.model.localSpeechModelOption, .custom)
        XCTAssertEqual(harness.model.localSpeechModel, "")
        XCTAssertEqual(activity.storage[.localSpeechModel], "")
    }

    func testCollectionMutationsAreRejectedUntilInitialSettingsReadFinishes() async throws {
        let storedWorkflow = WorkflowDefinition(
            id: UUID(),
            name: "Stored Workflow",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: AppModel.sherpaOnnxRecognizerID,
                postProcessSteps: [PostProcessStep(kind: .normalizeWhitespace)],
                outputActions: [OutputActionReference(id: "inject.text")]
            ),
            ui: WorkflowUIConfig(symbolName: "text.cursor", accentColorName: "teal"),
            metadata: [AppModel.workflowOriginMetadataKey: AppModel.userWorkflowOriginMetadataValue]
        )
        let storedRule = VocabularyRule(
            kind: .mapping,
            pattern: "stored phrase",
            replacement: "Stored Phrase"
        )
        let storedDownloadedModels = ["stored-downloaded-model"]
        let settingsStore = UITestSettingsStore(
            storage: [
                .customWorkflows: String(
                    decoding: try JSONEncoder().encode([storedWorkflow]),
                    as: UTF8.self
                ),
                .vocabularyRules: String(
                    decoding: try JSONEncoder().encode([storedRule]),
                    as: UTF8.self
                ),
                .localSpeechDownloadedModels: String(
                    decoding: try JSONEncoder().encode(storedDownloadedModels),
                    as: UTF8.self
                ),
            ],
            suspendBatchReads: true
        )
        let preparationProbe = WhisperKitPrepareProbe()
        let harness = makeHarness(
            settingsStore: settingsStore,
            prepareLocalSpeechAction: { settings, _ in
                await preparationProbe.recordPreparation(settings: settings)
                return settings.model
            }
        )
        await settingsStore.waitUntilBatchReadIsSuspended()

        harness.model.saveWorkflowDraft(
            WorkflowEditorDraft(name: "Early Workflow", recognizer: .localSpeech)
        )
        harness.model.addVocabularyRule(
            kind: .hotword,
            pattern: "Early Rule",
            replacement: "",
            matchMode: .exactPhrase,
            caseSensitive: false,
            scope: .init()
        )
        let correctionOutcome = harness.model.saveVocabularyCorrectionRule(
            VocabularyRule(pattern: "early correction", replacement: "Early Correction")
        )
        harness.model.prepareLocalSpeechModel()
        await Task.yield()

        var activity = await settingsStore.activitySnapshot()
        var preparation = await preparationProbe.snapshot()
        XCTAssertTrue(harness.model.customWorkflows.isEmpty)
        XCTAssertTrue(harness.model.vocabularyRules.isEmpty)
        XCTAssertTrue(harness.model.downloadedLocalSpeechModels.isEmpty)
        XCTAssertEqual(correctionOutcome, .notReady)
        XCTAssertEqual(preparation.prepareCount, 0)
        XCTAssertNil(activity.setCounts[.customWorkflows])
        XCTAssertNil(activity.setCounts[.workflowEnabledStates])
        XCTAssertNil(activity.setCounts[.vocabularyRules])
        XCTAssertNil(activity.setCounts[.localSpeechDownloadedModels])

        await settingsStore.resumeBatchRead()
        await waitForEventProcessing()

        activity = await settingsStore.activitySnapshot()
        preparation = await preparationProbe.snapshot()
        XCTAssertEqual(harness.model.customWorkflows.map(\.id), [storedWorkflow.id])
        XCTAssertEqual(harness.model.vocabularyRules.map(\.id), [storedRule.id])
        XCTAssertEqual(harness.model.downloadedLocalSpeechModels, storedDownloadedModels)
        XCTAssertEqual(preparation.prepareCount, 0)
        XCTAssertNil(activity.setCounts[.customWorkflows])
        XCTAssertNil(activity.setCounts[.workflowEnabledStates])
        XCTAssertNil(activity.setCounts[.vocabularyRules])
        XCTAssertNil(activity.setCounts[.localSpeechDownloadedModels])
    }

    func testWorkflowAndSpeechCheckCannotOverwriteProviderSettingsDuringInitialRead() async {
        let trustedModels = appModelTestTrustedLocalSpeechModels()
        let whisperWorkflow = WorkflowDefinition(
            name: "Local Startup Run",
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: AppModel.sherpaOnnxRecognizerID,
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
        let deepgramWorkflow = WorkflowDefinition(
            name: "Cloud Startup Run",
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: AppModel.deepgramRecognizerID,
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "cloud", accentColorName: "purple")
        )
        let settingsStore = UITestSettingsStore(
            storage: [
                .localSpeechModel: trustedModels[0].id,
                .legacyWhisperKitModelRepo: "stored-whisper-repo",
                .legacyWhisperKitModelFolder: "stored-whisper-folder",
                .legacyWhisperKitLanguage: "fr",
                .legacyWhisperKitDownloadIfNeeded: "false",
                .localSpeechPrewarm: "false",
                .deepgramBaseURL: "https://stored.example.test",
                .deepgramModel: "stored-deepgram-model",
                .deepgramLanguage: "de",
            ],
            suspendBatchReads: true
        )
        let credentialStore = UITestSecureCredentialStore(
            storage: [
                .legacyWhisperKitModelToken: "stored-whisper-token",
                .deepgramAPIKey: "stored-deepgram-key",
            ]
        )
        let harness = makeHarness(
            workflows: [whisperWorkflow, deepgramWorkflow],
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            trustedLocalSpeechModels: trustedModels,
            defaultLocalSpeechModelIdentifier: trustedModels[0].id,
            permissionSnapshot: PermissionSnapshot(
                accessibility: .granted,
                microphone: .granted
            )
        )
        await settingsStore.waitUntilBatchReadIsSuspended()

        XCTAssertFalse(harness.model.canTriggerWorkflow(whisperWorkflow))
        XCTAssertFalse(harness.model.canTriggerWorkflow(deepgramWorkflow))
        harness.model.runWorkflow(whisperWorkflow)
        harness.model.runWorkflow(deepgramWorkflow)
        harness.model.toggleDeepgramAudioTest()
        await Task.yield()

        var settingsActivity = await settingsStore.activitySnapshot()
        var credentialActivity = await credentialStore.activitySnapshot()
        XCTAssertFalse(harness.model.isRunning)
        XCTAssertEqual(harness.model.deepgramAudioTestState, .idle)
        XCTAssertTrue(settingsActivity.setCounts.isEmpty)
        XCTAssertTrue(settingsActivity.removeCounts.isEmpty)
        XCTAssertTrue(credentialActivity.setCounts.isEmpty)
        XCTAssertTrue(credentialActivity.removeCounts.isEmpty)

        await settingsStore.resumeBatchRead()
        await waitForEventProcessing()

        settingsActivity = await settingsStore.activitySnapshot()
        credentialActivity = await credentialStore.activitySnapshot()
        XCTAssertEqual(harness.model.localSpeechModel, trustedModels[0].id)
        XCTAssertEqual(harness.model.legacyWhisperKitModelToken, "")
        XCTAssertEqual(
            harness.model.currentLocalSpeechSettings(),
            LocalSpeechSettings(model: trustedModels[0].id, prewarm: false)
        )
        XCTAssertEqual(harness.model.deepgramAPIKey, "stored-deepgram-key")
        XCTAssertEqual(harness.model.deepgramBaseURL, "https://stored.example.test")
        XCTAssertEqual(harness.model.deepgramModel, "stored-deepgram-model")
        XCTAssertEqual(harness.model.deepgramLanguage, "de")
        XCTAssertTrue(settingsActivity.setCounts.isEmpty)
        XCTAssertTrue(settingsActivity.removeCounts.isEmpty)
        XCTAssertTrue(credentialActivity.setCounts.isEmpty)
        XCTAssertTrue(credentialActivity.removeCounts.isEmpty)
        XCTAssertEqual(
            credentialActivity.storage[.legacyWhisperKitModelToken],
            "stored-whisper-token"
        )
    }

    func testPresetSelectionDuringInitialReadDefersExactlyOneModelPreparation() async {
        let settingsStore = UITestSettingsStore(
            storage: [
                .localSpeechModel: "stale-whisper-model",
                .localSpeechPrewarm: "false",
            ],
            suspendBatchReads: true
        )
        let preparationProbe = WhisperKitPrepareProbe()
        let harness = makeHarness(
            settingsStore: settingsStore,
            settingsWriteDebounceDuration: .zero,
            prepareLocalSpeechAction: { settings, _ in
                await preparationProbe.recordPreparation(settings: settings)
                return settings.model
            }
        )
        await settingsStore.waitUntilBatchReadIsSuspended()

        harness.model.localSpeechModelOption = .distilLargeV3Compact
        await harness.model.flushPendingPersistenceWrites()
        var preparation = await preparationProbe.snapshot()
        XCTAssertEqual(preparation.prepareCount, 0)

        await settingsStore.resumeBatchRead()
        await waitForEventProcessing()
        await harness.model.flushPendingPersistenceWrites()

        preparation = await preparationProbe.snapshot()
        let settingsActivity = await settingsStore.activitySnapshot()
        XCTAssertEqual(preparation.prepareCount, 1)
        XCTAssertEqual(
            preparation.lastSettings?.model,
            LegacyWhisperModelOption.distilLargeV3Compact.modelIdentifier
        )
        XCTAssertEqual(harness.model.localSpeechModelOption, .distilLargeV3Compact)
        XCTAssertEqual(harness.model.localSpeechPreparationState, .ready)
        XCTAssertEqual(
            settingsActivity.storage[.localSpeechModel],
            LegacyWhisperModelOption.distilLargeV3Compact.modelIdentifier
        )
    }

    func testChangingSettingsPersistsLanguageWithoutWorkflowSelection() async throws {
        let primaryWorkflow = makeDefaultWorkflow()
        let secondaryWorkflow = WorkflowDefinition(
            name: "Secondary Workflow",
            titleKey: .rewriteDemoStack,
            pipeline: PipelineDeclaration(
                recognizerID: "ui.test.recognizer",
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "purple")
        )
        let settingsStore = UITestSettingsStore()
        let harness = makeHarness(
            workflows: [primaryWorkflow, secondaryWorkflow],
            settingsStore: settingsStore
        )

        let expectedLanguage: AppLanguage = harness.model.language == .english ? .simplifiedChinese : .english
        harness.model.language = expectedLanguage
        await waitForEventProcessing()

        let storedLanguage = try await settingsStore.string(forKey: .interfaceLanguage)
        let storedWorkflowID = try await settingsStore.string(forKey: .selectedWorkflowID)

        XCTAssertEqual(storedLanguage, expectedLanguage.rawValue)
        XCTAssertNil(storedWorkflowID)
    }

    func testLoadSettingsRestoresClipboardMergeSimilarPreferenceWithoutRewrite() async {
        let settingsStore = UITestSettingsStore(
            storage: [.clipboardMergeSimilarItems: "true"]
        )
        let harness = makeHarness(
            settingsStore: settingsStore,
            settingsWriteDebounceDuration: .milliseconds(5)
        )

        await waitForEventProcessing()
        try? await Task.sleep(for: .milliseconds(30))

        let activity = await settingsStore.activitySnapshot()

        XCTAssertTrue(harness.model.mergeSimilarClipboardItems)
        XCTAssertTrue(activity.setCounts.isEmpty)
    }

    func testLoadSettingsRestoresClipboardHistoryVisibilityPreference() async {
        let settingsStore = UITestSettingsStore(
            storage: [.clipboardHistoryVisibility: ClipboardHistoryVisibility.all.rawValue]
        )
        let harness = makeHarness(
            settingsStore: settingsStore,
            settingsWriteDebounceDuration: .milliseconds(5)
        )

        await waitForEventProcessing()
        try? await Task.sleep(for: .milliseconds(30))

        let activity = await settingsStore.activitySnapshot()

        XCTAssertEqual(harness.model.clipboardHistoryVisibility, .all)
        XCTAssertTrue(activity.setCounts.isEmpty)
    }

    func testUpdatingClipboardHistoryVisibilityPersistsSetting() async throws {
        let settingsStore = UITestSettingsStore()
        let harness = makeHarness(settingsStore: settingsStore)

        await waitForEventProcessing()

        harness.model.clipboardHistoryVisibility = .all
        await waitForEventProcessing()

        let storedValue = try await settingsStore.string(forKey: .clipboardHistoryVisibility)
        let activity = await settingsStore.activitySnapshot()

        XCTAssertEqual(storedValue, ClipboardHistoryVisibility.all.rawValue)
        XCTAssertEqual(activity.setCounts[.clipboardHistoryVisibility], 1)
    }

    func testDeepgramTextSettingWritesAreDebounced() async {
        let settingsStore = UITestSettingsStore()
        let credentialStore = UITestSecureCredentialStore()
        let harness = makeHarness(
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            settingsWriteDebounceDuration: .milliseconds(20)
        )

        await waitForEventProcessing()

        harness.model.deepgramAPIKey = "d"
        harness.model.deepgramAPIKey = "de"
        harness.model.deepgramAPIKey = "deepgram-key"

        try? await Task.sleep(for: .milliseconds(50))

        let activity = await settingsStore.activitySnapshot()
        let credentialActivity = await credentialStore.activitySnapshot()

        XCTAssertNil(activity.storage[.deepgramAPIKey])
        XCTAssertNil(activity.setCounts[.deepgramAPIKey])
        XCTAssertEqual(credentialActivity.storage[.deepgramAPIKey], "deepgram-key")
        XCTAssertEqual(credentialActivity.setCounts[.deepgramAPIKey], 1)
    }

    func testRetiredLocalSpeechSourceFieldsDoNotPersistOrReachTrustedRuntime() async {
        let trustedModels = appModelTestTrustedLocalSpeechModels()
        let settingsStore = UITestSettingsStore()
        let credentialStore = UITestSecureCredentialStore()
        let harness = makeHarness(
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            settingsWriteDebounceDuration: .milliseconds(20),
            trustedLocalSpeechModels: trustedModels,
            defaultLocalSpeechModelIdentifier: trustedModels[0].id
        )

        await waitForEventProcessing()

        harness.model.legacyWhisperKitCustomModel = "retired-custom-model"
        harness.model.legacyWhisperKitModelRepo = "retired/repository"
        harness.model.legacyWhisperKitModelToken = "retired-token"
        harness.model.legacyWhisperKitModelFolder = "/tmp/retired-model"
        harness.model.legacyWhisperKitLanguage = "fr"
        harness.model.legacyWhisperKitDownloadIfNeeded = false

        try? await Task.sleep(for: .milliseconds(50))

        let activity = await settingsStore.activitySnapshot()
        let credentialActivity = await credentialStore.activitySnapshot()

        XCTAssertEqual(
            harness.model.currentLocalSpeechSettings(),
            LocalSpeechSettings(model: trustedModels[0].id, prewarm: false)
        )
        for key in [
            AppSettingKey.legacyWhisperKitCustomModel,
            .legacyWhisperKitModelRepo,
            .legacyWhisperKitModelFolder,
            .legacyWhisperKitLanguage,
            .legacyWhisperKitDownloadIfNeeded,
        ] {
            XCTAssertNil(activity.storage[key])
            XCTAssertNil(activity.setCounts[key])
        }
        XCTAssertNil(credentialActivity.storage[.legacyWhisperKitModelToken])
        XCTAssertNil(credentialActivity.setCounts[.legacyWhisperKitModelToken])
    }

    func testLoadsAndMergesPersistedAndLiveDiagnosticsInNewestFirstOrder() async throws {
        let baseTimestamp = Date(timeIntervalSince1970: 1_000)
        let diagnosticRepository = InMemoryDiagnosticRepository()
        try await diagnosticRepository.save(
            DiagnosticEvent(
                timestamp: baseTimestamp,
                subsystem: .session,
                level: .info,
                event: "diagnostic.stored.older",
                message: "Older stored event"
            )
        )
        try await diagnosticRepository.save(
            DiagnosticEvent(
                timestamp: baseTimestamp.addingTimeInterval(2),
                subsystem: .session,
                level: .info,
                event: "diagnostic.stored.newer",
                message: "Newer stored event"
            )
        )
        let harness = makeHarness(diagnosticRepository: diagnosticRepository)

        await waitForEventProcessing()
        XCTAssertEqual(
            harness.model.diagnosticEvents.map(\.event),
            ["diagnostic.stored.newer", "diagnostic.stored.older"]
        )

        await harness.eventBus.publish(
            .diagnostic(
                DiagnosticEvent(
                    timestamp: baseTimestamp.addingTimeInterval(1),
                    subsystem: .ui,
                    level: .warning,
                    event: "diagnostic.live",
                    message: "Live event"
                )
            )
        )
        await waitForEventProcessing()

        XCTAssertEqual(
            harness.model.diagnosticEvents.map(\.event),
            ["diagnostic.stored.newer", "diagnostic.live", "diagnostic.stored.older"]
        )
    }

    func testDiagnosticsLoadFailureRemainsVisibleUntilRetrySucceeds() async {
        let recoveredEvent = DiagnosticEvent(
            timestamp: Date(timeIntervalSince1970: 1_000),
            subsystem: .ui,
            level: .info,
            event: "diagnostic.recovered",
            message: "Recovered diagnostic"
        )
        let diagnosticRepository = FailThenSucceedDiagnosticRepository(
            recoveredEvents: [recoveredEvent]
        )
        let harness = makeHarness(diagnosticRepository: diagnosticRepository)

        await waitForEventProcessing()

        XCTAssertEqual(harness.model.diagnosticsLoadState, .failed)
        guard case .failed(let entries) = DiagnosticsView.timelineContent(
            loadState: harness.model.diagnosticsLoadState,
            events: harness.model.diagnosticEvents
        ) else {
            return XCTFail("The failed repository load must not be presented as an empty timeline.")
        }
        XCTAssertTrue(entries.isEmpty)

        harness.model.refreshDiagnostics()
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.diagnosticsLoadState, .loaded)
        XCTAssertEqual(harness.model.diagnosticEvents, [recoveredEvent])
        let readCount = await diagnosticRepository.readCount()
        XCTAssertEqual(readCount, 2)
    }

    func testLoadsPersistedDeepgramSettings() async {
        let settingsStore = UITestSettingsStore(
            storage: [
                .deepgramBaseURL: "https://example.deepgram.test",
                .deepgramModel: "nova-2",
                .deepgramLanguage: "zh-CN",
            ]
        )
        let credentialStore = UITestSecureCredentialStore(
            storage: [.deepgramAPIKey: "dg-key"]
        )
        let harness = makeHarness(
            settingsStore: settingsStore,
            credentialStore: credentialStore
        )

        await waitForEventProcessing()

        XCTAssertEqual(harness.model.deepgramAPIKey, "dg-key")
        XCTAssertEqual(harness.model.deepgramBaseURL, "https://example.deepgram.test")
        XCTAssertEqual(harness.model.deepgramModel, "nova-2")
        XCTAssertEqual(harness.model.deepgramLanguage, "zh-CN")
    }

    func testLoadsPersistedVocabularyRules() async throws {
        let groupID = UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!
        let rule = VocabularyRule(
            kind: .mapping,
            pattern: "web coding",
            replacement: "vibe coding",
            matchMode: .wordBoundary,
            scope: VocabularyRuleScope(
                bundleIdentifier: "com.apple.Notes",
                clipboardGroupID: groupID,
                locale: "en-US"
            ),
            priority: 7
        )
        let payload = String(decoding: try JSONEncoder().encode([rule]), as: UTF8.self)
        let settingsStore = UITestSettingsStore(storage: [AppSettingKey(rawValue: "vocabulary.rules")!: payload])
        let settings = try await AppModel.loadStoredAppSettings(from: settingsStore)

        let mirror = Mirror(reflecting: settings)
        let loadedRules = mirror.children.first { $0.label == "vocabularyRules" }?.value as? [VocabularyRule]
        XCTAssertEqual(loadedRules, [rule])
    }

    func testVocabularySourceTracksLoadedRulesAndSessionEditsSynchronously() async throws {
        let loadedRule = VocabularyRule(
            kind: .hotword,
            pattern: "Rill",
            replacement: ""
        )
        let payload = String(
            decoding: try JSONEncoder().encode([loadedRule]),
            as: UTF8.self
        )
        let settingsStore = UITestSettingsStore(
            storage: [.vocabularyRules: payload]
        )
        let source = VocabularyRuleSource()
        let harness = makeHarness(
            settingsStore: settingsStore,
            vocabularyRuleSource: source
        )

        await waitForEventProcessing()

        XCTAssertEqual(try source.currentRules(), [loadedRule])
        harness.model.addVocabularyRule(
            kind: .hotword,
            pattern: "Project Aurora",
            replacement: "",
            matchMode: .regex,
            caseSensitive: true,
            scope: .init()
        )
        let currentRules = try source.currentRules()
        XCTAssertEqual(currentRules.map(\.pattern), ["Rill", "Project Aurora"])
    }

    func testVocabularySettingKeyDecodesRawValue() {
        XCTAssertEqual(AppSettingKey(rawValue: "vocabulary.rules")?.rawValue, "vocabulary.rules")
    }

    func testLoadsPersistedWhisperKitModelSelection() async {
        let settingsStore = UITestSettingsStore(
            storage: [
                .localSpeechModel: "distil-whisper_distil-large-v3_594MB",
            ]
        )
        let harness = makeHarness(settingsStore: settingsStore)

        await waitForEventProcessing()

        XCTAssertEqual(harness.model.localSpeechModelOption, .distilLargeV3Compact)
        XCTAssertEqual(harness.model.localSpeechModel, "distil-whisper_distil-large-v3_594MB")
    }

    func testLoadsPersistedDownloadedLocalSpeechModels() async throws {
        let payload = try XCTUnwrap(
            String(
                data: JSONEncoder().encode([
                    "openai_whisper-large-v3-v20240930",
                    "custom-downloaded-model",
                ]),
                encoding: .utf8
            )
        )
        let settingsStore = UITestSettingsStore(
            storage: [.localSpeechDownloadedModels: payload]
        )
        let harness = makeHarness(settingsStore: settingsStore)

        await waitForEventProcessing()

        XCTAssertEqual(
            harness.model.downloadedLocalSpeechModels,
            ["custom-downloaded-model", "openai_whisper-large-v3-v20240930"]
        )
    }

    func testLoadsPersistedCustomWhisperKitModelSelection() async {
        let settingsStore = UITestSettingsStore(
            storage: [
                .localSpeechModel: "distil-whisper_distil-large-v3_turbo_600MB-custom",
            ]
        )
        let harness = makeHarness(settingsStore: settingsStore)

        await waitForEventProcessing()

        XCTAssertEqual(harness.model.localSpeechModelOption, .custom)
        XCTAssertEqual(harness.model.legacyWhisperKitCustomModel, "distil-whisper_distil-large-v3_turbo_600MB-custom")
        XCTAssertEqual(harness.model.localSpeechModel, "distil-whisper_distil-large-v3_turbo_600MB-custom")
    }

    func testLoadsPersistedPreferredSpeechEngine() async {
        let settingsStore = UITestSettingsStore(
            storage: [
                .preferredSpeechEngine: PreferredSpeechEngine.cloud.rawValue,
            ]
        )
        let harness = makeHarness(settingsStore: settingsStore)

        await waitForEventProcessing()

        XCTAssertEqual(harness.model.preferredSpeechEngine, .cloud)
        XCTAssertEqual(harness.model.defaultWorkflowDraft().recognizer.rawValue, "automatic")
    }

    func testLoadsPersistedLongRecordingMode() async {
        let settingsStore = UITestSettingsStore(
            storage: [.longRecordingModeEnabled: "true"]
        )
        let harness = makeHarness(settingsStore: settingsStore)

        await waitForEventProcessing()

        XCTAssertTrue(harness.model.longRecordingModeEnabled)
    }

    func testUpdatingLongRecordingModePersistsSetting() async {
        let settingsStore = UITestSettingsStore()
        let harness = makeHarness(settingsStore: settingsStore)

        harness.model.longRecordingModeEnabled = true
        await waitForEventProcessing()

        let snapshot = await settingsStore.activitySnapshot()
        XCTAssertEqual(snapshot.storage[.longRecordingModeEnabled], "true")
    }

    func testBuiltinHotkeyWorkflowUsesPreferredSpeechEngineForExecution() async {
        let harness = makeHarness(workflows: [makeBuiltinPushToTalkWorkflow()])

        harness.model.preferredSpeechEngine = .cloud

        let resolvedHotkeyWorkflow = harness.model.enabledWorkflows(for: .hotkey).first

        XCTAssertEqual(resolvedHotkeyWorkflow?.pipeline.recognizerID, AppModel.deepgramRecognizerID)
    }

    func testBuiltinHotkeyWorkflowUsesConfiguredVoiceGroupOutputMode() async {
        let harness = makeHarness(workflows: [makeBuiltinPushToTalkWorkflow()])

        harness.model.builtinPushToTalkOutputMode = .saveToVoiceGroup

        let resolvedHotkeyWorkflow = harness.model.enabledWorkflows(for: .hotkey).first

        XCTAssertEqual(resolvedHotkeyWorkflow?.pipeline.outputActions.first?.id, "stack.push")
        XCTAssertEqual(
            resolvedHotkeyWorkflow?.metadata[WorkflowMetadataKey.targetClipboardGroupID],
            ClipboardGroup.voiceGroupID.uuidString
        )
    }

    func testAppModelExecutionRoutingMatchesRuntimeResolvedPlan() throws {
        let workflow = makeBuiltinPushToTalkWorkflow()
        let harness = makeHarness(workflows: [workflow])
        harness.model.preferredSpeechEngine = .cloud
        harness.model.builtinPushToTalkOutputMode = .saveToVoiceGroup

        let actual = harness.model.enabledWorkflows(for: .hotkey).first
        guard case .resolved(let plan) = WorkflowExecutionPlanResolver.resolve(
            workflow,
            initiatedBy: .hotkey,
            recognizer: .cloudSpeech,
            output: .builtinSaveToVoiceGroup
        ) else {
            return XCTFail("Expected the runtime routing choices to resolve.")
        }

        XCTAssertEqual(try XCTUnwrap(actual), plan.executionWorkflow)
    }

    func testCustomHotkeyWorkflowKeepsOwnRecognizerWhenPreferredSpeechEngineChanges() async {
        let customHotkeyWorkflow = WorkflowDefinition(
            name: "Custom Hotkey Workflow",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "custom.hotkey.recognizer",
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "orange"),
            metadata: [AppModel.workflowOriginMetadataKey: AppModel.userWorkflowOriginMetadataValue]
        )
        let harness = makeHarness(workflows: [customHotkeyWorkflow])

        harness.model.preferredSpeechEngine = .cloud

        let resolvedHotkeyWorkflow = harness.model.enabledWorkflows(for: .hotkey).first

        XCTAssertEqual(resolvedHotkeyWorkflow?.pipeline.recognizerID, "custom.hotkey.recognizer")
    }

    func testPreparingLiveSubtitleSnapshotAutoHidesWhenNoFurtherUpdatesArrive() async {
        let harness = makeHarness(liveSubtitlePreparingHideDelay: .milliseconds(80))
        let snapshot = LiveSubtitleSnapshot(runID: UUID(), phase: .preparing, providerID: "whisperkit.stream")

        await waitForEventProcessing()
        await harness.eventBus.publish(.liveSubtitleUpdated(snapshot))
        await waitForEventProcessing()
        XCTAssertEqual(harness.model.liveSubtitleSnapshot?.phase, .preparing)

        try? await Task.sleep(for: .milliseconds(140))

        XCTAssertNil(harness.model.liveSubtitleSnapshot)
    }

    func testLiveSubtitlePanelActionReceivesModelUpdates() async {
        let harness = makeHarness()
        let probe = LiveSubtitlePanelProbe()
        let runID = UUID()

        harness.model.installLiveSubtitlePanelAction { snapshot, language in
            Task { await probe.record(snapshot: snapshot, language: language) }
        }
        await waitForEventProcessing()

        await harness.eventBus.publish(
            .liveSubtitleUpdated(
                LiveSubtitleSnapshot(
                    runID: runID,
                    phase: .transcribing,
                    confirmedText: "hello",
                    providerID: "whisperkit.stream"
                )
            )
        )
        await waitForEventProcessing()

        var updates = await probe.snapshot()
        XCTAssertEqual(updates.last?.snapshot?.runID, runID)
        XCTAssertEqual(updates.last?.snapshot?.phase, .transcribing)

        harness.model.language = .english
        await waitForEventProcessing()

        updates = await probe.snapshot()
        XCTAssertEqual(updates.last?.snapshot?.runID, runID)
        XCTAssertEqual(updates.last?.language, .english)
    }

    func testHiddenSnapshotFromPreviousRunDoesNotClearCurrentLiveSubtitle() async {
        let harness = makeHarness()
        let previousRunID = UUID()
        let currentRunID = UUID()

        await harness.eventBus.publish(
            .liveSubtitleUpdated(
                LiveSubtitleSnapshot(
                    runID: previousRunID,
                    phase: .finalizing,
                    confirmedText: "previous",
                    providerID: "whisperkit.stream"
                )
            )
        )
        await waitForEventProcessing()

        await harness.eventBus.publish(
            .liveSubtitleUpdated(
                LiveSubtitleSnapshot(
                    runID: currentRunID,
                    phase: .preparing,
                    providerID: "whisperkit.stream"
                )
            )
        )
        await waitForEventProcessing()

        await harness.eventBus.publish(
            .liveSubtitleUpdated(
                LiveSubtitleSnapshot(
                    runID: previousRunID,
                    phase: .hidden
                )
            )
        )
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.liveSubtitleSnapshot?.runID, currentRunID)
        XCTAssertEqual(harness.model.liveSubtitleSnapshot?.phase, .preparing)
    }

    func testAudioProcessingQueueShowsCompactOverlayWhenNoActiveCapture() async {
        let harness = makeHarness()
        let queuedRunID = UUID()

        await waitForEventProcessing()
        await harness.eventBus.publish(
            .audioProcessingQueueUpdated(
                AudioProcessingQueueSnapshot(
                    processingRunID: queuedRunID,
                    workflow: harness.workflow.presentation,
                    pendingCount: 2
                )
            )
        )
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.liveSubtitleSnapshot?.runID, queuedRunID)
        XCTAssertEqual(harness.model.liveSubtitleSnapshot?.phase, .processing)
        XCTAssertEqual(harness.model.liveSubtitleSnapshot?.queuedRunCount, 1)
        XCTAssertEqual(harness.model.liveSubtitleSnapshot?.prefersCompactLayout, true)
    }

    func testLiveSubtitleCarriesBackgroundQueueCountWhileRecording() async {
        let harness = makeHarness()
        let liveRunID = UUID()

        await waitForEventProcessing()
        await harness.eventBus.publish(
            .audioProcessingQueueUpdated(
                AudioProcessingQueueSnapshot(
                    processingRunID: UUID(),
                    workflow: harness.workflow.presentation,
                    pendingCount: 3
                )
            )
        )
        await harness.eventBus.publish(
            .liveSubtitleUpdated(
                LiveSubtitleSnapshot(
                    runID: liveRunID,
                    workflow: harness.workflow.presentation,
                    phase: .transcribing,
                    confirmedText: "hello",
                    providerID: "whisperkit.stream"
                )
            )
        )
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.liveSubtitleSnapshot?.runID, liveRunID)
        XCTAssertEqual(harness.model.liveSubtitleSnapshot?.phase, .transcribing)
        XCTAssertEqual(harness.model.liveSubtitleSnapshot?.queuedRunCount, 2)
        XCTAssertEqual(harness.model.liveSubtitleSnapshot?.prefersCompactLayout, false)
    }

    func testLoadingLocalSpeechSettingsLoadsRuntimeWithCoreMLPrewarmEnabled() async {
        let warmupProbe = WhisperWarmupProbe()
        let settingsStore = UITestSettingsStore(
            storage: [
                .preferredSpeechEngine: PreferredSpeechEngine.local.rawValue,
                .localSpeechModel: "openai_whisper-large-v3",
                .localSpeechPrewarm: "true",
            ]
        )
        let harness = makeHarness(
            settingsStore: settingsStore,
            warmLocalSpeechForCaptureAction: { settings in
                await warmupProbe.record(settings)
                return settings.model
            }
        )

        _ = harness
        try? await Task.sleep(for: .milliseconds(260))

        let warmedSettings = await warmupProbe.snapshot()
        XCTAssertEqual(warmedSettings?.model, "openai_whisper-large-v3")
        XCTAssertEqual(warmedSettings?.prewarm, true)
    }

    func testLoadingLocalSpeechSettingsLoadsRuntimeWithCoreMLPrewarmDisabled() async {
        let warmupProbe = WhisperWarmupProbe()
        let settingsStore = UITestSettingsStore(
            storage: [
                .preferredSpeechEngine: PreferredSpeechEngine.local.rawValue,
                .localSpeechModel: "openai_whisper-large-v3",
                .localSpeechPrewarm: "false",
            ]
        )
        let harness = makeHarness(
            settingsStore: settingsStore,
            warmLocalSpeechForCaptureAction: { settings in
                await warmupProbe.record(settings)
                return settings.model
            }
        )

        _ = harness
        try? await Task.sleep(for: .milliseconds(260))

        let loadedSettings = await warmupProbe.snapshot()
        XCTAssertEqual(loadedSettings?.model, "openai_whisper-large-v3")
        XCTAssertEqual(loadedSettings?.prewarm, false)
        XCTAssertEqual(harness.model.localSpeechPreparationState, .ready)
        XCTAssertEqual(
            harness.model.localSpeechPreparedModelIdentifier,
            "openai_whisper-large-v3"
        )
    }

    func testLoadsPersistedClipboardPanelHotkeyBinding() async {
        let shortcut = KeyboardShortcut(keyCode: 8, modifiers: [.command, .shift])
        let settingsStore = UITestSettingsStore(
            storage: [
                .clipboardPanelHotkey: shortcut.storageString,
            ]
        )
        let harness = makeHarness(settingsStore: settingsStore)

        await waitForEventProcessing()

        XCTAssertEqual(
            harness.model.clipboardPanelHotkeyBinding,
            .keyboardShortcut(shortcut)
        )
    }

    func testLoadsPersistedWorkflowEnabledStates() async throws {
        let primaryWorkflow = makeDefaultWorkflow()
        let secondaryWorkflow = WorkflowDefinition(
            id: UUID(),
            name: "Secondary Workflow",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "ui.test.recognizer",
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "orange")
        )
        let storedEnabledStates = try XCTUnwrap(
            String(
                data: JSONEncoder().encode([secondaryWorkflow.id.uuidString: false]),
                encoding: .utf8
            )
        )
        let settingsStore = UITestSettingsStore(
            storage: [.workflowEnabledStates: storedEnabledStates]
        )
        let harness = makeHarness(
            workflows: [primaryWorkflow, secondaryWorkflow],
            settingsStore: settingsStore
        )

        await waitForEventProcessing()

        XCTAssertTrue(harness.model.isWorkflowEnabled(primaryWorkflow))
        XCTAssertFalse(harness.model.isWorkflowEnabled(secondaryWorkflow))
    }

    func testLoadsPersistedCustomWorkflowsAndSelection() async throws {
        let customWorkflow = WorkflowDefinition(
            id: UUID(),
            name: "Custom Follow-up",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "sherpa-onnx.local",
                postProcessSteps: [PostProcessStep(kind: .normalizeWhitespace)],
                outputActions: [OutputActionReference(id: "inject.text")],
                uncertaintyPolicy: UncertaintyPolicy(mode: .off, confidenceThreshold: 0, timeoutSeconds: 0),
                deliveryPolicy: DeliveryPolicy(strategy: .immediate)
            ),
            ui: WorkflowUIConfig(symbolName: "text.cursor", accentColorName: "teal"),
            metadata: ["workflow.origin": "user", "trigger.gesture": "control-option-shift-space"]
        )
        let payload = try XCTUnwrap(String(data: JSONEncoder().encode([customWorkflow]), encoding: .utf8))
        let settingsStore = UITestSettingsStore(
            storage: [
                .customWorkflows: payload,
                .selectedWorkflowID: customWorkflow.id.uuidString,
            ]
        )
        let harness = makeHarness(settingsStore: settingsStore)

        await waitForEventProcessing()

        XCTAssertEqual(harness.model.customWorkflows.count, 1)
        XCTAssertEqual(harness.model.customWorkflows.first?.name, "Custom Follow-up")
        XCTAssertTrue(harness.model.isCustomWorkflow(try XCTUnwrap(harness.model.customWorkflows.first)))
    }
}
