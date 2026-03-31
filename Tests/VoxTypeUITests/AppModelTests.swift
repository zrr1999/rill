import XCTest
@testable import VoxTypeCore
@testable import VoxTypeRuntime
@testable import VoxTypeUI

private struct UITestContextProvider: ContextProvider {
    func captureContext() async -> ContextSnapshot { .empty }
}

private struct UITestRecognizer: SpeechRecognizer {
    let id = "ui.test.recognizer"
    let result: RecognitionResult
    let delay: Duration

    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        try? await Task.sleep(for: delay)
        return result
    }
}

private actor ProbeActionLog {
    private(set) var callCount = 0

    func increment() {
        callCount += 1
    }

    func snapshot() -> Int {
        callCount
    }
}

private struct UITestAction: OutputAction {
    let id = "ui.test.action"
    let log: ProbeActionLog

    func execute(text: String, context: ActionContext) async throws -> ActionResult {
        await log.increment()
        return .copiedToClipboard
    }
}

private struct SettingsStoreActivitySnapshot {
    let storage: [AppSettingKey: String]
    let singleReadCount: Int
    let batchReadCount: Int
    let setCounts: [AppSettingKey: Int]
    let removeCounts: [AppSettingKey: Int]
}

private actor UITestSettingsStore: SettingsStore {
    private var storage: [AppSettingKey: String]
    private var singleReadCount = 0
    private var batchReadCount = 0
    private var setCounts: [AppSettingKey: Int] = [:]
    private var removeCounts: [AppSettingKey: Int] = [:]

    init(storage: [AppSettingKey: String] = [:]) {
        self.storage = storage
    }

    func string(forKey key: AppSettingKey) async throws -> String? {
        singleReadCount += 1
        return storage[key]
    }

    func strings(forKeys keys: [AppSettingKey]) async throws -> [AppSettingKey: String] {
        batchReadCount += 1
        return keys.reduce(into: [:]) { partialResult, key in
            if let value = storage[key] {
                partialResult[key] = value
            }
        }
    }

    func setString(_ value: String, forKey key: AppSettingKey) async throws {
        storage[key] = value
        setCounts[key, default: 0] += 1
    }

    func removeValue(forKey key: AppSettingKey) async throws {
        storage.removeValue(forKey: key)
        removeCounts[key, default: 0] += 1
    }

    func activitySnapshot() -> SettingsStoreActivitySnapshot {
        SettingsStoreActivitySnapshot(
            storage: storage,
            singleReadCount: singleReadCount,
            batchReadCount: batchReadCount,
            setCounts: setCounts,
            removeCounts: removeCounts
        )
    }
}

private actor DeepgramTestProbe {
    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var lastSettings: DeepgramSettings?

    func recordStart(settings: DeepgramSettings) {
        startCount += 1
        lastSettings = settings
    }

    func recordFinish(settings: DeepgramSettings) {
        finishCount += 1
        lastSettings = settings
    }

    func snapshot() -> (startCount: Int, finishCount: Int, lastSettings: DeepgramSettings?) {
        (startCount, finishCount, lastSettings)
    }
}

private actor WhisperKitPrepareProbe {
    private(set) var prepareCount = 0
    private(set) var lastSettings: WhisperKitSettings?
    private(set) var reportedProgress: [Double] = []

    func recordPreparation(settings: WhisperKitSettings) {
        prepareCount += 1
        lastSettings = settings
    }

    func recordProgress(_ progress: Progress) {
        reportedProgress.append(progress.fractionCompleted)
    }

    func snapshot() -> (prepareCount: Int, lastSettings: WhisperKitSettings?, reportedProgress: [Double]) {
        (prepareCount, lastSettings, reportedProgress)
    }
}

private actor WorkflowAudioRunProbe {
    private(set) var startCalls: [(workflowID: UUID, binding: TriggerBinding)] = []
    private(set) var finishCount = 0

    func recordStart(workflowID: UUID, binding: TriggerBinding) {
        startCalls.append((workflowID, binding))
    }

    func recordFinish() {
        finishCount += 1
    }

    func snapshot() -> (startCalls: [(workflowID: UUID, binding: TriggerBinding)], finishCount: Int) {
        (startCalls, finishCount)
    }
}

