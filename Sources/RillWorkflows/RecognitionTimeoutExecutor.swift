import Foundation
import RillCore

/// Runtime policy for bounding the post-recording recognition stage.
///
/// The budget grows with the captured audio duration so long recordings do not
/// inherit a short-dictation deadline, while the hard ceiling guarantees that a
/// provider can never keep the background queue occupied indefinitely.
public struct RecognitionTimeoutPolicy: Sendable, Equatable {
  public let minimumTimeoutSeconds: Double
  public let audioDurationMultiplier: Double
  public let additionalGraceSeconds: Double
  public let maximumTimeoutSeconds: Double

  public init(
    minimumTimeoutSeconds: Double = 120,
    audioDurationMultiplier: Double = 2,
    additionalGraceSeconds: Double = 0,
    maximumTimeoutSeconds: Double = 600
  ) {
    precondition(minimumTimeoutSeconds.isFinite && minimumTimeoutSeconds > 0)
    precondition(audioDurationMultiplier.isFinite && audioDurationMultiplier >= 0)
    precondition(additionalGraceSeconds.isFinite && additionalGraceSeconds >= 0)
    precondition(
      maximumTimeoutSeconds.isFinite
        && maximumTimeoutSeconds >= minimumTimeoutSeconds
    )
    self.minimumTimeoutSeconds = minimumTimeoutSeconds
    self.audioDurationMultiplier = audioDurationMultiplier
    self.additionalGraceSeconds = additionalGraceSeconds
    self.maximumTimeoutSeconds = maximumTimeoutSeconds
  }

  public static let standard = RecognitionTimeoutPolicy()

  public func timeoutSeconds(forAudioDuration audioDurationSeconds: Double?) -> Double {
    guard let audioDurationSeconds,
      audioDurationSeconds.isFinite,
      audioDurationSeconds > 0
    else {
      return minimumTimeoutSeconds
    }

    let scaledTimeout =
      audioDurationSeconds * audioDurationMultiplier + additionalGraceSeconds
    guard scaledTimeout.isFinite else { return maximumTimeoutSeconds }
    return min(max(scaledTimeout, minimumTimeoutSeconds), maximumTimeoutSeconds)
  }
}

enum RecognitionDeadlineError: Error, LocalizedError, Sendable, Equatable {
  case timedOut
  case previousOperationStillFinishing

  var errorDescription: String? {
    switch self {
    case .timedOut:
      HistoryFailureSanitizer.recognitionTimeoutMessage
    case .previousOperationStillFinishing:
      HistoryFailureSanitizer.recognitionRecoveryPendingMessage
    }
  }
}

