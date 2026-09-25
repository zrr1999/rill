import Foundation
import RillCore

/// Owns the opt-in policy separately from encrypted archive mechanics.
public actor BenchmarkRecordingArchiveController {
  private let store: any BenchmarkRecordingArchiveStore
  private let diagnostics: DiagnosticsRecorder?
  private var isEnabled = false
  private var policyGeneration: UInt64 = 0

  public init(
    store: any BenchmarkRecordingArchiveStore,
    diagnostics: DiagnosticsRecorder? = nil
  ) {
    self.store = store
    self.diagnostics = diagnostics
  }

  public func refresh(isEnabled: Bool) {
    policyGeneration &+= 1
    self.isEnabled = isEnabled
  }

  @discardableResult
  public func preserveIfEnabled(
    audio: CapturedAudio,
    runID: UUID,
    workflowID: UUID,
    trigger: WorkflowRunTriggerKind?,
    outcome: BenchmarkRecordingOutcome,
    metadata: [String: String],
    now: Date = Date()
  ) async throws -> BenchmarkRecordingReceipt? {
    guard isEnabled else { return nil }
    let generation = policyGeneration
    let receipt = try await store.preserve(
      audio: audio,
      runID: runID,
      workflowID: workflowID,
      trigger: trigger,
      outcome: outcome,
      metadata: metadata,
      now: now
    )
    guard isEnabled, generation == policyGeneration else {
      try? await store.delete(runID: runID)
      return nil
    }
    await diagnostics?.record(
      DiagnosticEvent(
        runID: runID,
        subsystem: .session,
        level: .info,
        event: .benchmarkRecordingPreserved,
        message: "Encrypted audio was retained for the private ASR benchmark.",
        metadata: [
          "outcome": outcome.rawValue,
          "plaintextByteCount": String(receipt.plaintextByteCount),
        ]
      )
    )
    return receipt
  }

  public func deleteAll() async throws {
    policyGeneration &+= 1
    try await store.deleteAll()
  }
}
