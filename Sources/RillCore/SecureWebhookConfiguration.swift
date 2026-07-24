import Foundation

public struct WebhookConfigurationReference: RawRepresentable, Codable, Hashable, Sendable {
    public static let formatPrefix = "workflow.webhook.v1"

    public let workflowID: UUID
    public let actionIndex: Int

    public var rawValue: String {
        "\(Self.formatPrefix):\(workflowID.uuidString.lowercased()):\(actionIndex)"
    }

    public init?(workflowID: UUID, actionIndex: Int) {
        guard actionIndex >= 0 else { return nil }
        self.workflowID = workflowID
        self.actionIndex = actionIndex
    }

    public init?(rawValue: String) {
        let components = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard
            components.count == 3,
            components[0] == Substring(Self.formatPrefix),
            let workflowID = UUID(uuidString: String(components[1])),
            let actionIndex = Int(components[2]),
            actionIndex >= 0,
            let canonical = Self(workflowID: workflowID, actionIndex: actionIndex),
            canonical.rawValue == rawValue
        else {
            return nil
        }
        self = canonical
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let reference = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid secure Webhook configuration reference."
            )
        }
        self = reference
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum WebhookProtectedConfigurationError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
    case emptyPayload
    case unsupportedKey

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Unsupported protected Webhook configuration schema version \(version)."
        case .emptyPayload:
            return "Protected Webhook configuration must contain at least one value."
        case .unsupportedKey:
            return "Protected Webhook configuration contains an unsupported key."
        }
    }
}

public struct WebhookProtectedConfiguration: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let protectedKeys: Set<String> = [
        ExternalOutputActionConfigurationKey.webhookURL,
        ExternalOutputActionConfigurationKey.webhookHeadersJSON,
    ]

    public let schemaVersion: Int
    public let values: [String: String]

    public init(
        schemaVersion: Int = WebhookProtectedConfiguration.currentSchemaVersion,
        values: [String: String]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WebhookProtectedConfigurationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard !values.isEmpty else {
            throw WebhookProtectedConfigurationError.emptyPayload
        }
        if values.keys.contains(where: { !Self.protectedKeys.contains($0) }) {
            throw WebhookProtectedConfigurationError.unsupportedKey
        }
        self.schemaVersion = schemaVersion
        self.values = values
    }

    public static func extractingPlaintext(
        from configuration: [String: String]
    ) throws -> WebhookProtectedConfiguration? {
        let values = configuration.filter { protectedKeys.contains($0.key) }
        guard !values.isEmpty else { return nil }
        return try WebhookProtectedConfiguration(values: values)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let values = try container.decode([String: String].self, forKey: .values)
        do {
            try self.init(schemaVersion: schemaVersion, values: values)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .values,
                in: container,
                debugDescription: error.localizedDescription
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case values
    }
}

public protocol SecureWebhookConfigurationStore: Sendable {
    func configuration(
        for reference: WebhookConfigurationReference
    ) async throws -> WebhookProtectedConfiguration?

    func setConfiguration(
        _ configuration: WebhookProtectedConfiguration,
        for reference: WebhookConfigurationReference
    ) async throws
}
