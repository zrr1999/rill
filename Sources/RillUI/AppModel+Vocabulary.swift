import Foundation
import RillCore
import RillRuntime

extension AppModel {
  func addVocabularyRule(
    kind: VocabularyRuleKind,
    pattern: String,
    replacement: String,
    matchMode: VocabularyMatchMode,
    caseSensitive: Bool,
    scope: VocabularyRuleScope,
    priority: Int = 0
  ) {
    guard !isLoadingSettings, areVocabularyRulesAvailable else { return }
    let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPattern.isEmpty else { return }
    let rule = VocabularyRule(
      kind: kind,
      enabled: true,
      pattern: trimmedPattern,
      replacement: replacement.trimmingCharacters(in: .whitespacesAndNewlines),
      matchMode: matchMode,
      caseSensitive: caseSensitive,
      scope: scope,
      priority: priority
    )
    insertVocabularyRule(rule)
  }

  func createVocabularyCollection(named name: String) {
    guard !isLoadingSettings, areVocabularyRulesAvailable else { return }
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    vocabularyCollections.append(VocabularyCollection(name: name))
    commitVocabularyLibraryChange()
  }

  func setVocabularyCollectionEnabled(_ collectionID: UUID, isEnabled: Bool) {
    guard let index = vocabularyCollections.firstIndex(where: {
      $0.id == collectionID
    }) else { return }
    vocabularyCollections[index].enabled = isEnabled
    vocabularyCollections[index].updatedAt = Date()
    commitVocabularyLibraryChange()
  }

