import Foundation

public enum WorkflowRunStage: String, Codable, Sendable, Equatable {
    case preparing
    case capturingInput
    case recognizing
    case resolving
    case transforming
    case delivering
    case completed
    case failed
}

public struct WorkflowTriggerEvent: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var binding: TriggerBinding
    public var workflowID: UUID?
    public var sourceID: String
    public var metadata: [String: String]
    public var triggeredAt: Date

    public init(
        id: UUID = UUID(),
        binding: TriggerBinding,
        workflowID: UUID? = nil,
        sourceID: String,
        metadata: [String: String] = [:],
        triggeredAt: Date = Date()
    ) {
        self.id = id
        self.binding = binding
        self.workflowID = workflowID
        self.sourceID = sourceID
        self.metadata = metadata
        self.triggeredAt = triggeredAt
    }
}

public struct AudioProcessingQueueSnapshot: Codable, Sendable, Equatable {
    public var processingRunID: UUID?
    public var workflow: WorkflowPresentation?
    public var pendingCount: Int
    public var updatedAt: Date

    public init(
        processingRunID: UUID? = nil,
        workflow: WorkflowPresentation? = nil,
        pendingCount: Int,
        updatedAt: Date = Date()
    ) {
        self.processingRunID = processingRunID
        self.workflow = workflow
        self.pendingCount = pendingCount
        self.updatedAt = updatedAt
    }

    public var isVisible: Bool {
        processingRunID != nil || pendingCount > 0
    }

    public var queuedCount: Int {
        max(pendingCount - (processingRunID == nil ? 0 : 1), 0)
    }
}

public struct WorkflowRunStageSnapshot: Codable, Sendable, Equatable {
    public var runID: UUID
    public var workflowID: UUID
    public var workflow: WorkflowPresentation
    public var stage: WorkflowRunStage
    public var updatedAt: Date

    public init(
        runID: UUID,
        workflowID: UUID,
        workflow: WorkflowPresentation,
        stage: WorkflowRunStage,
        updatedAt: Date = Date()
    ) {
        self.runID = runID
        self.workflowID = workflowID
        self.workflow = workflow
        self.stage = stage
        self.updatedAt = updatedAt
    }
}

// MARK: - Content-free terminal run receipts

/// A privacy-bounded duration classification used by persisted run receipts.
///
/// Overall runs retain buckets; selected processing steps and output actions
/// can additionally retain their measured duration in milliseconds.
public enum WorkflowRunDurationBucket: String, Codable, Sendable, Equatable, CaseIterable {
    case under250ms
    case ms250To999
    case s1To4
    case s5To14
    case s15To59
    case m1Plus
    case unavailable

    public static func classify(elapsedNanoseconds: UInt64) -> Self {
        switch elapsedNanoseconds {
        case ..<250_000_000:
            return .under250ms
        case ..<1_000_000_000:
            return .ms250To999
        case ..<5_000_000_000:
            return .s1To4
        case ..<15_000_000_000:
            return .s5To14
        case ..<60_000_000_000:
            return .s15To59
        default:
            return .m1Plus
        }
    }
}

/// The actual invocation source, rather than the workflow's declared binding.
public enum WorkflowRunTriggerKind: String, Codable, Sendable, Equatable, CaseIterable {
    case manual
    case menuBar
    case hotkey
    case wakeWord
    case recordCollectionEvent
    case recordDelivery
    case recordUse
    case recordReplay
    case failedAudioRecovery

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        let canonicalValue = switch value {
        case "stackDelivery": "recordDelivery"
        case "clipboardUse": "recordUse"
        case "clipboardReplay": "recordReplay"
        default: value
        }
        guard let trigger = Self(rawValue: canonicalValue) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown workflow run trigger."
            )
        }
        self = trigger
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Whether this invocation obtains its body from a voice capture.
    ///
    /// Record-derived invocations can reuse a workflow that declares a
    /// recognizer, so workflow configuration is not a safe proxy for whether
    /// a history body may be retained or displayed.
    public var isVoiceCapture: Bool {
        switch self {
        case .manual, .menuBar, .hotkey, .wakeWord, .failedAudioRecovery:
            return true
        case .recordCollectionEvent, .recordDelivery, .recordUse, .recordReplay:
            return false
        }
    }
}

/// A closed, content-free reason for an invocation that intentionally did not run.
public enum WorkflowRunSkipCode: String, Codable, Sendable, Equatable, CaseIterable {
    case workflowDisabled
    case busy
    case unsupported
    case privacyBlocked
    case eventKindMismatch
    case sourceCollectionMismatch
    case excludedByCaptureTag
    case conditionFailed
    case recordMissing
    case recordChanged
    case loopPrevented
    case allActionsSkipped
    case unclassified

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        let canonicalValue = switch value {
        case "sourceGroupMismatch": "sourceCollectionMismatch"
        case "itemMissing": "recordMissing"
        case "itemChanged": "recordChanged"
        default: value
        }
        guard let code = Self(rawValue: canonicalValue) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown workflow run skip code."
            )
        }
        self = code
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum WorkflowRunOutcome: String, Codable, Sendable, Equatable, CaseIterable {
    case completed
    case partiallyCompleted
    case failed
    case cancelled
    case skipped
}

