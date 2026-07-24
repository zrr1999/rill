@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import OSLog

typealias AppleVoiceProcessingInputDeviceID = AudioDeviceID

enum AppleVoiceProcessingAudioError: Error, Equatable, LocalizedError, Sendable {
  case engineMustBeStopped
  case voiceProcessingActivationFailed(String)
  case voiceProcessingDidNotActivate
  case voiceProcessingOutputPathUnavailable
  case voiceProcessingBypassCouldNotBeDisabled
  case voiceProcessingInputCouldNotBeUnmuted
  case automaticGainControlDidNotActivate
  case voiceProcessingFormatsDidNotRemainMatched
  case inputDeviceUnavailable
  case inputDeviceConfigurationFailed(OSStatus)
  case engineWasNotConfigured
  case invalidInputFormat
  case outputFormatCreationFailed
  case converterCreationFailed
  case audioConversionFailed(String)
  case inputConfigurationChanged
  case engineDidNotStart
  case streamBufferOverflow
  case inputBecameUnresponsive

  var permitsOneStartReconfigurationAttempt: Bool {
    switch self {
    case .voiceProcessingFormatsDidNotRemainMatched, .inputConfigurationChanged:
      return true
    default:
      return false
    }
  }

  var errorDescription: String? {
    switch self {
    case .engineMustBeStopped:
      return "Apple voice processing can only be enabled while the audio engine is stopped."
    case .voiceProcessingActivationFailed(let description):
      return "Apple voice processing could not be enabled: \(description)"
    case .voiceProcessingDidNotActivate:
      return "Apple voice processing did not become active on both audio I/O nodes."
    case .voiceProcessingOutputPathUnavailable:
      return "The Apple voice-processing output path could not be established."
    case .voiceProcessingBypassCouldNotBeDisabled:
      return "Apple voice processing remained bypassed after configuration."
    case .voiceProcessingInputCouldNotBeUnmuted:
      return "The Apple voice-processing microphone input remained muted after configuration."
    case .automaticGainControlDidNotActivate:
      return "Apple voice-processing automatic gain control did not become active."
    case .voiceProcessingFormatsDidNotRemainMatched:
      return "The Apple voice-processing input and output formats changed before recording began."
    case .inputDeviceUnavailable:
      return "The selected microphone could not be attached to the voice-processing audio unit."
    case .inputDeviceConfigurationFailed(let status):
      return "The selected microphone could not be configured (Core Audio status \(status))."
    case .engineWasNotConfigured:
      return "The audio engine was started before Apple voice processing was configured."
    case .invalidInputFormat:
      return "The microphone did not expose a valid input audio format."
    case .outputFormatCreationFailed:
      return "The 16 kHz mono speech-recognition audio format could not be created."
    case .converterCreationFailed:
      return "The microphone audio could not be converted to 16 kHz mono."
    case .audioConversionFailed(let description):
      return "The microphone audio stream could not be converted: \(description)"
    case .inputConfigurationChanged:
      return
        "The microphone route changed while voice processing was active. Start recording again."
    case .engineDidNotStart:
      return "The voice-processing audio engine did not start."
    case .streamBufferOverflow:
      return "The microphone audio consumer could not keep up with real-time capture."
    case .inputBecameUnresponsive:
      return "The microphone stopped supplying audio samples."
    }
  }
}

/// Arbitrates producer failure against normal endpoint/manual finish for one
/// PCM stream. `yield` and a dropped-buffer failure are one locked transition,
/// so a concurrent finish cannot claim success in between those two facts.
final class AppleVoiceProcessingPCMStreamTerminalState: @unchecked Sendable {
  enum YieldDisposition: Sendable {
    case enqueued
    case dropped
    case terminated
  }

  private enum State {
    case active
    case failed(AppleVoiceProcessingAudioError)
    case finishing
  }

  private let lock = NSLock()
  private var state = State.active

  var terminalFailure: AppleVoiceProcessingAudioError? {
    lock.withLock {
      guard case .failed(let error) = state else { return nil }
      return error
    }
  }

  var hasClaimedSuccessfulFinish: Bool {
    lock.withLock {
      guard case .finishing = state else { return false }
      return true
    }
  }

  func yield(
    _ samples: [Float],
    to continuation: AsyncThrowingStream<[Float], Error>.Continuation
  ) -> YieldDisposition {
    lock.withLock {
      guard case .active = state else { return .terminated }
      switch continuation.yield(samples) {
      case .enqueued:
        return .enqueued
      case .dropped:
        state = .failed(.streamBufferOverflow)
        return .dropped
      case .terminated:
        return .terminated
      @unknown default:
        state = .failed(.streamBufferOverflow)
        return .dropped
      }
    }
  }

  /// Claims this stream for a producer-side failure. Returning `nil` means a
  /// normal endpoint or manual finish already won the terminal boundary. An
  /// existing failure is returned unchanged so the first producer failure
  /// remains authoritative.
  func claimProducerFailure(
    _ error: AppleVoiceProcessingAudioError
  ) -> AppleVoiceProcessingAudioError? {
    lock.withLock {
      switch state {
      case .active:
        state = .failed(error)
        return error
      case .failed(let existingError):
        return existingError
      case .finishing:
        return nil
      }
    }
  }

  /// Orders a normal endpoint against a producer-side terminal failure.
  /// Once failure wins, buffered PCM can no longer publish a normal endpoint.
  func claimNormalEndpoint(_ operation: () -> Void) -> Bool {
    lock.withLock {
      guard case .active = state else { return false }
      state = .finishing
      operation()
      return true
    }
  }

  /// Claims the finish boundary against a producer failure. A normal endpoint
  /// may already have moved the state to `finishing`; both paths are allowed to
  /// complete, while an earlier producer failure is returned to the caller.
  func claimSuccessfulFinish() -> AppleVoiceProcessingAudioError? {
    lock.withLock {
      switch state {
      case .active:
        state = .finishing
        return nil
      case .finishing:
        return nil
      case .failed(let error):
        return error
      }
    }
  }
}

