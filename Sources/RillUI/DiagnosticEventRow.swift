import RillCore
import SwiftUI

struct DiagnosticEventRow: View {
    @Bindable var model: AppModel
    let entry: DiagnosticTimelineEntry

    var body: some View {
        let event = entry.event
        return HStack(alignment: .top, spacing: RillSpacing.row) {
            DisclosureGroup {
                Text(DiagnosticEventPresentation.detail(for: event))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: RillSpacing.row) {
                    Text(L10n.diagnosticLevel(event.level, language: model.settings.language))
                        .foregroundStyle(diagnosticColor(event.level))
                    Text(DiagnosticEventPresentation.title(for: event, language: model.settings.language))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: RillSpacing.row)
                    Text(event.timestamp.formatted(date: .omitted, time: .standard))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if event.level == .warning || event.level == .error {
                RillCopyButton(title: L10n.text(.copy, language: model.settings.language), language: model.settings.language) {
                    model.copyDiagnosticEvent(event)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(entry.copyAccessibilityLabel(language: model.settings.language))
            }
        }
        .font(.caption)
        .padding(.vertical, RillSpacing.compact)
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