/// The terminal classification for exactly one run attempt.
public enum WorkflowRunTermination: Codable, Sendable, Equatable {
    case completed
    case partiallyCompleted(code: WorkflowRunFailureCode)
    case failed(stage: WorkflowRunStage, code: WorkflowRunFailureCode)
    case cancelled(stage: WorkflowRunStage)
    case skipped(reason: WorkflowRunSkipCode)

    public var outcome: WorkflowRunOutcome {
        switch self {
        case .completed:
            return .completed
        case .partiallyCompleted:
            return .partiallyCompleted
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        case .skipped:
            return .skipped
        }
    }
}

/// A stable action result code. Associated strings from `ActionResult` never
/// cross into the receipt model.
public enum WorkflowActionResultCode: String, Codable, Sendable, Equatable, CaseIterable {
    case injected
    case copiedToClipboard
    case storedRecord
    case externalOutput
    case skipped
    case cancelled
    case failed

    public init(_ result: ActionResult) {
        switch result {
        case .injected:
            self = .injected
        case .copiedToClipboard:
            self = .copiedToClipboard
        case .storedRecord:
            self = .storedRecord
        case .externalOutput:
            self = .externalOutput
        case .skipped:
            self = .skipped
        case .failed:
            self = .failed
        }
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        if value == "pushedToStack" {
            self = .storedRecord
            return
        }
        guard let result = Self(rawValue: value) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown action result code.")
            )
        }
        self = result
    }
}

public struct WorkflowActionReceipt: Codable, Sendable, Equatable {
    public let actionIndex: Int
    public let result: WorkflowActionResultCode
    public let duration: WorkflowRunDurationBucket
    public let durationMilliseconds: UInt64?

    public init(
        actionIndex: Int,
        result: WorkflowActionResultCode,
        duration: WorkflowRunDurationBucket,
        durationMilliseconds: UInt64? = nil
    ) {
        self.actionIndex = actionIndex
        self.result = result
        self.duration = duration
        self.durationMilliseconds = durationMilliseconds
    }
}

public enum WorkflowStepResultCode: String, Codable, Sendable, Equatable {
    case completed, thenBranch, elseBranch, skipped, failed, cancelled
}

/// The index and kind belong to the frozen run definition, never to the current editor draft.
public struct WorkflowStepReceipt: Codable, Sendable, Equatable {
    public let stepIndex: Int
    public let kind: WorkflowProcessStepKind
    public let result: WorkflowStepResultCode
    public let duration: WorkflowRunDurationBucket
    public let durationMilliseconds: UInt64?

    public init(stepIndex: Int, kind: WorkflowProcessStepKind, result: WorkflowStepResultCode, duration: WorkflowRunDurationBucket, durationMilliseconds: UInt64? = nil) {
        self.stepIndex = stepIndex; self.kind = kind; self.result = result; self.duration = duration
        self.durationMilliseconds = durationMilliseconds
    }
}

public enum WorkflowRunReceiptValidationError: Error, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
    case tooManyActionDetails(Int)
    case invalidStepSequence
    case invalidActionSequence
    case inconsistentTruncationFlag
}

