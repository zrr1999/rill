import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
final class VocabularyCorrectionSaveTests: XCTestCase {
    func testRejectedAndUnchangedCorrectionsDoNotWriteSettings() async throws {
        let store = UITestSettingsStore()
        let harness = makeHarness(settingsStore: store, settingsWriteDebounceDuration: .zero)
        await harness.model.waitForInitialVoiceConfiguration()
        let rule = VocabularyRule(pattern: "rill", replacement: "Rill")
        XCTAssertEqual(harness.model.saveVocabularyCorrectionRule(rule), .created(ruleID: rule.id))
        await harness.model.flushPendingPersistenceWrites()
        let before = await store.activitySnapshot()
        XCTAssertEqual(harness.model.saveVocabularyCorrectionRule(rule), .reused(ruleID: rule.id))
        XCTAssertEqual(harness.model.saveVocabularyCorrectionRule(
            VocabularyRule(pattern: "rill", replacement: "Different")), .conflict(existingRuleID: rule.id))
        XCTAssertEqual(harness.model.saveVocabularyCorrectionRule(
            VocabularyRule(pattern: " ", replacement: "Invalid")), .invalid)
        await harness.model.flushPendingPersistenceWrites()
        let after = await store.activitySnapshot()
        XCTAssertEqual(after.setCounts, before.setCounts)
    }

    func testScopedCorrectionSurvivesPersistenceAndReusesAcrossMultipleBindings() async throws {
        let store = UITestSettingsStore()
        let harness = makeHarness(settingsStore: store, settingsWriteDebounceDuration: .zero)
        await harness.model.waitForInitialVoiceConfiguration()
        let scope = VocabularyRuleScope(bundleIdentifier: "com.example.Editor")
        let rule = VocabularyRule(pattern: "vox type", replacement: "Rill", scope: scope)
        XCTAssertEqual(harness.model.saveVocabularyCorrectionRule(rule), .created(ruleID: rule.id))
        let collectionID = try XCTUnwrap(harness.model.vocabularyCollectionIDs(compatibleWith: scope).first)
        let secondScope = VocabularyRuleScope(locale: "zh-CN")
        harness.model.vocabularyCollectionBindings.append(.init(collectionID: collectionID,
            condition: .init(locale: secondScope.locale)))
        harness.model.setVocabularyRuleEnabled(rule.id, isEnabled: false)
        await harness.model.flushPendingPersistenceWrites()

        let reloaded = makeHarness(settingsStore: store, settingsWriteDebounceDuration: .zero)
        await reloaded.model.waitForInitialVoiceConfiguration()
        XCTAssertEqual(reloaded.model.vocabularyRules.first(where: { $0.id == rule.id })?.scope, scope)
        var otherScopeRule = rule
        otherScopeRule.scope = secondScope
        XCTAssertEqual(reloaded.model.saveVocabularyCorrectionRule(otherScopeRule), .reused(ruleID: rule.id))
        XCTAssertEqual(reloaded.model.saveVocabularyCorrectionRule(rule), .reused(ruleID: rule.id))
        XCTAssertEqual(reloaded.model.vocabularyCollections.flatMap(\.entries).count, 1)
    }

    func testExactDuplicateIsReusedAndReenabledInsteadOfAppended() throws {
        let harness = makeHarness()
        let scope = VocabularyRuleScope(
            bundleIdentifier: "com.example.Editor",
            recordCollectionID: UUID(),
            locale: "en-US"
        )
        let rule = VocabularyRule(
            enabled: false,
            pattern: "vox type",
            replacement: "Rill",
            scope: scope
        )
        harness.model.vocabularyRules = [rule]

        let outcome = harness.model.saveVocabularyCorrectionRule(
            VocabularyRule(
                pattern: " vox type ",
                replacement: " Rill ",
                scope: scope
            )
        )

        XCTAssertEqual(outcome, .reused(ruleID: rule.id))
        XCTAssertEqual(harness.model.vocabularyRules.count, 1)
        XCTAssertTrue(try XCTUnwrap(harness.model.vocabularyRules.first).enabled)
    }

    func testConflictingReplacementIsBlocked() {
        let harness = makeHarness()
        let scope = VocabularyRuleScope(bundleIdentifier: "com.example.Editor")
        let existing = VocabularyRule(
            pattern: "project name",
            replacement: "Project Alpha",
            scope: scope
        )
        harness.model.vocabularyRules = [existing]

        let outcome = harness.model.saveVocabularyCorrectionRule(
            VocabularyRule(
                pattern: "project name",
                replacement: "Project Beta",
                scope: scope
            )
        )

        XCTAssertEqual(outcome, .conflict(existingRuleID: existing.id))
        XCTAssertEqual(harness.model.vocabularyRules, [existing])
    }

    func testDifferentScopeCreatesANewRule() {
        let harness = makeHarness()
        let existing = VocabularyRule(
            pattern: "release train",
            replacement: "Release Train",
            scope: VocabularyRuleScope(bundleIdentifier: "com.example.One")
        )
        harness.model.vocabularyRules = [existing]
        let proposed = VocabularyRule(
            pattern: "release train",
            replacement: "Release Train",
            scope: VocabularyRuleScope(bundleIdentifier: "com.example.Two")
        )

        let outcome = harness.model.saveVocabularyCorrectionRule(proposed)

        XCTAssertEqual(outcome, .created(ruleID: proposed.id))
        XCTAssertEqual(harness.model.vocabularyRules.count, 2)
    }

    func testHotwordNormalizationPreventsSemanticallyDuplicateRules() {
        let harness = makeHarness()
        let existing = VocabularyRule(
            kind: .hotword,
            pattern: "Rill",
            replacement: "",
            matchMode: .exactPhrase,
            caseSensitive: false
        )
        harness.model.vocabularyRules = [existing]

        let outcome = harness.model.saveVocabularyCorrectionRule(
            VocabularyRule(
                kind: .hotword,
                pattern: "Rill",
                replacement: "ignored",
                matchMode: .regex,
                caseSensitive: true
            )
        )

        XCTAssertEqual(outcome, .reused(ruleID: existing.id))
        XCTAssertEqual(harness.model.vocabularyRules.count, 1)
    }
}