private actor EventBusHolder {
    private var eventBus: EventBus?

    func set(_ eventBus: EventBus) {
        self.eventBus = eventBus
    }

    func get() -> EventBus? {
        eventBus
    }
}

private actor ClipboardPanelProbe {
    private(set) var showCount = 0

    func recordShow() {
        showCount += 1
    }

    func snapshot() -> Int {
        showCount
    }
}

private actor ClipboardUseProbe {
    private(set) var usedItemIDs: [UUID] = []

    func record(itemID: UUID) {
        usedItemIDs.append(itemID)
    }

    func snapshot() -> [UUID] {
        usedItemIDs
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    func testRunFailedWithoutRunIDDoesNotClearActiveRunOrCreateHistory() async {
        let harness = makeHarness()
        await waitForListenerSetup()
        let runID = UUID()
        let started = RunSnapshot(
            runID: runID,
            workflowID: harness.workflow.id,
            workflow: harness.workflow.presentation
        )

        await harness.eventBus.publish(.runStarted(started))
        await waitForEventProcessing()
        await harness.eventBus.publish(.runFailed(runID: nil, workflow: nil, message: "Stack injection failed"))
        await waitForEventProcessing()

        XCTAssertTrue(harness.model.isRunning)
        XCTAssertEqual(harness.model.historyRecords.count, 0)
        XCTAssertEqual(harness.model.lastFailure, "Stack injection failed")
    }

    func testNewRunAndSuccessClearStaleFailure() async {
        let harness = makeHarness()
        await waitForListenerSetup()
        let runID = UUID()

        await harness.eventBus.publish(.runFailed(runID: nil, workflow: nil, message: "Old failure"))
        await waitForEventProcessing()
        XCTAssertEqual(harness.model.lastFailure, "Old failure")

        await harness.eventBus.publish(
            .runStarted(
                RunSnapshot(
                    runID: runID,
                    workflowID: harness.workflow.id,
                    workflow: harness.workflow.presentation
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
                    finalText: "Done"
                )
            )
        )
        await waitForEventProcessing()

        XCTAssertFalse(harness.model.isRunning)
        XCTAssertNil(harness.model.lastFailure)
        XCTAssertEqual(harness.model.historyRecords.first?.outcome, .completed)
    }

    func testRunSelectedWorkflowGuardsAgainstDoubleClickBeforeEventsArrive() async {
        let harness = makeHarness(delay: .milliseconds(150))
        await waitForListenerSetup()
        let stream = await harness.eventBus.stream()
        let collector = Task { () -> [VoxTypeEvent] in
            var events: [VoxTypeEvent] = []
            for await event in stream {
                events.append(event)
                if case .runCompleted = event {
                    break
                }
            }
            return events
        }

        harness.model.runSelectedWorkflow()
        harness.model.runSelectedWorkflow()

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
                recognizerID: "whisperkit.local",
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
                            workflow: workflow.presentation
                        )
                    )
                )
                await eventBus.publish(
                    .runCompleted(
                        WorkflowRunSummary(
                            runID: runID,
                            workflowID: workflow.id,
                            workflow: workflow.presentation,
                            finalText: "dictated"
                        )
                    )
                )
            }
        )
        await eventBusHolder.set(harness.eventBus)

        harness.model.runSelectedWorkflow()
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
        XCTAssertTrue(harness.model.canRunSelectedWorkflow)

        harness.model.runSelectedWorkflow()
        await waitForEventProcessing()

        let finishedSnapshot = await probe.snapshot()
        XCTAssertEqual(finishedSnapshot.finishCount, 1)
        XCTAssertFalse(harness.model.isRunning)
        XCTAssertEqual(harness.model.lastCompletedText, "dictated")
    }

    func testAudioWorkflowStartFailureResetsRunningState() async {
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
                throw NSError(domain: "UITest", code: 7, userInfo: [NSLocalizedDescriptionKey: "Microphone unavailable"])
            }
        )

        harness.model.runSelectedWorkflow()
        await waitForEventProcessing()

        XCTAssertFalse(harness.model.isRunning)
        XCTAssertEqual(harness.model.lastFailure, "Microphone unavailable")
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

    func testLoadsPersistedLanguageAndWorkflowSelection() async {
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
        XCTAssertEqual(harness.model.selectedWorkflowID, secondaryWorkflow.id)
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
                .deepgramAPIKey: "persisted-key",
            ]
        )
        let harness = makeHarness(
            workflows: [makeDefaultWorkflow(), secondaryWorkflow],
            settingsStore: settingsStore,
            settingsWriteDebounceDuration: .milliseconds(5)
        )

        await waitForEventProcessing()
        try? await Task.sleep(for: .milliseconds(30))

        let activity = await settingsStore.activitySnapshot()

        XCTAssertEqual(harness.model.language, .simplifiedChinese)
        XCTAssertEqual(harness.model.selectedWorkflowID, secondaryWorkflow.id)
        XCTAssertEqual(harness.model.deepgramAPIKey, "persisted-key")
        XCTAssertEqual(activity.batchReadCount, 1)
        XCTAssertEqual(activity.singleReadCount, 0)
        XCTAssertTrue(activity.setCounts.isEmpty)
        XCTAssertTrue(activity.removeCounts.isEmpty)
    }

    func testChangingSettingsPersistsLanguageAndWorkflowSelection() async throws {
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
        harness.model.selectedWorkflowID = secondaryWorkflow.id
        await waitForEventProcessing()

        let storedLanguage = try await settingsStore.string(forKey: .interfaceLanguage)
        let storedWorkflowID = try await settingsStore.string(forKey: .selectedWorkflowID)

        XCTAssertEqual(storedLanguage, expectedLanguage.rawValue)
        XCTAssertEqual(storedWorkflowID, secondaryWorkflow.id.uuidString)
    }

    func testLoadSettingsRestoresClipboardMergeSimilarPreference() async {
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

    func testUpdatingClipboardMergeSimilarPreferencePersistsSetting() async throws {
        let settingsStore = UITestSettingsStore()
        let harness = makeHarness(settingsStore: settingsStore)

        await waitForEventProcessing()

        harness.model.mergeSimilarClipboardItems = true
        await waitForEventProcessing()

        let storedValue = try await settingsStore.string(forKey: .clipboardMergeSimilarItems)
        let activity = await settingsStore.activitySnapshot()

        XCTAssertEqual(storedValue, "true")
        XCTAssertEqual(activity.setCounts[.clipboardMergeSimilarItems], 1)
    }

    func testDeepgramTextSettingWritesAreDebounced() async {
        let settingsStore = UITestSettingsStore()
        let harness = makeHarness(
            settingsStore: settingsStore,
            settingsWriteDebounceDuration: .milliseconds(20)
        )

        await waitForEventProcessing()

        harness.model.deepgramAPIKey = "d"
        harness.model.deepgramAPIKey = "de"
        harness.model.deepgramAPIKey = "deepgram-key"

        try? await Task.sleep(for: .milliseconds(50))

        let activity = await settingsStore.activitySnapshot()

        XCTAssertEqual(activity.storage[.deepgramAPIKey], "deepgram-key")
        XCTAssertEqual(activity.setCounts[.deepgramAPIKey], 1)
    }

    func testWhisperKitTextSettingWritesAreDebounced() async {
        let settingsStore = UITestSettingsStore()
        let harness = makeHarness(
            settingsStore: settingsStore,
            settingsWriteDebounceDuration: .milliseconds(20)
        )

        await waitForEventProcessing()

        harness.model.whisperKitModelRepo = "repo"
        harness.model.whisperKitModelRepo = "repo/name"
        harness.model.whisperKitModelRepo = "repo/name/final"

        try? await Task.sleep(for: .milliseconds(50))

        let activity = await settingsStore.activitySnapshot()

        XCTAssertEqual(activity.storage[.whisperKitModelRepo], "repo/name/final")
        XCTAssertEqual(activity.setCounts[.whisperKitModelRepo], 1)
    }

    func testLoadsPersistedDiagnosticsAndAppendsLiveEvents() async throws {
        let diagnosticRepository = InMemoryDiagnosticRepository()
        try await diagnosticRepository.save(
            DiagnosticEvent(
                subsystem: .session,
                level: .info,
                event: "diagnostic.stored",
                message: "Stored event"
            )
        )
        let harness = makeHarness(diagnosticRepository: diagnosticRepository)

        await waitForEventProcessing()
        XCTAssertEqual(harness.model.diagnosticEvents.first?.event, "diagnostic.stored")

        await harness.eventBus.publish(
            .diagnostic(
                DiagnosticEvent(
                    subsystem: .ui,
                    level: .warning,
                    event: "diagnostic.live",
                    message: "Live event"
                )
            )
        )
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.diagnosticEvents.first?.event, "diagnostic.live")
    }

    func testLoadsPersistedDeepgramSettings() async {
        let settingsStore = UITestSettingsStore(
            storage: [
                .deepgramAPIKey: "dg-key",
                .deepgramBaseURL: "https://example.deepgram.test",
                .deepgramModel: "nova-2",
                .deepgramLanguage: "zh-CN",
            ]
        )
        let harness = makeHarness(settingsStore: settingsStore)

        await waitForEventProcessing()

        XCTAssertEqual(harness.model.deepgramAPIKey, "dg-key")
        XCTAssertEqual(harness.model.deepgramBaseURL, "https://example.deepgram.test")
        XCTAssertEqual(harness.model.deepgramModel, "nova-2")
        XCTAssertEqual(harness.model.deepgramLanguage, "zh-CN")
    }

    func testLoadsPersistedWhisperKitModelSelection() async {
        let settingsStore = UITestSettingsStore(
            storage: [
                .whisperKitModel: "openai_whisper-small",
            ]
        )
        let harness = makeHarness(settingsStore: settingsStore)

        await waitForEventProcessing()

        XCTAssertEqual(harness.model.whisperKitModelOption, .small)
        XCTAssertEqual(harness.model.whisperKitModel, "openai_whisper-small")
    }

    func testLoadsPersistedDownloadedWhisperKitModels() async throws {
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
            storage: [.whisperKitDownloadedModels: payload]
        )
        let harness = makeHarness(settingsStore: settingsStore)

        await waitForEventProcessing()

        XCTAssertEqual(
            harness.model.downloadedWhisperKitModels,
            ["custom-downloaded-model", "openai_whisper-large-v3-v20240930"]
        )
    }

    func testLoadsPersistedCustomWhisperKitModelSelection() async {
        let settingsStore = UITestSettingsStore(
            storage: [
                .whisperKitModel: "distil-whisper_distil-large-v3_turbo_600MB-custom",
            ]
        )
        let harness = makeHarness(settingsStore: settingsStore)

        await waitForEventProcessing()

        XCTAssertEqual(harness.model.whisperKitModelOption, .custom)
        XCTAssertEqual(harness.model.whisperKitCustomModel, "distil-whisper_distil-large-v3_turbo_600MB-custom")
        XCTAssertEqual(harness.model.whisperKitModel, "distil-whisper_distil-large-v3_turbo_600MB-custom")
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
        XCTAssertEqual(harness.model.defaultWorkflowDraft().recognizer, .cloudSpeech)
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
                recognizerID: "whisperkit.local",
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
        XCTAssertEqual(harness.model.selectedWorkflowID, customWorkflow.id)
        XCTAssertTrue(harness.model.isCustomWorkflow(try XCTUnwrap(harness.model.customWorkflows.first)))
    }

    func testSavingAndDeletingCustomWorkflowPersistsLibrary() async throws {
        let settingsStore = UITestSettingsStore()
        let harness = makeHarness(settingsStore: settingsStore)

        harness.model.saveWorkflowDraft(
            WorkflowEditorDraft(
                name: "Follow-up Draft",
                recognizer: .cloudSpeech,
                destination: .copyToClipboard,
                trigger: .manual,
                normalizeWhitespace: true
            )
        )
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.customWorkflows.count, 1)
        XCTAssertEqual(harness.model.customWorkflows.first?.name, "Follow-up Draft")
        XCTAssertTrue(harness.model.customWorkflows.first?.excludesOutputFromWorkflowCapture ?? false)

        let storedValue = try await settingsStore.string(forKey: .customWorkflows)
        let storedData = try XCTUnwrap(storedValue?.data(using: .utf8))
        let storedWorkflows = try JSONDecoder().decode([WorkflowDefinition].self, from: storedData)
        XCTAssertEqual(storedWorkflows.count, 1)
        XCTAssertEqual(storedWorkflows.first?.name, "Follow-up Draft")
        XCTAssertTrue(storedWorkflows.first?.excludesOutputFromWorkflowCapture ?? false)

        let savedWorkflow = try XCTUnwrap(harness.model.customWorkflows.first)
        harness.model.deleteCustomWorkflow(savedWorkflow)
        await waitForEventProcessing()

        XCTAssertTrue(harness.model.customWorkflows.isEmpty)
        let removedValue = try await settingsStore.string(forKey: .customWorkflows)
        XCTAssertNil(removedValue)
    }

    func testDeepgramAudioTestToggleStartsThenFinishes() async {
        let probe = DeepgramTestProbe()
        let harness = makeHarness(
            permissionSnapshot: PermissionSnapshot(accessibility: .granted, microphone: .granted),
            startDeepgramAudioTestAction: { settings in
                await probe.recordStart(settings: settings)
            },
            finishDeepgramAudioTestAction: { settings in
                await probe.recordFinish(settings: settings)
                return RecognitionResult(rawText: "cloud result", bestText: "cloud result")
            }
        )

        harness.model.deepgramAPIKey = "test-key"
        harness.model.deepgramModel = "nova-3"
        harness.model.deepgramLanguage = "en-US"
        harness.model.toggleDeepgramAudioTest()
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.deepgramAudioTestState, .recording)

        harness.model.toggleDeepgramAudioTest()
        await waitForEventProcessing()

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.startCount, 1)
        XCTAssertEqual(snapshot.finishCount, 1)
        XCTAssertEqual(snapshot.lastSettings?.apiKey, "test-key")
        XCTAssertEqual(harness.model.deepgramAudioTestState, .idle)
        XCTAssertEqual(harness.model.deepgramTestTranscript, "cloud result")
    }

    func testSelectingWhisperKitModelAutomaticallyPreparesIt() async {
        let probe = WhisperKitPrepareProbe()
        let harness = makeHarness(
            prepareWhisperKitAction: { settings, progressCallback in
                await probe.recordPreparation(settings: settings)
                let progress = Progress(totalUnitCount: 4)
                progress.completedUnitCount = 2
                progressCallback(progress)
                await probe.recordProgress(progress)
                return settings.model
            }
        )

        harness.model.whisperKitModelOption = .small
        await waitForEventProcessing()

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.prepareCount, 1)
        XCTAssertEqual(snapshot.lastSettings?.model, "openai_whisper-small")
        XCTAssertEqual(snapshot.reportedProgress, [0.5])
        XCTAssertEqual(harness.model.whisperKitModelOption, .small)
        XCTAssertEqual(harness.model.whisperKitPreparationState, .ready)
        XCTAssertEqual(harness.model.whisperKitPreparationProgress, 1)
        XCTAssertEqual(harness.model.whisperKitPreparedModelIdentifier, "openai_whisper-small")
        XCTAssertEqual(harness.model.downloadedWhisperKitModels, ["openai_whisper-small"])
        XCTAssertNil(harness.model.whisperKitPreparationError)
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

    func testSavingWorkflowCanDisableCaptureExclusionAndUseMenuBarTrigger() async throws {
        let settingsStore = UITestSettingsStore()
        let harness = makeHarness(settingsStore: settingsStore)

        harness.model.saveWorkflowDraft(
            WorkflowEditorDraft(
                name: "Chainable Menu Workflow",
                recognizer: .cloudSpeech,
                destination: .copyToClipboard,
                trigger: .menuBar,
                normalizeWhitespace: true,
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

    func testDisabledSelectedWorkflowCannotRun() async {
        let harness = makeHarness()
        harness.model.language = .simplifiedChinese

        harness.model.setWorkflowEnabled(false, for: harness.workflow.id)
        harness.model.runSelectedWorkflow()

        XCTAssertFalse(harness.model.isRunning)
        XCTAssertFalse(harness.model.canRunSelectedWorkflow)
        XCTAssertEqual(harness.model.lastFailure, "请先启用这个工作流再运行。")
    }

    func testSavingLocalWorkflowPersistsSpecificModelOverride() async {
        let harness = makeHarness()
        harness.model.saveWorkflowDraft(
            WorkflowEditorDraft(
                name: "Local Override",
                recognizer: .localSpeech,
                destination: .pasteIntoApp,
                trigger: .manual,
                normalizeWhitespace: true,
                whisperKitModelOverride: "openai_whisper-large-v3-v20240930"
            )
        )

        guard let savedWorkflow = harness.model.customWorkflows.first else {
            XCTFail("Expected saved workflow")
            return
        }
        XCTAssertEqual(savedWorkflow.metadata["recognizer.whisperkit.model"], "openai_whisper-large-v3-v20240930")
    }

    func testPreparingCustomWhisperKitModelUsesTypedIdentifier() async {
        let probe = WhisperKitPrepareProbe()
        let harness = makeHarness(
            prepareWhisperKitAction: { settings, progressCallback in
                await probe.recordPreparation(settings: settings)
                let progress = Progress(totalUnitCount: 5)
                progress.completedUnitCount = 3
                progressCallback(progress)
                await probe.recordProgress(progress)
                return settings.model
            }
        )

        harness.model.whisperKitModelOption = .custom
        harness.model.whisperKitCustomModel = "openai_whisper-large-v3-v20240930_turbo"
        harness.model.prepareWhisperKitModel()
        await waitForEventProcessing()

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.prepareCount, 1)
        XCTAssertEqual(snapshot.lastSettings?.model, "openai_whisper-large-v3-v20240930_turbo")
        XCTAssertEqual(snapshot.reportedProgress, [0.6])
        XCTAssertEqual(harness.model.whisperKitPreparationState, .ready)
        XCTAssertEqual(harness.model.whisperKitPreparedModelIdentifier, "openai_whisper-large-v3-v20240930_turbo")
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
                    groups: [
                        ClipboardGroupSummary(
                            group: group,
                            count: 1,
                            previewText: "saved item"
                        )
                    ],
                    appAssignments: [
                        ClipboardAppAssignment(
                            bundleIdentifier: "com.apple.Safari",
                            applicationName: "Safari",
                            groupID: group.id
                        )
                    ]
                )
            )
        )
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.clipboardItems.first?.text, "saved item")
        XCTAssertEqual(harness.model.clipboardGroups.first?.count, 1)
        XCTAssertEqual(harness.model.clipboardAppAssignments.first?.bundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(harness.model.clipboardHistoryEntries.first?.representativeItem.text, "saved item")
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
                    groups: [
                        ClipboardGroupSummary(
                            group: group,
                            count: 3,
                            previewText: "alpha"
                        )
                    ],
                    appAssignments: []
                )
            )
        )
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.clipboardHistoryEntries.count, 2)
        XCTAssertEqual(harness.model.clipboardHistoryEntries.first?.copyCount, 2)
        XCTAssertEqual(harness.model.clipboardHistoryEntries.first?.pasteCount, 3)
        XCTAssertEqual(harness.model.clipboardHistoryEntries.first?.alternatives, ["A", "B"])
        XCTAssertEqual(harness.model.clipboardHistoryEntries.first?.tags, ["primary", "secondary"])
        XCTAssertEqual(harness.model.clipboardHistoryEntries.first?.lastUsedAt, laterUse)
    }

    func testClipboardHistoryEntriesCanMergeSimilarTextWhenEnabled() async {
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
                    groups: [
                        ClipboardGroupSummary(
                            group: group,
                            count: 3,
                            previewText: "Hello, world!"
                        )
                    ],
                    appAssignments: []
                )
            )
        )
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.clipboardHistoryEntries.count, 3)

        harness.model.mergeSimilarClipboardItems = true
        await waitForEventProcessing()

        XCTAssertEqual(harness.model.clipboardHistoryEntries.count, 2)
        XCTAssertEqual(harness.model.clipboardHistoryEntries.first?.copyCount, 2)
        XCTAssertEqual(harness.model.clipboardHistoryEntries.first?.includesSimilarText, true)
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
}

