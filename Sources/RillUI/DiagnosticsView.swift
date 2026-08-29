import SwiftUI
import RillCore

public struct DiagnosticsView: View {
    @Bindable private var model: AppModel
    @State private var timelineFilter: DiagnosticsTimelineFilter = .activity

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(UIStrings.text(.diagnosticsDescription, language: model.language))
                    .foregroundStyle(.secondary)
                diagnosticsSection
            }
            .padding(24)
        }
        .navigationTitle(UIStrings.text(.diagnosticsTitle, language: model.language))
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(
                        UIStrings.text(.diagnosticsTimeline, language: model.language),
                        systemImage: RillSystemSymbol.clockBadgeCheckmark.rawValue
                    )
                    .font(.headline)
                    Spacer()
                    Picker(
                        UIStrings.text(.diagnosticsTimeline, language: model.language),
                        selection: $timelineFilter
                    ) {
                        ForEach(DiagnosticsTimelineFilter.allCases) { filter in
                            Text(filter.title(language: model.language))
                                .tag(filter)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityIdentifier("diagnostics.timeline.filter")
                    Button(UIStrings.text(.refreshDiagnostics, language: model.language)) {
                        model.refreshDiagnostics()
                    }
                    .disabled(model.diagnosticsLoadState == .loading)
                    .accessibilityIdentifier("diagnostics.timeline.refresh")
                }

                switch Self.timelineContent(
                    loadState: model.diagnosticsLoadState,
                    events: model.diagnosticEvents,
                    filter: timelineFilter
                ) {
                case .loading(let entries):
                    ProgressView(UIStrings.text(.diagnosticsLoading, language: model.language))
                        .controlSize(.small)
                        .accessibilityIdentifier("diagnostics.timeline.loading")
                    timelineRows(entries)
                case .failed(let entries):
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            UIStrings.text(.diagnosticsLoadFailed, language: model.language),
                            systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
                        )
                        .font(.callout)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("diagnostics.timeline.error")

                        Button(UIStrings.text(.diagnosticsRetry, language: model.language)) {
                            model.refreshDiagnostics()
                        }
                        .disabled(model.diagnosticsLoadState == .loading)
                        .accessibilityIdentifier("diagnostics.timeline.retry")
                    }
                    timelineRows(entries)
                case .empty:
                    Text(UIStrings.text(.diagnosticsEmpty, language: model.language))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("diagnostics.timeline.empty")
                case .events(let entries):
                    timelineRows(entries)
                }
            }
            .rillCard()
    }

    static func timelineEvents(
        from events: [DiagnosticEvent],
        filter: DiagnosticsTimelineFilter = .activity
    ) -> [DiagnosticEvent] {
        timelineEntries(from: events, filter: filter).map(\.event)
    }

    static func timelineEntries(
        from events: [DiagnosticEvent],
        filter: DiagnosticsTimelineFilter = .activity
    ) -> [DiagnosticTimelineEntry] {
        DiagnosticTimelineEntry.build(
            from: events.filter(filter.includes),
            limit: 20
        )
    }

    static func timelineContent(
        loadState: DiagnosticsLoadState,
        events: [DiagnosticEvent],
        filter: DiagnosticsTimelineFilter = .activity
    ) -> DiagnosticsTimelineContent {
        DiagnosticsTimelineContent.resolve(
            loadState: loadState,
            events: events,
            filter: filter
        )
    }

    @ViewBuilder
    private func timelineRows(_ entries: [DiagnosticTimelineEntry]) -> some View {
        ForEach(entries) { entry in
            diagnosticRow(entry)
        }
    }

    private func diagnosticRow(_ entry: DiagnosticTimelineEntry) -> some View {
        let event = entry.event
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(UIStrings.diagnosticLevel(event.level, language: model.language))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(diagnosticColor(event.level))
                Spacer()
                if event.level == .warning || event.level == .error {
                    Button(UIStrings.text(.copy, language: model.language)) {
                        model.copyDiagnosticEvent(event)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityLabel(entry.copyAccessibilityLabel(language: model.language))
                }
                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(DiagnosticEventPresentation.title(for: event, language: model.language))
                .font(.subheadline.weight(.medium))

            Text(DiagnosticEventPresentation.detail(for: event))
                .font(.caption)
                .monospaced()
                .foregroundStyle(.secondary)
        }
        .rillCard(.subdued, cornerRadius: 10, padding: 10)
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
