import RillCore

struct HistoryRecoveryPresentation: Equatable {
  enum OutputState: Equatable { case failed, uncertain }
  let wasSaved: Bool
  let outputState: OutputState?

  init(receipt: WorkflowRunReceipt?) {
    wasSaved = receipt?.actionDetails.contains { $0.result == .storedRecord } == true
    let unsuccessful =
      receipt?.actionDetails.filter { $0.result == .failed || $0.result == .cancelled } ?? []
    if unsuccessful.contains(where: { $0.failureDisposition != .notApplied }) {
      outputState = .uncertain
    } else if !unsuccessful.isEmpty {
      outputState = .failed
    } else {
      outputState = nil
    }
  }

  func message(language: AppLanguage) -> String? {
    L10n.recoveryMessage(wasSaved: wasSaved, outputState: outputState, language: language)
  }
}
