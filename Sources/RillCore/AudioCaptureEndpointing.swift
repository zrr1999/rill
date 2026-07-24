import Foundation

/// Policy for hands-free, short-form dictation endpoint detection.
///
/// The capture implementation owns acoustic observation. Workflow controllers
/// remain the only owners allowed to finish, cancel, and enqueue a run.
public struct SpeechEndpointPolicy: Sendable, Equatable {
  public var initialSilenceTimeoutSeconds: Double
  public var minimumSpeechDurationSeconds: Double
  public var trailingSilenceDurationSeconds: Double
  public var voiceActivityThreshold: Float

  public init(
    initialSilenceTimeoutSeconds: Double,
    minimumSpeechDurationSeconds: Double,
    trailingSilenceDurationSeconds: Double,
    voiceActivityThreshold: Float
  ) {
    precondition(initialSilenceTimeoutSeconds > 0)
    precondition(minimumSpeechDurationSeconds > 0)
    precondition(trailingSilenceDurationSeconds > 0)
    precondition(Self.isValidVoiceActivityThreshold(voiceActivityThreshold))
    self.initialSilenceTimeoutSeconds = initialSilenceTimeoutSeconds
    self.minimumSpeechDurationSeconds = minimumSpeechDurationSeconds
    self.trailingSilenceDurationSeconds = trailingSilenceDurationSeconds
    self.voiceActivityThreshold = voiceActivityThreshold
  }

  static func isValidVoiceActivityThreshold(_ threshold: Float) -> Bool {
    threshold.isFinite && threshold > 0 && threshold < 1
  }

  /// A conservative endpoint for one-shot dictation. Long-recording and
  /// hold-to-talk modes deliberately do not opt into this policy.
  public static let shortDictation = SpeechEndpointPolicy(
    initialSilenceTimeoutSeconds: 12,
    minimumSpeechDurationSeconds: 0.3,
    trailingSilenceDurationSeconds: 1.4,
    voiceActivityThreshold: 0.3
  )
}

public enum SpeechEndpointOutcome: String, Sendable, Equatable {
  case initialSilenceTimedOut
  case speechEnded
}

/// A deterministic timing state machine. Acoustic classification is supplied
/// by the capture runtime so the detector never infers speech from transcript
/// text or UI state.
public struct SpeechEndpointDetector: Sendable, Equatable {
  public enum State: Sendable, Equatable {
    case waitingForSpeech
    case speaking
    case trailingSilence
    case ended(SpeechEndpointOutcome)
  }

  public let policy: SpeechEndpointPolicy
  public private(set) var state: State = .waitingForSpeech
  private var elapsedSeconds = 0.0
  private var consecutiveSpeechSeconds = 0.0
  private var consecutiveSilenceSeconds = 0.0

  public init(policy: SpeechEndpointPolicy) {
    self.policy = policy
  }

  /// Consumes one independently classified audio interval.
  ///
  /// - Returns: A terminal outcome exactly once.
  @discardableResult
  public mutating func observe(
    isSpeech: Bool,
    durationSeconds: Double
  ) -> SpeechEndpointOutcome? {
    guard durationSeconds > 0 else { return nil }
    guard case .ended = state else {
      elapsedSeconds += durationSeconds

      switch state {
      case .waitingForSpeech:
        if isSpeech {
          consecutiveSpeechSeconds += durationSeconds
          if hasReached(
            consecutiveSpeechSeconds,
            policy.minimumSpeechDurationSeconds
          ) {
            state = .speaking
            consecutiveSilenceSeconds = 0
          }
        } else {
          consecutiveSpeechSeconds = 0
        }

        if state == .waitingForSpeech,
          hasReached(elapsedSeconds, policy.initialSilenceTimeoutSeconds)
        {
          return end(with: .initialSilenceTimedOut)
        }

      case .speaking, .trailingSilence:
        if isSpeech {
          state = .speaking
          consecutiveSilenceSeconds = 0
        } else {
          state = .trailingSilence
          consecutiveSilenceSeconds += durationSeconds
          if hasReached(
            consecutiveSilenceSeconds,
            policy.trailingSilenceDurationSeconds
          ) {
            return end(with: .speechEnded)
          }
        }

      case .ended:
        break
      }
      return nil
    }
    return nil
  }

  private mutating func end(with outcome: SpeechEndpointOutcome) -> SpeechEndpointOutcome {
    state = .ended(outcome)
    return outcome
  }

  private func hasReached(_ elapsed: Double, _ threshold: Double) -> Bool {
    elapsed + 1e-9 >= threshold
  }
}

