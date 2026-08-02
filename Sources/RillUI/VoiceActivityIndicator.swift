import SwiftUI

public struct VoiceActivityIndicator: View {
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

  public let levelMeter: [Float]
  public let isActive: Bool
  public let accentColor: Color
  public let barCount: Int
  public let barWidth: CGFloat
  public let barSpacing: CGFloat
  public let minHeight: CGFloat
  public let maxHeight: CGFloat

  public init(
    levelMeter: [Float],
    isActive: Bool,
    accentColor: Color = .purple,
    barCount: Int = 12,
    barWidth: CGFloat = 4,
    barSpacing: CGFloat = 3,
    minHeight: CGFloat = 6,
    maxHeight: CGFloat = 28
  ) {
    self.levelMeter = levelMeter
    self.isActive = isActive
    self.accentColor = accentColor
    self.barCount = barCount
    self.barWidth = barWidth
    self.barSpacing = barSpacing
    self.minHeight = minHeight
    self.maxHeight = maxHeight
  }

  public var body: some View {
    let levels = Self.displayedLevels(levelMeter, barCount: barCount, isActive: isActive)

    HStack(alignment: .center, spacing: barSpacing) {
      ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .fill(barGradient(for: index))
          .frame(width: barWidth, height: barHeight(for: level))
          .opacity(Self.barOpacity(for: level))
      }
    }
    .frame(height: maxHeight, alignment: .center)
    .animation(Self.meterAnimation(reduceMotion: accessibilityReduceMotion), value: levels)
    .accessibilityHidden(true)
  }

  private func barHeight(for level: Float) -> CGFloat {
    minHeight + CGFloat(level) * (maxHeight - minHeight)
  }

  static func displayedLevels(
    _ levels: [Float],
    barCount: Int,
    isActive: Bool = true
  ) -> [Float] {
    guard barCount > 0 else { return [] }
    guard isActive else { return Array(repeating: 0, count: barCount) }
    let samples = Array(levels.suffix(barCount)).map { level in
      level.isFinite ? max(0, min(level, 1)) : 0
    }
    let padding = max(barCount - samples.count, 0)

    // An animated waveform without measured levels falsely implies that
    // microphone samples are arriving. Zero padding keeps the meter neutral
    // until real energy frames arrive; phase/status copy communicates
    // preparation separately.
    return Array(repeating: 0, count: padding) + samples
  }

  static func meterAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeInOut(duration: 0.08)
  }

  static func barOpacity(for level: Float) -> Double {
    let clampedLevel = level.isFinite ? max(0, min(level, 1)) : 0
    return 0.62 + Double(clampedLevel) * 0.38
  }

  private func barGradient(for index: Int) -> LinearGradient {
    let opacity = 0.48 + (Double(index) / Double(max(barCount - 1, 1))) * 0.34
    return LinearGradient(
      colors: [
        accentColor.opacity(opacity),
        accentColor.opacity(min(opacity + 0.18, 1)),
        accentColor.opacity(opacity),
      ],
      startPoint: .top,
      endPoint: .bottom
    )
  }
}
