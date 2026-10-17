import Foundation
import RillCore
import Testing

@testable import RillUI

@MainActor
struct VocabularyLibraryModelTests {
  enum EditingBlock: CaseIterable { case loading, unavailable, shutdown }

  @Test(arguments: EditingBlock.allCases)
  func editsCannotChangeProtectedOrClosingVocabulary(_ block: EditingBlock) async throws {
    let store = UITestSettingsStore()
    let app = makeHarness(settingsStore: store).model
    await app.waitForInitialVoiceConfiguration()
    let rule = VocabularyRule(pattern: "rill", replacement: "Rill")
    #expect(app.vocabulary.saveVocabularyCorrectionRule(rule) == .created(ruleID: rule.id))
    await app.flushPendingPersistenceWrites()
    let before = app.vocabulary.vocabularyCollections
    let writes = await store.activitySnapshot().setCounts
    switch block {
    case .loading: app.settings.isLoading = true
    case .unavailable: app.vocabulary.availability = .unavailable
    case .shutdown: app.beginApplicationShutdown()
    }

    app.vocabulary.setVocabularyCollectionEnabled(VocabularyCollection.personalID, isEnabled: false)
    app.vocabulary.addVocabularyEntry(
      to: VocabularyCollection.personalID, kind: .hotword, pattern: "MLX")
    #expect(!app.vocabulary.updateVocabularyEntry(VocabularyEntry(rule: rule), in: VocabularyCollection.personalID))
    #expect(!app.vocabulary.addVocabularyEntry(VocabularyEntry(content: .hotword(phrase: "Ignored")), to: VocabularyCollection.personalID))
    app.vocabulary.deleteVocabularyEntry(rule.id, from: VocabularyCollection.personalID)
    app.vocabulary.deleteVocabularyRule(rule.id)
    app.vocabulary.setVocabularyRuleEnabled(rule.id, isEnabled: false)
    app.vocabulary.createVocabularyCollection(named: "Ignored")
    #expect(app.vocabulary.saveVocabularyCorrectionRule(rule) == .notReady)
    await app.flushPendingPersistenceWrites()

    #expect(app.vocabulary.vocabularyCollections == before)
    #expect(await store.activitySnapshot().setCounts == writes)
  }

  @Test
  func editingPersistsContentWithoutChangingIdentityBindingsOrEnabledState() async throws {
    let store = UITestSettingsStore()
    let app = makeHarness(settingsStore: store).model
    await app.waitForInitialVoiceConfiguration()
    let rule = VocabularyRule(enabled: false, pattern: "rill", replacement: "Rill", scope: .init(bundleIdentifier: "com.apple.TextEdit"))
    app.vocabulary.restoreLegacyRules([rule])
    let collection = try #require(app.vocabulary.vocabularyCollections.first { $0.entries.contains { $0.id == rule.id } })
    let bindings = app.vocabulary.vocabularyCollectionBindings
    var edit = VocabularyEntry(rule: rule)
    edit.content = .replacement(pattern: " rill ", replacement: " RILL ", matchMode: .wordBoundary, caseSensitive: true)
    edit.enabled = true
    edit.createdAt = .distantPast
    edit.priority = 3
    #expect(app.vocabulary.updateVocabularyEntry(edit, in: collection.id))
    await app.flushPendingPersistenceWrites()
    let updated = try #require(app.vocabulary.vocabularyRules.first { $0.id == rule.id })
    #expect(updated.pattern == "rill")
    #expect(updated.replacement == "RILL")
    #expect(updated.matchMode == .wordBoundary)
    #expect(updated.caseSensitive)
    #expect(updated.priority == 3)
    #expect(!updated.enabled)
    #expect(updated.createdAt == rule.createdAt)
    #expect(updated.scope == rule.scope)
    #expect(app.vocabulary.vocabularyCollectionBindings == bindings)
    let reloaded = makeHarness(settingsStore: store).model
    await reloaded.waitForInitialVoiceConfiguration()
    #expect(reloaded.vocabulary.vocabularyRules == app.vocabulary.vocabularyRules)
  }

  @Test
  func invalidNoOpAndDeletedEditsDoNotWrite() async throws {
    let store = UITestSettingsStore()
    let app = makeHarness(settingsStore: store).model
    await app.waitForInitialVoiceConfiguration()
    let entry = VocabularyEntry(enabled: false, content: .replacement(pattern: "rill", replacement: "Rill", matchMode: .regex, caseSensitive: false))
    #expect(app.vocabulary.addVocabularyEntry(entry, to: VocabularyCollection.personalID))
    await app.flushPendingPersistenceWrites()
    let before = app.vocabulary.vocabularyCollections
    let writes = await store.activitySnapshot().setCounts
    #expect(app.vocabulary.updateVocabularyEntry(entry, in: VocabularyCollection.personalID))
    var invalid = entry
    invalid.content = .replacement(pattern: "[", replacement: "Rill", matchMode: .regex, caseSensitive: false)
    #expect(!app.vocabulary.updateVocabularyEntry(invalid, in: VocabularyCollection.personalID))
    #expect(!app.vocabulary.addVocabularyEntry(invalid, to: VocabularyCollection.personalID))
    await app.flushPendingPersistenceWrites()
    #expect(app.vocabulary.vocabularyCollections == before)
    #expect(await store.activitySnapshot().setCounts == writes)
    app.vocabulary.deleteVocabularyEntry(entry.id, from: VocabularyCollection.personalID)
    await app.flushPendingPersistenceWrites()
    let afterDelete = await store.activitySnapshot().setCounts
    #expect(!app.vocabulary.updateVocabularyEntry(entry, in: VocabularyCollection.personalID))
    await app.flushPendingPersistenceWrites()
    #expect(await store.activitySnapshot().setCounts == afterDelete)
    #expect(!app.vocabulary.vocabularyRules.contains { $0.id == entry.id })
  }

}
