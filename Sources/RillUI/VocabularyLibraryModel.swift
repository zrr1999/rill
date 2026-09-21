import Foundation
import Observation
import RillCore
import RillRuntime

@MainActor @Observable
public final class VocabularyLibraryModel {
  public internal(set) var vocabularyRules: [VocabularyRule] = []
  public internal(set) var vocabularyCollections: [VocabularyCollection] = [.personal()]
  public internal(set) var vocabularyCollectionBindings: [VocabularyCollectionBinding] = [
    .init(collectionID: VocabularyCollection.personalID)
  ]
  public internal(set) var availability: StoredSettingsDomainAvailability = .available
  public internal(set) var error: String?
  private(set) var revision = 0
  var isApplying = false
  private let settings: SettingsPersistenceModel
  private let source: VocabularyRuleSource

  init(settings: SettingsPersistenceModel, source: VocabularyRuleSource) {
    self.settings = settings
    self.source = source
  }

  func setLegacyRules(_ rules: [VocabularyRule]) {
    vocabularyRules = rules
    guard !isApplying else { return }
    let migrated = VocabularyLegacyMigrator.migrate(rules)
    vocabularyCollections = migrated.collections
    vocabularyCollectionBindings = migrated.bindings
    source.updateCollections(vocabularyCollections)
  }

  func commit() {
    vocabularyRules = AppSettingsCodec.sortedVocabularyRules(
      VocabularyLegacyMigrator.project(
        vocabularyCollections, bindings: vocabularyCollectionBindings))
    revision += 1
    source.updateCollections(vocabularyCollections)
  }

  func addVocabularyRule(
    kind: VocabularyRuleKind,
    pattern: String,
    replacement: String,
    matchMode: VocabularyMatchMode,
    caseSensitive: Bool,
    scope: VocabularyRuleScope,
    priority: Int = 0
  ) {
    guard !settings.isLoading, availability == .available else { return }
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
    guard !settings.isLoading, availability == .available else { return }
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    vocabularyCollections.append(VocabularyCollection(name: name))
    commit()
  }

  func setVocabularyCollectionEnabled(_ collectionID: UUID, isEnabled: Bool) {
    guard
      let index = vocabularyCollections.firstIndex(where: {
        $0.id == collectionID
      })
    else { return }
    guard vocabularyCollections[index].enabled != isEnabled else { return }
    vocabularyCollections[index].enabled = isEnabled
    vocabularyCollections[index].updatedAt = Date()
    commit()
  }

  func addVocabularyEntry(
    to collectionID: UUID,
    kind: VocabularyRuleKind,
    pattern: String,
    replacement: String = ""
  ) {
    guard
      let index = vocabularyCollections.firstIndex(where: {
        $0.id == collectionID
      })
    else { return }
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
    commit()
  }

  func deleteVocabularyEntry(_ entryID: UUID, from collectionID: UUID) {
    guard
      let index = vocabularyCollections.firstIndex(where: {
        $0.id == collectionID
      })
    else { return }
    guard vocabularyCollections[index].entries.contains(where: { $0.id == entryID }) else { return }
    vocabularyCollections[index].entries.removeAll { $0.id == entryID }
    vocabularyCollections[index].updatedAt = Date()
    commit()
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
  ) -> VocabularyCorrectionSaveOutcome {
    guard !settings.isLoading, availability == .available else { return .notReady }
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

    let compatibleCollections = Set(vocabularyCollectionIDs(compatibleWith: rule.scope))
    let candidates = vocabularyCollections.filter { compatibleCollections.contains($0.id) }
      .flatMap { $0.entries.map { $0.legacyRule(scope: rule.scope) } }
    if let existing = candidates.first(where: { existing in
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
    return
      vocabularyCollections
      .filter { compatibleIDs.contains($0.id) }
      .map(\.id)
  }

  func setVocabularyRuleEnabled(_ ruleID: UUID, isEnabled: Bool) {
    guard !settings.isLoading, availability == .available else { return }
    for collectionIndex in vocabularyCollections.indices {
      guard
        let entryIndex = vocabularyCollections[collectionIndex].entries.firstIndex(
          where: { $0.id == ruleID }
        )
      else { continue }
      guard vocabularyCollections[collectionIndex].entries[entryIndex].enabled != isEnabled else {
        return
      }
      vocabularyCollections[collectionIndex].entries[entryIndex].enabled = isEnabled
      vocabularyCollections[collectionIndex].updatedAt = Date()
      commit()
      return
    }
  }

  func deleteVocabularyRule(_ ruleID: UUID) {
    guard !settings.isLoading, availability == .available else { return }
    for index in vocabularyCollections.indices {
      let oldCount = vocabularyCollections[index].entries.count
      vocabularyCollections[index].entries.removeAll { $0.id == ruleID }
      if vocabularyCollections[index].entries.count != oldCount {
        vocabularyCollections[index].updatedAt = Date()
        commit()
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
    commit()
  }

}
