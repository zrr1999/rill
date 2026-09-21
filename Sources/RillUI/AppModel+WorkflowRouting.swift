import AppKit
import Foundation
import RillCore
import RillRuntime

extension AppModel {
    func synchronizeWorkflowEnabledStates() {
        migrateRetiredBuiltinPushToTalkSelection()
        let validWorkflowIDs = Set(workflows.map(\.id))
        workflowEnabledStates = workflowEnabledStates.filter { validWorkflowIDs.contains($0.key) }

        for workflow in workflows {
            if !WorkflowExecutionPolicy.supports(workflow) {
                workflowEnabledStates[workflow.id] = false
            } else if workflowEnabledStates[workflow.id] == nil {
                workflowEnabledStates[workflow.id] = workflow.isEnabledByDefault
            }
        }

        normalizeExclusiveWorkflowSelections()
        updateWorkflowTriggerConflicts()
    }

    private func migrateRetiredBuiltinPushToTalkSelection() {
        guard
            let speechRecognitionID = UUID(
                uuidString: "B9E19A88-F9FB-4AB3-8444-CDBF7E215A88"
            ),
            workflows.contains(where: { $0.id == speechRecognitionID })
        else {
            return
        }
        let retiredIDs = [
            "A8E19A88-F9FB-4AB3-8444-CDBF7E215A88",
            "D1E19A88-F9FB-4AB3-8444-CDBF7E215A88",
        ].compactMap(UUID.init(uuidString:))
        guard retiredIDs.contains(where: { workflowEnabledStates[$0] == true }) else {
            return
        }
        workflowEnabledStates[speechRecognitionID] = true
    }

    func normalizeExclusiveWorkflowSelections() {
        let enabledGroups = Dictionary(grouping: workflows.filter { workflow in
            isWorkflowEnabled(workflow) && workflow.exclusiveGroupIdentifier != nil
        }, by: \.exclusiveGroupIdentifier)

        for (_, members) in enabledGroups {
            guard members.count > 1 else { continue }
            if members.contains(where: { workflowFileURLsByID[$0.id] != nil }) { continue }
            for workflow in members.dropFirst() {
                workflowEnabledStates[workflow.id] = false
            }
        }
    }

    func updateWorkflowTriggerConflicts() {
        let grouped = Dictionary(grouping: workflows.filter { workflow in
            triggerRequiresExclusiveBinding(workflow.trigger) && isWorkflowEnabled(workflow)
        }, by: \.trigger)

        workflowTriggerConflicts = grouped
            .filter { $0.value.count > 1 }
            .map { trigger, workflows in
                WorkflowTriggerConflict(
                    trigger: trigger,
                    workflowIDs: workflows
                        .map(\.id)
                        .sorted { $0.uuidString < $1.uuidString }
                )
            }
            .sorted { $0.trigger.rawValue < $1.trigger.rawValue }

        workflowConflictIDsByWorkflowID = workflowTriggerConflicts.reduce(into: [:]) { result, conflict in
            for workflowID in conflict.workflowIDs {
                result[workflowID] = conflict.workflowIDs.filter { $0 != workflowID }
            }
        }
    }

    func triggerRequiresExclusiveBinding(_ trigger: TriggerBinding) -> Bool {
        switch trigger {
        case .manual, .menuBar:
            return false
        case .hotkey, .wakeWord:
            return true
        }
    }

    func conflictingEnabledWorkflowsForActivation(of workflow: WorkflowDefinition) -> [WorkflowDefinition] {
        guard workflow.trigger != .manual else { return [] }
        let exclusiveGroup = workflow.exclusiveGroupIdentifier
        return workflows.filter { candidate in
            candidate.id != workflow.id &&
                candidate.trigger == workflow.trigger &&
                !(exclusiveGroup != nil && candidate.exclusiveGroupIdentifier == exclusiveGroup) &&
                isWorkflowEnabled(candidate)
        }
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
