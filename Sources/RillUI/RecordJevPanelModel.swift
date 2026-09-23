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
  public private(set) var result: RecordCloudRankingResult?
  public private(set) var isConfigured = false
  public var isPresented = false
  private let service: RecordCloudRanking
  private var generation: UInt64 = 0
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var closed = false

  public init(service: RecordCloudRanking) { self.service = service }
  isolated deinit { for task in tasks.values { task.cancel() } }

  public var isWorking: Bool { state == .preparing || state == .scoring }

  public func prepare(query: String, recordIDs: [RecordID]) {
    guard !closed, !isWorking else { return }
    invalidate()
    isPresented = true
    state = .preparing
    run { [self] in
      isConfigured = await service.isConfigured
      let prepared = try await service.prepare(query: query, recordIDs: recordIDs)
      try Task.checkCancellation()
      review = prepared
      state = .review
    }
  }

  public func setKey(_ value: String) {
    guard !closed, !isWorking else { return }
    run { [self] in
      try await service.setKey(value)
      try Task.checkCancellation()
      isConfigured = await service.isConfigured
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

  public func invalidate() {
    generation &+= 1
    for task in tasks.values { task.cancel() }
    review = nil
    result = nil
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
