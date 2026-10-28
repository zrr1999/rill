import AppKit
import Foundation
import RillCore
import RillWorkflows
import RillRecords
import RillKnowledge

extension AppModel {
  func synchronizeWorkflowEnabledStates() { workflowLibrary.synchronizeWorkflowEnabledStates() }
  func triggerRequiresExclusiveBinding(_ trigger: TriggerBinding) -> Bool {
    workflowLibrary.triggerRequiresExclusiveBinding(trigger)
  }
  func conflictingEnabledWorkflowsForActivation(of workflow: WorkflowDefinition)
    -> [WorkflowDefinition]
  {
    workflowLibrary.conflictingEnabledWorkflowsForActivation(of: workflow)
  }

  func resolvedWorkflowForExecution(
    _ workflow: WorkflowDefinition,
    trigger: TriggerBinding
  ) -> WorkflowDefinition? {
    let recognizerResolution = WorkflowRecognizerResolution.localSpeech
    guard let workflow = try? workflowApplyingOutputState(workflow) else { return nil }

    switch WorkflowExecutionPlanResolver.resolve(
      workflow,
      initiatedBy: trigger,
      recognizer: recognizerResolution
    ) {
    case .resolved(let plan):
      return plan.executionWorkflow
    case .blocked:
      return nil
    }
  }
}
