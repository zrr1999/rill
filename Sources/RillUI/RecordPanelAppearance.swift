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

extension View {
  func recordPanelSearchSurface() -> some View {
    frame(height: 30)
      .background(
        RecordPanelAppearance.paper.opacity(0.6),
        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
  }
}
