import Foundation

public enum SecureCredentialKey: String, CaseIterable, Sendable, Equatable {
    case deepgramAPIKey = "provider.deepgram.api-key"
    case legacyWhisperKitModelToken = "provider.whisperkit.model-token"

    public var legacySettingKey: AppSettingKey {
        switch self {
        case .deepgramAPIKey:
            return .deepgramAPIKey
        case .legacyWhisperKitModelToken:
            return .legacyWhisperKitModelToken
        }
    }
}

public protocol SecureCredentialStore: Sendable {
    func credential(for key: SecureCredentialKey) async throws -> String?
    func setCredential(_ value: String, for key: SecureCredentialKey) async throws
    func removeCredential(for key: SecureCredentialKey) async throws
}

public enum SecureCredentialStoreEventKind: String, Sendable, Equatable {
    case migrationSucceeded = "migration.succeeded"
    case migrationFailed = "migration.failed"
    case legacyCleanupFailed = "legacy-cleanup.failed"
    case secureReadFailed = "secure-read.failed"
    case secureWriteFailed = "secure-write.failed"
    case secureRemovalFailed = "secure-removal.failed"
    case legacyReadFailed = "legacy-read.failed"
}

public struct SecureCredentialStoreEvent: Sendable, Equatable {
    public let kind: SecureCredentialStoreEventKind
    public let key: SecureCredentialKey
    public let errorDescription: String?

    public init(
        kind: SecureCredentialStoreEventKind,
        key: SecureCredentialKey,
        errorDescription: String? = nil
    ) {
        self.kind = kind
        self.key = key
        self.errorDescription = errorDescription
    }
}

public enum SecureCredentialMigrationError: LocalizedError, Sendable, Equatable {
    case secureReadFailed(SecureCredentialKey)
    case legacyReadFailed(SecureCredentialKey)
    case migrationWriteFailed(SecureCredentialKey)
    case secureWriteFailed(SecureCredentialKey)
    case legacyRemovalFailed(SecureCredentialKey)
    case secureRemovalFailed(SecureCredentialKey)

    public var errorDescription: String? {
        switch self {
        case .secureReadFailed(let key):
            return "Secure credential storage could not read \(key.rawValue)."
        case .legacyReadFailed(let key):
            return "Legacy settings could not be checked for \(key.rawValue)."
        case .migrationWriteFailed(let key):
            return "The legacy value for \(key.rawValue) could not be migrated to secure storage."
        case .secureWriteFailed(let key):
            return "Secure credential storage could not save \(key.rawValue)."
        case .legacyRemovalFailed(let key):
            return "The legacy value for \(key.rawValue) could not be removed."
        case .secureRemovalFailed(let key):
            return "Secure credential storage could not remove \(key.rawValue)."
        }
    }
}

