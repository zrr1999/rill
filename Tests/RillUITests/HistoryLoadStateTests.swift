import XCTest
@testable import RillCore
@testable import RillUI

private actor FailThenSucceedHistoryRepository: HistoryRepository {
    func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration { .initial }
    func save(_ value: WorkflowResultRecord, generation: RunHistoryWriteGeneration) async throws {
        guard generation == .initial else { throw RunHistoryGenerationError.unsupported }
        try await (self as any HistoryRepository).save(value)
    }

    enum LoadError: Error {
        case unavailable
    }

    private var stored: [WorkflowResultRecord]
    private var readsAreAvailable = false

    init(records: [WorkflowResultRecord]) {
        stored = records
    }

    func allowReads() {
        readsAreAvailable = true
    }

    func save(_ record: WorkflowResultRecord) async throws {
        stored.append(record)
    }

    func records(matching query: HistoryQuery) async throws -> [WorkflowResultRecord] {
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
        let record = WorkflowResultRecord(
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
            harness.model.history.historyLoadState == .failed(.repositoryUnavailable)
        }
        XCTAssertTrue(failed)
        XCTAssertTrue(harness.model.history.historyRecords.isEmpty)
        XCTAssertEqual(
            HistoryViewState(
                loadState: harness.model.history.historyLoadState,
                hasEntries: false
            ),
            .failed(.repositoryUnavailable)
        )

        await repository.allowReads()
        harness.model.retryHistoryLoad()
        XCTAssertEqual(harness.model.history.historyLoadState, .loading)

        let loaded = await waitUntil {
            harness.model.history.historyLoadState == .loaded
                && harness.model.history.historyRecords == [record]
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
        let keys: [L10n.InterfaceKey] = [
            .historyLoading,
            .historyLoadFailedTitle,
            .historyLoadFailedDescription,
            .historyRetryLoad,
            .historyLoadSessionOnlyTitle,
            .historyLoadSessionOnlyDescription,
            .historyLoadSessionOnlyViewStorage,
        ]

        for key in keys {
            let english = L10n.text(key, language: .english)
            let simplifiedChinese = L10n.text(key, language: .simplifiedChinese)
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
