import Foundation
import RillCore
import RillKnowledge
import RillRecords
import RillSpeech
import RillWorkflows

extension AppModel {
  func deleteVocabularyCollection(_ collectionID: UUID) {
    guard !settings.hasBegunApplicationShutdown, !self.settings.isLoading,
      areVocabularyRulesAvailable,
      collectionID != VocabularyCollection.personalID,
      self.vocabulary.vocabularyCollections.contains(where: { $0.id == collectionID })
    else { return }
    self.vocabulary.vocabularyCollections.removeAll { $0.id == collectionID }
    self.vocabulary.vocabularyCollectionBindings.removeAll { $0.collectionID == collectionID }
    for index in workflowLibrary.customWorkflows.indices {
      workflowLibrary.customWorkflows[index].plan.setup.vocabularyBindings.removeAll { $0.collectionID == collectionID }
    }
    vocabulary.commit()
    rebuildWorkflowLibrary()
    persistWorkflowLibrary()
  }

  func setVocabularyBindings(
    _ bindings: [VocabularyCollectionBinding],
    for workflowID: UUID
  ) {
    guard !hasBegunApplicationShutdown, let workflow = workflowLibrary.workflows.first(where: { $0.id == workflowID }) else { return }
    var edited = workflow
    edited.titleKey = nil
    edited.properties.isBuiltin = false
    edited.plan.setup.vocabularyBindings = bindings
    if let index = workflowLibrary.customWorkflows.firstIndex(where: { $0.id == workflowID }) {
      workflowLibrary.customWorkflows[index] = edited
    } else {
      workflowLibrary.customWorkflows.append(edited)
    }
    rebuildWorkflowLibrary()
    persistWorkflowLibrary()
  }

}
