import Foundation
import RillCore
import RillWorkflows
import RillRecords
import RillKnowledge

extension AppModel {
  func rebuildWorkflowLibrary() {
    workflowLibrary.cancelWorkflowExplanation()
    workflowLibrary.rebuild()
    workflowLibraryChangedAction()
  }

  func persistCustomWorkflows() {
    persistWorkflowLibrary()
  }

  func persistWorkflowLibrary() {
    guard !settings.isRestoringSettings, isWorkflowLibraryAvailable, let workflowFileStore else { return }
    let documents = workflowLibrary.customWorkflows.map { workflow in
      WorkflowDocument(workflow: workflow, isEnabled: isWorkflowEnabled(workflow))
    }
    persistenceWrites.replace(for: Self.workflowLibrarySettingKey, debounce: .zero) { [weak self] in
      guard let self else { return }
      for document in documents {
        let (url, source) = await MainActor.run {
          (self.workflowLibrary.workflowFileURLsByID[document.workflow.id], self.workflowLibrary.workflowFileSourcesByID[document.workflow.id])
        }
        let canonical = try workflowFileStore.decodeDocument(workflowFileStore.encodeDocument(document))
        if let source, try workflowFileStore.decodeDocument(source) == canonical { continue }
        let saved = try await workflowFileStore.saveDocument(
          document, replacing: url,
          expected: source.map(WorkflowFileExpectation.source) ?? .missing)
        await MainActor.run {
          self.workflowLibrary.workflowFileURLsByID[document.workflow.id] = saved.fileURL
          self.workflowLibrary.workflowFileSourcesByID[document.workflow.id] = saved.source
        }
      }
    } completion: { [weak self] result in
      guard let self else { return }
      if case .failure(let error) = result {
        self.workflowLibrary.workflowLibraryErrorPresentation = { language in L10n.workflowFileFailureDetail(error, language: language) }
      }
    }
  }
}
