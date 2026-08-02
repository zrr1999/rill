import Foundation
import XCTest

@testable import RillCore
@testable import RillUI

@MainActor
final class GlobalSearchIndexTests: XCTestCase {
    func testSettingsSectionsFollowProgressiveImportanceOrder() {
        XCTAssertEqual(
            SettingsSection.allCases,
            [
                .permissions,
                .speech,
                .input,
                .voiceAssistant,
                .clipboardPanel,
                .vocabulary,
                .language,
                .privacy,
                .storage,
            ]
        )
    }

    func testSharedModelsArePresentedAsProvidersInsteadOfAssistantPersonality() {
        XCTAssertEqual(
            SettingsSection.speech.title(language: .english),
            "Providers & Models"
        )
        XCTAssertEqual(
            SettingsSection.speech.title(language: .simplifiedChinese),
            "提供商与模型"
        )
        XCTAssertTrue(SettingsSection.speech.searchKeywords.contains("tts"))
        XCTAssertFalse(SettingsSection.voiceAssistant.searchKeywords.contains("tts"))
    }

    func testHistoryRetryCopyIsFixedInBothLanguages() {
        XCTAssertEqual(GlobalSearchText.historyRetry(language: .english), "Retry")
        XCTAssertEqual(GlobalSearchText.historyRetry(language: .simplifiedChinese), "重试")
    }

    func testHistoryRetryOnlyAdvancesFailedVisibleNonemptyRequest() {
        XCTAssertEqual(
            GlobalHistorySearchRequestPolicy.nextRetryGeneration(
                currentGeneration: 4,
                isPresented: true,
                query: "  failed query  ",
                state: .failed
            ),
            5
        )
        XCTAssertNil(
            GlobalHistorySearchRequestPolicy.nextRetryGeneration(
                currentGeneration: 4,
                isPresented: false,
                query: "failed query",
                state: .failed
            )
        )

        XCTAssertEqual(
            GlobalHistorySearchRequestPolicy.retryTransition(
                currentGeneration: 4,
                currentFocusRequest: 9,
                isPresented: true,
                query: "failed query",
                state: .failed
            ),
            GlobalHistorySearchRequestPolicy.RetryTransition(
                retryGeneration: 5,
                focusRequest: 10
            ),
            "An accepted Retry must rehome focus before its transient button disappears."
        )
        XCTAssertNil(
            GlobalHistorySearchRequestPolicy.nextRetryGeneration(
                currentGeneration: 4,
                isPresented: true,
                query: " \n ",
                state: .failed
            )
        )
        XCTAssertNil(
            GlobalHistorySearchRequestPolicy.nextRetryGeneration(
                currentGeneration: 4,
                isPresented: true,
                query: "new query",
                state: .searching
            )
        )
    }

    func testOnlyCurrentHistorySearchRequestMayPublish() {
        let current = makeHistorySearchRequest(query: "new", retryGeneration: 2)
        let staleQuery = makeHistorySearchRequest(query: "old", retryGeneration: 2)
        let staleRetry = makeHistorySearchRequest(query: "new", retryGeneration: 1)

        XCTAssertTrue(
            GlobalHistorySearchRequestPolicy.canPublish(
                request: current,
                current: current,
                isCancelled: false
            )
        )
        XCTAssertFalse(
            GlobalHistorySearchRequestPolicy.canPublish(
                request: staleQuery,
                current: current,
                isCancelled: false
            )
        )
        XCTAssertFalse(
            GlobalHistorySearchRequestPolicy.canPublish(
                request: staleRetry,
                current: current,
                isCancelled: false
            )
        )
        XCTAssertFalse(
            GlobalHistorySearchRequestPolicy.canPublish(
                request: current,
                current: current,
                isCancelled: true
            )
        )
    }

