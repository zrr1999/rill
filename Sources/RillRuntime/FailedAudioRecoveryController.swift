import Foundation
import RillCore

public actor FailedAudioRecoveryController {
    public enum ControllerError: Error, LocalizedError, Sendable, Equatable {
        case retryAlreadyRunning
        case recoveryDisabled
        case retryFailed
        case retryFailedCleanupPending
        case plaintextCleanupPending

        public var errorDescription: String? {
            switch self {
            case .retryAlreadyRunning:
                return "A failed recording retry is already running."
            case .recoveryDisabled:
                return "Failed recording recovery is disabled."
            case .retryFailed:
                return "The failed recording could not be reprocessed."
            case .retryFailedCleanupPending:
                return "Recognition failed and the recovery state could not be restored safely."
            case .plaintextCleanupPending:
                return "An unencrypted recovery temporary recording may still be awaiting cleanup."
            }
        }
    }

    public enum RetryResult: Sendable, Equatable {
        case completed
        case completedCleanupPending
    }

    private let store: any FailedAudioRecoveryStore
    private let sessionCoordinator: SessionCoordinator
    private let eventBus: EventBus
    private let diagnostics: DiagnosticsRecorder?
    private let privacyRunGate: PrivacyRunGate?
    private let privacyContextProvider: @Sendable () async -> ContextSnapshot
    private let authorizedContextProvider: @Sendable (PrivacyPolicyDecision) async -> ContextSnapshot
    private let recognitionOptionsProvider: @Sendable (
        WorkflowDefinition,
        ContextSnapshot
    ) async -> SpeechRecognitionRequestOptions
    private let runPreflight: RecognitionRunPreflight
    private let currentDate: @Sendable () -> Date
    private let removeManagedRecoveryTemporaryFile: @Sendable (CapturedAudio) throws -> Void
    private let cleanupRecoveryTemporaryFiles: @Sendable () async -> Bool
    private let initialMaintenanceRetryInterval: TimeInterval
    private let maximumMaintenanceRetryInterval: TimeInterval

    private var retryingIDs: Set<UUID> = []
    private var isEnabled = false
    private var enableGeneration: UInt64 = 0
    private var activePreservationCount = 0
    private var preservationDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var expirationTask: Task<Void, Never>?
    private var expirationTaskID: UUID?
    private var expirationScheduleGeneration: UInt64 = 0
    private var knownEarliestExpiration: Date?
    private var expirationRetryInterval: TimeInterval
    private var plaintextCleanupTask: Task<Void, Never>?
    private var plaintextCleanupTaskID: UUID?
    private var plaintextCleanupScheduleGeneration: UInt64 = 0
    private var plaintextCleanupPending = false
    private var plaintextCleanupRetryInterval: TimeInterval
    private var isStoppingForApplicationShutdown = false
    private var applicationShutdownCleanupTask: Task<Void, Never>?
    private var retryDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var maintenanceTasks: [UUID: Task<Void, Never>] = [:]
    private var activeShutdownDrainOperationCount = 0
    private var shutdownDrainOperationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        store: any FailedAudioRecoveryStore,
        sessionCoordinator: SessionCoordinator,
        eventBus: EventBus,
        diagnostics: DiagnosticsRecorder? = nil,
        privacyRunGate: PrivacyRunGate? = nil,
        contextProvider: @escaping @Sendable () async -> ContextSnapshot = { .empty },
        privacyContextProvider: (@Sendable () async -> ContextSnapshot)? = nil,
        authorizedContextProvider: (@Sendable (PrivacyPolicyDecision) async -> ContextSnapshot)? = nil,
        recognitionOptionsProvider: @escaping @Sendable (
            WorkflowDefinition,
            ContextSnapshot
        ) async -> SpeechRecognitionRequestOptions = { _, _ in .empty },
        runPreflight: @escaping RecognitionRunPreflight = { _ in },
        currentDate: @escaping @Sendable () -> Date = { Date() },
        removeManagedRecoveryTemporaryFile: @escaping @Sendable (CapturedAudio) throws -> Void = {
            _ = try $0.removeManagedTemporaryFile()
        },
        cleanupRecoveryTemporaryFiles: @escaping @Sendable () async -> Bool = { true },
        initialMaintenanceRetryInterval: TimeInterval = 5,
        maximumMaintenanceRetryInterval: TimeInterval = 5 * 60
    ) {
        precondition(initialMaintenanceRetryInterval > 0)
        precondition(maximumMaintenanceRetryInterval >= initialMaintenanceRetryInterval)
        self.store = store
        self.sessionCoordinator = sessionCoordinator
        self.eventBus = eventBus
        self.diagnostics = diagnostics
        self.privacyRunGate = privacyRunGate
        self.privacyContextProvider = privacyContextProvider ?? { .empty }
        self.authorizedContextProvider = authorizedContextProvider ?? { _ in .empty }
        self.recognitionOptionsProvider = recognitionOptionsProvider
        self.runPreflight = runPreflight
        self.currentDate = currentDate
        self.removeManagedRecoveryTemporaryFile = removeManagedRecoveryTemporaryFile
        self.cleanupRecoveryTemporaryFiles = cleanupRecoveryTemporaryFiles
        self.initialMaintenanceRetryInterval = initialMaintenanceRetryInterval
        self.maximumMaintenanceRetryInterval = maximumMaintenanceRetryInterval
        self.expirationRetryInterval = initialMaintenanceRetryInterval
        self.plaintextCleanupRetryInterval = initialMaintenanceRetryInterval
    }

    /// Reconciles durable artifacts with the opt-in setting. This never starts
    /// recognition and is safe to call during application startup.
    public func refresh(isEnabled requestedState: Bool, now: Date? = nil) async throws {
        guard beginShutdownDrainOperation() != nil else { return }
        defer { finishShutdownDrainOperation() }
        let operationDate = now ?? currentDate()
        enableGeneration &+= 1
        let transitionGeneration = enableGeneration
        isEnabled = false
        cancelExpirationSchedule()

        if requestedState {
            // Startup can inherit an unencrypted retry temporary from a crash.
            // Reconcile it before opening the runtime latch, and keep retrying
            // in the background if the sweep cannot be proven complete.
            let plaintextCleanupSucceeded = await cleanupRecoveryTemporaryFiles()
            guard transitionGeneration == enableGeneration else { return }
            if plaintextCleanupSucceeded {
                clearPlaintextCleanupPending()
            } else {
                markPlaintextCleanupPending()
            }
            let receipts = try await store.receipts(now: operationDate)
            guard canPublish(generation: transitionGeneration) else { return }
            isEnabled = true
            await publish(receipts, generation: transitionGeneration)
            return
        }

        // Close the runtime latch before awaiting storage so no new operation
        // can commit after an opt-out has begun.
        var cleanupFailed = false
        do {
            try await store.deleteAll()
        } catch {
            cleanupFailed = true
        }
        guard transitionGeneration == enableGeneration else { return }
        await waitForPreservationsToDrain()
        guard transitionGeneration == enableGeneration else { return }
        do {
            // A final sweep closes the actor-reentrancy window for a preserve
            // that entered the store immediately before opt-out.
            try await store.deleteAll()
        } catch {
            cleanupFailed = true
        }
        guard transitionGeneration == enableGeneration else { return }
        let plaintextCleanupSucceeded = await cleanupRecoveryTemporaryFiles()
        guard transitionGeneration == enableGeneration else { return }
        if !plaintextCleanupSucceeded {
            cleanupFailed = true
            markPlaintextCleanupPending()
        } else {
            clearPlaintextCleanupPending()
        }
        await publish([], generation: transitionGeneration)
        guard canPublish(generation: transitionGeneration) else { return }
        if !plaintextCleanupSucceeded {
            throw ControllerError.plaintextCleanupPending
        }
        if cleanupFailed {
            throw FailedAudioRecoveryError.storageUnavailable
        }
    }

    public func currentReceipts(
        now: Date? = nil
    ) async throws -> [FailedAudioRecoveryReceipt] {
        guard let operationGeneration = beginShutdownDrainOperation() else {
            throw ControllerError.recoveryDisabled
        }
        defer { finishShutdownDrainOperation() }
        return try await publishReceipts(
            now: now ?? currentDate(),
            generation: operationGeneration
        )
    }

    /// Closes every recovery entry point and does not return until the global
    /// recovery-temp sweep proves that no decrypted retry audio remains. A
    /// transient cleanup failure intentionally keeps application termination
    /// pending; the termination coordinator will deny the current quit after
    /// its timeout while this security-critical cleanup continues.
    public func stopForApplicationShutdown() async {
        if let applicationShutdownCleanupTask {
            await applicationShutdownCleanupTask.value
            return
        }

        let maintenanceTasks = beginApplicationShutdown()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performApplicationShutdownCleanup(
                maintenanceTasks: maintenanceTasks
            )
        }
        applicationShutdownCleanupTask = task
        await task.value
    }

    /// Serializes opt-in state and preservation under one runtime actor. The
    /// generation check and final opt-out sweep prevent a late store commit
    /// from recreating data after the setting is disabled.
    @discardableResult
    public func preserveIfEnabled(
        audio: CapturedAudio,
        originalRunID: UUID,
        workflowID: UUID,
        failure: WorkflowRunFailureSummary,
        now: Date? = nil
    ) async throws -> FailedAudioRecoveryReceipt? {
        guard !isStoppingForApplicationShutdown, isEnabled else { return nil }
        let generation = enableGeneration
        activePreservationCount += 1
        do {
            let receipt = try await store.preserve(
                audio: audio,
                originalRunID: originalRunID,
                workflowID: workflowID,
                failure: failure,
                now: now ?? currentDate()
            )
            guard isEnabled, generation == enableGeneration else {
                try? await store.delete(id: receipt.id)
                finishPreservation()
                return nil
            }

            do {
                _ = try await publishReceipts(
                    now: currentDate(),
                    generation: generation
                )
            } catch {
                // The pair is already durable. Do not misreport a successful
                // preserve as data loss merely because the index refresh failed.
                scheduleExpirationCandidate(
                    receipt.expiresAt,
                    generation: generation
                )
                await recordDiagnostic(
                    event: "audio-recovery.index-refresh-failed",
                    runID: originalRunID,
                    level: .warning,
                    metadata: ["outcome": "preserved"]
                )
            }
            finishPreservation()
            return receipt
        } catch {
            finishPreservation()
            throw error
        }
    }

    public func retry(
        id: UUID,
        workflow: WorkflowDefinition
    ) async throws -> RetryResult {
        try Task.checkCancellation()
        guard !isStoppingForApplicationShutdown else {
            throw ControllerError.recoveryDisabled
        }
        guard !plaintextCleanupPending else {
            throw ControllerError.plaintextCleanupPending
        }
        guard isEnabled else {
            throw ControllerError.recoveryDisabled
        }
        if let issue = WorkflowExecutionPolicy.issue(for: workflow) {
            throw SessionCoordinator.SessionError.unsupportedWorkflow(issue)
        }
        // The recovery janitor is intentionally global, so only one decrypted
        // recovery temporary may be active at a time.
        guard retryingIDs.isEmpty else {
            throw ControllerError.retryAlreadyRunning
        }
        let retryGeneration = enableGeneration
        retryingIDs.insert(id)
        defer { finishRetry(id) }

        // Recovery reprocesses into run history only. It never repeats paste,
        // clipboard, Shortcut, file, or network output actions from the old run.
        var recoveryWorkflow = workflow
        recoveryWorkflow.pipeline.outputActions = []
        recoveryWorkflow.pipeline.deliveryPolicy = .init(strategy: .immediate)
        let retryRunID = UUID()

        // Current provider configuration and privacy policy are authoritative.
        // Claim the exact output-free retry before any audio is decrypted.
        try Task.checkCancellation()
        try await runPreflight(recoveryWorkflow)
        try Task.checkCancellation()
        guard let privacyRunGate else {
            throw SessionCoordinator.SessionError.privacyAuthorizationRequired
        }
        let processingLease = try await privacyRunGate.issueAudioProcessingLease(
            runID: retryRunID,
            privacyContextProvider: privacyContextProvider,
            contextProvider: authorizedContextProvider,
            recognitionOptionsProvider: recognitionOptionsProvider,
            workflow: recoveryWorkflow
        )
        try Task.checkCancellation()
        let authorizationClaim = try await processingLease.claim(triggerEvent: nil)
        try Task.checkCancellation()

        // The time is sampled after any user confirmation. materializeForRetry
        // also durably marks the attempt before writing plaintext.
        let attemptID = UUID()
        let capturedAudio = try await store.materializeForRetry(
            id: id,
            attemptID: attemptID,
            now: currentDate()
        )
        _ = try? await publishReceipts(
            now: currentDate(),
            generation: retryGeneration
        )

        let authorization: (
            runID: UUID,
            authorizedContext: AuthorizedWorkflowRunContext
        )
        do {
            try Task.checkCancellation()
            authorization = try await authorizationClaim.finalize()
            try Task.checkCancellation()
        } catch {
            let plaintextCleanupPending = await removeRecoveryPlaintext(
                capturedAudio,
                runID: retryRunID
            )
            var stateCleanupPending = false
            do {
                try await store.restoreAfterFailedRetry(id: id, attemptID: attemptID)
            } catch {
                stateCleanupPending = true
            }
            _ = try? await publishReceipts(
                now: currentDate(),
                generation: retryGeneration
            )
            if plaintextCleanupPending {
                throw ControllerError.plaintextCleanupPending
            }
            if stateCleanupPending {
                throw ControllerError.retryFailedCleanupPending
            }
            throw error
        }

        let result = await sessionCoordinator.runReportingOutcome(
            workflow: authorization.authorizedContext.workflow,
            runID: authorization.runID,
            capturedAudio: capturedAudio,
            contextSnapshot: authorization.authorizedContext.contextSnapshot,
            recognitionOptions: authorization.authorizedContext.recognitionOptions,
            receiptTrigger: .failedAudioRecovery
        )

        let plaintextCleanupPending = await removeRecoveryPlaintext(
            capturedAudio,
            runID: retryRunID
        )

        switch result {
        case .completed:
            var cleanupPending = plaintextCleanupPending
            do {
                try await store.delete(id: id)
            } catch {
                cleanupPending = true
            }
            do {
                _ = try await publishReceipts(
                    now: currentDate(),
                    generation: retryGeneration
                )
            } catch {
                cleanupPending = true
            }
            await recordDiagnostic(
                event: cleanupPending
                    ? "audio-recovery.retry-completed-cleanup-pending"
                    : "audio-recovery.retry-completed",
                runID: retryRunID,
                level: cleanupPending ? .warning : .info,
                metadata: ["outcome": cleanupPending ? "cleanup-pending" : "completed"]
            )
            return cleanupPending ? .completedCleanupPending : .completed

        case .cancelled:
            var stateCleanupPending = plaintextCleanupPending
            do {
                try await store.restoreAfterFailedRetry(id: id, attemptID: attemptID)
            } catch {
                stateCleanupPending = true
            }
            _ = try? await publishReceipts(
                now: currentDate(),
                generation: retryGeneration
            )
            if stateCleanupPending {
                throw ControllerError.retryFailedCleanupPending
            }
            throw CancellationError()

        case .failed(let failure):
            var stateCleanupPending = plaintextCleanupPending
            do {
                try await store.restoreAfterFailedRetry(id: id, attemptID: attemptID)
            } catch {
                stateCleanupPending = true
            }
            _ = try? await publishReceipts(
                now: currentDate(),
                generation: retryGeneration
            )
            await recordDiagnostic(
                event: stateCleanupPending
                    ? "audio-recovery.retry-failed-cleanup-pending"
                    : "audio-recovery.retry-failed",
                runID: retryRunID,
                level: .warning,
                metadata: [
                    "outcome": stateCleanupPending ? "cleanup-pending" : "failed",
                    "reason": failure.code.rawValue,
                    "stage": failure.stage.rawValue,
                ]
            )
            throw stateCleanupPending
                ? ControllerError.retryFailedCleanupPending
                : ControllerError.retryFailed
        }
    }

    /// Removes a materialized recovery plaintext and engages the existing
    /// process-wide janitor latch if direct removal cannot be proven complete.
    private func removeRecoveryPlaintext(
        _ capturedAudio: CapturedAudio,
        runID: UUID
    ) async -> Bool {
        do {
            try removeManagedRecoveryTemporaryFile(capturedAudio)
            return false
        } catch {
            let cleanupPending = !(await cleanupRecoveryTemporaryFiles())
            if cleanupPending {
                markPlaintextCleanupPending()
            } else {
                clearPlaintextCleanupPending()
            }
            await recordDiagnostic(
                event: cleanupPending
                    ? "audio-recovery.plaintext-cleanup-failed"
                    : "audio-recovery.plaintext-cleanup-recovered",
                runID: runID,
                level: cleanupPending ? .error : .info,
                metadata: [
                    "outcome": cleanupPending ? "cleanup-pending" : "completed",
                ]
            )
            return cleanupPending
        }
    }

    public func delete(id: UUID, now: Date? = nil) async throws {
        guard let operationGeneration = beginShutdownDrainOperation() else {
            throw ControllerError.recoveryDisabled
        }
        defer { finishShutdownDrainOperation() }
        guard !retryingIDs.contains(id) else {
            throw ControllerError.retryAlreadyRunning
        }
        try await store.delete(id: id)
        guard canPublish(generation: operationGeneration) else { return }
        _ = try await publishReceipts(
            now: now ?? currentDate(),
            generation: operationGeneration
        )
    }

    public func deleteAll(now: Date? = nil) async throws {
        guard beginShutdownDrainOperation() != nil else {
            throw ControllerError.recoveryDisabled
        }
        defer { finishShutdownDrainOperation() }
        let shouldRestoreEnabledState = isEnabled
        let previousKnownExpiration = knownEarliestExpiration
        isEnabled = false
        enableGeneration &+= 1
        let clearGeneration = enableGeneration
        cancelExpirationSchedule()

        var cleanupFailed = false
        do {
            try await store.deleteAll()
        } catch {
            cleanupFailed = true
        }
        await waitForPreservationsToDrain()
        do {
            try await store.deleteAll()
        } catch {
            cleanupFailed = true
        }
        let plaintextCleanupSucceeded = await cleanupRecoveryTemporaryFiles()
        if plaintextCleanupSucceeded {
            clearPlaintextCleanupPending()
        } else {
            cleanupFailed = true
            markPlaintextCleanupPending()
        }

        // Restore only if no concurrent opt-out changed the generation while
        // Clear was awaiting storage. A concurrent opt-out remains authoritative.
        if shouldRestoreEnabledState,
           !isStoppingForApplicationShutdown,
           enableGeneration == clearGeneration {
            isEnabled = true
            enableGeneration &+= 1
            let restoredGeneration = enableGeneration
            do {
                _ = try await publishReceipts(
                    now: now ?? currentDate(),
                    generation: restoredGeneration
                )
            } catch {
                cleanupFailed = true
                if let previousKnownExpiration {
                    scheduleExpirationCandidate(
                        previousKnownExpiration,
                        generation: restoredGeneration
                    )
                }
                scheduleExpirationMaintenanceRetry(generation: restoredGeneration)
            }
        }

        if !plaintextCleanupSucceeded {
            throw ControllerError.plaintextCleanupPending
        }
        if cleanupFailed {
            throw FailedAudioRecoveryError.storageUnavailable
        }
    }

    private func publishReceipts(
        now: Date,
        generation: UInt64
    ) async throws -> [FailedAudioRecoveryReceipt] {
        let receipts = try await store.receipts(now: now)
        await publish(receipts, generation: generation)
        return receipts
    }

    private func publish(
        _ receipts: [FailedAudioRecoveryReceipt],
        generation: UInt64
    ) async {
        guard canPublish(generation: generation) else { return }
        await eventBus.publish(.failedAudioRecoveryUpdated(receipts))
        guard canPublish(generation: generation) else { return }
        scheduleExpiration(for: receipts, generation: generation)
    }

    private func scheduleExpiration(
        for receipts: [FailedAudioRecoveryReceipt],
        generation: UInt64
    ) {
        guard canPublish(generation: generation) else { return }
        knownEarliestExpiration = receipts.map(\.expiresAt).min()
        expirationRetryInterval = initialMaintenanceRetryInterval
        invalidateExpirationTask()
        guard isEnabled, let deadline = knownEarliestExpiration else { return }
        installExpirationTask(firingAt: deadline, generation: generation)
    }

    /// Partial index information may only move the known deadline earlier.
    /// It must never replace an older receipt deadline with a newer one.
    private func scheduleExpirationCandidate(
        _ deadline: Date,
        generation: UInt64
    ) {
        guard isEnabled, canPublish(generation: generation) else { return }
        if let knownEarliestExpiration,
           knownEarliestExpiration <= deadline,
           expirationTask != nil {
            return
        }
        knownEarliestExpiration = min(knownEarliestExpiration ?? deadline, deadline)
        installExpirationTask(
            firingAt: knownEarliestExpiration ?? deadline,
            generation: generation
        )
    }

    private func scheduleExpirationMaintenanceRetry(generation: UInt64) {
        guard isEnabled, canPublish(generation: generation) else { return }
        let retryDate = currentDate().addingTimeInterval(expirationRetryInterval)
        expirationRetryInterval = min(
            maximumMaintenanceRetryInterval,
            expirationRetryInterval * 2
        )
        installExpirationTask(firingAt: retryDate, generation: generation)
    }

    private func installExpirationTask(firingAt date: Date, generation: UInt64) {
        guard isEnabled, canPublish(generation: generation) else { return }
        expirationTask?.cancel()
        expirationScheduleGeneration &+= 1
        let scheduleGeneration = expirationScheduleGeneration
        let delay = max(0, date.timeIntervalSince(currentDate()))
        let taskID = UUID()
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                await self?.finishMaintenanceTask(id: taskID)
                return
            }
            await self?.expireAtDeadline(
                generation: generation,
                scheduleGeneration: scheduleGeneration
            )
            await self?.finishMaintenanceTask(id: taskID)
        }
        expirationTask = task
        expirationTaskID = taskID
        maintenanceTasks[taskID] = task
    }

    private func invalidateExpirationTask() {
        expirationScheduleGeneration &+= 1
        expirationTask?.cancel()
        expirationTask = nil
        expirationTaskID = nil
    }

    private func cancelExpirationSchedule() {
        invalidateExpirationTask()
        knownEarliestExpiration = nil
        expirationRetryInterval = initialMaintenanceRetryInterval
    }

    private func expireAtDeadline(
        generation: UInt64,
        scheduleGeneration: UInt64
    ) async {
        guard isEnabled,
              scheduleGeneration == expirationScheduleGeneration,
              beginShutdownDrainOperation(expectedGeneration: generation) != nil else {
            return
        }
        defer { finishShutdownDrainOperation() }
        do {
            _ = try await store.purgeExpired(now: currentDate())
            guard canPublish(generation: generation),
                  scheduleGeneration == expirationScheduleGeneration else {
                return
            }
            _ = try await publishReceipts(
                now: currentDate(),
                generation: generation
            )
        } catch {
            guard canPublish(generation: generation),
                  scheduleGeneration == expirationScheduleGeneration else {
                return
            }
            scheduleExpirationMaintenanceRetry(generation: generation)
            guard canPublish(generation: generation) else { return }
            await recordDiagnostic(
                event: "audio-recovery.expiration-failed",
                runID: UUID(),
                level: .warning,
                metadata: ["outcome": "cleanup-pending"]
            )
        }
    }

    private func markPlaintextCleanupPending() {
        plaintextCleanupPending = true
        schedulePlaintextCleanupRetry()
    }

    private func clearPlaintextCleanupPending() {
        plaintextCleanupPending = false
        plaintextCleanupRetryInterval = initialMaintenanceRetryInterval
        plaintextCleanupScheduleGeneration &+= 1
        plaintextCleanupTask?.cancel()
        plaintextCleanupTask = nil
        plaintextCleanupTaskID = nil
    }

    /// Keeps retrying the narrow recovery-temp sweep while the application is
    /// running. Recovery retries stay blocked until no unencrypted temporary
    /// recording is known to remain.
    private func schedulePlaintextCleanupRetry() {
        guard plaintextCleanupPending,
              !isStoppingForApplicationShutdown,
              plaintextCleanupTask == nil else {
            return
        }
        let delay = plaintextCleanupRetryInterval
        plaintextCleanupRetryInterval = min(
            maximumMaintenanceRetryInterval,
            plaintextCleanupRetryInterval * 2
        )
        plaintextCleanupScheduleGeneration &+= 1
        let scheduleGeneration = plaintextCleanupScheduleGeneration
        let operationGeneration = enableGeneration
        let taskID = UUID()
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                await self?.finishMaintenanceTask(id: taskID)
                return
            }
            await self?.retryPlaintextCleanup(
                generation: operationGeneration,
                scheduleGeneration: scheduleGeneration
            )
            await self?.finishMaintenanceTask(id: taskID)
        }
        plaintextCleanupTask = task
        plaintextCleanupTaskID = taskID
        maintenanceTasks[taskID] = task
    }

    private func retryPlaintextCleanup(
        generation: UInt64,
        scheduleGeneration: UInt64
    ) async {
        guard scheduleGeneration == plaintextCleanupScheduleGeneration else { return }
        guard beginShutdownDrainOperation(expectedGeneration: generation) != nil else {
            plaintextCleanupTask = nil
            plaintextCleanupTaskID = nil
            return
        }
        defer { finishShutdownDrainOperation() }
        guard plaintextCleanupPending else {
            plaintextCleanupTask = nil
            plaintextCleanupTaskID = nil
            return
        }
        let cleanupSucceeded = await cleanupRecoveryTemporaryFiles()
        guard canPublish(generation: generation),
              scheduleGeneration == plaintextCleanupScheduleGeneration else {
            return
        }
        plaintextCleanupTask = nil
        plaintextCleanupTaskID = nil
        if cleanupSucceeded {
            clearPlaintextCleanupPending()
            await recordDiagnostic(
                event: "audio-recovery.plaintext-cleanup-completed",
                runID: UUID(),
                metadata: ["outcome": "completed"]
            )
        } else {
            schedulePlaintextCleanupRetry()
            await recordDiagnostic(
                event: "audio-recovery.plaintext-cleanup-retry-failed",
                runID: UUID(),
                level: .warning,
                metadata: ["outcome": "cleanup-pending"]
            )
        }
    }

    private func performApplicationShutdownCleanup(
        maintenanceTasks: [Task<Void, Never>]
    ) async {
        for task in maintenanceTasks {
            await task.value
        }
        await waitForShutdownDrainOperationsToDrain()
        await waitForPreservationsToDrain()
        await waitForRetriesToDrain()

        var retryDelay = initialMaintenanceRetryInterval
        var didObserveFailure = plaintextCleanupPending
        while !(await cleanupRecoveryTemporaryFiles()) {
            plaintextCleanupPending = true
            if !didObserveFailure {
                await recordDiagnostic(
                    event: "audio-recovery.plaintext-shutdown-cleanup-pending",
                    runID: UUID(),
                    level: .error,
                    metadata: ["outcome": "cleanup-pending"]
                )
                didObserveFailure = true
            }

            let delay = retryDelay
            retryDelay = min(maximumMaintenanceRetryInterval, retryDelay * 2)
            // This cleanup is intentionally cancellation-resistant. A normal
            // quit timeout cancels the quit request, not the proof-of-cleanup
            // operation that protects recovery plaintext.
            await Task.detached {
                try? await Task.sleep(for: .seconds(delay))
            }.value
        }

        clearPlaintextCleanupPending()
        if didObserveFailure {
            await recordDiagnostic(
                event: "audio-recovery.plaintext-shutdown-cleanup-completed",
                runID: UUID(),
                metadata: ["outcome": "completed"]
            )
        }
    }

    private func beginApplicationShutdown() -> [Task<Void, Never>] {
        let capturedMaintenanceTasks = Array(maintenanceTasks.values)
        isStoppingForApplicationShutdown = true
        isEnabled = false
        enableGeneration &+= 1
        cancelExpirationSchedule()
        plaintextCleanupScheduleGeneration &+= 1
        plaintextCleanupTask?.cancel()
        plaintextCleanupTask = nil
        plaintextCleanupTaskID = nil
        for task in capturedMaintenanceTasks { task.cancel() }
        maintenanceTasks.removeAll()
        return capturedMaintenanceTasks
    }

    private func finishMaintenanceTask(id: UUID) {
        maintenanceTasks.removeValue(forKey: id)
        if expirationTaskID == id {
            expirationTask = nil
            expirationTaskID = nil
        }
        if plaintextCleanupTaskID == id {
            plaintextCleanupTask = nil
            plaintextCleanupTaskID = nil
        }
    }

    private func canPublish(generation: UInt64) -> Bool {
        !isStoppingForApplicationShutdown && generation == enableGeneration
    }

    private func beginShutdownDrainOperation(
        expectedGeneration: UInt64? = nil
    ) -> UInt64? {
        guard !isStoppingForApplicationShutdown else { return nil }
        if let expectedGeneration, expectedGeneration != enableGeneration {
            return nil
        }
        activeShutdownDrainOperationCount += 1
        return enableGeneration
    }

    private func finishShutdownDrainOperation() {
        activeShutdownDrainOperationCount -= 1
        guard activeShutdownDrainOperationCount == 0 else { return }
        let waiters = shutdownDrainOperationWaiters
        shutdownDrainOperationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForShutdownDrainOperationsToDrain() async {
        guard activeShutdownDrainOperationCount > 0 else { return }
        await withCheckedContinuation { continuation in
            shutdownDrainOperationWaiters.append(continuation)
        }
    }

    private func finishRetry(_ id: UUID) {
        retryingIDs.remove(id)
        guard retryingIDs.isEmpty else { return }
        let waiters = retryDrainWaiters
        retryDrainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForRetriesToDrain() async {
        guard !retryingIDs.isEmpty else { return }
        await withCheckedContinuation { continuation in
            retryDrainWaiters.append(continuation)
        }
    }

    private func finishPreservation() {
        activePreservationCount -= 1
        guard activePreservationCount == 0 else { return }
        let waiters = preservationDrainWaiters
        preservationDrainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForPreservationsToDrain() async {
        guard activePreservationCount > 0 else { return }
        await withCheckedContinuation { continuation in
            preservationDrainWaiters.append(continuation)
        }
    }

    private func recordDiagnostic(
        event: String,
        runID: UUID,
        level: DiagnosticLevel = .info,
        metadata: [String: String]
    ) async {
        guard let diagnostics else { return }
        await diagnostics.record(
            DiagnosticEvent(
                runID: runID,
                subsystem: .session,
                level: level,
                event: event,
                message: "Failed recording recovery operation completed.",
                metadata: metadata
            )
        )
    }
}
