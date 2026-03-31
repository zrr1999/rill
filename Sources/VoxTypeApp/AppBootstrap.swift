import Foundation
import VoxTypeCore
import VoxTypePersistence
import VoxTypePlatform
import VoxTypeProviders
import VoxTypeRuntime
import VoxTypeUI

@MainActor
struct AppContainer {
    let model: AppModel
    let stackPasteController: StackPasteController
    let recordingSessionManager: RecordingSessionManager
    let useClipboardItem: @Sendable (ClipboardHistoryItem) -> Void
    let updateClipboardPanelHotkey: @Sendable (HotkeyBindingDescriptor) -> Void
}

@MainActor
enum AppBootstrap {
    static func makeContainer() -> AppContainer {
        let eventBus = EventBus()
        let persistence = makePersistenceBackends()
        let diagnosticsRepository = persistence.diagnosticRepository
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus, repository: diagnosticsRepository)
        let historyRepository = persistence.historyRepository
        let deliveryStack = DeliveryStack(
            eventBus: eventBus,
            diagnostics: diagnostics,
            settingsStore: persistence.settingsStore
        )
        let candidateResolver = CandidateResolver(eventBus: eventBus, diagnostics: diagnostics)
        let focusTracker = FocusTracker()
        let pasteboard = PasteboardController()
        let injectionEngine = TextInjectionEngine(pasteboard: pasteboard)
        let audioCaptureService = AVAudioCaptureService()
        let hotkeyTap = HotkeyEventTap()
        let permissionGate = PermissionGate()
        let contextProvider = BuiltinContextProvider(focusTracker: focusTracker, pasteboard: pasteboard)
        let whisperKitConfigurationProvider: @Sendable () async -> WhisperKitRecognizer.Configuration = {
            await loadWhisperKitConfiguration(from: persistence.settingsStore)
        }
        let deepgramConfigurationProvider: @Sendable () async -> DeepgramRecognizer.Configuration? = {
            await loadDeepgramConfiguration(from: persistence.settingsStore)
        }
        let whisperKitRecognizer = WhisperKitRecognizer(configurationProvider: whisperKitConfigurationProvider)

        let recognizerRegistry = SpeechRecognizerRegistry(
            recognizers: [
                whisperKitRecognizer,
                DeepgramRecognizer(configurationProvider: deepgramConfigurationProvider),
                DemoDirectRecognizer(),
                DemoAmbiguousRecognizer(),
                SelectionCaptureRecognizer(),
            ]
        )
        let transformerRegistry = TextTransformerRegistry(
            transformers: [
                SnippetReplacementTransformer(),
                DemoLLMTransformer(),
                WhitespaceNormalizerTransformer(),
            ]
        )
        let actionRegistry = OutputActionRegistry(
            actions: [
                PushToStackAction(stack: deliveryStack),
                ClipboardCopyAction(pasteboard: pasteboard, clipboardCapture: deliveryStack),
                InjectTextAction(engine: injectionEngine),
            ]
        )

        let coordinator = SessionCoordinator(
            contextProvider: contextProvider,
            recognizerRegistry: recognizerRegistry,
            transformerRegistry: transformerRegistry,
            actionRegistry: actionRegistry,
            candidateResolver: candidateResolver,
            deliveryStack: deliveryStack,
            eventBus: eventBus,
            diagnostics: diagnostics,
            defaultStackDeliveryActionID: "inject.text"
        )

        let manifest = loadWorkflowManifest(
            recognizerRegistry: recognizerRegistry,
            transformerRegistry: transformerRegistry,
            actionRegistry: actionRegistry,
            diagnostics: diagnostics
        )
        let workflows = manifest.workflows
        let workflowSelectionBridge = WorkflowSelectionBridge()

        let stackPasteController = StackPasteController(
            hotkeyTap: hotkeyTap,
            pasteboard: pasteboard,
            contextProvider: contextProvider,
            deliveryStack: deliveryStack,
            sessionCoordinator: coordinator,
            eventBus: eventBus,
            diagnostics: diagnostics
        )
        let recordingSessionManager = RecordingSessionManager(
            audioCaptureService: audioCaptureService,
            hotkeyTap: hotkeyTap,
            sessionCoordinator: coordinator,
            eventBus: eventBus,
            diagnostics: diagnostics,
            workflowProvider: {
                await MainActor.run {
                    workflowSelectionBridge.enabledWorkflows(for: .hotkey)
                }
            }
        )
        let workflowAudioRunController = WorkflowAudioRunController(
            audioCaptureService: audioCaptureService,
            sessionCoordinator: coordinator,
            diagnostics: diagnostics
        )
        let deepgramAudioTestController = DeepgramAudioTestController(
            audioCaptureService: audioCaptureService,
            diagnostics: diagnostics
        )