  func deleteVocabularyCollection(_ collectionID: UUID) {
    guard collectionID != VocabularyCollection.personalID else { return }
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

  func addVocabularyEntry(
    to collectionID: UUID,
    kind: VocabularyRuleKind,
    pattern: String,
    replacement: String = ""
  ) {
    guard let index = vocabularyCollections.firstIndex(where: {
      $0.id == collectionID
    }) else { return }
    let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pattern.isEmpty else { return }
    let content: VocabularyEntryContent =
      kind == .hotword
      ? .hotword(phrase: pattern)
      : .replacement(
        pattern: pattern,
        replacement: replacement.trimmingCharacters(in: .whitespacesAndNewlines),
        matchMode: .exactPhrase,
        caseSensitive: false
      )
    vocabularyCollections[index].entries.append(
      VocabularyEntry(content: content)
    )
    vocabularyCollections[index].updatedAt = Date()
    commitVocabularyLibraryChange()
  }

  func deleteVocabularyEntry(_ entryID: UUID, from collectionID: UUID) {
    guard let index = vocabularyCollections.firstIndex(where: {
      $0.id == collectionID
    }) else { return }
    vocabularyCollections[index].entries.removeAll { $0.id == entryID }
    vocabularyCollections[index].updatedAt = Date()
    commitVocabularyLibraryChange()
  }

  private func commitVocabularyLibraryChange() {
    isApplyingVocabularyLibrary = true
    let scopeByCollectionID = Dictionary(
      uniqueKeysWithValues: vocabularyCollectionBindings.map { binding in
        (
          binding.collectionID,
          VocabularyRuleScope(
            bundleIdentifier: binding.condition.bundleIdentifier,
            recordCollectionID: binding.condition.recordCollectionID,
            locale: binding.condition.locale
          )
        )
      }
    )
    vocabularyRules = Self.sortedVocabularyRules(
      vocabularyCollections.flatMap { collection in
        let scope = scopeByCollectionID[collection.id] ?? VocabularyRuleScope()
        return collection.entries.map { $0.legacyRule(scope: scope) }
      }
    )
    isApplyingVocabularyLibrary = false
    vocabularyRuleSource.updateCollections(vocabularyCollections)
    rebuildWorkflowLibrary()
    persistVocabularyLibrary()
  }

  @discardableResult
  public func saveVocabularyCorrectionRule(_ proposedRule: VocabularyRule)
    -> VocabularyCorrectionSaveOutcome
  {
    saveVocabularyCorrectionRule(proposedRule, to: nil)
  }

  @discardableResult
  public func saveVocabularyCorrectionRule(
    _ proposedRule: VocabularyRule,
    to targetCollectionID: UUID?
  ) -> VocabularyCorrectionSaveOutcome
  {
    guard !isLoadingSettings, areVocabularyRulesAvailable else { return .notReady }
    let pattern = proposedRule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pattern.isEmpty else { return .invalid }

    var rule = proposedRule
    rule.pattern = pattern
    rule.replacement = proposedRule.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    if rule.kind == .hotword {
      rule.replacement = ""
      rule.matchMode = .exactPhrase
      rule.caseSensitive = false
    }

    if let existing = vocabularyRules.first(where: { existing in
      existing.kind == rule.kind && existing.pattern == rule.pattern
        && existing.matchMode == rule.matchMode && existing.caseSensitive == rule.caseSensitive
        && existing.scope == rule.scope
    }) {
      guard existing.replacement == rule.replacement else {
        return .conflict(existingRuleID: existing.id)
      }
      if !existing.enabled {
        setVocabularyRuleEnabled(existing.id, isEnabled: true)
      }
      return .reused(ruleID: existing.id)
    }

    if let targetCollectionID {
      let condition = WorkflowBindingCondition(
        bundleIdentifier: rule.scope.bundleIdentifier,
        recordCollectionID: rule.scope.recordCollectionID,
        locale: rule.scope.locale
      )
      guard vocabularyCollections.contains(where: { $0.id == targetCollectionID }),
        vocabularyCollectionBindings.contains(where: {
          $0.collectionID == targetCollectionID && $0.condition == condition
        })
      else {
        return .invalid
      }
    }

    insertVocabularyRule(rule, targetCollectionID: targetCollectionID)
    return .created(ruleID: rule.id)
  }

  func vocabularyCollectionIDs(compatibleWith scope: VocabularyRuleScope) -> [UUID] {
    let condition = WorkflowBindingCondition(
      bundleIdentifier: scope.bundleIdentifier,
      recordCollectionID: scope.recordCollectionID,
      locale: scope.locale
    )
    let compatibleIDs = Set(
      vocabularyCollectionBindings.lazy
        .filter { $0.condition == condition }
        .map(\.collectionID)
    )
    return vocabularyCollections
      .filter { compatibleIDs.contains($0.id) }
      .map(\.id)
  }

  func setVocabularyRuleEnabled(_ ruleID: UUID, isEnabled: Bool) {
    guard !isLoadingSettings, areVocabularyRulesAvailable else { return }
    for collectionIndex in vocabularyCollections.indices {
      guard let entryIndex = vocabularyCollections[collectionIndex].entries.firstIndex(
        where: { $0.id == ruleID }
      ) else { continue }
      vocabularyCollections[collectionIndex].entries[entryIndex].enabled = isEnabled
      vocabularyCollections[collectionIndex].updatedAt = Date()
      commitVocabularyLibraryChange()
      return
    }
  }

  func deleteVocabularyRule(_ ruleID: UUID) {
    guard !isLoadingSettings, areVocabularyRulesAvailable else { return }
    for index in vocabularyCollections.indices {
      let oldCount = vocabularyCollections[index].entries.count
      vocabularyCollections[index].entries.removeAll { $0.id == ruleID }
      if vocabularyCollections[index].entries.count != oldCount {
        vocabularyCollections[index].updatedAt = Date()
        commitVocabularyLibraryChange()
        return
      }
    }
  }

  private func insertVocabularyRule(
    _ rule: VocabularyRule,
    targetCollectionID: UUID? = nil
  ) {
    let condition = WorkflowBindingCondition(
      bundleIdentifier: rule.scope.bundleIdentifier,
      recordCollectionID: rule.scope.recordCollectionID,
      locale: rule.scope.locale
    )
    let collectionID: UUID
    if let targetCollectionID {
      collectionID = targetCollectionID
    } else if rule.scope == VocabularyRuleScope() {
      collectionID = VocabularyCollection.personalID
    } else if let binding = vocabularyCollectionBindings.first(where: {
      $0.condition == condition
    }) {
      collectionID = binding.collectionID
    } else {
      let migration = VocabularyLegacyMigrator.migrate([rule])
      guard let collection = migration.collections.first,
        let binding = migration.bindings.first
      else { return }
      vocabularyCollections.append(
        VocabularyCollection(
          id: collection.id,
          name: collection.name,
          entries: []
        )
      )
      vocabularyCollectionBindings.append(binding)
      collectionID = collection.id
    }

    if let index = vocabularyCollections.firstIndex(where: {
      $0.id == collectionID
    }) {
      vocabularyCollections[index].entries.append(VocabularyEntry(rule: rule))
      vocabularyCollections[index].updatedAt = Date()
    } else {
      vocabularyCollections.append(
        .personal(entries: [VocabularyEntry(rule: rule)])
      )
    }
    commitVocabularyLibraryChange()
  }

}
