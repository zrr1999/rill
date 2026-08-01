import Foundation
import RillCore
import RillRuntime

extension AppModel {
    public func explainWorkflowBeforeRun(_ requestedWorkflow: WorkflowDefinition) {
        cancelWorkflowExplanation()

        guard let workflow = workflows.first(where: { $0.id == requestedWorkflow.id }) else {
            workflowExplanationState = .failed(
                workflowID: requestedWorkflow.id,
                reason: .workflowUnavailable
            )
            return
        }

        let recognizerResolution = WorkflowRecognizerResolution.localSpeech
        let outputResolution: WorkflowOutputResolution
        switch builtinPushToTalkOutputMode {
        case .pasteIntoApp:
            outputResolution = .builtinPasteIntoApplication
        case .saveToVoiceGroup:
            outputResolution = .builtinSaveToVoiceGroup
        }

        let generation = workflowExplanationGeneration
        switch WorkflowExecutionPlanResolver.resolve(
            workflow,
            initiatedBy: .manual,
            recognizer: recognizerResolution,
            output: outputResolution
        ) {
        case .blocked(let receipt):
            finishWorkflowExplanation(
                receipt,
                workflowID: workflow.id,
                generation: generation
            )
        case .resolved(let plan):
            workflowExplanationState = .loading(workflowID: workflow.id)
            let explain = explainResolvedWorkflowAction
            let task = Task { @MainActor [weak self, explain] in
                do {
                    let receipt = try await explain(plan)
                    try Task.checkCancellation()
                    self?.finishWorkflowExplanation(
                        receipt,
                        workflowID: workflow.id,
                        generation: generation
                    )
                } catch is CancellationError {
                    return
                } catch {
                    self?.failWorkflowExplanation(
                        workflowID: workflow.id,
                        generation: generation,
                        reason: .providerUnavailable
                    )
                }
            }
            workflowExplanationTaskOwner.replace(with: task)
        }
    }

    public func cancelWorkflowExplanation() {
        workflowExplanationGeneration += 1
        workflowExplanationTaskOwner.cancel()
        workflowExplanationState = .idle
    }

    func invalidateWorkflowExplanation() {
        cancelWorkflowExplanation()
    }

    private func finishWorkflowExplanation(
        _ receipt: WorkflowExplanationReceipt,
        workflowID: UUID,
        generation: Int
    ) {
        guard generation == workflowExplanationGeneration else { return }
        workflowExplanationTaskOwner.clear()

        guard workflows.contains(where: { $0.id == workflowID }) else {
            workflowExplanationState = .failed(
                workflowID: workflowID,
                reason: .workflowUnavailable
            )
            return
        }
        guard receipt.workflowID == workflowID, receipt.trigger == .manual else {
            workflowExplanationState = .failed(
                workflowID: workflowID,
                reason: .invalidReceipt
            )
            return
        }
        workflowExplanationState = .loaded(receipt)
    }

    private func failWorkflowExplanation(
        workflowID: UUID,
        generation: Int,
        reason: WorkflowExplanationFailure
    ) {
        guard generation == workflowExplanationGeneration else { return }
        workflowExplanationTaskOwner.clear()
        workflowExplanationState = .failed(workflowID: workflowID, reason: reason)
    }

    nonisolated static func unavailableWorkflowExplanation(
        for plan: WorkflowResolvedExecutionPlan
    ) -> WorkflowExplanationReceipt {
        WorkflowExplanationReceipt(
            workflowID: plan.executionWorkflow.id,
            trigger: .manual,
            inputs: [],
            transforms: [],
            outputs: [],
            processingDestinations: [],
            status: .blocked,
            issues: [
                WorkflowExplanationIssue(
                    kind: .privacyEvaluationUnavailable,
                    component: .privacyPolicy
                ),
            ]
        )
    }
}