protocol AppleVoiceProcessingEngineConfigurationTarget: AnyObject {
  var isRunning: Bool { get }
  var isInputVoiceProcessingEnabled: Bool { get }
  var isOutputVoiceProcessingEnabled: Bool { get }
  var voiceProcessingInputFormat: AppleVoiceProcessingIOFormat? { get }
  var isVoiceProcessingBypassed: Bool { get set }
  var isVoiceProcessingInputMuted: Bool { get set }
  var isVoiceProcessingAGCEnabled: Bool { get set }

  func setVoiceProcessingEnabled(_ isEnabled: Bool) throws
  func configureVoiceProcessingInputDevice() throws
  func establishVoiceProcessingOutputPath(matching format: AppleVoiceProcessingIOFormat) -> Bool
}

struct AppleVoiceProcessingIOFormat: Equatable, @unchecked Sendable {
  let audioFormat: AVAudioFormat

  init(audioFormat: AVAudioFormat) {
    self.audioFormat = audioFormat
  }

  init(sampleRate: Double, channelCount: AVAudioChannelCount) {
    guard
      let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channelCount,
        interleaved: false
      )
    else {
      preconditionFailure("The test voice-processing format must be valid.")
    }
    self.audioFormat = audioFormat
  }

  var sampleRate: Double { audioFormat.sampleRate }
  var channelCount: AVAudioChannelCount { audioFormat.channelCount }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.audioFormat.isEqual(rhs.audioFormat)
  }

  func matches(_ other: AVAudioFormat) -> Bool {
    audioFormat.isEqual(other)
  }
}

final class AppleVoiceProcessingOutputPath: @unchecked Sendable {
  private let engine: AVAudioEngine
  private var silencePlayerNode: AVAudioPlayerNode?

  init(engine: AVAudioEngine) {
    self.engine = engine
  }

  var inputFormat: AppleVoiceProcessingIOFormat? {
    let inputFormat = engine.inputNode.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return nil }
    return AppleVoiceProcessingIOFormat(audioFormat: inputFormat)
  }

  func establish(matching format: AppleVoiceProcessingIOFormat) -> Bool {
    // VoiceProcessingIO couples the client-side input and output streams. On
    // macOS, the main mixer can renegotiate its output to the stereo hardware
    // layout during prepare/start even after a mono connection was requested.
    // A capture-only graph does not need a mixer or a render callback. An
    // attached but unplayed player supplies deterministic silence while still
    // allowing VoiceProcessingIO to pull its downlink side. Reuse the exact
    // input-node AVAudioFormat, including its native stream flags and channel
    // layout, because VPIO requires its client-side streams to remain matched.
    let outputNode = engine.outputNode
    engine.disconnectNodeInput(outputNode, bus: 0)
    if let silencePlayerNode {
      engine.disconnectNodeOutput(silencePlayerNode, bus: 0)
      engine.detach(silencePlayerNode)
    }

    let silencePlayerNode = AVAudioPlayerNode()
    engine.attach(silencePlayerNode)
    engine.connect(
      silencePlayerNode,
      to: outputNode,
      fromBus: 0,
      toBus: 0,
      format: format.audioFormat
    )
    self.silencePlayerNode = silencePlayerNode

    return isEstablished(matching: format)
  }

  func isEstablished(matching format: AppleVoiceProcessingIOFormat) -> Bool {
    guard let silencePlayerNode else { return false }
    let establishedFormat = engine.outputNode.inputFormat(forBus: 0)
    let connectionPoints = engine.outputConnectionPoints(for: silencePlayerNode, outputBus: 0)
    return format.matches(establishedFormat)
      && connectionPoints.contains { point in
        point.node === engine.outputNode && point.bus == 0
      }
  }
}

struct AppleVoiceProcessingEngineConfigurator {
  func configure(_ target: any AppleVoiceProcessingEngineConfigurationTarget) throws {
    guard !target.isRunning else {
      throw AppleVoiceProcessingAudioError.engineMustBeStopped
    }

    do {
      try target.setVoiceProcessingEnabled(true)
    } catch {
      throw AppleVoiceProcessingAudioError.voiceProcessingActivationFailed(
        error.localizedDescription
      )
    }

    guard
      target.isInputVoiceProcessingEnabled,
      target.isOutputVoiceProcessingEnabled
    else {
      throw AppleVoiceProcessingAudioError.voiceProcessingDidNotActivate
    }

    try target.configureVoiceProcessingInputDevice()

    guard let inputFormat = target.voiceProcessingInputFormat else {
      throw AppleVoiceProcessingAudioError.invalidInputFormat
    }

    guard target.establishVoiceProcessingOutputPath(matching: inputFormat) else {
      throw AppleVoiceProcessingAudioError.voiceProcessingOutputPathUnavailable
    }

    target.isVoiceProcessingBypassed = false
    guard !target.isVoiceProcessingBypassed else {
      throw AppleVoiceProcessingAudioError.voiceProcessingBypassCouldNotBeDisabled
    }

    target.isVoiceProcessingInputMuted = false
    guard !target.isVoiceProcessingInputMuted else {
      throw AppleVoiceProcessingAudioError.voiceProcessingInputCouldNotBeUnmuted
    }

    target.isVoiceProcessingAGCEnabled = true
    guard target.isVoiceProcessingAGCEnabled else {
      throw AppleVoiceProcessingAudioError.automaticGainControlDidNotActivate
    }
  }
}

struct AppleVoiceProcessingStartedState: Equatable, Sendable {
  let isRunning: Bool
  let isInputVoiceProcessingEnabled: Bool
  let isOutputVoiceProcessingEnabled: Bool
  let isVoiceProcessingBypassed: Bool
  let isVoiceProcessingInputMuted: Bool
  let isVoiceProcessingAGCEnabled: Bool
  let formatsRemainMatched: Bool
}

