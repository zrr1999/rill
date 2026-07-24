import Foundation
import Security
import RillCore

/// Stores credentials in the Data Protection Keychain when the signed host has
/// an application-identifier entitlement. Source builds assembled without a
/// provisioning profile retain compatibility with the encrypted login Keychain;
/// an entitled build migrates those legacy items after a verified secure write.
public struct KeychainCredentialStore: SecureCredentialStore {
    public enum StoreError: LocalizedError, Sendable, Equatable {
        case operationFailed(operation: String, status: OSStatus)
        case invalidCredentialData

        public var errorDescription: String? {
            switch self {
            case .operationFailed(let operation, let status):
                let statusDescription = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "Keychain \(operation) failed: \(statusDescription)."
            case .invalidCredentialData:
                return "Keychain returned credential data that is not valid UTF-8."
            }
        }
    }

    public let service: String
    let usesDataProtectionKeychain: Bool

    public init(service: String) {
        self.init(
            service: service,
            useDataProtectionKeychain: Self.currentProcessHasApplicationIdentifierEntitlement()
        )
    }

    init(service: String, useDataProtectionKeychain: Bool) {
        precondition(!service.isEmpty, "A stable Keychain service identifier is required.")
        self.service = service
        self.usesDataProtectionKeychain = useDataProtectionKeychain
    }

    public func credential(for key: SecureCredentialKey) async throws -> String? {
        guard usesDataProtectionKeychain else {
            return try readCredential(for: key, useDataProtectionKeychain: false)
        }

        if let credential = try readCredential(for: key, useDataProtectionKeychain: true) {
            try removeCredential(for: key, useDataProtectionKeychain: false, operation: "legacy cleanup")
            return credential
        }

        guard let legacyCredential = try readCredential(
            for: key,
            useDataProtectionKeychain: false
        ) else {
            return nil
        }

        try writeCredential(legacyCredential, for: key, useDataProtectionKeychain: true)
        try removeCredential(for: key, useDataProtectionKeychain: false, operation: "legacy cleanup")
        return legacyCredential
    }

    public func setCredential(_ value: String, for key: SecureCredentialKey) async throws {
        guard !value.isEmpty else {
            try await removeCredential(for: key)
            return
        }

        try writeCredential(value, for: key, useDataProtectionKeychain: usesDataProtectionKeychain)
        if usesDataProtectionKeychain {
            try removeCredential(for: key, useDataProtectionKeychain: false, operation: "legacy cleanup")
        }
    }

    public func removeCredential(for key: SecureCredentialKey) async throws {
        guard usesDataProtectionKeychain else {
            try removeCredential(for: key, useDataProtectionKeychain: false, operation: "remove")
            return
        }

        var firstError: Error?
        do {
            try removeCredential(for: key, useDataProtectionKeychain: true, operation: "remove")
        } catch {
            firstError = error
        }

        do {
            try removeCredential(for: key, useDataProtectionKeychain: false, operation: "legacy remove")
        } catch {
            if firstError == nil {
                firstError = error
            }
        }

        if let firstError {
            throw firstError
        }
    }

    private func readCredential(
        for key: SecureCredentialKey,
        useDataProtectionKeychain: Bool
    ) throws -> String? {
        var query = baseQuery(for: key, useDataProtectionKeychain: useDataProtectionKeychain)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw StoreError.operationFailed(operation: "read", status: status)
        }
        guard
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            throw StoreError.invalidCredentialData
        }
        return value
    }

    private func writeCredential(
        _ value: String,
        for key: SecureCredentialKey,
        useDataProtectionKeychain: Bool
    ) throws {
        let valueData = Data(value.utf8)
        let query = baseQuery(for: key, useDataProtectionKeychain: useDataProtectionKeychain)
        var attributes: [CFString: Any] = [
            kSecValueData: valueData,
        ]
        if useDataProtectionKeychain {
            attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw StoreError.operationFailed(operation: "update", status: updateStatus)
        }

        var newItem = query
        for (attribute, value) in attributes {
            newItem[attribute] = value
        }
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw StoreError.operationFailed(operation: "add", status: addStatus)
        }
    }

    private func removeCredential(
        for key: SecureCredentialKey,
        useDataProtectionKeychain: Bool,
        operation: String
    ) throws {
        let status = SecItemDelete(
            baseQuery(for: key, useDataProtectionKeychain: useDataProtectionKeychain) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.operationFailed(operation: operation, status: status)
        }
    }

    func baseQuery(
        for key: SecureCredentialKey,
        useDataProtectionKeychain: Bool
    ) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key.rawValue,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
        if useDataProtectionKeychain {
            // On macOS, kSecAttrAccessible only applies to Data Protection or
            // synchronizable Keychain items. Rill keeps credentials local to
            // this Mac, so opt into Data Protection without enabling sync.
            query[kSecUseDataProtectionKeychain] = kCFBooleanTrue as Any
        }
        return query
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
