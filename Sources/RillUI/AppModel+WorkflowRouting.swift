import RillWorkflows
import AppKit
import Foundation
import RillCore

extension AppModel {
  func synchronizeWorkflowEnabledStates() { workflowLibrary.synchronizeWorkflowEnabledStates() }
  func normalizeExclusiveWorkflowSelections() {
    workflowLibrary.normalizeExclusiveWorkflowSelections()
  }
  func updateWorkflowTriggerConflicts() { workflowLibrary.updateWorkflowTriggerConflicts() }
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
    let outputResolution: WorkflowOutputResolution
    switch builtinPushToTalkOutputMode {
    case .pasteIntoApp:
      outputResolution = .builtinPasteIntoApplication
    case .saveToVoiceGroup:
      outputResolution = .builtinSaveToVoiceGroup
    }

    switch WorkflowExecutionPlanResolver.resolve(
      workflow,
      initiatedBy: trigger,
      recognizer: recognizerResolution,
      output: outputResolution
    ) {
    case .resolved(let plan):
      return plan.executionWorkflow
    case .blocked:
      return nil
    }
  }
}
