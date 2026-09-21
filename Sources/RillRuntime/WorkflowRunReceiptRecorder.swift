import Dispatch
import Foundation
import RillCore

public enum WorkflowRunReceiptRecorderError: Error, Sendable, Equatable {
    case runAlreadyStarted(runID: UUID)
    case runNotStarted(runID: UUID)
    case terminalAlreadyFinalized(runID: UUID)
    case terminalAlreadyPrepared(runID: UUID)
    case terminalWriteInProgress(runID: UUID)
    case actionAlreadyInProgress(runID: UUID)
    case actionNotInProgress(runID: UUID)
    case unexpectedActionIndex(expected: Int, actual: Int)
    case actionIndexMismatch(expected: Int, actual: Int)
    case terminalWhileActionInProgress(runID: UUID)
    case conflictingPreparedTerminal(runID: UUID)
    case persistenceFailed(runID: UUID)
    case writeObsoletedByClearBarrier(runID: UUID)
}

/// The sole builder for immutable terminal run receipts.
///
/// EventBus is deliberately downstream of persistence. Callers begin an
/// attempt, record ordered action results, and finalize it exactly once. If a
/// transient repository write fails, the frozen terminal value remains
/// available for an explicit retry; action timing and the terminal timestamp
/// are not recomputed. A terminal obsoleted by a completed clear is discarded
/// without fan-out or a dead letter.
public actor WorkflowRunReceiptRecorder {
    public typealias WallClock = @Sendable () -> Date
    public typealias MonotonicClock = @Sendable () -> UInt64
    public typealias PersistenceRetryDelay = @Sendable (_ failedAttempt: Int) async -> Void
    static let finalizedRunIDCapacity = 1_024
    static let failedTerminalCapacity = 128

    private struct ActiveAction: Sendable {
        let index: Int
        let startedAtNanoseconds: UInt64
    }

    private struct PreparedTerminal: Sendable {
        let receipt: WorkflowRunReceipt
        let generation: RunHistoryWriteGeneration
        let history: WorkflowResultRecord?
        let historyUpdate: CorrectionHistoryUpdate?
    }

    private struct PendingRun: Sendable {
        let workflowID: UUID?
        let trigger: WorkflowRunTriggerKind
        let startedAtNanoseconds: UInt64
        let historyWorkflow: WorkflowDefinition?
        var finalText: String?
        var correctionSource: RecognitionCorrectionSource?
        var textSteps: [WorkflowTextStep] = []
        var historyUpdate: CorrectionHistoryUpdate?
        var nextActionIndex = 0
        var recordingDurationMilliseconds: UInt64?
        var activeAction: ActiveAction?
        var actionDetails: [WorkflowActionReceipt] = []
        var activeStep: (index: Int, kind: WorkflowProcessStepKind, startedAt: UInt64)?
        var stepDetails: [WorkflowStepReceipt] = []
        var detailsTruncated = false
        var preparedTerminal: PreparedTerminal?
        var terminalWriteIsInProgress = false
    }

    private let repository: any WorkflowRunReceiptRepository
    private let eventBus: EventBus?
    private let diagnostics: DiagnosticsRecorder?
    private let wallClock: WallClock
    private let monotonicClock: MonotonicClock
    private let maximumPersistenceAttempts: Int
    private let persistenceRetryDelay: PersistenceRetryDelay
    private var pendingRuns: [UUID: PendingRun] = [:]
    private var beginningRunIDs: Set<UUID> = []
    private var finalizedRunIDs: Set<UUID> = []
    private var finalizedRunIDOrder: [UUID] = []
    private var failedTerminals: [UUID: PreparedTerminal] = [:]
    private var failedTerminalOrder: [UUID] = []
    private var retryingFailedTerminalRunIDs: Set<UUID> = []

    public init(
        repository: any WorkflowRunReceiptRepository,
        eventBus: EventBus? = nil,
        diagnostics: DiagnosticsRecorder? = nil,
        wallClock: @escaping WallClock = { Date() },
        monotonicClock: @escaping MonotonicClock = {
            DispatchTime.now().uptimeNanoseconds
        },
        maximumPersistenceAttempts: Int = 3,
        persistenceRetryDelay: @escaping PersistenceRetryDelay = { failedAttempt in
            let delay: Duration = failedAttempt == 1 ? .milliseconds(25) : .milliseconds(100)
            try? await Task.sleep(for: delay)
        }
    ) {
        self.repository = repository
        self.eventBus = eventBus
        self.diagnostics = diagnostics
        self.wallClock = wallClock
        self.monotonicClock = monotonicClock
        self.maximumPersistenceAttempts = max(1, maximumPersistenceAttempts)
        self.persistenceRetryDelay = persistenceRetryDelay
    }

    public func begin(
        runID: UUID,
        workflowID: UUID?,
        trigger: WorkflowRunTriggerKind,
        historyWorkflow: WorkflowDefinition? = nil,
        recordingDurationSeconds: Double? = nil
    ) async throws {
        await retryOneFailedTerminalIfPossible()
        guard !finalizedRunIDs.contains(runID) else {
            throw WorkflowRunReceiptRecorderError.terminalAlreadyFinalized(runID: runID)
        }
        guard pendingRuns[runID] == nil, !beginningRunIDs.contains(runID) else {
            throw WorkflowRunReceiptRecorderError.runAlreadyStarted(runID: runID)
        }
        beginningRunIDs.insert(runID)

        var existingReceipts: [WorkflowRunReceipt] = []
        do {
            existingReceipts = try await repository.receipts(
                matching: WorkflowRunReceiptQuery(runID: runID, limit: 1)
            )
        } catch {
            await recordPersistenceFailureDiagnostic(runID: runID)
        }
        beginningRunIDs.remove(runID)
        guard existingReceipts.isEmpty else {
            rememberFinalizedRunID(runID)
            throw WorkflowRunReceiptRecorderError.terminalAlreadyFinalized(runID: runID)
        }

        var run = PendingRun(
            workflowID: workflowID,
            trigger: trigger,
            startedAtNanoseconds: monotonicClock(),
            historyWorkflow: historyWorkflow
        )
        if let seconds = recordingDurationSeconds,
           seconds.isFinite, seconds >= 0, seconds * 1_000 < Double(UInt64.max) {
            run.recordingDurationMilliseconds = UInt64((seconds * 1_000).rounded(.down))
        }
        pendingRuns[runID] = run
    }

    public func recordTextStep(runID: UUID, step: WorkflowTextStep) {
        guard var run = pendingRuns[runID], run.preparedTerminal == nil else { return }
        run.textSteps.append(step)
        pendingRuns[runID] = run
    }

    public func recordResult(
        runID: UUID, finalText: String, correctionSource: RecognitionCorrectionSource?,
        historyUpdate: CorrectionHistoryUpdate?
    ) {
        guard var run = pendingRuns[runID], run.preparedTerminal == nil else { return }
        run.finalText = finalText
        run.correctionSource = correctionSource
        run.historyUpdate = historyUpdate
        pendingRuns[runID] = run
    }

    private func historyRecord(for run: PendingRun, runID: UUID, timestamp: Date,
                               termination: WorkflowRunTermination) -> WorkflowResultRecord? {
        guard run.trigger.isVoiceCapture, let workflow = run.historyWorkflow,
              termination.outcome != .cancelled else { return nil }
        let completed = termination.outcome == .completed
        let failureMessage: String?
        if case .failed(_, .noSpeech) = termination { failureMessage = HistoryFailureSanitizer.noSpeechMessage }
        else { failureMessage = completed ? nil : HistoryFailureSanitizer.genericMessage }
        let source = run.correctionSource ?? (run.textSteps.isEmpty ? nil : RecognitionCorrectionSource(
            preMappingText: run.textSteps.first?.outputText ?? "", context: VocabularyRuleContext(),
            processingSteps: run.textSteps
        ))
        return WorkflowResultRecord(
            id: runID, runID: runID, workflowID: workflow.id, workflow: workflow.presentation,
            finalText: run.finalText,
            failureMessage: failureMessage,
            timestamp: timestamp, isRecordRelated: workflow.plan.output.deliveryPolicy.strategy == .collectionFirst,
            outcome: completed ? .completed : .failed, correctionSource: source, trigger: run.trigger
        )
    }

    public func beginStep(runID: UUID, stepIndex: Int, kind: WorkflowProcessStepKind) throws {
        var run = try mutablePendingRun(runID: runID)
        guard run.preparedTerminal == nil, run.activeStep == nil,
              (0..<256).contains(stepIndex), !run.stepDetails.contains(where: { $0.stepIndex == stepIndex }) else {
            throw WorkflowRunReceiptValidationError.invalidStepSequence
        }
        run.activeStep = (stepIndex, kind, monotonicClock())
        pendingRuns[runID] = run
    }

    public func finishStep(runID: UUID, result: WorkflowStepResultCode, durationMilliseconds: UInt64? = nil) throws {
        var run = try mutablePendingRun(runID: runID)
        guard let step = run.activeStep, run.preparedTerminal == nil else {
            throw WorkflowRunReceiptValidationError.invalidStepSequence
        }
        run.stepDetails.append(WorkflowStepReceipt(
            stepIndex: step.index, kind: step.kind, result: result,
            duration: Self.durationBucket(from: step.startedAt, to: monotonicClock()),
            durationMilliseconds: durationMilliseconds
        ))
        run.activeStep = nil
        pendingRuns[runID] = run
    }

    public func beginAction(runID: UUID, actionIndex: Int) throws {
        var run = try mutablePendingRun(runID: runID)
        guard run.preparedTerminal == nil else {
            throw WorkflowRunReceiptRecorderError.terminalAlreadyPrepared(runID: runID)
        }
        guard !run.terminalWriteIsInProgress else {
            throw WorkflowRunReceiptRecorderError.terminalWriteInProgress(runID: runID)
        }
        guard run.activeAction == nil else {
            throw WorkflowRunReceiptRecorderError.actionAlreadyInProgress(runID: runID)
        }
        guard actionIndex == run.nextActionIndex else {
            throw WorkflowRunReceiptRecorderError.unexpectedActionIndex(
                expected: run.nextActionIndex,
                actual: actionIndex
            )
        }
        run.activeAction = ActiveAction(
            index: actionIndex,
            startedAtNanoseconds: monotonicClock()
        )
        pendingRuns[runID] = run
    }

    public func finishAction(
        runID: UUID,
        actionIndex: Int,
        result: WorkflowActionResultCode
    ) throws {
        var run = try mutablePendingRun(runID: runID)
        guard run.preparedTerminal == nil else {
            throw WorkflowRunReceiptRecorderError.terminalAlreadyPrepared(runID: runID)
        }
        guard !run.terminalWriteIsInProgress else {
            throw WorkflowRunReceiptRecorderError.terminalWriteInProgress(runID: runID)
        }
        guard let activeAction = run.activeAction else {
            throw WorkflowRunReceiptRecorderError.actionNotInProgress(runID: runID)
        }
        guard actionIndex == activeAction.index else {
            throw WorkflowRunReceiptRecorderError.actionIndexMismatch(
                expected: activeAction.index,
                actual: actionIndex
            )
        }

        let finishedAt = monotonicClock()
        let detail = WorkflowActionReceipt(
            actionIndex: actionIndex,
            result: result,
            duration: Self.durationBucket(
                from: activeAction.startedAtNanoseconds,
                to: finishedAt
            ),
            durationMilliseconds: finishedAt >= activeAction.startedAtNanoseconds
                ? (finishedAt - activeAction.startedAtNanoseconds) / 1_000_000 : nil
        )
        if run.actionDetails.count < WorkflowRunReceipt.maximumActionDetails {
            run.actionDetails.append(detail)
        } else {
            run.detailsTruncated = true
        }
        run.nextActionIndex += 1
        run.activeAction = nil
        pendingRuns[runID] = run
    }

    public func finishAction(
        runID: UUID,
        actionIndex: Int,
        result: ActionResult
    ) throws {
        try finishAction(
            runID: runID,
            actionIndex: actionIndex,
            result: WorkflowActionResultCode(result)
        )
    }

    @discardableResult
    public func finish(
        runID: UUID,
        termination: WorkflowRunTermination
    ) async throws -> WorkflowRunReceipt {
        if let failedTerminal = failedTerminals[runID] {
            guard failedTerminal.receipt.termination == termination else {
                throw WorkflowRunReceiptRecorderError.conflictingPreparedTerminal(runID: runID)
            }
            return try await retryFailedTerminal(runID: runID)
        }
        guard !finalizedRunIDs.contains(runID) else {
            throw WorkflowRunReceiptRecorderError.terminalAlreadyFinalized(runID: runID)
        }
        var run = try mutablePendingRun(runID: runID)
        guard run.activeAction == nil else {
            throw WorkflowRunReceiptRecorderError.terminalWhileActionInProgress(runID: runID)
        }
        guard !run.terminalWriteIsInProgress else {
            throw WorkflowRunReceiptRecorderError.terminalWriteInProgress(runID: runID)
        }

        run.terminalWriteIsInProgress = true
        pendingRuns[runID] = run

        let prepared: PreparedTerminal
        if let preparedTerminal = run.preparedTerminal {
            guard preparedTerminal.receipt.termination == termination else {
                throw WorkflowRunReceiptRecorderError.conflictingPreparedTerminal(runID: runID)
            }
            prepared = preparedTerminal
        } else {
            let generation: RunHistoryWriteGeneration
            do {
                generation = try await repository.captureRunHistoryWriteGeneration()
            } catch {
                await recordPersistenceFailureDiagnostic(runID: runID)
                pendingRuns.removeValue(forKey: runID)
                rememberFinalizedRunID(runID)
                if let record = historyRecord(for: run, runID: runID, timestamp: wallClock(), termination: termination) {
                    await eventBus?.publish(.runHistoryUpdated(.sessionOnly(record)))
                }
                throw WorkflowRunReceiptRecorderError.persistenceFailed(runID: runID)
            }
            let receipt = try WorkflowRunReceipt(
                runID: runID,
                workflowID: run.workflowID,
                trigger: run.trigger,
                timestamp: wallClock(),
                duration: Self.durationBucket(
                    from: run.startedAtNanoseconds,
                    to: monotonicClock()
                ),
                termination: termination,
                stepDetails: run.stepDetails.sorted { $0.stepIndex < $1.stepIndex },
                actionDetails: run.actionDetails,
                detailsTruncated: run.detailsTruncated,
                recordingDurationMilliseconds: run.recordingDurationMilliseconds
            )
            prepared = PreparedTerminal(
                receipt: receipt, generation: generation,
                history: historyRecord(for: run, runID: runID, timestamp: receipt.timestamp, termination: termination),
                historyUpdate: run.historyUpdate
            )
            run.preparedTerminal = prepared
            pendingRuns[runID] = run
        }

        do {
            try await persistWithBoundedRetry(prepared)
        } catch {
            if Self.writeWasObsoletedByClearBarrier(error) {
                pendingRuns.removeValue(forKey: runID)
                rememberFinalizedRunID(runID)
                throw WorkflowRunReceiptRecorderError.writeObsoletedByClearBarrier(
                    runID: runID
                )
            }
            await recordPersistenceFailureDiagnostic(runID: runID)
            pendingRuns.removeValue(forKey: runID)
            rememberFinalizedRunID(runID)
            rememberFailedTerminal(prepared)
            if let history = prepared.history { await eventBus?.publish(.runHistoryUpdated(.sessionOnly(history))) }
            throw WorkflowRunReceiptRecorderError.persistenceFailed(runID: runID)
        }

        rememberFinalizedRunID(runID)
        pendingRuns.removeValue(forKey: runID)
        await publishRepositoryChange(for: prepared)
        return prepared.receipt
    }

    /// Retries a bounded in-memory dead letter without recomputing its terminal
    /// timestamp or duration. Production also opportunistically retries one
    /// such receipt when a later run begins.
    @discardableResult
    public func retryFailedTerminal(runID: UUID) async throws -> WorkflowRunReceipt {
        guard let prepared = failedTerminals[runID] else {
            throw WorkflowRunReceiptRecorderError.runNotStarted(runID: runID)
        }
        guard retryingFailedTerminalRunIDs.insert(runID).inserted else {
            throw WorkflowRunReceiptRecorderError.terminalWriteInProgress(runID: runID)
        }
        defer { retryingFailedTerminalRunIDs.remove(runID) }
        do {
            try await persistWithBoundedRetry(prepared)
        } catch {
            if Self.writeWasObsoletedByClearBarrier(error) {
                removeFailedTerminal(runID)
                rememberFinalizedRunID(runID)
                throw WorkflowRunReceiptRecorderError.writeObsoletedByClearBarrier(
                    runID: runID
                )
            }
            await recordPersistenceFailureDiagnostic(runID: runID)
            throw WorkflowRunReceiptRecorderError.persistenceFailed(runID: runID)
        }
        removeFailedTerminal(runID)
        await publishRepositoryChange(for: prepared)
        return prepared.receipt
    }

    private func mutablePendingRun(runID: UUID) throws -> PendingRun {
        guard let run = pendingRuns[runID] else {
            if finalizedRunIDs.contains(runID) {
                throw WorkflowRunReceiptRecorderError.terminalAlreadyFinalized(runID: runID)
            }
            throw WorkflowRunReceiptRecorderError.runNotStarted(runID: runID)
        }
        return run
    }

    func rememberedFinalizedRunIDCount() -> Int {
        finalizedRunIDs.count
    }

    func rememberedFailedTerminalCount() -> Int {
        failedTerminals.count
    }

    func pendingRunCount() -> Int {
        pendingRuns.count
    }

    private func persistWithBoundedRetry(
        _ prepared: PreparedTerminal
    ) async throws {
        for attempt in 1 ... maximumPersistenceAttempts {
            do {
                try await persist(prepared)
                return
            } catch {
                if Self.writeWasObsoletedByClearBarrier(error) {
                    throw error
                }
                guard attempt < maximumPersistenceAttempts else { throw error }
                await persistenceRetryDelay(attempt)
            }
        }
    }

    private func retryOneFailedTerminalIfPossible() async {
        guard let runID = failedTerminalOrder.first,
              let prepared = failedTerminals[runID],
              retryingFailedTerminalRunIDs.insert(runID).inserted else { return }
        defer { retryingFailedTerminalRunIDs.remove(runID) }
        do {
            try await persist(prepared)
        } catch {
            if Self.writeWasObsoletedByClearBarrier(error) {
                removeFailedTerminal(runID)
                rememberFinalizedRunID(runID)
            }
            return
        }
        removeFailedTerminal(runID)
        await publishRepositoryChange(for: prepared)
    }

    private func persist(_ prepared: PreparedTerminal) async throws {
        if let terminalRepository = repository as? any WorkflowRunTerminalRepository {
            try await terminalRepository.commitTerminal(
                prepared.receipt, history: prepared.history, generation: prepared.generation
            )
        } else {
            try await repository.insertTerminal(prepared.receipt, generation: prepared.generation)
        }
    }

    private func publishRepositoryChange(for prepared: PreparedTerminal) async {
        if let history = prepared.history {
            if repository is any WorkflowRunTerminalRepository {
                await prepared.historyUpdate?.historySaved()
                await eventBus?.publish(.runHistoryUpdated(.persisted(runID: prepared.receipt.runID)))
            } else {
                await eventBus?.publish(.runHistoryUpdated(.sessionOnly(history)))
            }
        }
        guard let eventBus else { return }
        let receipt = prepared.receipt
        await eventBus.publish(
            .runReceiptRepositoryChanged(
                WorkflowRunReceiptRepositoryChange(
                    runID: receipt.runID,
                    terminalTimestamp: receipt.timestamp,
                    writeGeneration: prepared.generation
                )
            )
        )
    }

    private func recordPersistenceFailureDiagnostic(runID: UUID) async {
        guard let diagnostics else { return }
        await diagnostics.record(
            DiagnosticEvent(
                runID: runID,
                subsystem: .session,
                level: .error,
                event: "run-receipt.persistence.failed",
                message: "A terminal run receipt could not be persisted."
            )
        )
    }

    private static func writeWasObsoletedByClearBarrier(_ error: any Error) -> Bool {
        if (error as? HistoryRepositoryError) == .writeObsoletedByClearBarrier { return true }
        guard let repositoryError = error as? WorkflowRunReceiptRepositoryError,
              case .writeObsoletedByClearBarrier = repositoryError else {
            return false
        }
        return true
    }

    private func rememberFinalizedRunID(_ runID: UUID) {
        guard finalizedRunIDs.insert(runID).inserted else { return }
        finalizedRunIDOrder.append(runID)
        if finalizedRunIDOrder.count > Self.finalizedRunIDCapacity {
            let evictedRunID = finalizedRunIDOrder.removeFirst()
            finalizedRunIDs.remove(evictedRunID)
        }
    }

    private func rememberFailedTerminal(_ prepared: PreparedTerminal) {
        guard failedTerminals[prepared.receipt.runID] == nil else { return }
        failedTerminals[prepared.receipt.runID] = prepared
        failedTerminalOrder.append(prepared.receipt.runID)
        if failedTerminalOrder.count > Self.failedTerminalCapacity {
            let evictedRunID = failedTerminalOrder.removeFirst()
            failedTerminals.removeValue(forKey: evictedRunID)
        }
    }

    private func removeFailedTerminal(_ runID: UUID) {
        failedTerminals.removeValue(forKey: runID)
        failedTerminalOrder.removeAll { $0 == runID }
    }

    private nonisolated static func durationBucket(
        from start: UInt64,
        to end: UInt64
    ) -> WorkflowRunDurationBucket {
        guard end >= start else { return .unavailable }
        return .classify(elapsedNanoseconds: end - start)
    }
}
