import Foundation
import RillCore
import RillWorkflows
import RillRecords
import RillKnowledge

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
    guard !isLoadingSettings, areVocabularyRulesAvailable,
      collectionID != VocabularyCollection.personalID,
      vocabularyCollections.contains(where: { $0.id == collectionID })
    else { return }
    vocabularyCollections.removeAll { $0.id == collectionID }
    vocabularyCollectionBindings.removeAll { $0.collectionID == collectionID }
    workflowCustomizations = workflowCustomizations.map { customization in
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
    if let index = workflowCustomizations.firstIndex(where: {
      $0.workflowID == workflowID
    }) {
      workflowCustomizations[index].vocabularyBindings = bindings
    } else {
      workflowCustomizations.append(
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
    guard !isLoadingSettings, areVocabularyRulesAvailable else { return }
    vocabulary.commit()
    rebuildWorkflowLibrary()
    persistVocabularyLibrary()
  }

}
