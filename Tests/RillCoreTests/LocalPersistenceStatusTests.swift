import XCTest

@testable import RillCore

final class LocalPersistenceStatusTests: XCTestCase {
  func testReadyAndSessionOnlyStatesHaveStableAvailabilitySemantics() {
    XCTAssertFalse(LocalPersistenceStatus.ready.isSessionOnly)
    XCTAssertFalse(
      LocalPersistenceStatus.readyWithNotice(
        .alternateDataProtectionKeyRetained
      ).isSessionOnly
    )
    XCTAssertTrue(
      LocalPersistenceStatus.sessionOnly(
        reason: .persistentStorageUnavailable
      ).isSessionOnly
    )
    XCTAssertTrue(
      LocalPersistenceStatus.sessionOnly(
        reason: .keychainTemporarilyUnavailable
      ).isSessionOnly
    )
  }

  func testReadyNoticeIsAClosedNonSensitiveValue() {
    XCTAssertEqual(
      LocalPersistenceStatus.readyWithNotice(
        .alternateDataProtectionKeyRetained
      ),
      .readyWithNotice(.alternateDataProtectionKeyRetained)
    )
  }

  func testSessionOnlyReasonIsAClosedNonSensitiveValue() {
    let status = LocalPersistenceStatus.sessionOnly(
      reason: .persistentStorageUnavailable
    )

    XCTAssertEqual(
      status,
      .sessionOnly(reason: .persistentStorageUnavailable)
    )
    XCTAssertNotEqual(
      status,
      .sessionOnly(reason: .keychainTemporarilyUnavailable)
    )
  }
}
