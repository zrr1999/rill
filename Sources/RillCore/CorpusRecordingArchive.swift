import Foundation

public enum CorpusRecordingOutcome: String, Codable, Sendable, Equatable {
  case completed
  case cancelled
  case failed
}

/// Content-free metadata for one encrypted corpus recording.
///
/// Transcript bodies stay in run history and are joined by `runID` only when
/// the user exports a private evaluation corpus.
public struct CorpusRecordingReceipt: Codable, Sendable, Equatable {
  public let schemaVersion: Int
  public let runID: UUID
  public let workflowID: UUID
  public let createdAt: Date
  public let durationSeconds: Double
  public let format: AudioFormat
  public let plaintextByteCount: Int
  public let trigger: WorkflowRunTriggerKind?
  public let outcome: CorpusRecordingOutcome
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
    outcome: CorpusRecordingOutcome,
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

public enum CorpusRecordingArchiveError: Error, LocalizedError, Sendable, Equatable {
  case invalidEntry
  case protectionUnavailable
  case storageUnavailable
  case unsupportedPayload

  public var errorDescription: String? {
    switch self {
    case .invalidEntry:
      "A corpus recording could not be authenticated."
    case .protectionUnavailable:
      "A corpus recording could not be encrypted or opened."
    case .storageUnavailable:
      "Corpus recording storage is unavailable."
    case .unsupportedPayload:
      "Only Rill-managed file recordings can be archived for evaluation."
    }
  }
}

public protocol CorpusRecordingArchiveStore: Sendable {
  func preserve(
    audio: CapturedAudio,
    runID: UUID,
    workflowID: UUID,
    trigger: WorkflowRunTriggerKind?,
    outcome: CorpusRecordingOutcome,
    metadata: [String: String],
    now: Date
  ) async throws -> CorpusRecordingReceipt

  func delete(runID: UUID) async throws
  func deleteAll() async throws
}

/// Explicit evaluation reads are separate from the live capture write port.
public struct CorpusRecording: Sendable {
  public let receipt: CorpusRecordingReceipt
  public let audioBytes: Data

  public init(receipt: CorpusRecordingReceipt, audioBytes: Data) {
    self.receipt = receipt
    self.audioBytes = audioBytes
  }
}

public protocol CorpusRecordingArchiveReading: Sendable {
  func recordingIDs() async throws -> [UUID]
  func receipt(runID: UUID) async throws -> CorpusRecordingReceipt
  func recording(runID: UUID) async throws -> CorpusRecording
}

public enum CorpusEvidenceKind: String, Codable, Sendable, CaseIterable {
  case microphone, synthetic
  case publicFixture = "public_fixture"
}

public enum CorpusSplit: String, Codable, Sendable, CaseIterable {
  case development, validation
}

public struct CorpusSelection: Sendable, Equatable {
  public let runIDs: [UUID]
  public let evidenceKind: CorpusEvidenceKind
  public let split: CorpusSplit

  public init(runIDs: [UUID], evidenceKind: CorpusEvidenceKind, split: CorpusSplit) {
    self.runIDs = runIDs
    self.evidenceKind = evidenceKind
    self.split = split
  }
}

public protocol CorpusExporting: Sendable {
  func export(_ selection: CorpusSelection, to directory: URL) async throws -> URL
}

public enum CorpusExportError: Error, Sendable, Equatable {
  case cleanupPending(URL)
}