struct AppleVoiceProcessingStartedStateValidator {
  func validate(_ state: AppleVoiceProcessingStartedState) throws {
    guard state.isRunning else {
      throw AppleVoiceProcessingAudioError.engineDidNotStart
    }
    guard
      state.isInputVoiceProcessingEnabled,
      state.isOutputVoiceProcessingEnabled
    else {
      throw AppleVoiceProcessingAudioError.voiceProcessingDidNotActivate
    }
    guard !state.isVoiceProcessingBypassed else {
      throw AppleVoiceProcessingAudioError.voiceProcessingBypassCouldNotBeDisabled
    }
    guard !state.isVoiceProcessingInputMuted else {
      throw AppleVoiceProcessingAudioError.voiceProcessingInputCouldNotBeUnmuted
    }
    guard state.isVoiceProcessingAGCEnabled else {
      throw AppleVoiceProcessingAudioError.automaticGainControlDidNotActivate
    }
    guard state.formatsRemainMatched else {
      throw AppleVoiceProcessingAudioError.voiceProcessingFormatsDidNotRemainMatched
    }
  }
}

struct AppleVoiceProcessingConfigurationChangePolicy: Equatable, Sendable {
  private(set) var revision: UInt64 = 0
  private(set) var didCompleteStartValidation = false

  mutating func observeConfigurationChange() -> Bool {
    revision &+= 1
    return didCompleteStartValidation
  }

  mutating func completeStartValidation(ifRevisionMatches expectedRevision: UInt64) -> Bool {
    guard revision == expectedRevision else { return false }
    didCompleteStartValidation = true
    return true
  }

  var shouldFailCaptureOnChange: Bool {
    didCompleteStartValidation
  }
}

/// Tracks whether a retained VoiceProcessingIO engine can skip its expensive
/// graph configuration on the next normal start. Failures invalidate that
/// optimization so a route/format change cannot leave every later recording
/// stuck behind a stale, previously configured graph.
final class AppleVoiceProcessingConfigurationReuseState: @unchecked Sendable {
  private let lock = NSLock()
  private var configured = false

  var isConfigured: Bool {
    lock.withLock { configured }
  }

  var requiresConfiguration: Bool {
    lock.withLock { !configured }
  }

  func markConfigured() {
    lock.withLock {
      configured = true
    }
  }

  func invalidate() {
    lock.withLock {
      configured = false
    }
  }
}

struct AppleVoiceProcessingCaptureFormat: Equatable, Sendable {
  static let speechRecognition = AppleVoiceProcessingCaptureFormat(
    sampleRate: 16_000,
    channelCount: 1,
    bufferFrameCount: 1_600
  )

  let sampleRate: Double
  let channelCount: AVAudioChannelCount
  let bufferFrameCount: AVAudioFrameCount
}

struct AppleVoiceProcessingChannelSelection: Equatable, Sendable {
  let selectedChannel: Int
  let channelRMS: [Float]
}

enum AppleVoiceProcessingChannelSelector {
  static func select(channelSamples: [[Float]]) -> AppleVoiceProcessingChannelSelection? {
    guard !channelSamples.isEmpty else { return nil }
    return selection(channelRMS: channelSamples.map(rms))
  }

  static func select(
    from buffer: AVAudioPCMBuffer
  ) throws -> AppleVoiceProcessingChannelSelection {
    let channelCount = Int(buffer.format.channelCount)
    let frameLength = Int(buffer.frameLength)
    guard channelCount > 0, frameLength > 0 else {
      throw AppleVoiceProcessingAudioError.audioConversionFailed(
        "The microphone supplied an empty audio buffer."
      )
    }
    guard buffer.format.commonFormat == .pcmFormatFloat32,
      channelCount == 1 || !buffer.format.isInterleaved,
      let channelData = buffer.floatChannelData
    else {
      throw AppleVoiceProcessingAudioError.audioConversionFailed(
        "The microphone supplied an unsupported PCM layout: \(buffer.format)."
      )
    }

    var channelRMS: [Float] = []
    channelRMS.reserveCapacity(channelCount)
    for channelIndex in 0..<channelCount {
      var squaredSum = 0.0
      let samples = channelData[channelIndex]
      for frameIndex in 0..<frameLength {
        let sample = Double(samples[frameIndex])
        squaredSum += sample * sample
      }
      let value = Float((squaredSum / Double(frameLength)).squareRoot())
      channelRMS.append(value.isFinite ? value : 0)
    }
    return selection(channelRMS: channelRMS)
  }

  private static func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var squaredSum = 0.0
    for sample in samples {
      let value = Double(sample)
      squaredSum += value * value
    }
    let result = Float((squaredSum / Double(samples.count)).squareRoot())
    return result.isFinite ? result : 0
  }

  private static func selection(
    channelRMS: [Float]
  ) -> AppleVoiceProcessingChannelSelection {
    var selectedChannel = 0
    var selectedRMS = channelRMS[0]
    for channelIndex in channelRMS.indices.dropFirst()
    where channelRMS[channelIndex] > selectedRMS {
      selectedChannel = channelIndex
      selectedRMS = channelRMS[channelIndex]
    }
    return AppleVoiceProcessingChannelSelection(
      selectedChannel: selectedChannel,
      channelRMS: channelRMS
    )
  }
}

struct AppleVoiceProcessingCaptureDiagnostics: Equatable, Sendable {
  let inputFormatDescription: String
  let inputSampleRate: Double
  let inputChannelCount: AVAudioChannelCount
  let selectedChannel: Int
  let channelRMS: [Float]
  let outputRMS: Float
}

struct AppleVoiceProcessingCaptureConversion: Sendable {
  let samples: [Float]
  let diagnostics: AppleVoiceProcessingCaptureDiagnostics
  let shouldReportDiagnostics: Bool
}

