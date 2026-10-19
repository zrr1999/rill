import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
final class HistoryTextStepPresentationTests: XCTestCase {
  func testTokenUsagePresentationDistinguishesMissingFromZero() {
    XCTAssertEqual(HistoryTextStepPresentation.tokenUsage(nil, language: .simplifiedChinese), "Token 用量：未提供")
    XCTAssertEqual(
      HistoryTextStepPresentation.tokenUsage(.init(inputTokens: 0, outputTokens: 3), language: .english),
      "Tokens · Input 0 · Output 3 · Total Not provided"
    )
  }

  func testProcessingTimeUsesMillisecondsAndSeconds() {
    XCTAssertEqual(L10n.historyProcessingDuration(0, language: .english), "0 ms")
    XCTAssertEqual(L10n.historyProcessingDuration(999, language: .simplifiedChinese), "999 毫秒")
    XCTAssertEqual(L10n.historyProcessingDuration(1_234, language: .simplifiedChinese), "1.234 秒")
    XCTAssertEqual(L10n.historyProcessingDuration(62_005, language: .english), "62.005 s")
    XCTAssertEqual(HistoryTextStepPresentation.duration(5_000, language: .english), "Processing time: 5.000 s")
  }

  func testFailedVoiceRunRetainsHistorySteps() async throws {
    let harness = makeHarness()
    await harness.model.waitForInitialVoiceConfiguration()
    let runID = UUID()
    harness.model.handle(
      .runStarted(
        RunSnapshot(
          runID: runID, workflowID: harness.workflow.id,
          workflow: harness.workflow.presentation, trigger: .manual
        )))
    let steps = [
      WorkflowTextStep(kind: .recognizeSpeech, outputText: "识别正文", durationMilliseconds: 1_234),
      WorkflowTextStep(kind: .applyVocabulary, outputText: "替换后正文", didChange: true),
      WorkflowTextStep(kind: .llmRewrite, result: .failed, durationMilliseconds: 5_000),
    ]
    harness.model.handle(
      .runHistoryUpdated(
        .sessionOnly(
          WorkflowResultRecord(
            runID: runID, workflowID: harness.workflow.id, workflow: harness.workflow.presentation,
            outcome: .failed, correctionSource: .init(preMappingText: "识别正文", context: .init(), processingSteps: steps), trigger: .manual
          ))))
    harness.model.handle(
      .runFailed(
        runID: runID, workflow: harness.workflow.presentation, message: "provider unavailable"
      ))
    await harness.model.flushPendingPersistenceWrites()
    let record = try XCTUnwrap(harness.model.history.historyRecords.first { $0.runID == runID })
    XCTAssertEqual(record.outcome, .failed)
    XCTAssertEqual(record.correctionSource?.processingSteps, steps)
    XCTAssertNil(record.finalText)
    XCTAssertNil(harness.model.pendingRuns[runID])
    await harness.model.flushPendingPersistenceWrites()
  }

}
