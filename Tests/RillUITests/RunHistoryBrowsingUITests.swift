import Foundation
import XCTest

@testable import RillCore
@testable import RillUI

private enum ScriptedRunHistoryOutcome: Sendable {
    case page(RunHistoryPage)
    case missing
    case failure
}

private enum ScriptedRunHistoryError: Error {
    case unavailable
}

private actor ScriptedRunHistoryBrowser: RunHistoryBrowsing {
    private var pageOutcomes: [ScriptedRunHistoryOutcome]
    private var containingOutcomes: [ScriptedRunHistoryOutcome]
    private var recordedRequests: [RunHistoryPageRequest] = []
    private var inSessionContainingCallCount = 0
    private var freshContainingCallCount = 0

    init(
        pageOutcomes: [ScriptedRunHistoryOutcome],
        containingOutcomes: [ScriptedRunHistoryOutcome] = []
    ) {
        self.pageOutcomes = pageOutcomes
        self.containingOutcomes = containingOutcomes
    }

    func page(_ request: RunHistoryPageRequest) async throws -> RunHistoryPage {
        recordedRequests.append(request)
        return try resolvePage(from: &pageOutcomes)
    }

    func page(
        containing entryID: UUID,
        in session: RunHistoryReadSession,
        limit: Int
    ) async throws -> RunHistoryPage? {
        inSessionContainingCallCount += 1
        return try resolveOptionalPage(from: &containingOutcomes)
    }

    func page(
        containing entryID: UUID,
        scope: RunHistoryBrowseScope,
        retentionCutoff: Date?,
        contentAccess: RunHistoryContentAccess,
        limit: Int
    ) async throws -> RunHistoryPage? {
        freshContainingCallCount += 1
        return try resolveOptionalPage(from: &containingOutcomes)
    }

    func requests() -> [RunHistoryPageRequest] {
        recordedRequests
    }

    func containingCallSnapshot() -> (inSession: Int, fresh: Int) {
        (inSessionContainingCallCount, freshContainingCallCount)
    }

    private func resolvePage(
        from outcomes: inout [ScriptedRunHistoryOutcome]
    ) throws -> RunHistoryPage {
        guard !outcomes.isEmpty else { throw ScriptedRunHistoryError.unavailable }
        switch outcomes.removeFirst() {
        case .page(let page): return page
        case .missing, .failure: throw ScriptedRunHistoryError.unavailable
        }
    }

    private func resolveOptionalPage(
        from outcomes: inout [ScriptedRunHistoryOutcome]
    ) throws -> RunHistoryPage? {
        guard !outcomes.isEmpty else { throw ScriptedRunHistoryError.unavailable }
        switch outcomes.removeFirst() {
        case .page(let page): return page
        case .missing: return nil
        case .failure: throw ScriptedRunHistoryError.unavailable
        }
    }
}

