import Foundation
import XCTest
@testable import RillCore

final class AudioCaptureLifetimeTests: XCTestCase {
    func testPermitAcquisitionAndRevocationAreLinearized() async {
        let runID = UUID()
        let lifetime = AudioCaptureLifetime(runID: runID)

        XCTAssertEqual(lifetime.state, .active)
        XCTAssertEqual(lifetime.acquireTransmissionPermit()?.runID, runID)
        XCTAssertTrue(lifetime.revoke(.authorizationInvalidated))
        XCTAssertEqual(lifetime.state, .revoked(.authorizationInvalidated))
        XCTAssertNil(lifetime.acquireTransmissionPermit())
        XCTAssertFalse(lifetime.revoke(.serviceFailure), "The first terminal transition must win.")

        let postRevocationPermits = await withTaskGroup(
            of: AudioCaptureLifetime.TransmissionPermit?.self,
            returning: [AudioCaptureLifetime.TransmissionPermit?].self
        ) { group in
            for _ in 0..<32 {
                group.addTask { lifetime.acquireTransmissionPermit() }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertTrue(postRevocationPermits.allSatisfy { $0 == nil })
    }

    func testCompletionIsIdempotentAndTerminal() {
        let lifetime = AudioCaptureLifetime(runID: UUID())

        XCTAssertTrue(lifetime.complete())
        XCTAssertEqual(lifetime.state, .completed)
        XCTAssertFalse(lifetime.complete())
        XCTAssertFalse(lifetime.cancel())
        XCTAssertNil(lifetime.acquireTransmissionPermit())
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
