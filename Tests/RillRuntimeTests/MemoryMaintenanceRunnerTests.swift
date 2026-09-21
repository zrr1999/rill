import Foundation
import Testing
@testable import RillCore
@testable import RillRuntime

struct MemoryMaintenanceRunnerTests {
    @Test func interruptedRequestDoesNotConsumeAnotherBudgetWhileItsSlotIsOccupied() async throws {
        let repository = MaintenanceRepositoryProbe()
        let provider = MaintenanceProviderProbe()
        let token = ContextReferenceAuthorization(providerFingerprint: "fixture")
        let runner = MemoryMaintenanceRunner(repository: repository, eligible: { true }, session: {
            MemoryMaintenanceSession(authorization: token, workflowIDs: [], consolidator: provider)
        })
        let first = Task { await runner.runIfEligible() }
        await provider.waitUntilEntered()
        await runner.interrupt()
        await first.value
        await runner.runIfEligible()
        #expect(await repository.preparations == 1)
        #expect(await repository.commits == 0)
        await provider.release()
        await runner.shutdown()
        #expect(await repository.commits == 0)
    }

    @Test func activityPreemptsUncooperativeBackgroundRequestAndDiscardsItsLateResult() async throws {
        let repository = MaintenanceRepositoryProbe()
        let activity = MaintenanceActivityProbe()
        let provider = MaintenanceProviderProbe()
        let token = ContextReferenceAuthorization(providerFingerprint: "fixture")
        let runner = MemoryMaintenanceRunner(repository: repository, eligible: { await activity.idle }, session: {
            MemoryMaintenanceSession(authorization: token, workflowIDs: [], consolidator: provider)
        })
        await runner.runIfEligible()
        #expect(await repository.preparations == 0)
        await activity.setIdle(true)
        let running = Task { await runner.runIfEligible() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await !provider.entered && ContinuousClock.now < deadline { await Task.yield() }
        #expect(await provider.entered)
        let start = ContinuousClock.now
        await activity.setIdle(false)
        await running.value
        #expect(start.duration(to: .now) < .seconds(1))
        await provider.release()
        #expect(await repository.commits == 0)
        #expect(await repository.preparations == 1)
        await runner.shutdown()
    }
}

private actor MaintenanceActivityProbe {
    var idle = false
    func setIdle(_ value: Bool) { idle = value }
}
private actor MaintenanceProviderProbe: MemoryConsolidating {
    private(set) var entered = false
    private var continuation: CheckedContinuation<MemoryConsolidationResult, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func consolidate(_ batch: MemoryConsolidationBatch) async throws -> MemoryConsolidationResult {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: .init(memories: [])); continuation = nil }
}
private actor MaintenanceRepositoryProbe: ContextMemoryRepository {
    private(set) var preparations = 0
    private(set) var commits = 0
    func setContextAuthorization(_ id: UUID?) async throws {}
    func recordForegroundContextRequest(authorization: ContextReferenceAuthorization, now: Date) async throws {}
    func memories() async throws -> [LongTermMemory] { [] }
    func saveMemory(_ memory: LongTermMemory, expectedRevision: Int64) async throws {}
    func deleteMemory(id: UUID, expectedRevision: Int64) async throws {}
    func relevantMemories(scope: ContextMemoryScope, now: Date) async throws -> [LongTermMemory] { [] }
    func prepareMemoryBatch(authorizationID: UUID, allowedWorkflowIDs: Set<UUID>, excludedApplications: Set<String>, now: Date) async throws -> MemoryConsolidationBatch? {
        preparations += 1
        return .init(historyGeneration: .initial, authorizationID: authorizationID, memoryRevision: 0, sources: [], relatedMemories: [])
    }
    func commitMemoryBatch(_ batch: MemoryConsolidationBatch, result: MemoryConsolidationResult) async throws { commits += 1 }
    func memoryMaintenanceStatus(now: Date) async throws -> MemoryMaintenanceStatus { .init() }
    func appendScreenSummary(_ summary: ScreenReferenceSummary, runID: UUID, generation: RunHistoryWriteGeneration, authorization: ContextReferenceAuthorization) async throws {}
    func recordUserCorrection(_ correction: ConfirmedMemoryCorrection, recordID: UUID) async throws {}
}
