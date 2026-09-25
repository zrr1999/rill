import Foundation
import RillCore
import RillRuntime

extension AppModel {
  func addVocabularyRule(
    kind: VocabularyRuleKind, pattern: String, replacement: String, matchMode: VocabularyMatchMode,
    caseSensitive: Bool, scope: VocabularyRuleScope, priority: Int = 0
  ) {
    mutateVocabulary {
      $0.addVocabularyRule(
        kind: kind, pattern: pattern, replacement: replacement, matchMode: matchMode,
        caseSensitive: caseSensitive, scope: scope, priority: priority)
    }
  }
  func createVocabularyCollection(named name: String) {
    mutateVocabulary { $0.createVocabularyCollection(named: name) }
  }
  func setVocabularyCollectionEnabled(_ id: UUID, isEnabled: Bool) {
    mutateVocabulary { $0.setVocabularyCollectionEnabled(id, isEnabled: isEnabled) }
  }
  func addVocabularyEntry(
    to id: UUID, kind: VocabularyRuleKind, pattern: String, replacement: String = ""
  ) {
    mutateVocabulary {
      $0.addVocabularyEntry(to: id, kind: kind, pattern: pattern, replacement: replacement)
    }
  }
  func deleteVocabularyEntry(_ id: UUID, from collectionID: UUID) {
    mutateVocabulary { $0.deleteVocabularyEntry(id, from: collectionID) }
  }
  @discardableResult public func saveVocabularyCorrectionRule(_ rule: VocabularyRule)
    -> VocabularyCorrectionSaveOutcome
  {
    saveVocabularyCorrectionRule(rule, to: nil)
  }
  @discardableResult public func saveVocabularyCorrectionRule(
    _ rule: VocabularyRule, to collectionID: UUID?
  ) -> VocabularyCorrectionSaveOutcome {
    mutateVocabulary { $0.saveVocabularyCorrectionRule(rule, to: collectionID) }
  }
  func vocabularyCollectionIDs(compatibleWith scope: VocabularyRuleScope) -> [UUID] {
    vocabulary.vocabularyCollectionIDs(compatibleWith: scope)
  }
  func setVocabularyRuleEnabled(_ id: UUID, isEnabled: Bool) {
    mutateVocabulary { $0.setVocabularyRuleEnabled(id, isEnabled: isEnabled) }
  }
  func deleteVocabularyRule(_ id: UUID) {
    mutateVocabulary { $0.deleteVocabularyRule(id) }
  }

  private func mutateVocabulary<Result>(_ mutation: (VocabularyLibraryModel) -> Result) -> Result {
    let revision = vocabulary.revision
    let result = mutation(vocabulary)
    if vocabulary.revision != revision {
      rebuildWorkflowLibrary()
      persistVocabularyLibrary()
    }
    return result
  }

  func deleteVocabularyCollection(_ collectionID: UUID) {
    guard !self.settings.isLoading, areVocabularyRulesAvailable,
      collectionID != VocabularyCollection.personalID,
      self.vocabulary.vocabularyCollections.contains(where: { $0.id == collectionID })
    else { return }
    self.vocabulary.vocabularyCollections.removeAll { $0.id == collectionID }
    self.vocabulary.vocabularyCollectionBindings.removeAll { $0.collectionID == collectionID }
    self.workflowLibrary.workflowCustomizations = self.workflowLibrary.workflowCustomizations.map { customization in
      var customization = customization
      customization.vocabularyBindings?.removeAll {
        $0.collectionID == collectionID
      }
      return customization
    }
    commitVocabularyLibraryChange()
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

  private func commitVocabularyLibraryChange() {
    guard !self.settings.isLoading, areVocabularyRulesAvailable else { return }
    vocabulary.commit()
    rebuildWorkflowLibrary()
    persistVocabularyLibrary()
  }

}
