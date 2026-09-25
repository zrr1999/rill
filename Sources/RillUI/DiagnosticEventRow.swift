import RillCore
import SwiftUI

struct DiagnosticEventRow: View {
    @Bindable var model: AppModel
    let entry: DiagnosticTimelineEntry

    var body: some View {
        let event = entry.event
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.diagnosticLevel(event.level, language: model.settings.language))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(diagnosticColor(event.level))
                Spacer()
                if event.level == .warning || event.level == .error {
                    RillCopyButton(title: L10n.text(.copy, language: model.settings.language), language: model.settings.language) {
                        model.copyDiagnosticEvent(event)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityLabel(entry.copyAccessibilityLabel(language: model.settings.language))
                }
                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(DiagnosticEventPresentation.title(for: event, language: model.settings.language))
                .font(.subheadline.weight(.medium))

            DisclosureGroup(L10n.presentation(.metadata, language: model.settings.language)) {
                Text(DiagnosticEventPresentation.detail(for: event))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .font(.caption)
            Divider()
        }
        .padding(.vertical, RillSpacing.row)
    }

    private func diagnosticColor(_ level: DiagnosticLevel) -> Color {
        switch level {
        case .debug:
            return .secondary
        case .info:
            return .secondary
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}
