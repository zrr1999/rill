import Foundation
import Security
import RillCore

struct KeychainWebhookItemScope: Hashable, Sendable {
    let service: String
    let account: String
    let usesDataProtectionKeychain: Bool

    var query: [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
        if usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain] = kCFBooleanTrue as Any
        }
        return query
    }
}

protocol KeychainWebhookItemAccess: Sendable {
    func data(for scope: KeychainWebhookItemScope) async throws -> Data?
    func setData(_ data: Data, for scope: KeychainWebhookItemScope) async throws
    func removeData(for scope: KeychainWebhookItemScope, operation: String) async throws
}

private struct SecurityKeychainWebhookItemAccess: KeychainWebhookItemAccess {
    func data(for scope: KeychainWebhookItemScope) async throws -> Data? {
        var query = scope.query
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainWebhookConfigurationStore.StoreError.operationFailed(
                operation: "read",
                status: status
            )
        }
        guard let data = result as? Data else {
            throw KeychainWebhookConfigurationStore.StoreError.invalidStoredDataType
        }
        return data
    }

    func setData(_ data: Data, for scope: KeychainWebhookItemScope) async throws {
        let query = scope.query
        var attributes: [CFString: Any] = [kSecValueData: data]
        if scope.usesDataProtectionKeychain {
            attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainWebhookConfigurationStore.StoreError.operationFailed(
                operation: "update",
                status: updateStatus
            )
        }

        var newItem = query
        for (attribute, value) in attributes {
            newItem[attribute] = value
        }
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainWebhookConfigurationStore.StoreError.operationFailed(
                operation: "add",
                status: addStatus
            )
        }
    }

    func removeData(for scope: KeychainWebhookItemScope, operation: String) async throws {
        let status = SecItemDelete(scope.query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainWebhookConfigurationStore.StoreError.operationFailed(
                operation: operation,
                status: status
            )
        }
    }
}

