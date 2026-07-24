import RillCore

public enum DiagnosticsLoadState: Sendable, Equatable {
    case loading
    case loaded
    case failed
}

enum DiagnosticsTimelineContent: Sendable {
    case loading([DiagnosticTimelineEntry])
    case failed([DiagnosticTimelineEntry])
    case empty
    case events([DiagnosticTimelineEntry])
}

extension DiagnosticsTimelineContent {
    static func resolve(
        loadState: DiagnosticsLoadState,
        events: [DiagnosticEvent]
    ) -> Self {
        let entries = DiagnosticTimelineEntry.build(from: events, limit: 20)

        switch loadState {
        case .loading:
            return .loading(entries)
        case .failed:
            return .failed(entries)
        case .loaded:
            return entries.isEmpty ? .empty : .events(entries)
        }
    }
}
