import Foundation

public enum VoxTypeEvent: Sendable, Equatable {
    case runStarted(RunSnapshot)
    case contextCaptured(ContextSnapshot)
    case recognitionCompleted(RecognitionResult)
    case candidateResolutionRequested(CandidateResolutionCase)
    case candidateResolutionFinished(caseID: UUID, resolvedText: String)
    case transformationApplied(stepID: UUID, text: String)
    case actionExecuted(actionID: String, result: ActionResult)
    case stackUpdated(DeliveryStackSnapshot)
    case clipboardUpdated(ClipboardStoreSnapshot)
    case clipboardPanelRequested
    case runCompleted(WorkflowRunSummary)
    case runFailed(runID: UUID?, workflow: WorkflowPresentation?, message: String)
    case diagnostic(DiagnosticEvent)
}
