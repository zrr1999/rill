import Foundation
import RillCore
import RillRuntime

extension AppModel {
  func rebuildWorkflowLibrary() {
    invalidateWorkflowExplanation()
    let builtInWorkflowIDs = Set(builtInWorkflows.map(\.id))
    let builtInOverridesByID = Dictionary(
      uniqueKeysWithValues: customWorkflows
        .filter { builtInWorkflowIDs.contains($0.id) }
        .map { ($0.id, $0) }
    )
    let sortedCustomWorkflows = customWorkflows
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
      workflowApplyingVocabularyCustomization($0)
    }
    synchronizeWorkflowEnabledStates()
    workflowLibraryChangedAction()
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
    _ workflow: WorkflowDefinition
  ) -> WorkflowDefinition {
    if workflowFileURLsByID[workflow.id] != nil { return workflow }
    var workflow = workflow
    if let customization = workflowCustomizations.first(where: {
      $0.workflowID == workflow.id
    }), let bindings = customization.vocabularyBindings {
      workflow.plan.setup.vocabularyBindings = bindings
    } else if workflow.plan.setup.speechRoute != nil {
      workflow.plan.setup.vocabularyBindings = vocabularyCollectionBindings
    }
    return workflow
  }

  func persistCustomWorkflows() {
    persistWorkflowLibrary()
  }

  func persistWorkflowLibrary() {
    markSettingModifiedDuringInitialLoad(Self.workflowLibrarySettingKey)
    guard !isRestoringSettings, isWorkflowLibraryAvailable else { return }
    let document = WorkflowLibraryDocument(
      customWorkflows: usesWorkflowFilesAsSource ? [] : customWorkflows,
      customizations: workflowCustomizations
    )
    persistRetryableSettingsStoreWrite(
      for: Self.workflowLibrarySettingKey,
      category: .workflows
    ) { settingsStore in
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(document)
      try await settingsStore.setString(
        String(decoding: data, as: UTF8.self),
        forKey: Self.workflowLibrarySettingKey
      )
    }
  }

  static func loadCustomWorkflows(
    from rawValue: String?
  ) throws -> [WorkflowDefinition] {
    guard let rawValue, !rawValue.isEmpty else { return [] }
    let data = Data(rawValue.utf8)
    let decoded = try JSONDecoder().decode([WorkflowDefinition].self, from: data)
    guard Set(decoded.map(\.id)).count == decoded.count else {
      throw StoredSettingsCollectionValidationError.duplicateIdentifier
    }
    return decoded.map(Self.normalizeCustomWorkflow)
  }

  static func loadWorkflowLibrary(
    from rawValue: String?
  ) throws -> WorkflowLibraryDocument? {
    guard let rawValue, !rawValue.isEmpty else { return nil }
    let document = try JSONDecoder().decode(
      WorkflowLibraryDocument.self,
      from: Data(rawValue.utf8)
    )
    guard document.schemaVersion == WorkflowLibraryDocument.currentSchemaVersion else {
      throw StoredSettingsCollectionValidationError.invalidIdentifier
    }
    guard Set(document.customWorkflows.map(\.id)).count
      == document.customWorkflows.count
    else {
      throw StoredSettingsCollectionValidationError.duplicateIdentifier
    }
    guard Set(document.customizations.map(\.workflowID)).count
      == document.customizations.count
    else {
      throw StoredSettingsCollectionValidationError.duplicateIdentifier
    }
    for workflow in document.customWorkflows {
      let input: WorkflowPlanInput =
        workflow.plan.setup.speechRoute == nil ? .text : .audio
      try WorkflowPlanValidator.validate(workflow.plan, input: input)
    }
    for customization in document.customizations {
      guard let bindings = customization.vocabularyBindings else { continue }
      guard Set(bindings.map(\.id)).count == bindings.count else {
        throw StoredSettingsCollectionValidationError.duplicateIdentifier
      }
    }
    var normalized = document
    normalized.customWorkflows = normalized.customWorkflows.map(Self.normalizeCustomWorkflow)
    return normalized
  }

}
