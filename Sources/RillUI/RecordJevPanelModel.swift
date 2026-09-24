import Foundation
import Observation
import RillCore
import RillRuntime

@MainActor @Observable
public final class RecordJevPanelModel {
  public enum State: Equatable {
    case idle, preparing, review, scoring, ready, failed(RecordRankingError)
  }
  public private(set) var state: State = .idle
  public private(set) var review: RecordRankingReview?
  public private(set) var candidateIDs: [RecordID] = []
  public private(set) var query = ""
  public private(set) var result: RecordCloudRankingResult?
  public var isConfigured: Bool { settings.isConfigured }
  public let settings: JevAPISettingsModel
  public var isPresented = false
  private let service: RecordCloudRanking
  private var generation: UInt64 = 0
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var closed = false

  public init(settings: JevAPISettingsModel) {
    self.settings = settings
    self.service = settings.service
  }
  isolated deinit { for task in tasks.values { task.cancel() } }

  public var isWorking: Bool { state == .preparing || state == .scoring }

  public func prepare(query: String, recordIDs: [RecordID]) {
    guard !closed, !isWorking else { return }
    invalidate()
    self.query = query
    candidateIDs = recordIDs
    isPresented = true
    state = .preparing
    run { [self] in
      let prepared = try await service.prepare(query: query, recordIDs: recordIDs)
      try Task.checkCancellation()
      review = prepared
      state = .review
    }
  }

  public func confirm() {
    guard !closed, state == .review, isConfigured, let review else { return }
    state = .scoring
    run { [self] in
      let scored = try await service.confirm(review)
      try Task.checkCancellation()
      result = scored
      state = .ready
    }
  }

  func showChangedCandidates(query: String, recordIDs: [RecordID]) {
    invalidate()
    self.query = query
    candidateIDs = recordIDs
    state = .failed(.changed)
    isPresented = true
  }

  public func invalidate() {
    generation &+= 1
    for task in tasks.values { task.cancel() }
    review = nil
    result = nil
    candidateIDs = []
    query = ""
    state = .idle
    isPresented = false
  }

  public func shutdown() async {
    closed = true
    invalidate()
    for task in Array(tasks.values) { await task.value }
  }

  private func run(_ operation: @escaping @MainActor () async throws -> Void) {
    let id = UUID()
    let version = generation
    tasks[id] = Task { [weak self] in
      defer { self?.tasks.removeValue(forKey: id) }
      do { try await operation() }
      catch {
        guard !Task.isCancelled, let self, self.generation == version else { return }
        self.state = .failed((error as? RecordRankingError) ?? .unavailable)
      }
    }
  }
}
