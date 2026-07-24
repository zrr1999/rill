import SwiftUI

public struct VoiceActivityIndicator: View {
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

  public let levelMeter: [Float]
  public let isActive: Bool
  public let accentColor: Color
  public let barCount: Int
  public let barWidth: CGFloat
  public let minHeight: CGFloat
  public let maxHeight: CGFloat

  public init(
    levelMeter: [Float],
    isActive: Bool,
    accentColor: Color = .purple,
    barCount: Int = 12,
    barWidth: CGFloat = 4,
    minHeight: CGFloat = 6,
    maxHeight: CGFloat = 28
  ) {
    self.levelMeter = levelMeter
    self.isActive = isActive
    self.accentColor = accentColor
    self.barCount = barCount
    self.barWidth = barWidth
    self.minHeight = minHeight
    self.maxHeight = maxHeight
  }

  public var body: some View {
    let heights = barHeights

    HStack(alignment: .bottom, spacing: 3) {
      ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .fill(barGradient(for: index))
          .frame(width: barWidth, height: height)
      }
    }
    .frame(height: maxHeight, alignment: .bottomLeading)
    .animation(Self.meterAnimation(reduceMotion: accessibilityReduceMotion), value: heights)
    .accessibilityHidden(true)
  }

  private var barHeights: [CGFloat] {
    Self.displayedLevels(levelMeter, barCount: barCount, isActive: isActive).map { sample in
      minHeight + CGFloat(sample) * (maxHeight - minHeight)
    }
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
    reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.78)
  }

  private func barGradient(for index: Int) -> LinearGradient {
    let opacity = 0.48 + (Double(index) / Double(max(barCount - 1, 1))) * 0.34
    return LinearGradient(
      colors: [
        accentColor.opacity(opacity),
        accentColor.opacity(min(opacity + 0.18, 1)),
      ],
      startPoint: .bottom,
      endPoint: .top
    )
  }
}