/// Adds a one-way migration boundary around a secure credential store.
///
/// A legacy value is removed only after the secure write succeeds. Operations for
/// the same credential are serialized so a concurrent startup read cannot race a
/// user edit and write an older SQLite value back into secure storage.
public actor MigratingSecureCredentialStore: SecureCredentialStore {
    public typealias EventReporter = @Sendable (SecureCredentialStoreEvent) async -> Void

    private let secureStore: any SecureCredentialStore
    private let legacySettingsStore: (any SettingsStore)?
    private let eventReporter: EventReporter
    private var operationTails: [SecureCredentialKey: Task<Void, Never>] = [:]

    public init(
        secureStore: any SecureCredentialStore,
        legacySettingsStore: (any SettingsStore)?,
        eventReporter: @escaping EventReporter = { _ in }
    ) {
        self.secureStore = secureStore
        self.legacySettingsStore = legacySettingsStore
        self.eventReporter = eventReporter
    }

    public func credential(for key: SecureCredentialKey) async throws -> String? {
        let secureStore = self.secureStore
        let legacySettingsStore = self.legacySettingsStore
        let eventReporter = self.eventReporter

        return try await enqueue(for: key) {
            try await Self.loadAndMigrate(
                key: key,
                secureStore: secureStore,
                legacySettingsStore: legacySettingsStore,
                eventReporter: eventReporter
            )
        }
    }

    public func setCredential(_ value: String, for key: SecureCredentialKey) async throws {
        if value.isEmpty {
            try await removeCredential(for: key)
            return
        }

        let secureStore = self.secureStore
        let legacySettingsStore = self.legacySettingsStore
        let eventReporter = self.eventReporter

        try await enqueue(for: key) {
            do {
                try await secureStore.setCredential(value, for: key)
            } catch {
                await eventReporter(
                    SecureCredentialStoreEvent(
                        kind: .secureWriteFailed,
                        key: key,
                        errorDescription: error.localizedDescription
                    )
                )
                throw SecureCredentialMigrationError.secureWriteFailed(key)
            }

            await Self.removeLegacyValueAfterSecureWrite(
                for: key,
                from: legacySettingsStore,
                eventReporter: eventReporter
            )
        }
    }

    public func removeCredential(for key: SecureCredentialKey) async throws {
        let secureStore = self.secureStore
        let legacySettingsStore = self.legacySettingsStore
        let eventReporter = self.eventReporter

        try await enqueue(for: key) {
            if let legacySettingsStore {
                do {
                    try await legacySettingsStore.removeValue(forKey: key.legacySettingKey)
                } catch {
                    await eventReporter(
                        SecureCredentialStoreEvent(
                            kind: .legacyCleanupFailed,
                            key: key,
                            errorDescription: error.localizedDescription
                        )
                    )
                    // Keep the secure value intact when the legacy value cannot be
                    // removed, otherwise a later read could migrate it back.
                    throw SecureCredentialMigrationError.legacyRemovalFailed(key)
                }
            }

            do {
                try await secureStore.removeCredential(for: key)
            } catch {
                await eventReporter(
                    SecureCredentialStoreEvent(
                        kind: .secureRemovalFailed,
                        key: key,
                        errorDescription: error.localizedDescription
                    )
                )
                throw SecureCredentialMigrationError.secureRemovalFailed(key)
            }
        }
    }

    private func enqueue<Value: Sendable>(
        for key: SecureCredentialKey,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let previousOperation = operationTails[key]
        let operationTask = Task<Value, Error> {
            await previousOperation?.value
            return try await operation()
        }
        operationTails[key] = Task {
            _ = try? await operationTask.value
        }
        return try await operationTask.value
    }

    private static func loadAndMigrate(
        key: SecureCredentialKey,
        secureStore: any SecureCredentialStore,
        legacySettingsStore: (any SettingsStore)?,
        eventReporter: EventReporter
    ) async throws -> String? {
        let secureValue: String?
        do {
            secureValue = try await secureStore.credential(for: key)
        } catch {
            await eventReporter(
                SecureCredentialStoreEvent(
                    kind: .secureReadFailed,
                    key: key,
                    errorDescription: error.localizedDescription
                )
            )
            // Never fall back to plaintext when secure storage itself is unavailable.
            throw SecureCredentialMigrationError.secureReadFailed(key)
        }

        if let secureValue {
            await removeLegacyValueAfterSecureWrite(
                for: key,
                from: legacySettingsStore,
                eventReporter: eventReporter
            )
            return secureValue
        }

        guard let legacySettingsStore else { return nil }

        let legacyValue: String?
        do {
            legacyValue = try await legacySettingsStore.string(forKey: key.legacySettingKey)
        } catch {
            await eventReporter(
                SecureCredentialStoreEvent(
                    kind: .legacyReadFailed,
                    key: key,
                    errorDescription: error.localizedDescription
                )
            )
            throw SecureCredentialMigrationError.legacyReadFailed(key)
        }

        guard let legacyValue, !legacyValue.isEmpty else {
            if legacyValue != nil {
                try? await legacySettingsStore.removeValue(forKey: key.legacySettingKey)
            }
            return nil
        }

        do {
            try await secureStore.setCredential(legacyValue, for: key)
        } catch {
            await eventReporter(
                SecureCredentialStoreEvent(
                    kind: .migrationFailed,
                    key: key,
                    errorDescription: error.localizedDescription
                )
            )
            // The SQLite value is deliberately left untouched.
            throw SecureCredentialMigrationError.migrationWriteFailed(key)
        }

        do {
            try await legacySettingsStore.removeValue(forKey: key.legacySettingKey)
            await eventReporter(SecureCredentialStoreEvent(kind: .migrationSucceeded, key: key))
        } catch {
            // The Keychain write already succeeded, so the credential remains
            // available. A later read retries cleanup without risking data loss.
            await eventReporter(
                SecureCredentialStoreEvent(
                    kind: .legacyCleanupFailed,
                    key: key,
                    errorDescription: error.localizedDescription
                )
            )
        }

        return legacyValue
    }

    private static func removeLegacyValueAfterSecureWrite(
        for key: SecureCredentialKey,
        from legacySettingsStore: (any SettingsStore)?,
        eventReporter: EventReporter
    ) async {
        guard let legacySettingsStore else { return }

        do {
            guard try await legacySettingsStore.string(forKey: key.legacySettingKey) != nil else { return }
            try await legacySettingsStore.removeValue(forKey: key.legacySettingKey)
        } catch {
            await eventReporter(
                SecureCredentialStoreEvent(
                    kind: .legacyCleanupFailed,
                    key: key,
                    errorDescription: error.localizedDescription
                )
            )
        }
    }
}
