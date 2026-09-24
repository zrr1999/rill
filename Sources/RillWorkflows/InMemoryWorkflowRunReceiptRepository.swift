import Foundation
import RillCore

public actor InMemoryWorkflowRunReceiptRepository: WorkflowRunReceiptRepository {
    private struct StoredReceipt: Sendable {
        var receipt: WorkflowRunReceipt
        var generation: RunHistoryWriteGeneration
    }

    private var storageByRunID: [UUID: StoredReceipt] = [:]
    private var currentGeneration: RunHistoryWriteGeneration = .initial
    private var lastClearIntentID: UUID?

    public init() {}

    public init(receipts: [WorkflowRunReceipt]) throws {
        for receipt in receipts {
            if let existing = storageByRunID[receipt.runID], existing.receipt != receipt {
                throw WorkflowRunReceiptRepositoryError.conflictingTerminalReceipt(
                    runID: receipt.runID
                )
            }
            storageByRunID[receipt.runID] = StoredReceipt(
                receipt: receipt,
                generation: .initial
            )
        }
    }

    public func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration {
        currentGeneration
    }

    public func insertTerminal(_ receipt: WorkflowRunReceipt) async throws {
        try await insertTerminal(receipt, generation: currentGeneration)
    }

    public func insertTerminal(
        _ receipt: WorkflowRunReceipt,
        generation: RunHistoryWriteGeneration
    ) async throws {
        guard generation == currentGeneration else {
            throw WorkflowRunReceiptRepositoryError.writeObsoletedByClearBarrier(
                runID: receipt.runID
            )
        }
        if let existing = storageByRunID[receipt.runID] {
            guard existing.receipt == receipt else {
                throw WorkflowRunReceiptRepositoryError.conflictingTerminalReceipt(
                    runID: receipt.runID
                )
            }
            return
        }
        storageByRunID[receipt.runID] = StoredReceipt(
            receipt: receipt,
            generation: generation
        )
    }

    public func receipts(
        matching query: WorkflowRunReceiptQuery
    ) async throws -> [WorkflowRunReceipt] {
        var receipts = storageByRunID.values.map(\.receipt)

        if let runID = query.runID {
            receipts = receipts.filter { $0.runID == runID }
        }
        if let runIDs = query.runIDs {
            receipts = receipts.filter { runIDs.contains($0.runID) }
        }
        if let workflowID = query.workflowID {
            receipts = receipts.filter { $0.workflowID == workflowID }
        }
        if let trigger = query.trigger {
            receipts = receipts.filter { $0.trigger == trigger }
        }
        if let outcome = query.outcome {
            receipts = receipts.filter { $0.outcome == outcome }
        }
        if let since = query.since {
            receipts = receipts.filter { $0.timestamp >= since }
        }

        receipts.sort {
            if $0.timestamp == $1.timestamp {
                return $0.runID.uuidString < $1.runID.uuidString
            }
            return $0.timestamp > $1.timestamp
        }

        if let limit = query.limit, limit >= 0 {
            receipts = Array(receipts.prefix(limit))
        }
        return receipts
    }

    public func deleteReceipts(olderThan cutoff: Date) async throws -> Int {
        let originalCount = storageByRunID.count
        storageByRunID = storageByRunID.filter { $0.value.receipt.timestamp >= cutoff }
        return originalCount - storageByRunID.count
    }

    public func deleteReceipts(through upperBound: Date) async throws -> Int {
        let originalCount = storageByRunID.count
        storageByRunID = storageByRunID.filter {
            $0.value.receipt.timestamp > upperBound
        }
        return originalCount - storageByRunID.count
    }

    public func deleteReceipts(
        obsoletedBy transition: RunHistoryClearTransition,
        preservingLegacyRowsAfter legacyUpperBound: Date?
    ) async throws -> Int {
        try validateAndAdvance(transition)
        if let legacyUpperBound {
            for runID in Array(storageByRunID.keys) {
                guard var stored = storageByRunID[runID],
                      stored.generation < transition.nextGeneration,
                      stored.receipt.timestamp > legacyUpperBound else { continue }
                stored.generation = transition.nextGeneration
                storageByRunID[runID] = stored
            }
        }
        let originalCount = storageByRunID.count
        storageByRunID = storageByRunID.filter {
            $0.value.generation >= transition.nextGeneration
        }
        return originalCount - storageByRunID.count
    }

    public func deleteAllReceipts() async throws -> Int {
        let removedCount = storageByRunID.count
        storageByRunID.removeAll(keepingCapacity: false)
        return removedCount
    }

    private func validateAndAdvance(_ transition: RunHistoryClearTransition) throws {
        if currentGeneration == transition.nextGeneration,
           lastClearIntentID == transition.intentID {
            return
        }
        guard currentGeneration == transition.previousGeneration else {
            throw RunHistoryGenerationError.clearTransitionConflict
        }
        currentGeneration = transition.nextGeneration
        lastClearIntentID = transition.intentID
    }
}
