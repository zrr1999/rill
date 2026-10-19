import AppKit
import SwiftUI

/// Preferred lengths that follow the body text size, clamped so floating chrome
/// cannot collapse below its control target or grow off the screen.
public enum RillDynamicLength {
  public static func scaled(_ base: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
    let standard = NSFont.systemFontSize
    guard standard > 0 else { return min(maximum, max(minimum, base)) }
    let preferred = NSFont.preferredFont(forTextStyle: .body).pointSize
    let length = (base * preferred / standard).rounded()
    return min(maximum, max(minimum, length))
  }
}

extension View {
  func rillScaledWidth(_ base: CGFloat, minimum: CGFloat, maximum: CGFloat) -> some View {
    modifier(RillScaledWidth(base: base, minimum: minimum, maximum: maximum))
  }

  func rillScaledFrame(
    width: CGFloat,
    minimumWidth: CGFloat,
    maximumWidth: CGFloat,
    height: CGFloat,
    minimumHeight: CGFloat,
    maximumHeight: CGFloat,
    alignment: Alignment = .center
  ) -> some View {
    modifier(
      RillScaledFrame(
        baseWidth: width,
        minimumWidth: minimumWidth,
        maximumWidth: maximumWidth,
        baseHeight: height,
        minimumHeight: minimumHeight,
        maximumHeight: maximumHeight,
        alignment: alignment
      )
    )
  }
}

private struct RillScaledWidth: ViewModifier {
  @ScaledMetric(relativeTo: .body) private var textScale = 1.0
  let base: CGFloat
  let minimum: CGFloat
  let maximum: CGFloat

  func body(content: Content) -> some View {
    content.frame(width: rillClamped(base, minimum: minimum, maximum: maximum, scale: textScale))
  }
}

private struct RillScaledFrame: ViewModifier {
  @ScaledMetric(relativeTo: .body) private var textScale = 1.0
  let baseWidth: CGFloat
  let minimumWidth: CGFloat
  let maximumWidth: CGFloat
  let baseHeight: CGFloat
  let minimumHeight: CGFloat
  let maximumHeight: CGFloat
  let alignment: Alignment

  func body(content: Content) -> some View {
    content.frame(
      width: rillClamped(baseWidth, minimum: minimumWidth, maximum: maximumWidth, scale: textScale),
      height: rillClamped(baseHeight, minimum: minimumHeight, maximum: maximumHeight, scale: textScale),
      alignment: alignment
    )
  }
}

private func rillClamped(
  _ base: CGFloat, minimum: CGFloat, maximum: CGFloat, scale: CGFloat
) -> CGFloat {
  min(maximum, max(minimum, (base * scale).rounded()))
}
