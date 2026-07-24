import Foundation
import RillCore

extension DeliveryStack {
    public func pruneHistory(olderThan cutoff: Date) async throws -> ClipboardCleanupResult {
        try await cleanHistory { $0.createdAt < cutoff }
    }

    public func clearHistory() async throws -> ClipboardCleanupResult {
        try await cleanHistory { _ in true }
    }

    public func clearHistory(through upperBound: Date) async throws -> ClipboardCleanupResult {
        try await cleanHistory { $0.createdAt <= upperBound }
    }

    private func cleanHistory(
        where isEligible: (ClipboardHistoryItem) -> Bool
    ) async throws -> ClipboardCleanupResult {
        await ensureInitialized()
        guard persistenceAvailability != .loadUnavailable else {
            throw ClipboardHistoryMaintenanceError.persistenceUnavailable
        }
        await beginHistoryMaintenance()

        let eligibleIDs = Set(historyIDs.compactMap { itemID -> UUID? in
            guard let item = itemsByID[itemID], isEligible(item) else { return nil }
            return itemID
        })
        let initiallyActiveIDs = activeItemIDs()
        let targetIDs = eligibleIDs.subtracting(initiallyActiveIDs)
        let preservedActiveCount = eligibleIDs.intersection(initiallyActiveIDs).count

        guard !targetIDs.isEmpty else {
            endHistoryMaintenance()
            return ClipboardCleanupResult(
                removedCount: 0,
                preservedActiveCount: preservedActiveCount
            )
        }

        do {
            while true {
                let deletionIDs = targetIDs
                    .intersection(itemsByID.keys)
                    .subtracting(activeItemIDs())
                guard !deletionIDs.isEmpty else {
                    endHistoryMaintenance()
                    return ClipboardCleanupResult(
                        removedCount: 0,
                        preservedActiveCount: preservedActiveCount
                    )
                }

                let revision = stateRevision
                if let clipboardPersistenceStore {
                    let preparedWrite = try preparedPersistenceWrite(
                        excluding: deletionIDs
                    )
                    let committedRevision = try await clipboardPersistenceStore
                        .replaceClipboardPersistence(with: preparedWrite.snapshot)
                    // The repository advanced even if an unexpected actor
                    // revision resumed while the transaction was in flight.
                    repositoryRevision = committedRevision
                    persistedBlobIDs = preparedWrite.persistedBlobIDs
                    persistenceAvailability = confirmedPersistenceAvailability
                    guard revision == stateRevision else { continue }
                }

                removeHistoryOnlyItems(ids: deletionIDs)
                stateRevision &+= 1
                hasPendingPersistence = false
                await publishSnapshot()
                endHistoryMaintenance(schedulesPersistence: false)
                return ClipboardCleanupResult(
                    removedCount: deletionIDs.count,
                    preservedActiveCount: preservedActiveCount
                )
            }
        } catch {
            persistenceAvailability = .saveFailed
            hasPendingPersistence = true
            await publishSnapshot()
            endHistoryMaintenance()
            throw error
        }
    }

    private func beginHistoryMaintenance() async {
        while isHistoryMaintenanceActive || isPersistenceResetActive {
            await withCheckedContinuation { continuation in
                historyMaintenanceWaiters.append(continuation)
            }
        }
        isHistoryMaintenanceActive = true

        pendingPersistenceGeneration &+= 1
        let existingTask = pendingPersistenceTask
        pendingPersistenceTask = nil
        existingTask?.cancel()
        if let existingTask {
            await existingTask.value
        }
    }

    private func endHistoryMaintenance(schedulesPersistence: Bool = true) {
        isHistoryMaintenanceActive = false
        if schedulesPersistence {
            schedulePersistence()
        }

        let waiters = historyMaintenanceWaiters
        historyMaintenanceWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForHistoryMaintenanceIfNeeded() async {
        while isHistoryMaintenanceActive || isPersistenceResetActive {
            await withCheckedContinuation { continuation in
                historyMaintenanceWaiters.append(continuation)
            }
        }
    }
}
