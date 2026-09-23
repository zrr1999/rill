import Foundation
import RillCore

public struct MemoryMaintenanceSession: Sendable {
    public let authorization: ContextReferenceAuthorization
    public let workflowIDs: Set<UUID>
    public let excludedApplications: Set<String>
    public let consolidator: any MemoryConsolidating

    public init(authorization: ContextReferenceAuthorization, workflowIDs: Set<UUID>, excludedApplications: Set<String> = [], consolidator: any MemoryConsolidating) {
        self.authorization = authorization
        self.workflowIDs = workflowIDs
        self.excludedApplications = excludedApplications
        self.consolidator = consolidator
    }
}

public actor MemoryMaintenanceRunner {
    private let operations = BoundedOperation()
    private let repository: any ContextMemoryRepository
    private let eligible: @Sendable () async -> Bool
    private let session: @Sendable () async -> MemoryMaintenanceSession?
    private var work: Task<Void, Never>?
    private var operationID: UUID?
    private var stopped = false

    public init(repository: any ContextMemoryRepository, eligible: @escaping @Sendable () async -> Bool,
                session: @escaping @Sendable () async -> MemoryMaintenanceSession?) {
        self.repository = repository
        self.eligible = eligible
        self.session = session
    }

    public func runIfEligible() async {
        guard !stopped, work == nil, await eligible(), let session = await session(),
              session.authorization.isValid, !stopped, work == nil else { return }
        let id = UUID()
        operationID = id
        let task = Task { [repository, eligible] in
            let monitor = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    let remainsEligible = await eligible()
                    if !session.authorization.isValid || !remainsEligible {
                        self.interrupt()
                        return
                    }
                }
            }
            defer { monitor.cancel() }
            do {
                let prepared = try await operations.run(timeout: .seconds(30)) {
                    guard session.authorization.isValid, await eligible() else { return nil as (MemoryConsolidationBatch, MemoryConsolidationResult)? }
                    guard var batch = try await repository.prepareMemoryBatch(
                        authorizationID: session.authorization.id, allowedWorkflowIDs: session.workflowIDs,
                        excludedApplications: session.excludedApplications, now: Date()
                    ) else { return nil }
                    batch.authorization = session.authorization
                    try Task.checkCancellation()
                    guard session.authorization.isValid, await eligible() else { return nil }
                    let result = try await session.consolidator.consolidate(batch)
                    return (batch, result)
                }
                guard let (batch, result) = prepared else { return }
                try Task.checkCancellation()
                guard session.authorization.isValid, await eligible() else { return }
                try await repository.commitMemoryBatch(batch, result: result)
            } catch {
                // Failed requests retain their budget reservation and leave the source cursor unchanged.
            }
        }
        work = task
        await task.value
        if operationID == id { work = nil; operationID = nil }
    }

    public func interrupt() { work?.cancel() }

    public func shutdown() async {
        stopped = true
        work?.cancel()
        await work?.value
        await operations.shutdown()
    }
}
