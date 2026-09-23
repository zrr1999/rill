import Foundation
import Observation
import RillCore
import RillRuntime

@MainActor @Observable
public final class WorkflowLibraryModel {
  public internal(set) var builtInWorkflows: [WorkflowDefinition]
  public internal(set) var customWorkflows: [WorkflowDefinition] = []
  public internal(set) var workflows: [WorkflowDefinition]
  public internal(set) var workflowLibraryAvailability: StoredSettingsDomainAvailability =
    .available
  public internal(set) var workflowTriggerConflicts: [WorkflowTriggerConflict] = []
  public internal(set) var workflowConflictIDsByWorkflowID: [UUID: [UUID]] = [:]
  public internal(set) var workflowCustomizations: [WorkflowCustomization] = []
  public internal(set) var workflowEnabledStates: [UUID: Bool] = [:]
  public internal(set) var workflowFileURLsByID: [UUID: URL] = [:]
  public internal(set) var workflowFileSourcesByID: [UUID: String] = [:]
  public internal(set) var workflowFileIssues: [WorkflowFileIssue] = []
  public internal(set) var invalidWorkflowFileIDs: Set<UUID> = []
  public internal(set) var workflowFileLoadGeneration: Int = 0
  public internal(set) var usesWorkflowFilesAsSource: Bool = false
  public internal(set) var hasModifiedWorkflowLibrary: Bool = false
  public internal(set) var workflowLibraryError: String?
  init(workflows: [WorkflowDefinition]) {
    self.builtInWorkflows = workflows
    self.workflows = workflows
  }

  func rebuild(defaultVocabularyBindings: [VocabularyCollectionBinding]) {
    let builtInWorkflowIDs = Set(builtInWorkflows.map(\.id))
    let builtInOverridesByID = Dictionary(
      uniqueKeysWithValues:
        customWorkflows
        .filter { builtInWorkflowIDs.contains($0.id) }
        .map { ($0.id, $0) }
    )
    let sortedCustomWorkflows =
      customWorkflows
      .filter { !builtInWorkflowIDs.contains($0.id) }
      .sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
    // A custom workflow sharing a built-in's display name shadows that
    // built-in: listing both would read as duplication. The built-in returns
    // when the custom is deleted. Matching covers every localized display
    // variant so the result does not depend on the UI language.
    let customShadowNameKeys = Set(sortedCustomWorkflows.flatMap(workflowShadowNameKeys))
    let effectiveBuiltInWorkflows = builtInWorkflows.compactMap {
      builtIn -> WorkflowDefinition? in
      if let override = builtInOverridesByID[builtIn.id] { return override }
      guard workflowShadowNameKeys(builtIn).isDisjoint(with: customShadowNameKeys) else {
        return nil
      }
      return builtIn
    }
    workflows = (sortedCustomWorkflows + effectiveBuiltInWorkflows).map {
      workflowApplyingVocabularyCustomization($0, defaultBindings: defaultVocabularyBindings)
    }
    synchronizeWorkflowEnabledStates()
  }

  /// Every display name a workflow can be known by — raw name plus both
  /// localized title-key variants — normalized for collision matching.
  func workflowShadowNameKeys(_ workflow: WorkflowDefinition) -> Set<String> {
    [
      WorkflowNameDuplicationPolicy.normalizedName(workflow.name),
      WorkflowNameDuplicationPolicy.normalizedName(
        UIStrings.workflowName(workflow.presentation, language: .english)
      ),
      WorkflowNameDuplicationPolicy.normalizedName(
        UIStrings.workflowName(workflow.presentation, language: .simplifiedChinese)
      ),
    ]
  }

  private func workflowApplyingVocabularyCustomization(
    _ workflow: WorkflowDefinition, defaultBindings: [VocabularyCollectionBinding]
  ) -> WorkflowDefinition {
    if workflowFileURLsByID[workflow.id] != nil { return workflow }
    var workflow = workflow
    if let customization = workflowCustomizations.first(where: {
      $0.workflowID == workflow.id
    }), let bindings = customization.vocabularyBindings {
      workflow.plan.setup.vocabularyBindings = bindings
    } else if workflow.plan.setup.speechRoute != nil {
      workflow.plan.setup.vocabularyBindings = defaultBindings
    }
    return workflow
  }

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
    let enabledGroups = Dictionary(
      grouping: workflows.filter { workflow in
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
    let grouped = Dictionary(
      grouping: workflows.filter { workflow in
        triggerRequiresExclusiveBinding(workflow.trigger) && isWorkflowEnabled(workflow)
      }, by: \.trigger)

    workflowTriggerConflicts =
      grouped
      .filter { $0.value.count > 1 }
      .map { trigger, workflows in
        WorkflowTriggerConflict(
          trigger: trigger,
          workflowIDs:
            workflows
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
        )
      }
      .sorted { $0.trigger.rawValue < $1.trigger.rawValue }

    workflowConflictIDsByWorkflowID = workflowTriggerConflicts.reduce(into: [:]) {
      result, conflict in
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

  func conflictingEnabledWorkflowsForActivation(of workflow: WorkflowDefinition)
    -> [WorkflowDefinition]
  {
    guard workflow.trigger != .manual else { return [] }
    let exclusiveGroup = workflow.exclusiveGroupIdentifier
    return workflows.filter { candidate in
      candidate.id != workflow.id && candidate.trigger == workflow.trigger
        && !(exclusiveGroup != nil && candidate.exclusiveGroupIdentifier == exclusiveGroup)
        && isWorkflowEnabled(candidate)
    }
  }

  public func isWorkflowEnabled(_ workflow: WorkflowDefinition) -> Bool {
    !invalidWorkflowFileIDs.contains(workflow.id)
      && WorkflowExecutionPolicy.supports(workflow)
      && (workflowEnabledStates[workflow.id] ?? true)
  }

}
