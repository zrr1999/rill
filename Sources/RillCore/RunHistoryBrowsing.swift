import Foundation

public enum RunHistoryBrowseScope: String, Codable, Sendable, Equatable, CaseIterable {
    case allRuns = "all-runs"
    case voiceResults = "voice-results"
}

/// Controls whether a browsing session may open body-bearing history fields.
/// The value is captured in the session so a continuation cursor cannot
/// silently widen access on a later page.
public enum RunHistoryContentAccess: String, Codable, Sendable, Equatable, CaseIterable {
    case metadataOnly = "metadata-only"
    case restrictedPreview = "restricted-preview"
    case full

    public static let restrictedPreviewCharacterLimit = 96
}

public struct RunHistorySortKey: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let entryID: UUID

    public init(timestamp: Date, entryID: UUID) {
        self.timestamp = timestamp
        self.entryID = entryID
    }
}

public enum RunHistoryBrowsingError: Error, Sendable, Equatable {
    case invalidLimit(Int)
    case invalidSnapshotWriteOrdinal(Int64)
    case writeOrdinalExhausted
    case sessionInvalidated(
        expected: RunHistoryWriteGeneration,
        actual: RunHistoryWriteGeneration
    )
    case missingEntrySource
    case inconsistentEntrySource
}

public struct RunHistoryReadSession: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case generation
        case snapshotWriteOrdinal
        case retentionCutoff
        case scope
        case contentAccess
    }

    public let generation: RunHistoryWriteGeneration
    public let snapshotWriteOrdinal: Int64
    public let retentionCutoff: Date?
    public let scope: RunHistoryBrowseScope
    public let contentAccess: RunHistoryContentAccess

    public init(
        generation: RunHistoryWriteGeneration,
        snapshotWriteOrdinal: Int64,
        retentionCutoff: Date?,
        scope: RunHistoryBrowseScope,
        contentAccess: RunHistoryContentAccess
    ) throws {
        guard snapshotWriteOrdinal >= 0 else {
            throw RunHistoryBrowsingError.invalidSnapshotWriteOrdinal(snapshotWriteOrdinal)
        }
        self.generation = generation
        self.snapshotWriteOrdinal = snapshotWriteOrdinal
        self.retentionCutoff = retentionCutoff
        self.scope = scope
        self.contentAccess = contentAccess
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            generation: container.decode(RunHistoryWriteGeneration.self, forKey: .generation),
            snapshotWriteOrdinal: container.decode(Int64.self, forKey: .snapshotWriteOrdinal),
            retentionCutoff: container.decodeIfPresent(Date.self, forKey: .retentionCutoff),
            scope: container.decode(RunHistoryBrowseScope.self, forKey: .scope),
            contentAccess: container.decode(RunHistoryContentAccess.self, forKey: .contentAccess)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generation, forKey: .generation)
        try container.encode(snapshotWriteOrdinal, forKey: .snapshotWriteOrdinal)
        try container.encodeIfPresent(retentionCutoff, forKey: .retentionCutoff)
        try container.encode(scope, forKey: .scope)
        try container.encode(contentAccess, forKey: .contentAccess)
    }
}

public struct RunHistoryCursor: Codable, Sendable, Equatable {
    public let session: RunHistoryReadSession
    public let after: RunHistorySortKey

    public init(session: RunHistoryReadSession, after: RunHistorySortKey) {
        self.session = session
        self.after = after
    }
}

/// Plaintext, body-free columns that are safe to expose without opening the
/// protected history record. `hasNonemptyFinalText` reveals presence only.
public struct RunHistoryRecordMetadata: Sendable, Equatable {
    public let recordID: UUID
    public let runID: UUID?
    public let workflowID: UUID?
    public let timestamp: Date
    public let isRecordRelated: Bool
    public let outcome: HistoryOutcome
    public let trigger: WorkflowRunTriggerKind?
    public let hasNonemptyFinalText: Bool

    public init(
        recordID: UUID,
        runID: UUID?,
        workflowID: UUID?,
        timestamp: Date,
        isRecordRelated: Bool,
        outcome: HistoryOutcome,
        trigger: WorkflowRunTriggerKind?,
        hasNonemptyFinalText: Bool
    ) {
        self.recordID = recordID
        self.runID = runID
        self.workflowID = workflowID
        self.timestamp = timestamp
        self.isRecordRelated = isRecordRelated
        self.outcome = outcome
        self.trigger = trigger
        self.hasNonemptyFinalText = hasNonemptyFinalText
    }
}

/// One unified timeline item. Receipts are authoritative when present; an
/// orphan record remains representable through `recordMetadata` even when its
/// protected body is intentionally unopened.
public struct RunHistoryEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let recordMetadata: RunHistoryRecordMetadata?
    public let record: WorkflowResultRecord?
    public let receipt: WorkflowRunReceipt?

    public init(
        id: UUID,
        timestamp: Date,
        recordMetadata: RunHistoryRecordMetadata? = nil,
        record: WorkflowResultRecord? = nil,
        receipt: WorkflowRunReceipt? = nil
    ) throws {
        guard recordMetadata != nil || receipt != nil else {
            throw RunHistoryBrowsingError.missingEntrySource
        }
        if let record {
            guard let recordMetadata, record.id == recordMetadata.recordID else {
                throw RunHistoryBrowsingError.inconsistentEntrySource
            }
        }
        if let receipt, receipt.runID != id {
            throw RunHistoryBrowsingError.inconsistentEntrySource
        }
        self.id = id
        self.timestamp = timestamp
        self.recordMetadata = recordMetadata
        self.record = record
        self.receipt = receipt
    }

    public var workflowID: UUID? {
        receipt?.workflowID ?? recordMetadata?.workflowID
    }

    public var trigger: WorkflowRunTriggerKind? {
        receipt?.trigger ?? recordMetadata?.trigger
    }
}

public struct RunHistoryPage: Sendable, Equatable {
    public let session: RunHistoryReadSession
    public let entries: [RunHistoryEntry]
    public let nextCursor: RunHistoryCursor?

    public init(
        session: RunHistoryReadSession,
        entries: [RunHistoryEntry],
        nextCursor: RunHistoryCursor?
    ) {
        self.session = session
        self.entries = entries
        self.nextCursor = nextCursor
    }
}

public enum RunHistoryPageRequest: Sendable, Equatable {
    case first(
        scope: RunHistoryBrowseScope,
        retentionCutoff: Date?,
        contentAccess: RunHistoryContentAccess,
        limit: Int
    )
    case next(cursor: RunHistoryCursor, limit: Int)

    public var limit: Int {
        switch self {
        case .first(_, _, _, let limit), .next(_, let limit):
            return limit
        }
    }
}

public protocol RunHistoryBrowsing: Sendable {
    func page(_ request: RunHistoryPageRequest) async throws -> RunHistoryPage

    /// Finds an entry inside an already-captured snapshot.
    func page(
        containing entryID: UUID,
        in session: RunHistoryReadSession,
        limit: Int
    ) async throws -> RunHistoryPage?

    /// Captures a fresh snapshot and finds the page containing a deep-linked entry.
    func page(
        containing entryID: UUID,
        scope: RunHistoryBrowseScope,
        retentionCutoff: Date?,
        contentAccess: RunHistoryContentAccess,
        limit: Int
    ) async throws -> RunHistoryPage?
}