@MainActor
private func makeHarness(
    workflow: WorkflowDefinition? = nil,
    workflows: [WorkflowDefinition]? = nil,
    delay: Duration = .zero,
    settingsStore: (any SettingsStore)? = nil,
    settingsWriteDebounceDuration: Duration = .milliseconds(300),
    diagnosticRepository: (any DiagnosticRepository)? = nil,
    permissionSnapshot: PermissionSnapshot = PermissionSnapshot(accessibility: .granted, microphone: .unknown),
    prepareWhisperKitAction: @escaping @Sendable (
        WhisperKitSettings,
        @escaping @Sendable (Progress) -> Void
    ) async throws -> String = { settings, _ in
        settings.model
    },
    startWorkflowAudioRunAction: @escaping @Sendable (WorkflowDefinition, TriggerBinding) async throws -> Void = { _, _ in },
    finishWorkflowAudioRunAction: @escaping @Sendable () async throws -> Void = {},
    startDeepgramAudioTestAction: @escaping @Sendable (DeepgramSettings) async throws -> Void = { _ in },
    finishDeepgramAudioTestAction: @escaping @Sendable (DeepgramSettings) async throws -> RecognitionResult = { _ in
        RecognitionResult(rawText: "", bestText: "")
    },
    showClipboardPanelAction: @escaping @Sendable () async -> Void = {}
) -> (
    model: AppModel,
    workflow: WorkflowDefinition,
    eventBus: EventBus,
    actionLog: ProbeActionLog
) {
    let eventBus = EventBus()
    let actionLog = ProbeActionLog()
    let deliveryStack = DeliveryStack(eventBus: eventBus)
    let resolver = CandidateResolver(eventBus: eventBus)
    let defaultWorkflow = workflow ?? makeDefaultWorkflow()
    let resolvedWorkflows = workflows ?? [defaultWorkflow]
    let primaryWorkflow = resolvedWorkflows.first ?? defaultWorkflow

    let coordinator = SessionCoordinator(
        contextProvider: UITestContextProvider(),
        recognizerRegistry: SpeechRecognizerRegistry(
            recognizers: [
                UITestRecognizer(
                    result: RecognitionResult(rawText: "hello", bestText: "hello"),
                    delay: delay
                ),
            ]
        ),
        transformerRegistry: TextTransformerRegistry(transformers: []),
        actionRegistry: OutputActionRegistry(actions: [UITestAction(log: actionLog)]),
        candidateResolver: resolver,
        deliveryStack: deliveryStack,
        eventBus: eventBus
    )

    let model = AppModel(
        workflows: resolvedWorkflows,
        eventBus: eventBus,
        sessionCoordinator: coordinator,
        deliveryStack: deliveryStack,
        candidateResolver: resolver,
        diagnosticRepository: diagnosticRepository,
        settingsStore: settingsStore,
        settingsWriteDebounceDuration: settingsWriteDebounceDuration,
        prepareWhisperKitAction: prepareWhisperKitAction,
        startWorkflowAudioRunAction: startWorkflowAudioRunAction,
        finishWorkflowAudioRunAction: finishWorkflowAudioRunAction,
        startDeepgramAudioTestAction: startDeepgramAudioTestAction,
        finishDeepgramAudioTestAction: finishDeepgramAudioTestAction,
        pasteTopOfStackAction: {},
        permissionSnapshot: permissionSnapshot,
        refreshPermissionsAction: {},
        requestAccessibilityAction: {},
        requestMicrophoneAction: {},
        openAccessibilitySettingsAction: {},
        openMicrophoneSettingsAction: {}
    )
    model.installClipboardPanelAction {
        Task {
            await showClipboardPanelAction()
        }
    }

    return (model, primaryWorkflow, eventBus, actionLog)
}

private func makeDefaultWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
        name: "UI Test Workflow",
        titleKey: .directDemoClipboard,
        pipeline: PipelineDeclaration(
            recognizerID: "ui.test.recognizer",
            outputActions: [OutputActionReference(id: "ui.test.action")]
        ),
        ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
    )
}

private func waitForListenerSetup() async {
    try? await Task.sleep(for: .milliseconds(20))
}

private func waitForEventProcessing() async {
    try? await Task.sleep(for: .milliseconds(20))
}
