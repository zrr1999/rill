import Foundation
import RillCore
import RillPlatform
import RillProviders
import RillRuntime
import RillUI

@MainActor
final class ContextMemoryController {
    private let preparationOperations = BoundedOperation(maxConcurrentOperations: 3)
    private let referenceRequests = BoundedOperation(maxConcurrentOperations: 3)
    private let repository: any ContextMemoryRepository
    private let history: any HistoryRepository
    private let settingsStore: any SettingsStore
    private let providerSettings: @Sendable () async throws -> OpenAISettings
    private let privacySettings: PrivacyPolicySettingsSource
    private let capture = ScreenContextCapture()
    private weak var model: AppModel?
    private var settings = ContextFeatureSettings()
    private var authorization: ContextReferenceAuthorization?
    private var preparations: [UUID: RunContextPreparation] = [:]
    private var scheduler: IdleMemoryScheduler?
    private var nextIdleTask: Task<Void, Never>?
    private var isShuttingDown = false
    private var mutationRevision = 0
    private var runtimeIsIdle: @Sendable () async -> Bool = { false }
    private lazy var maintenance = MemoryMaintenanceRunner(
        repository: repository,
        eligible: { [weak self] in await self?.eligibleForMaintenance() ?? false },
        session: { [weak self] in await self?.maintenanceSession() }
    )

    init(repository: any ContextMemoryRepository, history: any HistoryRepository,
         settingsStore: any SettingsStore, providerSettings: @escaping @Sendable () async throws -> OpenAISettings,
         privacySettings: PrivacyPolicySettingsSource) {
        self.repository = repository
        self.history = history
        self.settingsStore = settingsStore
        self.providerSettings = providerSettings
        self.privacySettings = privacySettings
    }

    func installRuntimeIdleCheck(_ check: @escaping @Sendable () async -> Bool) {
        runtimeIsIdle = check
    }

    func attach(_ model: AppModel) {
        self.model = model
        let memory = ContextMemoryModel(
            repository: repository, settingsStore: settingsStore,
            activate: { [weak self] in try await self?.activate($0) ?? false },
            revoke: { [weak self] in self?.revoke() },
            fingerprint: { [providerSettings] in ContextProviderIdentity.fingerprint(try await providerSettings()) },
            screenPermission: { request in request ? ScreenContextCapture.requestPermission() : ScreenContextCapture.hasPermission },
            maintain: { [weak self] in self?.scheduleNextIdle() }
        )
        model.contextMemory = memory
        memory.load()
        scheduler = IdleMemoryScheduler(
            run: { [weak self] in await self?.maintenance.runIfEligible() },
            interrupt: { [weak self] in await self?.maintenance.interrupt() }
        )
    }

    private func activate(_ settings: ContextFeatureSettings) async throws -> Bool {
        revoke()
        self.settings = settings
        let revision = mutationRevision
        guard !isShuttingDown, settings.screenContextEnabled || settings.memoryEnabled,
              settings.providerFingerprint == ContextProviderIdentity.fingerprint(try await providerSettings()),
              revision == mutationRevision else {
            if revision == mutationRevision { try await repository.setContextAuthorization(nil) }
            return false
        }
        let token = ContextReferenceAuthorization(providerFingerprint: settings.providerFingerprint!)
        authorization = token
        try await repository.setContextAuthorization(token.id)
        guard authorization === token, token.isValid, !isShuttingDown else { return false }
        return true
    }

    private func revoke() {
        mutationRevision += 1
        authorization?.revoke()
        authorization = nil
        for preparation in preparations.values { preparation.cancel() }
        preparations.removeAll()
        Task { await maintenance.interrupt() }
    }

