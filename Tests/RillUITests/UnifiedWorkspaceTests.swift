import RillTestSupport
import XCTest
@testable import RillCore
@testable import RillWorkflows
@testable import RillRecords
@testable import RillKnowledge
@testable import RillUI

@MainActor
final class UnifiedWorkspaceTests: XCTestCase {
    func testAllRecordsIsDefaultAndSettingsPreservesContentNavigation() async throws {
        let model = makeHarness().model
        await model.recordWorkspace.refresh()
        XCTAssertEqual(model.selectedSidebarSection, .records)
        XCTAssertNil(model.recordWorkspace.selectedCollectionID)
        model.showRecordCollection(RecordCollection.inboxID)
        model.showSettings(.contextMemory)
        XCTAssertEqual(model.selectedSidebarSection, .records)
        XCTAssertEqual(model.recordWorkspace.selectedCollectionID, RecordCollection.inboxID)
        XCTAssertEqual(model.selectedSettingsPane, .vocabulary)
        XCTAssertTrue(model.consumeSettingsPresentation())
        XCTAssertFalse(model.consumeSettingsPresentation())
        model.selectSidebarSection(.records)
        XCTAssertNil(model.recordWorkspace.selectedCollectionID)
    }

    func testEverySettingsDestinationHasOnePane() {
        let sections = SettingsPane.allCases.flatMap(\.sections)
        XCTAssertEqual(Set(sections), Set(SettingsSection.allCases))
        XCTAssertEqual(sections.count, Set(sections).count)
        for pane in SettingsPane.allCases {
            XCTAssertTrue(pane.sections.allSatisfy { $0.pane == pane })
        }
    }

    func testSettingItemsResolveTheirPaneAndSearchDestination() {
        let model = makeHarness().model
        for item in SettingsItem.allCases {
            model.showSettings(.privacy, item: item)
            XCTAssertEqual(model.selectedSettingsPane, .voice)
            XCTAssertEqual(model.settingsNavigationRequest?.section, .providers)
            XCTAssertEqual(model.settingsNavigationRequest?.item, item)
        }
        let results = GlobalSearchIndex.makeStaticResults(language: .english, workflows: [])
        XCTAssertTrue(GlobalSearchIndex.filter(results, query: "Jev API").contains { $0.destination == .settingItem(.jevCredential) })
        XCTAssertTrue(GlobalSearchIndex.filter(results, query: "润色 判断").contains { $0.destination == .settingItem(.jevPolishing) })
    }

    func testClosingSettingsClearsReturnIntentAndCannotReopenComparison() {
        let model = makeHarness().model
        let context = RecordComparisonReturn(query: "sample", resultLimit: 1, candidateIDs: [RecordID()],
            semanticIDs: [], selectedID: nil, sourceBundleIdentifier: nil, currentAppOnly: false,
            kind: nil, pinnedOnly: false)
        var resumed = 0
        model.offerComparisonReturn(context) { _ in resumed += 1 }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = SettingsWindowCloseObserver.CloseView { model.discardComparisonReturn() }
        window.close()
        XCTAssertNil(model.comparisonReturn)
        model.resumeComparison()
        XCTAssertEqual(resumed, 0)
        model.offerComparisonReturn(context) { value in
            XCTAssertEqual(value, context)
            resumed += 1
        }
        model.resumeComparison()
        model.resumeComparison()
        XCTAssertEqual(resumed, 1)
        XCTAssertNil(model.comparisonReturn)
    }

    func testGlobalAndQuickSearchShareFallbackAndLoadMoreUsesCursor() async throws {
        let store = RecordStore()
        for index in 0..<25 { _ = try await store.ingest(draft("剪贴板 \(index)"), into: []) }
        let workspace = RecordWorkspaceModel(store: store)
        let search = GlobalSearchModel()
        search.query = "jiantieban"
        let request = request(search.query)
        var cursors: [RecordSearchCursor?] = []
        let records: @MainActor (String, RecordSearchCursor?, Int) async throws -> RecordSearchPage = { text, cursor, limit in
            cursors.append(cursor)
            return try await workspace.searchRecords(text, after: cursor, limit: limit)
        }
        await search.update(request: request, records: records, history: { _, _ in [] }, language: .english)
        XCTAssertEqual(search.recordResults.count, 20)
        search.showMore()
        await search.update(request: request, records: records, history: { _, _ in [] }, language: .english)
        XCTAssertEqual(cursors.count, 2)
        XCTAssertNil(cursors[0])
        XCTAssertEqual(cursors[1]?.matching, .approximate)
        XCTAssertEqual(Set(search.recordResults.map(\.id)).count, 25)
        XCTAssertFalse(search.hasMoreRecords)
        await workspace.shutdown()
    }

