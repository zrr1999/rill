import Foundation
import RillCore
import RillRuntime

extension AppModel {
  func rebuildWorkflowLibrary() {
    invalidateWorkflowExplanation()
    workflowLibrary.rebuild(defaultVocabularyBindings: self.vocabulary.vocabularyCollectionBindings)
    workflowLibraryChangedAction()
  }

  func persistCustomWorkflows() {
    persistWorkflowLibrary()
  }

  func persistWorkflowLibrary() {
    markSettingModifiedDuringInitialLoad(Self.workflowLibrarySettingKey)
    guard !self.settings.isRestoringSettings, isWorkflowLibraryAvailable else { return }
    let document = WorkflowLibraryDocument(
      customWorkflows: self.workflowLibrary.usesWorkflowFilesAsSource ? [] : self.workflowLibrary.customWorkflows,
      customizations: self.workflowLibrary.workflowCustomizations
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
