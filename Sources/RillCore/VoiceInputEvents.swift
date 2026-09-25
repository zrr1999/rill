import Foundation

/// A content-free invalidation coordinate for the durable run-receipt snapshot.
///
/// The referenced receipt was accepted before this change was emitted, but a
/// concurrent clear may remove it before a subscriber receives the event.
/// Consumers must reload `WorkflowRunReceiptRepository`; this value is never
/// proof that the receipt is still present.
public struct WorkflowRunReceiptRepositoryChange: Sendable, Equatable {
    public let runID: UUID
    public let terminalTimestamp: Date
    /// The content-free logical coordinate captured by the accepted terminal write.
    public let writeGeneration: RunHistoryWriteGeneration?

    public init(
        runID: UUID,
        terminalTimestamp: Date,
        writeGeneration: RunHistoryWriteGeneration? = nil
    ) {
        self.runID = runID
        self.terminalTimestamp = terminalTimestamp
        self.writeGeneration = writeGeneration
    }
}

public enum RillEvent: Sendable, Equatable {
    case runStarted(RunSnapshot)
    case runStageChanged(run: WorkflowRunIdentity, stage: WorkflowRunStage)
    case contextCaptured(run: WorkflowRunIdentity, snapshot: ContextSnapshot)
    case recognitionCompleted(run: WorkflowRunIdentity, result: RecognitionResult)
    case liveSubtitleUpdated(LiveSubtitleSnapshot)
    case audioProcessingQueueUpdated(AudioProcessingQueueSnapshot)
    case failedAudioRecoveryUpdated([FailedAudioRecoveryReceipt])
    case failedAudioRecoveryUnavailable(runID: UUID, reason: FailedAudioRecoveryError)
    case candidateResolutionRequested(CandidateResolutionCase)
    case candidateResolutionFinished(run: WorkflowRunIdentity, caseID: UUID, resolvedText: String)
    case transformationApplied(run: WorkflowRunIdentity, stepID: UUID, text: String)
    case runTextStepRecorded(runID: UUID, step: WorkflowTextStep)
    case actionExecuted(run: WorkflowRunIdentity, actionID: String, result: ActionResult)
    case recordPanelRequested
    /// Invalidates subscriber snapshots after a terminal receipt is accepted.
    /// Repository membership may already have changed again by delivery time.
    case runReceiptRepositoryChanged(WorkflowRunReceiptRepositoryChange)
    case runHistoryUpdated(WorkflowRunHistoryUpdate)
    case runCompleted(WorkflowRunSummary)
    case runCancelled(WorkflowRunCancelledSummary)
    case runFailed(runID: UUID?, workflow: WorkflowPresentation?, message: String)
    case diagnostic(DiagnosticEvent)
}