    func testRevealClearsFiltersAndDetectsDeletedRecord() async throws {
        let store = RecordStore()
        let target = try await store.ingest(draft("A saved idea"), into: [])
        let workspace = RecordWorkspaceModel(store: store)
        await workspace.refresh()
        workspace.selectCollection(RecordCollection.inboxID)
        workspace.setShowsPinnedOnly(true)
        workspace.setSourceAppFilter("com.example.unrelated")
        workspace.setPayloadKindFilter(.image)
        workspace.setSearchText("unrelated")
        await workspace.revealRecord(target.id)
        XCTAssertEqual(workspace.selectedVisibleRecord?.id, target.id)
        XCTAssertNil(workspace.selectedCollectionID)
        XCTAssertFalse(workspace.showsPinnedOnly)
        XCTAssertNil(workspace.payloadKindFilter)
        XCTAssertNil(workspace.sourceAppFilterBundleIdentifier)
        XCTAssertEqual(workspace.searchText, "")
        await workspace.deleteRecord(target.id)
        await workspace.cleanup.confirm()
        await workspace.revealRecord(target.id)
        XCTAssertNil(workspace.selectedRecordID)
        XCTAssertEqual(workspace.unavailableRecordID, target.id)
        await workspace.shutdown()
    }

    func testRepeatedRecordRevealHasANewFocusRequestAndOrdinaryNavigationCancelsIt() async throws {
        let store = RecordStore()
        let target = try await store.ingest(draft("A saved idea"), into: [])
        let workspace = RecordWorkspaceModel(store: store)
        await workspace.revealRecord(target.id)
        let firstRequest = workspace.navigationGeneration
        await workspace.revealRecord(target.id)
        XCTAssertGreaterThan(workspace.navigationGeneration, firstRequest)
        XCTAssertEqual(workspace.selectedRecordID, target.id)
        XCTAssertEqual(workspace.revealedRecordID, target.id)
        workspace.selectCollection(RecordCollection.inboxID)
        XCTAssertNil(workspace.revealedRecordID)
        await workspace.shutdown()
    }

    func testCopyFeedbackDistinguishesCommittedOutputFromFailure() {
        XCTAssertEqual(RecordReuseOutcome.copied.feedback, .copied)
        XCTAssertEqual(RecordReuseOutcome.outputCommittedWithIssue.feedback, .outputCommitted)
        XCTAssertEqual(RecordReuseOutcome.recordUnavailable.feedback, .recordUnavailable)
        XCTAssertEqual(RecordReuseOutcome.storageUnavailable.feedback, .storageUnavailable)
    }

    func testSearchScansPastEmptyStoragePagesAndIncludesTextBeyondPreview() async throws {
        let store = RecordStore()
        let target = try await store.ingest(draft(String(repeating: "prefix ", count: 200) + "needle"), into: [])
        for index in 0..<270 { _ = try await store.ingest(draft("unrelated \(index)"), into: []) }
        let workspace = RecordWorkspaceModel(store: store)
        let page = try await workspace.searchRecords("needle")
        XCTAssertEqual(page.records.map(\.id), [target.id])
        let results = GlobalSearchIndex.filter(GlobalSearchIndex.recordResults(page.records, language: .english), query: "needle")
        XCTAssertEqual(results.map(\.destination), [.record(target.id)])
        XCTAssertNil(page.nextOffset)
        await workspace.shutdown()
    }

    func testSearchLoadsMoreThanStoreSinglePageLimit() async throws {
        let store = RecordStore()
        for index in 0..<125 { _ = try await store.ingest(draft("match \(index)"), into: []) }
        let workspace = RecordWorkspaceModel(store: store)
        let page = try await workspace.searchRecords("match", limit: 120)
        XCTAssertEqual(page.records.count, 120)
        XCTAssertEqual(Set(page.records.map(\.id)).count, 120)
        XCTAssertNotNil(page.nextOffset)
        await workspace.shutdown()
    }