private actor PrivacyAwareRunHistoryBrowser: RunHistoryBrowsing {
    static let totalEntryCount = 500
    static let timestampBase: TimeInterval = 10_000

    let workflow: WorkflowDefinition
    let fullText: String
    private var accesses: [RunHistoryContentAccess] = []
    private var limits: [Int] = []

    init(workflow: WorkflowDefinition, fullText: String) {
        self.workflow = workflow
        self.fullText = fullText
    }

    func page(_ request: RunHistoryPageRequest) async throws -> RunHistoryPage {
        let scope: RunHistoryBrowseScope
        let cutoff: Date?
        let access: RunHistoryContentAccess
        let limit: Int
        let startIndex: Int
        let session: RunHistoryReadSession
        switch request {
        case .first(let requestedScope, let requestedCutoff, let requestedAccess, let requestedLimit):
            scope = requestedScope
            cutoff = requestedCutoff
            access = requestedAccess
            limit = requestedLimit
            startIndex = 0
            session = try RunHistoryReadSession(
                generation: .initial,
                snapshotWriteOrdinal: Int64(accesses.count + 1),
                retentionCutoff: cutoff,
                scope: scope,
                contentAccess: access
            )
        case .next(let cursor, let requestedLimit):
            scope = cursor.session.scope
            cutoff = cursor.session.retentionCutoff
            access = cursor.session.contentAccess
            limit = requestedLimit
            startIndex = Int(
                Self.timestampBase - cursor.after.timestamp.timeIntervalSince1970
            ) + 1
            session = cursor.session
        }
        accesses.append(access)
        limits.append(limit)
        let endIndex = min(startIndex + limit, Self.totalEntryCount)
        let entries = try (startIndex ..< endIndex).map { index in
            let runID = UUID()
            let recordID = UUID()
            let timestamp = Date(
                timeIntervalSince1970: Self.timestampBase - TimeInterval(index)
            )
            var indexedFullText = fullText
            if index == 75 {
                indexedFullText += " POSITION-75-CANARY"
            } else if index == 175 {
                indexedFullText += " POSITION-175-CANARY"
            }
            let projectedText: String? = switch access {
            case .metadataOnly:
                nil
            case .restrictedPreview:
                String(indexedFullText.prefix(RunHistoryContentAccess.restrictedPreviewCharacterLimit))
            case .full:
                indexedFullText
            }
            let record = projectedText.map { text in
                HistoryRecord(
                    id: recordID,
                    runID: runID,
                    workflowID: workflow.id,
                    workflow: workflow.presentation,
                    finalText: text,
                    timestamp: timestamp,
                    outcome: .completed,
                    trigger: .manual
                )
            }
            let metadata = RunHistoryRecordMetadata(
                recordID: recordID,
                runID: runID,
                workflowID: workflow.id,
                timestamp: timestamp,
                isStackRelated: false,
                outcome: .completed,
                trigger: .manual,
                hasNonemptyFinalText: true
            )
            return try RunHistoryEntry(
                id: runID,
                timestamp: timestamp,
                recordMetadata: metadata,
                record: record
            )
        }
        let nextCursor = entries.last.flatMap { lastEntry in
            endIndex < Self.totalEntryCount
                ? RunHistoryCursor(
                    session: session,
                    after: RunHistorySortKey(
                        timestamp: lastEntry.timestamp,
                        entryID: lastEntry.id
                    )
                )
                : nil
        }
        return RunHistoryPage(
            session: session,
            entries: entries,
            nextCursor: nextCursor
        )
    }

    func page(
        containing entryID: UUID,
        in session: RunHistoryReadSession,
        limit: Int
    ) async throws -> RunHistoryPage? {
        nil
    }

    func page(
        containing entryID: UUID,
        scope: RunHistoryBrowseScope,
        retentionCutoff: Date?,
        contentAccess: RunHistoryContentAccess,
        limit: Int
    ) async throws -> RunHistoryPage? {
        nil
    }

    func requestSnapshot() -> (accesses: [RunHistoryContentAccess], limits: [Int]) {
        (accesses, limits)
    }
}

