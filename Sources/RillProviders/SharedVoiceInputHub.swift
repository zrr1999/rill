import Foundation

public enum SharedVoiceInputMetadata {
  public static let handoffID = "rill.voiceInput.handoffID"
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
  private struct Handoff: Sendable {
    let startSampleIndex: Int64
    let expiresAt: ContinuousClock.Instant
  }

  private static let ringCapacity = SharedVoiceInputFrame.sampleRate * 2
  private static let subscriberBufferCapacity = 48
  private static let handoffLifetime: Duration = .seconds(15)

  private let processor: AppleVoiceProcessingAudioProcessor
  private var subscribers:
    [UUID: AsyncThrowingStream<SharedVoiceInputFrame, Error>.Continuation] = [:]
  private var producerContinuation: AsyncThrowingStream<[Float], Error>.Continuation?
  private var producerTask: Task<Void, Never>?
  private var producerGeneration: UInt64 = 0
  private var ringSamples: [Float] = []
  private var ringStartSampleIndex: Int64 = 0
  private var nextSampleIndex: Int64 = 0
  private var handoffs: [UUID: Handoff] = [:]
  private var terminated = false

  init(processor: AppleVoiceProcessingAudioProcessor) {
    self.processor = processor
    ringSamples.reserveCapacity(Self.ringCapacity)
  }

  public func subscribe(
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

    try ensureProducerStarted()
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
    subscribers[id] = continuation
    return SharedVoiceInputSubscription(id: id, stream: stream)
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
    guard let continuation = subscribers.removeValue(forKey: id) else { return }
    continuation.finish()
    stopProducerIfIdle()
  }

  public func resetHandoffs() {
    handoffs.removeAll()
  }

  public func shutdown() {
    guard !terminated else { return }
    terminated = true
    let continuations = Array(subscribers.values)
    subscribers.removeAll()
    for continuation in continuations {
      continuation.finish()
    }
    producerTask?.cancel()
    producerTask = nil
    producerContinuation?.finish()
    producerContinuation = nil
    processor.shutdown()
    ringSamples.removeAll(keepingCapacity: false)
    handoffs.removeAll()
  }

  private func ensureProducerStarted() throws {
    guard producerTask == nil else { return }
    producerGeneration &+= 1
    let generation = producerGeneration
    let terminalState = AppleVoiceProcessingPCMStreamTerminalState()
    let (stream, continuation) = processor.startStreamingRecordingLive(
      inputDeviceID: nil,
      terminalState: terminalState
    )
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
    for (id, continuation) in subscribers {
      switch continuation.yield(frame) {
      case .enqueued:
        break
      case .dropped:
        continuation.finish(throwing: SharedVoiceInputError.consumerTooSlow)
        failedSubscribers.append(id)
      case .terminated:
        failedSubscribers.append(id)
      @unknown default:
        continuation.finish(throwing: SharedVoiceInputError.consumerTooSlow)
        failedSubscribers.append(id)
      }
    }
    for id in failedSubscribers {
      subscribers.removeValue(forKey: id)
    }
    stopProducerIfIdle()
  }

  private func producerEnded(generation: UInt64, error: Error?) {
    guard generation == producerGeneration else { return }
    producerTask = nil
    producerContinuation = nil
    let continuations = Array(subscribers.values)
    subscribers.removeAll()
    for continuation in continuations {
      continuation.finish(throwing: error ?? SharedVoiceInputError.producerStopped)
    }
  }

  private func appendToRing(_ samples: [Float]) {
    ringSamples.append(contentsOf: samples)
    let overflow = ringSamples.count - Self.ringCapacity
    if overflow > 0 {
      ringSamples.removeFirst(overflow)
      ringStartSampleIndex += Int64(overflow)
    }
  }

  private func stopProducerIfIdle() {
    guard subscribers.isEmpty, producerTask != nil else { return }
    producerGeneration &+= 1
    producerTask?.cancel()
    producerTask = nil
    producerContinuation?.finish()
    producerContinuation = nil
    processor.stopRecording()
  }

  private func pruneExpiredHandoffs() {
    let now = ContinuousClock.now
    handoffs = handoffs.filter { $0.value.expiresAt > now }
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

  var endpointRMS: [Float] {
    processor.endpointRMS
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
        let subscription = try await hub.subscribe(replaying: handoffID)
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
