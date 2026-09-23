import Foundation
import RillCore
import RillRuntime

extension AppModel {
  func rebuildWorkflowLibrary() {
    invalidateWorkflowExplanation()
    workflowLibrary.rebuild(defaultVocabularyBindings: vocabularyCollectionBindings)
    workflowLibraryChangedAction()
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

}
