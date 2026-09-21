import Foundation
import Testing
@testable import RillApp
import RillCore
import RillPersistence
import RillProviders
import RillRuntime
import RillUI

@MainActor
struct ContextMemoryControllerTests {
    @Test func slowOptionalSettingsCannotDelayRecordingOrStartLateReferences() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rill-context-controller-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let protector = try AESGCMDataProtector(key: Data(repeating: 0x42, count: AESGCMDataProtector.keyByteCount))
        let store = try SQLitePersistenceStore(databaseURL: directory.appendingPathComponent("rill.sqlite"), localDataProtector: protector)
        let workflow = WorkflowDefinition(name: "Context", pipeline: PipelineDeclaration(
            recognizerID: "test", postProcessSteps: [.init(kind: .llmRewrite, prompt: "Cleanup")], outputActions: []
        ), ui: .init(symbolName: "waveform", accentColorName: "blue"))
        let provider = ContextSettingsGate()
        var settings = ContextFeatureSettings()
        settings.memoryEnabled = true
        settings.authorizedWorkflowIDs = [workflow.id]
        settings.providerFingerprint = ContextProviderIdentity.fingerprint(await provider.read())
        try await store.setString(String(decoding: JSONEncoder().encode(settings), as: UTF8.self), forKey: .contextFeatureSettings)
        let controller = ContextMemoryController(repository: store, history: store, settingsStore: store,
            providerSettings: { await provider.read() }, privacySettings: .init(initialSettings: .init()))
        let model = makeModel()
        controller.attach(model)
        let memory = try #require(model.contextMemory)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while memory.isLoading && ContinuousClock.now < deadline { await Task.yield() }
        #expect(memory.isAuthorized)
        await provider.block()
        let runID = UUID()
        let start = ContinuousClock.now
        do {
            let preparation = try #require(try await BoundedOperation.run(timeout: .seconds(1)) {
                try await controller.prepare(runID: runID, workflow: workflow, context: .empty,
                    recognitionOptions: .init(), audioLifetime: AudioCaptureLifetime(runID: runID))
            })
            #expect(start.duration(to: .now) < .milliseconds(750))
            preparation.recordingStarted()
            let frozen = try preparation.freeze(transcript: "正文")
            #expect(frozen.request.referenceImage == nil)
            #expect(frozen.request.memorySummary == nil)
            #expect(frozen.receipt.memorySummary == .timedOut)
        } catch {
            await provider.release()
            await controller.shutdown()
            throw error
        }
        await provider.release()
        await controller.shutdown()
        #expect(try await store.memoryMaintenanceStatus(now: Date()).foregroundRequestsToday == 0)
    }

    private func makeModel() -> AppModel {
        let bus = EventBus()
        let resolver = CandidateResolver(eventBus: bus)
        let actions = OutputActionRegistry(actions: [])
        let coordinator = SessionCoordinator(contextProvider: EmptyContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []), actionRegistry: actions,
            candidateResolver: resolver, eventBus: bus)
        return AppModel(workflows: [], eventBus: bus, sessionCoordinator: coordinator,
            outputActionRegistry: actions, candidateResolver: resolver, loadsPersistentSettingsOnInitialization: false,
            writeClipboardTextAction: { _ in }, deliverNextRecordAction: {},
            permissionSnapshot: .init(accessibility: .granted, microphone: .granted),
            refreshPermissionsAction: {}, requestAccessibilityAction: {}, requestMicrophoneAction: {},
            openAccessibilitySettingsAction: {}, openMicrophoneSettingsAction: {})
    }
}

private struct EmptyContextProvider: ContextProvider {
    func captureContext() async -> ContextSnapshot { .empty }
}

private actor ContextSettingsGate {
    private var blocked = false
    private var waiter: CheckedContinuation<Void, Never>?
    func block() { blocked = true }
    func release() { blocked = false; waiter?.resume(); waiter = nil }
    func read() async -> OpenAISettings {
        if blocked { await withCheckedContinuation { waiter = $0 } }
        return OpenAISettings(apiKey: "test", baseURL: LLMTextProcessing.deepSeekBaseURL, model: LLMTextProcessing.deepSeekModel)
    }
}