    func testHistorySearchRespectsFullRestrictedAndDisabledPreviewModes() throws {
        let workflow = makeWorkflow(name: "Private Dictation")
        let visiblePrefix = "VISIBLE-PREFIX-"
        let tailCanary = "PRIVATE-TAIL-CANARY"
        let body = visiblePrefix
            + String(repeating: "x", count: HistoryPreviewPresentation.restrictedCharacterLimit)
            + tailCanary
        let record = HistoryRecord(
            runID: UUID(),
            workflowID: workflow.id,
            workflow: workflow.presentation,
            finalText: body,
            timestamp: Date(timeIntervalSince1970: 100),
            outcome: .completed,
            trigger: .manual
        )

        let full = makeResults(
            workflow: workflow,
            record: record,
            previewMode: .full
        )
        XCTAssertEqual(historyMatches(full, query: tailCanary).count, 1)

        let restricted = makeResults(
            workflow: workflow,
            record: record,
            previewMode: .restricted
        )
        XCTAssertEqual(historyMatches(restricted, query: visiblePrefix).count, 1)
        XCTAssertTrue(historyMatches(restricted, query: tailCanary).isEmpty)
        let restrictedHistory = try XCTUnwrap(
            restricted.first { $0.category == .history }
        )
        XCTAssertFalse(restrictedHistory.searchableText.contains(tailCanary))
        XCTAssertFalse(restrictedHistory.preview?.contains(tailCanary) ?? false)

        let disabled = makeResults(
            workflow: workflow,
            record: record,
            previewMode: .disabled
        )
        XCTAssertTrue(historyMatches(disabled, query: visiblePrefix).isEmpty)
        XCTAssertTrue(historyMatches(disabled, query: tailCanary).isEmpty)
        let disabledHistory = try XCTUnwrap(
            disabled.first { $0.category == .history }
        )
        XCTAssertNil(disabledHistory.preview)
        XCTAssertFalse(disabledHistory.searchableText.contains(visiblePrefix))
        XCTAssertFalse(disabledHistory.searchableText.contains(tailCanary))
    }

    func testSearchUsesAllTermsAndKeepsStableCategoryOrdering() {
        let workflow = makeWorkflow(name: "Cloud Notes")
        let results = GlobalSearchIndex.makeResults(
            language: .english,
            workflows: [workflow],
            historyRecords: [],
            receipts: [],
            historyPreviewMode: .full
        )

        let speechSettings = GlobalSearchIndex.filter(results, query: "openai key")
        XCTAssertEqual(speechSettings.map(\.destination), [.settings(.speech)])
        XCTAssertTrue(
            GlobalSearchIndex.filter(results, query: "sensevoice").isEmpty,
            "Preview-only model names must not leak into the public search index."
        )

        let quickDestinations = GlobalSearchIndex.filter(results, query: "")
        XCTAssertFalse(quickDestinations.isEmpty)
        XCTAssertTrue(
            quickDestinations.allSatisfy {
                $0.category == .pages || $0.category == .settings
            }
        )
        XCTAssertEqual(
            quickDestinations.map(\.category.rawValue),
            quickDestinations.map(\.category.rawValue).sorted()
        )
    }

    func testStaticIndexRemainsUsefulWithoutHistoryStorage() {
        let workflow = makeWorkflow(name: "Offline Notes")
        let results = GlobalSearchIndex.filter(
            GlobalSearchIndex.makeStaticResults(
                language: .english,
                workflows: [workflow]
            ),
            query: "Offline Notes"
        )

        XCTAssertEqual(results.map(\.destination), [.workflow(workflow.id)])
        XCTAssertFalse(results.contains { $0.category == .history })
    }

    func testPlannedWorkflowsStayOutOfProductSearch() {
        let active = makeWorkflow(name: "Ready Workflow")
        var planned = makeWorkflow(name: "Future Workflow")
        planned.metadata[WorkflowMetadataKey.availability] = WorkflowAvailability.planned.rawValue

        let results = GlobalSearchIndex.makeStaticResults(
            language: .english,
            workflows: [planned, active]
        )

        XCTAssertEqual(
            GlobalSearchIndex.filter(results, query: "Ready Workflow").map(\.destination),
            [.workflow(active.id)]
        )
        XCTAssertTrue(
            GlobalSearchIndex.filter(results, query: "Future Workflow").isEmpty
        )
    }

    func testKeyboardSelectionIsVisibleStableAndClampedToResults() throws {
        let results = GlobalSearchIndex.filter(
            GlobalSearchIndex.makeResults(
                language: .english,
                workflows: [],
                historyRecords: [],
                receipts: [],
                historyPreviewMode: .full
            ),
            query: ""
        )
        XCTAssertGreaterThan(results.count, 2)

        let firstID = try XCTUnwrap(results.first?.id)
        let secondID = results[1].id
        let lastID = try XCTUnwrap(results.last?.id)
        XCTAssertEqual(
            GlobalSearchSelection.reconcile(currentID: nil, results: results),
            firstID
        )
        XCTAssertEqual(
            GlobalSearchSelection.move(currentID: firstID, offset: 1, results: results),
            secondID
        )
        XCTAssertEqual(
            GlobalSearchSelection.move(currentID: firstID, offset: -1, results: results),
            firstID
        )
        XCTAssertEqual(
            GlobalSearchSelection.move(currentID: lastID, offset: 1, results: results),
            lastID
        )
        XCTAssertEqual(
            GlobalSearchSelection.reconcile(currentID: "stale", results: results),
            firstID
        )
        XCTAssertNil(
            GlobalSearchSelection.reconcile(currentID: firstID, results: [])
        )
    }

