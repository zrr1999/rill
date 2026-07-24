import Foundation
import Security
import XCTest

@testable import RillCore
@testable import RillPlatform

final class KeychainLocalDataKeyStoreTests: XCTestCase {
  func testDataProtectionItemIsLocalNonSynchronizableAndThisDeviceOnly() {
    let store = makeStore(useDataProtectionKeychain: true).store
    let key = Data(repeating: 0x11, count: KeychainLocalDataKeyStore.keyByteCount)

    let query = store.baseQuery(useDataProtectionKeychain: true)
    let item = store.newItem(data: key, useDataProtectionKeychain: true)

    XCTAssertTrue(store.usesDataProtectionKeychain)
    XCTAssertEqual(query[kSecClass] as? String, kSecClassGenericPassword as String)
    XCTAssertEqual(query[kSecAttrService] as? String, service)
    XCTAssertEqual(query[kSecAttrAccount] as? String, account)
    XCTAssertEqual(query[kSecAttrSynchronizable] as? Bool, false)
    XCTAssertEqual(query[kSecUseDataProtectionKeychain] as? Bool, true)
    XCTAssertEqual(
      item[kSecAttrAccessible] as? String,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
    )
    XCTAssertEqual(item[kSecValueData] as? Data, key)
  }

  func testLegacyItemKeepsStableNamespaceWithoutClaimingDataProtectionAccessibility() {
    let store = makeStore(useDataProtectionKeychain: false).store
    let key = Data(repeating: 0x22, count: KeychainLocalDataKeyStore.keyByteCount)

    let query = store.baseQuery(useDataProtectionKeychain: false)
    let item = store.newItem(data: key, useDataProtectionKeychain: false)

    XCTAssertFalse(store.usesDataProtectionKeychain)
    XCTAssertEqual(query[kSecAttrService] as? String, service)
    XCTAssertEqual(query[kSecAttrAccount] as? String, account)
    XCTAssertEqual(query[kSecAttrSynchronizable] as? Bool, false)
    XCTAssertNil(query[kSecUseDataProtectionKeychain])
    XCTAssertNil(item[kSecAttrAccessible])
  }

  func testUniqueLoginKeychainServiceCreatesAndReadsStableKey() throws {
    let uniqueService = service + "." + UUID().uuidString
    let uniqueAccount = account + "." + UUID().uuidString
    cleanupSecurityItems(service: uniqueService, account: uniqueAccount)
    defer { cleanupSecurityItems(service: uniqueService, account: uniqueAccount) }
    let store = KeychainLocalDataKeyStore(
      service: uniqueService,
      account: uniqueAccount,
      useDataProtectionKeychain: false
    )

    XCTAssertNil(try store.loadKey())
    let created = try store.loadOrCreateKey(allowCreation: true)
    let repeated = try store.loadOrCreateKey(allowCreation: true)
    let reloaded = try KeychainLocalDataKeyStore(
      service: uniqueService,
      account: uniqueAccount,
      useDataProtectionKeychain: false
    ).loadKey()

    XCTAssertEqual(created.count, KeychainLocalDataKeyStore.keyByteCount)
    XCTAssertEqual(repeated, created)
    XCTAssertEqual(reloaded, created)
  }

  func testLoadKeyDoesNotCreateMissingItem() throws {
    let (store, itemAccess) = makeStore(useDataProtectionKeychain: false)

    XCTAssertNil(try store.loadKey())

    let snapshot = itemAccess.snapshot()
    XCTAssertTrue(snapshot.storage.isEmpty)
    XCTAssertEqual(snapshot.events, [.read(scope(dataProtection: false))])
  }

  func testCreationDisabledFailsClosedWhenKeyIsMissing() {
    let (store, itemAccess) = makeStore(useDataProtectionKeychain: false)

    assertStoreError(.keyNotFound) {
      _ = try store.loadOrCreateKey(allowCreation: false)
    }

    let snapshot = itemAccess.snapshot()
    XCTAssertTrue(snapshot.storage.isEmpty)
    XCTAssertEqual(snapshot.events, [.read(scope(dataProtection: false))])
  }

