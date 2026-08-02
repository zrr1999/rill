@preconcurrency import AVFoundation
import Foundation
import RillCore

public enum SpeechPlaybackError: Error, LocalizedError, Sendable {
  case invalidAsset
  case playbackFailed

  public var errorDescription: String? {
    switch self {
    case .invalidAsset:
      return "The synthesized speech asset is invalid."
    case .playbackFailed:
      return "The synthesized speech could not be played."
    }
  }
}

@MainActor
public final class AVSpeechPlaybackService: NSObject, SpeechPlaybackService,
  @MainActor AVAudioPlayerDelegate
{
  private var player: AVAudioPlayer?
  private var activeRunID: UUID?
  private var continuation: CheckedContinuation<Void, Error>?

  public override init() {
    super.init()
  }

  public var isPlaying: Bool {
    activeRunID != nil
  }

  public func play(_ asset: SpeechAsset, runID: UUID) async throws {
    guard FileManager.default.isReadableFile(atPath: asset.fileURL.path) else {
      throw SpeechPlaybackError.invalidAsset
    }
    stopActive(with: CancellationError())
    let player: AVAudioPlayer
    do {
      player = try AVAudioPlayer(contentsOf: asset.fileURL)
    } catch {
      throw SpeechPlaybackError.invalidAsset
    }
    player.delegate = self
    guard player.prepareToPlay() else {
      throw SpeechPlaybackError.playbackFailed
    }
    self.player = player
    activeRunID = runID
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        guard player.play() else {
          stopActive(with: SpeechPlaybackError.playbackFailed)
          return
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard self?.activeRunID == runID else { return }
        self?.stopActive(with: CancellationError())
      }
    }
  }

  public func stop(runID: UUID) async {
    guard activeRunID == runID else { return }
    stopActive(with: CancellationError())
  }

  public func shutdown() async {
    stopActive(with: CancellationError())
  }

  public func audioPlayerDidFinishPlaying(
    _ player: AVAudioPlayer,
    successfully flag: Bool
  ) {
    guard player === self.player else { return }
    finish(
      flag
        ? .success(())
        : .failure(SpeechPlaybackError.playbackFailed)
    )
  }

  public func audioPlayerDecodeErrorDidOccur(
    _ player: AVAudioPlayer,
    error: Error?
  ) {
    guard player === self.player else { return }
    finish(.failure(error ?? SpeechPlaybackError.playbackFailed))
  }

  private func stopActive(with error: Error) {
    player?.stop()
    finish(.failure(error))
  }

  private func finish(_ result: Result<Void, Error>) {
    player?.delegate = nil
    player = nil
    activeRunID = nil
    let continuation = continuation
    self.continuation = nil
    continuation?.resume(with: result)
  }
}