/// Races a recognizer against a monotonic deadline without structurally waiting
/// for a provider that ignores cooperative task cancellation.
///
/// A timed-out provider remains quarantined until its late operation actually
/// returns. This bounds queued native work to one operation per recognizer and
/// ensures a late transcript can never re-enter the workflow session.
actor RecognitionTimeoutExecutor {
  typealias Sleep = @Sendable (Duration) async throws -> Void

  private struct ActiveOperation: Sendable {
    let id: UUID
    let runID: UUID
    let isolatedAudio: CapturedAudio?
  }

  private struct PreparedRequest: Sendable {
    let request: RecognitionRequest
    let isolatedAudio: CapturedAudio?
  }

  private let isolateAudio: @Sendable (CapturedAudio) throws -> CapturedAudio
  private let sleep: Sleep
  private let cleanupOwner: any ManagedTemporaryAudioCleaning
  private var activeOperationsByRecognizer: [String: ActiveOperation] = [:]

  init(
    sleep: @escaping Sleep = { duration in
      try await ContinuousClock().sleep(for: duration)
    },
    cleanupOwner: any ManagedTemporaryAudioCleaning,
    isolateAudio: @escaping @Sendable (CapturedAudio) throws -> CapturedAudio
  ) {
    self.isolateAudio = isolateAudio
    self.sleep = sleep
    self.cleanupOwner = cleanupOwner
  }

  func recognize(
    using recognizer: any SpeechRecognizer,
    request: RecognitionRequest,
    timeout: Duration
  ) async throws -> RecognitionResult {
    precondition(timeout > .zero)
    try Task.checkCancellation()

    guard activeOperationsByRecognizer[recognizer.id] == nil else {
      throw RecognitionDeadlineError.previousOperationStillFinishing
    }

    let operationID = UUID()
    let recognizerID = recognizer.id
    let preparedRequest = try isolateManagedAudio(in: request)
    let race = RecognitionDeadlineRace()
    let priority = Task.currentPriority
    activeOperationsByRecognizer[recognizerID] = ActiveOperation(
      id: operationID,
      runID: request.runID,
      isolatedAudio: preparedRequest.isolatedAudio
    )

    let operationTask = Task.detached(priority: priority) { [self] in
      let outcome: RecognitionDeadlineOutcome
      do {
        outcome = .completed(try await recognizer.recognize(preparedRequest.request))
      } catch {
        outcome = .failed(error)
      }
      await operationDidFinish(operationID, recognizerID: recognizerID)
      await race.resolve(outcome)
    }
    let sleep = self.sleep
    let timeoutTask = Task.detached(priority: priority) {
      do {
        try await sleep(timeout)
        try Task.checkCancellation()
      } catch {
        return
      }
      await race.resolve(.timedOut)
    }

    let outcome = await withTaskCancellationHandler {
      await race.wait()
    } onCancel: {
      operationTask.cancel()
      timeoutTask.cancel()
      Task {
        await race.resolve(.cancelled)
      }
    }

    timeoutTask.cancel()
    if Task.isCancelled {
      operationTask.cancel()
      throw CancellationError()
    }
    switch outcome {
    case .completed(let result):
      return result
    case .failed(let error):
      throw error
    case .timedOut:
      operationTask.cancel()
      throw RecognitionDeadlineError.timedOut
    case .cancelled:
      operationTask.cancel()
      throw CancellationError()
    }
  }

  private func isolateManagedAudio(in request: RecognitionRequest) throws -> PreparedRequest {
    guard let capturedAudio = request.capturedAudio,
      capturedAudio.fileOwnership == .managedTemporary,
      capturedAudio.fileURL != nil
    else {
      return PreparedRequest(request: request, isolatedAudio: nil)
    }

    let isolatedAudio = try isolateAudio(capturedAudio)
    var isolatedRequest = request
    isolatedRequest.capturedAudio = isolatedAudio
    return PreparedRequest(request: isolatedRequest, isolatedAudio: isolatedAudio)
  }

  private func operationDidFinish(_ operationID: UUID, recognizerID: String) async {
    guard let operation = activeOperationsByRecognizer[recognizerID],
      operation.id == operationID
    else {
      return
    }

    activeOperationsByRecognizer[recognizerID] = nil
    await transferCleanupToOwner(operation)
  }

  private func transferCleanupToOwner(_ operation: ActiveOperation) async {
    guard let isolatedAudio = operation.isolatedAudio else { return }
    _ = await cleanupOwner.transfer(isolatedAudio, runID: operation.runID)
  }

  func hasActiveOperation(for recognizerID: String) -> Bool {
    activeOperationsByRecognizer[recognizerID] != nil
  }
}

private enum RecognitionDeadlineOutcome: Sendable {
  case completed(RecognitionResult)
  case failed(any Error)
  case timedOut
  case cancelled
}

private actor RecognitionDeadlineRace {
  private var outcome: RecognitionDeadlineOutcome?
  private var waiter: CheckedContinuation<RecognitionDeadlineOutcome, Never>?

  func wait() async -> RecognitionDeadlineOutcome {
    if let outcome { return outcome }
    return await withCheckedContinuation { continuation in
      precondition(waiter == nil)
      waiter = continuation
    }
  }

  func resolve(_ newOutcome: RecognitionDeadlineOutcome) {
    guard outcome == nil else { return }
    outcome = newOutcome
    let pendingWaiter = waiter
    waiter = nil
    pendingWaiter?.resume(returning: newOutcome)
  }
}