  func testNewAccountsReceiveIndependentRandomKeys() throws {
    let itemAccess = InMemoryLocalDataKeychain()
    let firstStore = KeychainLocalDataKeyStore(
      service: service,
      account: "first-root-key",
      useDataProtectionKeychain: false,
      itemAccess: itemAccess
    )
    let secondStore = KeychainLocalDataKeyStore(
      service: service,
      account: "second-root-key",
      useDataProtectionKeychain: false,
      itemAccess: itemAccess
    )

    let first = try firstStore.loadOrCreateKey()
    let second = try secondStore.loadOrCreateKey()

    XCTAssertEqual(first.count, KeychainLocalDataKeyStore.keyByteCount)
    XCTAssertEqual(second.count, KeychainLocalDataKeyStore.keyByteCount)
    XCTAssertNotEqual(first, second)
  }

  func testInvalidStoredKeyLengthFailsClosedWithoutReplacement() {
    let invalidKey = Data(repeating: 0x33, count: KeychainLocalDataKeyStore.keyByteCount - 1)
    let itemAccess = InMemoryLocalDataKeychain(
      storage: [scope(dataProtection: false): invalidKey]
    )
    let store = KeychainLocalDataKeyStore(
      service: service,
      account: account,
      useDataProtectionKeychain: false,
      itemAccess: itemAccess
    )

    assertStoreError(
      .invalidKeyLength(
        expected: KeychainLocalDataKeyStore.keyByteCount,
        actual: invalidKey.count
      )
    ) {
      _ = try store.loadOrCreateKey(allowCreation: true)
    }

    let snapshot = itemAccess.snapshot()
    XCTAssertEqual(snapshot.storage[scope(dataProtection: false)], invalidKey)
    XCTAssertEqual(snapshot.events, [.read(scope(dataProtection: false))])
  }

  func testInvalidProtectedKeyDoesNotFallBackToOrDeleteLegacyKey() {
    let invalidProtectedKey = Data(repeating: 0x44, count: 12)
    let legacyKey = Data(repeating: 0x55, count: KeychainLocalDataKeyStore.keyByteCount)
    let itemAccess = InMemoryLocalDataKeychain(
      storage: [
        scope(dataProtection: true): invalidProtectedKey,
        scope(dataProtection: false): legacyKey,
      ]
    )
    let store = KeychainLocalDataKeyStore(
      service: service,
      account: account,
      useDataProtectionKeychain: true,
      itemAccess: itemAccess
    )

    assertStoreError(
      .invalidKeyLength(
        expected: KeychainLocalDataKeyStore.keyByteCount,
        actual: invalidProtectedKey.count
      )
    ) {
      _ = try store.loadKey()
    }

    let snapshot = itemAccess.snapshot()
    XCTAssertEqual(snapshot.storage[scope(dataProtection: true)], invalidProtectedKey)
    XCTAssertEqual(snapshot.storage[scope(dataProtection: false)], legacyKey)
    XCTAssertEqual(snapshot.events, [.read(scope(dataProtection: true))])
  }

  func testLoadCandidatesReadsDistinctProtectedAndLegacyKeysWithoutMutation() throws {
    let protectedKey = key(byte: 0x66)
    let legacyKey = key(byte: 0x67)
    let itemAccess = InMemoryLocalDataKeychain(
      storage: [
        scope(dataProtection: true): protectedKey,
        scope(dataProtection: false): legacyKey,
      ]
    )
    let store = makeStore(itemAccess: itemAccess)

    let candidates = try store.loadCandidates()

    XCTAssertEqual(
      candidates,
      [
        .init(key: protectedKey, source: .dataProtection),
        .init(key: legacyKey, source: .legacyLogin),
      ]
    )
    let snapshot = itemAccess.snapshot()
    XCTAssertEqual(snapshot.storage[scope(dataProtection: true)], protectedKey)
    XCTAssertEqual(snapshot.storage[scope(dataProtection: false)], legacyKey)
    XCTAssertEqual(
      snapshot.events,
      [
        .read(scope(dataProtection: true)),
        .read(scope(dataProtection: false)),
      ]
    )
  }

