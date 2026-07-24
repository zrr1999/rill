import XCTest
@testable import RillCore
@testable import RillUI

private actor FailThenSucceedHistoryRepository: HistoryRepository {
    enum LoadError: Error {
        case unavailable
    }

    private var stored: [HistoryRecord]
    private var readsAreAvailable = false

    init(records: [HistoryRecord]) {
        stored = records
    }

    func allowReads() {
        readsAreAvailable = true
    }

    func save(_ record: HistoryRecord) async throws {
        stored.append(record)
    }

    func records(matching query: HistoryQuery) async throws -> [HistoryRecord] {
        guard readsAreAvailable else {
            throw LoadError.unavailable
        }
        let sorted = stored.sorted { $0.timestamp > $1.timestamp }
        guard let limit = query.limit, limit >= 0 else { return sorted }
        return Array(sorted.prefix(limit))
    }

    func deleteRecords(olderThan cutoff: Date) async throws -> Int {
        let originalCount = stored.count
        stored.removeAll { $0.timestamp < cutoff }
        return originalCount - stored.count
    }

    func deleteRecords(through upperBound: Date) async throws -> Int {
        let originalCount = stored.count
        stored.removeAll { $0.timestamp <= upperBound }
        return originalCount - stored.count
    }

    func deleteAllRecords() async throws -> Int {
        let originalCount = stored.count
        stored.removeAll()
        return originalCount
    }
}

@MainActor
final class HistoryLoadStateTests: XCTestCase {
    func testFailedLoadRemainsVisibleUntilRetrySucceeds() async {
        let record = HistoryRecord(
            runID: UUID(),
            workflow: WorkflowPresentation(fallbackName: "Recovered history"),
            finalText: "Recovered result",
            timestamp: Date(),
            outcome: .completed,
            trigger: .hotkey
        )
        let repository = FailThenSucceedHistoryRepository(records: [record])
        let harness = makeHarness(historyRepository: repository)

        let failed = await waitUntil {
            harness.model.historyLoadState == .failed(.repositoryUnavailable)
        }
        XCTAssertTrue(failed)
        XCTAssertTrue(harness.model.historyRecords.isEmpty)
        XCTAssertEqual(
            HistoryViewState(
                loadState: harness.model.historyLoadState,
                hasEntries: false
            ),
            .failed(.repositoryUnavailable)
        )

        await repository.allowReads()
        harness.model.retryHistoryLoad()
        XCTAssertEqual(harness.model.historyLoadState, .loading)

        let loaded = await waitUntil {
            harness.model.historyLoadState == .loaded
                && harness.model.historyRecords == [record]
        }
        XCTAssertTrue(loaded)
    }

    func testLoadFailureCannotResolveToTheNormalEmptyState() {
        let failed = HistoryViewState(
            loadState: .failed(.repositoryUnavailable),
            hasEntries: false
        )

        XCTAssertEqual(failed, .failed(.repositoryUnavailable))
        XCTAssertNotEqual(failed, .loaded(isEmpty: true))
        XCTAssertEqual(
            HistoryViewState(loadState: .loaded, hasEntries: false),
            .loaded(isEmpty: true)
        )
    }

    func testHistoryLoadFailureAndRetryCopyIsLocalized() {
        let keys: [UIStrings.Key] = [
            .historyLoading,
            .historyLoadFailedTitle,
            .historyLoadFailedDescription,
            .historyRetryLoad,
        ]

        for key in keys {
            let english = UIStrings.text(key, language: .english)
            let simplifiedChinese = UIStrings.text(key, language: .simplifiedChinese)
            XCTAssertFalse(english.isEmpty)
            XCTAssertFalse(simplifiedChinese.isEmpty)
            XCTAssertNotEqual(english, simplifiedChinese)
            XCTAssertNotEqual(english, String(describing: key))
            XCTAssertNotEqual(simplifiedChinese, String(describing: key))
        }
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
}
