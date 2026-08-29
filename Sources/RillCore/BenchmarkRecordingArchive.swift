import Foundation

public enum BenchmarkRecordingOutcome: String, Codable, Sendable, Equatable {
  case completed
  case cancelled
  case failed
}

/// Content-free metadata for one encrypted benchmark recording.
///
/// Transcript bodies stay in run history and are joined by `runID` only when
/// the user exports a private benchmark corpus.
public struct BenchmarkRecordingReceipt: Codable, Sendable, Equatable {
  public let schemaVersion: Int
  public let runID: UUID
  public let workflowID: UUID
  public let createdAt: Date
  public let durationSeconds: Double
  public let format: AudioFormat
  public let plaintextByteCount: Int
  public let trigger: WorkflowRunTriggerKind?
  public let outcome: BenchmarkRecordingOutcome
  public let metadata: [String: String]

  public init(
    schemaVersion: Int = 1,
    runID: UUID,
    workflowID: UUID,
    createdAt: Date,
    durationSeconds: Double,
    format: AudioFormat,
    plaintextByteCount: Int,
    trigger: WorkflowRunTriggerKind?,
    outcome: BenchmarkRecordingOutcome,
    metadata: [String: String]
  ) {
    self.schemaVersion = schemaVersion
    self.runID = runID
    self.workflowID = workflowID
    self.createdAt = createdAt
    self.durationSeconds = durationSeconds
    self.format = format
    self.plaintextByteCount = plaintextByteCount
    self.trigger = trigger
    self.outcome = outcome
    self.metadata = metadata
  }
}

public enum BenchmarkRecordingArchiveError: Error, LocalizedError, Sendable, Equatable {
  case invalidEntry
  case protectionUnavailable
  case storageUnavailable
  case unsupportedPayload

  public var errorDescription: String? {
    switch self {
    case .invalidEntry:
      "A benchmark recording could not be authenticated."
    case .protectionUnavailable:
      "A benchmark recording could not be encrypted or opened."
    case .storageUnavailable:
      "Benchmark recording storage is unavailable."
    case .unsupportedPayload:
      "Only Rill-managed file recordings can be archived for benchmarks."
    }
  }
}

public protocol BenchmarkRecordingArchiveStore: Sendable {
  func preserve(
    audio: CapturedAudio,
    runID: UUID,
    workflowID: UUID,
    trigger: WorkflowRunTriggerKind?,
    outcome: BenchmarkRecordingOutcome,
    metadata: [String: String],
    now: Date
  ) async throws -> BenchmarkRecordingReceipt

  func delete(runID: UUID) async throws
  func deleteAll() async throws
}
