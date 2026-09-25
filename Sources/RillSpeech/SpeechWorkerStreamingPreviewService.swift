import RillSpeechContracts
import Foundation
import RillCore

/// Bridges the duplex worker protocol to the capture runtime's deliberately
/// small synchronous preview seam. The event reader is independent from the
/// audio callback; each callback only appends to a bounded 100 ms PCM buffer.
public actor SpeechWorkerStreamingPreviewService {
  private let supervisor: SpeechWorkerSupervisor
  private let settingsProvider: @Sendable () async throws -> LocalSpeechSettings
  private let measuredPeakObserver: @Sendable (String, UInt64) async -> Void

  public init(
    supervisor: SpeechWorkerSupervisor,
    settingsProvider: @escaping @Sendable () async throws -> LocalSpeechSettings,
    measuredPeakObserver: @escaping @Sendable (String, UInt64) async -> Void = { _, _ in }
  ) {
    self.supervisor = supervisor
    self.settingsProvider = settingsProvider
    self.measuredPeakObserver = measuredPeakObserver
  }

  func makeSession(
    for request: AudioCaptureRequest
  ) async -> (any LocalSpeechStreamingPreviewSession)? {
    do {
      let settings = try await settingsProvider()
      let configuration = request.configuration
      let modelID = LocalSpeechModelCatalog.effectiveModelIdentifier(
        settings: settings,
        modelOverride: configuration.modelOverride
      )
      guard MLXAudioModelCatalog.distributableModelIdentifiers.contains(modelID),
        settings.enabledModelIDs.contains(modelID)
      else {
        return nil
      }
      let language =
        configuration.languageOverride
        ?? settings.language
      let profile =
        SpeechWorkerStreamingProfile(
          rawValue: configuration.streamingProfile ?? ""
        ) ?? Self.defaultProfile(for: request)
      let livePreview = configuration.livePreviewEnabled
      guard livePreview || request.endpointControl != nil else { return nil }
      let workerSession = try await supervisor.startStreaming(
        SpeechWorkerStreamStart(
          modelID: modelID,
          language: language,
          keyterms: [],
          mode: livePreview ? .vadAndTranscription : .vadOnly,
          profile: profile,
          priority: .interactive,
          downloadIfNeeded: settings.downloadIfNeeded
        )
      )
      return SpeechWorkerStreamingPreviewSession(
        workerSession: workerSession,
        modelID: modelID,
        measuredPeakObserver: measuredPeakObserver
      )
    } catch {
      return nil
    }
  }

  public func makeVADSession() async -> (any LocalSpeechStreamingPreviewSession)? {
    do {
      let settings = try await settingsProvider()
      let modelID = LocalSpeechModelCatalog.effectiveModelIdentifier(
        settings: settings,
        modelOverride: nil
      )
      guard MLXAudioModelCatalog.distributableModelIdentifiers.contains(modelID),
        settings.enabledModelIDs.contains(modelID)
      else {
        return nil
      }
      let workerSession = try await supervisor.startStreaming(
        SpeechWorkerStreamStart(
          modelID: modelID,
          language: settings.language,
          keyterms: [],
          mode: .vadOnly,
          profile: .agent,
          priority: .voiceActivity,
          downloadIfNeeded: settings.downloadIfNeeded
        )
      )
      return SpeechWorkerStreamingPreviewSession(
        workerSession: workerSession,
        modelID: modelID,
        measuredPeakObserver: measuredPeakObserver
      )
    } catch {
      return nil
    }
  }

  public func releaseLoadedModels() async throws {
    try await supervisor.releaseLoadedModel()
  }

  private static func defaultProfile(
    for request: AudioCaptureRequest
  ) -> SpeechWorkerStreamingProfile {
    if request.triggerEvent?.binding == .wakeWord {
      return .agent
    }
    return .realtime
  }

}

