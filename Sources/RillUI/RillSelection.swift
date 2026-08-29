import SwiftUI

/// Shared corner radii, so cards, badges and floating panels stop inventing
/// their own values (HIG: Consistency).
public enum RillRadius {
    /// Content cards (`rillCard` default).
    public static let card: CGFloat = 14
    /// Small labelled surfaces (badges, inline editors).
    public static let badge: CGFloat = 8
    /// Compact chips and key hints.
    public static let chip: CGFloat = 6
    /// Floating panels and sheets.
    public static let panel: CGFloat = 16
}

extension View {
    /// Unified selected-row/card treatment: accent wash + accent stroke when
    /// selected, a subdued neutral fill otherwise. Selection state is
    /// expressed once here instead of per-view opacity numbers.
    func rillSelection(
        _ isSelected: Bool,
        cornerRadius: CGFloat = RillRadius.card
    ) -> some View {
        self
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.quaternary.opacity(RillCardProminence.subdued.fillOpacity))
                }
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
                }
            }
    }
}
