import RillCore
import SwiftUI

struct HistoryRunDiagnosticsView: View {
    @Bindable var model: AppModel
    let runID: UUID
    @State private var events: [DiagnosticEvent] = []
    @State private var loadState: DiagnosticsLoadState = .loading
    @State private var refreshID = UUID()
    @State private var showsAllEvents = false

    var body: some View {
        let visibleEvents = events.filter {
            (showsAllEvents ? DiagnosticsTimelineFilter.all : .issues).includes($0)
        }
        return VStack(alignment: .leading, spacing: RillSpacing.compact) {
            HStack {
                Text(L10n.historyRunDetail(.diagnostics, language: model.settings.language))
                    .font(.caption.weight(.semibold))
                Spacer()
                if !events.isEmpty {
                    Button(showsAllEvents
                        ? L10n.historyRunDetail(.showDiagnosticIssues, language: model.settings.language)
                        : L10n.historyShowAllDiagnostics(events.count, language: model.settings.language)) {
                        showsAllEvents.toggle()
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("history.run-diagnostics.filter")
                }
                Button {
                    refreshID = UUID()
                } label: {
                    Label(L10n.text(.refreshDiagnostics, language: model.settings.language),
                          systemImage: RillSystemSymbol.arrowClockwise.rawValue)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(loadState == .loading)
            }
            .font(.caption)
            switch loadState {
            case .loading:
                ProgressView(L10n.text(.diagnosticsLoading, language: model.settings.language))
                    .controlSize(.small)
            case .failed:
                Label(L10n.text(.diagnosticsLoadFailed, language: model.settings.language),
                      systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue)
                    .foregroundStyle(.red)
            case .loaded:
                if events.isEmpty {
                    Text(L10n.historyRunDetail(.noDiagnostics, language: model.settings.language))
                        .foregroundStyle(.secondary)
                } else if visibleEvents.isEmpty {
                    Text(L10n.historyRunDetail(.noDiagnosticIssues, language: model.settings.language))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(DiagnosticTimelineEntry.build(from: visibleEvents, limit: 20)) { entry in
                DiagnosticEventRow(model: model, entry: entry)
            }
        }
        .font(.caption)
        .accessibilityIdentifier("history.run-diagnostics")
        .task(id: refreshID) {
            loadState = .loading
            do {
                let loaded = try await model.diagnostics(for: runID)
                events = loaded
                loadState = .loaded
            } catch is CancellationError {
                return
            } catch {
                loadState = .failed
            }
        }
        .onChange(of: model.history.diagnosticsLoadGeneration) { _, _ in
            events = []
            refreshID = UUID()
        }
    }
}
