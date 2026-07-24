import XCTest
@testable import RillCore
@testable import RillUI

final class VocabularyCorrectionDraftTests: XCTestCase {
    func testEligibilityRequiresCompletedCorrectionSourceAndVisibleHistoryPreviews() {
        let eligible = historyRecord(outcome: .completed, includesSource: true)
        XCTAssertTrue(
            VocabularyCorrectionDraft.isEligible(
                record: eligible,
                privacyPreviewMode: .restricted
            )
        )
        XCTAssertTrue(
            VocabularyCorrectionDraft.isEligible(record: eligible, privacyPreviewMode: .full)
        )
        XCTAssertFalse(
            VocabularyCorrectionDraft.isEligible(record: eligible, privacyPreviewMode: .disabled)
        )
        XCTAssertFalse(
            VocabularyCorrectionDraft.isEligible(
                record: historyRecord(outcome: .failed, includesSource: true),
                privacyPreviewMode: .restricted
            )
        )
        XCTAssertFalse(
            VocabularyCorrectionDraft.isEligible(
                record: historyRecord(outcome: .completed, includesSource: false),
                privacyPreviewMode: .restricted
            )
        )
    }

    func testRecordInitializerEnforcesEligibility() {
        let eligible = historyRecord(outcome: .completed, includesSource: true)

        XCTAssertNotNil(
            VocabularyCorrectionDraft(record: eligible, privacyPreviewMode: .restricted)
        )
        XCTAssertNil(
            VocabularyCorrectionDraft(record: eligible, privacyPreviewMode: .disabled)
        )
    }

    func testTextEditGeneratesPlannerOptionsButRequiresExplicitSelection() throws {
        let source = correctionSource(
            text: "open aaa now",
            context: VocabularyRuleContext(
                bundleIdentifier: "com.example.editor",
                clipboardGroupID: groupID,
                locale: "en-US"
            )
        )
        var draft = VocabularyCorrectionDraft(source: source)

        draft.updateCorrectedText("open BBB now")

        XCTAssertEqual(draft.status, .optionsAvailable)
        XCTAssertEqual(draft.options.map(\.id), [.mapping, .hotword])
        XCTAssertNil(draft.selectedOptionID)
        XCTAssertNil(draft.proposedRule)

        draft.selectOption(id: .mapping)

        let rule = try XCTUnwrap(draft.proposedRule)
        XCTAssertEqual(rule.kind, .mapping)
        XCTAssertEqual(rule.pattern, "aaa")
        XCTAssertEqual(rule.replacement, "BBB")
        XCTAssertEqual(rule.matchMode, .exactPhrase)
        XCTAssertFalse(rule.caseSensitive)
        XCTAssertEqual(rule.scope, source.context.ruleScope)
        XCTAssertEqual(draft.proposedRule?.id, rule.id)
        XCTAssertEqual(draft.proposedRule?.createdAt, rule.createdAt)
    }

    func testEveryUnknownScopeFieldMustBeExplicitlyConfirmedAsAny() throws {
        let source = correctionSource(
            text: "launch old name",
            context: VocabularyRuleContext(bundleIdentifier: "com.example.editor")
        )
        var draft = VocabularyCorrectionDraft(source: source)
        draft.updateCorrectedText("launch NewName")
        draft.selectOption(id: .mapping)

        XCTAssertEqual(draft.unknownScopeFields, [.clipboardGroupID, .locale])
        XCTAssertNil(draft.proposedRule)

        draft.setAnyScopeConfirmed(true, for: .clipboardGroupID)
        XCTAssertNil(draft.proposedRule)

        draft.setAnyScopeConfirmed(true, for: .locale)
        let rule = try XCTUnwrap(draft.proposedRule)
        XCTAssertEqual(rule.scope.bundleIdentifier, "com.example.editor")
        XCTAssertNil(rule.scope.clipboardGroupID)
        XCTAssertNil(rule.scope.locale)

        draft.setAnyScopeConfirmed(false, for: .locale)
        XCTAssertNil(draft.proposedRule)
    }

    func testKnownScopeIsPreservedAndCannotBeConfirmedAsUnknown() throws {
        let context = VocabularyRuleContext(
            bundleIdentifier: "  com.example.editor  ",
            clipboardGroupID: groupID,
            locale: nil
        )
        var draft = VocabularyCorrectionDraft(source: correctionSource(text: "foo", context: context))
        draft.updateCorrectedText("bar")
        draft.selectOption(id: .mapping)

        draft.setAnyScopeConfirmed(true, for: .bundleIdentifier)
        XCTAssertFalse(draft.confirmedAnyScopeFields.contains(.bundleIdentifier))
        XCTAssertNil(draft.proposedRule)

        draft.setAnyScopeConfirmed(true, for: .locale)
        let rule = try XCTUnwrap(draft.proposedRule)
        XCTAssertEqual(rule.scope.bundleIdentifier, "com.example.editor")
        XCTAssertEqual(rule.scope.clipboardGroupID, groupID)
        XCTAssertNil(rule.scope.locale)
    }