    func prepare(runID: UUID, workflow: WorkflowDefinition, context: ContextSnapshot,
                 recognitionOptions: SpeechRecognitionRequestOptions, audioLifetime: AudioCaptureLifetime) async throws -> RunContextPreparation? {
        await maintenance.interrupt()
        guard let token = authorization, token.isValid,
              settings.authorizedWorkflowIDs.contains(workflow.id),
              workflow.supportsContextualCorrection else { return nil }
        let preparation: RunContextPreparation?
        do {
            preparation = try await preparationOperations.run(timeout: .milliseconds(250)) { [weak self] in
                try await self?.prepareWithinBudget(runID: runID, workflow: workflow, context: context,
                                                   recognitionOptions: recognitionOptions, audioLifetime: audioLifetime)
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            preparation = RunContextPreparation.skipped(
                authorization: token, audioLifetime: audioLifetime, screenEnabled: settings.screenContextEnabled,
                memoryEnabled: settings.memoryEnabled, status: error is OperationDeadlineError ? .timedOut : .unavailable)
        }
        guard token.isValid, audioLifetime.isActive else { preparation?.cancel(); throw CancellationError() }
        preparations = preparations.filter { !$0.value.isFinished }
        if let preparation { preparations[runID] = preparation }
        return preparation
    }

    private func prepareWithinBudget(runID: UUID, workflow: WorkflowDefinition, context: ContextSnapshot,
                                    recognitionOptions: SpeechRecognitionRequestOptions,
                                    audioLifetime: AudioCaptureLifetime) async throws -> RunContextPreparation? {
        guard let token = authorization, token.isValid,
              settings.authorizedWorkflowIDs.contains(workflow.id),
              workflow.supportsContextualCorrection, !context.focus.secureInput,
              let privacy = try? privacySettings.currentSettings() else { return nil }
        let excluded = Set(privacy.sensitiveAppRules.filter(\.enabled).map(\.normalizedBundleIdentifier))
        guard !excluded.contains(SensitiveAppRule(bundleIdentifier: context.focus.bundleIdentifier ?? "").normalizedBundleIdentifier) else { return nil }
        let provider = try await providerSettings()
        try Task.checkCancellation()
        guard token.isValid, token.providerFingerprint == ContextProviderIdentity.fingerprint(provider) else { throw CancellationError() }
        let generation = try await history.captureRunHistoryWriteGeneration()
        try Task.checkCancellation()
        let scope = ContextMemoryScope(workflowID: workflow.id, applicationBundleID: context.focus.bundleIdentifier,
                                       language: recognitionOptions.language ?? workflow.metadata[WorkflowMetadataKey.languageOverride])
        let summarizer = ContextCorrectionProvider(settingsProvider: providerSettings, authorization: token, operations: referenceRequests) { [repository] in
            try await repository.recordForegroundContextRequest(authorization: token, now: Date())
        }
        let preparation = try await RunContextPreparation.prepare(
            focus: context.focus,
            screenEnabled: settings.screenContextEnabled,
            memoryEnabled: settings.memoryEnabled, canSendImages: ContextProviderIdentity.supportsImages(provider),
            excludedApplications: excluded, capture: capture, summarizer: summarizer,
            memories: { [repository] in try await repository.relevantMemories(scope: scope, now: Date()) },
            authorization: token, audioLifetime: audioLifetime, operations: preparationOperations,
            saveLateSummary: { [repository, weak self] summary, runAuthorization in
                guard runAuthorization.isValid else { return }
                do {
                    try await repository.appendScreenSummary(summary, runID: runID, generation: generation, authorization: runAuthorization)
                    await self?.refreshHistory()
                } catch {}
            }
        )
        guard token.isValid, audioLifetime.isActive else { preparation.cancel(); throw CancellationError() }
        return preparation
    }

    private func refreshHistory() {
        model?.retryHistoryLoad()
        model?.refreshNewestRunHistoryPage()
    }

    private func eligibleForMaintenance() async -> Bool {
        guard !isShuttingDown, settings.memoryEnabled, authorization?.isValid == true,
              IdleMemoryScheduler.idleSeconds >= 5 * 60, let model,
              !model.settings.isLoading, !model.isLoadingPrivacySettings,
              !model.hasActiveOrQueuedVoiceRun, !model.isLocalHistoryMaintenanceRunning,
              !model.isSpeechPlaybackActive else { return false }
        return await runtimeIsIdle()
    }

    private func maintenanceSession() async -> MemoryMaintenanceSession? {
        guard let token = authorization, token.isValid, settings.memoryEnabled,
              let provider = try? await providerSettings(),
              ContextProviderIdentity.fingerprint(provider) == token.providerFingerprint,
              let privacy = try? privacySettings.currentSettings() else { return nil }
        return MemoryMaintenanceSession(
            authorization: token, workflowIDs: settings.authorizedWorkflowIDs,
            excludedApplications: Set(privacy.sensitiveAppRules.filter(\.enabled).map(\.normalizedBundleIdentifier)),
            consolidator: ContextCorrectionProvider(settingsProvider: providerSettings, authorization: token, operations: referenceRequests)
        )
    }

    private func scheduleNextIdle() {
        nextIdleTask?.cancel()
        nextIdleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.isShuttingDown else { return }
                if await self.eligibleForMaintenance() {
                    await self.maintenance.runIfEligible()
                    await self.model?.contextMemory?.refresh()
                    return
                }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }

    func shutdown() async {
        isShuttingDown = true
        revoke()
        scheduler?.stop()
        scheduler = nil
        nextIdleTask?.cancel()
        await maintenance.shutdown()
        await model?.contextMemory?.shutdown()
        await preparationOperations.shutdown()
        await referenceRequests.shutdown()
        await nextIdleTask?.value
        try? await repository.setContextAuthorization(nil)
    }
}
