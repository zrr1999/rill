import RillCore
import SwiftUI

enum WorkflowOutputDisabledReason: Equatable {
  case invalidWorkflow
  case saving
  case required

  var localizationKey: String {
    switch self {
    case .invalidWorkflow: "workflow.outputInvalid"
    case .saving: "workflow.outputSaving"
    case .required: "workflow.outputRequired"
    }
  }

  static func resolve(optional: Bool, saving: Bool, invalid: Bool) -> Self? {
    if invalid { return .invalidWorkflow }
    if saving { return .saving }
    if !optional { return .required }
    return nil
  }
}

struct WorkflowOutputChoices: View {
  @Bindable var model: AppModel
  let workflow: WorkflowDefinition

  var body: some View {
    ForEach(Array(workflow.plan.output.actions.enumerated()), id: \.offset) { index, action in
      let disabledReason = WorkflowOutputDisabledReason.resolve(
        optional: action.optional,
        saving: model.workflowLibrary.savingOutputStates.contains(workflow.id),
        invalid: model.workflowLibrary.invalidWorkflowFileIDs.contains(workflow.id)
      )
      Toggle(
        isOn: Binding(
          get: { model.isWorkflowOutputEnabled(action, index: index, workflow: workflow) },
          set: { enabled in model.setWorkflowOutputEnabled(enabled, action: action, index: index, workflow: workflow) }
        )
      ) {
        VStack(alignment: .leading, spacing: 2) {
          Text(
            action.configuration.buffer == "speech"
              ? L10n.resource("models.output.pending").string(for: model.settings.language)
              : L10n.actionName(action.id, language: model.settings.language))
          if let disabledReason {
            Text(L10n.resource(disabledReason.localizationKey).string(for: model.settings.language))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .disabled(disabledReason != nil)
      .accessibilityIdentifier("workflow.output.\(action.documentID ?? String(index))")
    }
  }
}

extension AppModel {
  var activeVoiceInputWorkflow: WorkflowDefinition? {
    workflowLibrary.workflows.first { $0.properties.gesture == "fn-hold" && isWorkflowEnabled($0) }
  }
}
