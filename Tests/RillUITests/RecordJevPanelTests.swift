import Foundation
import Testing

@testable import RillCore
@testable import RillWorkflows
@testable import RillRecords
@testable import RillKnowledge
@testable import RillUI

@MainActor
struct RecordJevPanelTests {
  @Test func workspaceWiresExplicitRankingWithoutChangingLocalOrderOrRecords() async throws {
    let fixture = JevPanelFixture()
    let first = try await fixture.insert("git reset --soft HEAD~1")
    let second = try await fixture.insert("git revert HEAD")
    let workspace = RecordWorkspaceModel(store: fixture.store, cloudRanking: fixture.service)
    let panel = workspace.makeQuickPanelModel()
    panel.setSearchText("git")
    try await waitUntil { !panel.isSearching && panel.results.count == 2 }
    let ids = panel.results.map(\.id)
    let selected = panel.selectedID
    let before = try await fixture.store.catalogSnapshot().revision
    #expect(panel.canCompareWithJev)
    panel.compareWithJev()
    let model = try #require(panel.jev)
    try await waitUntil { model.state == .review }
    #expect(await fixture.provider.calls == 0)
    #expect(!model.isConfigured)
    model.confirm()
    #expect(model.state == .review)
    model.settings.setKey("unit-test-key")
    try await waitUntil { model.isConfigured }
    model.confirm()
    try await waitUntil { model.state == .ready }
    #expect(await fixture.provider.calls == 1)
    #expect(panel.results.map(\.id) == ids)
    #expect(panel.selectedID == selected)
    panel.selectJevCandidate(first.id)
    #expect(panel.selectedID == first.id)
    #expect(try await fixture.store.catalogSnapshot().revision == before)
    #expect(Set(model.review?.candidates.map(\.id) ?? []) == [first.id, second.id])
    await panel.shutdown()
    #expect(await fixture.service.isConfigured)
    await workspace.shutdown()
    #expect(await !fixture.service.isConfigured)
  }

  @Test func filteringBoundsDisclosureAndQueryChangeCancelsLateResults() async throws {
    let fixture = JevPanelFixture(held: true)
    let allowed = try await fixture.insert("git reset", app: "example.allowed")
    _ = try await fixture.insert("git secret", app: "example.excluded")
    let panel = RecordQuickPanelModel(store: fixture.store, jevSettings: JevAPISettingsModel(service: fixture.service))
    panel.start(sourceBundleIdentifier: "example.allowed")
    try await waitUntil { panel.results.count == 2 && !panel.isSearching }
    panel.setCurrentAppOnly(true)
    panel.setSearchText("git")
    try await waitUntil { panel.results.count == 1 && !panel.isSearching }
    panel.compareWithJev()
    let model = try #require(panel.jev)
    try await waitUntil { model.state == .review }
    #expect(model.review?.candidates.map(\.id) == [allowed.id])
    model.settings.setKey("unit-test-key")
    try await waitUntil { model.isConfigured }
    model.confirm()
    await fixture.provider.waitUntilEntered()
    panel.setSearchText("reset")
    #expect(!model.isPresented)
    #expect(model.review == nil)
    let shutdown = Task { await panel.shutdown() }
    await fixture.provider.release()
    await shutdown.value
    #expect(model.state == .idle)
    #expect(model.result == nil)
    #expect(await fixture.provider.calls == 1)
    await fixture.service.shutdown()
  }

  @Test func closedReviewAndShutdownCannotSubmitAndErrorsAreLocalized() async throws {
    let fixture = JevPanelFixture()
    let record = try await fixture.insert("git sample")
    let model = RecordJevPanelModel(settings: JevAPISettingsModel(service: fixture.service))
    model.prepare(query: "git", recordIDs: [record.id])
    try await waitUntil { model.state == .review }
    model.invalidate()
    model.confirm()
    #expect(await fixture.provider.calls == 0)
    await model.shutdown()
    model.prepare(query: "git", recordIDs: [record.id])
    #expect(!model.isPresented)
    for key in JevText.allCases {
      #expect(!L10n.jev(key, language: .english).isEmpty)
      #expect(!L10n.jev(key, language: .simplifiedChinese).isEmpty)
    }
    await fixture.service.shutdown()
  }

