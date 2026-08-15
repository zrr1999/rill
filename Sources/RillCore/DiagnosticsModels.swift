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
    public var event: String
    public var message: String
    public var metadata: [String: String]

    public init(
        timestamp: Date = Date(),
        runID: UUID? = nil,
        subsystem: SubsystemTag,
        level: DiagnosticLevel,
        event: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.runID = runID
        self.subsystem = subsystem
        self.level = level
        self.event = event
        self.message = message
        self.metadata = metadata
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
