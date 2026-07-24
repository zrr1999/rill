import Foundation
import XCTest

@testable import RillApp
@testable import RillPlatform

final class LocalDataKeyResolutionTests: XCTestCase {
  func testFreshStateGeneratesOnlyWhenNoCandidateExists() throws {
    let decision = try resolve(candidates: [], database: false, recovery: false)
    guard case .generateFresh = decision else {
      return XCTFail("A fresh installation should generate one root key.")
    }
  }

  func testUnboundStatePrefersDataProtectionCandidateWithoutProbing() throws {
    var probeCount = 0
    let legacy = candidate(0x11, source: .legacyLogin)
    let protected = candidate(0x22, source: .dataProtection)

    let decision = try LocalDataKeyResolver.resolve(
      candidates: [legacy, protected],
      databaseRequiresExistingKey: false,
      recoveryRequiresExistingKey: false,
      databaseAccepts: { _ in
        probeCount += 1
        return false
      },
      recoveryAccepts: { _ in
        probeCount += 1
        return false
      }
    )

    XCTAssertEqual(existingCandidate(in: decision)?.key, protected.key)
    XCTAssertEqual(probeCount, 0)
  }

  func testDatabaseBindingSelectsLegacyCandidateWithoutConsultingRecovery() throws {
    var recoveryProbeCount = 0
    let protected = candidate(0x31, source: .dataProtection)
    let legacy = candidate(0x32, source: .legacyLogin)

    let decision = try LocalDataKeyResolver.resolve(
      candidates: [protected, legacy],
      databaseRequiresExistingKey: true,
      recoveryRequiresExistingKey: false,
      databaseAccepts: { $0 == legacy.key },
      recoveryAccepts: { _ in
        recoveryProbeCount += 1
        return false
      }
    )

    XCTAssertEqual(existingCandidate(in: decision)?.key, legacy.key)
    XCTAssertEqual(recoveryProbeCount, 0)
  }

  func testSplitRootBindingsFailClosed() {
    let protected = candidate(0x41, source: .dataProtection)
    let legacy = candidate(0x42, source: .legacyLogin)

    XCTAssertThrowsError(
      try LocalDataKeyResolver.resolve(
        candidates: [protected, legacy],
        databaseRequiresExistingKey: true,
        recoveryRequiresExistingKey: true,
        databaseAccepts: { $0 == protected.key },
        recoveryAccepts: { $0 == legacy.key }
      )
    ) {
      XCTAssertEqual($0 as? LocalDataKeyResolutionError, .noValidatedCandidate)
    }
  }

  func testDistinctCandidatesThatBothAuthenticateAreRejectedAsAmbiguous() {
    let protected = candidate(0x51, source: .dataProtection)
    let legacy = candidate(0x52, source: .legacyLogin)

    XCTAssertThrowsError(
      try LocalDataKeyResolver.resolve(
        candidates: [protected, legacy],
        databaseRequiresExistingKey: true,
        recoveryRequiresExistingKey: false,
        databaseAccepts: { _ in true },
        recoveryAccepts: { _ in true }
      )
    ) {
      XCTAssertEqual(
        $0 as? LocalDataKeyResolutionError,
        .ambiguousValidatedCandidates
      )
    }
  }

  func testMissingCandidatesNeverAuthorizeGenerationAndFatalProbeErrorsPropagate() {
    XCTAssertThrowsError(
      try LocalDataKeyResolver.resolve(
        candidates: [],
        databaseRequiresExistingKey: true,
        recoveryRequiresExistingKey: false,
        databaseAccepts: { _ in true },
        recoveryAccepts: { _ in true }
      )
    ) {
      XCTAssertEqual($0 as? LocalDataKeyResolutionError, .noValidatedCandidate)
    }

    let protected = candidate(0x61, source: .dataProtection)
    XCTAssertThrowsError(
      try LocalDataKeyResolver.resolve(
        candidates: [protected],
        databaseRequiresExistingKey: true,
        recoveryRequiresExistingKey: false,
        databaseAccepts: { _ in throw ProbeFailure.rejected },
        recoveryAccepts: { _ in true }
      )
    ) {
      XCTAssertEqual($0 as? ProbeFailure, .rejected)
    }
  }

  func testRevalidationRejectsRecoveryBindingCreatedAfterInitialSelection() throws {
    let protected = candidate(0x71, source: .dataProtection)

    let initialDecision = try LocalDataKeyResolver.resolve(
      candidates: [protected],
      databaseRequiresExistingKey: true,
      recoveryRequiresExistingKey: false,
      databaseAccepts: { $0 == protected.key },
      recoveryAccepts: { _ in false }
    )
    XCTAssertEqual(existingCandidate(in: initialDecision), protected)

    XCTAssertThrowsError(
      try LocalDataKeyResolver.revalidate(
        candidate: protected,
        databaseRequiresExistingKey: true,
        recoveryRequiresExistingKey: true,
        databaseAccepts: { $0 == protected.key },
        recoveryAccepts: { _ in false }
      )
    ) {
      XCTAssertEqual($0 as? LocalDataKeyResolutionError, .noValidatedCandidate)
    }
  }

  func testRevalidationPropagatesFatalProbeFailure() {
    let protected = candidate(0x72, source: .dataProtection)

    XCTAssertThrowsError(
      try LocalDataKeyResolver.revalidate(
        candidate: protected,
        databaseRequiresExistingKey: true,
        recoveryRequiresExistingKey: true,
        databaseAccepts: { _ in true },
        recoveryAccepts: { _ in throw ProbeFailure.rejected }
      )
    ) {
      XCTAssertEqual($0 as? ProbeFailure, .rejected)
    }
  }

  private func resolve(
    candidates: [KeychainLocalDataKeyStore.Candidate],
    database: Bool,
    recovery: Bool
  ) throws -> LocalDataKeyResolutionDecision {
    try LocalDataKeyResolver.resolve(
      candidates: candidates,
      databaseRequiresExistingKey: database,
      recoveryRequiresExistingKey: recovery,
      databaseAccepts: { _ in true },
      recoveryAccepts: { _ in true }
    )
  }

  private func candidate(
    _ byte: UInt8,
    source: KeychainLocalDataKeyStore.Candidate.Source
  ) -> KeychainLocalDataKeyStore.Candidate {
    KeychainLocalDataKeyStore.Candidate(
      key: Data(repeating: byte, count: KeychainLocalDataKeyStore.keyByteCount),
      source: source
    )
  }

  private func existingCandidate(
    in decision: LocalDataKeyResolutionDecision
  ) -> KeychainLocalDataKeyStore.Candidate? {
    guard case .existing(let candidate) = decision else { return nil }
    return candidate
  }
}

private enum ProbeFailure: Error, Equatable {
  case rejected
}
