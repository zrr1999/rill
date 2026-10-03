import AppKit
import SwiftUI

private struct RillGlassSurface<Surface: Shape>: ViewModifier {
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
  func rillGlass(in shape: some Shape, interactive: Bool = false) -> some View {
    modifier(RillGlassSurface(shape: shape, interactive: interactive))
  }
}
