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
    case contextCaptured(ContextSnapshot)
    case recognitionCompleted(RecognitionResult)
    case liveSubtitleUpdated(LiveSubtitleSnapshot)
    case audioProcessingQueueUpdated(AudioProcessingQueueSnapshot)
    case failedAudioRecoveryUpdated([FailedAudioRecoveryReceipt])
    case failedAudioRecoveryUnavailable(runID: UUID, reason: FailedAudioRecoveryError)
    case candidateResolutionRequested(CandidateResolutionCase)
    case candidateResolutionFinished(caseID: UUID, resolvedText: String)
    case transformationApplied(stepID: UUID, text: String)
    case actionExecuted(actionID: String, result: ActionResult)
    case stackUpdated(DeliveryStackSnapshot)
    case clipboardUpdated(ClipboardStoreSnapshot)
    case clipboardGroupEvent(ClipboardGroupEventDescriptor)
    case clipboardPanelRequested
    /// Invalidates subscriber snapshots after a terminal receipt is accepted.
    /// Repository membership may already have changed again by delivery time.
    case runReceiptRepositoryChanged(WorkflowRunReceiptRepositoryChange)
    case runCompleted(WorkflowRunSummary)
    case runCancelled(WorkflowRunCancelledSummary)
    case runFailed(runID: UUID?, workflow: WorkflowPresentation?, message: String)
    case diagnostic(DiagnosticEvent)
}
