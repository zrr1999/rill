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
    self.workflowLibrary.workflowCustomizations = self.workflowLibrary.workflowCustomizations.map {
      customization in
      var customization = customization
      customization.vocabularyBindings?.removeAll {
        $0.collectionID == collectionID
      }
      return customization
    }
    vocabulary.commit()
    persistWorkflowLibrary()
  }

  func setVocabularyBindings(
    _ bindings: [VocabularyCollectionBinding],
    for workflowID: UUID
  ) {
    if let index = self.workflowLibrary.workflowCustomizations.firstIndex(where: {
      $0.workflowID == workflowID
    }) {
      self.workflowLibrary.workflowCustomizations[index].vocabularyBindings = bindings
    } else {
      self.workflowLibrary.workflowCustomizations.append(
        WorkflowCustomization(
          workflowID: workflowID,
          vocabularyBindings: bindings
        )
      )
    }
    rebuildWorkflowLibrary()
    persistWorkflowLibrary()
  }

}
