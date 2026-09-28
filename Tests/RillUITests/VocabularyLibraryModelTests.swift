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
    app.vocabulary.deleteVocabularyEntry(rule.id, from: VocabularyCollection.personalID)
    app.vocabulary.deleteVocabularyRule(rule.id)
    app.vocabulary.setVocabularyRuleEnabled(rule.id, isEnabled: false)
    app.vocabulary.createVocabularyCollection(named: "Ignored")
    #expect(app.vocabulary.saveVocabularyCorrectionRule(rule) == .notReady)
    await app.flushPendingPersistenceWrites()

    #expect(app.vocabulary.vocabularyCollections == before)
    #expect(await store.activitySnapshot().setCounts == writes)
  }
}
