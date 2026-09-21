import SwiftUI

/// Shared corner radii, so cards, badges and floating panels stop inventing
/// their own values (HIG: Consistency).
public enum RillRadius {
    /// Compact chips and key hints.
    public static let chip: CGFloat = 6
    /// Small labelled surfaces (badges, inline editors).
    public static let badge: CGFloat = 8
    /// Nested rows and inner panels inside a card.
    public static let row: CGFloat = 10
    /// Section containers and cards inside sheets.
    public static let section: CGFloat = 12
    /// Content cards (`rillCard` default).
    public static let card: CGFloat = 14
    /// Floating panels and sheets.
    public static let panel: CGFloat = 16
}

extension View {
    /// Unified selected-row/card treatment: accent wash + accent stroke when
    /// selected, a subdued neutral fill otherwise. Selection state is
    /// expressed once here instead of per-view opacity numbers.
    ///
    /// Selection changes transition with a short tween owned by this modifier,
    /// so every caller animates identically instead of opting in per call site.
    /// Reduce Motion disables the transition.
    func rillSelection(
        _ isSelected: Bool,
        cornerRadius: CGFloat = RillRadius.card
    ) -> some View {
        RillSelectionWrapper(isSelected: isSelected, cornerRadius: cornerRadius) {
            self
        }
    }
}

private struct RillSelectionWrapper<Content: View>: View {
    let isSelected: Bool
    let cornerRadius: CGFloat
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        content
            .background {
                if isSelected {
                    shape.fill(Color.accentColor.opacity(0.12))
                } else {
                    shape.fill(.quaternary.opacity(RillCardProminence.subdued.fillOpacity))
                }
            }
            .overlay {
                if isSelected {
                    shape.strokeBorder(Color.accentColor.opacity(contrast == .increased ? 1 : 0.5), lineWidth: contrast == .increased ? 2 : 1)
                }
            }
            .animation(
                reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1),
                value: isSelected
            )
    }
}
