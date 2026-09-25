@preconcurrency import AVFoundation
import Foundation
import RillCore

struct LocalSpeechAudioStream: Sendable {
  let stream: AsyncThrowingStream<[Float], Error>
  let continuation: AsyncThrowingStream<[Float], Error>.Continuation
  let terminalState: AppleVoiceProcessingPCMStreamTerminalState
}

protocol LocalSpeechAudioCaptureSource: AnyObject, Sendable {
  var meterRMS: [Float] { get }

  func prepareStoppedFrontend() throws
  func setPendingHandoffID(_ id: UUID?)
  func startStreaming() -> LocalSpeechAudioStream
  func stop()
  func shutdown()
}

extension LocalSpeechAudioCaptureSource {
  func prepareStoppedFrontend() throws {}
  func setPendingHandoffID(_: UUID?) {}
  func shutdown() {}
}

struct LocalSpeechVoiceActivityObservation: Sendable, Equatable {
  let isSpeech: Bool
  let durationSeconds: Double
  let normalizedRMS: Float
}

protocol LocalSpeechVoiceActivityDetector: AnyObject, Sendable {
  func accept(samples: [Float]) throws -> [LocalSpeechVoiceActivityObservation]
  func reset()
}

/// Keeps the low-latency decoder useful without letting transient empty or
/// unrelated hypotheses make the subtitle visibly disappear or jump on every
/// audio callback. The final offline recognizer remains authoritative.
struct LocalSpeechStreamingPreviewProjection: Sendable, Equatable {
  private(set) var text = ""
  private var previousRawCandidate = ""
  private var previousProjectedCandidate = ""
  private var pendingReplacement = ""
  private var pendingReplacementObservations = 0

  mutating func observe(_ rawCandidate: String) {
    let trimmedCandidate = rawCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedCandidate.isEmpty else { return }
    let candidate = Self.projectingCumulativeCandidate(
      trimmedCandidate,
      afterRaw: previousRawCandidate,
      projectedPrevious: previousProjectedCandidate,
      displayedText: text
    )
    previousRawCandidate = trimmedCandidate
    previousProjectedCandidate = candidate
    guard !text.isEmpty else {
      accept(candidate)
      return
    }
    guard candidate != text else {
      clearPendingReplacement()
      return
    }
    if Self.isCompatibleProgression(from: text, to: candidate) {
      accept(candidate)
      return
    }

    if !pendingReplacement.isEmpty,
      Self.isCompatibleProgression(from: pendingReplacement, to: candidate)
    {
      pendingReplacement = candidate
      pendingReplacementObservations += 1
    } else {
      pendingReplacement = candidate
      pendingReplacementObservations = 1
    }
    if pendingReplacementObservations >= 2 {
      accept(candidate)
    }
  }

  mutating func reset() {
    text = ""
    previousRawCandidate = ""
    previousProjectedCandidate = ""
    clearPendingReplacement()
  }

  private mutating func accept(_ candidate: String) {
    text = candidate
    clearPendingReplacement()
  }

  private mutating func clearPendingReplacement() {
    pendingReplacement = ""
    pendingReplacementObservations = 0
  }

  private static func isCompatibleProgression(
    from current: String,
    to candidate: String
  ) -> Bool {
    if candidate.hasPrefix(current) { return true }

    let currentCharacters = Array(current)
    let candidateCharacters = Array(candidate)
    let shorterCount = min(currentCharacters.count, candidateCharacters.count)
    guard shorterCount >= 2 else { return false }
    let commonPrefixCount = zip(currentCharacters, candidateCharacters)
      .prefix { $0.0 == $0.1 }
      .count
    return commonPrefixCount >= 2
      && Double(commonPrefixCount) / Double(shorterCount) >= 0.65
  }

  /// Some transducer hypotheses repeat the stable tail when extending the
  /// transcript, for example `今天天气` -> `今天天气天气怎么样`. Remove only the
  /// overlap that crosses the already-present/new-extension boundary. This is
  /// deliberately more conservative than generic repeated-word cleanup: a
  /// complete candidate such as `谢谢谢谢` remains untouched, and a one-character
  /// overlap is only collapsed when it would otherwise create three identical
  /// characters in a row.
  private static func removingDuplicatedExtensionOverlap(
    from candidate: String,
    after current: String
  ) -> String {
    guard !current.isEmpty, candidate.hasPrefix(current) else { return candidate }

    let currentCharacters = Array(current)
    let candidateCharacters = Array(candidate)
    let extensionCharacters = Array(candidateCharacters.dropFirst(currentCharacters.count))
    guard extensionCharacters.count >= 2 else { return candidate }

    // A complete repeated utterance is ambiguous and must remain verbatim.
    // The decoder-boundary bug always has additional novel text after the
    // duplicated tail, while `谢谢` -> `谢谢谢谢` does not.
    if extensionCharacters == currentCharacters { return candidate }

    let maximumOverlap = min(currentCharacters.count, extensionCharacters.count - 1)
    guard maximumOverlap > 0 else { return candidate }

    for overlapCount in stride(from: maximumOverlap, through: 1, by: -1) {
      let isSafeSingleCharacterOverlap =
        overlapCount > 1
        || (currentCharacters.count >= 2
          && currentCharacters[currentCharacters.count - 1]
            == currentCharacters[currentCharacters.count - 2])
      guard isSafeSingleCharacterOverlap else { continue }
      guard currentCharacters.suffix(overlapCount) == extensionCharacters.prefix(overlapCount)
      else { continue }

      return String(
        currentCharacters + extensionCharacters.dropFirst(overlapCount)
      )
    }
    return candidate
  }

