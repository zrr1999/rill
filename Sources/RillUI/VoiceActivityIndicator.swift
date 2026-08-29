import AppKit
import QuartzCore
import SwiftUI

@MainActor
public final class VoiceActivityMeterModel: ObservableObject {
  @Published public private(set) var levels: [Float]

  public init(levels: [Float] = []) {
    self.levels = levels
  }

  public func update(levels: [Float]) {
    guard self.levels != levels else { return }
    self.levels = levels
  }
}

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
    accentColor: Color,
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
    VoiceActivityLayerMeter(
      levels: levels,
      accentColor: accentColor,
      barWidth: barWidth,
      barSpacing: barSpacing,
      minHeight: minHeight,
      maxHeight: maxHeight,
      animatesChanges: !accessibilityReduceMotion
    )
    .frame(
      width: Self.meterWidth(
        barCount: barCount,
        barWidth: barWidth,
        barSpacing: barSpacing
      ),
      height: maxHeight
    )
    .accessibilityHidden(true)
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
    reduceMotion ? nil : .linear(duration: meterAnimationDuration)
  }

  static let meterTargetInterval: TimeInterval = 0.04
  // Let each target overlap the next 25 Hz meter sample. The native layer view
  // restarts from the current presentation value, producing one continuous
  // display-clock interpolation instead of a sequence of SwiftUI layout jumps.
  static let meterAnimationDuration: TimeInterval = 0.08

  static func meterWidth(
    barCount: Int,
    barWidth: CGFloat,
    barSpacing: CGFloat
  ) -> CGFloat {
    guard barCount > 0 else { return 0 }
    return CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
  }

  static func barOpacity(for level: Float) -> Double {
    let clampedLevel = level.isFinite ? max(0, min(level, 1)) : 0
    return 0.62 + Double(clampedLevel) * 0.38
  }

}

private struct VoiceActivityLayerMeter: NSViewRepresentable {
  let levels: [Float]
  let accentColor: Color
  let barWidth: CGFloat
  let barSpacing: CGFloat
  let minHeight: CGFloat
  let maxHeight: CGFloat
  let animatesChanges: Bool

  func makeNSView(context _: Context) -> VoiceActivityMeterView {
    VoiceActivityMeterView()
  }

  func updateNSView(_ view: VoiceActivityMeterView, context _: Context) {
    view.update(
      levels: levels,
      accentColor: NSColor(accentColor),
      barWidth: barWidth,
      barSpacing: barSpacing,
      minHeight: minHeight,
      maxHeight: maxHeight,
      animatesChanges: animatesChanges
    )
  }
}

@MainActor
private final class VoiceActivityMeterView: NSView {
  private var barLayers: [CAGradientLayer] = []
  private var levels: [Float] = []
  private var barWidth: CGFloat = 0
  private var barSpacing: CGFloat = 0
  private var minHeight: CGFloat = 0
  private var maxHeight: CGFloat = 0
  private var lastLayoutBounds = NSRect.zero

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isFlipped: Bool { true }

  func update(
    levels: [Float],
    accentColor: NSColor,
    barWidth: CGFloat,
    barSpacing: CGFloat,
    minHeight: CGFloat,
    maxHeight: CGFloat,
    animatesChanges: Bool
  ) {
    let geometryChanged = self.barWidth != barWidth
      || self.barSpacing != barSpacing
      || self.minHeight != minHeight
      || self.maxHeight != maxHeight
      || barLayers.count != levels.count

    self.barWidth = barWidth
    self.barSpacing = barSpacing
    self.minHeight = minHeight
    self.maxHeight = maxHeight
    ensureBarLayers(count: levels.count)
    updateColors(accentColor)

    let levelsChanged = self.levels != levels
    self.levels = levels
    guard geometryChanged || levelsChanged else { return }

    if geometryChanged || bounds.isEmpty {
      needsLayout = true
    } else {
      applyLevels(animated: animatesChanges)
    }
  }

  override func layout() {
    super.layout()
    guard bounds != lastLayoutBounds else { return }
    lastLayoutBounds = bounds
    applyLevels(animated: false)
  }

  private func ensureBarLayers(count: Int) {
    guard barLayers.count != count else { return }
    barLayers.forEach { $0.removeFromSuperlayer() }
    barLayers = (0..<count).map { _ in
      let barLayer = CAGradientLayer()
      barLayer.startPoint = CGPoint(x: 0.5, y: 0)
      barLayer.endPoint = CGPoint(x: 0.5, y: 1)
      barLayer.actions = [
        "bounds": NSNull(),
        "position": NSNull(),
        "opacity": NSNull(),
        "colors": NSNull(),
      ]
      layer?.addSublayer(barLayer)
      return barLayer
    }
  }

  private func updateColors(_ accentColor: NSColor) {
    for (index, barLayer) in barLayers.enumerated() {
      let denominator = Double(max(barLayers.count - 1, 1))
      let opacity = 0.48 + (Double(index) / denominator) * 0.34
      barLayer.colors = [
        accentColor.withAlphaComponent(opacity).cgColor,
        accentColor.withAlphaComponent(min(opacity + 0.18, 1)).cgColor,
        accentColor.withAlphaComponent(opacity).cgColor,
      ]
    }
  }

  private func applyLevels(animated: Bool) {
    guard !barLayers.isEmpty else { return }

    for (index, barLayer) in barLayers.enumerated() {
      let level = index < levels.count ? levels[index] : 0
      let height = minHeight + CGFloat(level) * (maxHeight - minHeight)
      let targetBounds = CGRect(x: 0, y: 0, width: barWidth, height: height)
      let targetPosition = CGPoint(
        x: CGFloat(index) * (barWidth + barSpacing) + barWidth / 2,
        y: bounds.midY
      )
      let targetOpacity = Float(VoiceActivityIndicator.barOpacity(for: level))

      let currentHeight = barLayer.presentation()?.bounds.height ?? barLayer.bounds.height
      let currentOpacity = barLayer.presentation()?.opacity ?? barLayer.opacity

      CATransaction.begin()
      CATransaction.setDisableActions(true)
      barLayer.bounds = targetBounds
      barLayer.position = targetPosition
      barLayer.cornerRadius = min(2, barWidth / 2, height / 2)
      barLayer.opacity = targetOpacity
      CATransaction.commit()

      guard animated else {
        barLayer.removeAllAnimations()
        continue
      }

      let heightAnimation = CABasicAnimation(keyPath: "bounds.size.height")
      heightAnimation.fromValue = currentHeight
      heightAnimation.toValue = height
      heightAnimation.duration = VoiceActivityIndicator.meterAnimationDuration
      heightAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
      barLayer.add(heightAnimation, forKey: "meter.height")

      let opacityAnimation = CABasicAnimation(keyPath: "opacity")
      opacityAnimation.fromValue = currentOpacity
      opacityAnimation.toValue = targetOpacity
      opacityAnimation.duration = VoiceActivityIndicator.meterAnimationDuration
      opacityAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
      barLayer.add(opacityAnimation, forKey: "meter.opacity")
    }
  }
}
