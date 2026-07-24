import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
final class EventFeedPrivacyPresentationTests: XCTestCase {
    func testRecognitionActivityUsesHistoryPreviewPolicyForVisualAndAccessibilityPresentation() throws {
        let harness = makeHarness()
        let tailCanary = "PRIVATE-TAIL-CANARY"
        let privateText = String(repeating: "private result ", count: 12) + tailCanary

        harness.model.handle(
            .recognitionCompleted(
                RecognitionResult(rawText: privateText, bestText: privateText)
            )
        )

        let entry = try XCTUnwrap(harness.model.eventFeed.last)
        XCTAssertFalse(entry.english.contains(tailCanary))
        XCTAssertFalse(entry.simplifiedChinese.contains(tailCanary))

        let full = entry.presentation(
            for: .english,
            historyPreviewMode: .full
        )
        XCTAssertEqual(full.text, "Recognition: \(privateText)")
        XCTAssertEqual(full.accessibilityLabel, full.text)
        XCTAssertNil(full.lineLimit)

        let restricted = entry.presentation(
            for: .english,
            historyPreviewMode: .restricted
        )
        let restrictedPrefix = "Recognition summary: "
        XCTAssertTrue(restricted.text.hasPrefix(restrictedPrefix))
        XCTAssertLessThanOrEqual(
            restricted.text.dropFirst(restrictedPrefix.count).count,
            HistoryPreviewPresentation.restrictedCharacterLimit
        )
        XCTAssertFalse(restricted.text.contains(tailCanary))
        XCTAssertEqual(restricted.accessibilityLabel, restricted.text)
        XCTAssertEqual(restricted.lineLimit, 3)

        let disabled = entry.presentation(
            for: .english,
            historyPreviewMode: .disabled
        )
        XCTAssertEqual(
            disabled.text,
            "Recognition completed. Preview hidden by privacy setting"
        )
        XCTAssertEqual(disabled.accessibilityLabel, disabled.text)
        XCTAssertFalse(disabled.text.contains("private result"))
        XCTAssertFalse(disabled.accessibilityLabel.contains(tailCanary))
        XCTAssertNil(disabled.lineLimit)

        let disabledChinese = entry.presentation(
            for: .simplifiedChinese,
            historyPreviewMode: .disabled
        )
        XCTAssertEqual(disabledChinese.text, "识别已完成。 已按隐私设置隐藏预览")
        XCTAssertEqual(disabledChinese.accessibilityLabel, disabledChinese.text)
        XCTAssertFalse(disabledChinese.accessibilityLabel.contains(tailCanary))
    }

    func testEveryBodyBearingActivityEventIsContentFreeWhenPreviewIsDisabled() throws {
        let harness = makeHarness()
        let tailCanary = "EVENT-BODY-PRIVATE-TAIL-CANARY"
        let privateBody = String(repeating: "private activity body ", count: 8) + tailCanary
        let events: [(event: RillEvent, disabledText: String)] = [
            (
                .recognitionCompleted(
                    RecognitionResult(rawText: privateBody, bestText: privateBody)
                ),
                "Recognition completed. Preview hidden by privacy setting"
            ),
            (
                .candidateResolutionFinished(caseID: UUID(), resolvedText: privateBody),
                "Resolution completed. Preview hidden by privacy setting"
            ),
            (
                .transformationApplied(stepID: UUID(), text: privateBody),
                "Text transformation completed. Preview hidden by privacy setting"
            ),
            (
                .runCompleted(
                    WorkflowRunSummary(
                        runID: UUID(),
                        workflowID: harness.workflow.id,
                        workflow: harness.workflow.presentation,
                        trigger: .manual,
                        finalText: privateBody
                    )
                ),
                "Run completed. Preview hidden by privacy setting"
            ),
        ]

        for (event, expectedDisabledText) in events {
            harness.model.eventFeed.removeAll()
            harness.model.handle(event)

            let entry = try XCTUnwrap(harness.model.eventFeed.last)
            let full = entry.presentation(
                for: .english,
                historyPreviewMode: .full
            )
            let restricted = entry.presentation(
                for: .english,
                historyPreviewMode: .restricted
            )
            let disabled = entry.presentation(
                for: .english,
                historyPreviewMode: .disabled
            )

            XCTAssertTrue(full.text.contains(tailCanary))
            XCTAssertTrue(full.accessibilityLabel.contains(tailCanary))

            let summaryMarker = "summary: "
            let summaryRange = try XCTUnwrap(restricted.text.range(of: summaryMarker))
            XCTAssertLessThanOrEqual(
                restricted.text[summaryRange.upperBound...].count,
                HistoryPreviewPresentation.restrictedCharacterLimit
            )
            XCTAssertFalse(restricted.text.contains(tailCanary))
            XCTAssertEqual(restricted.accessibilityLabel, restricted.text)
            XCTAssertEqual(restricted.lineLimit, 3)

            XCTAssertFalse(entry.english.contains(tailCanary))
            XCTAssertFalse(entry.simplifiedChinese.contains(tailCanary))
            XCTAssertEqual(disabled.text, expectedDisabledText)
            XCTAssertEqual(disabled.accessibilityLabel, expectedDisabledText)
            XCTAssertFalse(disabled.text.contains(tailCanary))
            XCTAssertFalse(disabled.accessibilityLabel.contains(tailCanary))
        }
    }
}
