import XCTest

@testable import RillCore
@testable import RillWorkflows

final class SealedCaptureHandoffTests: XCTestCase {
    func testCancellationAtEachSuspensionDiscardsOrCancelsTheQueue() async throws {
        let steps = ["finish", "seal", "cue", "lease", "enqueue"]
        for cancelledStep in steps {
            let probe = HandoffProbe()
            let outcome = try await SealedCaptureHandoff.transfer(
                finish: { try await probe.gate("finish", cancelledStep: cancelledStep) },
                owns: { probe.owns },
                ownsForQueue: { probe.owns },
                seal: { try await probe.gateVoid("seal", cancelledStep: cancelledStep) },
                stoppedCue: { await probe.gateCue("cue", cancelledStep: cancelledStep) },
                beforeLease: { _ in },
                lease: { try await probe.gateVoid("lease", cancelledStep: cancelledStep) },
                enqueue: { _, capture in
                    await probe.gateCue("enqueue", cancelledStep: cancelledStep)
                    probe.enqueued = capture
                    return probe.enqueueResult
                },
                discard: { capture in
                    capture.cancel()
                    probe.discarded = true
                },
                discardAfterSealFailure: { capture in
                    capture.cancel()
                    probe.sealDiscarded = true
                },
                afterRejected: { probe.rejected = true },
                afterLostOwnership: { probe.lost = true }
            )
            switch cancelledStep {
            case "enqueue":
                XCTAssertEqual(outcome, .lostAfterAccept)
                XCTAssertTrue(probe.lost)
                XCTAssertFalse(probe.discarded)
            default:
                XCTAssertEqual(outcome, .discarded)
                XCTAssertTrue(probe.discarded)
                XCTAssertFalse(probe.lost)
            }
        }
    }

    func testRejectedEnqueueDiscardsAndDoesNotReportQueued() async throws {
        let probe = HandoffProbe()
        probe.enqueueResult = .rejected
        let outcome = try await SealedCaptureHandoff.transfer(
            finish: { probe.capture },
            owns: { true },
            ownsForQueue: { true },
            seal: {},
            stoppedCue: {},
            beforeLease: { _ in },
            lease: { "lease" },
            enqueue: { _, _ in .rejected },
            discard: { _ in probe.discarded = true },
            discardAfterSealFailure: { _ in },
            afterRejected: { probe.rejected = true },
            afterLostOwnership: {}
        )
        XCTAssertEqual(outcome, .rejected)
        XCTAssertTrue(probe.discarded)
        XCTAssertTrue(probe.rejected)
    }
}

private final class HandoffProbe: @unchecked Sendable {
    var owns = true
    var discarded = false
    var sealDiscarded = false
    var rejected = false
    var lost = false
    var enqueued: DeferredCapturedAudio?
    var enqueueResult: CapturedAudioProcessingQueue.OwnershipTransferResult = .accepted
    let capture = DeferredCapturedAudio(task: Task { throw CancellationError() })

    func gate(_ name: String, cancelledStep: String) async throws -> DeferredCapturedAudio {
        if name == cancelledStep { owns = false }
        return capture
    }

    func gateVoid(_ name: String, cancelledStep: String) async throws {
        if name == cancelledStep { owns = false }
    }

    func gateCue(_ name: String, cancelledStep: String) async {
        if name == cancelledStep { owns = false }
    }
}
