import RillSpeechContracts
import Foundation
import RillCore

public enum WakeWordSuspensionReason: String, Sendable, Equatable, Hashable {
  case busy
  case interactiveRecognition
  case speechPlayback
  case microphonePermission
  case inputDeviceChanged
}

public enum WakeWordListeningStatus: Sendable, Equatable {
  case disabled
  case modelMissing
  case starting
  case listening
  case suspended(WakeWordSuspensionReason)
  case failed(String)
}

public enum WakeWordTriggerSourceError: Error, LocalizedError, Equatable, Sendable {
  case modelNotInstalled
  case invalidConfiguration

  public var errorDescription: String? {
    switch self {
    case .modelNotInstalled:
      return "Prepare the selected local speech model before enabling wake-word listening."
    case .invalidConfiguration:
      return "The wake-word configuration is invalid."
    }
  }
}

/// A local Qwen-ASR phrase gate fed by Rill's process-wide microphone owner.
///
/// Idle listening runs only the bundled Silero VAD. Complete speech candidates
/// are written to a private managed temporary WAV, recognized by the selected
/// local speech route, matched strictly against configured phrase prefixes, and
/// then removed. Unmatched speech is never emitted or added to history.
public actor WakeWordTriggerSource: TriggerSource {
  public nonisolated let id = "wake-word.qwen-asr"
  public nonisolated let binding = TriggerBinding.wakeWord

  private struct Candidate {
    let writer: any LocalSpeechRecordingWriting
    var speechDurationSeconds: Double
    var trailingSilenceSeconds: Double
    var totalDurationSeconds: Double
  }

  private struct PendingRecognition {
    let capturedAudio: CapturedAudio
    let workflow: WorkflowDefinition
    let phrases: [String]
  }

  private enum Timing {
    static let preRollSampleCount = SharedVoiceInputFrame.sampleRate / 2
    static let minimumSpeechDurationSeconds = 0.3
    static let trailingSilenceSeconds = 0.8
    static let maximumCandidateDurationSeconds = 12.0
  }

  private let hub: SharedVoiceInputHub
  private let recognizer: any SpeechRecognizer
  private let vadSessionFactory:
    @Sendable () async -> (any LocalSpeechStreamingPreviewSession)?
  private nonisolated let eventStream: AsyncStream<WorkflowTriggerEvent>
  private nonisolated let eventContinuation:
    AsyncStream<WorkflowTriggerEvent>.Continuation
  private nonisolated let statusStreamValue: AsyncStream<WakeWordListeningStatus>
  private nonisolated let statusContinuation:
    AsyncStream<WakeWordListeningStatus>.Continuation

  private var vadSession: (any LocalSpeechStreamingPreviewSession)?
  private var workflow: WorkflowDefinition?
  private var configuration: WakeWordConfiguration?
  private var subscriptionID: UUID?
  private var listeningTask: Task<Void, Never>?
  private var activityTask: Task<Void, Never>?
  private var inputRestartTask: Task<Void, Never>?
  private var recognitionTask: Task<Void, Never>?
  private var activeRecognitionID: UUID?
  private var queuedRecognition: PendingRecognition?
  private var candidate: Candidate?
  private var preRoll: [Float] = []
  private var pendingCommands: [UUID: String] = [:]
  private var suspensionReasons: Set<WakeWordSuspensionReason> = []
  private var status = WakeWordListeningStatus.disabled

  public init(
    hub: SharedVoiceInputHub,
    recognizer: any SpeechRecognizer,
    vadSessionFactory: @escaping @Sendable () async ->
      (any LocalSpeechStreamingPreviewSession)? = { nil }
  ) {
    self.hub = hub
    self.recognizer = recognizer
    self.vadSessionFactory = vadSessionFactory
    let (eventStream, eventContinuation) =
      AsyncStream<WorkflowTriggerEvent>.makeStream(
        bufferingPolicy: .bufferingNewest(8)
      )
    self.eventStream = eventStream
    self.eventContinuation = eventContinuation
    let (statusStream, statusContinuation) =
      AsyncStream<WakeWordListeningStatus>.makeStream(
        bufferingPolicy: .bufferingNewest(8)
      )
    statusStreamValue = statusStream
    self.statusContinuation = statusContinuation
    preRoll.reserveCapacity(Timing.preRollSampleCount)
  }

  public nonisolated func stream() -> AsyncStream<WorkflowTriggerEvent> {
    eventStream
  }

  public nonisolated func statusStream() -> AsyncStream<WakeWordListeningStatus> {
    statusStreamValue
  }

  public func currentStatus() -> WakeWordListeningStatus {
    status
  }

  public func validate(configuration: WakeWordConfiguration) throws {
    do {
      _ = try configuration.validatedPhrases()
    } catch {
      throw WakeWordTriggerSourceError.invalidConfiguration
    }
  }

  public func start(
    configuration: WakeWordConfiguration,
    workflow: WorkflowDefinition
  ) async throws {
    await stopListening(publishDisabled: false)
    publish(.starting)
    try validate(configuration: configuration)

    guard let vadSession = await vadSessionFactory() else {
      publish(.modelMissing)
      throw WakeWordTriggerSourceError.modelNotInstalled
    }
    let activityStream = hub.activityStream()
    let subscription = try await hub.subscribe(channel: .ambientWakeWord)
    let activity = await hub.currentActivity()
    self.vadSession = vadSession
    self.workflow = workflow
    self.configuration = configuration
    subscriptionID = subscription.id
    suspensionReasons.removeAll()
    apply(activity: activity)

    activityTask = Task { [weak self] in
      for await activity in activityStream {
        guard !Task.isCancelled else { return }
        await self?.voiceInputActivityChanged(activity)
      }
    }

    listeningTask = Task { [weak self] in
      do {
        for try await frame in subscription.stream {
          guard !Task.isCancelled else { return }
          await self?.receive(frame)
        }
        await self?.listeningEnded(error: SharedVoiceInputError.producerStopped)
      } catch is CancellationError {
        return
      } catch {
        await self?.listeningEnded(error: error)
      }
    }
  }

  /// Returns and removes a command recognized in the same utterance as the
  /// wake phrase. The payload is deliberately one-shot and memory-only.
  public func claimPrefilledCommand(for eventID: UUID) -> String? {
    pendingCommands.removeValue(forKey: eventID)
  }

  public func setSuspended(_ reason: WakeWordSuspensionReason?) async {
    let interactiveRecognitionIsActive = suspensionReasons.contains(
      .interactiveRecognition
    )
    suspensionReasons = reason.map { [$0] } ?? []
    if interactiveRecognitionIsActive {
      suspensionReasons.insert(.interactiveRecognition)
    }
    resetGate(cancelRecognition: true)
    publishEffectiveListeningStatus()
  }

  public func suspend(for reason: WakeWordSuspensionReason) async {
    suspensionReasons.insert(reason)
    resetGate(cancelRecognition: true)
    publishEffectiveListeningStatus()
  }

  public func resume(from reason: WakeWordSuspensionReason) async {
    suspensionReasons.remove(reason)
    resetGate(cancelRecognition: false)
    publishEffectiveListeningStatus()
  }

  public func stop() async {
    await stopListening(publishDisabled: true)
  }

  public func shutdown() async {
    await stopListening(publishDisabled: true)
    eventContinuation.finish()
    statusContinuation.finish()
  }

  private func receive(_ frame: SharedVoiceInputFrame) async {
    guard suspensionReasons.isEmpty, let vadSession else { return }
    let wakeWordSamples = WakeWordAudioConditioner.prepare(frame.samples)

    do {
      _ = try vadSession.accept(samples: wakeWordSamples)
      let observations = vadSession.drainVoiceActivity()
      let speechDuration = observations
        .filter(\.isSpeech)
        .reduce(0) { duration, _ in
          duration + Double(MLXSileroVADConstants.chunkSampleCount)
            / Double(SharedVoiceInputFrame.sampleRate)
        }
      let silenceDuration = observations
        .filter { !$0.isSpeech }
        .reduce(0) { duration, _ in
          duration + Double(MLXSileroVADConstants.chunkSampleCount)
            / Double(SharedVoiceInputFrame.sampleRate)
        }

      if candidate == nil, speechDuration > 0 {
        try beginCandidate(with: wakeWordSamples)
      } else if candidate != nil {
        try candidate?.writer.append(wakeWordSamples)
      }

      if var candidate {
        candidate.totalDurationSeconds +=
          Double(wakeWordSamples.count) / Double(SharedVoiceInputFrame.sampleRate)
        candidate.speechDurationSeconds += speechDuration
        if speechDuration > 0 {
          candidate.trailingSilenceSeconds = 0
        } else {
          candidate.trailingSilenceSeconds += silenceDuration
        }
        self.candidate = candidate

        if candidate.totalDurationSeconds >= Timing.maximumCandidateDurationSeconds
          || (candidate.speechDurationSeconds >= Timing.minimumSpeechDurationSeconds
            && candidate.trailingSilenceSeconds >= Timing.trailingSilenceSeconds)
        {
          try finishCandidate()
        }
      }
      appendToPreRoll(wakeWordSamples)
    } catch {
      discardCandidate()
      publish(.failed(error.localizedDescription))
    }
  }

  private func beginCandidate(with samples: [Float]) throws {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      RecognitionTemporaryAudioNamespace.currentProcessFilenamePrefix
        + "wake-gate-\(UUID().uuidString.lowercased()).wav",
      isDirectory: false
    )
    let writer = try LocalSpeechIncrementalWaveWriter(
      fileURL: fileURL,
      maximumFrameCount:
        Int(Timing.maximumCandidateDurationSeconds)
        * SharedVoiceInputFrame.sampleRate
        + Timing.preRollSampleCount
        + SharedVoiceInputFrame.sampleRate
    )
    do {
      try writer.append(preRoll)
      try writer.append(samples)
      candidate = Candidate(
        writer: writer,
        speechDurationSeconds: 0,
        trailingSilenceSeconds: 0,
        totalDurationSeconds:
          Double(preRoll.count)
          / Double(SharedVoiceInputFrame.sampleRate)
      )
    } catch {
      writer.closeForDiscard()
      try? FileManager.default.removeItem(at: fileURL)
      throw error
    }
  }

  private func finishCandidate() throws {
    guard let candidate, let workflow, let configuration else { return }
    self.candidate = nil
    guard candidate.speechDurationSeconds >= Timing.minimumSpeechDurationSeconds else {
      candidate.writer.closeForDiscard()
      try? FileManager.default.removeItem(at: candidate.writer.fileURL)
      return
    }

    let artifact = try candidate.writer.finalize()
    let duration =
      Double(artifact.frameCount) / Double(SharedVoiceInputFrame.sampleRate)
    let capturedAudio = try CapturedAudio(
      durationSeconds: duration,
      format: AudioFormat(
        sampleRateHz: Double(SharedVoiceInputFrame.sampleRate),
        channelCount: 1,
        encoding: .float32
      ),
      fileURL: artifact.fileURL,
      fileOwnership: .managedTemporary
    )
    let pending = PendingRecognition(
      capturedAudio: capturedAudio,
      workflow: workflow,
      phrases: try configuration.validatedPhrases()
    )
    guard recognitionTask == nil else {
      replaceQueuedRecognition(with: pending)
      return
    }
    startRecognition(pending)
  }

  private func startRecognition(_ pending: PendingRecognition) {
    let recognitionID = UUID()
    activeRecognitionID = recognitionID
    recognitionTask = Task { [weak self] in
      guard let self else {
        _ = try? pending.capturedAudio.removeManagedTemporaryFile()
        return
      }
      await self.recognizeCandidate(
        pending.capturedAudio,
        workflow: pending.workflow,
        phrases: pending.phrases,
        recognitionID: recognitionID
      )
    }
  }

  private func recognizeCandidate(
    _ capturedAudio: CapturedAudio,
    workflow: WorkflowDefinition,
    phrases: [String],
    recognitionID: UUID
  ) async {
    defer {
      _ = try? capturedAudio.removeManagedTemporaryFile()
    }
    do {
      var options = SpeechRecognitionRequestOptions.empty
      options.hints.keyterms = phrases
      var candidateWorkflow = workflow
      candidateWorkflow.metadata["speech.task-priority"] = "wake-candidate"
      let result = try await recognizer.recognize(
        RecognitionRequest(
          runID: recognitionID,
          workflow: candidateWorkflow,
          contextSnapshot: .empty,
          capturedAudio: capturedAudio,
          options: options
        )
      )
      try Task.checkCancellation()
      await candidateRecognitionCompleted(
        result,
        phrases: phrases,
        recognitionID: recognitionID
      )
    } catch is CancellationError {
      candidateRecognitionCancelled(recognitionID: recognitionID)
    } catch {
      candidateRecognitionFailed(error, recognitionID: recognitionID)
    }
  }

  private func candidateRecognitionCompleted(
    _ result: RecognitionResult,
    phrases: [String],
    recognitionID: UUID
  ) async {
    guard activeRecognitionID == recognitionID else { return }
    recognitionTask = nil
    activeRecognitionID = nil
    let activity = await hub.currentActivity()
    guard !activity.isInteractiveRecognitionActive,
      suspensionReasons.isEmpty,
      let workflow,
      let match = WakePhraseMatcher.match(
        transcript: result.bestText,
        phrases: phrases
      )
    else {
      startQueuedRecognitionOrPublishStatus()
      return
    }

    discardQueuedRecognition()

    let event = WorkflowTriggerEvent(
      binding: .wakeWord,
      workflowID: workflow.id,
      sourceID: id,
      metadata: ["wakeWord.phrase": match.phrase]
    )
    if let command = match.command {
      pendingCommands[event.id] = command
    }
    suspensionReasons.insert(.busy)
    preRoll.removeAll(keepingCapacity: true)
    publishEffectiveListeningStatus()
    eventContinuation.yield(event)
  }

  private func candidateRecognitionCancelled(recognitionID: UUID) {
    guard activeRecognitionID == recognitionID else { return }
    recognitionTask = nil
    activeRecognitionID = nil
    startQueuedRecognitionOrPublishStatus()
  }

  private func candidateRecognitionFailed(
    _ error: Error,
    recognitionID: UUID
  ) {
    guard activeRecognitionID == recognitionID else { return }
    recognitionTask = nil
    activeRecognitionID = nil
    discardQueuedRecognition()
    publish(.failed(error.localizedDescription))
  }

  private func listeningEnded(error: Error) {
    guard listeningTask != nil else { return }
    listeningTask = nil
    subscriptionID = nil
    try? vadSession?.cancel()
    vadSession = nil
    discardCandidate()
    guard
      let configuration,
      let workflow,
      inputRestartTask == nil
    else {
      publish(.failed(error.localizedDescription))
      return
    }
    suspensionReasons.insert(.inputDeviceChanged)
    publishEffectiveListeningStatus()
    inputRestartTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(500))
        try Task.checkCancellation()
        await self?.restartAfterInputChange(
          configuration: configuration,
          workflow: workflow
        )
      } catch {
        // Explicit stop/shutdown owns the terminal status.
      }
    }
  }

  private func restartAfterInputChange(
    configuration: WakeWordConfiguration,
    workflow: WorkflowDefinition
  ) async {
    inputRestartTask = nil
    do {
      try await start(configuration: configuration, workflow: workflow)
    } catch is CancellationError {
      return
    } catch {
      publish(.failed(error.localizedDescription))
    }
  }

  private func stopListening(publishDisabled: Bool) async {
    inputRestartTask?.cancel()
    inputRestartTask = nil
    activityTask?.cancel()
    activityTask = nil
    let task = listeningTask
    listeningTask = nil
    task?.cancel()
    if let subscriptionID {
      await hub.unsubscribe(id: subscriptionID)
    }
    subscriptionID = nil
    resetGate(cancelRecognition: true)
    try? vadSession?.cancel()
    vadSession = nil
    workflow = nil
    configuration = nil
    pendingCommands.removeAll()
    suspensionReasons.removeAll()
    if publishDisabled {
      publish(.disabled)
    }
  }

  private func resetGate(cancelRecognition: Bool) {
    discardCandidate()
    if cancelRecognition {
      recognitionTask?.cancel()
      recognitionTask = nil
      activeRecognitionID = nil
      discardQueuedRecognition()
    }
    preRoll.removeAll(keepingCapacity: true)
  }

  private func discardCandidate() {
    guard let candidate else { return }
    self.candidate = nil
    candidate.writer.closeForDiscard()
    try? FileManager.default.removeItem(at: candidate.writer.fileURL)
  }

  private func replaceQueuedRecognition(with pending: PendingRecognition) {
    discardQueuedRecognition()
    queuedRecognition = pending
  }

  private func startQueuedRecognitionOrPublishStatus() {
    guard suspensionReasons.isEmpty, let pending = queuedRecognition else {
      publishEffectiveListeningStatus()
      return
    }
    queuedRecognition = nil
    startRecognition(pending)
  }

  private func discardQueuedRecognition() {
    guard let queuedRecognition else { return }
    self.queuedRecognition = nil
    _ = try? queuedRecognition.capturedAudio.removeManagedTemporaryFile()
  }

  private func appendToPreRoll(_ samples: [Float]) {
    guard !samples.isEmpty else { return }
    preRoll.append(contentsOf: samples)
    let overflow = preRoll.count - Timing.preRollSampleCount
    if overflow > 0 {
      preRoll.removeFirst(overflow)
    }
  }

  private func publish(_ status: WakeWordListeningStatus) {
    self.status = status
    statusContinuation.yield(status)
  }

  private func publishEffectiveListeningStatus() {
    if let reason = [
      WakeWordSuspensionReason.microphonePermission,
      .inputDeviceChanged,
      .speechPlayback,
      .busy,
      .interactiveRecognition,
    ].first(where: suspensionReasons.contains) {
      publish(.suspended(reason))
    } else if vadSession != nil, subscriptionID != nil {
      publish(.listening)
    }
  }

  private func voiceInputActivityChanged(_ activity: SharedVoiceInputActivity) {
    apply(activity: activity)
  }

  private func apply(activity: SharedVoiceInputActivity) {
    if activity.isInteractiveRecognitionActive {
      let inserted = suspensionReasons.insert(.interactiveRecognition).inserted
      if inserted {
        resetGate(cancelRecognition: true)
      }
    } else {
      let removed = suspensionReasons.remove(.interactiveRecognition) != nil
      if removed {
        resetGate(cancelRecognition: false)
      }
    }
    publishEffectiveListeningStatus()
  }
}
