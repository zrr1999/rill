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
  private let removeTemporaryAsset: @Sendable (SpeechAsset) throws -> Void
  private let playbackStateChanged: @Sendable (Bool) async -> Void

  public init(
    synthesizer: any SpeechSynthesizer,
    playback: any SpeechPlaybackService,
    removeTemporaryAsset: @escaping @Sendable (SpeechAsset) throws -> Void,
    playbackStateChanged: @escaping @Sendable (Bool) async -> Void = { _ in }
  ) {
    self.synthesizer = synthesizer
    self.playback = playback
    self.removeTemporaryAsset = removeTemporaryAsset
    self.playbackStateChanged = playbackStateChanged
  }

  public func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
      let text = try record.requireText(for: id)
    let configuration: SpeechActionConfiguration
    do {
      guard case .speech(let resolved) = try context.configuration(for: id) else {
        return .failed(SpeechSynthesisActionError.invalidRequest.localizedDescription)
      }
      configuration = resolved
    } catch { return .failed(SpeechSynthesisActionError.invalidRequest.localizedDescription) }
    let request = SpeechSynthesisRequest(runID: context.runID, text: text, provider: configuration.provider,
      modelID: configuration.model, voice: configuration.voice, language: configuration.language)
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
      try? removeTemporaryAsset(asset)
      return .externalOutput("Speech")
    } catch is CancellationError {
      await playbackStateChanged(false)
      try? removeTemporaryAsset(asset)
      throw CancellationError()
    } catch {
      await playbackStateChanged(false)
      try? removeTemporaryAsset(asset)
      return .failed(SpeechSynthesisActionError.playbackFailed.localizedDescription)
    }
  }
}
