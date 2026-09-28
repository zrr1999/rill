import Foundation

public enum DiagnosticLevel: String, Codable, Sendable, Equatable {
    case debug
    case info
    case warning
    case error
}

public extension DiagnosticLevel {
    var severity: Int {
        switch self {
        case .debug:
            return 0
        case .info:
            return 1
        case .warning:
            return 2
        case .error:
            return 3
        }
    }
}

public enum SubsystemTag: String, Codable, Sendable, Equatable {
    case session
    case records
    case systemClipboard
    case resolver
    case platform
    case providers
    case ui

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        let canonicalValue = switch value {
        case "stack": "records"
        case "clipboard": "systemClipboard"
        default: value
        }
        guard let tag = Self(rawValue: canonicalValue) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown diagnostic subsystem."
            )
        }
        self = tag
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct DiagnosticEvent: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var runID: UUID?
    public var subsystem: SubsystemTag
    public var level: DiagnosticLevel
    public var name: DiagnosticEventName
    public var event: String { name.rawValue }
    public var message: String
    public var metadata: [String: String]

    public init(
        timestamp: Date = Date(),
        runID: UUID? = nil,
        subsystem: SubsystemTag,
        level: DiagnosticLevel,
        event: DiagnosticEventName,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.runID = runID
        self.subsystem = subsystem
        self.level = level
        self.name = event
        self.message = message
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case timestamp, runID, subsystem, level, message, metadata
        case name = "event"
    }

    /// Used only at persisted/external-data boundaries; producers use the typed initializer.
    public init(timestamp: Date = Date(), runID: UUID? = nil, subsystem: SubsystemTag,
                level: DiagnosticLevel, untrustedEvent: String, message: String,
                metadata: [String: String] = [:]) {
        self.init(timestamp: timestamp, runID: runID, subsystem: subsystem, level: level,
                  event: DiagnosticEventName(rawValue: untrustedEvent) ?? .diagnosticEventInvalid,
                  message: message, metadata: metadata)
    }

}

public struct DiagnosticQuery: Sendable, Equatable {
    public var runID: UUID?
    public var subsystem: SubsystemTag?
    public var minimumLevel: DiagnosticLevel?
    public var since: Date?
    public var limit: Int?

    public init(
        runID: UUID? = nil,
        subsystem: SubsystemTag? = nil,
        minimumLevel: DiagnosticLevel? = nil,
        since: Date? = nil,
        limit: Int? = nil
    ) {
        self.runID = runID
        self.subsystem = subsystem
        self.minimumLevel = minimumLevel
        self.since = since
        self.limit = limit
    }
}

/// Monotonic durations shared by content-free diagnostic producers.
public enum DiagnosticTiming {
    public static func milliseconds(since start: ContinuousClock.Instant) -> String {
        let parts = start.duration(to: .now).components
        return String(max(0, parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000))
    }
}
