import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
final class VocabularyCorrectionSaveTests: XCTestCase {
    func testExactDuplicateIsReusedAndReenabledInsteadOfAppended() throws {
        let harness = makeHarness()
        let scope = VocabularyRuleScope(
            bundleIdentifier: "com.example.Editor",
            clipboardGroupID: UUID(),
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