    func testHotwordRuleIsNormalized() throws {
        var draft = VocabularyCorrectionDraft(source: correctionSource(text: "open project"))
        draft.updateCorrectedText("open Rill project")
        draft.selectOption(id: .hotword)
        confirmEveryUnknownScope(on: &draft)

        let rule = try XCTUnwrap(draft.proposedRule)
        XCTAssertEqual(rule.kind, .hotword)
        XCTAssertEqual(rule.pattern, "Rill")
        XCTAssertEqual(rule.replacement, "")
        XCTAssertEqual(rule.matchMode, .exactPhrase)
        XCTAssertFalse(rule.caseSensitive)
    }

    func testUnchangedInvalidAndOverlongTextProduceNoOptions() {
        let source = correctionSource(text: "original")
        var draft = VocabularyCorrectionDraft(
            source: source,
            planner: VocabularyCorrectionPlanner(maximumTextCharacterCount: 10)
        )

        draft.updateCorrectedText("original")
        XCTAssertEqual(draft.status, .unchanged)
        XCTAssertTrue(draft.options.isEmpty)

        draft.updateCorrectedText("o\u{0000}riginal")
        XCTAssertEqual(draft.status, .invalid(.containsControlCharacters))
        XCTAssertTrue(draft.options.isEmpty)

        draft.updateCorrectedText("an overlong correction")
        XCTAssertEqual(draft.status, .invalid(.textExceedsCharacterLimit(10)))
        XCTAssertTrue(draft.options.isEmpty)
    }

    func testOutOfBoundsSelectionDoesNotProduceRule() {
        var draft = VocabularyCorrectionDraft(source: correctionSource(text: "old"))
        draft.updateCorrectedText("new")
        draft.selectOption(at: 0)
        confirmEveryUnknownScope(on: &draft)
        XCTAssertNotNil(draft.proposedRule)

        draft.selectOption(at: draft.options.count)

        XCTAssertNil(draft.selectedOptionID)
        XCTAssertTrue(draft.confirmedAnyScopeFields.isEmpty)
        XCTAssertNil(draft.proposedRule)
    }

    func testTextAndOptionUpdatesClearSelectionAndScopeConfirmations() {
        var draft = VocabularyCorrectionDraft(source: correctionSource(text: "old term"))
        draft.updateCorrectedText("new term")
        draft.selectOption(id: .mapping)
        confirmEveryUnknownScope(on: &draft)
        XCTAssertNotNil(draft.proposedRule)

        draft.selectOption(id: .hotword)
        XCTAssertEqual(draft.selectedOptionID, .hotword)
        XCTAssertTrue(draft.confirmedAnyScopeFields.isEmpty)
        XCTAssertNil(draft.proposedRule)

        confirmEveryUnknownScope(on: &draft)
        draft.updateCorrectedText("newer term")
        XCTAssertNil(draft.selectedOptionID)
        XCTAssertTrue(draft.confirmedAnyScopeFields.isEmpty)
        XCTAssertNil(draft.proposedRule)
    }

    private let groupID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!

    private func historyRecord(
        outcome: HistoryOutcome,
        includesSource: Bool
    ) -> HistoryRecord {
        HistoryRecord(
            workflow: WorkflowPresentation(fallbackName: "Dictation"),
            finalText: outcome == .completed ? "Rill" : nil,
            failureMessage: outcome == .failed ? "Failed" : nil,
            outcome: outcome,
            correctionSource: includesSource ? correctionSource(text: "vox type") : nil
        )
    }

    private func correctionSource(
        text: String,
        context: VocabularyRuleContext = .init()
    ) -> RecognitionCorrectionSource {
        RecognitionCorrectionSource(preMappingText: text, context: context)
    }

    private func confirmEveryUnknownScope(on draft: inout VocabularyCorrectionDraft) {
        for field in draft.unknownScopeFields {
            draft.setAnyScopeConfirmed(true, for: field)
        }
    }
}

private extension VocabularyRuleContext {
    var ruleScope: VocabularyRuleScope {
        VocabularyCorrectionScopeAssessment(context: self).knownConstraints
    }
}