        var model: AppModel?
        model = AppModel(
            workflows: workflows,
            eventBus: eventBus,
            sessionCoordinator: coordinator,
            deliveryStack: deliveryStack,
            candidateResolver: candidateResolver,
            historyRepository: historyRepository,
            diagnosticRepository: diagnosticsRepository,
            settingsStore: persistence.settingsStore,
            prepareWhisperKitAction: { settings, progressCallback in
                try await whisperKitRecognizer.prepareModel(
                    using: whisperKitConfiguration(forModelIdentifier: trimmedNonEmpty(settings.model)),
                    progressCallback: progressCallback
                )
            },
            startWorkflowAudioRunAction: { workflow, binding in
                try await workflowAudioRunController.startRun(workflow: workflow, binding: binding)
            },
            finishWorkflowAudioRunAction: {
                try await workflowAudioRunController.finishRun()
            },
            startDeepgramAudioTestAction: { settings in
                try await deepgramAudioTestController.startTest(settings: settings)
            },
            finishDeepgramAudioTestAction: { settings in
                try await deepgramAudioTestController.finishTest(settings: settings)
            },
            cancelDeepgramAudioTestAction: {
                await deepgramAudioTestController.cancelTest()
            },
            pasteTopOfStackAction: {
                Task {
                    await stackPasteController.pasteTopOfStack()
                }
            },
            permissionSnapshot: permissionGate.snapshot,
            refreshPermissionsAction: {
                permissionGate.refresh()
                guard let model else { return }
                model.updatePermissionSnapshot(permissionGate.snapshot)
            },
            requestAccessibilityAction: {
                permissionGate.requestAccessibilityAccess()
                guard let model else { return }
                model.updatePermissionSnapshot(permissionGate.snapshot)
            },
            requestMicrophoneAction: {
                permissionGate.requestMicrophoneAccess { snapshot in
                    guard let model else { return }
                    model.updatePermissionSnapshot(snapshot)
                }
            },
            openAccessibilitySettingsAction: {
                permissionGate.openAccessibilitySettings()
            },
            openMicrophoneSettingsAction: {
                permissionGate.openMicrophoneSettings()
            }
        )
        guard let resolvedModel = model else {
            preconditionFailure("AppModel was not initialized")
        }
        workflowSelectionBridge.model = resolvedModel

        resolvedModel.updatePermissionSnapshot(permissionGate.snapshot)

        Task {
            if let startupDiagnostic = persistence.startupDiagnostic {
                await diagnostics.record(startupDiagnostic)
            }
            await diagnostics.record(WhisperKitRecognizer.startupDiagnostic())
            if let configuration = await loadDeepgramConfiguration(from: persistence.settingsStore) {
                await diagnostics.record(DeepgramRecognizer.startupDiagnostic(configuration: configuration))
            } else {
                await diagnostics.record(DeepgramRecognizer.startupDiagnostic())
            }
            await recordingSessionManager.start()
            await stackPasteController.start()
        }

