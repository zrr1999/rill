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
                Text(L10n.text(.diagnosticsDescription, language: model.language))
                    .foregroundStyle(.secondary)
                diagnosticsSection
            }
            .padding(24)
        }
        .navigationTitle(L10n.text(.diagnosticsTitle, language: model.language))
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(
                        L10n.text(.diagnosticsTimeline, language: model.language),
                        systemImage: RillSystemSymbol.clockBadgeCheckmark.rawValue
                    )
                    .font(.headline)
                    Spacer()
                    Picker(
                        L10n.text(.diagnosticsTimeline, language: model.language),
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
                    Button(L10n.text(.refreshDiagnostics, language: model.language)) {
                        model.refreshDiagnostics()
                    }
                    .disabled(model.history.diagnosticsLoadState == .loading)
                    .accessibilityIdentifier("diagnostics.timeline.refresh")
                }

                switch Self.timelineContent(
                    loadState: model.history.diagnosticsLoadState,
                    events: model.history.diagnosticEvents,
                    filter: timelineFilter
                ) {
                case .loading(let entries):
                    ProgressView(L10n.text(.diagnosticsLoading, language: model.language))
                        .controlSize(.small)
                        .accessibilityIdentifier("diagnostics.timeline.loading")
                    timelineRows(entries)
                case .failed(let entries):
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            L10n.text(.diagnosticsLoadFailed, language: model.language),
                            systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
                        )
                        .font(.callout)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("diagnostics.timeline.error")

                        Button(L10n.text(.diagnosticsRetry, language: model.language)) {
                            model.refreshDiagnostics()
                        }
                        .disabled(model.history.diagnosticsLoadState == .loading)
                        .accessibilityIdentifier("diagnostics.timeline.retry")
                    }
                    timelineRows(entries)
                case .empty:
                    Text(L10n.text(.diagnosticsEmpty, language: model.language))
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
            DiagnosticEventRow(model: model, entry: entry)
        }
    }

}
