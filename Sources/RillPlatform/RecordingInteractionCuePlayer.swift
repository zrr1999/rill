import AVFoundation
import Foundation
import RillCore

public final class RecordingCuePlayback: @unchecked Sendable {
  private let lock = NSLock()
  private var finished = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public func wait() async {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        lock.withLock {
          if finished {
            continuation.resume()
          } else {
            waiters.append(continuation)
          }
        }
      }
    } onCancel: {
      self.finish()
    }
  }

  func finish() {
    let pending = lock.withLock {
      finished = true
      let pending = waiters
      waiters.removeAll()
      return pending
    }
    for waiter in pending { waiter.resume() }
  }
}

enum RecordingInteractionCueToneRenderer {
  static let sampleRate = 48_000.0

  static func samples(for cue: RecordingInteractionCue) -> [Float] {
    let durationSeconds: Double
    let startFrequency: Double
    let endFrequency: Double
    switch cue {
    case .started:
      durationSeconds = 0.055
      startFrequency = 660
      endFrequency = 990
    case .stopped:
      durationSeconds = 0.065
      startFrequency = 740
      endFrequency = 440
    }

    let sampleCount = Int(sampleRate * durationSeconds)
    var samples = [Float](repeating: 0, count: sampleCount)
    var phase = 0.0

    for index in samples.indices {
      let progress = Double(index) / Double(max(1, sampleCount - 1))
      let frequency = startFrequency + ((endFrequency - startFrequency) * progress)
      phase += (2 * Double.pi * frequency) / sampleRate

      let attack = min(1, progress / 0.12)
      let release = min(1, (1 - progress) / 0.28)
      let envelope = sin(Double.pi * min(attack, release) / 2)
      samples[index] = Float(sin(phase) * envelope * 0.10)
    }

    return samples
  }
}

/// Plays short, asset-free recording earcons through the app's audio process.
///
/// Buffers are generated once. The returned playback completes at the device
/// boundary, allowing microphone startup to follow the audible start cue.
@MainActor
public final class RecordingInteractionCuePlayer {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let buffers: [RecordingInteractionCue: AVAudioPCMBuffer]
  private var activePlayback: RecordingCuePlayback?

  public init() {
    let format = AVAudioFormat(
      standardFormatWithSampleRate: RecordingInteractionCueToneRenderer.sampleRate,
      channels: 1
    )!
    buffers = Dictionary(
      uniqueKeysWithValues: [
        RecordingInteractionCue.started,
        .stopped,
      ].compactMap { cue in
        Self.makeBuffer(
          samples: RecordingInteractionCueToneRenderer.samples(for: cue),
          format: format
        ).map { (cue, $0) }
      }
    )

    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    engine.prepare()
  }

  @discardableResult
  public func play(_ cue: RecordingInteractionCue) -> RecordingCuePlayback? {
    guard let buffer = buffers[cue] else { return nil }
    stop()
    if !engine.isRunning {
      do {
        try engine.start()
      } catch {
        return nil
      }
    }

    let playback = RecordingCuePlayback()
    activePlayback = playback
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
      playback.finish()
    }
    player.play()
    return playback
  }

  public func stop() {
    player.stop()
    activePlayback?.finish()
    activePlayback = nil
  }

  private static func makeBuffer(
    samples: [Float],
    format: AVAudioFormat
  ) -> AVAudioPCMBuffer? {
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(samples.count)
      ),
      let channel = buffer.floatChannelData?.pointee
    else {
      return nil
    }

    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      guard let baseAddress = source.baseAddress else { return }
      channel.update(from: baseAddress, count: samples.count)
    }
    return buffer
  }
}