  func testLoadCandidatesDeduplicatesMatchingKeysWithProtectedPrecedence() throws {
    let sharedKey = key(byte: 0x68)
    let itemAccess = InMemoryLocalDataKeychain(
      storage: [
        scope(dataProtection: true): sharedKey,
        scope(dataProtection: false): sharedKey,
      ]
    )
    let store = makeStore(itemAccess: itemAccess)

    XCTAssertEqual(
      try store.loadCandidates(),
      [.init(key: sharedKey, source: .dataProtection)]
    )
    XCTAssertEqual(itemAccess.snapshot().storage.count, 2)
  }

  func testFinalizeLegacyCandidatePreservesAndReportsAlternateProtectedKey() throws {
    let protectedKey = key(byte: 0x69)
    let legacyKey = key(byte: 0x6A)
    let itemAccess = InMemoryLocalDataKeychain(
      storage: [
        scope(dataProtection: true): protectedKey,
        scope(dataProtection: false): legacyKey,
      ]
    )
    let store = makeStore(itemAccess: itemAccess)
    let selected = try XCTUnwrap(
      store.loadCandidates().first { $0.source == .legacyLogin }
    )
    itemAccess.resetEvents()

    let result = try store.finalizeValidatedKey(selected)

    XCTAssertEqual(result.key, legacyKey)
    XCTAssertEqual(result.additionalKeyStatus, .alternateKeyRetained)
    let snapshot = itemAccess.snapshot()
    XCTAssertEqual(snapshot.storage[scope(dataProtection: true)], protectedKey)
    XCTAssertEqual(snapshot.storage[scope(dataProtection: false)], legacyKey)
    XCTAssertEqual(
      snapshot.events,
      [
        .read(scope(dataProtection: true)),
        .read(scope(dataProtection: false)),
      ]
    )
  }

  func testFinalizeProtectedCandidateRetainsMatchingLegacyKey() throws {
    let protectedKey = key(byte: 0x6B)
    let itemAccess = InMemoryLocalDataKeychain(
      storage: [
        scope(dataProtection: true): protectedKey,
        scope(dataProtection: false): protectedKey,
      ]
    )
    let store = makeStore(itemAccess: itemAccess)
    let selected = try XCTUnwrap(
      store.loadCandidates().first { $0.source == .dataProtection }
    )
    itemAccess.resetEvents()

    let result = try store.finalizeValidatedKey(selected)

    XCTAssertEqual(
      result,
      .init(key: protectedKey, additionalKeyStatus: .matchingLegacyKeyRetained)
    )
    let snapshot = itemAccess.snapshot()
    XCTAssertEqual(snapshot.storage[scope(dataProtection: true)], protectedKey)
    XCTAssertEqual(snapshot.storage[scope(dataProtection: false)], protectedKey)
    XCTAssertEqual(
      snapshot.events,
      [
        .read(scope(dataProtection: true)),
        .read(scope(dataProtection: false)),
      ]
    )
  }

  func testFinalizePreservesDistinctLegacyKeyCreatedAfterCandidateSelection() throws {
    let protectedKey = key(byte: 0x6C)
    let concurrentLegacyKey = key(byte: 0x6D)
    let protectedScope = scope(dataProtection: true)
    let legacyScope = scope(dataProtection: false)
    let itemAccess = InMemoryLocalDataKeychain(
      storage: [protectedScope: protectedKey]
    )
    let store = makeStore(itemAccess: itemAccess)
    let selected = try XCTUnwrap(store.loadCandidates().first)
    itemAccess.installConcurrentData(concurrentLegacyKey, for: legacyScope)
    itemAccess.resetEvents()

    let result = try store.finalizeValidatedKey(selected)

    XCTAssertEqual(
      result,
      .init(key: protectedKey, additionalKeyStatus: .alternateKeyRetained)
    )
    let snapshot = itemAccess.snapshot()
    XCTAssertEqual(snapshot.storage[protectedScope], protectedKey)
    XCTAssertEqual(snapshot.storage[legacyScope], concurrentLegacyKey)
    XCTAssertEqual(snapshot.events, [.read(protectedScope), .read(legacyScope)])
  }

