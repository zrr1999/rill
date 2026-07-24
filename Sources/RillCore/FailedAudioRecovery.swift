import Foundation

/// A content-free classification returned by the workflow runtime.
public enum WorkflowRunFailureCode: String, Codable, Sendable, Equatable {
    case busy
    case cancelled
    case configuration
    case noSpeech
    case processing
}

/// The minimum failure information needed by reliability features.
///
/// This deliberately excludes localized errors, provider responses, recognized
/// text, and application context.
public struct WorkflowRunFailureSummary: Codable, Sendable, Equatable {
    public var runID: UUID?
    public var stage: WorkflowRunStage
    public var code: WorkflowRunFailureCode

    public init(
        runID: UUID?,
        stage: WorkflowRunStage,
        code: WorkflowRunFailureCode
    ) {
        self.runID = runID
        self.stage = stage
        self.code = code
    }

    /// Delivery may have already produced an external side effect, so audio is
    /// only eligible for a clean reprocessing attempt before delivery begins.
    public var isCapturedAudioRecoveryEligible: Bool {
        guard code != .cancelled, code != .noSpeech else { return false }
        switch stage {
        case .preparing, .capturingInput, .recognizing, .resolving, .transforming:
            return true
        case .delivering, .completed, .failed:
            return false
        }
    }
}

/// A content-free description of an explicitly cancelled workflow run.
public struct WorkflowRunCancelledSummary: Codable, Sendable, Equatable {
    public var runID: UUID
    public var stage: WorkflowRunStage
    public var wasPartiallyCompleted: Bool

    public init(
        runID: UUID,
        stage: WorkflowRunStage,
        wasPartiallyCompleted: Bool
    ) {
        self.runID = runID
        self.stage = stage
        self.wasPartiallyCompleted = wasPartiallyCompleted
    }

    public var termination: WorkflowRunTermination {
        if wasPartiallyCompleted {
            return .partiallyCompleted(code: .cancelled)
        }
        return .cancelled(stage: stage)
    }
}

public enum WorkflowRunExecutionResult: Sendable, Equatable {
    case completed(WorkflowRunSummary)
    case cancelled(WorkflowRunCancelledSummary)
    case failed(WorkflowRunFailureSummary)
}

/// Durable retry state for an encrypted failed recording.
///
/// A retry is marked before plaintext is materialized. If the process exits
/// while recognition is in flight, the next launch keeps the entry blocked
/// instead of silently repeating a potentially billable provider request.
public enum FailedAudioRecoveryStatus: Codable, Sendable, Equatable {
    case available
    case retrying(attemptID: UUID, startedAt: Date)

    public var canRetry: Bool {
        if case .available = self { return true }
        return false
    }
}

/// A content-free index entry for one encrypted failed recording.
public struct FailedAudioRecoveryReceipt: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var originalRunID: UUID
    public var workflowID: UUID
    public var createdAt: Date
    public var expiresAt: Date
    public var durationSeconds: Double
    public var format: AudioFormat
    public var plaintextByteCount: Int
    public var failureStage: WorkflowRunStage
    public var failureCode: WorkflowRunFailureCode
    public var status: FailedAudioRecoveryStatus

    public init(
        id: UUID = UUID(),
        originalRunID: UUID,
        workflowID: UUID,
        createdAt: Date,
        expiresAt: Date,
        durationSeconds: Double,
        format: AudioFormat,
        plaintextByteCount: Int,
        failureStage: WorkflowRunStage,
        failureCode: WorkflowRunFailureCode,
        status: FailedAudioRecoveryStatus = .available
    ) {
        self.id = id
        self.originalRunID = originalRunID
        self.workflowID = workflowID
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.durationSeconds = durationSeconds
        self.format = format
        self.plaintextByteCount = plaintextByteCount
        self.failureStage = failureStage
        self.failureCode = failureCode
        self.status = status
    }

    public func isExpired(at date: Date) -> Bool {
        expiresAt <= date
    }
}

public struct FailedAudioRecoveryPolicy: Sendable, Equatable {
    public static let `default` = FailedAudioRecoveryPolicy(
        retentionInterval: 24 * 60 * 60,
        maximumEntryCount: 3,
        maximumEntryBytes: 16 * 1_024 * 1_024,
        maximumTotalBytes: 32 * 1_024 * 1_024
    )

    public var retentionInterval: TimeInterval
    public var maximumEntryCount: Int
    public var maximumEntryBytes: Int
    public var maximumTotalBytes: Int

    public init(
        retentionInterval: TimeInterval,
        maximumEntryCount: Int,
        maximumEntryBytes: Int,
        maximumTotalBytes: Int
    ) {
        self.retentionInterval = retentionInterval
        self.maximumEntryCount = maximumEntryCount
        self.maximumEntryBytes = maximumEntryBytes
        self.maximumTotalBytes = maximumTotalBytes
    }
}

public enum FailedAudioRecoveryError: Error, LocalizedError, Sendable, Equatable {
    case entryTooLarge
    case expired
    case invalidEntry
    case notFound
    case protectionUnavailable
    case retryOutcomeUnknown
    case storageUnavailable
    case unsupportedPayload

    public var errorDescription: String? {
        switch self {
        case .entryTooLarge:
            return "The failed recording exceeds the recovery size limit."
        case .expired:
            return "The failed recording has expired."
        case .invalidEntry:
            return "The failed recording could not be authenticated."
        case .notFound:
            return "The failed recording is no longer available."
        case .protectionUnavailable:
            return "The failed recording could not be protected or opened."
        case .retryOutcomeUnknown:
            return "A previous retry may have reached the speech provider, so it cannot be repeated safely."
        case .storageUnavailable:
            return "Failed recording recovery storage is unavailable."
        case .unsupportedPayload:
            return "Only file-backed recordings can be retained for recovery."
        }
    }
}

public protocol FailedAudioRecoveryStore: Sendable {
    func preserve(
        audio: CapturedAudio,
        originalRunID: UUID,
        workflowID: UUID,
        failure: WorkflowRunFailureSummary,
        now: Date
    ) async throws -> FailedAudioRecoveryReceipt

    func receipts(now: Date) async throws -> [FailedAudioRecoveryReceipt]
    func materializeForRetry(
        id: UUID,
        attemptID: UUID,
        now: Date
    ) async throws -> CapturedAudio
    func restoreAfterFailedRetry(id: UUID, attemptID: UUID) async throws
    func delete(id: UUID) async throws
    func deleteAll() async throws
    func purgeExpired(now: Date) async throws -> Int
}

public extension FailedAudioRecoveryStore {
    func receipts() async throws -> [FailedAudioRecoveryReceipt] {
        try await receipts(now: Date())
    }

    func materializeForRetry(id: UUID, attemptID: UUID) async throws -> CapturedAudio {
        try await materializeForRetry(id: id, attemptID: attemptID, now: Date())
    }

    func purgeExpired() async throws -> Int {
        try await purgeExpired(now: Date())
    }
}
