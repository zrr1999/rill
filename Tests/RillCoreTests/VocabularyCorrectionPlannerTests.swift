import XCTest
@testable import RillCore

final class VocabularyCorrectionPlannerTests: XCTestCase {
    func testUnchangedTextProducesNoOptions() {
        let source = Self.source(text: "保持原样")

        XCTAssertEqual(
            VocabularyCorrectionPlanner().plan(source: source, correctedText: "保持原样"),
            .unchanged
        )
    }

    func testSingleReplacementSuggestsMappingAndHotwordWithNarrowScope() {
        let source = Self.source(
            text: "请打开旧名称，谢谢",
            context: VocabularyRuleContext(
                bundleIdentifier: "com.example.editor",
                locale: "zh-CN"
            )
        )
        let scope = VocabularyCorrectionScopeAssessment(context: source.context)

        let plan = VocabularyCorrectionPlanner().plan(
            source: source,
            correctedText: "请打开新名称，谢谢"
        )

        XCTAssertEqual(
            plan,
            .options([
                .mapping(pattern: "旧", replacement: "新", scope: scope),
                .hotword(term: "新", scope: scope),
            ])
        )
        XCTAssertEqual(scope.knownConstraints.bundleIdentifier, "com.example.editor")
        XCTAssertEqual(scope.knownConstraints.locale, "zh-CN")
        XCTAssertEqual(scope.unknownFields, [.recordCollectionID])
        XCTAssertNil(scope.confirmedRuleScope)
    }

    func testPureInsertionSuggestsOnlyHotwordAndTreatsEmojiAsOneCharacter() {
        let source = Self.source(text: "打开项目")

        let plan = VocabularyCorrectionPlanner().plan(
            source: source,
            correctedText: "打开🚀项目"
        )

        XCTAssertEqual(
            plan,
            .options([
                .hotword(
                    term: "🚀",
                    scope: VocabularyCorrectionScopeAssessment(context: source.context)
                ),
            ])
        )
    }

    func testPureDeletionSuggestsOnlyMapping() {
        let source = Self.source(text: "保留多余词文本")

        let plan = VocabularyCorrectionPlanner().plan(
            source: source,
            correctedText: "保留文本"
        )

        XCTAssertEqual(
            plan,
            .options([
                .mapping(
                    pattern: "多余词",
                    replacement: "",
                    scope: VocabularyCorrectionScopeAssessment(context: source.context)
                ),
            ])
        )
    }

    func testDispersedChangesAreRejectedInsteadOfBecomingBroadMapping() {
        let source = Self.source(text: "甲A乙B丙")

        XCTAssertEqual(
            VocabularyCorrectionPlanner().plan(source: source, correctedText: "甲X乙Y丙"),
            .invalid(.multipleDisjointChanges)
        )
    }

    func testControlCharactersAreRejected() {
        let source = Self.source(text: "safe text")

        XCTAssertEqual(
            VocabularyCorrectionPlanner().plan(
                source: source,
                correctedText: "safe\u{0000}text"
            ),
            .invalid(.containsControlCharacters)
        )
    }

    func testOverlongTextIsRejectedBeforeDiffing() {
        let source = Self.source(text: "123456")
        let planner = VocabularyCorrectionPlanner(maximumTextCharacterCount: 5)

        XCTAssertEqual(
            planner.plan(source: source, correctedText: "123457"),
            .invalid(.textExceedsCharacterLimit(5))
        )
    }

    func testOverlongChangedPhraseIsRejected() {
        let source = Self.source(text: "前abcd后")
        let planner = VocabularyCorrectionPlanner(
            maximumTextCharacterCount: 20,
            maximumSuggestionCharacterCount: 3
        )

        XCTAssertEqual(
            planner.plan(source: source, correctedText: "前wxyz后"),
            .invalid(.suggestionExceedsCharacterLimit(3))
        )
    }

    func testExtendedGraphemeClusterReplacementIsNotSplit() {
        let source = Self.source(text: "发送🙂消息")
        let scope = VocabularyCorrectionScopeAssessment(context: source.context)

        XCTAssertEqual(
            VocabularyCorrectionPlanner().plan(
                source: source,
                correctedText: "发送👨‍👩‍👧‍👦消息"
            ),
            .options([
                .mapping(pattern: "🙂", replacement: "👨‍👩‍👧‍👦", scope: scope),
                .hotword(term: "👨‍👩‍👧‍👦", scope: scope),
            ])
        )
    }

    func testWhitespaceOnlyEditsDoNotCreateRules() {
        let cases = [
            (sourceText: "word", correctedText: "word "),
            (sourceText: "Rill App", correctedText: "RillApp"),
        ]

        for testCase in cases {
            XCTAssertEqual(
                VocabularyCorrectionPlanner().plan(
                    source: Self.source(text: testCase.sourceText),
                    correctedText: testCase.correctedText
                ),
                .invalid(.noUsableSuggestion)
            )
        }
    }

    func testCompleteScopeCanBeUsedWithoutConfirmation() {
        let groupID = UUID(uuidString: "00000000-0000-0000-0000-000000000100")!
        let context = VocabularyRuleContext(
            bundleIdentifier: "com.example.editor",
            recordCollectionID: groupID,
            locale: "en-US"
        )
        let assessment = VocabularyCorrectionScopeAssessment(context: context)

        XCTAssertFalse(assessment.containsUnknownFields)
        XCTAssertEqual(assessment.unknownFields, [])
        XCTAssertEqual(
            assessment.confirmedRuleScope,
            VocabularyRuleScope(
                bundleIdentifier: "com.example.editor",
                recordCollectionID: groupID,
                locale: "en-US"
            )
        )
    }

    func testMissingContextIsExplicitlyUnknownInsteadOfGlobalAny() {
        let assessment = VocabularyCorrectionScopeAssessment(context: .init())

        XCTAssertTrue(assessment.containsUnknownFields)
        XCTAssertEqual(
            assessment.unknownFields,
            [.bundleIdentifier, .recordCollectionID, .locale]
        )
        XCTAssertEqual(assessment.knownConstraints, VocabularyRuleScope())
        XCTAssertNil(assessment.confirmedRuleScope)
    }

    private static func source(
        text: String,
        context: VocabularyRuleContext = .init()
    ) -> RecognitionCorrectionSource {
        RecognitionCorrectionSource(preMappingText: text, context: context)
    }
}
