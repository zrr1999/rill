import Foundation
import RillPlatform

enum LocalDataKeyResolutionError: Error, Sendable, Equatable {
  case noValidatedCandidate
  case ambiguousValidatedCandidates
}

enum LocalDataKeyResolutionDecision: Sendable {
  case existing(KeychainLocalDataKeyStore.Candidate)
  case generateFresh
}

/// Selects one root key without mutating SQLite, recovery artifacts, or Keychain.
///
/// Durable stores that already contain protected data must all authenticate the
/// same candidate. A fresh installation may prefer the Data Protection Keychain
/// candidate because no encrypted data is being rebound by that choice.
enum LocalDataKeyResolver {
  static func resolve(
    candidates: [KeychainLocalDataKeyStore.Candidate],
    databaseRequiresExistingKey: Bool,
    recoveryRequiresExistingKey: Bool,
    archiveRequiresExistingKey: Bool = false,
    databaseAccepts: (Data) throws -> Bool,
    recoveryAccepts: (Data) throws -> Bool,
    archiveAccepts: (Data) throws -> Bool = { _ in true }
  ) throws -> LocalDataKeyResolutionDecision {
    guard databaseRequiresExistingKey || recoveryRequiresExistingKey
      || archiveRequiresExistingKey
    else {
      if let protected = candidates.first(where: { $0.source == .dataProtection }) {
        return .existing(protected)
      }
      if let first = candidates.first {
        return .existing(first)
      }
      return .generateFresh
    }

    var validated: [KeychainLocalDataKeyStore.Candidate] = []
    for candidate in candidates {
      if databaseRequiresExistingKey,
        try !databaseAccepts(candidate.key)
      {
        continue
      }
      if recoveryRequiresExistingKey,
        try !recoveryAccepts(candidate.key)
      {
        continue
      }
      if archiveRequiresExistingKey,
        try !archiveAccepts(candidate.key)
      {
        continue
      }
      if !validated.contains(where: { $0.key == candidate.key }) {
        validated.append(candidate)
      }
    }

    switch validated.count {
    case 1:
      return .existing(validated[0])
    case 0:
      throw LocalDataKeyResolutionError.noValidatedCandidate
    default:
      throw LocalDataKeyResolutionError.ambiguousValidatedCandidates
    }
  }

  /// Re-authenticates the selected key against the current durable-storage
  /// bindings immediately before Keychain finalization.
  ///
  /// Bootstrap performs an earlier discovery pass to select a candidate.
  /// Another process can create a recovery artifact after that pass, so the
  /// selection must not be finalized from the stale binding snapshot.
  static func revalidate(
    candidate: KeychainLocalDataKeyStore.Candidate,
    databaseRequiresExistingKey: Bool,
    recoveryRequiresExistingKey: Bool,
    archiveRequiresExistingKey: Bool = false,
    databaseAccepts: (Data) throws -> Bool,
    recoveryAccepts: (Data) throws -> Bool,
    archiveAccepts: (Data) throws -> Bool = { _ in true }
  ) throws {
    if databaseRequiresExistingKey,
      try !databaseAccepts(candidate.key)
    {
      throw LocalDataKeyResolutionError.noValidatedCandidate
    }
    if recoveryRequiresExistingKey,
      try !recoveryAccepts(candidate.key)
    {
      throw LocalDataKeyResolutionError.noValidatedCandidate
    }
    if archiveRequiresExistingKey,
      try !archiveAccepts(candidate.key)
    {
      throw LocalDataKeyResolutionError.noValidatedCandidate
    }
  }
}
