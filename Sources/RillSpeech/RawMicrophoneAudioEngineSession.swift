import RillSpeechContracts
@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import OSLog

/// Supplies unprocessed microphone PCM to the process-wide KWS/STT hub.
///
/// The existing processor still owns lifecycle, buffering, endpoint energy,
/// and restart behavior. This factory changes only the physical frontend:
/// VoiceProcessingIO is intentionally not enabled because its speech DSP can
/// attenuate a wake phrase by tens of decibels during continuous capture.
struct LiveRawMicrophoneAudioEngineSessionFactory:
  AppleVoiceProcessingAudioEngineSessionFactory
{
  func makeSession(inputDeviceID: AppleVoiceProcessingInputDeviceID?)
    -> any AppleVoiceProcessingAudioEngineSession
  {
    LiveRawMicrophoneAudioEngineSession(inputDeviceID: inputDeviceID)
  }
}

private final class LiveRawMicrophoneAudioEngineSession:
  AppleVoiceProcessingAudioEngineSession,
  @unchecked Sendable
{
  private static let logger = Logger(
    subsystem: "dev.zrr.Rill",
    category: "raw-microphone-capture"
  )

  private let engine = AVAudioEngine()
  private let inputDeviceID: AppleVoiceProcessingInputDeviceID?
  private let configurationReuseState = AppleVoiceProcessingConfigurationReuseState()
  private let tearDownLock = NSLock()
  private let configurationChangeLock = NSLock()
  private let diagnosticsLock = NSLock()

  private var configuredInputFormat: AppleVoiceProcessingIOFormat?
  private var isTapInstalled = false
  private var configurationChangeObserver: NSObjectProtocol?
  private var configurationChangePolicy = AppleVoiceProcessingConfigurationChangePolicy()
  private var lastDiagnosticsUptime = TimeInterval.zero

  init(inputDeviceID: AppleVoiceProcessingInputDeviceID?) {
    self.inputDeviceID = inputDeviceID
  }

  func configureVoiceProcessing() throws {
    guard configurationReuseState.requiresConfiguration else { return }
    guard !engine.isRunning else {
      throw AppleVoiceProcessingAudioError.engineMustBeStopped
    }

    do {
      try configureInputDeviceIfNeeded()
      let inputFormat = engine.inputNode.outputFormat(forBus: 0)
      guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
        throw AppleVoiceProcessingAudioError.invalidInputFormat
      }
      configuredInputFormat = AppleVoiceProcessingIOFormat(audioFormat: inputFormat)
      configurationReuseState.markConfigured()
    } catch {
      configuredInputFormat = nil
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
    guard configuredInputFormat?.matches(inputFormat) == true else {
      configurationReuseState.invalidate()
      throw AppleVoiceProcessingAudioError.inputConfigurationChanged
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
    ) { [weak self] buffer, _ in
      do {
        let conversion = try captureConverter.convert(buffer)
        if self?.shouldReportDiagnostics(conversion) == true {
          let diagnostics = conversion.diagnostics
          let channelRMS = diagnostics.channelRMS
            .map { String(format: "%.6f", $0) }
            .joined(separator: ",")
          Self.logger.debug(
            "Raw input format=\(diagnostics.inputFormatDescription, privacy: .public) selectedChannel=\(diagnostics.selectedChannel, privacy: .public) channelRMS=[\(channelRMS, privacy: .public)] outputRMS=\(diagnostics.outputRMS, privacy: .public)"
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
      guard inputNode.outputFormat(forBus: 0).isEqual(inputFormat) else {
        throw AppleVoiceProcessingAudioError.inputConfigurationChanged
      }
      try engine.start()
      guard engine.isRunning else {
        throw AppleVoiceProcessingAudioError.engineDidNotStart
      }

      var didCommitStableStartedState = false
      for _ in 0..<4 {
        let observedRevision = configurationChangeLock.withLock {
          configurationChangePolicy.revision
        }
        guard inputNode.outputFormat(forBus: 0).isEqual(inputFormat) else {
          throw AppleVoiceProcessingAudioError.inputConfigurationChanged
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
      tearDownEngine(preserveConfiguration: false)
      throw error
    }
  }

  func stop() {
    tearDownEngine(preserveConfiguration: configurationReuseState.isConfigured)
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

  private func shouldReportDiagnostics(
    _ conversion: AppleVoiceProcessingCaptureConversion
  ) -> Bool {
    diagnosticsLock.withLock {
      let now = ProcessInfo.processInfo.systemUptime
      let isAudible = conversion.diagnostics.outputRMS >= 0.001
      guard conversion.shouldReportDiagnostics
        || (isAudible && now - lastDiagnosticsUptime >= 0.5)
      else {
        return false
      }
      lastDiagnosticsUptime = now
      return true
    }
  }

  private func tearDownEngine(preserveConfiguration: Bool) {
    tearDownLock.lock()
    defer { tearDownLock.unlock() }

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
    guard !preserveConfiguration else { return }

    configuredInputFormat = nil
    configurationReuseState.invalidate()
  }
}
