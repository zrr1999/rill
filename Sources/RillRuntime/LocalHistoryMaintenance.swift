import Foundation
import RillCore

public protocol RecordHistoryMaintaining: Sendable {
    func pruneHistory(olderThan cutoff: Date) async throws -> RecordCleanupResult
    func clearHistory(through upperBound: Date) async throws -> RecordCleanupResult
}

extension RecordStore: RecordHistoryMaintaining {}

public struct LocalHistoryMaintenanceCounts: Sendable, Equatable {
    public var recordRemovedCount: Int
    public var runRemovedCount: Int
    public var runReceiptRemovedCount: Int
    public var diagnosticRemovedCount: Int
    public var preservedActiveRecordCount: Int

    public init(
        recordRemovedCount: Int = 0,
        runRemovedCount: Int = 0,
        runReceiptRemovedCount: Int = 0,
        diagnosticRemovedCount: Int = 0,
        preservedActiveRecordCount: Int = 0
    ) {
        self.recordRemovedCount = recordRemovedCount
        self.runRemovedCount = runRemovedCount
        self.runReceiptRemovedCount = runReceiptRemovedCount
        self.diagnosticRemovedCount = diagnosticRemovedCount
        self.preservedActiveRecordCount = preservedActiveRecordCount
    }

    public var totalRemovedCount: Int {
        recordRemovedCount + runRemovedCount + runReceiptRemovedCount + diagnosticRemovedCount
    }
}

public enum LocalHistoryMaintenancePendingReason: String, Sendable, Equatable {
    case logicalDeletionFailed = "logical-deletion-failed"
    case stateWriteFailed = "state-write-failed"
    case physicalPurgeFailed = "physical-purge-failed"
    case stateRemovalFailed = "state-removal-failed"
}

public enum LocalHistoryMaintenanceBlockReason: String, Sendable, Equatable {
    case stateReadFailed = "state-read-failed"
    case invalidPendingState = "invalid-pending-state"
    case stateWriteFailed = "state-write-failed"
}

public enum LocalHistoryMaintenanceResult: Sendable, Equatable {
    case completed(LocalHistoryMaintenanceCounts)
    case pending(LocalHistoryMaintenanceCounts, LocalHistoryMaintenancePendingReason)
    case blocked(LocalHistoryMaintenanceBlockReason)
}

public enum LocalHistoryMaintenanceEventOutcome: String, Sendable, Equatable {
    case completed
    case pending
    case blocked
}

/// A content-free maintenance event. It exposes only outcome, counts, and reason codes.
public struct LocalHistoryMaintenanceEvent: Sendable, Equatable {
    public let outcome: LocalHistoryMaintenanceEventOutcome
    public let counts: LocalHistoryMaintenanceCounts
    public let pendingReason: LocalHistoryMaintenancePendingReason?
    public let blockReason: LocalHistoryMaintenanceBlockReason?

    public init(
        outcome: LocalHistoryMaintenanceEventOutcome,
        counts: LocalHistoryMaintenanceCounts,
        pendingReason: LocalHistoryMaintenancePendingReason? = nil,
        blockReason: LocalHistoryMaintenanceBlockReason? = nil
    ) {
        self.outcome = outcome
        self.counts = counts
        self.pendingReason = pendingReason
        self.blockReason = blockReason
    }
}

public protocol LocalHistoryMaintaining: Sendable {
    func performRetention(
        recordRetention: HistoryRetentionPeriod,
        runRetention: HistoryRetentionPeriod,
        now: Date
    ) async -> LocalHistoryMaintenanceResult

    func clearRecordHistory() async -> LocalHistoryMaintenanceResult
    func clearRunHistory() async -> LocalHistoryMaintenanceResult
    func retryPendingMaintenance() async -> LocalHistoryMaintenanceResult
}

public extension LocalHistoryMaintaining {
    func performRetention(
        recordRetention: HistoryRetentionPeriod,
        runRetention: HistoryRetentionPeriod
    ) async -> LocalHistoryMaintenanceResult {
        await performRetention(
            recordRetention: recordRetention,
            runRetention: runRetention,
            now: Date()
        )
    }
}

