import AVFoundation
import RillCore

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
/// The buffers are generated once and the engine is prepared eagerly so the
/// confirmed recording transition does not wait on file I/O or sound decoding.
@MainActor
public final class RecordingInteractionCuePlayer {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let buffers: [RecordingInteractionCue: AVAudioPCMBuffer]

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

  public func play(_ cue: RecordingInteractionCue) {
    guard let buffer = buffers[cue] else { return }
    if !engine.isRunning {
      do {
        try engine.start()
      } catch {
        return
      }
    }

    player.stop()
    player.scheduleBuffer(buffer, at: nil, options: .interrupts)
    player.play()
  }

  public func stop() {
    player.stop()
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
