import RillCore

enum WorkflowExplanationSelectionState {
    static func canExplainSavedWorkflow(
        draft: WorkflowEditorDraft,
        selectedWorkflow: WorkflowDefinition?
    ) -> Bool {
        guard
            let selectedWorkflow,
            let savedDraft = WorkflowEditorDraft(workflow: selectedWorkflow)
        else {
            return false
        }
        return draft == savedDraft
    }

    static func unavailableFailure(workflowExists: Bool) -> WorkflowExplanationFailure {
        workflowExists ? .providerUnavailable : .workflowUnavailable
    }
}