final class AppleVoiceProcessingCaptureConverter: @unchecked Sendable {
  private let outputFormat: AVAudioFormat
  private let lock = NSLock()
  private var converter: AVAudioConverter?
  private var converterInputFormat: AVAudioFormat?
  private var lastReportedInputFormat: AVAudioFormat?
  private var lastReportedChannel: Int?

  init(outputFormat: AVAudioFormat) {
    self.outputFormat = outputFormat
  }

  func convert(_ buffer: AVAudioPCMBuffer) throws -> AppleVoiceProcessingCaptureConversion {
    lock.lock()
    defer { lock.unlock() }

    let selection = try AppleVoiceProcessingChannelSelector.select(from: buffer)
    let monoBuffer: AVAudioPCMBuffer
    if buffer.format.channelCount == 1 {
      monoBuffer = buffer
    } else {
      monoBuffer = try Self.copyChannel(selection.selectedChannel, from: buffer)
    }

    if converter == nil || converterInputFormat?.isEqual(monoBuffer.format) != true {
      guard let newConverter = AVAudioConverter(from: monoBuffer.format, to: outputFormat) else {
        throw AppleVoiceProcessingAudioError.converterCreationFailed
      }
      converter = newConverter
      converterInputFormat = monoBuffer.format
    }
    guard let converter else {
      throw AppleVoiceProcessingAudioError.converterCreationFailed
    }

    let convertedBuffer = try Self.resample(monoBuffer, with: converter, to: outputFormat)
    let samples = Self.floatSamples(from: convertedBuffer)
    guard samples.allSatisfy(\.isFinite) else {
      throw AppleVoiceProcessingAudioError.audioConversionFailed(
        "The microphone supplied non-finite PCM samples."
      )
    }
    let inputFormatChanged = lastReportedInputFormat?.isEqual(buffer.format) != true
    let selectedChannelChanged = lastReportedChannel != selection.selectedChannel
    let shouldReportDiagnostics = inputFormatChanged || selectedChannelChanged
    if shouldReportDiagnostics {
      lastReportedInputFormat = buffer.format
      lastReportedChannel = selection.selectedChannel
    }

    return AppleVoiceProcessingCaptureConversion(
      samples: samples,
      diagnostics: AppleVoiceProcessingCaptureDiagnostics(
        inputFormatDescription: buffer.format.description,
        inputSampleRate: buffer.format.sampleRate,
        inputChannelCount: buffer.format.channelCount,
        selectedChannel: selection.selectedChannel,
        channelRMS: selection.channelRMS,
        outputRMS: Self.rms(samples)
      ),
      shouldReportDiagnostics: shouldReportDiagnostics
    )
  }

  private static func floatSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
    guard let channel = buffer.floatChannelData?[0] else { return [] }
    return Array(
      UnsafeBufferPointer(
        start: channel,
        count: Int(buffer.frameLength)
      )
    )
  }

  private static func copyChannel(
    _ channelIndex: Int,
    from buffer: AVAudioPCMBuffer
  ) throws -> AVAudioPCMBuffer {
    guard
      buffer.format.commonFormat == .pcmFormatFloat32,
      !buffer.format.isInterleaved,
      channelIndex >= 0,
      channelIndex < Int(buffer.format.channelCount),
      let sourceChannels = buffer.floatChannelData,
      let monoFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: buffer.format.sampleRate,
        channels: 1,
        interleaved: false
      ),
      let monoBuffer = AVAudioPCMBuffer(
        pcmFormat: monoFormat,
        frameCapacity: buffer.frameLength
      ),
      let destination = monoBuffer.floatChannelData?[0]
    else {
      throw AppleVoiceProcessingAudioError.audioConversionFailed(
        "The selected microphone channel could not be isolated."
      )
    }

    monoBuffer.frameLength = buffer.frameLength
    destination.update(
      from: sourceChannels[channelIndex],
      count: Int(buffer.frameLength)
    )
    return monoBuffer
  }

  private static func resample(
    _ inputBuffer: AVAudioPCMBuffer,
    with converter: AVAudioConverter,
    to outputFormat: AVAudioFormat
  ) throws -> AVAudioPCMBuffer {
    let scale = outputFormat.sampleRate / inputBuffer.format.sampleRate
    let outputFrameCapacity = AVAudioFrameCount(
      max(1, ceil(Double(inputBuffer.frameLength) * scale) + 32)
    )
    guard
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: outputFrameCapacity
      )
    else {
      throw AppleVoiceProcessingAudioError.outputFormatCreationFailed
    }

    let inputSupply = AppleVoiceProcessingConverterInputSupply(inputBuffer)
    var conversionError: NSError?
    let status = converter.convert(to: outputBuffer, error: &conversionError) {
      _, inputStatus in
      inputSupply.take(status: inputStatus)
    }
    if status == .error || conversionError != nil {
      throw AppleVoiceProcessingAudioError.audioConversionFailed(
        conversionError?.localizedDescription ?? "AVAudioConverter returned an error."
      )
    }
    return outputBuffer
  }

  private static func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var squaredSum = 0.0
    for sample in samples {
      let value = Double(sample)
      squaredSum += value * value
    }
    let result = Float((squaredSum / Double(samples.count)).squareRoot())
    return result.isFinite ? result : 0
  }
}

private final class AppleVoiceProcessingConverterInputSupply: @unchecked Sendable {
  private let lock = NSLock()
  private var inputBuffer: AVAudioPCMBuffer?

  init(_ inputBuffer: AVAudioPCMBuffer) {
    self.inputBuffer = inputBuffer
  }

  func take(
    status: UnsafeMutablePointer<AVAudioConverterInputStatus>
  ) -> AVAudioBuffer? {
    lock.lock()
    defer { lock.unlock() }
    guard let inputBuffer else {
      status.pointee = .noDataNow
      return nil
    }
    self.inputBuffer = nil
    status.pointee = .haveData
    return inputBuffer
  }
}