  func testFinalizeAddsLegacyKeyToProtectedScopeAndRetainsMatchingLegacy() throws {
    let legacyKey = key(byte: 0x6D)
    let itemAccess = InMemoryLocalDataKeychain(
      storage: [scope(dataProtection: false): legacyKey]
    )
    let store = makeStore(itemAccess: itemAccess)
    let selected = try XCTUnwrap(store.loadCandidates().first)
    itemAccess.resetEvents()

    let result = try store.finalizeValidatedKey(selected)

    XCTAssertEqual(result.additionalKeyStatus, .matchingLegacyKeyRetained)
    let snapshot = itemAccess.snapshot()
    XCTAssertEqual(snapshot.storage[scope(dataProtection: true)], legacyKey)
    XCTAssertEqual(snapshot.storage[scope(dataProtection: false)], legacyKey)
    XCTAssertEqual(
      snapshot.events,
      [
        .read(scope(dataProtection: true)),
        .add(scope(dataProtection: true)),
        .read(scope(dataProtection: true)),
        .read(scope(dataProtection: false)),
      ]
    )
  }

  func testFinalizePreservesAndReportsConcurrentProtectedWinner() throws {
    let concurrentProtectedKey = key(byte: 0x6E)
    let legacyKey = key(byte: 0x6F)
    let protectedScope = scope(dataProtection: true)
    let legacyScope = scope(dataProtection: false)
    let itemAccess = InMemoryLocalDataKeychain(
      storage: [legacyScope: legacyKey],
      duplicateDataOnAdd: [protectedScope: concurrentProtectedKey]
    )
    let store = makeStore(itemAccess: itemAccess)
    let selected = try XCTUnwrap(store.loadCandidates().first)
    itemAccess.resetEvents()

    let result = try store.finalizeValidatedKey(selected)

    XCTAssertEqual(
      result,
      .init(key: legacyKey, additionalKeyStatus: .alternateKeyRetained)
    )
    let snapshot = itemAccess.snapshot()
    XCTAssertEqual(snapshot.storage[protectedScope], concurrentProtectedKey)
    XCTAssertEqual(snapshot.storage[legacyScope], legacyKey)
    XCTAssertEqual(
      snapshot.events,
      [
        .read(protectedScope),
        .add(protectedScope),
        .read(protectedScope),
        .read(legacyScope),
      ]
    )
  }

  func testFinalizeFailsClosedWhenSelectedProtectedKeyWasReplacedAndIsNotRetained() throws {
    let selectedKey = key(byte: 0x70)
    let concurrentProtectedKey = key(byte: 0x71)
    let protectedScope = scope(dataProtection: true)
    let legacyScope = scope(dataProtection: false)
    let itemAccess = InMemoryLocalDataKeychain(
      storage: [protectedScope: selectedKey]
    )
    let store = makeStore(itemAccess: itemAccess)
    let selected = try XCTUnwrap(store.loadCandidates().first)
    itemAccess.installConcurrentData(concurrentProtectedKey, for: protectedScope)
    itemAccess.resetEvents()

    assertStoreError(.verificationFailed) {
      _ = try store.finalizeValidatedKey(selected)
    }

    let snapshot = itemAccess.snapshot()
    XCTAssertEqual(snapshot.storage[protectedScope], concurrentProtectedKey)
    XCTAssertNil(snapshot.storage[legacyScope])
    XCTAssertEqual(
      snapshot.events,
      [
        .read(protectedScope),
        .read(legacyScope),
      ]
    )
  }

