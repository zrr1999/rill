import Foundation
import RillCore
import RillWorkflows
import RillRecords
import RillKnowledge
import RillSpeech

extension WorkflowLibraryModel {
    public func explainWorkflowBeforeRun(_ requestedWorkflow: WorkflowDefinition) {
        guard !settings.hasBegunApplicationShutdown else { return }
        cancelWorkflowExplanation()

        guard let workflow = self.workflows.first(where: { $0.id == requestedWorkflow.id }) else {
            self.workflowExplanationState = .failed(
                workflowID: requestedWorkflow.id,
                reason: .workflowUnavailable
            )
            return
        }

        let recognizerResolution = WorkflowRecognizerResolution.localSpeech
        let outputResolution: WorkflowOutputResolution
        switch self.settings.builtinPushToTalkOutputMode {
        case .pasteIntoApp:
            outputResolution = .builtinPasteIntoApplication
        case .saveToVoiceGroup:
            outputResolution = .builtinSaveToVoiceGroup
        }

        let generation = self.workflowExplanationGeneration
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
            self.workflowExplanationState = .loading(workflowID: workflow.id)
            let explain = explainResolvedWorkflowAction
            let taskID = UUID()
            let taskOwner = self.workflowExplanationTaskOwner
            let task = Task { @MainActor [weak self, explain, taskOwner] in
                defer { taskOwner.finish(id: taskID) }
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
            self.workflowExplanationTaskOwner.replace(id: taskID, with: task)
        }
    }

    public func cancelWorkflowExplanation() {
        self.workflowExplanationGeneration += 1
        self.workflowExplanationTaskOwner.cancel()
        self.workflowExplanationState = .idle
    }

    func waitForWorkflowExplanationTasks() async {
        await self.workflowExplanationTaskOwner.waitUntilIdle()
    }

    private func finishWorkflowExplanation(
        _ receipt: WorkflowExplanationReceipt,
        workflowID: UUID,
        generation: Int
    ) {
        guard generation == self.workflowExplanationGeneration else { return }

        guard self.workflows.contains(where: { $0.id == workflowID }) else {
            self.workflowExplanationState = .failed(
                workflowID: workflowID,
                reason: .workflowUnavailable
            )
            return
        }
        guard receipt.workflowID == workflowID, receipt.trigger == .manual else {
            self.workflowExplanationState = .failed(
                workflowID: workflowID,
                reason: .invalidReceipt
            )
            return
        }
        self.workflowExplanationState = .loaded(receipt)
    }

    private func failWorkflowExplanation(
        workflowID: UUID,
        generation: Int,
        reason: WorkflowExplanationFailure
    ) {
        guard generation == self.workflowExplanationGeneration else { return }
        self.workflowExplanationState = .failed(workflowID: workflowID, reason: reason)
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
