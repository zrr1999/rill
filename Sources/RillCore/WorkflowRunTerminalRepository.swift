import Foundation

/// Commits the body and content-free receipt at one generation and transaction boundary.
public protocol WorkflowRunTerminalRepository: WorkflowRunReceiptRepository {
  func commitTerminal(
    _ receipt: WorkflowRunReceipt,
    history: WorkflowResultRecord?,
    generation: RunHistoryWriteGeneration
  ) async throws
}

public enum WorkflowRunHistoryUpdate: Sendable, Equatable {
  case persisted(runID: UUID)
  case sessionOnly(WorkflowResultRecord)
}