public enum AudioCaptureTerminalReason: String, Sendable, Equatable {
  case initialSilenceTimedOut
  case speechEnded
  case maximumDurationReached
  case inputEndedUnexpectedly
}

/// A content-free, run-scoped summary of the energy intervals observed while
/// capture was active.
///
/// This summary deliberately contains only aggregate integer counters. It
/// cannot carry audio samples, transcript text, device identity, or file
/// coordinates across the diagnostic boundary.
public struct AudioCaptureAcousticSummary: Sendable, Equatable {
  public let observedSegmentCount: UInt64
  public let observedDurationMilliseconds: UInt64
  public let aboveThresholdDurationMilliseconds: UInt64
  /// The upper bound of the highest five-percentage-point energy bucket.
  public let peakLevelPercentBucket: UInt64
  public let maximumConsecutiveAboveThresholdDurationMilliseconds: UInt64

  public init(
    observedSegmentCount: UInt64 = 0,
    observedDurationMilliseconds: UInt64 = 0,
    aboveThresholdDurationMilliseconds: UInt64 = 0,
    peakLevelPercentBucket: UInt64 = 0,
    maximumConsecutiveAboveThresholdDurationMilliseconds: UInt64 = 0
  ) {
    self.observedSegmentCount = observedSegmentCount
    self.observedDurationMilliseconds = observedDurationMilliseconds
    self.aboveThresholdDurationMilliseconds = aboveThresholdDurationMilliseconds
    self.peakLevelPercentBucket = peakLevelPercentBucket
    self.maximumConsecutiveAboveThresholdDurationMilliseconds =
      maximumConsecutiveAboveThresholdDurationMilliseconds
  }

  public static let empty = AudioCaptureAcousticSummary()
}

public struct AudioCaptureTerminalSignal: Sendable, Equatable {
  public let runID: UUID
  public let reason: AudioCaptureTerminalReason
  public let acousticSummary: AudioCaptureAcousticSummary

  public init(
    runID: UUID,
    reason: AudioCaptureTerminalReason,
    acousticSummary: AudioCaptureAcousticSummary = .empty
  ) {
    self.runID = runID
    self.reason = reason
    self.acousticSummary = acousticSummary
  }
}

/// A single-consumer, run-scoped endpoint capability shared by one capture
/// runtime and its workflow owner. The first terminal signal wins.
public final class AudioCaptureEndpointControl: @unchecked Sendable, Equatable {
  public let runID: UUID
  public let policy: SpeechEndpointPolicy

  private let lock = NSLock()
  private let stream: AsyncStream<AudioCaptureTerminalSignal>
  private let continuation: AsyncStream<AudioCaptureTerminalSignal>.Continuation
  private var isConsumerClaimed = false
  private var isFinished = false
  private var acousticAccumulator = AcousticAccumulator()

  public init(runID: UUID, policy: SpeechEndpointPolicy) {
    self.runID = runID
    self.policy = policy
    let channel = AsyncStream<AudioCaptureTerminalSignal>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    stream = channel.stream
    continuation = channel.continuation
  }

  /// Claims the only supported consumer. Returning `nil` means another
  /// owner already claimed this run's terminal stream.
  public func claimStream() -> AsyncStream<AudioCaptureTerminalSignal>? {
    lock.withLock {
      guard !isConsumerClaimed else { return nil }
      isConsumerClaimed = true
      return stream
    }
  }

  /// Adds one content-free relative-energy interval to this run's summary.
  ///
  /// Invalid intervals and observations arriving after the terminal snapshot
  /// are ignored. Returning `true` means the interval was included.
  @discardableResult
  public func observeEnergy(
    relativeLevel: Float,
    durationSeconds: Double
  ) -> Bool {
    lock.withLock {
      guard !isFinished else { return false }
      return acousticAccumulator.observe(
        relativeLevel: relativeLevel,
        durationSeconds: durationSeconds,
        isAboveThreshold: relativeLevel >= policy.voiceActivityThreshold
      )
    }
  }

  /// Adds the native detector's speech decision and the independently measured
  /// relative input level without altering either observation to make them
  /// appear correlated. The detector was configured from this control's policy.
  @discardableResult
  public func observeVoiceActivity(
    isSpeech: Bool,
    relativeLevel: Float,
    durationSeconds: Double
  ) -> Bool {
    lock.withLock {
      guard !isFinished else { return false }
      return acousticAccumulator.observe(
        relativeLevel: relativeLevel,
        durationSeconds: durationSeconds,
        isAboveThreshold: isSpeech
      )
    }
  }

