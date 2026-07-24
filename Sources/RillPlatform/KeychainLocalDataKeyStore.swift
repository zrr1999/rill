import Foundation
import Security
import RillCore

struct KeychainLocalDataKeyScope: Hashable, Sendable {
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

  func newItem(data: Data) -> [CFString: Any] {
    var item = query
    item[kSecValueData] = data
    if usesDataProtectionKeychain {
      item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    }
    return item
  }
}

enum KeychainLocalDataKeyAddResult: Sendable, Equatable {
  case added
  case duplicateItem
}

protocol KeychainLocalDataKeyItemAccess: Sendable {
  func data(for scope: KeychainLocalDataKeyScope) throws -> Data?
  func addData(
    _ data: Data,
    for scope: KeychainLocalDataKeyScope
  ) throws -> KeychainLocalDataKeyAddResult
}

private struct SecurityKeychainLocalDataKeyItemAccess: KeychainLocalDataKeyItemAccess {
  func data(for scope: KeychainLocalDataKeyScope) throws -> Data? {
    var query = scope.query
    query[kSecReturnData] = kCFBooleanTrue
    query[kSecMatchLimit] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw KeychainLocalDataKeyStore.errorForSecurityStatus(
        operation: "read",
        status: status
      )
    }
    guard let data = result as? Data else {
      throw KeychainLocalDataKeyStore.StoreError.invalidStoredDataType
    }
    return data
  }

  func addData(
    _ data: Data,
    for scope: KeychainLocalDataKeyScope
  ) throws -> KeychainLocalDataKeyAddResult {
    let status = SecItemAdd(scope.newItem(data: data) as CFDictionary, nil)
    switch status {
    case errSecSuccess:
      return .added
    case errSecDuplicateItem:
      return .duplicateItem
    default:
      throw KeychainLocalDataKeyStore.errorForSecurityStatus(
        operation: "add",
        status: status
      )
    }
  }

}

/// Owns the immutable root key used to protect local user content.
///
/// Entitled builds prefer the local Data Protection Keychain. Source builds
/// without an application identifier use the encrypted login Keychain. Root
/// keys are only read or installed into an empty scope; this store never
/// replaces or removes an existing root-key item.
public struct KeychainLocalDataKeyStore: Sendable {
  public static let defaultAccount = "local-data-root-key.v1"
  public static let keyByteCount = AESGCMDataProtector.keyByteCount

