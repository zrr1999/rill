import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
final class EventFeedPrivacyPresentationTests: XCTestCase {
    func testTokenUsageRemainsVisibleWithoutExposingTheStepText() async throws {
        let harness = makeHarness()
        await harness.model.waitForInitialVoiceConfiguration()
        let runID = UUID()
        harness.model.handle(.runStarted(RunSnapshot(
            runID: runID, workflowID: harness.workflow.id,
            workflow: harness.workflow.presentation, trigger: .manual
        )))
        harness.model.handle(.runTextStepRecorded(runID: runID, step: WorkflowTextStep(
            kind: .llmRewrite, outputText: "PRIVATE-RESULT", didChange: true,
            tokenUsage: .init(inputTokens: 120, outputTokens: 24, totalTokens: 144)
        )))
        let entry = try XCTUnwrap(harness.model.eventFeed.last)
        for language in AppLanguage.allCases {
            for mode: PrivacyHistoryPreviewMode in [.full, .restricted, .disabled] {
                let text = entry.presentation(for: language, historyPreviewMode: mode).text
                XCTAssertTrue(text.contains("120"))
                XCTAssertTrue(text.contains("24"))
                XCTAssertTrue(text.contains("144"))
                XCTAssertEqual(text.contains("PRIVATE-RESULT"), mode != .disabled)
            }
        }
        await harness.model.flushPendingPersistenceWrites()
    }

    func testTokenUsagePresentationDistinguishesMissingFromZero() {
        XCTAssertEqual(HistoryTextStepPresentation.tokenUsage(nil, language: .simplifiedChinese), "Token 用量：未提供")
        XCTAssertEqual(
            HistoryTextStepPresentation.tokenUsage(.init(inputTokens: 0, outputTokens: 3), language: .english),
            "Tokens · Input 0 · Output 3 · Total Not provided"
        )
    }

    func testFailedVoiceRunRetainsStepsAndAddsPrivacyAwareDetailedLog() async throws {
        let harness = makeHarness()
        await harness.model.waitForInitialVoiceConfiguration()
        let runID = UUID()
        harness.model.handle(.runStarted(RunSnapshot(
            runID: runID, workflowID: harness.workflow.id,
            workflow: harness.workflow.presentation, trigger: .manual
        )))
        let steps = [
            WorkflowTextStep(kind: .recognizeSpeech, outputText: "识别正文"),
            WorkflowTextStep(kind: .applyVocabulary, outputText: "替换后正文", didChange: true),
            WorkflowTextStep(kind: .llmRewrite, result: .failed)
        ]
        let feedCount = harness.model.eventFeed.count
        for step in steps {
            harness.model.handle(.runTextStepRecorded(runID: runID, step: step))
        }
        harness.model.handle(.runTextStepRecorded(
            runID: UUID(), step: WorkflowTextStep(kind: .recognizeSpeech, outputText: "其他运行")
        ))
        XCTAssertEqual(harness.model.eventFeed.count, feedCount + steps.count)
        let replacement = harness.model.eventFeed[feedCount + 1]
        XCTAssertTrue(replacement.presentation(for: .simplifiedChinese, historyPreviewMode: .full).text.contains("词替换 · 已完成\n替换后正文"))
        XCTAssertFalse(replacement.presentation(for: .simplifiedChinese, historyPreviewMode: .disabled).text.contains("替换后正文"))
        XCTAssertFalse(replacement.simplifiedChinese.contains("替换后正文"))
        harness.model.handle(.runFailed(
            runID: runID, workflow: harness.workflow.presentation, message: "provider unavailable"
        ))
        await harness.model.flushPendingPersistenceWrites()
        let record = try XCTUnwrap(harness.model.historyRecords.first { $0.runID == runID })
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.correctionSource?.processingSteps, steps)
        XCTAssertNil(record.finalText)
        XCTAssertNil(harness.model.pendingRuns[runID])
        await harness.model.flushPendingPersistenceWrites()
    }

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