  func testFinalizeFailsClosedWhenCompetingProtectedKeyHasAlternateLegacyKey() throws {
    let selectedKey = key(byte: 0x79)
    let concurrentProtectedKey = key(byte: 0x7A)
    let alternateLegacyKey = key(byte: 0x7B)
    let protectedScope = scope(dataProtection: true)
    let legacyScope = scope(dataProtection: false)
    let itemAccess = InMemoryLocalDataKeychain(
      storage: [
        protectedScope: selectedKey,
        legacyScope: alternateLegacyKey,
      ]
    )
    let store = makeStore(itemAccess: itemAccess)
    let selected = try XCTUnwrap(
      store.loadCandidates().first { $0.source == .dataProtection }
    )
    itemAccess.installConcurrentData(concurrentProtectedKey, for: protectedScope)
    itemAccess.resetEvents()

    assertStoreError(.verificationFailed) {
      _ = try store.finalizeValidatedKey(selected)
    }

    let snapshot = itemAccess.snapshot()
    XCTAssertEqual(snapshot.storage[protectedScope], concurrentProtectedKey)
    XCTAssertEqual(snapshot.storage[legacyScope], alternateLegacyKey)
    XCTAssertEqual(snapshot.events, [.read(protectedScope), .read(legacyScope)])
  }

  func testFinalizeReportsAlternateKeyWhenProtectedKeyIsReplaced() throws {
    let selectedKey = key(byte: 0x77)
    let concurrentProtectedKey = key(byte: 0x78)
    let protectedScope = scope(dataProtection: true)
    let legacyScope = scope(dataProtection: false)
    let itemAccess = InMemoryLocalDataKeychain(
      storage: [
        protectedScope: selectedKey,
        legacyScope: selectedKey,
      ]
    )
    let store = makeStore(itemAccess: itemAccess)
    let selected = try XCTUnwrap(store.loadCandidates().first)
    itemAccess.installConcurrentData(concurrentProtectedKey, for: protectedScope)
    itemAccess.resetEvents()

    let result = try store.finalizeValidatedKey(selected)

    XCTAssertEqual(
      result,
      .init(key: selectedKey, additionalKeyStatus: .alternateKeyRetained)
    )
    let snapshot = itemAccess.snapshot()
    XCTAssertEqual(snapshot.storage[protectedScope], concurrentProtectedKey)
    XCTAssertEqual(snapshot.storage[legacyScope], selectedKey)
    XCTAssertEqual(snapshot.events, [.read(protectedScope), .read(legacyScope)])
  }

  func testFinalizeWithoutLegacyReportsNoAdditionalKey() throws {
    let protectedKey = key(byte: 0x72)
    let itemAccess = InMemoryLocalDataKeychain(
      storage: [scope(dataProtection: true): protectedKey]
    )
    let store = makeStore(itemAccess: itemAccess)
    let selected = try XCTUnwrap(
      store.loadCandidates().first { $0.source == .dataProtection }
    )
    itemAccess.resetEvents()

    let result = try store.finalizeValidatedKey(selected)

    XCTAssertEqual(result, .init(key: protectedKey, additionalKeyStatus: .none))
    let snapshot = itemAccess.snapshot()
    XCTAssertEqual(snapshot.storage[scope(dataProtection: true)], protectedKey)
    XCTAssertNil(snapshot.storage[scope(dataProtection: false)])
    XCTAssertEqual(
      snapshot.events,
      [
        .read(scope(dataProtection: true)),
        .read(scope(dataProtection: false)),
      ]
    )
  }

  func testFinalizeWithoutDataProtectionKeepsValidatedKeyInLoginScope() throws {
    let loginKey = key(byte: 0x76)
    let loginScope = scope(dataProtection: false)
    let itemAccess = InMemoryLocalDataKeychain(storage: [loginScope: loginKey])
    let store = KeychainLocalDataKeyStore(
      service: service,
      account: account,
      useDataProtectionKeychain: false,
      itemAccess: itemAccess
    )
    let selected = try XCTUnwrap(store.loadCandidates().first)
    itemAccess.resetEvents()

    let result = try store.finalizeValidatedKey(selected)

    XCTAssertEqual(result, .init(key: loginKey, additionalKeyStatus: .none))
    let snapshot = itemAccess.snapshot()
    XCTAssertEqual(snapshot.storage, [loginScope: loginKey])
    XCTAssertEqual(snapshot.events, [.read(loginScope)])
  }