  /// Online transducers return the complete hypothesis after every chunk. A
  /// duplicated tail removed from the display can still remain in that raw
  /// hypothesis and otherwise reappear on the next extension. Track both
  /// coordinates so every cumulative extension is applied to the previously
  /// projected form instead of comparing raw text with already-repaired text.
  private static func projectingCumulativeCandidate(
    _ candidate: String,
    afterRaw previousRawCandidate: String,
    projectedPrevious previousProjectedCandidate: String,
    displayedText: String
  ) -> String {
    guard !previousRawCandidate.isEmpty,
      candidate.hasPrefix(previousRawCandidate)
    else {
      return removingDuplicatedExtensionOverlap(
        from: candidate,
        after: displayedText
      )
    }
    guard candidate != previousRawCandidate else {
      return previousProjectedCandidate
    }

    let previousRawCharacters = Array(previousRawCandidate)
    let extensionCharacters = Array(candidate.dropFirst(previousRawCharacters.count))
    guard extensionCharacters.count >= 2 else {
      return previousProjectedCandidate + String(extensionCharacters)
    }
    if extensionCharacters == previousRawCharacters {
      return previousProjectedCandidate + String(extensionCharacters)
    }

    let maximumOverlap = min(previousRawCharacters.count, extensionCharacters.count - 1)
    for overlapCount in stride(from: maximumOverlap, through: 1, by: -1) {
      let isSafeSingleCharacterOverlap =
        overlapCount > 1
        || (previousRawCharacters.count >= 2
          && previousRawCharacters[previousRawCharacters.count - 1]
            == previousRawCharacters[previousRawCharacters.count - 2])
      guard isSafeSingleCharacterOverlap else { continue }
      guard
        previousRawCharacters.suffix(overlapCount)
          == extensionCharacters.prefix(overlapCount)
      else { continue }
      return previousProjectedCandidate
        + String(extensionCharacters.dropFirst(overlapCount))
    }
    return previousProjectedCandidate + String(extensionCharacters)
  }
}

typealias LocalSpeechVoiceActivityDetectorFactory =
  @Sendable (_ voiceActivityThreshold: Float) throws -> any LocalSpeechVoiceActivityDetector

final class AppleVoiceProcessingCaptureSource: LocalSpeechAudioCaptureSource,
  @unchecked Sendable
{
  private let processor: AppleVoiceProcessingAudioProcessor

  init(processor: AppleVoiceProcessingAudioProcessor = AppleVoiceProcessingAudioProcessor()) {
    self.processor = processor
  }

  var meterRMS: [Float] {
    processor.meterRMS
  }

  func prepareStoppedFrontend() throws {
    try processor.prepareRecordingFrontend(inputDeviceID: nil)
  }

  func startStreaming() -> LocalSpeechAudioStream {
    let terminalState = AppleVoiceProcessingPCMStreamTerminalState()
    let (stream, continuation) = processor.startStreamingRecordingLive(
      inputDeviceID: nil,
      terminalState: terminalState
    )
    return LocalSpeechAudioStream(
      stream: stream,
      continuation: continuation,
      terminalState: terminalState
    )
  }

  func stop() {
    processor.stopRecording()
  }

  func shutdown() {
    processor.shutdown()
  }
}

