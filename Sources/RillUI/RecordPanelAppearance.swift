import AppKit
import SwiftUI

public enum RecordPanelAppearance {
  public static let cornerRadius: CGFloat = 19
  static let sidebarWidth: CGFloat = 194
  static let paper = Color(nsColor: .textBackgroundColor)
}

struct RecordPanelActionStyle: ButtonStyle {
  enum Role { case primary, secondary, quiet }
  var role: Role = .secondary
  @State private var isHovered = false
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.colorSchemeContrast) private var contrast

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: role == .primary ? .medium : .regular))
      .frame(maxWidth: .infinity)
      .frame(height: 31)
      .foregroundStyle(role == .primary ? RecordPanelAppearance.paper
        : role == .quiet ? Color.accentColor : Color.primary)
      .background {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(role == .primary ? Color.primary.opacity(isHovered && isEnabled ? 0.86 : 1)
            : role == .secondary ? RecordPanelAppearance.paper.opacity(isHovered && isEnabled ? 0.9 : 0.6)
            : Color.primary.opacity(isHovered && isEnabled ? 0.05 : 0))
      }
      .overlay {
        if role == .secondary {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0.1))
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 7))
      .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.38)
      .onHover { isHovered = $0 }
  }
}

struct RecordPanelIconStyle: ButtonStyle {
  @State private var isHovered = false
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12))
      .frame(width: 28, height: 28)
      .contentShape(RoundedRectangle(cornerRadius: 6))
      .background(isEnabled && (configuration.isPressed || isHovered) ? Color.primary.opacity(0.08) : .clear,
                  in: RoundedRectangle(cornerRadius: 6))
      .opacity(isEnabled ? 1 : 0.38)
      .onHover { isHovered = $0 }
  }
}

extension View {
  func recordPanelSearchSurface() -> some View {
    frame(height: 30)
      .background(RecordPanelAppearance.paper.opacity(0.6),
                  in: RoundedRectangle(cornerRadius: 7, style: .continuous))
  }
}