  func testTransientProtectedReadDoesNotFallBackToLegacy() {
    let legacyKey = key(byte: 0x74)
    let unavailable = KeychainLocalDataKeyStore.StoreError.temporarilyUnavailable(
      status: errSecInteractionNotAllowed
    )
    let itemAccess = InMemoryLocalDataKeychain(
      storage: [scope(dataProtection: false): legacyKey],
      readErrors: [scope(dataProtection: true): unavailable]
    )
    let store = makeStore(itemAccess: itemAccess)

    assertStoreError(unavailable) {
      _ = try store.loadCandidates()
    }

    let snapshot = itemAccess.snapshot()
    XCTAssertEqual(snapshot.storage[scope(dataProtection: false)], legacyKey)
    XCTAssertEqual(snapshot.events, [.read(scope(dataProtection: true))])
  }

  func testSecurityOperationsMapLockedAndUnavailableStatusesToTemporaryFailure() {
    for operation in ["read", "add"] {
      for status in [errSecInteractionNotAllowed, errSecNotAvailable] {
        XCTAssertEqual(
          KeychainLocalDataKeyStore.errorForSecurityStatus(
            operation: operation,
            status: status
          ),
          .temporarilyUnavailable(status: status)
        )
      }
    }
  }

  func testSecurityOperationsKeepPermanentFailuresOperationSpecific() {
    XCTAssertEqual(
      KeychainLocalDataKeyStore.errorForSecurityStatus(
        operation: "add",
        status: errSecAuthFailed
      ),
      .operationFailed(operation: "add", status: errSecAuthFailed)
    )
  }

  func testFreshGenerationReportsLockedProtectedAddAsTemporarilyUnavailable() {
    let protectedScope = scope(dataProtection: true)
    let unavailable = KeychainLocalDataKeyStore.StoreError.temporarilyUnavailable(
      status: errSecInteractionNotAllowed
    )
    let itemAccess = InMemoryLocalDataKeychain(
      addErrors: [protectedScope: unavailable]
    )
    let store = makeStore(itemAccess: itemAccess)

    assertStoreError(unavailable) {
      _ = try store.generateFreshKey()
    }

    let snapshot = itemAccess.snapshot()
    XCTAssertTrue(snapshot.storage.isEmpty)
    XCTAssertEqual(snapshot.events, [.add(protectedScope)])
  }

  func testFreshGenerationReportsLockedProtectedReadbackAsTemporarilyUnavailable() {
    let protectedScope = scope(dataProtection: true)
    let unavailable = KeychainLocalDataKeyStore.StoreError.temporarilyUnavailable(
      status: errSecNotAvailable
    )
    let itemAccess = InMemoryLocalDataKeychain(
      readErrors: [protectedScope: unavailable]
    )
    let store = makeStore(itemAccess: itemAccess)

    assertStoreError(unavailable) {
      _ = try store.generateFreshKey()
    }

    let snapshot = itemAccess.snapshot()
    XCTAssertNotNil(snapshot.storage[protectedScope])
    XCTAssertEqual(snapshot.events, [.add(protectedScope), .read(protectedScope)])
  }

  func testFreshGenerationAcceptsConcurrentDuplicateWinner() throws {
    let concurrentWinner = key(byte: 0x75)
    let protectedScope = scope(dataProtection: true)
    let itemAccess = InMemoryLocalDataKeychain(
      duplicateDataOnAdd: [protectedScope: concurrentWinner]
    )
    let store = makeStore(itemAccess: itemAccess)

    let candidate = try store.generateFreshKey()

    XCTAssertEqual(candidate, .init(key: concurrentWinner, source: .dataProtection))
    let snapshot = itemAccess.snapshot()
    XCTAssertEqual(snapshot.storage[protectedScope], concurrentWinner)
    XCTAssertEqual(snapshot.events, [.add(protectedScope), .read(protectedScope)])
  }

  private let service = "dev.zrr.Rill.local-data-key-tests"
  private let account = "root-key"

  private func makeStore(
    useDataProtectionKeychain: Bool
  ) -> (store: KeychainLocalDataKeyStore, itemAccess: InMemoryLocalDataKeychain) {
    let itemAccess = InMemoryLocalDataKeychain()
    return (
      KeychainLocalDataKeyStore(
        service: service,
        account: account,
        useDataProtectionKeychain: useDataProtectionKeychain,
        itemAccess: itemAccess
      ),
      itemAccess
    )
  }

