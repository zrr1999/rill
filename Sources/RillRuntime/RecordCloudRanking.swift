import Foundation
import RillCore

public struct RecordRankingReview: Sendable, Identifiable {
  public let id: UUID
  public let query: String
  public let candidates: [Candidate]
  fileprivate let catalogRevision: UInt64
  fileprivate let created: ContinuousClock.Instant
  public struct Candidate: Sendable, Identifiable {
    public let id: RecordID
    public let text: String
    public let isTruncated: Bool
  }
}

public struct RecordCloudRankingResult: Sendable {
  public let review: RecordRankingReview
  public let response: RecordRankingResponse
  public let elapsedMilliseconds: Double
  public var orderedIndices: [Int] {
    response.scores.indices.sorted {
      response.scores[$0] == response.scores[$1] ? $0 < $1 : response.scores[$0] > response.scores[$1]
    }
  }
}

/// Owns a session-only key and a single-use review. RecordStore remains the catalog authority.
public actor RecordCloudRanking {
  private let store: RecordStore
  private let provider: any RecordRankingProvider
  private let privacy: PrivacyPolicySettingsSource
  private let currentFocus: @Sendable () async -> FocusSnapshot
  private var apiKey = ""
  private var preparedID: UUID?
  private var active: Task<RecordCloudRankingResult, Error>?
  private var closed = false

  public init(store: RecordStore, provider: any RecordRankingProvider,
    privacy: PrivacyPolicySettingsSource, currentFocus: @escaping @Sendable () async -> FocusSnapshot) {
    self.store = store
    self.provider = provider
    self.privacy = privacy
    self.currentFocus = currentFocus
  }

  public var isConfigured: Bool { !apiKey.isEmpty }

  public func setKey(_ key: String) throws {
    guard !closed else { throw CancellationError() }
    guard active == nil else { throw RecordRankingError.busy }
    guard key.isEmpty || JevAPIKey.isValid(key)
    else { throw RecordRankingError.invalidInput }
    apiKey = key
  }

  public func prepare(query: String, recordIDs: [RecordID]) async throws -> RecordRankingReview {
    guard !closed else { throw CancellationError() }
    guard active == nil else { throw RecordRankingError.busy }
    preparedID = nil
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.utf8.count <= 1_800,
      (1...10).contains(recordIDs.count), Set(recordIDs).count == recordIDs.count
    else { throw RecordRankingError.invalidInput }
    let snapshot = try await store.catalogSnapshot()
    var candidates: [RecordRankingReview.Candidate] = []
    let settings = try settings()
    for id in recordIDs {
      try Task.checkCancellation()
      guard let record = try await store.record(id: id) else { throw RecordRankingError.changed }
      try checkProvenance(record.record.provenance, settings: settings)
      let text: String
      switch record.record.payload {
      case .text(let value): text = value
      case .files(let urls): text = urls.map(\.lastPathComponent).joined(separator: "\n")
      case .image: continue
      }
      guard !text.isEmpty else { continue }
      var bytes = Array(text.utf8.prefix(1_800))
      while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
      let clipped = String(decoding: bytes, as: UTF8.self)
      candidates.append(.init(id: id, text: clipped, isTruncated: clipped != text))
    }
    guard !candidates.isEmpty else { throw RecordRankingError.invalidInput }
    let review = RecordRankingReview(id: UUID(), query: query, candidates: candidates,
      catalogRevision: snapshot.revision, created: .now)
    try await validate(review)
    guard !closed else { throw CancellationError() }
    preparedID = review.id
    return review
  }

  /// Called only after the user reviews the exact query and clipped text in the UI.
  public func confirm(_ review: RecordRankingReview) async throws -> RecordCloudRankingResult {
    guard !closed else { throw CancellationError() }
    guard active == nil else { throw RecordRankingError.busy }
    guard !apiKey.isEmpty else { throw RecordRankingError.missingKey }
    guard preparedID == review.id, review.created.duration(to: .now) < .seconds(600)
    else { throw RecordRankingError.changed }
    preparedID = nil
    let key = apiKey
    let task = Task { [self] in
      try await validate(review)
      try Task.checkCancellation()
      let start = ContinuousClock.now
      let response = try await provider.score(query: review.query, candidates: review.candidates.map(\.text), apiKey: key)
      try await validate(review)
      guard response.scores.count == review.candidates.count,
        response.scores.allSatisfy({ $0.isFinite && (0...2).contains($0) })
      else { throw RecordRankingError.invalidResponse }
      let elapsed = start.duration(to: .now).components
      return RecordCloudRankingResult(review: review, response: response,
        elapsedMilliseconds: Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
    }
    active = task
    defer { active = nil }
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }

  public func shutdown() async {
    closed = true
    preparedID = nil
    apiKey = ""
    active?.cancel()
    _ = await active?.result
  }

  private func settings() throws -> PrivacyPolicySettings {
    do { return try privacy.currentSettings() } catch { throw RecordRankingError.privacyBlocked }
  }

  private func validate(_ review: RecordRankingReview) async throws {
    try Task.checkCancellation()
    guard !closed else { throw CancellationError() }
    let focus = await currentFocus()
    let snapshot = try await store.catalogSnapshot()
    try Task.checkCancellation()
    guard snapshot.revision == review.catalogRevision else { throw RecordRankingError.changed }
    let settings = try settings()
    let context = ContextSnapshot(focus: focus, clipboard: .init(plainText: "", changeCount: 0))
    let decision = PrivacyPolicy.evaluate(context: context, processingDestinations: [.cloudText], settings: settings)
    guard !decision.blocksCloudProcessing, !(focus.secureInput && settings.secureInputConservativeMode)
    else { throw RecordRankingError.privacyBlocked }
    for candidate in review.candidates {
      guard let record = snapshot.records.first(where: { $0.id == candidate.id }) else { throw RecordRankingError.changed }
      try checkProvenance(record.header.provenance, settings: settings)
    }
  }

  private func checkProvenance(_ provenance: RecordProvenance, settings: PrivacyPolicySettings) throws {
    let focus = FocusSnapshot(applicationName: provenance.sourceApplicationName,
      bundleIdentifier: provenance.sourceBundleIdentifier, processIdentifier: nil, focusedRole: nil,
      selectedText: "", secureInput: false)
    let context = ContextSnapshot(focus: focus,
      clipboard: .init(plainText: "", changeCount: 0, captureTags: provenance.captureTags))
    let decision = PrivacyPolicy.evaluate(context: context, processingDestinations: [.cloudText], settings: settings)
    guard !decision.blocksCloudProcessing, decision.allowsWorkflowCapture else { throw RecordRankingError.privacyBlocked }
  }
}
