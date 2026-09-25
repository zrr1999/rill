import RillCore
import SwiftUI

struct HistoryRunDiagnosticsView: View {
    @Bindable var model: AppModel
    let runID: UUID
    @State private var events: [DiagnosticEvent] = []
    @State private var loadState: DiagnosticsLoadState = .loading
    @State private var refreshID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.historyRunDetail(.diagnostics, language: model.language))
                    .font(.callout.weight(.semibold))
                Spacer()
                Button(L10n.text(.refreshDiagnostics, language: model.language)) {
                    refreshID = UUID()
                }
                .buttonStyle(.borderless)
                .disabled(loadState == .loading)
            }
            switch loadState {
            case .loading:
                ProgressView(L10n.text(.diagnosticsLoading, language: model.language))
                    .controlSize(.small)
            case .failed:
                Label(L10n.text(.diagnosticsLoadFailed, language: model.language),
                      systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue)
                    .foregroundStyle(.red)
            case .loaded:
                if events.isEmpty {
                    Text(L10n.historyRunDetail(.noDiagnostics, language: model.language))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(DiagnosticTimelineEntry.build(from: events, limit: 20)) { entry in
                DiagnosticEventRow(model: model, entry: entry)
            }
        }
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
