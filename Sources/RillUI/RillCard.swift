import SwiftUI

/// Shared spacing steps, so gaps and paddings stay on one scale instead of
/// drifting into per-view magic numbers (HIG: Consistency).
public enum RillSpacing {
    /// Tight inline gaps (icon-to-label, badge internals).
    public static let compact: CGFloat = 4
    /// Gap between rows and items within a group.
    public static let row: CGFloat = 8
    /// Inner padding of small cards and nested groups.
    public static let card: CGFloat = 12
    /// Default card/panel padding (`rillCard` default).
    public static let panel: CGFloat = 16
    /// Gap between sections.
    public static let section: CGFloat = 20
    /// Page-level margins.
    public static let page: CGFloat = 24
}

/// Visual weight of a Rill card, mapped to one consistent fill treatment.
///
/// Cards communicate hierarchy through named levels instead of ad-hoc opacity
/// numbers scattered across views, keeping the whole surface visually
/// consistent (HIG: Consistency, Aesthetic Integrity).
public enum RillCardProminence: Sendable {
    /// Calls for attention or action (setup checklists, failure banners).
    case prominent
    /// Default content card.
    case regular
    /// Low-emphasis nested rows (feed entries, list-in-card items).
    case subdued

    var fillOpacity: Double {
        switch self {
        case .prominent: 0.45
        case .regular: 0.35
        case .subdued: 0.2
        }
    }
}

extension View {
    func rillCard(
        _ prominence: RillCardProminence = .regular,
        cornerRadius: CGFloat = RillRadius.card,
        padding: CGFloat = RillSpacing.panel
    ) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .quaternary.opacity(prominence.fillOpacity),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

/// Button style for interactive cards, such as the tappable Dashboard
/// summaries.
///
/// HIG (Feedback, Direct Manipulation): a clickable card must acknowledge the
/// pointer. Hovering raises a hairline stroke and pressing gently compresses
/// the card, without changing layout. Reduce Motion disables the animation.
public struct RillCardButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = RillRadius.card) {
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        RillCardButtonBody(configuration: configuration, cornerRadius: cornerRadius)
    }
}

private struct RillCardButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let cornerRadius: CGFloat

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        configuration.label
            .contentShape(shape)
            .overlay {
                shape.strokeBorder(
                    Color.primary.opacity(isHovering ? 0.22 : 0),
                    lineWidth: 1
                )
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 1.0),
                value: isHovering
            )
            .animation(
                reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8),
                value: configuration.isPressed
            )
            .onHover { isHovering = $0 }
    }
}

/// The caller supplies already-authorized text; expansion never fetches a fuller body.
struct RillTextPreview: View {
    let text: String
    let permitsExpansion: Bool
    let language: AppLanguage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: RillSpacing.compact) {
            Text(text)
                .font(.body)
                .lineLimit(expanded && permitsExpansion ? nil : 3)
                .textSelection(.enabled)
            if permitsExpansion && (text.count > 60 || text.contains("\n")) {
                Button(L10n.presentation(expanded ? .less : .more, language: language)) {
                    expanded.toggle()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .onChange(of: text) { expanded = false }
        .onChange(of: permitsExpansion) { expanded = false }
    }
}

struct RillCopyButton: View {
    let title: String
    let language: AppLanguage
    let action: () -> Void
    @State private var feedbackID: UUID?

    var body: some View {
        Button {
            action()
            feedbackID = UUID()
        } label: {
            Text(title).hidden().overlay {
                Text(feedbackID == nil ? title : L10n.presentation(.copied, language: language))
            }
        }
        .accessibilityLabel(feedbackID == nil ? title : L10n.presentation(.copied, language: language))
        .buttonStyle(.borderless)
        .task(id: feedbackID) {
            guard feedbackID != nil else { return }
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            feedbackID = nil
        }
    }
}