  private func makeStore(
    itemAccess: InMemoryLocalDataKeychain
  ) -> KeychainLocalDataKeyStore {
    KeychainLocalDataKeyStore(
      service: service,
      account: account,
      useDataProtectionKeychain: true,
      itemAccess: itemAccess
    )
  }

  private func key(byte: UInt8) -> Data {
    Data(repeating: byte, count: KeychainLocalDataKeyStore.keyByteCount)
  }

  private func scope(dataProtection: Bool) -> KeychainLocalDataKeyScope {
    KeychainLocalDataKeyScope(
      service: service,
      account: account,
      usesDataProtectionKeychain: dataProtection
    )
  }

  private func cleanupSecurityItems(service: String, account: String) {
    for dataProtection in [false, true] {
      var query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecAttrSynchronizable: kCFBooleanFalse as Any,
      ]
      if dataProtection {
        query[kSecUseDataProtectionKeychain] = kCFBooleanTrue as Any
      }
      SecItemDelete(query as CFDictionary)
    }
  }

  private func assertStoreError(
    _ expected: KeychainLocalDataKeyStore.StoreError,
    operation: () throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    do {
      try operation()
      XCTFail("Expected Keychain local data key operation to fail.", file: file, line: line)
    } catch let error as KeychainLocalDataKeyStore.StoreError {
      XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
      XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
  }
}

private enum LocalDataKeychainEvent: Sendable, Equatable {
  case read(KeychainLocalDataKeyScope)
  case add(KeychainLocalDataKeyScope)
}

private final class InMemoryLocalDataKeychain: KeychainLocalDataKeyItemAccess, @unchecked Sendable {
  struct Snapshot: Sendable {
    let storage: [KeychainLocalDataKeyScope: Data]
    let events: [LocalDataKeychainEvent]
  }

  private let lock = NSLock()
  private var storage: [KeychainLocalDataKeyScope: Data]
  private var events: [LocalDataKeychainEvent] = []
  private let readErrors: [KeychainLocalDataKeyScope: KeychainLocalDataKeyStore.StoreError]
  private let addErrors: [KeychainLocalDataKeyScope: KeychainLocalDataKeyStore.StoreError]
  private let duplicateDataOnAdd: [KeychainLocalDataKeyScope: Data]

  init(
    storage: [KeychainLocalDataKeyScope: Data] = [:],
    readErrors: [KeychainLocalDataKeyScope: KeychainLocalDataKeyStore.StoreError] = [:],
    addErrors: [KeychainLocalDataKeyScope: KeychainLocalDataKeyStore.StoreError] = [:],
    duplicateDataOnAdd: [KeychainLocalDataKeyScope: Data] = [:]
  ) {
    self.storage = storage
    self.readErrors = readErrors
    self.addErrors = addErrors
    self.duplicateDataOnAdd = duplicateDataOnAdd
  }

  func data(for scope: KeychainLocalDataKeyScope) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    events.append(.read(scope))
    if let error = readErrors[scope] {
      throw error
    }
    return storage[scope]
  }

  func addData(
    _ data: Data,
    for scope: KeychainLocalDataKeyScope
  ) throws -> KeychainLocalDataKeyAddResult {
    lock.lock()
    defer { lock.unlock() }
    events.append(.add(scope))
    if let error = addErrors[scope] {
      throw error
    }
    guard storage[scope] == nil else {
      return .duplicateItem
    }
    if let duplicateData = duplicateDataOnAdd[scope] {
      storage[scope] = duplicateData
      return .duplicateItem
    }
    storage[scope] = data
    return .added
  }

  func resetEvents() {
    lock.lock()
    defer { lock.unlock() }
    events.removeAll(keepingCapacity: true)
  }

  func installConcurrentData(_ data: Data, for scope: KeychainLocalDataKeyScope) {
    lock.lock()
    defer { lock.unlock() }
    storage[scope] = data
  }

  func snapshot() -> Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return Snapshot(storage: storage, events: events)
  }
}
