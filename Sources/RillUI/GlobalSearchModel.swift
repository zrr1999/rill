import Foundation
import Observation
import RillCore
import RillRuntime

@MainActor
@Observable
final class GlobalSearchModel {
    var query = ""
    var selectedID: String?
    private(set) var recordResults: [GlobalSearchResult] = []
    private(set) var historyResults: [GlobalSearchResult] = []
    private(set) var recordState: GlobalHistorySearchState = .idle
    private(set) var historyState: GlobalHistorySearchState = .idle
    private(set) var hasMoreRecords = false
    private(set) var hasMoreHistory = false
    private var limit = 20
    private var recordCursor: RecordSearchCursor?
    private var loadedRecordLimit = 0
    private var activeRequest: GlobalHistorySearchTaskIdentity?

    func reset() {
        query = ""
        selectedID = nil
        recordResults = []
        historyResults = []
        recordState = .idle
        historyState = .idle
        hasMoreRecords = false
        hasMoreHistory = false
        limit = 20
        recordCursor = nil
        loadedRecordLimit = 0
        activeRequest = nil
    }

    func results(matching request: GlobalHistorySearchTaskIdentity) -> [GlobalSearchResult] {
        activeRequest == request ? recordResults + historyResults : []
    }

    func showMore() { limit += 20 }

    func update(
        request: GlobalHistorySearchTaskIdentity,
        records: @MainActor (String, RecordSearchCursor?, Int) async throws -> RecordSearchPage,
        history: @MainActor (String, Int) async throws -> [GlobalSearchResult],
        language: AppLanguage
    ) async {
        let changed = activeRequest?.query != request.query
            || activeRequest?.previewMode != request.previewMode
            || activeRequest?.retentionPeriod != request.retentionPeriod
            || activeRequest?.language != request.language
            || activeRequest?.recordRevision != request.recordRevision
        if changed {
            recordResults = []
            historyResults = []
            hasMoreRecords = false
            hasMoreHistory = false
            limit = 20
            recordCursor = nil
            loadedRecordLimit = 0
        }
        activeRequest = request
        guard request.isPresented, !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            recordState = .idle
            historyState = .idle
            hasMoreRecords = false
            hasMoreHistory = false
            return
        }
        historyState = .searching
        async let recordSearch: Void = updateRecords(request, search: records, language: language)
        async let historySearch: Void = updateHistory(request, search: history)
        _ = await (recordSearch, historySearch)
    }

    private func canPublish(_ request: GlobalHistorySearchTaskIdentity) -> Bool {
        !Task.isCancelled && activeRequest == request && query == request.query
    }

    private func updateRecords(
        _ request: GlobalHistorySearchTaskIdentity,
        search: @MainActor (String, RecordSearchCursor?, Int) async throws -> RecordSearchPage,
        language: AppLanguage
    ) async {
        guard loadedRecordLimit < limit || recordState == .failed else { return }
        guard loadedRecordLimit == 0 || recordCursor != nil else { return }
        recordState = .searching
        do {
            let page: RecordSearchPage
            var replacesResults = recordCursor == nil
            do {
                page = try await search(request.query, recordCursor, limit - recordResults.count)
            } catch RecordStoreError.membershipChanged {
                guard canPublish(request) else { return }
                page = try await search(request.query, nil, limit)
                replacesResults = true
            }
            guard canPublish(request) else { return }
            let results = GlobalSearchIndex.recordResults(page.records, language: language)
            if replacesResults { recordResults = results } else { recordResults += results }
            recordCursor = page.cursor
            loadedRecordLimit = limit
            hasMoreRecords = page.cursor != nil
            recordState = .loaded
        } catch {
            guard canPublish(request) else { return }
            recordState = .failed
        }
    }

    private func updateHistory(
        _ request: GlobalHistorySearchTaskIdentity,
        search: @MainActor (String, Int) async throws -> [GlobalSearchResult]
    ) async {
        do {
            try await Task.sleep(for: .milliseconds(250))
            let results = try await search(request.query, limit + 1)
            guard canPublish(request) else { return }
            historyResults = Array(results.prefix(limit))
            hasMoreHistory = results.count > limit
            historyState = .loaded
        } catch {
            guard canPublish(request) else { return }
            historyState = .failed
        }
    }
}
