import Security
import XCTest
@testable import RillCore
@testable import RillPlatform

final class KeychainWebhookConfigurationStoreTests: XCTestCase {
    private let service = "dev.zrr.Rill.webhook-tests"
    private let reference = WebhookConfigurationReference(
        workflowID: UUID(uuidString: "92A9B593-66A4-4700-9654-460616E644EF")!,
        actionIndex: 2
    )!

    func testDataProtectionQueryUsesStableLocalNamespace() {
        let store = makeStore(useDataProtectionKeychain: true).store

        let query = store.baseQuery(for: reference, useDataProtectionKeychain: true)

        XCTAssertTrue(store.usesDataProtectionKeychain)
        XCTAssertEqual(query[kSecClass] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService] as? String, service)
        XCTAssertEqual(query[kSecAttrAccount] as? String, reference.rawValue)
        XCTAssertEqual(query[kSecAttrSynchronizable] as? Bool, false)
        XCTAssertEqual(query[kSecUseDataProtectionKeychain] as? Bool, true)
    }

    func testLegacyQueryKeepsTheSameServiceAndAccountWithoutPretendingAccessibilityApplies() {
        let store = makeStore(useDataProtectionKeychain: false).store

        let query = store.baseQuery(for: reference, useDataProtectionKeychain: false)

        XCTAssertFalse(store.usesDataProtectionKeychain)
        XCTAssertEqual(query[kSecAttrService] as? String, service)
        XCTAssertEqual(query[kSecAttrAccount] as? String, reference.rawValue)
        XCTAssertEqual(query[kSecAttrSynchronizable] as? Bool, false)
        XCTAssertNil(query[kSecUseDataProtectionKeychain])
        XCTAssertNil(query[kSecAttrAccessible])
    }

    func testEntitledWriteUsesDataProtectionAndCleansLegacyOnlyAfterExactReadback() async throws {
        let (store, itemAccess) = makeStore(useDataProtectionKeychain: true)
        let configuration = try makeConfiguration(url: "https://hooks.example.test/new")

        try await store.setConfiguration(configuration, for: reference)

        let storedConfiguration = try await store.configuration(for: reference)
        XCTAssertEqual(storedConfiguration, configuration)
        let snapshot = await itemAccess.snapshot()
        XCTAssertNotNil(snapshot.storage[scope(dataProtection: true)])
        XCTAssertNil(snapshot.storage[scope(dataProtection: false)])
        XCTAssertEqual(
            snapshot.events.prefix(3),
            [
                .write(scope(dataProtection: true)),
                .read(scope(dataProtection: true)),
                .remove(scope(dataProtection: false), operation: "legacy cleanup"),
            ]
        )
    }

    func testDataProtectionValueWinsOverLegacyAndLegacyIsRemoved() async throws {
        let protectedConfiguration = try makeConfiguration(url: "https://hooks.example.test/protected")
        let legacyConfiguration = try makeConfiguration(url: "https://hooks.example.test/legacy")
        let itemAccess = InMemoryWebhookKeychain(
            storage: [
                scope(dataProtection: true): try encoded(protectedConfiguration),
                scope(dataProtection: false): try encoded(legacyConfiguration),
            ]
        )
        let store = KeychainWebhookConfigurationStore(
            service: service,
            useDataProtectionKeychain: true,
            itemAccess: itemAccess
        )

        let storedConfiguration = try await store.configuration(for: reference)
        XCTAssertEqual(storedConfiguration, protectedConfiguration)

        let snapshot = await itemAccess.snapshot()
        XCTAssertNil(snapshot.storage[scope(dataProtection: false)])
        XCTAssertEqual(
            Array(snapshot.events.prefix(2)),
            [
                .read(scope(dataProtection: true)),
                .remove(scope(dataProtection: false), operation: "legacy cleanup"),
            ]
        )
    }

    func testLegacyValueMigratesOnlyAfterDataProtectionReadbackMatches() async throws {
        let configuration = try makeConfiguration(url: "https://hooks.example.test/legacy")
        let itemAccess = InMemoryWebhookKeychain(
            storage: [scope(dataProtection: false): try encoded(configuration)]
        )
        let store = KeychainWebhookConfigurationStore(
            service: service,
            useDataProtectionKeychain: true,
            itemAccess: itemAccess
        )

        let storedConfiguration = try await store.configuration(for: reference)
        XCTAssertEqual(storedConfiguration, configuration)

        let snapshot = await itemAccess.snapshot()
        XCTAssertNotNil(snapshot.storage[scope(dataProtection: true)])
        XCTAssertNil(snapshot.storage[scope(dataProtection: false)])
        XCTAssertEqual(
            snapshot.events,
            [
                .read(scope(dataProtection: true)),
                .read(scope(dataProtection: false)),
                .write(scope(dataProtection: true)),
                .read(scope(dataProtection: true)),
                .remove(scope(dataProtection: false), operation: "legacy cleanup"),
            ]
        )
    }

    func testFailedDataProtectionVerificationKeepsLegacyValue() async throws {
        let configuration = try makeConfiguration(url: "https://hooks.example.test/legacy")
        let mismatched = try makeConfiguration(url: "https://hooks.example.test/mismatch")
        let itemAccess = InMemoryWebhookKeychain(
            storage: [scope(dataProtection: false): try encoded(configuration)],
            forcedReadbackAfterWrite: try encoded(mismatched)
        )
        let store = KeychainWebhookConfigurationStore(
            service: service,
            useDataProtectionKeychain: true,
            itemAccess: itemAccess
        )

        do {
            _ = try await store.configuration(for: reference)
            XCTFail("Expected exact readback verification to fail.")
        } catch {
            XCTAssertEqual(
                error as? KeychainWebhookConfigurationStore.StoreError,
                .verificationFailed(reference: reference)
            )
        }

        let snapshot = await itemAccess.snapshot()
        XCTAssertNotNil(snapshot.storage[scope(dataProtection: false)])
        XCTAssertFalse(
            snapshot.events.contains(
                .remove(scope(dataProtection: false), operation: "legacy cleanup")
            )
        )
    }

    func testUnentitledStoreUsesOnlyEncryptedLoginKeychainScope() async throws {
        let (store, itemAccess) = makeStore(useDataProtectionKeychain: false)
        let configuration = try makeConfiguration(url: "https://hooks.example.test/login")

        try await store.setConfiguration(configuration, for: reference)
        let storedConfiguration = try await store.configuration(for: reference)
        XCTAssertEqual(storedConfiguration, configuration)

        let snapshot = await itemAccess.snapshot()
        XCTAssertEqual(
            snapshot.events,
            [
                .write(scope(dataProtection: false)),
                .read(scope(dataProtection: false)),
                .read(scope(dataProtection: false)),
            ]
        )
        XCTAssertNil(snapshot.storage[scope(dataProtection: true)])
    }

    func testStrictDecoderRejectsUnexpectedTopLevelFieldsWithoutFallingBack() async throws {
        let invalid = Data(
            """
            {"schemaVersion":1,"values":{"webhook.url":"https://hooks.example.test"},"extra":"rejected"}
            """.utf8
        )
        let itemAccess = InMemoryWebhookKeychain(
            storage: [scope(dataProtection: true): invalid]
        )
        let store = KeychainWebhookConfigurationStore(
            service: service,
            useDataProtectionKeychain: true,
            itemAccess: itemAccess
        )

        do {
            _ = try await store.configuration(for: reference)
            XCTFail("Expected invalid Keychain payload to be rejected.")
        } catch let error as KeychainWebhookConfigurationStore.StoreError {
            guard case .invalidStoredConfiguration(let failedReference, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(failedReference, reference)
        }

        let snapshot = await itemAccess.snapshot()
        XCTAssertEqual(snapshot.events, [.read(scope(dataProtection: true))])
    }

    private func makeStore(
        useDataProtectionKeychain: Bool
    ) -> (store: KeychainWebhookConfigurationStore, itemAccess: InMemoryWebhookKeychain) {
        let itemAccess = InMemoryWebhookKeychain()
        return (
            KeychainWebhookConfigurationStore(
                service: service,
                useDataProtectionKeychain: useDataProtectionKeychain,
                itemAccess: itemAccess
            ),
            itemAccess
        )
    }

    private func scope(dataProtection: Bool) -> KeychainWebhookItemScope {
        KeychainWebhookItemScope(
            service: service,
            account: reference.rawValue,
            usesDataProtectionKeychain: dataProtection
        )
    }

    private func makeConfiguration(url: String) throws -> WebhookProtectedConfiguration {
        try WebhookProtectedConfiguration(values: [
            ExternalOutputActionConfigurationKey.webhookURL: url,
            ExternalOutputActionConfigurationKey.webhookHeadersJSON: "{\"Authorization\":\"Bearer test-token\"}",
        ])
    }

    private func encoded(_ configuration: WebhookProtectedConfiguration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(configuration)
    }
}

