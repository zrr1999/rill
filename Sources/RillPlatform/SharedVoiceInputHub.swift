import Foundation

public enum SharedVoiceInputMetadata {
  public static let handoffID = "rill.voiceInput.handoffID"
}

/// Declares why a consumer is attached to Rill's process-wide microphone.
/// Interactive recognition always owns the live frames while it is active;
/// ambient wake-word listening resumes automatically after capture ends.
public enum SharedVoiceInputChannel: String, Sendable, Equatable, Hashable {
  case ambientWakeWord
  case interactiveRecognition

  fileprivate var priority: Int {
    switch self {
    case .ambientWakeWord:
      0
    case .interactiveRecognition:
      100
    }
  }
}

public struct SharedVoiceInputActivity: Sendable, Equatable {
  public let activeChannels: Set<SharedVoiceInputChannel>

  public init(activeChannels: Set<SharedVoiceInputChannel>) {
    self.activeChannels = activeChannels
  }

  public var highestPriorityChannel: SharedVoiceInputChannel? {
    activeChannels.max { $0.priority < $1.priority }
  }

  public var isInteractiveRecognitionActive: Bool {
    activeChannels.contains(.interactiveRecognition)
  }
}

enum SharedVoiceInputArbitration {
  static func shouldDeliver(
    to subscriberChannel: SharedVoiceInputChannel,
    activity: SharedVoiceInputActivity
  ) -> Bool {
    activity.highestPriorityChannel == subscriberChannel
  }
}

/// One 16 kHz mono frame from Rill's process-wide microphone producer.
public struct SharedVoiceInputFrame: Sendable, Equatable {
  public static let sampleRate = 16_000

  public let samples: [Float]
  public let startSampleIndex: Int64

  public init(samples: [Float], startSampleIndex: Int64) {
    self.samples = samples
    self.startSampleIndex = startSampleIndex
  }

  public var endSampleIndex: Int64 {
    startSampleIndex + Int64(samples.count)
  }
}

public struct SharedVoiceInputSubscription: Sendable {
  public let id: UUID
  public let channel: SharedVoiceInputChannel
  public let stream: AsyncThrowingStream<SharedVoiceInputFrame, Error>
}

public enum SharedVoiceInputError: Error, LocalizedError, Equatable, Sendable {
  case invalidHandoff
  case consumerTooSlow
  case producerStopped

  public var errorDescription: String? {
    switch self {
    case .invalidHandoff:
      return "The wake-word microphone handoff is no longer available."
    case .consumerTooSlow:
      return "A microphone consumer could not keep up with real-time input."
    case .producerStopped:
      return "The shared microphone input stopped unexpectedly."
    }
  }
}

