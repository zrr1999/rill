import XCTest
@testable import RillCore

final class SecureCredentialMigrationTests: XCTestCase {
    func testMigrationWritesSecureStoreBeforeRemovingLegacyValue() async throws {
        let log = CredentialOperationLog()
        let legacyStore = FakeLegacySettingsStore(
            storage: [.deepgramAPIKey: "legacy-secret"],
            log: log
        )
        let secureStore = FakeSecureCredentialStore(log: log)
        let eventRecorder = CredentialEventRecorder()
        let store = MigratingSecureCredentialStore(
            secureStore: secureStore,
            legacySettingsStore: legacyStore,
            eventReporter: { event in await eventRecorder.record(event) }
        )

        let value = try await store.credential(for: .deepgramAPIKey)
        let operations = await log.snapshot()
        let secureValue = await secureStore.storedValue(for: .deepgramAPIKey)
        let legacyValue = await legacyStore.storedValue(for: .deepgramAPIKey)
        let eventKinds = await eventRecorder.snapshot().map(\.kind)

        XCTAssertEqual(value, "legacy-secret")
        XCTAssertEqual(
            operations,
            ["secure.read", "legacy.read", "secure.set", "legacy.remove"]
        )
        XCTAssertEqual(secureValue, "legacy-secret")
        XCTAssertNil(legacyValue)
        XCTAssertEqual(eventKinds, [.migrationSucceeded])
    }

    func testMigrationWriteFailurePreservesLegacyValueAndFailsClosed() async {
        let log = CredentialOperationLog()
        let legacyStore = FakeLegacySettingsStore(
            storage: [.legacyWhisperKitModelToken: "legacy-token"],
            log: log
        )
        let secureStore = FakeSecureCredentialStore(log: log, failSet: true)
        let eventRecorder = CredentialEventRecorder()
        let store = MigratingSecureCredentialStore(
            secureStore: secureStore,
            legacySettingsStore: legacyStore,
            eventReporter: { event in await eventRecorder.record(event) }
        )

        do {
            _ = try await store.credential(for: .legacyWhisperKitModelToken)
            XCTFail("Expected migration to fail when secure storage rejects the write")
        } catch {
            XCTAssertEqual(
                error as? SecureCredentialMigrationError,
                .migrationWriteFailed(.legacyWhisperKitModelToken)
            )
        }

        let legacyValue = await legacyStore.storedValue(for: .legacyWhisperKitModelToken)
        let secureValue = await secureStore.storedValue(for: .legacyWhisperKitModelToken)
        let operations = await log.snapshot()
        let eventKinds = await eventRecorder.snapshot().map(\.kind)
        XCTAssertEqual(legacyValue, "legacy-token")
        XCTAssertNil(secureValue)
        XCTAssertEqual(
            operations,
            ["secure.read", "legacy.read", "secure.set"]
        )
        XCTAssertEqual(eventKinds, [.migrationFailed])
    }

    func testLegacyCleanupFailureKeepsKeychainValueAvailableAndDiagnosable() async throws {
        let log = CredentialOperationLog()
        let legacyStore = FakeLegacySettingsStore(
            storage: [.deepgramAPIKey: "legacy-secret"],
            log: log,
            failRemove: true
        )
        let secureStore = FakeSecureCredentialStore(log: log)
        let eventRecorder = CredentialEventRecorder()
        let store = MigratingSecureCredentialStore(
            secureStore: secureStore,
            legacySettingsStore: legacyStore,
            eventReporter: { event in await eventRecorder.record(event) }
        )

        let value = try await store.credential(for: .deepgramAPIKey)
        let secureValue = await secureStore.storedValue(for: .deepgramAPIKey)
        let legacyValue = await legacyStore.storedValue(for: .deepgramAPIKey)
        let eventKinds = await eventRecorder.snapshot().map(\.kind)

        XCTAssertEqual(value, "legacy-secret")
        XCTAssertEqual(secureValue, "legacy-secret")
        XCTAssertEqual(legacyValue, "legacy-secret")
        XCTAssertEqual(eventKinds, [.legacyCleanupFailed])
    }

    func testSecureReadFailureNeverFallsBackToPlaintext() async {
        let log = CredentialOperationLog()
        let legacyStore = FakeLegacySettingsStore(
            storage: [.deepgramAPIKey: "legacy-secret"],
            log: log
        )
        let secureStore = FakeSecureCredentialStore(log: log, failRead: true)
        let eventRecorder = CredentialEventRecorder()
        let store = MigratingSecureCredentialStore(
            secureStore: secureStore,
            legacySettingsStore: legacyStore,
            eventReporter: { event in await eventRecorder.record(event) }
        )

        do {
            _ = try await store.credential(for: .deepgramAPIKey)
            XCTFail("Expected a secure read failure")
        } catch {
            XCTAssertEqual(
                error as? SecureCredentialMigrationError,
                .secureReadFailed(.deepgramAPIKey)
            )
        }

        let operations = await log.snapshot()
        let legacyValue = await legacyStore.storedValue(for: .deepgramAPIKey)
        let eventKinds = await eventRecorder.snapshot().map(\.kind)
        XCTAssertEqual(operations, ["secure.read"])
        XCTAssertEqual(legacyValue, "legacy-secret")
        XCTAssertEqual(eventKinds, [.secureReadFailed])
    }

