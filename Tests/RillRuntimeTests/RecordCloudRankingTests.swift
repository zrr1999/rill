import Foundation
import Testing

@testable import RillCore
@testable import RillWorkflows
@testable import RillRecords
@testable import RillKnowledge

struct RecordCloudRankingTests {
  @Test func reviewIsBoundedAndDoesNotCallProviderUntilConfirmed() async throws {
    let (store, privacy, provider, service) = fixture()
    let record = try await store.ingest(draft(String(repeating: "中😀", count: 1_000)), into: [])
    let file = try await store.ingest(.init(payload: .files([URL(fileURLWithPath: "/private/folder/report.pdf")]),
      provenance: provenance()), into: [])
    let before = try await store.catalogSnapshot()
    let review = try await service.prepare(query: "report", recordIDs: [record.id, file.id])
    #expect(await provider.calls == 0)
    #expect(review.candidates[0].isTruncated)
    #expect(review.candidates[0].text.utf8.count <= 1_800)
    #expect(!review.candidates[0].text.contains("�"))
    #expect(review.candidates[1].text == "report.pdf")
    await #expect(throws: RecordRankingError.missingKey) { try await service.confirm(review) }
    try await service.setKey("unit-test-key")
    let result = try await service.confirm(review)
    #expect(result.orderedIndices == [1, 0])
    #expect(await provider.inputs == review.candidates.map(\.text))
    await #expect(throws: RecordRankingError.changed) { try await service.confirm(review) }
    #expect(await provider.calls == 1)
    #expect(try await store.catalogSnapshot().revision == before.revision)
    #expect(try privacy.currentSettings() == .defaults)
    await service.shutdown()
    #expect(await !service.isConfigured)
  }

  @Test func deletionAndPrivacyChangesPreventSendingPreviouslyReviewedText() async throws {
    let (store, privacy, provider, service) = fixture()
    let record = try await store.ingest(draft("sample"), into: [])
    try await service.setKey("unit-test-key")
    let review = try await service.prepare(query: "sample", recordIDs: [record.id])
    privacy.update(.init(sensitiveAppRules: [.init(bundleIdentifier: "example.source", blocksCloudProcessing: true)]))
    await #expect(throws: RecordRankingError.privacyBlocked) { try await service.confirm(review) }
    #expect(await provider.calls == 0)
    privacy.update(.defaults)
    let refreshed = try await service.prepare(query: "sample", recordIDs: [record.id])
    try await store.deleteRecord(record.id)
    await #expect(throws: RecordRankingError.changed) { try await service.confirm(refreshed) }
    #expect(await provider.calls == 0)
    await service.shutdown()
  }

  @Test func unknownSourcesCaptureExclusionsAndUnavailablePrivacyFailClosed() async throws {
    let (store, privacy, provider, service) = fixture()
    let unknown = try await store.ingest(.init(payload: .text("unknown"), provenance: .init(source: .init(kind: .systemClipboard))), into: [])
    var tagged = provenance()
    tagged.captureTags = [.excludeFromWorkflowCapture]
    let excluded = try await store.ingest(.init(payload: .text("excluded"), provenance: tagged), into: [])
    for id in [unknown.id, excluded.id] {
      await #expect(throws: RecordRankingError.privacyBlocked) { try await service.prepare(query: "q", recordIDs: [id]) }
    }
    privacy.markUnavailable(reason: "fixture")
    await #expect(throws: RecordRankingError.privacyBlocked) { try await service.prepare(query: "q", recordIDs: [unknown.id]) }
    #expect(await provider.calls == 0)
    await service.shutdown()
  }

  @Test func cancelledUncooperativeProviderKeepsSlotUntilDrainedAndCannotPublish() async throws {
    let (store, _, provider, service) = fixture(held: true)
    let record = try await store.ingest(draft("sample"), into: [])
    try await service.setKey("unit-test-key")
    let review = try await service.prepare(query: "sample", recordIDs: [record.id])
    let task = Task { try await service.confirm(review) }
    await provider.waitUntilEntered()
    task.cancel()
    try await service.setKey("")
    #expect(await !service.isConfigured)
    let shutdown = Task { await service.shutdown() }
    await provider.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    await shutdown.value
    #expect(await !service.isConfigured)
    #expect(await provider.calls == 1)
  }

  @Test func catalogChangeDuringRequestDiscardsReturnedScores() async throws {
    let (store, _, provider, service) = fixture(held: true)
    let record = try await store.ingest(draft("sample"), into: [])
    try await service.setKey("unit-test-key")
    let review = try await service.prepare(query: "sample", recordIDs: [record.id])
    let task = Task { try await service.confirm(review) }
    await provider.waitUntilEntered()
    try await store.deleteRecord(record.id)
    await provider.release()
    await #expect(throws: RecordRankingError.changed) { try await task.value }
    await service.shutdown()
  }

  @Test func privacyRevocationDuringRequestDiscardsReturnedScores() async throws {
    let (store, privacy, provider, service) = fixture(held: true)
    let record = try await store.ingest(draft("sample"), into: [])
    try await service.setKey("unit-test-key")
    let review = try await service.prepare(query: "sample", recordIDs: [record.id])
    let task = Task { try await service.confirm(review) }
    await provider.waitUntilEntered()
    privacy.update(.init(sensitiveAppRules: [.init(bundleIdentifier: "example.source", blocksCloudProcessing: true)]))
    await provider.release()
    await #expect(throws: RecordRankingError.privacyBlocked) { try await task.value }
    await service.shutdown()
  }

  private func fixture(held: Bool = false) -> (RecordStore, PrivacyPolicySettingsSource, RankingFixture, RecordCloudRanking) {
    let store = RecordStore()
    let privacy = PrivacyPolicySettingsSource(initialSettings: .defaults)
    let provider = RankingFixture(held: held)
    let service = RecordCloudRanking(store: store, provider: provider, privacy: privacy, currentFocus: {
      .init(applicationName: "Notes", bundleIdentifier: "example.target", processIdentifier: 123,
        focusedRole: nil, selectedText: "", secureInput: false)
    })
    return (store, privacy, provider, service)
  }
  private func provenance() -> RecordProvenance {
    .init(source: .init(kind: .systemClipboard), sourceApplicationName: "Editor", sourceBundleIdentifier: "example.source")
  }
  private func draft(_ text: String) -> RecordDraft { .init(payload: .text(text), provenance: provenance()) }
}

private actor RankingFixture: RecordRankingProvider {
  private let held: Bool
  private var continuation: CheckedContinuation<Void, Never>?
  private var entered: CheckedContinuation<Void, Never>?
  var calls = 0
  var inputs: [String] = []
  init(held: Bool) { self.held = held }
  func score(query _: String, candidates: [String], apiKey _: String) async -> RecordRankingResponse {
    inputs = candidates
    calls += 1
    if held {
      await withCheckedContinuation { continuation in
        self.continuation = continuation
        entered?.resume(); entered = nil
      }
    }
    return .init(scores: candidates.indices.map { $0 == 0 ? 0.2 : 1.8 }, model: "jev-1.13.0", inputTokens: 50, outputTokens: 10)
  }
  func waitUntilEntered() async {
    if continuation != nil { return }
    await withCheckedContinuation { entered = $0 }
  }
  func release() { continuation?.resume(); continuation = nil }
}