  @Test func settingsKeyIsSharedAcrossReviewsAndClearingBlocksSubmission() async throws {
    let fixture = JevPanelFixture()
    let record = try await fixture.insert("git sample")
    let workspace = RecordWorkspaceModel(store: fixture.store, cloudRanking: fixture.service)
    let settings = try #require(workspace.jevSettings)
    let first = workspace.makeQuickPanelModel()
    let second = workspace.makeQuickPanelModel()
    let firstReview = try #require(first.jev)
    let secondReview = try #require(second.jev)
    #expect(firstReview.settings === settings)
    #expect(secondReview.settings === settings)
    settings.setKey("  unit-test-key  ")
    #expect(settings.isConfigured)
    #expect(await fixture.provider.calls == 0)
    firstReview.prepare(query: "git", recordIDs: [record.id])
    try await waitUntil { firstReview.state == .review }
    settings.setKey("")
    #expect(!firstReview.isConfigured && !secondReview.isConfigured)
    firstReview.confirm()
    #expect(await fixture.provider.calls == 0)
    settings.setKey("replacement-key")
    firstReview.confirm()
    try await waitUntil { firstReview.state == .ready }
    #expect(await fixture.provider.keys == ["replacement-key"])
    await first.shutdown()
    #expect(settings.isConfigured)
    await second.shutdown()
    await workspace.shutdown()
    #expect(!settings.isConfigured)
    #expect(await !fixture.service.isConfigured)
    settings.setKey("after-shutdown-key")
    #expect(!settings.isConfigured)
  }

  @Test func failedCredentialUpdateKeepsExistingKeyAndSurfacesErrorInSettings() async throws {
    let fixture = JevPanelFixture(held: true)
    let record = try await fixture.insert("git sample")
    let settings = JevAPISettingsModel(service: fixture.service)
    let review = RecordJevPanelModel(settings: settings)
    settings.setKey("unit-test-key")
    settings.setKey("bad")
    #expect(settings.error == .invalidInput)
    #expect(settings.isConfigured)
    review.prepare(query: "git", recordIDs: [record.id])
    try await waitUntil { review.state == .review }
    review.confirm()
    await fixture.provider.waitUntilEntered()
    settings.setKey("")
    #expect(settings.error == nil)
    #expect(!settings.isConfigured)
    #expect(await fixture.provider.keys == ["unit-test-key"])
    await fixture.provider.release()
    try await waitUntil { review.state == .failed(.changed) }
    await review.shutdown()
    await settings.shutdown()
  }

  @Test func settingsReturnRebuildsReviewPreservesSelectionAndNeverSends() async throws {
    let fixture = JevPanelFixture()
    let record = try await fixture.insert("git worktree")
    let workspace = RecordWorkspaceModel(store: fixture.store, cloudRanking: fixture.service)
    let original = workspace.makeQuickPanelModel()
    original.start(sourceBundleIdentifier: "example.allowed")
    original.setCurrentAppOnly(true)
    original.setKind(.text)
    original.setSearchText("git")
    try await waitUntil { !original.isSearching && original.results.count == 1 }
    original.compareWithJev()
    let review = try #require(original.jev)
    try await waitUntil { review.state == .review }
    let originalReviewID = review.review?.id
    let context = try #require(original.comparisonReturnContext())
    original.stop()
    #expect(review.review == nil)
    workspace.jevSettings?.setKey("unit-test-key")
    let restored = workspace.makeQuickPanelModel()
    restored.start(sourceBundleIdentifier: nil)
    restored.restoreComparison(context)
    try await waitUntil { restored.jev?.state == .review }
    #expect(restored.searchText == "git" && restored.currentAppOnly && restored.kind == .text)
    #expect(restored.selectedID == record.id)
    #expect(restored.jev?.review?.id != originalReviewID)
    #expect(restored.jev?.review?.candidates.map(\.id) == [record.id])
    #expect(await fixture.provider.calls == 0)
    await original.shutdown()
    await restored.shutdown()
    await workspace.shutdown()
  }

  @Test func deletedCandidateOnSettingsReturnShowsRecoveryWithoutOldPayload() async throws {
    let fixture = JevPanelFixture()
    let record = try await fixture.insert("git worktree")
    let workspace = RecordWorkspaceModel(store: fixture.store, cloudRanking: fixture.service)
    let panel = workspace.makeQuickPanelModel()
    panel.setSearchText("git")
    try await waitUntil { !panel.isSearching && panel.results.count == 1 }
    panel.compareWithJev()
    try await waitUntil { panel.jev?.state == .review }
    let context = try #require(panel.comparisonReturnContext())
    panel.stop()
    try await fixture.store.deleteRecord(record.id)
    panel.restoreComparison(context)
    try await waitUntil { panel.jev?.state == .failed(.changed) }
    #expect(panel.jev?.review == nil)
    #expect(await fixture.provider.calls == 0)
    await panel.shutdown()
    await workspace.shutdown()
  }