/// Stores protected Webhook action configuration as generic-password items.
///
/// Entitled builds use the local Data Protection Keychain. Source builds without
/// an application identifier use the encrypted login Keychain and migrate those
/// compatibility items only after an exact Data Protection readback succeeds.
public actor KeychainWebhookConfigurationStore: SecureWebhookConfigurationStore {
    public enum StoreError: Error, LocalizedError, Sendable, Equatable {
        case operationFailed(operation: String, status: OSStatus)
        case invalidStoredDataType
        case invalidStoredConfiguration(reference: WebhookConfigurationReference, reason: String)
        case encodingFailed(reference: WebhookConfigurationReference, reason: String)
        case verificationFailed(reference: WebhookConfigurationReference)

        public var errorDescription: String? {
            switch self {
            case .operationFailed(let operation, let status):
                let description = SecCopyErrorMessageString(status, nil) as String?
                    ?? "OSStatus \(status)"
                return "Keychain Webhook configuration \(operation) failed: \(description)."
            case .invalidStoredDataType:
                return "Keychain returned Webhook configuration in an unexpected data type."
            case .invalidStoredConfiguration(let reference, let reason):
                return "Protected Webhook configuration \(reference.rawValue) is invalid: \(reason)."
            case .encodingFailed(let reference, let reason):
                return "Protected Webhook configuration \(reference.rawValue) could not be encoded: \(reason)."
            case .verificationFailed(let reference):
                return "Protected Webhook configuration \(reference.rawValue) did not match its Keychain readback."
            }
        }
    }

    public nonisolated let service: String
    nonisolated let usesDataProtectionKeychain: Bool

    private let itemAccess: any KeychainWebhookItemAccess

    public init(service: String) {
        self.init(
            service: service,
            useDataProtectionKeychain: Self.currentProcessHasApplicationIdentifierEntitlement(),
            itemAccess: SecurityKeychainWebhookItemAccess()
        )
    }

    init(
        service: String,
        useDataProtectionKeychain: Bool,
        itemAccess: any KeychainWebhookItemAccess
    ) {
        precondition(!service.isEmpty, "A stable Keychain service identifier is required.")
        self.service = service
        self.usesDataProtectionKeychain = useDataProtectionKeychain
        self.itemAccess = itemAccess
    }

    public func configuration(
        for reference: WebhookConfigurationReference
    ) async throws -> WebhookProtectedConfiguration? {
        guard usesDataProtectionKeychain else {
            guard let data = try await itemAccess.data(for: scope(for: reference, dataProtection: false)) else {
                return nil
            }
            return try decode(data, for: reference)
        }

        let protectedScope = scope(for: reference, dataProtection: true)
        if let protectedData = try await itemAccess.data(for: protectedScope) {
            let configuration = try decode(protectedData, for: reference)
            try await itemAccess.removeData(
                for: scope(for: reference, dataProtection: false),
                operation: "legacy cleanup"
            )
            return configuration
        }

        let legacyScope = scope(for: reference, dataProtection: false)
        guard let legacyData = try await itemAccess.data(for: legacyScope) else {
            return nil
        }
        let configuration = try decode(legacyData, for: reference)
        try await writeAndVerify(configuration, encodedData: legacyData, for: reference, to: protectedScope)
        try await itemAccess.removeData(for: legacyScope, operation: "legacy cleanup")
        return configuration
    }

    public func setConfiguration(
        _ configuration: WebhookProtectedConfiguration,
        for reference: WebhookConfigurationReference
    ) async throws {
        let encodedData = try encode(configuration, for: reference)
        try await writeAndVerify(
            configuration,
            encodedData: encodedData,
            for: reference,
            to: scope(for: reference, dataProtection: usesDataProtectionKeychain)
        )

        if usesDataProtectionKeychain {
            try await itemAccess.removeData(
                for: scope(for: reference, dataProtection: false),
                operation: "legacy cleanup"
            )
        }
    }

    nonisolated func baseQuery(
        for reference: WebhookConfigurationReference,
        useDataProtectionKeychain: Bool
    ) -> [CFString: Any] {
        scope(for: reference, dataProtection: useDataProtectionKeychain).query
    }

    private func writeAndVerify(
        _ configuration: WebhookProtectedConfiguration,
        encodedData: Data,
        for reference: WebhookConfigurationReference,
        to scope: KeychainWebhookItemScope
    ) async throws {
        try await itemAccess.setData(encodedData, for: scope)
        guard let readback = try await itemAccess.data(for: scope), readback == encodedData else {
            throw StoreError.verificationFailed(reference: reference)
        }
        guard try decode(readback, for: reference) == configuration else {
            throw StoreError.verificationFailed(reference: reference)
        }
    }

    private func encode(
        _ configuration: WebhookProtectedConfiguration,
        for reference: WebhookConfigurationReference
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(configuration)
        } catch {
            throw StoreError.encodingFailed(
                reference: reference,
                reason: String(describing: error)
            )
        }
    }

    private func decode(
        _ data: Data,
        for reference: WebhookConfigurationReference
    ) throws -> WebhookProtectedConfiguration {
        do {
            let json = try JSONSerialization.jsonObject(with: data)
            guard let object = json as? [String: Any] else {
                throw StrictDecodingError.expectedObject
            }
            guard Set(object.keys) == ["schemaVersion", "values"] else {
                throw StrictDecodingError.unexpectedTopLevelKeys
            }
            guard
                let schemaVersion = object["schemaVersion"] as? NSNumber,
                CFGetTypeID(schemaVersion) != CFBooleanGetTypeID()
            else {
                throw StrictDecodingError.invalidSchemaVersion
            }
            guard let values = object["values"] as? [String: Any] else {
                throw StrictDecodingError.invalidValues
            }
            guard values.values.allSatisfy({ $0 is String }) else {
                throw StrictDecodingError.invalidValues
            }
            return try JSONDecoder().decode(WebhookProtectedConfiguration.self, from: data)
        } catch {
            throw StoreError.invalidStoredConfiguration(
                reference: reference,
                reason: String(describing: error)
            )
        }
    }

    private nonisolated func scope(
        for reference: WebhookConfigurationReference,
        dataProtection: Bool
    ) -> KeychainWebhookItemScope {
        KeychainWebhookItemScope(
            service: service,
            account: reference.rawValue,
            usesDataProtectionKeychain: dataProtection
        )
    }

    private enum StrictDecodingError: Error {
        case expectedObject
        case unexpectedTopLevelKeys
        case invalidSchemaVersion
        case invalidValues
    }

    private static func currentProcessHasApplicationIdentifierEntitlement() -> Bool {
        guard
            let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.application-identifier" as CFString,
                nil
            )
        else {
            return false
        }
        return value is String
    }
}