actor LocalSpeechVoiceCaptureRuntime {
  typealias PermissionRequester = @Sendable () async -> Bool
  typealias CaptureSourceFactory = @Sendable () -> any LocalSpeechAudioCaptureSource
  typealias ReadinessSleep = @Sendable (Duration) async throws -> Void
  typealias PCMInactivitySleep = @Sendable (Duration) async throws -> Void
  typealias StreamingPreviewSessionFactory =
    @Sendable (_ request: AudioCaptureRequest) async ->
      (any LocalSpeechStreamingPreviewSession)?

  private struct PreparingCapture: Sendable {
    let request: AudioCaptureRequest
    let generation: UInt64
  }

  private struct DetachedResources: Sendable {
    let request: AudioCaptureRequest
    let source: any LocalSpeechAudioCaptureSource
    let continuation: AsyncThrowingStream<[Float], Error>.Continuation
    let streamTask: Task<Void, Never>
    let readinessGate: LocalSpeechCaptureReadinessGate
    let recordingWriter: any LocalSpeechRecordingWriting
  }

  private let permissionRequester: PermissionRequester
  private let sourceFactory: CaptureSourceFactory
  private let recordingWriterFactory: LocalSpeechRecordingWriterFactory
  private let voiceActivityDetectorFactory: LocalSpeechVoiceActivityDetectorFactory
  private let streamingPreviewSessionFactory: StreamingPreviewSessionFactory
  private let liveUpdateHandler: @Sendable (LiveSubtitleSnapshot) async -> Void
  private let cleanupOwner: ManagedTemporaryAudioCleanupOwner
  private let startupTimeout: Duration
  private let readinessSleep: ReadinessSleep
  private let pcmInactivityTimeout: Duration
  private let pcmInactivitySleep: PCMInactivitySleep
  private let unexpectedTerminationHandler: @Sendable () async -> Void
  private let wakeWordSpeechStartedHandler: @Sendable () -> Void
  private let readinessCommitHook: (@Sendable () async -> Void)?
  private let startupTerminationRecordedHook: (@Sendable () async -> Void)?

  private var preparingCapture: PreparingCapture?
  private var cancelledPreparingGenerations: Set<UInt64> = []
  private var activeRequest: AudioCaptureRequest?
  private var activeSource: (any LocalSpeechAudioCaptureSource)?
  private var activeContinuation: AsyncThrowingStream<[Float], Error>.Continuation?
  private var activeStreamTask: Task<Void, Never>?
  private var activeReadinessGate: LocalSpeechCaptureReadinessGate?
  private var activeStreamTerminalState: AppleVoiceProcessingPCMStreamTerminalState?
  private var activeRecordingWriter: (any LocalSpeechRecordingWriting)?
  private var activePCMInactivityTask: Task<Void, Never>?
  private var captureGeneration: UInt64 = 0
  private var pcmActivityRevision: UInt64 = 0
  private var recordingGeneration: UInt64?
  private var finishingGeneration: UInt64?
  private var pendingStartupTermination: LocalSpeechCaptureReadinessGate.Failure?
  private var endpointDetector: SpeechEndpointDetector?
  private var voiceActivityDetector: (any LocalSpeechVoiceActivityDetector)?
  private var streamingPreviewStartupTask: Task<Void, Never>?
  private var streamingPreviewSession: (any LocalSpeechStreamingPreviewSession)?
  private var pendingStreamingPreviewSamples: [Float] = []
  private var captureStartedAt: ContinuousClock.Instant?
  private var firstPreviewObservedMillis: String?
  private var stablePreviewObservedMillis: String?
  private var streamingPreviewSampleCount = 0
  private var drainedTailSampleCount = 0
  private var streamingPreviewProjection = LocalSpeechStreamingPreviewProjection()
  private var recordingStartedAt: Date?
  private var recordingDurationLimitRemoved = false
  private var inputReadinessDetector = LocalSpeechInputReadinessDetector()
  private var wakeWordPreRollSamples: [Float] = []
  private var wakeWordCommandStarted = false

  private static let wakeWordPreRollFrameCount =
    Int(Double(SharedVoiceInputFrame.sampleRate) * 0.2)
  private static let streamingPreviewPreRollFrameCount =
    Int(Double(SharedVoiceInputFrame.sampleRate) * 3)

  init(
    permissionRequester: @escaping PermissionRequester =
      LocalSpeechVoiceCaptureRuntime.requestMicrophonePermission,
    sourceFactory: @escaping CaptureSourceFactory = {
      AppleVoiceProcessingCaptureSource()
    },
    recordingWriterFactory: @escaping LocalSpeechRecordingWriterFactory = { fileURL, frameLimit in
      try LocalSpeechIncrementalWaveWriter(
        fileURL: fileURL,
        maximumFrameCount: frameLimit
      )
    },
    voiceActivityDetectorFactory: @escaping LocalSpeechVoiceActivityDetectorFactory = { _ in
      throw RealtimeAudioCaptureService.CaptureError.voiceActivityDetectionUnavailable
    },
    streamingPreviewSessionFactory: @escaping StreamingPreviewSessionFactory = { _ in nil },
    liveUpdateHandler: @escaping @Sendable (LiveSubtitleSnapshot) async -> Void = { _ in },
    cleanupOwner: ManagedTemporaryAudioCleanupOwner = ManagedTemporaryAudioCleanupOwner(),
    startupTimeout: Duration = .seconds(3),
    readinessSleep: @escaping ReadinessSleep = { try await Task.sleep(for: $0) },
    pcmInactivityTimeout: Duration = .seconds(2),
    pcmInactivitySleep: @escaping PCMInactivitySleep = { try await Task.sleep(for: $0) },
    unexpectedTerminationHandler: @escaping @Sendable () async -> Void = {},
    wakeWordSpeechStartedHandler: @escaping @Sendable () -> Void = {},
    readinessCommitHook: (@Sendable () async -> Void)? = nil,
    startupTerminationRecordedHook: (@Sendable () async -> Void)? = nil
  ) {
    self.permissionRequester = permissionRequester
    self.sourceFactory = sourceFactory
    self.recordingWriterFactory = recordingWriterFactory
    self.voiceActivityDetectorFactory = voiceActivityDetectorFactory
    self.streamingPreviewSessionFactory = streamingPreviewSessionFactory
    self.liveUpdateHandler = liveUpdateHandler
    self.cleanupOwner = cleanupOwner
    self.startupTimeout = startupTimeout
    self.readinessSleep = readinessSleep
    precondition(pcmInactivityTimeout > .zero)
    self.pcmInactivityTimeout = pcmInactivityTimeout
    self.pcmInactivitySleep = pcmInactivitySleep
    self.unexpectedTerminationHandler = unexpectedTerminationHandler
    self.wakeWordSpeechStartedHandler = wakeWordSpeechStartedHandler
    self.readinessCommitHook = readinessCommitHook
    self.startupTerminationRecordedHook = startupTerminationRecordedHook
  }

  func startCapture(request: AudioCaptureRequest) async throws {
    guard activeRequest == nil, preparingCapture == nil else {
      throw RealtimeAudioCaptureService.CaptureError.alreadyCapturing
    }
    captureGeneration &+= 1
    let generation = captureGeneration
    preparingCapture = PreparingCapture(request: request, generation: generation)
    defer {
      if preparingCapture?.generation == generation {
        preparingCapture = nil
      }
      cancelledPreparingGenerations.remove(generation)
    }
    try throwIfPreparationCancelled(request: request, generation: generation)

    let permissionGranted = await permissionRequester()
    try throwIfPreparationCancelled(request: request, generation: generation)
    guard permissionGranted else {
      throw RealtimeAudioCaptureService.CaptureError.microphonePermissionDenied
    }

    let newVoiceActivityDetector: (any LocalSpeechVoiceActivityDetector)?
    if let endpointControl = request.endpointControl {
      do {
        let detector = try voiceActivityDetectorFactory(
          endpointControl.policy.voiceActivityThreshold
        )
        detector.reset()
        newVoiceActivityDetector = detector
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as RealtimeAudioCaptureService.CaptureError
        where error == .voiceActivityDetectionUnavailable
      {
        // The product runtime keeps Silero in the worker. Its streaming
        // session is attached after the microphone starts so model/process
        // setup never extends the Fn critical path.
        newVoiceActivityDetector = nil
      } catch {
        throw RealtimeAudioCaptureService.CaptureError.voiceActivityDetectionUnavailable
      }
    } else {
      newVoiceActivityDetector = nil
    }
    try throwIfPreparationCancelled(request: request, generation: generation)
    try throwIfPreparationCancelled(request: request, generation: generation)
    let outputURL = Self.makeTemporaryRecordingURL(for: request.runID)
    let recordingWriter: any LocalSpeechRecordingWriting
    do {
      recordingWriter = try recordingWriterFactory(
        outputURL,
        maximumRecordingFrameCount(for: request)
      )
    } catch {
      await removeServiceOwnedFile(outputURL, runID: request.runID)
      throw RealtimeAudioCaptureService.CaptureError.microphoneStartFailed
    }
    do {
      try throwIfPreparationCancelled(request: request, generation: generation)
    } catch {
      recordingWriter.closeForDiscard()
      await removeServiceOwnedFile(outputURL, runID: request.runID)
      throw error
    }
    let source = sourceFactory()
    source.setPendingHandoffID(
      request.triggerEvent?.metadata[SharedVoiceInputMetadata.handoffID]
        .flatMap(UUID.init(uuidString:))
    )
    captureStartedAt = .now
    let audioStream = source.startStreaming()
    let readinessGate = LocalSpeechCaptureReadinessGate()

    preparingCapture = nil
    activeRequest = request
    activeSource = source
    activeContinuation = audioStream.continuation
    activeReadinessGate = readinessGate
    activeStreamTerminalState = audioStream.terminalState
    activeRecordingWriter = recordingWriter
    cancelPCMInactivityWatchdog()
    pcmActivityRevision = 0
    recordingGeneration = nil
    finishingGeneration = nil
    streamingPreviewSampleCount = 0
    firstPreviewObservedMillis = nil
    stablePreviewObservedMillis = nil
    drainedTailSampleCount = 0
    pendingStartupTermination = nil
    endpointDetector = request.endpointControl.map { SpeechEndpointDetector(policy: $0.policy) }
    voiceActivityDetector = newVoiceActivityDetector
    streamingPreviewStartupTask = nil
    streamingPreviewSession = nil
    pendingStreamingPreviewSamples.removeAll(keepingCapacity: true)
    streamingPreviewProjection.reset()
    recordingStartedAt = nil
    recordingDurationLimitRemoved = false
    inputReadinessDetector = LocalSpeechInputReadinessDetector()
    wakeWordPreRollSamples.removeAll(keepingCapacity: true)
    wakeWordCommandStarted = request.triggerEvent?.binding != .wakeWord

    let streamTask = Task { [weak self] in
      do {
        for try await buffer in audioStream.stream {
          guard !Task.isCancelled else { break }
          guard audioStream.terminalState.terminalFailure == nil else {
            await self?.streamEnded(generation: generation, failed: true)
            return
          }
          await self?.receiveBuffer(
            buffer,
            generation: generation,
            terminalState: audioStream.terminalState
          )
          guard audioStream.terminalState.terminalFailure == nil else {
            await self?.streamEnded(generation: generation, failed: true)
            return
          }
        }
        guard !audioStream.terminalState.hasClaimedSuccessfulFinish else { return }
        await self?.streamEnded(generation: generation, failed: false)
      } catch is CancellationError {
        guard !audioStream.terminalState.hasClaimedSuccessfulFinish else { return }
        await self?.streamEnded(generation: generation, failed: false)
      } catch {
        guard !audioStream.terminalState.hasClaimedSuccessfulFinish else { return }
        await self?.streamEnded(generation: generation, failed: true)
      }
    }
    activeStreamTask = streamTask
    startStreamingPreview(request: request, generation: generation)

    do {
      try await readinessGate.wait(timeout: startupTimeout, sleep: readinessSleep)
      if let readinessCommitHook {
        await readinessCommitHook()
      }
      try throwIfCaptureCancelled(request: request, generation: generation)
      guard activeRequest?.runID == request.runID,
        captureGeneration == generation,
        activeStreamTask != nil
      else {
        throw CancellationError()
      }
      if let pendingStartupTermination {
        throw pendingStartupTermination
      }
      activeReadinessGate = nil
      recordingGeneration = generation
      recordingStartedAt = Date()
      startPCMInactivityWatchdog(generation: generation)
      await publish(
        phase: .recording,
        request: request,
        hypothesisText: streamingPreviewProjection.text,
        levelMeter: Self.levelMeter(from: source.meterRMS)
      )
    } catch is CancellationError {
      await abandonCapture(request: request, generation: generation, publishHidden: true)
      throw CancellationError()
    } catch let failure as LocalSpeechCaptureReadinessGate.Failure {
      await abandonCapture(request: request, generation: generation, publishHidden: true)
      switch failure {
      case .streamEnded, .streamFailed:
        throw RealtimeAudioCaptureService.CaptureError.microphoneStartFailed
      case .timedOut:
        throw RealtimeAudioCaptureService.CaptureError.microphoneStartTimedOut
      }
    } catch {
      await abandonCapture(request: request, generation: generation, publishHidden: true)
      throw error
    }
  }

  func finishCaptureDeferred(for request: AudioCaptureRequest) async throws
    -> DeferredCapturedAudio
  {
    guard activeRequest?.runID == request.runID,
      let terminalState = activeStreamTerminalState,
      let source = activeSource,
      let continuation = activeContinuation,
      let streamTask = activeStreamTask
    else {
      throw RealtimeAudioCaptureService.CaptureError.notCapturing
    }
    let terminalFailure = terminalState.claimSuccessfulFinish()
    if let terminalFailure {
      guard let resources = detach(request: request) else {
        throw RealtimeAudioCaptureService.CaptureError.notCapturing
      }
      await stopAbnormally(resources)
      await discardRecording(resources.recordingWriter, for: resources.request)
      // The owning service arbitrates user-visible failure state and endpoint
      // delivery against an autonomous termination callback.
      throw terminalFailure
    }
    cancelPCMInactivityWatchdog()

    // A successful terminal claim seals the producer. Keep the active
    // generation and writer installed until every chunk already accepted by
    // the bounded stream has been consumed and written.
    finishingGeneration = captureGeneration
    var timing: [String: String] = [:]
    let stopStart = ContinuousClock.now
    source.stop()
    timing["captureStopMillis"] = DiagnosticTiming.milliseconds(since: stopStart)
    let drainStart = ContinuousClock.now
    continuation.finish()
    await streamTask.value
    timing["captureDrainMillis"] = DiagnosticTiming.milliseconds(since: drainStart)

    // Offline recognition owns final text. Finish still owns worker retirement
    // (including its decode-drain guard); discard only the unused preview text.
    let previewStart = ContinuousClock.now
    streamingPreviewStartupTask?.cancel()
    streamingPreviewStartupTask = nil
    pendingStreamingPreviewSamples.removeAll(keepingCapacity: false)
    _ = try? await streamingPreviewSession?.finish()
    timing["capturePreviewRetireMillis"] = DiagnosticTiming.milliseconds(since: previewStart)
    timing["firstPreviewObservedMillis"] = firstPreviewObservedMillis
    timing["stablePreviewObservedMillis"] = stablePreviewObservedMillis
    timing["captureTailSampleCount"] = String(drainedTailSampleCount)
    timing["previewDeliveredSampleCount"] = String(streamingPreviewSampleCount)
    timing["previewKeytermStatus"] = (request.options.hints.keyterms.isEmpty
      ? RecognitionHintApplicationStatus.notRequested
      : streamingPreviewSession?.keytermStatus ?? .unavailable).rawValue
    timing["previewRequestedKeytermCount"] = String(request.options.hints.keyterms.count)

    guard let resources = detach(request: request) else {
      throw RealtimeAudioCaptureService.CaptureError.notCapturing
    }
    await resources.readinessGate.cancel()

    let finalizeStart = ContinuousClock.now
    let artifact: LocalSpeechRecordingArtifact
    do {
      artifact = try resources.recordingWriter.finalize()
    } catch {
      await discardRecording(resources.recordingWriter, for: resources.request)
      throw error
    }
    timing["captureFinalizeMillis"] = DiagnosticTiming.milliseconds(since: finalizeStart)
    var metadata = request.metadata.merging(timing) { _, measured in measured }
    metadata["runID"] = request.runID.uuidString
    metadata["live.provider"] = "local-speech.streaming-preview"
    let capturedAudio: CapturedAudio
    do {
      capturedAudio = try CapturedAudio(
        durationSeconds: Double(artifact.frameCount) / 16_000,
        format: AudioFormat(
          sampleRateHz: 16_000,
          channelCount: 1,
          encoding: .float32
        ),
        fileURL: artifact.fileURL,
        fileOwnership: .managedTemporary,
        metadata: metadata
      )
    } catch {
      await removeServiceOwnedFile(artifact.fileURL, runID: request.runID)
      throw error
    }
    await publish(phase: .hidden, request: request)
    return DeferredCapturedAudio(task: Task { capturedAudio })
  }

  func cancelCapture(for request: AudioCaptureRequest) async {
    if let preparingCapture, preparingCapture.request.runID == request.runID {
      cancelledPreparingGenerations.insert(preparingCapture.generation)
      self.preparingCapture = nil
      await publish(phase: .hidden, request: request)
      return
    }
    guard let resources = detach(request: request) else {
      await publish(phase: .hidden, request: request)
      return
    }
    await stopAbnormally(resources)
    await discardRecording(resources.recordingWriter, for: resources.request)
    await publish(phase: .hidden, request: request)
  }

  func removeMaximumDurationLimit(runID: UUID) async -> Bool {
    guard activeRequest?.runID == runID,
      activeRequest?.canRemoveMaxDurationLimit == true,
      !recordingDurationLimitRemoved,
      recordingGeneration != nil,
      let recordingWriter = activeRecordingWriter
    else {
      return false
    }
    recordingWriter.removeFrameLimit()
    recordingDurationLimitRemoved = true
    if let request = activeRequest {
      await publish(
        phase: .recording,
        request: request,
        hypothesisText: streamingPreviewProjection.text,
        levelMeter: Self.levelMeter(from: activeSource?.meterRMS ?? [])
      )
    }
    return true
  }

  private func receiveBuffer(
    _ buffer: [Float],
    generation: UInt64,
    terminalState: AppleVoiceProcessingPCMStreamTerminalState
  ) async {
    guard !buffer.isEmpty,
      activeRequest != nil,
      captureGeneration == generation,
      activeStreamTerminalState === terminalState,
      let source = activeSource,
      let recordingWriter = activeRecordingWriter
    else {
      return
    }
    guard terminalState.terminalFailure == nil else {
      await failActiveStream(generation: generation)
      return
    }
    pcmActivityRevision &+= 1

    if finishingGeneration == generation {
      if activeRequest?.triggerEvent?.binding == .wakeWord, !wakeWordCommandStarted {
        return
      }
      do {
        try recordingWriter.append(buffer)
        drainedTailSampleCount += buffer.count
        acceptPreviewSamples(buffer)
      } catch {
        await failActiveStream(generation: generation)
      }
      return
    }

    let readiness = inputReadinessDetector.observe(samples: buffer)
    guard readiness != .invalid else {
      await failActiveStream(generation: generation)
      return
    }
    let isWaitingForWakeCommand =
      activeRequest?.triggerEvent?.binding == .wakeWord && !wakeWordCommandStarted
    if isWaitingForWakeCommand {
      wakeWordPreRollSamples.append(contentsOf: buffer)
      if wakeWordPreRollSamples.count > Self.wakeWordPreRollFrameCount {
        wakeWordPreRollSamples.removeFirst(
          wakeWordPreRollSamples.count - Self.wakeWordPreRollFrameCount
        )
      }
    }
    acceptPreviewSamples(buffer)
    let observedSpeech: Bool
    do {
      observedSpeech = try observeEndpointSamples(
        buffer,
        generation: generation,
        terminalState: terminalState
      )
    } catch {
      await failActiveStream(generation: generation)
      return
    }
    let samplesForRecording: [Float]
    if isWaitingForWakeCommand {
      guard observedSpeech else {
        if readiness == .ready {
          await activeReadinessGate?.signalReady()
        }
        return
      }
      wakeWordCommandStarted = true
      samplesForRecording = wakeWordPreRollSamples
      wakeWordPreRollSamples.removeAll(keepingCapacity: true)
      wakeWordSpeechStartedHandler()
    } else {
      samplesForRecording = buffer
    }
    do {
      try recordingWriter.append(samplesForRecording)
    } catch {
      await failActiveStream(generation: generation)
      return
    }
    switch readiness {
    case .waiting:
      break
    case .ready:
      await activeReadinessGate?.signalReady()
    case .invalid:
      break
    }
    if recordingGeneration == generation, let request = activeRequest {
      await publish(
        phase: .recording,
        request: request,
        hypothesisText: streamingPreviewProjection.text,
        levelMeter: Self.levelMeter(from: source.meterRMS)
      )
    }
  }

  private func observeEndpointSamples(
    _ samples: [Float],
    generation: UInt64,
    terminalState: AppleVoiceProcessingPCMStreamTerminalState
  ) throws -> Bool {
    guard recordingGeneration == generation || activeReadinessGate != nil,
      activeStreamTerminalState === terminalState,
      let request = activeRequest,
      let endpointControl = request.endpointControl,
      var detector = endpointDetector,
      streamingPreviewSession?.providesVoiceActivity == true || voiceActivityDetector != nil
    else {
      return false
    }

    var observedSpeech = false
    let activities: [LocalSpeechVoiceActivityObservation]
    if let previewSession = streamingPreviewSession,
      previewSession.providesVoiceActivity
    {
      let normalizedRMS = Self.normalizedRMS(samples)
      activities = previewSession.drainVoiceActivity().map {
        LocalSpeechVoiceActivityObservation(
          isSpeech: $0.isSpeech,
          durationSeconds: $0.durationSeconds,
          normalizedRMS: normalizedRMS
        )
      }
    } else if let voiceActivityDetector {
      activities = try voiceActivityDetector.accept(samples: samples)
    } else {
      activities = []
    }
    for activity in activities {
      guard terminalState.terminalFailure == nil else {
        throw RealtimeAudioCaptureService.CaptureError.microphoneStartFailed
      }
      guard activity.durationSeconds.isFinite,
        activity.durationSeconds > 0,
        activity.normalizedRMS.isFinite
      else {
        throw RealtimeAudioCaptureService.CaptureError.voiceActivityDetectionUnavailable
      }
      let measuredLevel = AppleVoiceProcessingAudioProcessor.endpointRelativeEnergy(
        fromNormalizedRMS: activity.normalizedRMS
      )
      endpointControl.observeVoiceActivity(
        isSpeech: activity.isSpeech,
        relativeLevel: measuredLevel,
        durationSeconds: activity.durationSeconds
      )
      observedSpeech = observedSpeech || activity.isSpeech
      guard
        let outcome = detector.observe(
          isSpeech: activity.isSpeech,
          durationSeconds: activity.durationSeconds
        )
      else {
        continue
      }
      let terminalReason: AudioCaptureTerminalReason
      switch outcome {
      case .initialSilenceTimedOut:
        terminalReason = .initialSilenceTimedOut
      case .speechEnded:
        terminalReason = .speechEnded
      }
      guard
        terminalState.claimNormalEndpoint({
          _ = endpointControl.send(terminalReason)
        })
      else {
        throw RealtimeAudioCaptureService.CaptureError.microphoneStartFailed
      }
      break
    }
    endpointDetector = detector
    return observedSpeech
  }

  private static func normalizedRMS(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let squareSum = samples.reduce(Float.zero) { partial, sample in
      let bounded = min(max(sample, -1), 1)
      return partial + bounded * bounded
    }
    return sqrt(squareSum / Float(samples.count))
  }

  private func failActiveStream(generation: UInt64) async {
    await streamEnded(generation: generation, failed: true)
  }

  private func startPCMInactivityWatchdog(generation: UInt64) {
    cancelPCMInactivityWatchdog()
    let timeout = pcmInactivityTimeout
    let sleep = pcmInactivitySleep
    let initialRevision = pcmActivityRevision
    activePCMInactivityTask = Task { [weak self] in
      var observedRevision = initialRevision
      while !Task.isCancelled {
        do {
          try await sleep(timeout)
          try Task.checkCancellation()
        } catch {
          return
        }
        guard let self,
          let currentRevision = await self.handlePCMInactivityCheck(
            generation: generation,
            observedRevision: observedRevision
          )
        else {
          return
        }
        observedRevision = currentRevision
      }
    }
  }

  private func handlePCMInactivityCheck(
    generation: UInt64,
    observedRevision: UInt64
  ) async -> UInt64? {
    guard captureGeneration == generation,
      recordingGeneration == generation,
      finishingGeneration != generation,
      let terminalState = activeStreamTerminalState
    else {
      return nil
    }
    let currentRevision = pcmActivityRevision
    guard currentRevision == observedRevision else { return currentRevision }
    guard
      terminalState.claimProducerFailure(.inputBecameUnresponsive) != nil
    else {
      return nil
    }
    await streamEnded(generation: generation, failed: true)
    return nil
  }

  private func cancelPCMInactivityWatchdog() {
    let task = activePCMInactivityTask
    activePCMInactivityTask = nil
    task?.cancel()
  }

  private func streamEnded(generation: UInt64, failed: Bool) async {
    guard captureGeneration == generation, let request = activeRequest else { return }
    if let readinessGate = activeReadinessGate {
      let didRecordTermination = pendingStartupTermination == nil
      if didRecordTermination {
        pendingStartupTermination = failed ? .streamFailed : .streamEnded
      }
      if failed {
        await readinessGate.signalStreamFailed()
      } else {
        await readinessGate.signalStreamEnded()
      }
      if didRecordTermination, let startupTerminationRecordedHook {
        await startupTerminationRecordedHook()
      }
      return
    }

    guard let resources = detach(request: request) else { return }
    resources.source.stop()
    resources.continuation.finish()
    resources.streamTask.cancel()
    resources.recordingWriter.closeForDiscard()
    await removeServiceOwnedFile(
      resources.recordingWriter.fileURL,
      runID: resources.request.runID
    )
    // Reservation ownership, lifetime revocation, endpoint delivery, and the
    // failure snapshot all belong to the service callback. A concurrent
    // manual finish and this callback therefore compete on one service-owned
    // reservation instead of publishing independently.
    await unexpectedTerminationHandler()
  }

  private func detach(request: AudioCaptureRequest) -> DetachedResources? {
    guard activeRequest?.runID == request.runID,
      let source = activeSource,
      let continuation = activeContinuation,
      let streamTask = activeStreamTask,
      let recordingWriter = activeRecordingWriter
    else {
      return nil
    }
    let readinessGate = activeReadinessGate ?? LocalSpeechCaptureReadinessGate()
    captureGeneration &+= 1
    activeRequest = nil
    activeSource = nil
    activeContinuation = nil
    activeStreamTask = nil
    activeReadinessGate = nil
    activeStreamTerminalState = nil
    activeRecordingWriter = nil
    cancelPCMInactivityWatchdog()
    recordingGeneration = nil
    finishingGeneration = nil
    streamingPreviewSampleCount = 0
    firstPreviewObservedMillis = nil
    stablePreviewObservedMillis = nil
    drainedTailSampleCount = 0
    pendingStartupTermination = nil
    pcmActivityRevision = 0
    endpointDetector = nil
    voiceActivityDetector?.reset()
    voiceActivityDetector = nil
    streamingPreviewStartupTask?.cancel()
    streamingPreviewStartupTask = nil
    try? streamingPreviewSession?.cancel()
    streamingPreviewSession = nil
    pendingStreamingPreviewSamples.removeAll(keepingCapacity: false)
    streamingPreviewProjection.reset()
    recordingStartedAt = nil
    recordingDurationLimitRemoved = false
    inputReadinessDetector = LocalSpeechInputReadinessDetector()
    wakeWordPreRollSamples.removeAll(keepingCapacity: true)
    wakeWordCommandStarted = false
    return DetachedResources(
      request: request,
      source: source,
      continuation: continuation,
      streamTask: streamTask,
      readinessGate: readinessGate,
      recordingWriter: recordingWriter
    )
  }

  private func startStreamingPreview(
    request: AudioCaptureRequest,
    generation: UInt64
  ) {
    let factory = streamingPreviewSessionFactory
    streamingPreviewStartupTask = Task { [weak self] in
      let session = await factory(request)
      guard !Task.isCancelled else {
        try? session?.cancel()
        return
      }
      await self?.attachStreamingPreviewSession(
        session,
        request: request,
        generation: generation
      )
    }
  }

  private func attachStreamingPreviewSession(
    _ session: (any LocalSpeechStreamingPreviewSession)?,
    request: AudioCaptureRequest,
    generation: UInt64
  ) async {
    guard captureGeneration == generation,
      activeRequest?.runID == request.runID,
      finishingGeneration != generation,
      streamingPreviewStartupTask != nil
    else {
      try? session?.cancel()
      return
    }
    streamingPreviewStartupTask = nil
    guard let session else {
      pendingStreamingPreviewSamples.removeAll(keepingCapacity: false)
      return
    }

    streamingPreviewSession = session
    let preRoll = pendingStreamingPreviewSamples
    pendingStreamingPreviewSamples.removeAll(keepingCapacity: false)
    guard !preRoll.isEmpty else { return }
    do {
      streamingPreviewProjection.observe(
        try session.accept(samples: preRoll)
      )
      streamingPreviewSampleCount += preRoll.count
      observePreviewTiming(session)
      if recordingGeneration == generation, let activeRequest {
        await publish(
          phase: .recording,
          request: activeRequest,
          hypothesisText: streamingPreviewProjection.text,
          levelMeter: Self.levelMeter(from: activeSource?.meterRMS ?? [])
        )
      }
    } catch {
      try? session.cancel()
      streamingPreviewSession = nil
    }
  }

  private func observePreviewTiming(_ session: any LocalSpeechStreamingPreviewSession) {
    guard let captureStartedAt else { return }
    if firstPreviewObservedMillis == nil, !streamingPreviewProjection.text.isEmpty {
      firstPreviewObservedMillis = DiagnosticTiming.milliseconds(since: captureStartedAt)
    }
    if stablePreviewObservedMillis == nil, session.hasConfirmedText {
      stablePreviewObservedMillis = DiagnosticTiming.milliseconds(since: captureStartedAt)
    }
  }

  private func acceptPreviewSamples(_ samples: [Float]) {
    if let session = streamingPreviewSession {
      do {
        streamingPreviewProjection.observe(try session.accept(samples: samples))
        streamingPreviewSampleCount += samples.count
        observePreviewTiming(session)
      } catch {
        // Preview failure never discards the authoritative WAV recording.
        try? session.cancel()
        streamingPreviewSession = nil
      }
    } else if streamingPreviewStartupTask != nil {
      appendPendingStreamingPreviewSamples(samples)
    }
  }

  private func appendPendingStreamingPreviewSamples(_ samples: [Float]) {
    pendingStreamingPreviewSamples.append(contentsOf: samples)
    let overflow =
      pendingStreamingPreviewSamples.count - Self.streamingPreviewPreRollFrameCount
    if overflow > 0 {
      pendingStreamingPreviewSamples.removeFirst(overflow)
    }
  }

  private func stopAbnormally(_ resources: DetachedResources) async {
    await resources.readinessGate.cancel()
    resources.source.stop()
    resources.continuation.finish()
    resources.streamTask.cancel()
    await resources.streamTask.value
  }

  private func abandonCapture(
    request: AudioCaptureRequest,
    generation: UInt64,
    publishHidden: Bool
  ) async {
    guard captureGeneration == generation, let resources = detach(request: request) else { return }
    await stopAbnormally(resources)
    await discardRecording(resources.recordingWriter, for: resources.request)
    if publishHidden {
      await publish(phase: .hidden, request: request)
    }
  }

  private func discardRecording(
    _ recordingWriter: any LocalSpeechRecordingWriting,
    for request: AudioCaptureRequest
  ) async {
    recordingWriter.closeForDiscard()
    await removeServiceOwnedFile(recordingWriter.fileURL, runID: request.runID)
  }

  private func removeServiceOwnedFile(_ fileURL: URL, runID: UUID) async {
    guard await cleanupOwner.transfer(fileURL: fileURL, runID: runID) else { return }
    await cleanupOwner.drain(runID: runID)
  }

  private func throwIfPreparationCancelled(
    request: AudioCaptureRequest,
    generation: UInt64
  ) throws {
    try Task.checkCancellation()
    guard !cancelledPreparingGenerations.contains(generation),
      preparingCapture?.request.runID == request.runID,
      preparingCapture?.generation == generation,
      captureGeneration == generation,
      Self.hasActiveLifetime(for: request)
    else {
      throw CancellationError()
    }
  }

  private func throwIfCaptureCancelled(
    request: AudioCaptureRequest,
    generation: UInt64
  ) throws {
    try Task.checkCancellation()
    guard activeRequest?.runID == request.runID,
      captureGeneration == generation,
      Self.hasActiveLifetime(for: request)
    else {
      throw CancellationError()
    }
  }

  private static func hasActiveLifetime(for request: AudioCaptureRequest) -> Bool {
    guard let lifetime = request.audioLifetime else { return true }
    return lifetime.runID == request.runID && lifetime.isActive
  }

  private func publish(
    phase: LiveSubtitlePhase,
    request: AudioCaptureRequest,
    hypothesisText: String = "",
    levelMeter: [Float] = []
  ) async {
    await liveUpdateHandler(
      LiveSubtitleSnapshot(
        runID: request.runID,
        workflow: request.workflow.presentation,
        phase: phase,
        hypothesisText: hypothesisText,
        levelMeter: levelMeter,
        providerID: phase == .hidden
          ? nil
          : request.workflow.plan.setup.speechRoute?.recognizerID,
        networkUsage: request.liveSubtitleNetworkUsage,
        livePreviewPlacement: request.workflow.resolvedLivePreviewPlacement,
        recordingStartedAt: phase == .hidden ? nil : recordingStartedAt,
        maximumRecordingDurationSeconds:
          phase == .hidden || recordingDurationLimitRemoved
          ? nil : request.maxDurationSeconds,
        recordingDurationIsUnlimited:
          phase == .hidden ? nil : (request.maxDurationSeconds == nil || recordingDurationLimitRemoved),
        canRemoveRecordingDurationLimit:
          phase == .hidden
          ? nil
          : (request.canRemoveMaxDurationLimit && !recordingDurationLimitRemoved)
      )
    )
  }

  private static func requestMicrophonePermission() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return true
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .audio)
    case .denied, .restricted:
      return false
    @unknown default:
      return false
    }
  }

  private static func makeTemporaryRecordingURL(for runID: UUID) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-local-\(runID.uuidString)")
      .appendingPathExtension("wav")
  }

  private func maximumRecordingFrameCount(for request: AudioCaptureRequest) -> Int? {
    guard let requestedDuration = request.maxDurationSeconds else { return nil }
    guard requestedDuration.isFinite, requestedDuration > 0 else { return 0 }
    let timeoutComponents = startupTimeout.components
    let timeoutSeconds = max(
      Double(timeoutComponents.seconds)
        + Double(timeoutComponents.attoseconds) / 1_000_000_000_000_000_000,
      0
    )
    let startupGrace = min(
      timeoutSeconds + 0.1,
      LocalSpeechIncrementalWaveWriter.maximumStartupGraceSeconds
    )
    let captureDuration = requestedDuration + startupGrace
    let exactFrameCount = captureDuration * LocalSpeechIncrementalWaveWriter.sampleRateHz
    guard exactFrameCount.isFinite, exactFrameCount <= Double(Int.max) else { return 0 }
    return max(Int(exactFrameCount.rounded(.down)), 1)
  }

  private static func levelMeter(from cumulativeRMS: [Float]) -> [Float] {
    cumulativeRMS.suffix(20).map {
      AppleVoiceProcessingAudioProcessor.meterRelativeEnergy(fromNormalizedRMS: $0)
    }
  }

}