    func testClearFailureOnLegacyRemovalDoesNotRemoveSecureValue() async {
        let log = CredentialOperationLog()
        let legacyStore = FakeLegacySettingsStore(
            storage: [.deepgramAPIKey: "legacy-secret"],
            log: log,
            failRemove: true
        )
        let secureStore = FakeSecureCredentialStore(
            storage: [.deepgramAPIKey: "current-secret"],
            log: log
        )
        let store = MigratingSecureCredentialStore(
            secureStore: secureStore,
            legacySettingsStore: legacyStore
        )

        do {
            try await store.removeCredential(for: .deepgramAPIKey)
            XCTFail("Expected legacy cleanup failure")
        } catch {
            XCTAssertEqual(
                error as? SecureCredentialMigrationError,
                .legacyRemovalFailed(.deepgramAPIKey)
            )
        }

        let secureValue = await secureStore.storedValue(for: .deepgramAPIKey)
        let legacyValue = await legacyStore.storedValue(for: .deepgramAPIKey)
        let operations = await log.snapshot()
        XCTAssertEqual(secureValue, "current-secret")
        XCTAssertEqual(legacyValue, "legacy-secret")
        XCTAssertEqual(operations, ["legacy.remove"])
    }

    func testConcurrentUserWriteWinsOverInFlightLegacyMigration() async throws {
        let log = CredentialOperationLog()
        let readGate = CredentialReadGate()
        let legacyStore = FakeLegacySettingsStore(
            storage: [.deepgramAPIKey: "legacy-secret"],
            log: log,
            readGate: readGate
        )
        let secureStore = FakeSecureCredentialStore(log: log)
        let store = MigratingSecureCredentialStore(
            secureStore: secureStore,
            legacySettingsStore: legacyStore
        )

        let migrationTask = Task {
            try await store.credential(for: .deepgramAPIKey)
        }
        await log.wait(for: "legacy.read")
        let userWriteTask = Task {
            try await store.setCredential("new-user-secret", for: .deepgramAPIKey)
        }

        await readGate.open()
        let migratedValue = try await migrationTask.value
        XCTAssertEqual(migratedValue, "legacy-secret")
        try await userWriteTask.value

        let finalValue = await secureStore.storedValue(for: .deepgramAPIKey)
        XCTAssertEqual(finalValue, "new-user-secret")
    }
}

private enum FakeCredentialStoreError: Error {
    case requestedFailure
}

private actor CredentialOperationLog {
    private var entries: [String] = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func append(_ entry: String) {
        entries.append(entry)
        let matchingWaiters = waiters.removeValue(forKey: entry) ?? []
        matchingWaiters.forEach { $0.resume() }
    }

    func wait(for entry: String) async {
        guard !entries.contains(entry) else { return }
        await withCheckedContinuation { continuation in
            waiters[entry, default: []].append(continuation)
        }
    }

    func snapshot() -> [String] {
        entries
    }
}

private actor CredentialReadGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pendingWaiters = waiters
        waiters = []
        pendingWaiters.forEach { $0.resume() }
    }
}

private actor CredentialEventRecorder {
    private var events: [SecureCredentialStoreEvent] = []

    func record(_ event: SecureCredentialStoreEvent) {
        events.append(event)
    }

    func snapshot() -> [SecureCredentialStoreEvent] {
        events
    }
}

private actor FakeSecureCredentialStore: SecureCredentialStore {
    private var storage: [SecureCredentialKey: String]
    private let log: CredentialOperationLog
    private let failRead: Bool
    private let failSet: Bool

    init(
        storage: [SecureCredentialKey: String] = [:],
        log: CredentialOperationLog,
        failRead: Bool = false,
        failSet: Bool = false
    ) {
        self.storage = storage
        self.log = log
        self.failRead = failRead
        self.failSet = failSet
    }

    func credential(for key: SecureCredentialKey) async throws -> String? {
        await log.append("secure.read")
        if failRead { throw FakeCredentialStoreError.requestedFailure }
        return storage[key]
    }

    func setCredential(_ value: String, for key: SecureCredentialKey) async throws {
        await log.append("secure.set")
        if failSet { throw FakeCredentialStoreError.requestedFailure }
        storage[key] = value
    }

    func removeCredential(for key: SecureCredentialKey) async throws {
        await log.append("secure.remove")
        storage.removeValue(forKey: key)
    }

    func storedValue(for key: SecureCredentialKey) -> String? {
        storage[key]
    }
}

private actor FakeLegacySettingsStore: SettingsStore {
    private var storage: [AppSettingKey: String]
    private let log: CredentialOperationLog
    private let failRemove: Bool
    private let readGate: CredentialReadGate?

    init(
        storage: [AppSettingKey: String],
        log: CredentialOperationLog,
        failRemove: Bool = false,
        readGate: CredentialReadGate? = nil
    ) {
        self.storage = storage
        self.log = log
        self.failRemove = failRemove
        self.readGate = readGate
    }

    func string(forKey key: AppSettingKey) async throws -> String? {
        let value = storage[key]
        await log.append("legacy.read")
        await readGate?.wait()
        return value
    }

    func strings(forKeys keys: [AppSettingKey]) async throws -> [AppSettingKey: String] {
        keys.reduce(into: [:]) { result, key in
            result[key] = storage[key]
        }
    }

    func setString(_ value: String, forKey key: AppSettingKey) async throws {
        storage[key] = value
    }

    func setStringsAtomically(_ values: [AppSettingKey: String]) async throws {
        storage.merge(values) { _, newValue in newValue }
    }

    func removeValue(forKey key: AppSettingKey) async throws {
        await log.append("legacy.remove")
        if failRemove { throw FakeCredentialStoreError.requestedFailure }
        storage.removeValue(forKey: key)
    }

    func storedValue(for key: AppSettingKey) -> String? {
        storage[key]
    }
}