private actor OutOfOrderRunHistoryBrowser: RunHistoryBrowsing {
    let workflow: WorkflowDefinition
    private var pageCallCount = 0
    private var suspendedPageContinuation: CheckedContinuation<RunHistoryPage, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

    init(workflow: WorkflowDefinition) {
        self.workflow = workflow
    }

    func page(_ request: RunHistoryPageRequest) async throws -> RunHistoryPage {
        pageCallCount += 1
        if pageCallCount == 1 {
            return try makePage(text: "initial value", request: request)
        }
        if pageCallCount == 2 {
            let page = try makePage(text: "alpha value", request: request)
            let waiters = suspensionWaiters
            suspensionWaiters.removeAll()
            waiters.forEach { $0.resume() }
            return await withCheckedContinuation { continuation in
                suspendedPageContinuation = continuation
                // Store the page in a separate task-free closure: cancellation
                // of the caller deliberately does not resume this continuation.
                suspendedAlphaPage = page
            }
        }
        return try makePage(text: "beta value", request: request)
    }

    private var suspendedAlphaPage: RunHistoryPage?

    func waitUntilAlphaIsSuspended() async {
        if suspendedPageContinuation != nil { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resumeAlpha() {
        guard let continuation = suspendedPageContinuation,
              let page = suspendedAlphaPage else {
            return
        }
        suspendedPageContinuation = nil
        suspendedAlphaPage = nil
        continuation.resume(returning: page)
    }

    func page(
        containing entryID: UUID,
        in session: RunHistoryReadSession,
        limit: Int
    ) async throws -> RunHistoryPage? {
        nil
    }

    func page(
        containing entryID: UUID,
        scope: RunHistoryBrowseScope,
        retentionCutoff: Date?,
        contentAccess: RunHistoryContentAccess,
        limit: Int
    ) async throws -> RunHistoryPage? {
        nil
    }

    private func makePage(
        text: String,
        request: RunHistoryPageRequest
    ) throws -> RunHistoryPage {
        let scope: RunHistoryBrowseScope
        let retentionCutoff: Date?
        let contentAccess: RunHistoryContentAccess
        switch request {
        case .first(let requestedScope, let cutoff, let access, _):
            scope = requestedScope
            retentionCutoff = cutoff
            contentAccess = access
        case .next(let cursor, _):
            scope = cursor.session.scope
            retentionCutoff = cursor.session.retentionCutoff
            contentAccess = cursor.session.contentAccess
        }
        let session = try RunHistoryReadSession(
            generation: .initial,
            snapshotWriteOrdinal: Int64(pageCallCount),
            retentionCutoff: retentionCutoff,
            scope: scope,
            contentAccess: contentAccess
        )
        let runID = UUID()
        let recordID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let projectedText: String? = switch contentAccess {
        case .metadataOnly: nil
        case .restrictedPreview:
            String(text.prefix(RunHistoryContentAccess.restrictedPreviewCharacterLimit))
        case .full: text
        }
        let record = projectedText.map {
            HistoryRecord(
                id: recordID,
                runID: runID,
                workflowID: workflow.id,
                workflow: workflow.presentation,
                finalText: $0,
                timestamp: timestamp,
                outcome: .completed,
                trigger: .manual
            )
        }
        let metadata = RunHistoryRecordMetadata(
            recordID: recordID,
            runID: runID,
            workflowID: workflow.id,
            timestamp: timestamp,
            isStackRelated: false,
            outcome: .completed,
            trigger: .manual,
            hasNonemptyFinalText: true
        )
        let entry = try RunHistoryEntry(
            id: runID,
            timestamp: timestamp,
            recordMetadata: metadata,
            record: record
        )
        return RunHistoryPage(session: session, entries: [entry], nextCursor: nil)
    }
}

@MainActor
final class RunHistoryBrowsingUITests: XCTestCase {
    func testPaginationKeepsOneResidentPageAndRefetchesNewerPage() async throws {
        let session = try makeSession(access: .restrictedPreview)
        let firstEntry = try makeEntry(name: "Newest", timestamp: 200)
        let olderEntry = try makeEntry(name: "Older", timestamp: 100)
        let cursor = RunHistoryCursor(
            session: session,
            after: RunHistorySortKey(timestamp: firstEntry.timestamp, entryID: firstEntry.id)
        )
        let firstPage = RunHistoryPage(
            session: session,
            entries: [firstEntry],
            nextCursor: cursor
        )
        let olderPage = RunHistoryPage(session: session, entries: [olderEntry], nextCursor: nil)
        let browser = ScriptedRunHistoryBrowser(
            pageOutcomes: [.page(firstPage), .page(olderPage)],
            containingOutcomes: [.page(firstPage)]
        )
        let harness = makeHarness(runHistoryBrowser: browser)

        let loadedFirst = await waitUntil { harness.model.runHistoryPage == firstPage }
        XCTAssertTrue(loadedFirst)
        harness.model.loadOlderRunHistoryPage()
        let loadedOlder = await waitUntil { harness.model.runHistoryPage == olderPage }
        XCTAssertTrue(loadedOlder)
        XCTAssertEqual(harness.model.runHistoryPage?.entries.map(\.id), [olderEntry.id])
        XCTAssertTrue(harness.model.canLoadNewerRunHistoryPage)

        harness.model.loadNewerRunHistoryPage()
        let returnedToFirst = await waitUntil { harness.model.runHistoryPage == firstPage }
        XCTAssertTrue(returnedToFirst)
        XCTAssertEqual(harness.model.runHistoryPage?.entries.count, 1)

        let requests = await browser.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.limit == AppModel.runHistoryPageSize })
        let containingCalls = await browser.containingCallSnapshot()
        XCTAssertEqual(containingCalls.inSession, 1)
        XCTAssertEqual(containingCalls.fresh, 0)
    }

    func testPaginationFailurePreservesCurrentPage() async throws {
        let session = try makeSession(access: .restrictedPreview)
        let entry = try makeEntry(name: "Stable", timestamp: 200)
        let cursor = RunHistoryCursor(
            session: session,
            after: RunHistorySortKey(timestamp: entry.timestamp, entryID: entry.id)
        )
        let page = RunHistoryPage(session: session, entries: [entry], nextCursor: cursor)
        let browser = ScriptedRunHistoryBrowser(pageOutcomes: [.page(page), .failure])
        let harness = makeHarness(runHistoryBrowser: browser)

        let loaded = await waitUntil { harness.model.runHistoryPage == page }
        XCTAssertTrue(loaded)
        harness.model.loadOlderRunHistoryPage()
        let failed = await waitUntil { harness.model.runHistoryPaginationFailed }
        XCTAssertTrue(failed)
        XCTAssertEqual(harness.model.runHistoryPage, page)
        XCTAssertFalse(harness.model.isRunHistoryPageTransitioning)
    }

    func testDeepLinkMissingFromFreshSnapshotIsExplicitlyExpired() async throws {
        let session = try makeSession(access: .restrictedPreview)
        let entry = try makeEntry(name: "Current", timestamp: 200)
        let page = RunHistoryPage(session: session, entries: [entry], nextCursor: nil)
        let browser = ScriptedRunHistoryBrowser(
            pageOutcomes: [.page(page)],
            containingOutcomes: [.missing]
        )
        let harness = makeHarness(runHistoryBrowser: browser)
        let loaded = await waitUntil { harness.model.runHistoryPage == page }
        XCTAssertTrue(loaded)

        let missingID = UUID()
        harness.model.showHistoryEntry(missingID)
        await harness.model.resolveRunHistoryDeepLinkIfNeeded()

        XCTAssertEqual(harness.model.runHistoryDeepLinkState, .expired(entryID: missingID))
        XCTAssertEqual(harness.model.runHistoryPage, page)
    }

    func testScopeResetAndNewRunRefreshCaptureFreshFirstPages() async throws {
        let allSession = try makeSession(access: .restrictedPreview, scope: .allRuns)
        let resultsSession = try makeSession(access: .restrictedPreview, scope: .voiceResults)
        let allEntry = try makeEntry(name: "All", timestamp: 300)
        let resultEntry = try makeEntry(name: "Result", timestamp: 200)
        let refreshedEntry = try makeEntry(name: "Refreshed", timestamp: 400)
        let allPage = RunHistoryPage(session: allSession, entries: [allEntry], nextCursor: nil)
        let resultsPage = RunHistoryPage(
            session: resultsSession,
            entries: [resultEntry],
            nextCursor: nil
        )
        let refreshedPage = RunHistoryPage(
            session: resultsSession,
            entries: [refreshedEntry],
            nextCursor: nil
        )
        let browser = ScriptedRunHistoryBrowser(
            pageOutcomes: [.page(allPage), .page(resultsPage), .page(refreshedPage)]
        )
        let harness = makeHarness(runHistoryBrowser: browser)
        let loadedAll = await waitUntil { harness.model.runHistoryPage == allPage }
        XCTAssertTrue(loadedAll)

        harness.model.runHistoryScope = .recentResults
        let loadedResults = await waitUntil { harness.model.runHistoryPage == resultsPage }
        XCTAssertTrue(loadedResults)
        harness.model.noteNewRunAvailableForHistoryBrowsing()
        XCTAssertTrue(harness.model.runHistoryHasNewerEntries)
        XCTAssertEqual(harness.model.runHistoryPage, resultsPage)

        harness.model.refreshNewestRunHistoryPage()
        let loadedRefresh = await waitUntil { harness.model.runHistoryPage == refreshedPage }
        XCTAssertTrue(loadedRefresh)
        XCTAssertFalse(harness.model.runHistoryHasNewerEntries)

        let recordedRequests = await browser.requests()
        let scopes = recordedRequests.compactMap { request -> RunHistoryBrowseScope? in
            guard case .first(let scope, _, _, _) = request else { return nil }
            return scope
        }
        XCTAssertEqual(scopes, [.allRuns, .voiceResults, .voiceResults])
    }

    func testDeepLinkFailurePreservesPageAndCanRetry() async throws {
        let session = try makeSession(access: .restrictedPreview)
        let currentEntry = try makeEntry(name: "Current", timestamp: 200)
        let targetEntry = try makeEntry(name: "Target", timestamp: 100)
        let currentPage = RunHistoryPage(
            session: session,
            entries: [currentEntry],
            nextCursor: nil
        )
        let targetPage = RunHistoryPage(
            session: session,
            entries: [targetEntry],
            nextCursor: nil
        )
        let browser = ScriptedRunHistoryBrowser(
            pageOutcomes: [.page(currentPage)],
            containingOutcomes: [.failure, .page(targetPage)]
        )
        let harness = makeHarness(runHistoryBrowser: browser)
        let loaded = await waitUntil { harness.model.runHistoryPage == currentPage }
        XCTAssertTrue(loaded)

        harness.model.showHistoryEntry(targetEntry.id)
        await harness.model.resolveRunHistoryDeepLinkIfNeeded()
        XCTAssertEqual(
            harness.model.runHistoryDeepLinkState,
            .failed(entryID: targetEntry.id)
        )
        XCTAssertEqual(harness.model.runHistoryPage, currentPage)

        harness.model.retryRunHistoryDeepLink()
        await harness.model.resolveRunHistoryDeepLinkIfNeeded()
        XCTAssertEqual(
            harness.model.runHistoryDeepLinkState,
            .resolved(entryID: targetEntry.id)
        )
        XCTAssertEqual(harness.model.runHistoryPage, targetPage)
    }

    func testSearchUsesStorageEnforcedPrivacyAndCapsResults() async throws {
        let workflow = makeSearchWorkflow(name: "Search Workflow")
        let tailCanary = "PRIVATE-TAIL-CANARY"
        let body = "VISIBLE "
            + String(repeating: "x", count: RunHistoryContentAccess.restrictedPreviewCharacterLimit)
            + tailCanary
        let browser = PrivacyAwareRunHistoryBrowser(workflow: workflow, fullText: body)
        let harness = makeHarness(workflows: [workflow], runHistoryBrowser: browser)
        let loaded = await waitUntil { harness.model.runHistoryPage != nil }
        XCTAssertTrue(loaded)

        let baselineCount = await browser.requestSnapshot().limits.count
        let full = try await harness.model.searchRunHistory(
            query: tailCanary,
            language: .english,
            previewMode: .full
        )
        let restricted = try await harness.model.searchRunHistory(
            query: tailCanary,
            language: .english,
            previewMode: .restricted
        )
        let metadataOnly = try await harness.model.searchRunHistory(
            query: "Search Workflow",
            language: .english,
            previewMode: .disabled
        )
        let position75 = try await harness.model.searchRunHistory(
            query: "POSITION-75-CANARY",
            language: .english,
            previewMode: .full
        )
        let position175 = try await harness.model.searchRunHistory(
            query: "POSITION-175-CANARY",
            language: .english,
            previewMode: .full
        )
        let noMatch = try await harness.model.searchRunHistory(
            query: "NO-SUCH-500-ENTRY-CANARY",
            language: .english,
            previewMode: .full
        )

        XCTAssertEqual(full.count, GlobalSearchIndex.maximumHistoryResultCount)
        XCTAssertTrue(restricted.isEmpty)
        XCTAssertEqual(metadataOnly.count, GlobalSearchIndex.maximumHistoryResultCount)
        XCTAssertTrue(metadataOnly.allSatisfy { $0.preview == nil })
        XCTAssertEqual(position75.count, 1)
        XCTAssertEqual(position175.count, 1)
        XCTAssertTrue(noMatch.isEmpty)

        let requests = await browser.requestSnapshot()
        let searchAccesses = Array(requests.accesses.dropFirst(baselineCount))
        XCTAssertEqual(searchAccesses.first, .full)
        XCTAssertTrue(searchAccesses.contains(.restrictedPreview))
        XCTAssertTrue(searchAccesses.contains(.metadataOnly))
        XCTAssertTrue(requests.limits.allSatisfy { $0 <= AppModel.runHistoryPageSize })
        // full common match reaches the 20-result cap on page 1; restricted
        // and no-match queries scan all 10 pages. Sparse canaries at rows 75
        // and 175 also scan to the end because more matches may exist later.
        XCTAssertEqual(requests.limits.count - baselineCount, 42)
    }

    func testUnavailableBrowserIsAWarningNotAFalseNoMatch() async {
        let harness = makeHarness()
        do {
            _ = try await harness.model.searchRunHistory(
                query: "anything",
                language: .english,
                previewMode: .full
            )
            XCTFail("Expected unavailable search to throw")
        } catch {
            XCTAssertEqual(error as? RunHistorySearchError, .unavailable)
        }
    }

    func testMetadataOnlyHiddenPreviewIndicatorIsVoiceOnly() throws {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        func entry(trigger: WorkflowRunTriggerKind) throws -> HistoryTimelineEntry {
            let runID = UUID()
            let metadata = RunHistoryRecordMetadata(
                recordID: UUID(),
                runID: runID,
                workflowID: UUID(),
                timestamp: timestamp,
                isStackRelated: false,
                outcome: .completed,
                trigger: trigger,
                hasNonemptyFinalText: true
            )
            return HistoryTimelineEntry(
                try RunHistoryEntry(
                    id: runID,
                    timestamp: timestamp,
                    recordMetadata: metadata
                )
            )
        }

        XCTAssertTrue(try entry(trigger: .manual).hasProtectedPreview)
        XCTAssertFalse(try entry(trigger: .clipboardUse).hasProtectedPreview)
    }

    func testRecordIDDeepLinkAliasMapsToVisibleRunRowIdentity() async throws {
        let session = try makeSession(access: .restrictedPreview)
        let entry = try makeEntry(name: "Aliased", timestamp: 200)
        let recordID = try XCTUnwrap(entry.recordMetadata?.recordID)
        let page = RunHistoryPage(session: session, entries: [entry], nextCursor: nil)
        let browser = ScriptedRunHistoryBrowser(pageOutcomes: [.page(page)])
        let harness = makeHarness(runHistoryBrowser: browser)

        let loaded = await waitUntil { harness.model.runHistoryPage == page }
        XCTAssertTrue(loaded)
        XCTAssertEqual(
            harness.model.visibleRunHistoryEntryID(matching: recordID),
            entry.id
        )
    }

    func testCancelledSearchCannotPublishAfterNewerQueryCompletes() async throws {
        let workflow = makeSearchWorkflow(name: "Cancellation Workflow")
        let browser = OutOfOrderRunHistoryBrowser(workflow: workflow)
        let harness = makeHarness(workflows: [workflow], runHistoryBrowser: browser)
        let loaded = await waitUntil { harness.model.runHistoryPage != nil }
        XCTAssertTrue(loaded)

        let alphaTask = Task { @MainActor in
            try await harness.model.searchRunHistory(
                query: "alpha",
                language: .english,
                previewMode: .full
            )
        }
        await browser.waitUntilAlphaIsSuspended()
        alphaTask.cancel()

        let betaResults = try await harness.model.searchRunHistory(
            query: "beta",
            language: .english,
            previewMode: .full
        )
        XCTAssertEqual(betaResults.count, 1)
        XCTAssertEqual(betaResults.first?.preview, "beta value")

        await browser.resumeAlpha()
        do {
            _ = try await alphaTask.value
            XCTFail("Cancelled alpha search must not publish late results")
        } catch is CancellationError {
            // Expected: the storage call ignored cancellation, but the search
            // boundary checks cancellation before returning anything to SwiftUI.
        }
    }

    private func makeSession(
        access: RunHistoryContentAccess,
        scope: RunHistoryBrowseScope = .allRuns
    ) throws -> RunHistoryReadSession {
        try RunHistoryReadSession(
            generation: .initial,
            snapshotWriteOrdinal: 10,
            retentionCutoff: nil,
            scope: scope,
            contentAccess: access
        )
    }

    private func makeEntry(
        name: String,
        timestamp: TimeInterval
    ) throws -> RunHistoryEntry {
        let runID = UUID()
        let recordID = UUID()
        let date = Date(timeIntervalSince1970: timestamp)
        let workflowID = UUID()
        let record = HistoryRecord(
            id: recordID,
            runID: runID,
            workflowID: workflowID,
            workflow: WorkflowPresentation(fallbackName: name),
            finalText: name,
            timestamp: date,
            outcome: .completed,
            trigger: .manual
        )
        let metadata = RunHistoryRecordMetadata(
            recordID: recordID,
            runID: runID,
            workflowID: workflowID,
            timestamp: date,
            isStackRelated: false,
            outcome: .completed,
            trigger: .manual,
            hasNonemptyFinalText: true
        )
        return try RunHistoryEntry(
            id: runID,
            timestamp: date,
            recordMetadata: metadata,
            record: record
        )
    }

    private func makeSearchWorkflow(name: String) -> WorkflowDefinition {
        WorkflowDefinition(
            name: name,
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: "ui.test.recognizer",
                outputActions: []
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}