  @Test func returnPreservesSemanticOrderAndASelectionOutsideComparedCandidates() async throws {
    let fixture = JevPanelFixture()
    let first = try await fixture.insert("one")
    let second = try await fixture.insert("two")
    let third = try await fixture.insert("three")
    let panel = RecordQuickPanelModel(store: fixture.store, jevSettings: JevAPISettingsModel(service: fixture.service))
    let context = RecordComparisonReturn(query: "meaning", resultLimit: 0, candidateIDs: [first.id],
      semanticIDs: [second.id, first.id, third.id], selectedID: third.id,
      sourceBundleIdentifier: nil, currentAppOnly: false, kind: nil, pinnedOnly: false)
    panel.restoreComparison(context)
    try await waitUntil { panel.jev?.state == .review }
    #expect(panel.semanticResults.map(\.id) == context.semanticIDs)
    #expect(panel.selectedID == third.id)
    #expect(await fixture.provider.calls == 0)
    await panel.shutdown()
    await fixture.service.shutdown()
  }

  @Test func lateInitialCatalogSnapshotDoesNotDismissPreparedComparison() async throws {
    let fixture = JevPanelFixture()
    _ = try await fixture.insert("git worktree")
    let initialSnapshot = try await fixture.store.catalogSnapshot()
    let panel = RecordQuickPanelModel(store: fixture.store, jevSettings: JevAPISettingsModel(service: fixture.service))
    panel.setSearchText("git")
    try await waitUntil { !panel.isSearching && panel.results.count == 1 }
    panel.compareWithJev()
    try await waitUntil { panel.jev?.state == .review }
    let reviewID = panel.jev?.review?.id
    panel.receiveCatalogSnapshot(initialSnapshot)
    #expect(panel.jev?.state == .review)
    #expect(panel.jev?.review?.id == reviewID)
    _ = try await fixture.insert("git stash")
    panel.receiveCatalogSnapshot(try await fixture.store.catalogSnapshot())
    #expect(panel.jev?.state == .idle)
    #expect(panel.isSearching)
    await panel.shutdown()
    await fixture.service.shutdown()
  }

  private func waitUntil(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    #expect(condition(), sourceLocation: sourceLocation)
    try #require(condition(), sourceLocation: sourceLocation)
  }
}

struct JevPanelFixture {
  let store: RecordStore
  let provider: JevPanelProvider
  let service: RecordCloudRanking
  init(held: Bool = false) {
    let store = RecordStore()
    let provider = JevPanelProvider(held: held)
    self.store = store
    self.provider = provider
    service = RecordCloudRanking(store: store, provider: provider,
      privacy: .init(initialSettings: .defaults), currentFocus: {
        .init(applicationName: "Rill", bundleIdentifier: "example.rill", processIdentifier: 1,
          focusedRole: nil, selectedText: "", secureInput: false)
      })
  }
  func insert(_ text: String, app: String = "example.allowed") async throws -> RecordProjection {
    try await store.ingest(.init(payload: .text(text), provenance: .init(
      source: .init(kind: .systemClipboard), sourceApplicationName: "Terminal", sourceBundleIdentifier: app)), into: [])
  }
}

actor JevPanelProvider: RecordRankingProvider {
  let held: Bool
  var calls = 0
  var keys: [String] = []
  private var continuation: CheckedContinuation<Void, Never>?
  private var entered: CheckedContinuation<Void, Never>?
  init(held: Bool) { self.held = held }
  func score(query _: String, candidates: [String], apiKey: String) async -> RecordRankingResponse {
    calls += 1
    keys.append(apiKey)
    if held {
      await withCheckedContinuation {
        continuation = $0
        entered?.resume(); entered = nil
      }
    }
    return .init(scores: candidates.map { $0.contains("--soft") ? 1.8 : 0.4 },
      model: "jev-1.13.0", inputTokens: 321, outputTokens: 0)
  }
  func waitUntilEntered() async {
    if continuation != nil { return }
    await withCheckedContinuation { entered = $0 }
  }
  func release() { continuation?.resume(); continuation = nil }
}