protocol AppleVoiceProcessingAudioEngineSession: AnyObject {
  func configureVoiceProcessing() throws
  func start(
    format: AppleVoiceProcessingCaptureFormat,
    bufferHandler: @escaping @Sendable ([Float]) -> Void,
    failureHandler: @escaping @Sendable (AppleVoiceProcessingAudioError) -> Void
  ) throws
  func stop()
}

protocol AppleVoiceProcessingAudioEngineSessionFactory: Sendable {
  func makeSession(inputDeviceID: AppleVoiceProcessingInputDeviceID?)
    -> any AppleVoiceProcessingAudioEngineSession
}

struct LiveAppleVoiceProcessingAudioEngineSessionFactory:
  AppleVoiceProcessingAudioEngineSessionFactory
{
  func makeSession(inputDeviceID: AppleVoiceProcessingInputDeviceID?)
    -> any AppleVoiceProcessingAudioEngineSession
  {
    LiveAppleVoiceProcessingAudioEngineSession(inputDeviceID: inputDeviceID)
  }
}

private final class LiveAppleVoiceProcessingAudioEngineSession:
  AppleVoiceProcessingAudioEngineSession,
  AppleVoiceProcessingEngineConfigurationTarget,
  @unchecked Sendable
{
  private static let logger = Logger(
    subsystem: "dev.zrr.Rill",
    category: "voice-processing-capture"
  )

  private let engine: AVAudioEngine
  private let outputPath: AppleVoiceProcessingOutputPath
  private let inputDeviceID: AppleVoiceProcessingInputDeviceID?
  private let configurator = AppleVoiceProcessingEngineConfigurator()
  private let startedStateValidator = AppleVoiceProcessingStartedStateValidator()
  private let configurationReuseState = AppleVoiceProcessingConfigurationReuseState()
  private let tearDownLock = NSLock()
  private let configurationChangeLock = NSLock()
  private var isTapInstalled = false
  private var configurationChangeObserver: NSObjectProtocol?
  private var configurationChangePolicy = AppleVoiceProcessingConfigurationChangePolicy()

  init(inputDeviceID: AppleVoiceProcessingInputDeviceID?) {
    let engine = AVAudioEngine()
    self.engine = engine
    outputPath = AppleVoiceProcessingOutputPath(engine: engine)
    self.inputDeviceID = inputDeviceID
  }

  var isRunning: Bool { engine.isRunning }
  var isInputVoiceProcessingEnabled: Bool {
    engine.inputNode.isVoiceProcessingEnabled
  }
  var isOutputVoiceProcessingEnabled: Bool {
    engine.outputNode.isVoiceProcessingEnabled
  }
  var voiceProcessingInputFormat: AppleVoiceProcessingIOFormat? {
    outputPath.inputFormat
  }
  var isVoiceProcessingBypassed: Bool {
    get { engine.inputNode.isVoiceProcessingBypassed }
    set { engine.inputNode.isVoiceProcessingBypassed = newValue }
  }
  var isVoiceProcessingInputMuted: Bool {
    get { engine.inputNode.isVoiceProcessingInputMuted }
    set { engine.inputNode.isVoiceProcessingInputMuted = newValue }
  }
  var isVoiceProcessingAGCEnabled: Bool {
    get { engine.inputNode.isVoiceProcessingAGCEnabled }
    set { engine.inputNode.isVoiceProcessingAGCEnabled = newValue }
  }

  func setVoiceProcessingEnabled(_ isEnabled: Bool) throws {
    try engine.inputNode.setVoiceProcessingEnabled(isEnabled)
  }

  func configureVoiceProcessingInputDevice() throws {
    try configureInputDeviceIfNeeded()
  }

  func establishVoiceProcessingOutputPath(
    matching format: AppleVoiceProcessingIOFormat
  ) -> Bool {
    outputPath.establish(matching: format)
  }

  func configureVoiceProcessing() throws {
    guard configurationReuseState.requiresConfiguration else { return }
    do {
      try configurator.configure(self)
      configurationReuseState.markConfigured()
    } catch {
      configurationReuseState.invalidate()
      throw error
    }
  }

  func start(
    format: AppleVoiceProcessingCaptureFormat,
    bufferHandler: @escaping @Sendable ([Float]) -> Void,
    failureHandler: @escaping @Sendable (AppleVoiceProcessingAudioError) -> Void
  ) throws {
    guard configurationReuseState.isConfigured else {
      throw AppleVoiceProcessingAudioError.engineWasNotConfigured
    }
    guard !engine.isRunning else {
      throw AppleVoiceProcessingAudioError.engineMustBeStopped
    }

    let inputNode = engine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      throw AppleVoiceProcessingAudioError.invalidInputFormat
    }
    guard
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: format.sampleRate,
        channels: format.channelCount,
        interleaved: false
      )
    else {
      throw AppleVoiceProcessingAudioError.outputFormatCreationFailed
    }
    let captureConverter = AppleVoiceProcessingCaptureConverter(outputFormat: outputFormat)

    inputNode.installTap(
      onBus: 0,
      bufferSize: format.bufferFrameCount,
      format: nil
    ) { buffer, _ in
      do {
        let conversion = try captureConverter.convert(buffer)
        if conversion.shouldReportDiagnostics {
          let diagnostics = conversion.diagnostics
          let channelRMS = diagnostics.channelRMS
            .map { String(format: "%.6f", $0) }
            .joined(separator: ",")
          Self.logger.debug(
            "VPIO input format=\(diagnostics.inputFormatDescription, privacy: .public) selectedChannel=\(diagnostics.selectedChannel, privacy: .public) channelRMS=[\(channelRMS, privacy: .public)] outputRMS=\(diagnostics.outputRMS, privacy: .public)"
          )
        }
        bufferHandler(conversion.samples)
      } catch let error as AppleVoiceProcessingAudioError {
        failureHandler(error)
      } catch {
        failureHandler(.audioConversionFailed(error.localizedDescription))
      }
    }
    isTapInstalled = true

    do {
      configurationChangeLock.withLock {
        configurationChangePolicy = AppleVoiceProcessingConfigurationChangePolicy()
      }
      configurationChangeObserver = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange,
        object: engine,
        queue: nil
      ) { [weak self] _ in
        guard let self else { return }
        let shouldFailCapture = self.configurationChangeLock.withLock {
          self.configurationChangePolicy.observeConfigurationChange()
        }
        if shouldFailCapture {
          self.configurationReuseState.invalidate()
          failureHandler(.inputConfigurationChanged)
        }
      }
      engine.prepare()
      let preparedInputFormat = AppleVoiceProcessingIOFormat(
        audioFormat: inputNode.outputFormat(forBus: 0)
      )
      guard
        preparedInputFormat.matches(inputFormat),
        outputPath.isEstablished(matching: preparedInputFormat)
      else {
        throw AppleVoiceProcessingAudioError.voiceProcessingFormatsDidNotRemainMatched
      }
      try engine.start()
      var didCommitStableStartedState = false
      for _ in 0..<4 {
        let observedRevision = configurationChangeLock.withLock {
          configurationChangePolicy.revision
        }
        let startedInputFormat = AppleVoiceProcessingIOFormat(
          audioFormat: inputNode.outputFormat(forBus: 0)
        )
        do {
          try startedStateValidator.validate(
            AppleVoiceProcessingStartedState(
              isRunning: engine.isRunning,
              isInputVoiceProcessingEnabled: isInputVoiceProcessingEnabled,
              isOutputVoiceProcessingEnabled: isOutputVoiceProcessingEnabled,
              isVoiceProcessingBypassed: isVoiceProcessingBypassed,
              isVoiceProcessingInputMuted: isVoiceProcessingInputMuted,
              isVoiceProcessingAGCEnabled: isVoiceProcessingAGCEnabled,
              formatsRemainMatched: startedInputFormat.matches(inputFormat)
                && outputPath.isEstablished(matching: startedInputFormat)
            )
          )
        } catch {
          let changedDuringValidation = configurationChangeLock.withLock {
            configurationChangePolicy.revision != observedRevision
          }
          if changedDuringValidation { continue }
          throw error
        }
        didCommitStableStartedState = configurationChangeLock.withLock {
          configurationChangePolicy.completeStartValidation(
            ifRevisionMatches: observedRevision
          )
        }
        if didCommitStableStartedState { break }
      }
      guard didCommitStableStartedState else {
        throw AppleVoiceProcessingAudioError.inputConfigurationChanged
      }
    } catch {
      configurationReuseState.invalidate()
      tearDownEngine()
      throw error
    }
  }

  func stop() {
    tearDownEngine()
  }

  private func configureInputDeviceIfNeeded() throws {
    guard let inputDeviceID else { return }
    guard let audioUnit = engine.inputNode.audioUnit else {
      throw AppleVoiceProcessingAudioError.inputDeviceUnavailable
    }
    var mutableInputDeviceID = inputDeviceID
    let status = AudioUnitSetProperty(
      audioUnit,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &mutableInputDeviceID,
      UInt32(MemoryLayout<AppleVoiceProcessingInputDeviceID>.size)
    )
    guard status == noErr else {
      throw AppleVoiceProcessingAudioError.inputDeviceConfigurationFailed(status)
    }
  }

  private func tearDownEngine() {
    tearDownLock.lock()
    defer { tearDownLock.unlock() }

    guard engine.isRunning || isTapInstalled || configurationChangeObserver != nil else { return }
    if let configurationChangeObserver {
      NotificationCenter.default.removeObserver(configurationChangeObserver)
      self.configurationChangeObserver = nil
    }
    configurationChangeLock.withLock {
      configurationChangePolicy = AppleVoiceProcessingConfigurationChangePolicy()
    }
    engine.stop()
    if isTapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      isTapInstalled = false
    }
    engine.reset()
  }
}

