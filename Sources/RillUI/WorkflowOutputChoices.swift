import RillCore
import SwiftUI

struct WorkflowOutputChoices: View {
  @Bindable var model: AppModel
  let workflow: WorkflowDefinition

  var body: some View {
    ForEach(Array(workflow.plan.output.actions.enumerated()), id: \.offset) { index, action in
      Toggle(
        isOn: Binding(
          get: { model.isWorkflowOutputEnabled(action, index: index, workflow: workflow) },
          set: { enabled in model.setWorkflowOutputEnabled(enabled, action: action, index: index, workflow: workflow) }
        )
      ) {
        Text(
          action.configuration.buffer == "speech"
            ? L10n.resource("models.output.pending").string(for: model.settings.language)
            : L10n.actionName(action.id, language: model.settings.language))
      }
      .disabled(
        !action.optional || model.workflowLibrary.savingOutputStates.contains(workflow.id)
          || model.workflowLibrary.invalidWorkflowFileIDs.contains(workflow.id)
      )
      .accessibilityIdentifier("workflow.output.\(action.documentID ?? String(index))")
    }
  }
}

extension AppModel {
  var activeVoiceInputWorkflow: WorkflowDefinition? {
    workflowLibrary.workflows.first { $0.properties.gesture == "fn-hold" && isWorkflowEnabled($0) }
  }
}