private final class SpeechWorkerStreamingPreviewSession:
  LocalSpeechStreamingPreviewSession,
  @unchecked Sendable
{
  private struct State {
    var pendingSamples: [Float] = []
    var confirmed = ""
    var provisional = ""
    var completed = ""
    var terminalError: Error?
    var finishSent = false
    var pendingVoiceActivity: [SpeechWorkerVADActivity] = []
  }

  private let workerSession: SpeechWorkerStreamingSession
  private let modelID: String
  private let measuredPeakObserver: @Sendable (String, UInt64) async -> Void
  private let lock = NSLock()
  private var state = State()
  private var eventTask: Task<Void, Never>?

  init(
    workerSession: SpeechWorkerStreamingSession,
    modelID: String,
    measuredPeakObserver: @escaping @Sendable (String, UInt64) async -> Void
  ) {
    self.workerSession = workerSession
    self.modelID = modelID
    self.measuredPeakObserver = measuredPeakObserver
    eventTask = Task { [weak self] in
      do {
        for try await event in workerSession.events {
          self?.observe(event)
        }
      } catch {
        self?.record(error)
      }
    }
  }

  var providesVoiceActivity: Bool { true }

  deinit {
    eventTask?.cancel()
    let shouldCancel = lock.withLock { !state.finishSent }
    if shouldCancel {
      try? workerSession.cancel()
    }
  }

  func accept(samples: [Float]) throws -> String {
    guard samples.allSatisfy(\.isFinite) else {
      throw SpeechWorkerProtocolError.invalidFrame
    }
    let frames: [[Float]] = try lock.withLock {
      if let terminalError = state.terminalError { throw terminalError }
      guard !state.finishSent else { throw SpeechWorkerClientError.staleResponse }
      state.pendingSamples.append(contentsOf: samples)
      var frames: [[Float]] = []
      while state.pendingSamples.count
        >= SpeechWorkerStreamingProtocol.preferredSamplesPerFrame
      {
        frames.append(
          Array(
            state.pendingSamples.prefix(
              SpeechWorkerStreamingProtocol.preferredSamplesPerFrame
            )
          )
        )
        state.pendingSamples.removeFirst(
          SpeechWorkerStreamingProtocol.preferredSamplesPerFrame
        )
      }
      return frames
    }
    for frame in frames {
      try workerSession.append(samples: frame)
    }
    return currentText()
  }

  func finish() async throws -> String {
    let tail: [Float] = try lock.withLock {
      if let terminalError = state.terminalError { throw terminalError }
      guard !state.finishSent else { return [] }
      state.finishSent = true
      defer { state.pendingSamples.removeAll(keepingCapacity: false) }
      return state.pendingSamples
    }
    if !tail.isEmpty {
      try workerSession.append(samples: tail)
    }
    try workerSession.finish()
    await eventTask?.value
    if let terminalError = lock.withLock({ state.terminalError }) {
      throw terminalError
    }
    return currentText()
  }

  func drainVoiceActivity() -> [SpeechWorkerVADActivity] {
    lock.withLock {
      defer { state.pendingVoiceActivity.removeAll(keepingCapacity: true) }
      return state.pendingVoiceActivity
    }
  }

  func cancel() throws {
    let shouldCancel = lock.withLock { () -> Bool in
      guard !state.finishSent else { return false }
      state.finishSent = true
      state.pendingSamples.removeAll(keepingCapacity: false)
      return true
    }
    if shouldCancel { try workerSession.cancel() }
  }

  private func observe(_ event: SpeechWorkerStreamEvent) {
    if case .stats(let stats) = event {
      guard stats.peakMemoryBytes > 0 else { return }
      Task { [modelID, measuredPeakObserver] in
        await measuredPeakObserver(modelID, stats.peakMemoryBytes)
      }
      return
    }
    lock.withLock {
      switch event {
      case .transcriptUpdate(let update):
        state.confirmed = update.confirmed
        state.provisional = update.provisional
      case .completed(let previewText):
        state.completed = previewText
      case .failure(let code):
        state.terminalError = SpeechWorkerClientError.remoteFailure(code)
      case .vadActivity(let activity):
        state.pendingVoiceActivity.append(activity)
      case .accepted, .started, .speechStarted, .speechEnded:
        break
      case .stats:
        assertionFailure("Streaming stats must be handled before locking preview state.")
      }
    }
  }

  private func record(_ error: Error) {
    lock.withLock { state.terminalError = error }
  }

  private func currentText() -> String {
    lock.withLock {
      if !state.completed.isEmpty { return state.completed }
      if state.confirmed.isEmpty { return state.provisional }
      if state.provisional.isEmpty { return state.confirmed }
      return state.confirmed + " " + state.provisional
    }
  }
}
