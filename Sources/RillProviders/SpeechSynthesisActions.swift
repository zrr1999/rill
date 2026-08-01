import Foundation
import RillCore

public struct AutomaticSpeechSynthesizer: SpeechSynthesizer {
  public let id = "speech.automatic"
  private let preferred: (any SpeechSynthesizer)?
  private let fallback: any SpeechSynthesizer

  public init(
    preferred: (any SpeechSynthesizer)?,
    fallback: any SpeechSynthesizer
  ) {
    self.preferred = preferred
    self.fallback = fallback
  }

  public func synthesize(_ request: SpeechSynthesisRequest) async throws -> SpeechAsset {
    switch request.provider {
    case .system:
      return try await fallback.synthesize(request)
    case .qwen3:
      guard let preferred else {
        throw SpeechSynthesisActionError.preferredProviderUnavailable
      }
      return try await preferred.synthesize(request)
    case .automatic:
      guard let preferred else {
        return try await fallback.synthesize(request)
      }
      do {
        return try await preferred.synthesize(request)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        return try await fallback.synthesize(request)
      }
    }
  }

  public func releaseResources() async {
    await preferred?.releaseResources()
    await fallback.releaseResources()
  }
}

public enum SpeechSynthesisActionError: Error, LocalizedError, Sendable {
  case invalidRequest
  case preferredProviderUnavailable
  case synthesisFailed
  case playbackFailed

  public var errorDescription: String? {
    switch self {
    case .invalidRequest:
      return "The speech output action contains an invalid request."
    case .preferredProviderUnavailable:
      return "Qwen3-TTS is not available in this build."
    case .synthesisFailed:
      return "Speech synthesis could not complete."
    case .playbackFailed:
      return "Speech playback could not complete."
    }
  }
}

public struct SpeakTextAction: OutputAction {
  public let id = SpeechOutputActionID.speak
  private let synthesizer: any SpeechSynthesizer
  private let playback: any SpeechPlaybackService
  private let playbackStateChanged: @Sendable (Bool) async -> Void

  public init(
    synthesizer: any SpeechSynthesizer,
    playback: any SpeechPlaybackService,
    playbackStateChanged: @escaping @Sendable (Bool) async -> Void = { _ in }
  ) {
    self.synthesizer = synthesizer
    self.playback = playback
    self.playbackStateChanged = playbackStateChanged
  }

  public func execute(text: String, context: ActionContext) async throws -> ActionResult {
    let configuration =
      context.workflow.plan.output.actions.first { $0.id == id }?.configuration
      ?? [:]
    let provider =
      configuration[SpeechOutputActionConfigurationKey.provider]
        .flatMap(SpeechSynthesisProvider.init(rawValue:))
      ?? .automatic
    let request = SpeechSynthesisRequest(
      runID: context.runID,
      text: text,
      provider: provider,
      voice:
        configuration[SpeechOutputActionConfigurationKey.voice]
        ?? Qwen3TTSVoice.vivian.rawValue,
      language: configuration[SpeechOutputActionConfigurationKey.language]
    )
    guard request.isValid else {
      return .failed(SpeechSynthesisActionError.invalidRequest.localizedDescription)
    }

    let asset: SpeechAsset
    do {
      asset = try await synthesizer.synthesize(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .failed(SpeechSynthesisActionError.synthesisFailed.localizedDescription)
    }

    await playbackStateChanged(true)
    do {
      try await playback.play(asset, runID: context.runID)
      await playbackStateChanged(false)
      _ = try? asset.removeManagedTemporaryFile()
      return .externalOutput("Speech")
    } catch is CancellationError {
      await playbackStateChanged(false)
      _ = try? asset.removeManagedTemporaryFile()
      throw CancellationError()
    } catch {
      await playbackStateChanged(false)
      _ = try? asset.removeManagedTemporaryFile()
      return .failed(SpeechSynthesisActionError.playbackFailed.localizedDescription)
    }
  }
}
