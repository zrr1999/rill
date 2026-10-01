import Foundation
import RillCore

/// Shared microphone-stop to queue-ownership sequence.
/// Callers keep their own state machines and pass the discard policy for each exit.
enum SealedCaptureHandoff {
  struct Timings: Equatable, Sendable {
    var finishMillis: String
    var sealMillis: String
    var cueMillis: String
  }

  enum Outcome: Equatable {
    case queued(Timings)
    case discarded
    case rejected
    case lostAfterAccept
  }

  nonisolated(nonsending) static func transfer<Lease>(
    finish: () async throws -> DeferredCapturedAudio,
    owns: () -> Bool,
    ownsForQueue: () -> Bool,
    seal: () async throws -> Void,
    stoppedCue: () async -> Void,
    beforeLease: (Timings) async -> Void,
    lease: () async throws -> Lease,
    enqueue: (Lease, DeferredCapturedAudio) async -> CapturedAudioProcessingQueue.OwnershipTransferResult,
    discard: (DeferredCapturedAudio) async -> Void,
    discardAfterSealFailure: (DeferredCapturedAudio) async -> Void,
    afterRejected: () async -> Void,
    afterLostOwnership: () async -> Void
  ) async throws -> Outcome {
    let finishStart = ContinuousClock.now
    let deferredCapture = try await finish()
    let finishMillis = DiagnosticTiming.milliseconds(since: finishStart)
    guard owns() else {
      await discard(deferredCapture)
      return .discarded
    }
    let sealStart = ContinuousClock.now
    do {
      try await seal()
    } catch {
      deferredCapture.cancel()
      await discardAfterSealFailure(deferredCapture)
      throw error
    }
    guard owns() else {
      await discard(deferredCapture)
      return .discarded
    }
    let sealMillis = DiagnosticTiming.milliseconds(since: sealStart)
    let cueStart = ContinuousClock.now
    await stoppedCue()
    let cueMillis = DiagnosticTiming.milliseconds(since: cueStart)
    guard owns() else {
      await discard(deferredCapture)
      return .discarded
    }
    let timings = Timings(finishMillis: finishMillis, sealMillis: sealMillis, cueMillis: cueMillis)
    await beforeLease(timings)
    guard owns() else {
      await discard(deferredCapture)
      return .discarded
    }
    let processingLease = try await lease()
    guard ownsForQueue() else {
      await discard(deferredCapture)
      return .discarded
    }
    let ownership = await enqueue(processingLease, deferredCapture)
    guard ownership == .accepted else {
      await discard(deferredCapture)
      await afterRejected()
      return .rejected
    }
    guard ownsForQueue() else {
      await afterLostOwnership()
      return .lostAfterAccept
    }
    return .queued(timings)
  }
}