  @discardableResult
  public func send(_ reason: AudioCaptureTerminalReason) -> Bool {
    let signal = lock.withLock { () -> AudioCaptureTerminalSignal? in
      guard !isFinished else { return nil }
      isFinished = true
      return AudioCaptureTerminalSignal(
        runID: runID,
        reason: reason,
        acousticSummary: acousticAccumulator.snapshot
      )
    }
    guard let signal else { return false }
    let result = continuation.yield(signal)
    continuation.finish()
    switch result {
    case .enqueued:
      return true
    case .dropped, .terminated:
      return false
    @unknown default:
      return false
    }
  }

  public func finish() {
    let shouldFinish = lock.withLock { () -> Bool in
      guard !isFinished else { return false }
      isFinished = true
      return true
    }
    if shouldFinish {
      continuation.finish()
    }
  }

  public static func == (
    lhs: AudioCaptureEndpointControl,
    rhs: AudioCaptureEndpointControl
  ) -> Bool {
    lhs === rhs
  }

  deinit {
    continuation.finish()
  }

  private struct AcousticAccumulator {
    private static let peakBucketWidth: UInt64 = 5

    private var observedSegmentCount: UInt64 = 0
    private var observedDurationMilliseconds: UInt64 = 0
    private var aboveThresholdDurationMilliseconds: UInt64 = 0
    private var peakLevelPercentBucket: UInt64 = 0
    private var consecutiveAboveThresholdDurationMilliseconds: UInt64 = 0
    private var maximumConsecutiveAboveThresholdDurationMilliseconds: UInt64 = 0

    var snapshot: AudioCaptureAcousticSummary {
      AudioCaptureAcousticSummary(
        observedSegmentCount: observedSegmentCount,
        observedDurationMilliseconds: observedDurationMilliseconds,
        aboveThresholdDurationMilliseconds: aboveThresholdDurationMilliseconds,
        peakLevelPercentBucket: peakLevelPercentBucket,
        maximumConsecutiveAboveThresholdDurationMilliseconds:
          maximumConsecutiveAboveThresholdDurationMilliseconds
      )
    }

    mutating func observe(
      relativeLevel: Float,
      durationSeconds: Double,
      isAboveThreshold: Bool
    ) -> Bool {
      guard relativeLevel.isFinite,
        durationSeconds.isFinite,
        durationSeconds > 0
      else {
        return false
      }

      let durationMilliseconds = Self.milliseconds(for: durationSeconds)
      observedSegmentCount = Self.addingClamped(observedSegmentCount, 1)
      observedDurationMilliseconds = Self.addingClamped(
        observedDurationMilliseconds,
        durationMilliseconds
      )
      peakLevelPercentBucket = max(
        peakLevelPercentBucket,
        Self.percentBucket(for: relativeLevel)
      )

      if isAboveThreshold {
        aboveThresholdDurationMilliseconds = Self.addingClamped(
          aboveThresholdDurationMilliseconds,
          durationMilliseconds
        )
        consecutiveAboveThresholdDurationMilliseconds = Self.addingClamped(
          consecutiveAboveThresholdDurationMilliseconds,
          durationMilliseconds
        )
        maximumConsecutiveAboveThresholdDurationMilliseconds = max(
          maximumConsecutiveAboveThresholdDurationMilliseconds,
          consecutiveAboveThresholdDurationMilliseconds
        )
      } else {
        consecutiveAboveThresholdDurationMilliseconds = 0
      }
      return true
    }

    private static func milliseconds(for durationSeconds: Double) -> UInt64 {
      let scaled = durationSeconds * 1_000
      guard scaled < Double(UInt64.max) else { return UInt64.max }
      return max(1, UInt64(scaled.rounded()))
    }

    private static func percentBucket(for relativeLevel: Float) -> UInt64 {
      let clampedLevel = min(max(relativeLevel, 0), 1)
      // Keep the multiplication in Float. Converting a decimal Float such
      // as 0.3 to Double before scaling preserves its representation error
      // and can make `ceil` incorrectly promote an exact 5% boundary.
      let bucketIndex = UInt64((clampedLevel * 20).rounded(.up))
      let bucket = bucketIndex * peakBucketWidth
      return min(bucket, 100)
    }

    private static func addingClamped(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
      let (sum, overflowed) = lhs.addingReportingOverflow(rhs)
      return overflowed ? UInt64.max : sum
    }
  }
}
