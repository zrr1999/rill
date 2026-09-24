import Foundation
import RillCore

public actor CapturedAudioProcessingQueue {
    public enum Lane: String, Sendable, Equatable {
        case interactive
        case assistant
    }

    public enum OwnershipTransferResult: Sendable, Equatable {
        case accepted
        case rejected
    }

    private enum Lifecycle: Sendable, Equatable {
        case accepting
        case shuttingDown
        case terminated
    }

    private enum RejectedCaptureCleanupSource: Sendable {
        case deferred(DeferredCapturedAudio)
        case cancelledDeferred(DeferredCapturedAudio)
        case resolved(CapturedAudio)
    }

    private struct RejectedCleanupWork: Sendable {
        let runID: UUID
        let task: Task<Void, Never>
    }

    private struct Job: Sendable {
        let authorizationLease: AuthorizedAudioProcessingLease
        let triggerEvent: WorkflowTriggerEvent?
        let deferredCapture: DeferredCapturedAudio
        let enqueuedAt: Date
        let bufferReservation: Task<BufferInputReservation?, Error>

        var runID: UUID { authorizationLease.runID }
        var workflow: WorkflowDefinition { authorizationLease.workflow }
    }

    private let sessionCoordinator: SessionCoordinator
    private let eventBus: EventBus
    private let diagnostics: DiagnosticsRecorder?
    private let failedAudioRecoveryController: FailedAudioRecoveryController?
    private let benchmarkRecordingArchiveController: BenchmarkRecordingArchiveController?
    private let lane: Lane
    private let publishesSnapshots: Bool
    private let rejectedCapturedAudioRemoval: @Sendable (CapturedAudio) async throws -> Void
    private let rejectedCleanupInitialRetryDelay: Duration
    private let rejectedCleanupMaximumRetryDelay: Duration
    private let rejectedCleanupSleep: @Sendable (Duration) async throws -> Void
    private let ownershipTransferObserver: @Sendable (UUID) async -> Void

    private var pendingJobs: [Job] = []
    private var lastBufferObservation: Task<BufferInputReservation?, Error>?
    private var activeJob: Job?
    private var drainTask: Task<Void, Never>?
    private var drainGeneration: UInt64 = 0
    private var rejectedCleanupTasks: [UUID: RejectedCleanupWork] = [:]
    private var lifecycle: Lifecycle = .accepting
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        sessionCoordinator: SessionCoordinator,
        eventBus: EventBus,
        diagnostics: DiagnosticsRecorder? = nil,
        failedAudioRecoveryController: FailedAudioRecoveryController? = nil,
        benchmarkRecordingArchiveController: BenchmarkRecordingArchiveController? = nil,
        lane: Lane = .interactive,
        publishesSnapshots: Bool = true
    ) {
        self.init(
            sessionCoordinator: sessionCoordinator,
            eventBus: eventBus,
            diagnostics: diagnostics,
            failedAudioRecoveryController: failedAudioRecoveryController,
            benchmarkRecordingArchiveController: benchmarkRecordingArchiveController,
            lane: lane,
            publishesSnapshots: publishesSnapshots,
            rejectedCapturedAudioRemoval: { capturedAudio in
                _ = try capturedAudio.removeManagedTemporaryFile()
            },
            rejectedCleanupInitialRetryDelay: .milliseconds(100),
            rejectedCleanupMaximumRetryDelay: .seconds(5),
            rejectedCleanupSleep: { delay in
                try await Task.sleep(for: delay)
            },
            ownershipTransferObserver: { _ in }
        )
    }

    init(
        sessionCoordinator: SessionCoordinator,
        eventBus: EventBus,
        diagnostics: DiagnosticsRecorder? = nil,
        failedAudioRecoveryController: FailedAudioRecoveryController? = nil,
        benchmarkRecordingArchiveController: BenchmarkRecordingArchiveController? = nil,
        lane: Lane = .interactive,
        publishesSnapshots: Bool = true,
        rejectedCapturedAudioRemoval: @escaping @Sendable (
            CapturedAudio
        ) async throws -> Void,
        rejectedCleanupInitialRetryDelay: Duration,
        rejectedCleanupMaximumRetryDelay: Duration,
        rejectedCleanupSleep: @escaping @Sendable (Duration) async throws -> Void,
        ownershipTransferObserver: @escaping @Sendable (UUID) async -> Void = { _ in }
    ) {
        precondition(rejectedCleanupInitialRetryDelay > .zero)
        precondition(rejectedCleanupMaximumRetryDelay >= rejectedCleanupInitialRetryDelay)
        self.sessionCoordinator = sessionCoordinator
        self.eventBus = eventBus
        self.diagnostics = diagnostics
        self.failedAudioRecoveryController = failedAudioRecoveryController
        self.benchmarkRecordingArchiveController = benchmarkRecordingArchiveController
        self.lane = lane
        self.publishesSnapshots = publishesSnapshots
        self.rejectedCapturedAudioRemoval = rejectedCapturedAudioRemoval
        self.rejectedCleanupInitialRetryDelay = rejectedCleanupInitialRetryDelay
        self.rejectedCleanupMaximumRetryDelay = rejectedCleanupMaximumRetryDelay
        self.rejectedCleanupSleep = rejectedCleanupSleep
        self.ownershipTransferObserver = ownershipTransferObserver
    }

    /// Attempts to transfer ownership of a deferred capture to the queue.
    ///
    /// `.accepted` is the exact ownership boundary: the queue then resolves or
    /// cancels the capture and disposes of any managed temporary file. On
    /// `.rejected`, the caller retains cancellation and cleanup responsibility.
    @discardableResult
    public func enqueue(
        authorizationLease: AuthorizedAudioProcessingLease,
        triggerEvent: WorkflowTriggerEvent?,
        deferredCapture: DeferredCapturedAudio
    ) async -> OwnershipTransferResult {
        let runID = authorizationLease.runID
        let workflow = authorizationLease.workflow
        guard lifecycle == .accepting,
              authorizationLease.acceptQueueOwnership() else {
            return .rejected
        }

        if let issue = WorkflowExecutionPolicy.issue(for: workflow) {
            authorizationLease.cancel()
            deferredCapture.cancel()
            scheduleCancelledDeferredCaptureCleanup(
                deferredCapture,
                runID: runID
            )
            await eventBus.publish(
                .runFailed(
                    runID: runID,
                    workflow: workflow.presentation,
                    message: SessionCoordinator.SessionError.unsupportedWorkflow(issue).localizedDescription
                )
            )
            return .accepted
        }

        // No suspension is permitted between the synchronous lease transition
        // above and this append. At every instant exactly one owner exists.
        let previousObservation = lastBufferObservation
        let bufferReservation = Task {
            _ = try? await previousObservation?.value
            return try await sessionCoordinator.observeCollectedSpeech(runID: runID, workflow: workflow)
        }
        lastBufferObservation = bufferReservation
        pendingJobs.append(
            Job(
                authorizationLease: authorizationLease,
                triggerEvent: triggerEvent,
                deferredCapture: deferredCapture,
                enqueuedAt: Date(),
                bufferReservation: bufferReservation
            )
        )
        // Assign input order before acknowledging submission, without waiting for disk.
        _ = try? await bufferReservation.value
        await ownershipTransferObserver(runID)
        await recordDiagnostic(
            event: "audio-processing.enqueued",
            message: "Queued a recorded workflow run for background processing.",
            runID: runID,
            metadata: [
                "workflow": workflow.name,
                "pendingCount": String(pendingCount),
            ]
        )
        await publishSnapshot()
        ensureDrainTask()
        return .accepted
    }

    public var pendingCount: Int {
        pendingJobs.count + (activeJob == nil ? 0 : 1)
    }

    var rejectedCleanupCount: Int {
        rejectedCleanupTasks.count
    }

    var activeRunIDForTesting: UUID? {
        activeJob?.runID
    }

    var isShutdownInProgressForTesting: Bool {
        lifecycle == .shuttingDown
    }

    public func snapshot() -> AudioProcessingQueueSnapshot {
        AudioProcessingQueueSnapshot(
            processingRunID: activeJob?.runID ?? pendingJobs.first?.runID,
            workflow: activeJob?.workflow.presentation ?? pendingJobs.first?.workflow.presentation,
            pendingCount: pendingCount
        )
    }

    /// Stops accepting work, cancels the active processing task, and settles
    /// every pending capture under the queue's ownership contract.
    public func shutdown() async {
        switch lifecycle {
        case .terminated:
            return
        case .shuttingDown:
            await withCheckedContinuation { continuation in
                shutdownWaiters.append(continuation)
            }
            return
        case .accepting:
            lifecycle = .shuttingDown
        }

        let abandonedJobs = pendingJobs
        pendingJobs.removeAll()
        for job in abandonedJobs {
            job.authorizationLease.cancel()
            job.deferredCapture.cancel()
            scheduleCancelledDeferredCaptureCleanup(
                job.deferredCapture,
                runID: job.runID
            )
        }

        let activeDrainTask = drainTask
        if let activeJob {
            activeJob.authorizationLease.cancel()
            activeJob.deferredCapture.cancel()
        }
        activeDrainTask?.cancel()
        for job in abandonedJobs {
            _ = try? await job.bufferReservation.value
            await sessionCoordinator.finishCollectedSpeech(runID: job.runID)
        }
        if let activeDrainTask {
            await activeDrainTask.value
        }
        await publishSnapshot()
        await awaitRejectedCleanupTasks()
        lifecycle = .terminated
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Cancels and settles work for one accepted run without disturbing newer
    /// or unrelated queue work.
    public func cancel(runID: UUID) async {
        guard lifecycle == .accepting else { return }

        let abandonedJobs = pendingJobs.filter { $0.runID == runID }
        pendingJobs.removeAll { $0.runID == runID }
        for job in abandonedJobs {
            job.authorizationLease.cancel()
            job.deferredCapture.cancel()
            scheduleCancelledDeferredCaptureCleanup(
                job.deferredCapture,
                runID: job.runID
            )
        }

        let activeDrainTask: Task<Void, Never>?
        if let activeJob, activeJob.runID == runID {
            activeJob.authorizationLease.cancel()
            activeJob.deferredCapture.cancel()
            activeDrainTask = drainTask
            activeDrainTask?.cancel()
        } else {
            activeDrainTask = nil
        }
        for job in abandonedJobs {
            _ = try? await job.bufferReservation.value
            await sessionCoordinator.finishCollectedSpeech(runID: job.runID)
        }
        if let activeDrainTask {
            await activeDrainTask.value
        }

        await publishSnapshot()
        await awaitRejectedCleanupTasks(runID: runID)
        ensureDrainTask()
    }

    private func ensureDrainTask() {
        guard lifecycle == .accepting,
              drainTask == nil,
              !pendingJobs.isEmpty else { return }
        drainGeneration &+= 1
        let generation = drainGeneration
        drainTask = Task { [weak self] in
            await self?.drainQueue()
            await self?.drainDidFinish(generation: generation)
        }
    }

    private func scheduleRejectedCaptureCleanup(
        _ deferredCapture: DeferredCapturedAudio,
        runID: UUID
    ) {
        scheduleRejectedCaptureCleanup(
            source: .deferred(deferredCapture),
            runID: runID
        )
    }

    private func scheduleCancelledDeferredCaptureCleanup(
        _ deferredCapture: DeferredCapturedAudio,
        runID: UUID
    ) {
        scheduleRejectedCaptureCleanup(
            source: .cancelledDeferred(deferredCapture),
            runID: runID
        )
    }

    private func scheduleRejectedCapturedAudioRemoval(
        _ capturedAudio: CapturedAudio,
        runID: UUID
    ) {
        scheduleRejectedCaptureCleanup(
            source: .resolved(capturedAudio),
            runID: runID
        )
    }

    private func scheduleRejectedCaptureCleanup(
        source: RejectedCaptureCleanupSource,
        runID: UUID
    ) {
        let cleanupID = UUID()
        let removeCapturedAudio = rejectedCapturedAudioRemoval
        let initialRetryDelay = rejectedCleanupInitialRetryDelay
        let maximumRetryDelay = rejectedCleanupMaximumRetryDelay
        let sleep = rejectedCleanupSleep
        let task = Task { [weak self] in
            await Self.retryRejectedCaptureCleanup(
                source: source,
                initialRetryDelay: initialRetryDelay,
                maximumRetryDelay: maximumRetryDelay,
                removeCapturedAudio: removeCapturedAudio,
                sleep: sleep,
                recordResolutionFailure: { [weak self] in
                    guard let self else { return }
                    await self.recordDiagnostic(
                        event: "audio-processing.rejected-capture-resolution-failed",
                        message: "Rejected audio capture resolution failed terminally.",
                        runID: runID,
                        level: .error
                    )
                },
                recordRemovalFailure: { [weak self] in
                    guard let self else { return }
                    await self.recordDiagnostic(
                        event: "audio-processing.rejected-cleanup-pending",
                        message: "Managed temporary audio cleanup remains pending.",
                        runID: runID,
                        level: .error
                    )
                }
            )
            await self?.rejectedCaptureCleanupDidFinish(cleanupID)
        }
        rejectedCleanupTasks[cleanupID] = RejectedCleanupWork(
            runID: runID,
            task: task
        )
    }

    private static func retryRejectedCaptureCleanup(
        source: RejectedCaptureCleanupSource,
        initialRetryDelay: Duration,
        maximumRetryDelay: Duration,
        removeCapturedAudio: @escaping @Sendable (CapturedAudio) async throws -> Void,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        recordResolutionFailure: @escaping @Sendable () async -> Void,
        recordRemovalFailure: @escaping @Sendable () async -> Void
    ) async {
        let capturedAudio: CapturedAudio
        switch source {
        case .resolved(let resolvedAudio):
            capturedAudio = resolvedAudio
        case .deferred(let deferredCapture):
            // Resolution transfers a complete payload to the queue. A failure leaves partial-artifact
            // cleanup with the capture implementation, so repeating the same failed task cannot help.
            do {
                capturedAudio = try await deferredCapture.value()
            } catch {
                await recordResolutionFailure()
                return
            }
        case .cancelledDeferred(let deferredCapture):
            deferredCapture.cancel()
            do {
                capturedAudio = try await deferredCapture.value()
            } catch is CancellationError {
                // The capture contract assigns partial-artifact cleanup to the
                // implementation when cancellation prevents a complete value.
                return
            } catch {
                await recordResolutionFailure()
                return
            }
        }

        var retryDelay = initialRetryDelay
        while true {
            do {
                try await removeCapturedAudio(capturedAudio)
                return
            } catch {
                await recordRemovalFailure()
                // Queue ownership of managed plaintext is cancellation-
                // resistant. A cancelled caller may stop waiting only by
                // force-terminating the process; it must never cancel cleanup.
                let delay = retryDelay
                await Task.detached {
                    do {
                        try await sleep(delay)
                    } catch {
                        try? await Task.sleep(for: delay)
                    }
                }.value
                retryDelay = min(retryDelay * 2, maximumRetryDelay)
            }
        }
    }

    private func rejectedCaptureCleanupDidFinish(_ cleanupID: UUID) {
        rejectedCleanupTasks[cleanupID] = nil
    }

    private func drainQueue() async {
        while !Task.isCancelled {
            guard !pendingJobs.isEmpty else {
                await publishSnapshot()
                return
            }

            let job = pendingJobs.removeFirst()
            activeJob = job
            await publishSnapshot()
            await recordDiagnostic(
                event: "audio-processing.started",
                message: "Background processing started for a recorded workflow run.",
                runID: job.runID,
                metadata: [
                    "workflow": job.workflow.name,
                    "pendingCount": String(pendingCount),
                ]
            )

            var capturedAudioForCleanup: CapturedAudio?
            var captureResolutionStarted = false
            do {
                try Task.checkCancellation()
                let reservation = try await job.bufferReservation.value
                try await reservation?.committed.value
                try Task.checkCancellation()
                let authorizationClaim = try await job.authorizationLease.claim(
                    triggerEvent: job.triggerEvent
                )
                try Task.checkCancellation()
                captureResolutionStarted = true
                let capturedAudio = try await job.deferredCapture.value()
                capturedAudioForCleanup = capturedAudio
                let timingKeys = ["captureStopMillis", "captureDrainMillis",
                                  "capturePreviewRetireMillis", "captureFinalizeMillis"]
                let timing = capturedAudio.metadata.filter { timingKeys.contains($0.key) }
                if !timing.isEmpty {
                    await recordDiagnostic(
                        event: "audio-processing.capture-timing",
                        message: "Capture finalization timings.", runID: job.runID,
                        metadata: timing
                    )
                }

                try Task.checkCancellation()
                let authorization = try await authorizationClaim.finalize()
                try Task.checkCancellation()
                let outcome = await sessionCoordinator.runReportingOutcome(
                    workflow: authorization.authorizedContext.workflow,
                    runID: authorization.runID,
                    triggerEvent: job.triggerEvent,
                    capturedAudio: capturedAudio,
                    contextSnapshot: authorization.authorizedContext.contextSnapshot,
                    recognitionOptions: authorization.authorizedContext.recognitionOptions,
                    waitsForAvailability: true,
                    contextPreparation: authorization.authorizedContext.contextPreparation
                )
                await preserveBenchmarkRecordingIfEnabled(
                    capturedAudio,
                    outcome: outcome,
                    for: job
                )
                if case .failed(let failure) = outcome {
                    await preserveFailedAudioIfEligible(
                        capturedAudio,
                        failure: failure,
                        for: job
                    )
                }
                try Task.checkCancellation()
            } catch {
                job.authorizationLease.cancel()
                if let resolvedCapturedAudio = capturedAudioForCleanup {
                    // Final authorization failed after ownership transferred.
                    // Retry removal without resolving the deferred capture again.
                    scheduleRejectedCapturedAudioRemoval(
                        resolvedCapturedAudio,
                        runID: job.runID
                    )
                    capturedAudioForCleanup = nil
                } else if !captureResolutionStarted {
                    if Task.isCancelled {
                        scheduleCancelledDeferredCaptureCleanup(
                            job.deferredCapture,
                            runID: job.runID
                        )
                    } else {
                        scheduleRejectedCaptureCleanup(
                            job.deferredCapture,
                            runID: job.runID
                        )
                    }
                }
                if !Task.isCancelled {
                    await eventBus.publish(
                        .runFailed(
                            runID: job.runID,
                            workflow: job.workflow.presentation,
                            message: error.localizedDescription
                        )
                    )
                    await recordDiagnostic(
                        event: "audio-processing.failed",
                        message: "Queued audio processing failed.",
                        runID: job.runID,
                        level: .error
                    )
                }
            }

            _ = try? await job.bufferReservation.value
            await sessionCoordinator.finishCollectedSpeech(runID: job.runID)
            if let capturedAudioForCleanup {
                await removeManagedTemporaryFile(from: capturedAudioForCleanup, for: job)
            }

            activeJob = nil
            await publishSnapshot()
        }
    }

    private func drainDidFinish(generation: UInt64) {
        guard generation == drainGeneration else { return }
        drainTask = nil
        ensureDrainTask()
    }

    private func awaitRejectedCleanupTasks(runID: UUID? = nil) async {
        while true {
            let tasks: [Task<Void, Never>] = rejectedCleanupTasks.values.compactMap { work in
                guard runID == nil || work.runID == runID else { return nil }
                return work.task
            }
            guard !tasks.isEmpty else { return }
            for task in tasks {
                await task.value
            }
        }
    }

    private func publishSnapshot() async {
        guard publishesSnapshots else { return }
        await eventBus.publish(.audioProcessingQueueUpdated(snapshot()))
    }

    private func preserveBenchmarkRecordingIfEnabled(
        _ capturedAudio: CapturedAudio,
        outcome: WorkflowRunExecutionResult,
        for job: Job
    ) async {
        guard let benchmarkRecordingArchiveController else { return }
        let archiveOutcome: BenchmarkRecordingOutcome =
            switch outcome {
            case .completed:
                .completed
            case .cancelled:
                .cancelled
            case .failed:
                .failed
            }
        var metadata = capturedAudio.metadata
        metadata["recognizerID"] = job.workflow.plan.setup.speechRoute?.recognizerID
        do {
            _ = try await benchmarkRecordingArchiveController.preserveIfEnabled(
                audio: capturedAudio,
                runID: job.runID,
                workflowID: job.workflow.id,
                trigger: Self.runTriggerKind(for: job.triggerEvent),
                outcome: archiveOutcome,
                metadata: metadata
            )
        } catch {
            await recordDiagnostic(
                event: "benchmark-recording.preserve-failed",
                message: "The recording could not be retained for the private ASR benchmark.",
                runID: job.runID,
                level: .warning,
                metadata: ["reason": "storage-unavailable"]
            )
        }
    }

    private static func runTriggerKind(
        for triggerEvent: WorkflowTriggerEvent?
    ) -> WorkflowRunTriggerKind {
        guard let triggerEvent else { return .manual }
        switch triggerEvent.binding {
        case .manual:
            return .manual
        case .menuBar:
            return .menuBar
        case .hotkey:
            return .hotkey
        case .wakeWord:
            return .wakeWord
        }
    }

    private func preserveFailedAudioIfEligible(
        _ capturedAudio: CapturedAudio,
        failure: WorkflowRunFailureSummary,
        for job: Job
    ) async {
        guard failure.isCapturedAudioRecoveryEligible,
              capturedAudio.fileOwnership == .managedTemporary,
              let failedAudioRecoveryController else {
            return
        }
        do {
            guard try await failedAudioRecoveryController.preserveIfEnabled(
                audio: capturedAudio,
                originalRunID: job.runID,
                workflowID: job.workflow.id,
                failure: failure,
                now: Date()
            ) != nil else {
                return
            }
            await recordDiagnostic(
                event: "audio-recovery.preserved",
                message: "A failed recording was protected for manual retry.",
                runID: job.runID,
                metadata: [
                    "reason": failure.code.rawValue,
                    "stage": failure.stage.rawValue,
                ]
            )
        } catch {
            let recoveryError = (error as? FailedAudioRecoveryError) ?? .storageUnavailable
            _ = try? await failedAudioRecoveryController.currentReceipts()
            await eventBus.publish(
                .failedAudioRecoveryUnavailable(
                    runID: job.runID,
                    reason: recoveryError
                )
            )
            await recordDiagnostic(
                event: "audio-recovery.preserve-failed",
                message: "A failed recording could not be retained for recovery.",
                runID: job.runID,
                level: .warning,
                metadata: [
                    "reason": Self.recoveryFailureReason(for: recoveryError),
                    "stage": failure.stage.rawValue,
                ]
            )
        }
    }

    private static func recoveryFailureReason(for error: Error) -> String {
        guard let recoveryError = error as? FailedAudioRecoveryError else {
            return "storage-unavailable"
        }
        switch recoveryError {
        case .entryTooLarge:
            return "entry-too-large"
        case .expired:
            return "expired"
        case .invalidEntry:
            return "invalid-entry"
        case .notFound:
            return "not-found"
        case .protectionUnavailable:
            return "protection-unavailable"
        case .retryOutcomeUnknown:
            return "retry-outcome-unknown"
        case .storageUnavailable:
            return "storage-unavailable"
        case .unsupportedPayload:
            return "unsupported-payload"
        }
    }

    private func removeManagedTemporaryFile(from capturedAudio: CapturedAudio, for job: Job) async {
        guard capturedAudio.fileOwnership == .managedTemporary else { return }
        do {
            try await rejectedCapturedAudioRemoval(capturedAudio)
            await recordDiagnostic(
                event: "audio-processing.temporary-file-removed",
                message: "Removed the managed temporary audio file after processing.",
                runID: job.runID,
                metadata: ["workflow": job.workflow.name]
            )
        } catch {
            // A transient unlink failure must not leave an unencrypted recording
            // outside the queue's shutdown barrier. Reuse the queue-owned cleanup
            // retry path so cancel(runID:) and application shutdown both wait for
            // the managed file to be removed or explicitly cancel the retry.
            scheduleRejectedCapturedAudioRemoval(capturedAudio, runID: job.runID)
            await recordDiagnostic(
                event: "audio-processing.temporary-file-removal-failed",
                message: "Managed temporary audio cleanup remains pending.",
                runID: job.runID,
                level: .error,
                metadata: ["workflow": job.workflow.name]
            )
        }
    }

    private func recordDiagnostic(
        event: String,
        message: String,
        runID: UUID,
        level: DiagnosticLevel = .debug,
        metadata: [String: String] = [:]
    ) async {
        guard let diagnostics else { return }
        await diagnostics.record(
            DiagnosticEvent(
                runID: runID,
                subsystem: .session,
                level: level,
                event: event,
                message: message,
                metadata: metadata.merging(["lane": lane.rawValue]) { current, _ in current }
            )
        )
    }
}