public actor LocalHistoryMaintenance: LocalHistoryMaintaining {
    public typealias EventReporter = @Sendable (LocalHistoryMaintenanceEvent) async -> Void
    public typealias WallClock = @Sendable () -> Date

    private enum PendingLoadResult {
        case none
        case state(LocalHistoryMaintenanceState)
        case blocked(LocalHistoryMaintenanceBlockReason)
    }

    private let recordHistory: any RecordHistoryMaintaining
    private let runHistory: any HistoryMaintaining
    private let runReceipts: any WorkflowRunReceiptMaintaining
    private let diagnosticHistory: any DiagnosticHistoryMaintaining
    private let settingsStore: any SettingsStore
    private let physicalPurger: any StorageResiduePurging
    private let eventReporter: EventReporter
    private let wallClock: WallClock

    private var operationIsActive = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        recordHistory: any RecordHistoryMaintaining,
        runHistory: any HistoryMaintaining,
        runReceipts: any WorkflowRunReceiptMaintaining = InMemoryWorkflowRunReceiptRepository(),
        diagnosticHistory: any DiagnosticHistoryMaintaining,
        settingsStore: any SettingsStore,
        physicalPurger: any StorageResiduePurging,
        eventReporter: @escaping EventReporter = { _ in },
        wallClock: @escaping WallClock = { Date() }
    ) {
        self.recordHistory = recordHistory
        self.runHistory = runHistory
        self.runReceipts = runReceipts
        self.diagnosticHistory = diagnosticHistory
        self.settingsStore = settingsStore
        self.physicalPurger = physicalPurger
        self.eventReporter = eventReporter
        self.wallClock = wallClock
    }

    public func performRetention(
        recordRetention: HistoryRetentionPeriod,
        runRetention: HistoryRetentionPeriod,
        now: Date
    ) async -> LocalHistoryMaintenanceResult {
        await acquireOperationAccess()
        let state = LocalHistoryMaintenanceState(
            clipboardOperation: recordRetention.cutoffDate(relativeTo: now).map {
                .prune(olderThan: $0)
            },
            runOperation: runRetention.cutoffDate(relativeTo: now).map {
                .prune(olderThan: $0)
            }
        )
        let result = await performNewMaintenance(state)
        await report(result)
        releaseOperationAccess()
        return result
    }

    public func clearRecordHistory() async -> LocalHistoryMaintenanceResult {
        await acquireOperationAccess()
        let upperBound = wallClock()
        let result = await performNewMaintenance(
            LocalHistoryMaintenanceState(
                clipboardOperation: .clearAll,
                clearThrough: upperBound
            )
        )
        await report(result)
        releaseOperationAccess()
        return result
    }

    public func clearRunHistory() async -> LocalHistoryMaintenanceResult {
        await acquireOperationAccess()
        let result = await performNewRunClearMaintenance()
        await report(result)
        releaseOperationAccess()
        return result
    }

    public func retryPendingMaintenance() async -> LocalHistoryMaintenanceResult {
        await acquireOperationAccess()
        let result: LocalHistoryMaintenanceResult
        switch await loadPendingState() {
        case .none:
            result = .completed(LocalHistoryMaintenanceCounts())
        case .state(let state):
            result = await execute(state, isRecoveredIntent: true)
        case .blocked(let reason):
            result = .blocked(reason)
        }
        await report(result)
        releaseOperationAccess()
        return result
    }

    private func performNewMaintenance(
        _ state: LocalHistoryMaintenanceState
    ) async -> LocalHistoryMaintenanceResult {
        switch await loadPendingState() {
        case .none:
            break
        case .state(let pendingState):
            let pendingResult = await execute(pendingState, isRecoveredIntent: true)
            guard case .completed = pendingResult else { return pendingResult }
        case .blocked(let reason):
            return .blocked(reason)
        }

        guard state.hasPendingOperations else {
            return .completed(LocalHistoryMaintenanceCounts())
        }

        do {
            try await persist(state)
        } catch {
            return .blocked(.stateWriteFailed)
        }
        return await execute(state, isRecoveredIntent: false)
    }

    /// A new clear transition must be captured only after an older persisted
    /// intent has completed; otherwise recovery can make the prebuilt CAS stale.
    private func performNewRunClearMaintenance() async -> LocalHistoryMaintenanceResult {
        switch await loadPendingState() {
        case .none:
            break
        case .state(let pendingState):
            let pendingResult = await execute(pendingState, isRecoveredIntent: true)
            guard case .completed = pendingResult else { return pendingResult }
        case .blocked(let reason):
            return .blocked(reason)
        }

        let transition: RunHistoryClearTransition
        do {
            let generation = try await runHistory.captureRunHistoryWriteGeneration()
            transition = try RunHistoryClearTransition(advancing: generation)
        } catch {
            return .blocked(.stateReadFailed)
        }
        let state = LocalHistoryMaintenanceState(
            runOperation: .clearAll,
            runClearTransition: transition
        )
        do {
            try await persist(state)
        } catch {
            return .blocked(.stateWriteFailed)
        }
        return await execute(state, isRecoveredIntent: false)
    }

    private func execute(
        _ initialState: LocalHistoryMaintenanceState,
        isRecoveredIntent: Bool
    ) async -> LocalHistoryMaintenanceResult {
        var state = initialState
        var counts = LocalHistoryMaintenanceCounts()

        if state.schemaVersion == 4,
           state.phase == .logicalPending,
           case .clearAll? = state.runOperation {
            do {
                let generation = try await runHistory.captureRunHistoryWriteGeneration()
                state.schemaVersion = LocalHistoryMaintenanceState.currentSchemaVersion
                state.runClearTransition = try RunHistoryClearTransition(advancing: generation)
                state.legacyRunClearThrough = state.clearThrough
                if case .clearAll? = state.clipboardOperation {
                    // The shared schema-4 timestamp remains the clipboard boundary.
                } else {
                    state.clearThrough = nil
                }
                try await persist(state)
            } catch {
                return .pending(counts, .stateWriteFailed)
            }
        }

        switch state.phase {
        case .logicalPending:
            var logicalDeletionFailed = false

            if let operation = state.clipboardOperation {
                do {
                    let result = try await executeClipboard(
                        operation,
                        clearThrough: state.clearThrough
                    )
                    counts.recordRemovedCount = result.removedCount
                    counts.preservedActiveRecordCount = result.preservedActiveCount
                } catch {
                    logicalDeletionFailed = true
                }
            }

            if let operation = state.runOperation {
                do {
                    counts.runRemovedCount = try await executeRunHistory(
                        operation,
                        transition: state.runClearTransition,
                        legacyClearThrough: state.legacyRunClearThrough
                    )
                } catch {
                    logicalDeletionFailed = true
                }
                if state.schemaVersion >= 2 {
                    do {
                        counts.diagnosticRemovedCount = try await executeDiagnosticHistory(
                            operation,
                            transition: state.runClearTransition,
                            legacyClearThrough: state.legacyRunClearThrough
                        )
                    } catch {
                        logicalDeletionFailed = true
                    }
                }
                if state.schemaVersion >= 3 {
                    do {
                        counts.runReceiptRemovedCount = try await executeRunReceipts(
                            operation,
                            transition: state.runClearTransition,
                            legacyClearThrough: state.legacyRunClearThrough
                        )
                    } catch {
                        logicalDeletionFailed = true
                    }
                }
            }

            if logicalDeletionFailed {
                return .pending(counts, .logicalDeletionFailed)
            }

            state.phase = .residuePending
            do {
                try await persist(state)
            } catch {
                return .pending(counts, .stateWriteFailed)
            }

            if counts.totalRemovedCount == 0, !isRecoveredIntent {
                do {
                    try await removePendingState()
                    return .completed(counts)
                } catch {
                    return .pending(counts, .stateRemovalFailed)
                }
            }

        case .residuePending:
            break
        }

        do {
            try await physicalPurger.purgeSensitiveStorageResidue()
        } catch {
            return .pending(counts, .physicalPurgeFailed)
        }

        do {
            try await removePendingState()
            return .completed(counts)
        } catch {
            return .pending(counts, .stateRemovalFailed)
        }
    }

    private func executeClipboard(
        _ operation: LocalHistoryMaintenanceOperation,
        clearThrough: Date?
    ) async throws -> RecordCleanupResult {
        switch operation {
        case .prune(let cutoff):
            return try await recordHistory.pruneHistory(olderThan: cutoff)
        case .clearAll:
            guard let clearThrough else {
                throw MaintenanceExecutionError.missingClearBoundary
            }
            return try await recordHistory.clearHistory(through: clearThrough)
        }
    }

    private func executeRunHistory(
        _ operation: LocalHistoryMaintenanceOperation,
        transition: RunHistoryClearTransition?,
        legacyClearThrough: Date?
    ) async throws -> Int {
        switch operation {
        case .prune(let cutoff):
            return try await runHistory.deleteRecords(olderThan: cutoff)
        case .clearAll:
            guard let transition else {
                throw MaintenanceExecutionError.missingClearBoundary
            }
            return try await runHistory.deleteRecords(
                obsoletedBy: transition,
                preservingLegacyRowsAfter: legacyClearThrough
            )
        }
    }

    private func executeDiagnosticHistory(
        _ operation: LocalHistoryMaintenanceOperation,
        transition: RunHistoryClearTransition?,
        legacyClearThrough: Date?
    ) async throws -> Int {
        switch operation {
        case .prune(let cutoff):
            return try await diagnosticHistory.deleteEvents(olderThan: cutoff)
        case .clearAll:
            guard let transition else {
                throw MaintenanceExecutionError.missingClearBoundary
            }
            return try await diagnosticHistory.deleteEvents(
                obsoletedBy: transition,
                preservingLegacyRowsAfter: legacyClearThrough
            )
        }
    }

    private func executeRunReceipts(
        _ operation: LocalHistoryMaintenanceOperation,
        transition: RunHistoryClearTransition?,
        legacyClearThrough: Date?
    ) async throws -> Int {
        switch operation {
        case .prune(let cutoff):
            return try await runReceipts.deleteReceipts(olderThan: cutoff)
        case .clearAll:
            guard let transition else {
                throw MaintenanceExecutionError.missingClearBoundary
            }
            return try await runReceipts.deleteReceipts(
                obsoletedBy: transition,
                preservingLegacyRowsAfter: legacyClearThrough
            )
        }
    }

    private func loadPendingState() async -> PendingLoadResult {
        let storedValue: String?
        do {
            storedValue = try await settingsStore.string(forKey: .localHistoryMaintenanceState)
        } catch {
            return .blocked(.stateReadFailed)
        }
        guard let storedValue else { return .none }

        do {
            let data = Data(storedValue.utf8)
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dictionary = object as? [String: Any] else {
                return .blocked(.invalidPendingState)
            }
            let allowedKeys: Set<String> = [
                "schemaVersion",
                "clipboardOperation",
                "runOperation",
                "clearThrough",
                "runClearTransition",
                "legacyRunClearThrough",
                "phase",
            ]
            guard
                Set(dictionary.keys).isSubset(of: allowedKeys),
                dictionary["schemaVersion"] != nil,
                dictionary["phase"] != nil,
                optionalDateIsStrict(dictionary["clearThrough"]),
                optionalDateIsStrict(dictionary["legacyRunClearThrough"]),
                transitionIsStrict(dictionary["runClearTransition"]),
                operationIsStrict(dictionary["clipboardOperation"]),
                operationIsStrict(dictionary["runOperation"])
            else {
                return .blocked(.invalidPendingState)
            }

            let state = try JSONDecoder().decode(LocalHistoryMaintenanceState.self, from: data)
            guard
                (1...LocalHistoryMaintenanceState.currentSchemaVersion).contains(state.schemaVersion),
                state.hasPendingOperations,
                stateHasSafeClearBoundary(state)
            else {
                return .blocked(.invalidPendingState)
            }
            return .state(state)
        } catch {
            return .blocked(.invalidPendingState)
        }
    }

    private func persist(_ state: LocalHistoryMaintenanceState) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(state)
        try await settingsStore.setString(
            String(decoding: encoded, as: UTF8.self),
            forKey: .localHistoryMaintenanceState
        )
    }

    private func operationIsStrict(_ value: Any?) -> Bool {
        guard let value else { return true }
        guard let operation = value as? [String: Any], let kind = operation["kind"] as? String else {
            return false
        }
        switch kind {
        case "prune":
            return Set(operation.keys) == ["kind", "olderThan"]
                && operation["olderThan"] is NSNumber
        case "clear-all":
            return Set(operation.keys) == ["kind"]
        default:
            return false
        }
    }

    private func optionalDateIsStrict(_ value: Any?) -> Bool {
        value == nil || value is NSNumber
    }

    private func transitionIsStrict(_ value: Any?) -> Bool {
        guard let value else { return true }
        guard let transition = value as? [String: Any],
              Set(transition.keys) == [
                "intentID",
                "previousGeneration",
                "nextGeneration",
              ],
              let intentID = transition["intentID"] as? String,
              UUID(uuidString: intentID) != nil,
              transition["previousGeneration"] is NSNumber,
              transition["nextGeneration"] is NSNumber else {
            return false
        }
        return true
    }

    private func stateHasSafeClearBoundary(_ state: LocalHistoryMaintenanceState) -> Bool {
        if state.schemaVersion < 4 {
            guard state.clearThrough == nil else { return false }
            // A legacy residue-only replay performs no logical deletion and is safe.
            return state.phase == .residuePending || !state.containsClearAllOperation
        }
        if state.schemaVersion == 4 {
            return state.runClearTransition == nil
                && state.legacyRunClearThrough == nil
                && state.containsClearAllOperation == (state.clearThrough != nil)
        }

        let clipboardContainsClear: Bool
        if case .clearAll? = state.clipboardOperation {
            clipboardContainsClear = true
        } else {
            clipboardContainsClear = false
        }
        let runContainsClear: Bool
        if case .clearAll? = state.runOperation {
            runContainsClear = true
        } else {
            runContainsClear = false
        }
        guard clipboardContainsClear == (state.clearThrough != nil),
              runContainsClear == (state.runClearTransition != nil) else {
            return false
        }
        if state.legacyRunClearThrough != nil {
            guard runContainsClear, state.runClearTransition != nil else { return false }
        }
        return true
    }

    private func removePendingState() async throws {
        try await settingsStore.removeValue(forKey: .localHistoryMaintenanceState)
    }

    private func acquireOperationAccess() async {
        if !operationIsActive {
            operationIsActive = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperationAccess() {
        guard !operationWaiters.isEmpty else {
            operationIsActive = false
            return
        }
        let next = operationWaiters.removeFirst()
        next.resume()
    }

    private func report(_ result: LocalHistoryMaintenanceResult) async {
        let event: LocalHistoryMaintenanceEvent
        switch result {
        case .completed(let counts):
            event = LocalHistoryMaintenanceEvent(outcome: .completed, counts: counts)
        case .pending(let counts, let reason):
            event = LocalHistoryMaintenanceEvent(
                outcome: .pending,
                counts: counts,
                pendingReason: reason
            )
        case .blocked(let reason):
            event = LocalHistoryMaintenanceEvent(
                outcome: .blocked,
                counts: LocalHistoryMaintenanceCounts(),
                blockReason: reason
            )
        }
        await eventReporter(event)
    }
}

private enum MaintenanceExecutionError: Error {
    case missingClearBoundary
}
