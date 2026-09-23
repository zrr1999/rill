import Foundation
import Testing
@testable import RillCore
@testable import RillUI

@MainActor
struct ContextMemoryModelTests {
    @Test func failedSaveRetainsAnActionableResult() async {
        let repository = ContextUIRepository(failsWrites: true)
        let model = ContextMemoryModel(repository: repository, settingsStore: UITestSettingsStore(storage: [:]),
            activate: { _ in true }, revoke: {}, fingerprint: { "fixture" }, screenPermission: { _ in false }, maintain: {})
        let memory = LongTermMemory(scope: .init(workflowID: UUID(), applicationBundleID: nil, language: nil),
            summary: "Retained draft", evidenceKind: .userStatement, sources: [.init(sourceID: UUID(), revision: 1)])
        #expect(await model.save(memory) == .failed(.mutation))
        #expect(model.error == .mutation)
        await model.shutdown()
    }

    @Test(arguments: [false, true])
    func shutdownFlushesAcceptedEditsAndRejectsNewOnes(deleting: Bool) async throws {
        let repository = ContextUIRepository()
        var settings = ContextFeatureSettings()
        settings.memoryEnabled = true
        settings.providerFingerprint = "fixture"
        let store = UITestSettingsStore(storage: [.contextFeatureSettings: String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)])
        let model = ContextMemoryModel(repository: repository, settingsStore: store, activate: { _ in true },
            revoke: {}, fingerprint: { "fixture" }, screenPermission: { _ in false }, maintain: {})
        model.load()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.isLoading && ContinuousClock.now < deadline { await Task.yield() }
        let memory = LongTermMemory(scope: .init(workflowID: UUID(), applicationBundleID: nil, language: nil),
            summary: "Rill", evidenceKind: .userStatement, sources: [.init(sourceID: UUID(), revision: 1)])
        let operation = Task {
            if deleting { await model.delete(memory) } else { await model.save(memory) }
        }
        while await !repository.entered && ContinuousClock.now < deadline { await Task.yield() }
        #expect(await repository.entered)
        var shutdownStarted = false
        var shutdownCompleted = false
        let shutdown = Task { shutdownStarted = true; await model.shutdown(); shutdownCompleted = true }
        while !shutdownStarted { await Task.yield() }
        #expect(!shutdownCompleted)
        await repository.release()
        #expect(await operation.value == .saved)
        await shutdown.value
        #expect(shutdownCompleted)
        #expect(await model.save(memory) == .stopped)
        #expect(await model.delete(memory) == .stopped)
        model.invalidateAuthorization()
        model.recordCorrection(.init(original: "Ril", corrected: "Rill"), recordID: UUID())
        model.scheduleMaintenance()
        #expect(await repository.writeCount == 1)
        let stored = try #require(try await store.string(forKey: .contextFeatureSettings))
        #expect(try JSONDecoder().decode(ContextFeatureSettings.self, from: Data(stored.utf8)).providerFingerprint == "fixture")
    }

    @Test(arguments: [false, true])
    func revokedConfigurationCannotBeReauthorizedByAnOlderEdit(deleting: Bool) async throws {
        let repository = ContextUIRepository()
        var settings = ContextFeatureSettings()
        settings.memoryEnabled = true
        settings.providerFingerprint = "fixture"
        let store = UITestSettingsStore(storage: [.contextFeatureSettings: String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)])
        var activations = 0
        let model = ContextMemoryModel(repository: repository, settingsStore: store, activate: { value in
            activations += 1
            return value.providerFingerprint != nil
        }, revoke: {}, fingerprint: { "fixture" }, screenPermission: { _ in false }, maintain: {})
        model.load()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.isLoading && ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.isAuthorized)
        let memory = LongTermMemory(scope: .init(workflowID: UUID(), applicationBundleID: nil, language: nil),
            summary: "Rill", evidenceKind: .userStatement, sources: [.init(sourceID: UUID(), revision: 1)])
        let operation = Task {
            if deleting { await model.delete(memory) } else { await model.save(memory) }
        }
        while await !repository.entered && ContinuousClock.now < deadline { await Task.yield() }
        #expect(await repository.entered)
        model.invalidateAuthorization()
        await repository.release()
        #expect(await operation.value == .saved)
        #expect(!model.isAuthorized)
        #expect(activations == 1)
        await model.shutdown()
        let stored = try #require(try await store.string(forKey: .contextFeatureSettings))
        #expect(try JSONDecoder().decode(ContextFeatureSettings.self, from: Data(stored.utf8)).providerFingerprint == nil)
    }
}

private actor ContextUIRepository: ContextMemoryRepository {
    private(set) var entered = false
    private(set) var writeCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private let failsWrites: Bool
    init(failsWrites: Bool = false) { self.failsWrites = failsWrites }
    private func pause() async {
        entered = true
        writeCount += 1
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
    func setContextAuthorization(_ id: UUID?) async throws {}
    func recordForegroundContextRequest(authorization: ContextReferenceAuthorization, now: Date) async throws {}
    func memories() async throws -> [LongTermMemory] { [] }
    func saveMemory(_ memory: LongTermMemory, expectedRevision: Int64) async throws {
        if failsWrites { throw ContextCorrectionError.authorizationChanged }
        await pause()
    }
    func deleteMemory(id: UUID, expectedRevision: Int64) async throws {
        if failsWrites { throw ContextCorrectionError.authorizationChanged }
        await pause()
    }
    func relevantMemories(scope: ContextMemoryScope, now: Date) async throws -> [LongTermMemory] { [] }
    func prepareMemoryBatch(authorizationID: UUID, allowedWorkflowIDs: Set<UUID>, excludedApplications: Set<String>, now: Date) async throws -> MemoryConsolidationBatch? { nil }
    func commitMemoryBatch(_ batch: MemoryConsolidationBatch, result: MemoryConsolidationResult) async throws {}
    func memoryMaintenanceStatus(now: Date) async throws -> MemoryMaintenanceStatus { .init() }
    func appendScreenSummary(_ summary: ScreenReferenceSummary, runID: UUID, generation: RunHistoryWriteGeneration, authorization: ContextReferenceAuthorization) async throws {}
    func recordUserCorrection(_ correction: ConfirmedMemoryCorrection, recordID: UUID) async throws {}
}
