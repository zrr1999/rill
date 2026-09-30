import AppKit
import SwiftUI

public enum RecordPanelAppearance {
  public static let cornerRadius: CGFloat = 19
  static let sidebarWidth: CGFloat = 194
  static let paneInset: CGFloat = 8
  static let paper = Color(nsColor: .textBackgroundColor)

  static var paneShape: ConcentricRectangle {
    ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true)
  }
}

private struct RecordPanelGlass<Surface: Shape>: ViewModifier {
  let shape: Surface
  let interactive: Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    if reduceTransparency || contrast == .increased {
      content.background(Color(nsColor: .controlBackgroundColor), in: shape)
    } else {
      content.glassEffect(.regular.interactive(interactive), in: shape)
    }
  }
}

extension View {
  func recordPanelGlass(in shape: some Shape, interactive: Bool = false) -> some View {
    modifier(RecordPanelGlass(shape: shape, interactive: interactive))
  }

  func recordPanelSearchSurface() -> some View {
    frame(height: 30)
      .background(RecordPanelAppearance.paper.opacity(0.6),
                  in: RoundedRectangle(cornerRadius: 7, style: .continuous))
  }
}