/// An immutable, content-free terminal receipt for one workflow attempt.
///
/// The receipt deliberately excludes workflow names, component identifiers,
/// source metadata, text statistics, free-form failures, paths, endpoints, and
/// exact overall durations. Recording length, selected processing steps and
/// output actions can retain measured milliseconds. `timestamp` is the terminal
/// timeline coordinate; no recording start timestamp is retained.
public struct WorkflowRunReceipt: Identifiable, Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2
    public static let maximumActionDetails = 32

    public let schemaVersion: Int
    public let runID: UUID
    public let workflowID: UUID?
    public let trigger: WorkflowRunTriggerKind
    public let timestamp: Date
    public let duration: WorkflowRunDurationBucket
    public let termination: WorkflowRunTermination
    public let stepDetails: [WorkflowStepReceipt]
    public let actionDetails: [WorkflowActionReceipt]
    public let detailsTruncated: Bool
    public let recordingDurationMilliseconds: UInt64?

    public var id: UUID { runID }
    public var outcome: WorkflowRunOutcome { termination.outcome }

    public init(
        runID: UUID,
        workflowID: UUID?,
        trigger: WorkflowRunTriggerKind,
        timestamp: Date,
        duration: WorkflowRunDurationBucket,
        termination: WorkflowRunTermination,
        stepDetails: [WorkflowStepReceipt] = [],
        actionDetails: [WorkflowActionReceipt] = [],
        detailsTruncated: Bool = false,
        recordingDurationMilliseconds: UInt64? = nil
    ) throws {
        try self.init(
            schemaVersion: Self.currentSchemaVersion,
            runID: runID,
            workflowID: workflowID,
            trigger: trigger,
            timestamp: timestamp,
            duration: duration,
            termination: termination,
            stepDetails: stepDetails,
            actionDetails: actionDetails,
            detailsTruncated: detailsTruncated,
            recordingDurationMilliseconds: recordingDurationMilliseconds
        )
    }

    private init(
        schemaVersion: Int,
        runID: UUID,
        workflowID: UUID?,
        trigger: WorkflowRunTriggerKind,
        timestamp: Date,
        duration: WorkflowRunDurationBucket,
        termination: WorkflowRunTermination,
        stepDetails: [WorkflowStepReceipt],
        actionDetails: [WorkflowActionReceipt],
        detailsTruncated: Bool,
        recordingDurationMilliseconds: UInt64?
    ) throws {
        guard schemaVersion == 1 || schemaVersion == Self.currentSchemaVersion else {
            throw WorkflowRunReceiptValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard actionDetails.count <= Self.maximumActionDetails else {
            throw WorkflowRunReceiptValidationError.tooManyActionDetails(actionDetails.count)
        }
        guard actionDetails.enumerated().allSatisfy({ offset, detail in
            detail.actionIndex == offset
        }) else {
            throw WorkflowRunReceiptValidationError.invalidActionSequence
        }
        guard !detailsTruncated || actionDetails.count == Self.maximumActionDetails else {
            throw WorkflowRunReceiptValidationError.inconsistentTruncationFlag
        }

        guard stepDetails.count <= 256,
              stepDetails.allSatisfy({ (0..<256).contains($0.stepIndex) }),
              Set(stepDetails.map(\.stepIndex)).count == stepDetails.count,
              schemaVersion != 1 || stepDetails.isEmpty else {
            throw WorkflowRunReceiptValidationError.invalidStepSequence
        }
        self.stepDetails = stepDetails
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.workflowID = workflowID
        self.trigger = trigger
        self.timestamp = timestamp
        self.duration = duration
        self.termination = termination
        self.actionDetails = actionDetails
        self.detailsTruncated = detailsTruncated
        self.recordingDurationMilliseconds = recordingDurationMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case runID
        case workflowID
        case trigger
        case timestamp
        case duration
        case termination
        case stepDetails
        case actionDetails
        case detailsTruncated
        case recordingDurationMilliseconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            runID: container.decode(UUID.self, forKey: .runID),
            workflowID: container.decodeIfPresent(UUID.self, forKey: .workflowID),
            trigger: container.decode(WorkflowRunTriggerKind.self, forKey: .trigger),
            timestamp: container.decode(Date.self, forKey: .timestamp),
            duration: container.decode(WorkflowRunDurationBucket.self, forKey: .duration),
            termination: container.decode(WorkflowRunTermination.self, forKey: .termination),
            stepDetails: container.decodeIfPresent([WorkflowStepReceipt].self, forKey: .stepDetails) ?? [],
            actionDetails: container.decode([WorkflowActionReceipt].self, forKey: .actionDetails),
            detailsTruncated: container.decode(Bool.self, forKey: .detailsTruncated),
            recordingDurationMilliseconds: container.decodeIfPresent(UInt64.self, forKey: .recordingDurationMilliseconds)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(runID, forKey: .runID)
        try container.encodeIfPresent(workflowID, forKey: .workflowID)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(duration, forKey: .duration)
        try container.encode(termination, forKey: .termination)
        if schemaVersion >= 2 { try container.encode(stepDetails, forKey: .stepDetails) }
        try container.encode(actionDetails, forKey: .actionDetails)
        try container.encode(detailsTruncated, forKey: .detailsTruncated)
        try container.encodeIfPresent(recordingDurationMilliseconds, forKey: .recordingDurationMilliseconds)
    }
}

public struct WorkflowRunReceiptQuery: Sendable, Equatable {
    public var runID: UUID?
    public var runIDs: Set<UUID>?
    public var workflowID: UUID?
    public var trigger: WorkflowRunTriggerKind?
    public var outcome: WorkflowRunOutcome?
    public var since: Date?
    public var limit: Int?

    public init(
        runID: UUID? = nil,
        runIDs: Set<UUID>? = nil,
        workflowID: UUID? = nil,
        trigger: WorkflowRunTriggerKind? = nil,
        outcome: WorkflowRunOutcome? = nil,
        since: Date? = nil,
        limit: Int? = nil
    ) {
        self.runID = runID
        self.runIDs = runIDs
        self.workflowID = workflowID
        self.trigger = trigger
        self.outcome = outcome
        self.since = since
        self.limit = limit
    }
}

public extension WorkflowRunReceiptQuery {
    static let all = WorkflowRunReceiptQuery()
}
