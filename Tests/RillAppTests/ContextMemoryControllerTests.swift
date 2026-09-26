import RillDomainTestSupport
import RillTestSupport
import Foundation
import Testing
@testable import RillApp
import RillCore
import RillPersistence
import RillProviders
import RillWorkflows
import RillRecords
import RillKnowledge
import RillUI

@MainActor
struct ContextMemoryControllerTests {
    @Test func vocabularyOnlyUsesFrozenCandidatesWithoutAwaitingProviderAndRevokes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rill-vocabulary-controller-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let protector = try AESGCMDataProtector(key: Data(repeating: 0x42, count: AESGCMDataProtector.keyByteCount))
        let store = try SQLitePersistenceStore(databaseURL: directory.appendingPathComponent("rill.sqlite"), localDataProtector: protector)
        var workflow = try #require(BuiltinWorkflowCatalog().manifest().workflows.first { $0.titleKey == .smartCleanup })
        #expect(workflow.supportsVocabularyCorrection)
        let provider = ContextSettingsGate()
        var settings = ContextFeatureSettings()
        settings.vocabularyCorrectionEnabled = true
        settings.authorizedWorkflowIDs = [workflow.id]
        settings.providerFingerprint = ContextProviderIdentity.fingerprint(await provider.read())
        try await store.setString(String(decoding: JSONEncoder().encode(settings), as: UTF8.self), forKey: .contextFeatureSettings)
        let privacy = PrivacyPolicySettingsSource(initialSettings: .init())
        let controller = ContextMemoryController(repository: store, history: store, settingsStore: store,
            providerSettings: { await provider.read() }, privacySettings: privacy)
        let model = makeModel()
        controller.attach(model)
        let memory = try #require(model.contextMemory)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while memory.isLoading && ContinuousClock.now < deadline { await Task.yield() }
        try #require(memory.isAuthorized)
        await provider.block()
        let context = ContextSnapshot(focus: .init(applicationName: "Editor", bundleIdentifier: "test.editor", processIdentifier: 1,
            focusedRole: "AXTextArea", selectedText: "", secureInput: false), clipboard: .init(plainText: "", changeCount: 0))
        let runID = UUID()
        let candidates = (0..<70).map { HotwordCandidate(id: UUID(), term: "Term\($0)", priority: 70 - $0) }
        do {
            let result = try await BoundedOperation().run(timeout: .seconds(1)) { [workflow] in
                try await controller.prepare(runID: runID, workflow: workflow, context: context,
                    recognitionOptions: .init(), audioLifetime: AudioCaptureLifetime(runID: runID), vocabularyCandidates: candidates)
            }
            let preparation = try #require(result)
            preparation.recordingStarted()
            let frozen = try preparation.freeze(transcript: "正文")
            #expect(frozen.request.vocabularyReference?.terms == candidates.map(\.term))
            #expect(frozen.receipt.image == .disabled)
            #expect(frozen.receipt.memorySummary == .disabled)
            #expect(try await store.memoryMaintenanceStatus(now: Date()).foregroundRequestsToday == 0)
            var secure = context
            secure.focus.secureInput = true
            #expect(try await controller.prepare(runID: UUID(), workflow: workflow, context: secure,
                recognitionOptions: .init(), audioLifetime: AudioCaptureLifetime(runID: UUID()), vocabularyCandidates: candidates) == nil)
            privacy.update(.init(sensitiveAppRules: [.init(bundleIdentifier: "test.editor")]))
            #expect(try await controller.prepare(runID: UUID(), workflow: workflow, context: context,
                recognitionOptions: .init(), audioLifetime: AudioCaptureLifetime(runID: UUID()), vocabularyCandidates: candidates) == nil)
            privacy.update(.init())
            workflow.metadata[WorkflowMetadataKey.catalog] = "custom"
            #expect(try await controller.prepare(runID: UUID(), workflow: workflow, context: context,
                recognitionOptions: .init(), audioLifetime: AudioCaptureLifetime(runID: UUID()), vocabularyCandidates: candidates) == nil)
            memory.invalidateAuthorization()
            #expect(frozen.request.authorization?.isValid == false)
        } catch {
            await provider.release()
            await controller.shutdown()
            throw error
        }
        await provider.release()
        await controller.shutdown()
    }

    @Test func slowOptionalSettingsCannotDelayRecordingOrStartLateReferences() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rill-context-controller-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let protector = try AESGCMDataProtector(key: Data(repeating: 0x42, count: AESGCMDataProtector.keyByteCount))
        let store = try SQLitePersistenceStore(databaseURL: directory.appendingPathComponent("rill.sqlite"), localDataProtector: protector)
        let workflow = try #require(BuiltinWorkflowCatalog().manifest().workflows.first { $0.titleKey == .smartCleanup })
        let provider = ContextSettingsGate()
        var settings = ContextFeatureSettings()
        settings.memoryEnabled = true
        settings.vocabularyCorrectionEnabled = true
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
        let context = ContextSnapshot(focus: .init(applicationName: "Editor", bundleIdentifier: "test.editor", processIdentifier: 1,
            focusedRole: "AXTextArea", selectedText: "", secureInput: false), clipboard: .init(plainText: "", changeCount: 0))
        do {
            let preparation = try #require(try await BoundedOperation().run(timeout: .seconds(1)) {
                try await controller.prepare(runID: runID, workflow: workflow, context: context,
                    recognitionOptions: .init(), audioLifetime: AudioCaptureLifetime(runID: runID),
                    vocabularyCandidates: [.init(id: UUID(), term: "Rill", priority: 0)])
            })
            #expect(start.duration(to: .now) < .milliseconds(750))
            preparation.recordingStarted()
            let frozen = try preparation.freeze(transcript: "正文")
            #expect(frozen.request.referenceImage == nil)
            #expect(frozen.request.memorySummary == nil)
            #expect(frozen.receipt.memorySummary == .timedOut)
            #expect(frozen.request.vocabularyReference?.terms == ["Rill"])
            #expect(frozen.receipt.vocabulary?.status == .ready)
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
        let coordinator = makeTestSessionCoordinator(
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []), actionRegistry: actions,
            candidateResolver: resolver, eventBus: bus)
        return makeAppModelForTesting(workflows: [], eventBus: bus, sessionCoordinator: coordinator,
            outputActionRegistry: actions, candidateResolver: resolver, loadsPersistentSettingsOnInitialization: false,
            writeClipboardTextAction: { _ in }, deliverNextRecordAction: {},
            permissionSnapshot: .init(accessibility: .granted, microphone: .granted),
            refreshPermissionsAction: {}, requestAccessibilityAction: {}, requestMicrophoneAction: {},
            openAccessibilitySettingsAction: {}, openMicrophoneSettingsAction: {}, requestGlobalInputAction: {}, retryGlobalInputAction: {}, workflowLibraryChangedAction: {})
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