    private func makeResults(
        workflow: WorkflowDefinition,
        record: HistoryRecord,
        previewMode: PrivacyHistoryPreviewMode
    ) -> [GlobalSearchResult] {
        GlobalSearchIndex.makeResults(
            language: .english,
            workflows: [workflow],
            historyRecords: [record],
            receipts: [],
            historyPreviewMode: previewMode
        )
    }

    private func historyMatches(
        _ results: [GlobalSearchResult],
        query: String
    ) -> [GlobalSearchResult] {
        GlobalSearchIndex.filter(results, query: query).filter { $0.category == .history }
    }

    private func makeWorkflow(name: String) -> WorkflowDefinition {
        WorkflowDefinition(
            name: name,
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: "sherpa-onnx.local",
                outputActions: []
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
    }

    private func makeHistorySearchRequest(
        query: String,
        retryGeneration: Int
    ) -> GlobalHistorySearchTaskIdentity {
        GlobalHistorySearchTaskIdentity(
            isPresented: true,
            query: query,
            language: AppLanguage.english.rawValue,
            previewMode: PrivacyHistoryPreviewMode.full.rawValue,
            retentionPeriod: HistoryRetentionPeriod.thirtyDays.rawValue,
            workflowSearchSnapshot: [],
            retryGeneration: retryGeneration
        )
    }
}

@MainActor
extension AppModelTests {
    func testTypedGlobalSearchDestinationsCreateFreshSupersedableRouteRequests() async throws {
        let workflow = makeDefaultWorkflow()
        let harness = makeHarness(workflow: workflow)
        await waitForEventProcessing()

        harness.model.showSettings(.speech)
        let firstSettingsRequest = try XCTUnwrap(harness.model.settingsNavigationRequest)
        XCTAssertEqual(harness.model.selectedSidebarSection, .settings)
        XCTAssertEqual(firstSettingsRequest.section, .speech)

        harness.model.showSettings(.privacy)
        let secondSettingsRequest = try XCTUnwrap(harness.model.settingsNavigationRequest)
        XCTAssertEqual(secondSettingsRequest.section, .privacy)
        XCTAssertNotEqual(firstSettingsRequest.id, secondSettingsRequest.id)

        let historyEntryID = UUID()
        harness.model.showHistoryEntry(historyEntryID)
        XCTAssertEqual(harness.model.selectedSidebarSection, .history)
        XCTAssertEqual(harness.model.runHistoryScope, .recentRuns)
        XCTAssertEqual(harness.model.historyNavigationRequest?.entryID, historyEntryID)

        var workflowWindowOpenCount = 0
        harness.model.installOpenWorkflowEditorAction {
            workflowWindowOpenCount += 1
        }
        harness.model.openWorkflowEditor(workflowID: workflow.id)
        XCTAssertEqual(workflowWindowOpenCount, 1)
        XCTAssertEqual(
            harness.model.workflowEditorNavigationRequest?.workflowID,
            workflow.id
        )

        harness.model.openWorkflowEditor(workflowID: UUID())
        XCTAssertEqual(workflowWindowOpenCount, 1)

        harness.model.openWorkflowEditor()
        XCTAssertEqual(workflowWindowOpenCount, 2)
        XCTAssertNil(harness.model.workflowEditorNavigationRequest)
    }

    func testPlainAndSupersedingRoutesDiscardStaleDetailRequests() async throws {
        let harness = makeHarness(workflow: makeDefaultWorkflow())
        await waitForEventProcessing()

        harness.model.showSettings(.speech)
        XCTAssertNotNil(harness.model.settingsNavigationRequest)
        harness.model.selectSidebarSection(.dashboard)
        XCTAssertNil(harness.model.settingsNavigationRequest)

        harness.model.showHistoryEntry(UUID())
        XCTAssertNotNil(harness.model.historyNavigationRequest)
        harness.model.showSettings(.privacy)
        XCTAssertNil(harness.model.historyNavigationRequest)
        XCTAssertEqual(harness.model.settingsNavigationRequest?.section, .privacy)

        harness.model.showHistoryEntry(UUID())
        XCTAssertNil(harness.model.settingsNavigationRequest)
        XCTAssertNotNil(harness.model.historyNavigationRequest)
        harness.model.showClipboardManagement()
        XCTAssertNil(harness.model.historyNavigationRequest)
    }
}
