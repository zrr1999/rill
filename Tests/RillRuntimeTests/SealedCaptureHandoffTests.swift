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

  func testSealFailureCancelsCaptureUsesSealDiscardAndRethrows() async throws {
    let probe = HandoffProbe()
    let capture = DeferredCapturedAudio(
      task: Task {
        try await Task.sleep(for: .seconds(10))
        throw HandoffTestError.captureNotCancelled
      })
    do {
      _ = try await SealedCaptureHandoff.transfer(
        finish: { capture },
        owns: { true },
        ownsForQueue: { true },
        seal: { throw HandoffTestError.sealFailed },
        stoppedCue: { XCTFail("The stop cue follows a sealed capture.") },
        beforeLease: { _ in },
        lease: { "lease" },
        enqueue: { _, _ in
          XCTFail("A capture that failed to seal must not be queued.")
          return .accepted
        },
        discard: { _ in probe.discarded = true },
        discardAfterSealFailure: { _ in probe.sealDiscarded = true },
        afterRejected: {},
        afterLostOwnership: {}
      )
      XCTFail("Seal failure must propagate.")
    } catch HandoffTestError.sealFailed {}
    XCTAssertTrue(probe.sealDiscarded)
    XCTAssertFalse(probe.discarded)
    do {
      _ = try await capture.value()
      XCTFail("An unsealed capture must be cancelled.")
    } catch is CancellationError {}
  }
}

private enum HandoffTestError: Error {
  case sealFailed
  case captureNotCancelled
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