/// Project-owned capture surface for the VoiceProcessingIO microphone frontend.
///
/// Model runtimes consume the resulting 16 kHz mono WAV through Rill's
/// `AudioCaptureService`; this type deliberately has no speech-model or
/// tokenizer responsibilities.
protocol AppleVoiceProcessingAudioCapturing: AnyObject, Sendable {
  var endpointRMS: [Float] { get }

  func startStreamingRecordingLive(
    inputDeviceID: AppleVoiceProcessingInputDeviceID?
  ) -> (
    AsyncThrowingStream<[Float], Error>,
    AsyncThrowingStream<[Float], Error>.Continuation
  )
  func stopRecording()
}

final class AppleVoiceProcessingAudioProcessor:
  AppleVoiceProcessingAudioCapturing,
  @unchecked Sendable
{
  enum AsynchronousTeardownReason: Sendable, Equatable {
    case streamTermination
    case producerFailure
  }

  private final class SessionTeardownToken: @unchecked Sendable {}

  /// At the largest supported 16 kHz callback this bounds queued PCM to about
  /// 200 KiB. A full queue is a capture failure, never permission to lose PCM.
  static let maximumBufferedPCMChunkCount = 32
  static let maximumRetainedEndpointRMSSampleCount = 20

  private struct RetainedSession {
    let inputDeviceID: AppleVoiceProcessingInputDeviceID?
    let session: any AppleVoiceProcessingAudioEngineSession
  }

  private let sessionFactory: any AppleVoiceProcessingAudioEngineSessionFactory
  private let streamOverflowDetectedHook: @Sendable () -> Void
  private let producerFailureClaimedHook: @Sendable () -> Void
  private let asynchronousTeardownHook: @Sendable (AsynchronousTeardownReason) -> Void
  private let stateLock = NSLock()
  private let lifecycleLock = NSLock()

  private var pendingEnergySquaredSum = Double.zero
  private var pendingEnergySampleCount = 0
  private var endpointRMSSamples: [Float] = []
  private var captureGeneration: UInt64 = 0
  private var bufferCallback:
    (@Sendable ([Float]) -> AppleVoiceProcessingPCMStreamTerminalState.YieldDisposition)?
  private var streamTerminalState: AppleVoiceProcessingPCMStreamTerminalState?
  private var streamFailureCallback: (@Sendable (AppleVoiceProcessingAudioError) -> Void)?
  private var session: (any AppleVoiceProcessingAudioEngineSession)?
  private var activeSessionTeardownToken: SessionTeardownToken?
  private var retainedSessions: [RetainedSession] = []

  init(
    sessionFactory: any AppleVoiceProcessingAudioEngineSessionFactory =
      LiveAppleVoiceProcessingAudioEngineSessionFactory(),
    streamOverflowDetectedHook: @escaping @Sendable () -> Void = {},
    producerFailureClaimedHook: @escaping @Sendable () -> Void = {},
    asynchronousTeardownHook:
      @escaping @Sendable (AsynchronousTeardownReason) -> Void = { _ in }
  ) {
    self.sessionFactory = sessionFactory
    self.streamOverflowDetectedHook = streamOverflowDetectedHook
    self.producerFailureClaimedHook = producerFailureClaimedHook
    self.asynchronousTeardownHook = asynchronousTeardownHook
  }

  deinit {
    for retainedSession in retainedSessions {
      retainedSession.session.stop()
    }
  }

  var endpointRMS: [Float] {
    withStateLock { endpointRMSSamples }
  }

  var retainedEnergySampleCount: Int {
    withStateLock { pendingEnergySampleCount }
  }

  /// Configures and retains the VoiceProcessingIO graph while its engine is
  /// stopped. Callers must gate this on an already-authorized microphone;
  /// this method never requests permission or starts audio I/O.
  func prepareRecordingFrontend(
    inputDeviceID: AppleVoiceProcessingInputDeviceID?
  ) throws {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    guard session == nil else { return }
    try retainedSession(for: inputDeviceID).configureVoiceProcessing()
  }

  func startStreamingRecordingLive(
    inputDeviceID: AppleVoiceProcessingInputDeviceID?
  ) -> (
    AsyncThrowingStream<[Float], Error>,
    AsyncThrowingStream<[Float], Error>.Continuation
  ) {
    startStreamingRecordingLive(
      inputDeviceID: inputDeviceID,
      terminalState: AppleVoiceProcessingPCMStreamTerminalState()
    )
  }

  func startStreamingRecordingLive(
    inputDeviceID: AppleVoiceProcessingInputDeviceID?,
    terminalState: AppleVoiceProcessingPCMStreamTerminalState
  ) -> (
    AsyncThrowingStream<[Float], Error>,
    AsyncThrowingStream<[Float], Error>.Continuation
  ) {
    let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream(
      bufferingPolicy: .bufferingOldest(Self.maximumBufferedPCMChunkCount)
    )
    lifecycleLock.lock()
    do {
      let teardownToken = try activateSession(
        inputDeviceID: inputDeviceID,
        terminalState: terminalState,
        callback: { samples in
          terminalState.yield(samples, to: continuation)
        },
        failureCallback: { error in
          Task {
            continuation.finish(throwing: error)
          }
        }
      )
      continuation.onTermination = { [weak self] _ in
        Task { [weak self] in
          guard let self else { return }
          self.stopRecording(teardownToken: teardownToken)
          self.asynchronousTeardownHook(.streamTermination)
        }
      }
      lifecycleLock.unlock()
    } catch {
      lifecycleLock.unlock()
      continuation.finish(throwing: error)
    }
    return (stream, continuation)
  }

  func stopRecording() {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    stopSession()
  }

  func shutdown() {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }

    let sessions = retainedSessions
    retainedSessions.removeAll()
    session = nil
    activeSessionTeardownToken = nil
    withStateLock {
      captureGeneration &+= 1
      pendingEnergySquaredSum = 0
      pendingEnergySampleCount = 0
      endpointRMSSamples.removeAll(keepingCapacity: false)
      bufferCallback = nil
      streamTerminalState = nil
      streamFailureCallback = nil
    }
    for retainedSession in sessions {
      retainedSession.session.stop()
    }
  }

  private func stopRecording(teardownToken: SessionTeardownToken) {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    guard activeSessionTeardownToken === teardownToken else { return }
    stopSession()
  }

  private func activateSession(
    inputDeviceID: AppleVoiceProcessingInputDeviceID?,
    terminalState: AppleVoiceProcessingPCMStreamTerminalState,
    callback:
      (@Sendable ([Float]) -> AppleVoiceProcessingPCMStreamTerminalState.YieldDisposition)?,
    failureCallback: (@Sendable (AppleVoiceProcessingAudioError) -> Void)?
  ) throws -> SessionTeardownToken {
    stopSession()
    let teardownToken = SessionTeardownToken()
    let generation = withStateLock { () -> UInt64 in
      pendingEnergySquaredSum = 0
      pendingEnergySampleCount = 0
      endpointRMSSamples.removeAll(keepingCapacity: true)
      bufferCallback = callback
      streamTerminalState = terminalState
      streamFailureCallback = failureCallback
      return captureGeneration
    }

    let newSession = retainedSession(for: inputDeviceID)
    // Retain the VPIO engine before configuration begins. CoreAudio can still
    // have property-listener callbacks in flight when prepare/start fails; an
    // engine released while those callbacks drain can crash inside
    // AVAudioIOUnit::IOUnitPropertyListener.
    session = newSession
    activeSessionTeardownToken = teardownToken
    do {
      try newSession.configureVoiceProcessing()
      do {
        try start(
          newSession,
          generation: generation,
          teardownToken: teardownToken
        )
      } catch let error as AppleVoiceProcessingAudioError
        where error.permitsOneStartReconfigurationAttempt
      {
        // A retained VPIO graph can become stale while stopped because no
        // active-capture configuration observer exists during that interval.
        // The failed start invalidates the live session's reuse state; stop
        // defensively, rebuild once, and retry inside this user action.
        newSession.stop()
        try newSession.configureVoiceProcessing()
        try start(
          newSession,
          generation: generation,
          teardownToken: teardownToken
        )
      }
      return teardownToken
    } catch {
      newSession.stop()
      session = nil
      activeSessionTeardownToken = nil
      withStateLock {
        captureGeneration &+= 1
        bufferCallback = nil
        streamTerminalState = nil
        streamFailureCallback = nil
      }
      throw error
    }
  }

  private func start(
    _ engineSession: any AppleVoiceProcessingAudioEngineSession,
    generation: UInt64,
    teardownToken: SessionTeardownToken
  ) throws {
    try engineSession.start(
      format: .speechRecognition,
      bufferHandler: { [weak self] buffer in
        self?.process(
          buffer,
          generation: generation,
          teardownToken: teardownToken
        )
      },
      failureHandler: { [weak self] error in
        self?.handleSessionFailure(
          error,
          generation: generation,
          teardownToken: teardownToken
        )
      }
    )
  }

  private func retainedSession(
    for inputDeviceID: AppleVoiceProcessingInputDeviceID?
  ) -> any AppleVoiceProcessingAudioEngineSession {
    if let retainedSession = retainedSessions.first(where: {
      $0.inputDeviceID == inputDeviceID
    }) {
      return retainedSession.session
    }
    let newSession = sessionFactory.makeSession(inputDeviceID: inputDeviceID)
    retainedSessions.append(
      RetainedSession(inputDeviceID: inputDeviceID, session: newSession)
    )
    return newSession
  }

  private func stopSession() {
    let activeSession = session
    session = nil
    activeSessionTeardownToken = nil
    withStateLock {
      captureGeneration &+= 1
      bufferCallback = nil
      streamTerminalState = nil
      streamFailureCallback = nil
    }
    activeSession?.stop()
  }

  private func process(
    _ buffer: [Float],
    generation: UInt64,
    teardownToken: SessionTeardownToken
  ) {
    guard !buffer.isEmpty else { return }
    let callback = withStateLock {
      () -> (@Sendable ([Float]) -> AppleVoiceProcessingPCMStreamTerminalState.YieldDisposition)? in
      guard generation == captureGeneration else { return nil }

      // The AVAudioEngine tap's requested frame count is expressed in the
      // device input format. A 1,600-frame tap at 48 kHz therefore produces
      // only about 533 samples after conversion to 16 kHz. Endpoint timing
      // must be derived from exact 16 kHz output frames, not callback count.
      let energyFrameLength = Int(
        AppleVoiceProcessingCaptureFormat.speechRecognition.bufferFrameCount
      )
      for sample in buffer {
        let value = Double(sample)
        pendingEnergySquaredSum += value * value
        pendingEnergySampleCount += 1
        if pendingEnergySampleCount == energyFrameLength {
          let rms = Float(
            (pendingEnergySquaredSum / Double(pendingEnergySampleCount)).squareRoot()
          )
          endpointRMSSamples.append(rms.isFinite ? rms : 0)
          pendingEnergySquaredSum = 0
          pendingEnergySampleCount = 0
        }
      }
      if endpointRMSSamples.count > Self.maximumRetainedEndpointRMSSampleCount {
        endpointRMSSamples.removeFirst(
          endpointRMSSamples.count - Self.maximumRetainedEndpointRMSSampleCount
        )
      }
      return bufferCallback
    }
    guard let callback else { return }
    switch callback(buffer) {
    case .enqueued, .terminated:
      return
    case .dropped:
      // AsyncThrowingStream does not suspend its producer. Seal this capture
      // synchronously on the CoreAudio callback, then stop the engine and
      // finish the stream off-thread through the existing failure path.
      streamOverflowDetectedHook()
      handleSessionFailure(
        .streamBufferOverflow,
        generation: generation,
        teardownToken: teardownToken
      )
    }
  }

  static func endpointRelativeEnergy(fromNormalizedRMS rms: Float) -> Float {
    min(max(rms / 0.05, 0), 1)
  }

  private func handleSessionFailure(
    _ error: AppleVoiceProcessingAudioError,
    generation: UInt64,
    teardownToken: SessionTeardownToken
  ) {
    let outcome = withStateLock {
      () -> (
        accepted: Bool,
        terminalError: AppleVoiceProcessingAudioError?,
        completion: (@Sendable (AppleVoiceProcessingAudioError) -> Void)?
      ) in
      guard generation == captureGeneration,
        let terminalState = streamTerminalState,
        let terminalError = terminalState.claimProducerFailure(error)
      else {
        return (false, nil, nil)
      }
      // This hook is empty in production. Tests block here to prove that the
      // producer failure owns the terminal boundary before processor state is
      // generation-sealed, so a concurrent finish cannot hide the failure.
      producerFailureClaimedHook()
      captureGeneration &+= 1
      bufferCallback = nil
      streamTerminalState = nil
      let completion = streamFailureCallback
      streamFailureCallback = nil
      return (true, terminalError, completion)
    }
    guard outcome.accepted, let terminalError = outcome.terminalError else { return }
    Task { [weak self] in
      guard let self else {
        outcome.completion?(terminalError)
        return
      }
      self.asynchronousTeardownHook(.producerFailure)
      self.stopRecording(teardownToken: teardownToken)
      outcome.completion?(terminalError)
    }
  }

  private func withStateLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
    stateLock.lock()
    defer { stateLock.unlock() }
    return try operation()
  }
}