/// Owns the only live microphone producer used by local KWS and recording.
///
/// The rolling buffer is process memory only. A handoff names an absolute
/// sample boundary, allowing wake-word detection to transfer the post-keyword
/// audio already received while the workflow starts without opening a second
/// audio engine or writing pre-roll to disk.
public actor SharedVoiceInputHub {
  private struct Subscriber {
    let channel: SharedVoiceInputChannel
    let continuation: AsyncThrowingStream<SharedVoiceInputFrame, Error>.Continuation
  }

  private struct Handoff: Sendable {
    let startSampleIndex: Int64
    let expiresAt: ContinuousClock.Instant
  }

  private static let ringCapacity = SharedVoiceInputFrame.sampleRate * 2
  private static let subscriberBufferCapacity = 48
  private static let handoffLifetime: Duration = .seconds(15)

  /// Ambient listening deliberately uses an ordinary AVAudioEngine input so
  /// an enabled wake workflow does not leave VoiceProcessingIO attached to the
  /// system's input/output devices for the whole application lifetime.
  private let ambientProcessor: AppleVoiceProcessingAudioProcessor
  private let interactiveProcessor: AppleVoiceProcessingAudioProcessor
  private var subscribers: [UUID: Subscriber] = [:]
  private nonisolated let activityStreamValue: AsyncStream<SharedVoiceInputActivity>
  private nonisolated let activityContinuation:
    AsyncStream<SharedVoiceInputActivity>.Continuation
  private var producerContinuation: AsyncThrowingStream<[Float], Error>.Continuation?
  private var producerTask: Task<Void, Never>?
  private var producerGeneration: UInt64 = 0
  private var producerChannel: SharedVoiceInputChannel?
  private var ringSamples: [Float] = []
  private var ringStartSampleIndex: Int64 = 0
  private var nextSampleIndex: Int64 = 0
  private var handoffs: [UUID: Handoff] = [:]
  private var terminated = false

  init(processor: AppleVoiceProcessingAudioProcessor) {
    ambientProcessor = processor
    interactiveProcessor = processor
    let (activityStream, activityContinuation) =
      AsyncStream<SharedVoiceInputActivity>.makeStream(
        bufferingPolicy: .bufferingNewest(8)
      )
    activityStreamValue = activityStream
    self.activityContinuation = activityContinuation
    ringSamples.reserveCapacity(Self.ringCapacity)
  }

  init(
    ambientProcessor: AppleVoiceProcessingAudioProcessor,
    interactiveProcessor: AppleVoiceProcessingAudioProcessor
  ) {
    self.ambientProcessor = ambientProcessor
    self.interactiveProcessor = interactiveProcessor
    let (activityStream, activityContinuation) =
      AsyncStream<SharedVoiceInputActivity>.makeStream(
        bufferingPolicy: .bufferingNewest(8)
      )
    activityStreamValue = activityStream
    self.activityContinuation = activityContinuation
    ringSamples.reserveCapacity(Self.ringCapacity)
  }

  public nonisolated func activityStream() -> AsyncStream<SharedVoiceInputActivity> {
    activityStreamValue
  }

  public func currentActivity() -> SharedVoiceInputActivity {
    makeActivity()
  }

  public func subscribe(
    channel: SharedVoiceInputChannel = .interactiveRecognition,
    replaying handoffID: UUID? = nil
  ) throws -> SharedVoiceInputSubscription {
    guard !terminated else {
      throw SharedVoiceInputError.producerStopped
    }
    pruneExpiredHandoffs()
    let replayStart: Int64?
    if let handoffID {
      guard let handoff = handoffs.removeValue(forKey: handoffID) else {
        throw SharedVoiceInputError.invalidHandoff
      }
      replayStart = max(handoff.startSampleIndex, ringStartSampleIndex)
    } else {
      replayStart = nil
    }

    let id = UUID()
    let (stream, continuation) =
      AsyncThrowingStream<SharedVoiceInputFrame, Error>.makeStream(
        bufferingPolicy: .bufferingOldest(Self.subscriberBufferCapacity)
      )
    continuation.onTermination = { [weak self] _ in
      Task { await self?.unsubscribe(id: id) }
    }

    if let replayStart, replayStart < nextSampleIndex {
      let offset = Int(replayStart - ringStartSampleIndex)
      if offset >= 0, offset < ringSamples.count {
        let samples = Array(ringSamples[offset...])
        if case .dropped = continuation.yield(
          SharedVoiceInputFrame(samples: samples, startSampleIndex: replayStart)
        ) {
          continuation.finish(throwing: SharedVoiceInputError.consumerTooSlow)
          throw SharedVoiceInputError.consumerTooSlow
        }
      }
    }
    subscribers[id] = Subscriber(channel: channel, continuation: continuation)
    publishActivity()
    reconcileProducer()
    return SharedVoiceInputSubscription(id: id, channel: channel, stream: stream)
  }

  /// Creates a single-use transfer token. The requested boundary is clamped to
  /// PCM still retained by the two-second in-memory ring.
  public func makeHandoff(afterSampleIndex sampleIndex: Int64) -> UUID {
    pruneExpiredHandoffs()
    let id = UUID()
    handoffs[id] = Handoff(
      startSampleIndex: min(max(sampleIndex, ringStartSampleIndex), nextSampleIndex),
      expiresAt: ContinuousClock.now.advanced(by: Self.handoffLifetime)
    )
    return id
  }

  public func currentSampleIndex() -> Int64 {
    nextSampleIndex
  }

  public func unsubscribe(id: UUID) {
    guard let subscriber = subscribers.removeValue(forKey: id) else { return }
    subscriber.continuation.finish()
    publishActivity()
    reconcileProducer()
  }

  public func resetHandoffs() {
    handoffs.removeAll()
  }

  public func shutdown() {
    guard !terminated else { return }
    terminated = true
    let continuations = subscribers.values.map(\.continuation)
    subscribers.removeAll()
    for continuation in continuations {
      continuation.finish()
    }
    producerTask?.cancel()
    producerTask = nil
    producerContinuation?.finish()
    producerContinuation = nil
    producerChannel = nil
    ambientProcessor.shutdown()
    if ambientProcessor !== interactiveProcessor {
      interactiveProcessor.shutdown()
    }
    ringSamples.removeAll(keepingCapacity: false)
    handoffs.removeAll()
    publishActivity()
    activityContinuation.finish()
  }

  private func reconcileProducer() {
    let desiredChannel = makeActivity().highestPriorityChannel
    guard desiredChannel != producerChannel || producerTask == nil else { return }

    stopProducer(releaseFrontend: true)
    guard let desiredChannel else { return }

    producerGeneration &+= 1
    let generation = producerGeneration
    let terminalState = AppleVoiceProcessingPCMStreamTerminalState()
    let processor = processor(for: desiredChannel)
    let (stream, continuation) = processor.startStreamingRecordingLive(
      inputDeviceID: nil,
      terminalState: terminalState
    )
    producerChannel = desiredChannel
    producerContinuation = continuation
    producerTask = Task { [weak self] in
      do {
        for try await samples in stream {
          guard !Task.isCancelled else { return }
          await self?.receive(samples, generation: generation)
        }
        await self?.producerEnded(generation: generation, error: nil)
      } catch {
        await self?.producerEnded(generation: generation, error: error)
      }
    }
  }

  private func receive(_ samples: [Float], generation: UInt64) {
    guard generation == producerGeneration, !samples.isEmpty else { return }
    let frame = SharedVoiceInputFrame(
      samples: samples,
      startSampleIndex: nextSampleIndex
    )
    nextSampleIndex = frame.endSampleIndex
    appendToRing(samples)

    var failedSubscribers: [UUID] = []
    let activity = makeActivity()
    for (id, subscriber) in subscribers where SharedVoiceInputArbitration.shouldDeliver(
      to: subscriber.channel,
      activity: activity
    ) {
      switch subscriber.continuation.yield(frame) {
      case .enqueued:
        break
      case .dropped:
        subscriber.continuation.finish(throwing: SharedVoiceInputError.consumerTooSlow)
        failedSubscribers.append(id)
      case .terminated:
        failedSubscribers.append(id)
      @unknown default:
        subscriber.continuation.finish(throwing: SharedVoiceInputError.consumerTooSlow)
        failedSubscribers.append(id)
      }
    }
    for id in failedSubscribers {
      subscribers.removeValue(forKey: id)
    }
    if !failedSubscribers.isEmpty {
      publishActivity()
    }
    reconcileProducer()
  }

  private func producerEnded(generation: UInt64, error: Error?) {
    guard generation == producerGeneration else { return }
    producerTask = nil
    producerContinuation = nil
    producerChannel = nil
    let continuations = subscribers.values.map(\.continuation)
    subscribers.removeAll()
    for continuation in continuations {
      continuation.finish(throwing: error ?? SharedVoiceInputError.producerStopped)
    }
    publishActivity()
  }

  private func appendToRing(_ samples: [Float]) {
    ringSamples.append(contentsOf: samples)
    let overflow = ringSamples.count - Self.ringCapacity
    if overflow > 0 {
      ringSamples.removeFirst(overflow)
      ringStartSampleIndex += Int64(overflow)
    }
  }

  private func stopProducer(releaseFrontend: Bool) {
    guard producerTask != nil || producerChannel != nil else { return }
    let processor = producerChannel.map(processor(for:))
    producerGeneration &+= 1
    producerTask?.cancel()
    producerTask = nil
    if releaseFrontend {
      // A configured, stopped VoiceProcessingIO graph can still affect other
      // applications. Release the complete frontend whenever ownership moves
      // away from this channel; the processor remains reusable on the next run.
      processor?.shutdown()
    } else {
      processor?.stopRecording()
    }
    producerContinuation?.finish()
    producerContinuation = nil
    producerChannel = nil
  }

  private func processor(
    for channel: SharedVoiceInputChannel
  ) -> AppleVoiceProcessingAudioProcessor {
    switch channel {
    case .ambientWakeWord:
      ambientProcessor
    case .interactiveRecognition:
      interactiveProcessor
    }
  }

  private func pruneExpiredHandoffs() {
    let now = ContinuousClock.now
    handoffs = handoffs.filter { $0.value.expiresAt > now }
  }

  private func makeActivity() -> SharedVoiceInputActivity {
    SharedVoiceInputActivity(
      activeChannels: Set(subscribers.values.map(\.channel))
    )
  }

  private func publishActivity() {
    activityContinuation.yield(makeActivity())
  }
}

