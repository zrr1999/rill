import SwiftUI

/// Shared spacing steps, so gaps and paddings stay on one scale instead of
/// drifting into per-view magic numbers (HIG: Consistency).
public enum RillSpacing {
  /// Tight inline gaps (icon-to-label, badge internals).
  public static let compact: CGFloat = 4
  /// Gap between rows and items within a group.
  public static let row: CGFloat = 8
  /// List-row density between `row` (8) and `card` (12).
  public static let dense: CGFloat = 10
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

/// Pointer acknowledgement shared by cards, chips, navigation rows, and tinted labels.
///
/// Reduce Motion disables the transition. The kind only changes the cue, not layout.
struct RillHoverButtonStyle: ButtonStyle {
  enum Kind {
    case card(cornerRadius: CGFloat)
    case stroke(cornerRadius: CGFloat)
    case fill(cornerRadius: CGFloat)
    case tint
  }

  var kind: Kind

  func makeBody(configuration: Configuration) -> some View {
    RillHoverButtonBody(configuration: configuration, kind: kind)
  }
}

private struct RillHoverButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let kind: RillHoverButtonStyle.Kind

  @State private var isHovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    switch kind {
    case .card(let cornerRadius):
      stroked(cornerRadius: cornerRadius, scalesWhenPressed: true)
    case .stroke(let cornerRadius):
      stroked(cornerRadius: cornerRadius, scalesWhenPressed: false)
    case .fill(let cornerRadius):
      configuration.label
        .background {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.quaternary.opacity(isHovering ? RillCardProminence.regular.fillOpacity : 0))
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
    case .tint:
      configuration.label
        .foregroundStyle(isHovering ? Color.accentColor : Color.primary)
        .opacity(configuration.isPressed ? 0.7 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
    }
  }

  private func stroked(cornerRadius: CGFloat, scalesWhenPressed: Bool) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    return configuration.label
      .contentShape(shape)
      .overlay {
        shape.strokeBorder(Color.primary.opacity(isHovering ? 0.22 : 0), lineWidth: 1)
      }
      .scaleEffect(scalesWhenPressed && configuration.isPressed && !reduceMotion ? 0.985 : 1)
      .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 1.0), value: isHovering)
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button {
      action()
      feedbackID = UUID()
    } label: {
      Text(title).hidden().overlay {
        HStack(spacing: RillSpacing.compact) {
          if feedbackID != nil {
            Image(systemName: RillSystemSymbol.checkmark.rawValue)
              .symbolEffect(.bounce, value: feedbackID)
              .symbolEffectsRemoved(reduceMotion)
          }
          Text(feedbackID == nil ? title : L10n.presentation(.copied, language: language))
        }
      }
    }
    .accessibilityLabel(feedbackID == nil ? title : L10n.presentation(.copied, language: language))
    .buttonStyle(.borderless)
    .sensoryFeedback(.success, trigger: feedbackID)
    .task(id: feedbackID) {
      guard feedbackID != nil else { return }
      do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
      feedbackID = nil
    }
  }
}
