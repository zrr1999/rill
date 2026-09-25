import Foundation
import RillCore

struct WorkflowRunReporter: Sendable {
  let diagnostics: DiagnosticsRecorder?
  let eventBus: EventBus
  let lane: WorkflowRunLane
  func recordStage(
    _ stage: WorkflowRunStage,
    runID: UUID,
    workflow: WorkflowPresentation,
    metadata: [String: String] = [:]
  ) async {
    await eventBus.publish(.runStageChanged(run: .init(runID: runID, lane: lane), stage: stage))
    guard let diagnostics else { return }
    await diagnostics.record(
      DiagnosticEvent(
        runID: runID,
        subsystem: .session,
        level: .debug,
        event: "session.stage",
        message: "Workflow entered the \(stage.rawValue) stage.",
        metadata: [
          "stage": stage.rawValue,
          "workflow": workflow.fallbackName,
        ].merging(metadata) { _, new in new }
      )
    )
  }

  func recordTransformStep(
    runID: UUID,
    workflow: WorkflowPresentation,
    step: PostProcessStep,
    transformerID: String
  ) async {
    guard let diagnostics else { return }
    await diagnostics.record(
      DiagnosticEvent(
        runID: runID,
        subsystem: .session,
        level: .debug,
        event: "session.transform.step",
        message: "Applied post-process step \(step.kind.rawValue).",
        metadata: [
          "workflow": workflow.fallbackName,
          "stepID": step.id.uuidString,
          "stepKind": step.kind.rawValue,
          "transformerID": transformerID,
        ]
      )
    )
  }

  func recordAction(
    runID: UUID,
    workflow: WorkflowPresentation,
    actionID: String,
    result: ActionResult,
    durationMilliseconds: String? = nil
  ) async {
    guard let diagnostics else { return }
    await diagnostics.record(
      DiagnosticEvent(
        runID: runID,
        subsystem: .session,
        level: .debug,
        event: "session.action",
        message: "Executed output action \(actionID).",
        metadata: [
          "workflow": workflow.fallbackName,
          "actionID": actionID,
          "resultCode": diagnosticResultCode(for: result),
        ].merging(durationMilliseconds.map { ["durationMillis": $0] } ?? [:]) { _, new in new }
      )
    )
  }

  func diagnosticResultCode(for result: ActionResult) -> String {
    switch result {
    case .injected:
      return "injected"
    case .copiedToClipboard:
      return "copiedToClipboard"
    case .storedRecord:
      return "storedRecord"
    case .externalOutput:
      return "externalOutput"
    case .skipped:
      return "skipped"
    case .failed:
      return "failed"
    }
  }
}
