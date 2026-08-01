import Foundation

/// Applies a small, KWS-only gain after VoiceProcessingIO.
///
/// The shared microphone stream intentionally remains untouched so recording
/// and STT preserve their existing levels. Sherpa's short-keyword decoder is
/// noticeably more level-sensitive than the downstream ASR path, especially
/// for a speaker more than arm's length from the built-in microphone.
enum WakeWordAudioConditioner {
  /// Up to +10 dB, while keeping loud input below the normalized PCM ceiling.
  static let maximumLinearGain: Float = 3.162_277_7
  static let targetPeak: Float = 0.95

  static func prepare(_ samples: [Float]) -> [Float] {
    let peak = samples.reduce(Float.zero) { currentPeak, sample in
      guard sample.isFinite else { return currentPeak }
      return max(currentPeak, abs(sample))
    }
    let headroomLimitedGain =
      peak > 0 ? max(1, targetPeak / peak) : maximumLinearGain
    let gain = min(maximumLinearGain, headroomLimitedGain)

    return samples.map { sample in
      guard sample.isFinite else { return Float.zero }
      return min(max(sample * gain, Float(-1)), Float(1))
    }
  }
}
