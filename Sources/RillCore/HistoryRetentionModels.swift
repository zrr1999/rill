import Foundation

/// The period for which local history remains available before maintenance removes it.
public enum HistoryRetentionPeriod: String, Codable, CaseIterable, Identifiable, Sendable, Equatable {
    case oneDay = "one-day"
    case oneWeek = "one-week"
    case thirtyDays = "thirty-days"
    case oneYear = "one-year"
    case forever

    public static let defaultPeriod: Self = .thirtyDays

    public var id: String { rawValue }

    /// A fixed retention duration. `nil` means that automatic pruning is disabled.
    public var duration: TimeInterval? {
        switch self {
        case .oneDay:
            return 86_400
        case .oneWeek:
            return 604_800
        case .thirtyDays:
            return 2_592_000
        case .oneYear:
            return 31_536_000
        case .forever:
            return nil
        }
    }

    /// Returns the point-in-time cutoff captured from the caller's injected clock.
    public func cutoffDate(relativeTo now: Date) -> Date? {
        duration.map { now.addingTimeInterval(-$0) }
    }
}

/// An idempotent logical operation recorded before local-history maintenance starts.
public enum LocalHistoryMaintenanceOperation: Sendable, Equatable {
    case prune(olderThan: Date)
    case clearAll
}

extension LocalHistoryMaintenanceOperation: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case olderThan
    }

    private enum Kind: String, Codable {
        case prune
        case clearAll = "clear-all"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .prune:
            self = .prune(olderThan: try container.decode(Date.self, forKey: .olderThan))
        case .clearAll:
            guard !container.contains(.olderThan) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .olderThan,
                    in: container,
                    debugDescription: "A clear-all operation must not contain a cutoff."
                )
            }
            self = .clearAll
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .prune(let cutoff):
            try container.encode(Kind.prune, forKey: .kind)
            try container.encode(cutoff, forKey: .olderThan)
        case .clearAll:
            try container.encode(Kind.clearAll, forKey: .kind)
        }
    }
}

public enum LocalHistoryMaintenancePhase: String, Codable, Sendable, Equatable {
    case logicalPending = "logical-pending"
    case residuePending = "residue-pending"
}

public enum RunHistoryGenerationError: Error, Sendable, Equatable {
    case invalidGeneration
    case generationExhausted
    case invalidClearTransition
    case clearTransitionConflict
    case unsupported
}

/// A durable logical coordinate captured when an asynchronous run-history write begins.
/// Wall-clock timestamps remain presentation and retention data; they do not order clears.
public struct RunHistoryWriteGeneration: Sendable, Equatable, Comparable, Codable {
    public static let initial = try! Self(0)

    public let value: Int64

    public init(_ value: Int64) throws {
        guard value >= 0 else { throw RunHistoryGenerationError.invalidGeneration }
        self.value = value
    }

    public func advanced() throws -> Self {
        guard value < Int64.max else { throw RunHistoryGenerationError.generationExhausted }
        return try Self(value + 1)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(Int64.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// A compare-and-swap clear coordinate. `intentID` distinguishes an idempotent replay
/// from a concurrent clear that selected the same next generation.
public struct RunHistoryClearTransition: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case intentID
        case previousGeneration
        case nextGeneration
    }

    public let intentID: UUID
    public let previousGeneration: RunHistoryWriteGeneration
    public let nextGeneration: RunHistoryWriteGeneration

    public init(
        intentID: UUID = UUID(),
        previousGeneration: RunHistoryWriteGeneration,
        nextGeneration: RunHistoryWriteGeneration
    ) throws {
        guard previousGeneration.value < Int64.max,
              nextGeneration.value == previousGeneration.value + 1 else {
            throw RunHistoryGenerationError.invalidClearTransition
        }
        self.intentID = intentID
        self.previousGeneration = previousGeneration
        self.nextGeneration = nextGeneration
    }

    public init(
        intentID: UUID = UUID(),
        advancing previousGeneration: RunHistoryWriteGeneration
    ) throws {
        try self.init(
            intentID: intentID,
            previousGeneration: previousGeneration,
            nextGeneration: previousGeneration.advanced()
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            intentID: container.decode(UUID.self, forKey: .intentID),
            previousGeneration: container.decode(
                RunHistoryWriteGeneration.self,
                forKey: .previousGeneration
            ),
            nextGeneration: container.decode(
                RunHistoryWriteGeneration.self,
                forKey: .nextGeneration
            )
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(intentID, forKey: .intentID)
        try container.encode(previousGeneration, forKey: .previousGeneration)
        try container.encode(nextGeneration, forKey: .nextGeneration)
    }
}

/// A versioned, replayable maintenance intent stored before destructive work begins.
///
/// Clipboard and run operations are independent so one point-in-time snapshot can
/// preserve different retention cutoffs for the two history domains.
public struct LocalHistoryMaintenanceState: Codable, Sendable, Equatable {
    /// Schema 1 covered run records. Schema 2 added diagnostics. Schema 3 also
    /// covered durable, content-free workflow run receipts. Schema 4 bounded
    /// clear intents with wall-clock timestamps. Schema 5 gives run-history
    /// clears a replayable logical-generation transition while retaining the
    /// timestamp boundary for clipboard history and one-time schema-4 replay.
    public static let currentSchemaVersion = 5

    public var schemaVersion: Int
    public var clipboardOperation: LocalHistoryMaintenanceOperation?
    public var runOperation: LocalHistoryMaintenanceOperation?
    /// Inclusive record-timestamp upper bound captured before a clear-all intent is persisted.
    /// In schema 5 it applies only to clipboard history.
    public var clearThrough: Date?
    /// The durable CAS coordinate used by a schema-5 run-history clear.
    public var runClearTransition: RunHistoryClearTransition?
    /// A one-time timestamp bridge when a pending schema-4 run clear is upgraded.
    public var legacyRunClearThrough: Date?
    public var phase: LocalHistoryMaintenancePhase

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        clipboardOperation: LocalHistoryMaintenanceOperation? = nil,
        runOperation: LocalHistoryMaintenanceOperation? = nil,
        clearThrough: Date? = nil,
        runClearTransition: RunHistoryClearTransition? = nil,
        legacyRunClearThrough: Date? = nil,
        phase: LocalHistoryMaintenancePhase = .logicalPending
    ) {
        self.schemaVersion = schemaVersion
        self.clipboardOperation = clipboardOperation
        self.runOperation = runOperation
        self.clearThrough = clearThrough
        self.runClearTransition = runClearTransition
        self.legacyRunClearThrough = legacyRunClearThrough
        self.phase = phase
    }

    public var hasPendingOperations: Bool {
        clipboardOperation != nil || runOperation != nil
    }

    public var containsClearAllOperation: Bool {
        [clipboardOperation, runOperation].contains { operation in
            guard case .clearAll? = operation else { return false }
            return true
        }
    }
}