  public struct Candidate: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
      case dataProtection
      case legacyLogin
    }

    public let key: Data
    public let source: Source

    public init(key: Data, source: Source) {
      self.key = key
      self.source = source
    }
  }

  public enum AdditionalKeyStatus: Sendable, Equatable {
    case none
    case matchingLegacyKeyRetained
    case alternateKeyRetained
  }

  public struct FinalizationResult: Sendable, Equatable {
    public let key: Data
    public let additionalKeyStatus: AdditionalKeyStatus

    public init(key: Data, additionalKeyStatus: AdditionalKeyStatus) {
      self.key = key
      self.additionalKeyStatus = additionalKeyStatus
    }
  }

  public enum StoreError: Error, LocalizedError, Sendable, Equatable {
    case keyNotFound
    case conflictingKeys
    case invalidKeyLength(expected: Int, actual: Int)
    case invalidStoredDataType
    case operationFailed(operation: String, status: OSStatus)
    case temporarilyUnavailable(status: OSStatus)
    case randomGenerationFailed(status: OSStatus)
    case verificationFailed

    public var errorDescription: String? {
      switch self {
      case .keyNotFound:
        return "The local data protection key is unavailable and key creation is disabled."
      case .conflictingKeys:
        return "Multiple local data protection keys require durable-storage validation."
      case .invalidKeyLength(let expected, let actual):
        return
          "The local data protection key must contain exactly \(expected) bytes; received \(actual)."
      case .invalidStoredDataType:
        return "Keychain returned the local data protection key in an unexpected data type."
      case .operationFailed(let operation, let status):
        let description =
          SecCopyErrorMessageString(status, nil) as String?
          ?? "OSStatus \(status)"
        return "Local data protection key \(operation) failed: \(description)."
      case .temporarilyUnavailable(let status):
        let description =
          SecCopyErrorMessageString(status, nil) as String?
          ?? "OSStatus \(status)"
        return "The local data protection key is temporarily unavailable: \(description)."
      case .randomGenerationFailed(let status):
        let description =
          SecCopyErrorMessageString(status, nil) as String?
          ?? "OSStatus \(status)"
        return "Local data protection key generation failed: \(description)."
      case .verificationFailed:
        return "The local data protection key did not match its Keychain readback."
      }
    }
  }

  public let service: String
  public let account: String
  let usesDataProtectionKeychain: Bool

  private let itemAccess: any KeychainLocalDataKeyItemAccess

  public init(service: String, account: String = Self.defaultAccount) {
    self.init(
      service: service,
      account: account,
      useDataProtectionKeychain: Self.currentProcessHasApplicationIdentifierEntitlement(),
      itemAccess: SecurityKeychainLocalDataKeyItemAccess()
    )
  }

  init(
    service: String,
    account: String = Self.defaultAccount,
    useDataProtectionKeychain: Bool
  ) {
    self.init(
      service: service,
      account: account,
      useDataProtectionKeychain: useDataProtectionKeychain,
      itemAccess: SecurityKeychainLocalDataKeyItemAccess()
    )
  }

  init(
    service: String,
    account: String = Self.defaultAccount,
    useDataProtectionKeychain: Bool,
    itemAccess: any KeychainLocalDataKeyItemAccess
  ) {
    precondition(!service.isEmpty, "A stable Keychain service identifier is required.")
    precondition(!account.isEmpty, "A stable Keychain account identifier is required.")
    self.service = service
    self.account = account
    self.usesDataProtectionKeychain = useDataProtectionKeychain
    self.itemAccess = itemAccess
  }

  /// Loads every distinct candidate without changing either Keychain scope.
  ///
  /// A Data Protection read failure is terminal for this attempt. In
  /// particular, a locked Keychain must never cause fallback to a possibly
  /// stale login item.
  public func loadCandidates() throws -> [Candidate] {
    let legacyScope = scope(dataProtection: false)
    guard usesDataProtectionKeychain else {
      return try itemAccess.data(for: legacyScope).map {
        [Candidate(key: try validate($0), source: .legacyLogin)]
      } ?? []
    }

    let protectedScope = scope(dataProtection: true)
    let protectedKey = try itemAccess.data(for: protectedScope).map(validate)
    let legacyKey = try itemAccess.data(for: legacyScope).map(validate)

    switch (protectedKey, legacyKey) {
    case (nil, nil):
      return []
    case (.some(let key), nil):
      return [Candidate(key: key, source: .dataProtection)]
    case (nil, .some(let key)):
      return [Candidate(key: key, source: .legacyLogin)]
    case (.some(let protectedKey), .some(let legacyKey)):
      if protectedKey == legacyKey {
        return [Candidate(key: protectedKey, source: .dataProtection)]
      }
      return [
        Candidate(key: protectedKey, source: .dataProtection),
        Candidate(key: legacyKey, source: .legacyLogin),
      ]
    }
  }

  /// Generates and installs a key for storage that the caller has already
  /// proven has no durable key binding and no existing candidates.
  ///
  /// A concurrent creator wins through the duplicate-item path; its exact
  /// readback becomes the returned candidate.
  public func generateFreshKey() throws -> Candidate {
    let generatedKey = try generateKey()
    let dataProtection = usesDataProtectionKeychain
    let targetScope = scope(dataProtection: dataProtection)
    let result = try itemAccess.addData(generatedKey, for: targetScope)
    guard let readback = try itemAccess.data(for: targetScope) else {
      throw StoreError.verificationFailed
    }
    let storedKey = try validate(readback)
    if result == .added, storedKey != generatedKey {
      throw StoreError.verificationFailed
    }
    return Candidate(
      key: storedKey,
      source: dataProtection ? .dataProtection : .legacyLogin
    )
  }

  /// Commits a key only after the caller has authenticated every durable
  /// local-data binding with that candidate.
  ///
  /// An existing active-scope root key is immutable. A distinct incumbent or
  /// concurrent winner is never overwritten. When a competing Data Protection
  /// key is active, finalization succeeds only while the login scope retains
  /// the selected key exactly. Login-scope keys are reported and always kept.
  public func finalizeValidatedKey(_ selected: Candidate) throws -> FinalizationResult {
    let key = try validate(selected.key)
    guard usesDataProtectionKeychain else {
      guard
        try ensureValidatedKey(key, in: scope(dataProtection: false))
          == .selectedKeyIsActive
      else {
        throw StoreError.verificationFailed
      }
      return FinalizationResult(key: key, additionalKeyStatus: .none)
    }

    let protectedKeyState = try ensureValidatedKey(
      key,
      in: scope(dataProtection: true)
    )
    let legacyScope = scope(dataProtection: false)
    let legacyKey = try itemAccess.data(for: legacyScope).map(validate)
    if protectedKeyState == .competingKeyIsActive {
      guard legacyKey == key else {
        throw StoreError.verificationFailed
      }
      return FinalizationResult(
        key: key,
        additionalKeyStatus: .alternateKeyRetained
      )
    }

    let additionalKeyStatus: AdditionalKeyStatus
    switch legacyKey {
    case nil:
      additionalKeyStatus = .none
    case key:
      additionalKeyStatus = .matchingLegacyKeyRetained
    default:
      additionalKeyStatus = .alternateKeyRetained
    }
    return FinalizationResult(key: key, additionalKeyStatus: additionalKeyStatus)
  }

  /// Compatibility read that is deliberately non-mutating. Callers that see
  /// conflicting candidates must validate durable storage explicitly.
  public func loadKey() throws -> Data? {
    let candidates = try loadCandidates()
    guard candidates.count <= 1 else {
      throw StoreError.conflictingKeys
    }
    return candidates.first?.key
  }

  /// Compatibility wrapper for unbound storage. It never finalizes or cleans
  /// legacy state; new code should use the explicit two-phase API.
  public func loadOrCreateKey(allowCreation: Bool = true) throws -> Data {
    let candidates = try loadCandidates()
    guard candidates.count <= 1 else {
      throw StoreError.conflictingKeys
    }
    if let candidate = candidates.first {
      return candidate.key
    }
    guard allowCreation else {
      throw StoreError.keyNotFound
    }
    return try generateFreshKey().key
  }

  func baseQuery(useDataProtectionKeychain: Bool) -> [CFString: Any] {
    scope(dataProtection: useDataProtectionKeychain).query
  }

  func newItem(
    data: Data,
    useDataProtectionKeychain: Bool
  ) -> [CFString: Any] {
    scope(dataProtection: useDataProtectionKeychain).newItem(data: data)
  }

  static func errorForSecurityStatus(
    operation: String,
    status: OSStatus
  ) -> StoreError {
    switch status {
    case errSecInteractionNotAllowed, errSecNotAvailable:
      return .temporarilyUnavailable(status: status)
    default:
      return .operationFailed(operation: operation, status: status)
    }
  }

  private enum KeyInstallationState: Equatable {
    case selectedKeyIsActive
    case competingKeyIsActive
  }

  /// Installs only into an empty scope. Root-key items are immutable once
  /// present, so a different incumbent or concurrent winner is never
  /// overwritten.
  private func ensureValidatedKey(
    _ selectedKey: Data,
    in targetScope: KeychainLocalDataKeyScope
  ) throws -> KeyInstallationState {
    if let existingKey = try itemAccess.data(for: targetScope) {
      return try validate(existingKey) == selectedKey
        ? .selectedKeyIsActive
        : .competingKeyIsActive
    }

    _ = try itemAccess.addData(selectedKey, for: targetScope)
    return try keyInstallationState(
      selectedKey,
      from: targetScope
    )
  }

  private func keyInstallationState(
    _ selectedKey: Data,
    from targetScope: KeychainLocalDataKeyScope
  ) throws -> KeyInstallationState {
    guard let readback = try itemAccess.data(for: targetScope) else {
      throw StoreError.verificationFailed
    }
    return try validate(readback) == selectedKey
      ? .selectedKeyIsActive
      : .competingKeyIsActive
  }

  private func validate(_ key: Data) throws -> Data {
    guard key.count == Self.keyByteCount else {
      throw StoreError.invalidKeyLength(
        expected: Self.keyByteCount,
        actual: key.count
      )
    }
    return key
  }

  private func generateKey() throws -> Data {
    var key = Data(count: Self.keyByteCount)
    let status = key.withUnsafeMutableBytes { bytes -> OSStatus in
      guard let baseAddress = bytes.baseAddress else {
        return errSecAllocate
      }
      return SecRandomCopyBytes(kSecRandomDefault, bytes.count, baseAddress)
    }
    guard status == errSecSuccess else {
      throw StoreError.randomGenerationFailed(status: status)
    }
    return key
  }

  private func scope(dataProtection: Bool) -> KeychainLocalDataKeyScope {
    KeychainLocalDataKeyScope(
      service: service,
      account: account,
      usesDataProtectionKeychain: dataProtection
    )
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