        return AppContainer(
            model: resolvedModel,
            stackPasteController: stackPasteController,
            recordingSessionManager: recordingSessionManager,
            useClipboardItem: { item in
                Task {
                    if item.contentKind == .text {
                        await coordinator.deliverClipboardItem(itemID: item.id, actionID: "inject.text")
                        return
                    }

                    do {
                        try await injectionEngine.injectClipboardSnapshot(item.clipboardSnapshot)
                        await deliveryStack.markUsed(itemID: item.id)
                    } catch {
                        await eventBus.publish(
                            .runFailed(
                                runID: nil,
                                workflow: nil,
                                message: error.localizedDescription
                            )
                        )
                    }
                }
            },
            updateClipboardPanelHotkey: { binding in
                hotkeyTap.setClipboardPanelHotkeyBinding(binding)
            }
        )
    }

    private static func makePersistenceBackends() -> (
        diagnosticRepository: any DiagnosticRepository,
        historyRepository: any HistoryRepository,
        settingsStore: (any SettingsStore)?,
        startupDiagnostic: DiagnosticEvent?
    ) {
        do {
            let store = try SQLitePersistenceStore()
            let startupDiagnostic = DiagnosticEvent(
                subsystem: .session,
                level: .info,
                event: "persistence.sqlite.ready",
                message: "SQLite persistence is active."
            )
            return (
                diagnosticRepository: store,
                historyRepository: store,
                settingsStore: store,
                startupDiagnostic: startupDiagnostic
            )
        } catch {
            let startupDiagnostic = DiagnosticEvent(
                subsystem: .session,
                level: .warning,
                event: "persistence.sqlite.fallback",
                message: "SQLite persistence could not be initialized. Falling back to in-memory storage.",
                metadata: ["error": error.localizedDescription]
            )
            return (
                diagnosticRepository: InMemoryDiagnosticRepository(),
                historyRepository: InMemoryHistoryRepository(),
                settingsStore: nil,
                startupDiagnostic: startupDiagnostic
            )
        }
    }

    private static func loadWorkflowManifest(
        recognizerRegistry: SpeechRecognizerRegistry,
        transformerRegistry: TextTransformerRegistry,
        actionRegistry: OutputActionRegistry,
        diagnostics: DiagnosticsRecorder
    ) -> WorkflowManifest {
        let fallback = BuiltinWorkflowCatalog().manifest()

        guard let manifestURL = Bundle.module.url(
            forResource: "BuiltinWorkflowManifest",
            withExtension: "json"
        ) else {
            Task {
                await diagnostics.record(
                    DiagnosticEvent(
                        subsystem: .providers,
                        level: .warning,
                        event: "workflow-manifest.bundle.missing",
                        message: "Workflow manifest resource was not found. Falling back to the built-in catalog."
                    )
                )
            }
            return fallback
        }

        do {
            let manifest = try JSONWorkflowManifestLoader(url: manifestURL).loadManifest()
            try WorkflowManifestValidator(
                recognizerRegistry: recognizerRegistry,
                transformerRegistry: transformerRegistry,
                actionRegistry: actionRegistry
            ).validate(manifest)

            Task {
                await diagnostics.record(
                    DiagnosticEvent(
                        subsystem: .providers,
                        level: .info,
                        event: "workflow-manifest.loaded",
                        message: "Loaded workflow manifest from the app bundle.",
                        metadata: ["path": manifestURL.lastPathComponent]
                    )
                )
            }

            return manifest
        } catch {
            Task {
                await diagnostics.record(
                    DiagnosticEvent(
                        subsystem: .providers,
                        level: .warning,
                        event: "workflow-manifest.fallback",
                        message: "Failed to load the workflow manifest. Falling back to the built-in catalog.",
                        metadata: ["error": error.localizedDescription]
                    )
                )
            }
            return fallback
        }
    }

    private nonisolated static func loadDeepgramConfiguration(
        from settingsStore: (any SettingsStore)?
    ) async -> DeepgramRecognizer.Configuration? {
        guard let settingsStore else { return nil }

        do {
            let storedAPIKey = try await settingsStore.string(forKey: .deepgramAPIKey)
            let storedBaseURL = try await settingsStore.string(forKey: .deepgramBaseURL)
            let storedModel = try await settingsStore.string(forKey: .deepgramModel)
            let storedLanguage = try await settingsStore.string(forKey: .deepgramLanguage)

            return DeepgramRecognizer.Configuration(
                apiKey: trimmedNonEmpty(storedAPIKey),
                baseURL: trimmedNonEmpty(storedBaseURL) ?? DeepgramSettings().baseURL,
                model: trimmedNonEmpty(storedModel) ?? DeepgramSettings().model,
                language: trimmedNonEmpty(storedLanguage)
            )
        } catch {
            return nil
        }
    }

    private nonisolated static func loadWhisperKitConfiguration(
        from settingsStore: (any SettingsStore)?
    ) async -> WhisperKitRecognizer.Configuration {
        guard let settingsStore else {
            return whisperKitConfiguration(forModelIdentifier: nil)
        }

        do {
            let storedModel = try await settingsStore.string(forKey: .whisperKitModel)
            return whisperKitConfiguration(forModelIdentifier: trimmedNonEmpty(storedModel))
        } catch {
            return whisperKitConfiguration(forModelIdentifier: nil)
        }
    }

    private nonisolated static func whisperKitConfiguration(
        forModelIdentifier modelIdentifier: String?
    ) -> WhisperKitRecognizer.Configuration {
        WhisperKitRecognizer.Configuration(
            model: modelIdentifier,
            downloadIfNeeded: true,
            prewarm: false
        )
    }

    private nonisolated static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
private final class WorkflowSelectionBridge {
    weak var model: AppModel?

    func enabledWorkflows(for trigger: TriggerBinding) -> [WorkflowDefinition] {
        model?.enabledWorkflows(for: trigger) ?? []
    }
}