struct LocalSpeechInputReadinessDetector: Sendable, Equatable {
  enum Outcome: Sendable, Equatable {
    case waiting
    case ready
    case invalid
  }

  /// One complete 32 ms Silero-sized frame is enough to prove that VPIO is
  /// delivering usable 16 kHz PCM. Speech endpoint confidence is evaluated by
  /// the separate VAD; holding startup for a 300 ms calibration window only
  /// keeps recording feedback in `.preparing` after valid input already exists.
  static let minimumUsableFrameSampleCount = 512
  static let minimumSignalMagnitude: Float = 1e-7

  private var observedSampleCount = 0
  private var hasSignalEvidence = false
  private var isReady = false

  mutating func observe(samples: [Float]) -> Outcome {
    guard !isReady else { return .ready }
    guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else { return .invalid }

    observedSampleCount += samples.count
    if !hasSignalEvidence {
      hasSignalEvidence = samples.contains { abs($0) >= Self.minimumSignalMagnitude }
    }
    guard observedSampleCount >= Self.minimumUsableFrameSampleCount,
      hasSignalEvidence
    else {
      return .waiting
    }
    isReady = true
    return .ready
  }
}

actor LocalSpeechCaptureReadinessGate {
  enum Failure: Error, Sendable, Equatable {
    case streamEnded
    case streamFailed
    case timedOut
  }

  private enum Resolution: Sendable {
    case ready
    case failed(Failure)
    case cancelled
  }

  private var resolution: Resolution?
  private var waiters: [CheckedContinuation<Resolution, Never>] = []

  func wait(
    timeout: Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) async throws {
    let timeoutTask = Task { [weak self] in
      do {
        try await sleep(timeout)
      } catch {
        return
      }
      await self?.resolve(.failed(.timedOut))
    }
    let result = await withTaskCancellationHandler {
      await nextResolution()
    } onCancel: {
      Task { [weak self] in await self?.resolve(.cancelled) }
    }
    timeoutTask.cancel()
    await timeoutTask.value
    try Task.checkCancellation()

    switch result {
    case .ready:
      return
    case .failed(let failure):
      throw failure
    case .cancelled:
      throw CancellationError()
    }
  }

  func signalReady() {
    resolve(.ready)
  }

  func signalStreamEnded() {
    resolve(.failed(.streamEnded))
  }

  func signalStreamFailed() {
    resolve(.failed(.streamFailed))
  }

  func cancel() {
    resolve(.cancelled)
  }

  private func nextResolution() async -> Resolution {
    if let resolution { return resolution }
    return await withCheckedContinuation { waiters.append($0) }
  }

  private func resolve(_ result: Resolution) {
    guard resolution == nil else { return }
    resolution = result
    let currentWaiters = waiters
    waiters.removeAll()
    for waiter in currentWaiters {
      waiter.resume(returning: result)
    }
  }
}
