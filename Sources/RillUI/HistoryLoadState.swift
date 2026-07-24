import Foundation

public enum HistoryLoadFailure: Hashable, Sendable {
    case repositoryUnavailable
}

public enum HistoryLoadState: Hashable, Sendable {
    case loading
    case loaded
    case failed(HistoryLoadFailure)
}

public enum RunHistoryDeepLinkState: Hashable, Sendable {
    case idle
    case resolving(entryID: UUID)
    case resolved(entryID: UUID)
    case expired(entryID: UUID)
    case failed(entryID: UUID)
}

enum HistoryViewState: Equatable {
    case loading
    case loaded(isEmpty: Bool)
    case failed(HistoryLoadFailure)

    init(loadState: HistoryLoadState, hasEntries: Bool) {
        switch loadState {
        case .loading:
            self = .loading
        case .loaded:
            self = .loaded(isEmpty: !hasEntries)
        case .failed(let failure):
            self = .failed(failure)
        }
    }
}
