import Foundation
import XCTest
@testable import RillCore

final class AudioCaptureLifetimeTests: XCTestCase {
  func testRevocationRejectsLaterTransitions() {
    let lifetime = AudioCaptureLifetime(runID: UUID())

    XCTAssertEqual(lifetime.state, .active)
    XCTAssertTrue(lifetime.isActive)
    XCTAssertTrue(lifetime.revoke(.authorizationInvalidated))
    XCTAssertEqual(lifetime.state, .revoked(.authorizationInvalidated))
    XCTAssertFalse(lifetime.isActive)
    XCTAssertFalse(lifetime.revoke(.serviceFailure), "The first terminal transition must win.")
  }

  func testCompletionIsIdempotentAndTerminal() {
    let lifetime = AudioCaptureLifetime(runID: UUID())

    XCTAssertTrue(lifetime.complete())
    XCTAssertEqual(lifetime.state, .completed)
    XCTAssertFalse(lifetime.complete())
    XCTAssertFalse(lifetime.cancel())
    XCTAssertFalse(lifetime.isActive)
  }

  func testCancellationIsIdempotentAndPreservesFirstReason() {
    let lifetime = AudioCaptureLifetime(runID: UUID())

    XCTAssertTrue(lifetime.cancel(reason: .captureSuperseded))
    XCTAssertFalse(lifetime.cancel())
    XCTAssertEqual(lifetime.state, .revoked(.captureSuperseded))
  }

  func testLifetimeEqualityUsesAuthorizationIdentity() {
    let runID = UUID()
    let lifetime = AudioCaptureLifetime(runID: runID)
    let sameReference = lifetime
    let distinctAuthorization = AudioCaptureLifetime(runID: runID)

    XCTAssertEqual(lifetime, sameReference)
    XCTAssertNotEqual(lifetime, distinctAuthorization)
  }

  func testTerminalStateStreamDeliversTransitionAndCanOnlyBeClaimedOnce() async throws {
    let lifetime = AudioCaptureLifetime(runID: UUID())
    let stream = try XCTUnwrap(lifetime.claimTerminalStateStream())

    XCTAssertNil(lifetime.claimTerminalStateStream())
    XCTAssertTrue(lifetime.revoke(.serviceFailure))

    var iterator = stream.makeAsyncIterator()
    let terminalState = await iterator.next()
    let end = await iterator.next()
    XCTAssertEqual(terminalState, .revoked(.serviceFailure))
    XCTAssertNil(end)
  }

  func testTerminalStateStreamBuffersTransitionThatPrecedesClaim() async throws {
    let lifetime = AudioCaptureLifetime(runID: UUID())
    XCTAssertTrue(lifetime.complete())

    let stream = try XCTUnwrap(lifetime.claimTerminalStateStream())
    var iterator = stream.makeAsyncIterator()

    let terminalState = await iterator.next()
    let end = await iterator.next()
    XCTAssertEqual(terminalState, .completed)
    XCTAssertNil(end)
  }
}
