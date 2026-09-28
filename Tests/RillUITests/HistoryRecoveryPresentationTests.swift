import Foundation
import RillCore
import Testing

@testable import RillUI

struct HistoryRecoveryPresentationTests {
  @Test func savedTextAndUnconfirmedOutputRemainSeparate() throws {
    for disposition in [nil, OutputFailureDisposition.unknown, .notApplied] {
      let receipt = try WorkflowRunReceipt(
        runID: UUID(), workflowID: nil, trigger: .hotkey, timestamp: Date(), duration: .s1To4,
        termination: .partiallyCompleted(code: .processing),
        actionDetails: [
          .init(actionIndex: 0, result: .storedRecord, duration: .under250ms),
          .init(actionIndex: 1, result: .failed, duration: .s1To4, failureDisposition: disposition),
        ])
      let decoded = try JSONDecoder().decode(
        WorkflowRunReceipt.self, from: JSONEncoder().encode(receipt))
      let state = HistoryRecoveryPresentation(receipt: decoded)
      #expect(state.wasSaved)
      #expect(state.outputState == (disposition == .notApplied ? .failed : .uncertain))
    }
  }

  @Test func cancellationWithNoConfirmedOutputIsUncertain() throws {
    let receipt = try WorkflowRunReceipt(
      runID: UUID(), workflowID: nil, trigger: .hotkey, timestamp: Date(), duration: .s1To4,
      termination: .cancelled(stage: .delivering),
      actionDetails: [
        .init(actionIndex: 0, result: .cancelled, duration: .s1To4)
      ])
    let state = HistoryRecoveryPresentation(receipt: receipt)
    #expect(!state.wasSaved)
    #expect(state.outputState == .uncertain)
    #expect(HistoryRecoveryPresentation(receipt: nil).message(language: .english) == nil)
  }
}