/// Adapts the shared producer to the existing local-recording stream contract.
final class SharedVoiceInputCaptureSource: LocalSpeechAudioCaptureSource,
  @unchecked Sendable
{
  private let hub: SharedVoiceInputHub
  private let processor: AppleVoiceProcessingAudioProcessor
  private let lock = NSLock()
  private var pumpTask: Task<Void, Never>?
  private var subscriptionID: UUID?
  private var pendingHandoffID: UUID?

  init(hub: SharedVoiceInputHub, processor: AppleVoiceProcessingAudioProcessor) {
    self.hub = hub
    self.processor = processor
  }

  var meterRMS: [Float] {
    processor.meterRMS
  }

  func prepareStoppedFrontend() throws {
    try processor.prepareRecordingFrontend(inputDeviceID: nil)
  }

  func setPendingHandoffID(_ id: UUID?) {
    lock.withLock {
      pendingHandoffID = id
    }
  }

  func startStreaming() -> LocalSpeechAudioStream {
    stop()
    let terminalState = AppleVoiceProcessingPCMStreamTerminalState()
    let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream(
      bufferingPolicy: .bufferingOldest(
        AppleVoiceProcessingAudioProcessor.maximumBufferedPCMChunkCount
      )
    )
    let handoffID = lock.withLock {
      defer { pendingHandoffID = nil }
      return pendingHandoffID
    }
    let task = Task { [weak self] in
      guard let self else {
        continuation.finish(throwing: SharedVoiceInputError.producerStopped)
        return
      }
      do {
        let subscription = try await hub.subscribe(
          channel: .interactiveRecognition,
          replaying: handoffID
        )
        lock.withLock { subscriptionID = subscription.id }
        for try await frame in subscription.stream {
          guard !Task.isCancelled else { break }
          switch terminalState.yield(frame.samples, to: continuation) {
          case .enqueued:
            continue
          case .dropped:
            await hub.unsubscribe(id: subscription.id)
            continuation.finish(throwing: SharedVoiceInputError.consumerTooSlow)
            return
          case .terminated:
            await hub.unsubscribe(id: subscription.id)
            return
          }
        }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    lock.withLock { pumpTask = task }
    continuation.onTermination = { [weak self] _ in
      self?.stop()
    }
    return LocalSpeechAudioStream(
      stream: stream,
      continuation: continuation,
      terminalState: terminalState
    )
  }

  func stop() {
    let detached = lock.withLock { () -> (Task<Void, Never>?, UUID?) in
      let result = (pumpTask, subscriptionID)
      pumpTask = nil
      subscriptionID = nil
      return result
    }
    detached.0?.cancel()
    if let id = detached.1 {
      Task { await hub.unsubscribe(id: id) }
    }
  }

  func shutdown() {
    stop()
    Task { await hub.shutdown() }
  }
}