private enum WebhookKeychainEvent: Sendable, Equatable {
    case read(KeychainWebhookItemScope)
    case write(KeychainWebhookItemScope)
    case remove(KeychainWebhookItemScope, operation: String)
}

private actor InMemoryWebhookKeychain: KeychainWebhookItemAccess {
    struct Snapshot: Sendable {
        let storage: [KeychainWebhookItemScope: Data]
        let events: [WebhookKeychainEvent]
    }

    private var storage: [KeychainWebhookItemScope: Data]
    private var events: [WebhookKeychainEvent] = []
    private let forcedReadbackAfterWrite: Data?
    private var forcedReadbackScopes: Set<KeychainWebhookItemScope> = []

    init(
        storage: [KeychainWebhookItemScope: Data] = [:],
        forcedReadbackAfterWrite: Data? = nil
    ) {
        self.storage = storage
        self.forcedReadbackAfterWrite = forcedReadbackAfterWrite
    }

    func data(for scope: KeychainWebhookItemScope) async throws -> Data? {
        events.append(.read(scope))
        if forcedReadbackScopes.remove(scope) != nil, let forcedReadbackAfterWrite {
            return forcedReadbackAfterWrite
        }
        return storage[scope]
    }

    func setData(_ data: Data, for scope: KeychainWebhookItemScope) async throws {
        events.append(.write(scope))
        storage[scope] = data
        if forcedReadbackAfterWrite != nil {
            forcedReadbackScopes.insert(scope)
        }
    }

    func removeData(for scope: KeychainWebhookItemScope, operation: String) async throws {
        events.append(.remove(scope, operation: operation))
        storage.removeValue(forKey: scope)
    }

    func snapshot() -> Snapshot {
        Snapshot(storage: storage, events: events)
    }
}