    func testSearchKeepsRecordsWhenHistoryFailsAndResetClearsResults() async throws {
        let store = RecordStore()
        let target = try await store.ingest(draft("match"), into: [])
        let workspace = RecordWorkspaceModel(store: store)
        let search = GlobalSearchModel()
        search.query = "match"
        let request = request("match")
        await search.update(request: request, records: { text, cursor, limit in
            try await workspace.searchRecords(text, after: cursor, limit: limit)
        }, history: { _, _ in throw SearchFailure.unavailable }, language: .english)
        XCTAssertEqual(search.recordState, .loaded)
        XCTAssertEqual(search.historyState, .failed)
        XCTAssertEqual(search.results(matching: request).map(\.destination), [.record(target.id)])
        search.reset()
        XCTAssertTrue(search.results(matching: request).isEmpty)
        await workspace.shutdown()
    }

    func testClearingSearchRemovesPaginationWithoutQueryingSources() async {
        let search = GlobalSearchModel()
        search.query = "match"
        await search.update(request: request("match"), records: { _, _, _ in
            RecordSearchPage(revision: 1, records: [], cursor: .init(query: .init(text: "match"), matching: .literal, revision: 1, offset: 20))
        }, history: { _, limit in
            (0..<limit).map { _ in
                GlobalSearchResult(destination: .history(UUID()), category: .history, title: "match",
                    detail: nil, preview: nil, symbolName: "clock", searchableText: "match", timestamp: nil)
            }
        }, language: .english)
        XCTAssertTrue(search.hasMoreRecords)
        XCTAssertTrue(search.hasMoreHistory)

        search.query = ""
        await search.update(request: request(""), records: { _, _, _ in
            XCTFail("Empty queries must not load records")
            return RecordSearchPage(revision: 1, records: [], cursor: nil)
        }, history: { _, _ in
            XCTFail("Empty queries must not load history")
            return []
        }, language: .english)
        XCTAssertFalse(search.hasMoreRecords)
        XCTAssertFalse(search.hasMoreHistory)
        XCTAssertTrue(search.results(matching: request("")).isEmpty)
    }

    func testSupersededSearchCannotPublishLateResults() async throws {
        let search = GlobalSearchModel()
        var continuation: CheckedContinuation<RecordSearchPage, Error>?
        let started = expectation(description: "Old query is suspended")
        search.query = "old"
        let old = Task {
            await search.update(request: request("old"), records: { _, _, _ in
                try await withCheckedThrowingContinuation { value in
                    continuation = value
                    started.fulfill()
                }
            }, history: { _, _ in [] }, language: .english)
        }
        await fulfillment(of: [started], timeout: 2)
        search.query = "new"
        let current = request("new")
        await search.update(request: current, records: { _, _, _ in
            RecordSearchPage(revision: 2, records: [], cursor: nil)
        }, history: { _, _ in [] }, language: .english)
        continuation?.resume(throwing: SearchFailure.unavailable)
        await old.value
        XCTAssertEqual(search.recordState, .loaded)
        XCTAssertEqual(search.historyState, .loaded)
        XCTAssertTrue(search.results(matching: request("old")).isEmpty)
    }

    func testQuickPanelPreviewUsesExactWidthBoundary() {
        XCTAssertFalse(RecordQuickPanelLayoutPolicy.usesSidePreview(width: 759))
        XCTAssertTrue(RecordQuickPanelLayoutPolicy.usesSidePreview(width: 760))
    }

    func testWorkspaceCopyIsExplicitAndReportsActualOutcome() async throws {
        let subject = RecordReuseSubject(recordID: RecordID(), metadataRevision: 0)
        var received: RecordReuseSubject?
        let model = makeHarness(recordInteractionServices: makeRecordInteractionServicesForTesting(
            copy: { value in received = value; return .storageUnavailable }
        )).model
        XCTAssertNil(received)
        let outcome = await model.copyRecord(subject)
        XCTAssertEqual(received, subject)
        XCTAssertEqual(outcome, .storageUnavailable)
    }

    private func request(_ query: String) -> GlobalHistorySearchTaskIdentity {
        .init(isPresented: true, query: query, language: "english", previewMode: "full", retentionPeriod: "forever", workflowSearchSnapshot: [], retryGeneration: 0)
    }

    private func draft(_ text: String) -> RecordDraft {
        .init(payload: .text(text), provenance: .init(source: .init(kind: .user)))
    }

    private enum SearchFailure: Error { case unavailable }
}
