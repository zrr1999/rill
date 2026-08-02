import XCTest
@testable import RillCore
@testable import RillUI

final class HistoryPreviewPresentationTests: XCTestCase {
    func testFullModeExposesCompleteTextAndRestrictedModeUsesBoundedDisplayText() {
        let privateText = String(repeating: "private ", count: 20) + "TAIL-CANARY"
        XCTAssertEqual(
            HistoryPreviewPresentation(
                text: privateText,
                mode: .full,
                language: .english
            ),
            .visible(text: privateText, lineLimit: nil)
        )
        let restricted = HistoryPreviewPresentation(
            text: privateText,
            mode: .restricted,
            language: .simplifiedChinese
        )
        guard case .visible(let displayText, let lineLimit) = restricted else {
            return XCTFail("Restricted mode should produce bounded display text.")
        }
        XCTAssertEqual(lineLimit, 3)
        XCTAssertLessThanOrEqual(
            displayText.count,
            HistoryPreviewPresentation.restrictedCharacterLimit
        )
        XCTAssertFalse(displayText.contains("TAIL-CANARY"))
        XCTAssertNotEqual(displayText, privateText)
    }

    func testDisabledModeNeverExposesTextAndUsesExistingLocalizedCopy() {
        XCTAssertEqual(
            HistoryPreviewPresentation(
                text: "private result",
                mode: .disabled,
                language: .english
            ),
            .hidden(message: "Preview hidden by privacy setting")
        )
        XCTAssertEqual(
            HistoryPreviewPresentation(
                text: "private result",
                mode: .disabled,
                language: .simplifiedChinese
            ),
            .hidden(message: "已按隐私设置隐藏预览")
        )
    }

    func testMissingTextProducesNoPreviewInEveryMode() {
        for mode in PrivacyHistoryPreviewMode.allCases {
            XCTAssertNil(
                HistoryPreviewPresentation(
                    text: nil,
                    mode: mode,
                    language: .english
                )
            )
            XCTAssertNil(
                HistoryPreviewPresentation(
                    text: nil,
                    mode: mode,
                    language: .simplifiedChinese
                )
            )
        }
    }

    func testLanguageModelTracePrefersExactOrderedInputs() throws {
        let record = HistoryRecord(
            workflow: WorkflowPresentation(fallbackName: "Assistant"),
            finalText: "answer",
            outcome: .completed,
            correctionSource: RecognitionCorrectionSource(
                preMappingText: "raw question",
                context: VocabularyRuleContext(),
                languageModelInputTexts: ["normalized question", "second-step input"]
            ),
            trigger: .wakeWord
        )

        let presentation = try XCTUnwrap(
            HistoryLanguageModelTracePresentation(record: record)
        )
        XCTAssertEqual(presentation.inputTexts, ["normalized question", "second-step input"])
        XCTAssertEqual(presentation.inputProvenance, .exact)
        XCTAssertEqual(presentation.outputText, "answer")
    }

    func testOlderWakeRecordShowsRecognizedInputWithoutClaimingExactLLMTrace() throws {
        let record = HistoryRecord(
            workflow: WorkflowPresentation(fallbackName: "Assistant"),
            finalText: "answer",
            outcome: .completed,
            correctionSource: RecognitionCorrectionSource(
                preMappingText: "legacy question",
                context: VocabularyRuleContext()
            ),
            trigger: .wakeWord
        )

        let presentation = try XCTUnwrap(
            HistoryLanguageModelTracePresentation(record: record)
        )
        XCTAssertEqual(presentation.inputTexts, ["legacy question"])
        XCTAssertEqual(presentation.inputProvenance, .legacyRecognition)
    }

    func testLanguageModelTraceExposesProviderModelPromptsMessagesAndReply() throws {
        let detailedTrace = LanguageModelTrace(
            providerID: "openai.responses",
            modelID: "gpt-test",
            systemPrompt: "system contract",
            workflowPrompt: "answer briefly",
            messages: [.init(role: .user, content: "actual question")],
            responseText: "actual answer"
        )
        let record = HistoryRecord(
            workflow: WorkflowPresentation(fallbackName: "Assistant"),
            finalText: "actual answer",
            outcome: .completed,
            correctionSource: RecognitionCorrectionSource(
                preMappingText: "raw question",
                context: VocabularyRuleContext(),
                languageModelTraces: [detailedTrace]
            ),
            trigger: .wakeWord
        )

        let presentation = try XCTUnwrap(
            HistoryLanguageModelTracePresentation(record: record)
        )
        XCTAssertEqual(presentation.traces, [detailedTrace])
        XCTAssertEqual(presentation.inputTexts, ["actual question"])
        XCTAssertEqual(presentation.outputText, "actual answer")
    }

    func testOlderNonAssistantRecordDoesNotInventLLMTrace() {
        let record = HistoryRecord(
            workflow: WorkflowPresentation(fallbackName: "Dictation"),
            finalText: "output",
            outcome: .completed,
            correctionSource: RecognitionCorrectionSource(
                preMappingText: "recognized",
                context: VocabularyRuleContext()
            ),
            trigger: .hotkey
        )

        XCTAssertNil(HistoryLanguageModelTracePresentation(record: record))
    }
}
