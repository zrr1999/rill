import Foundation
import Observation
import RillCore
import RillRuntime

/// Shares the session credential status between Settings and candidate reviews.
@MainActor @Observable
public final class JevAPISettingsModel {
  public private(set) var isConfigured = false
  public private(set) var isSaving = false
  public private(set) var error: RecordRankingError?
  let service: RecordCloudRanking
  private var saveTask: Task<Void, Never>?
  private var closed = false

  public init(service: RecordCloudRanking) { self.service = service }
  isolated deinit { saveTask?.cancel() }

  public func setKey(_ value: String) {
    guard !closed, !isSaving else { return }
    let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
    isSaving = true
    error = nil
    saveTask = Task { [weak self, service] in
      defer { self?.isSaving = false }
      do {
        try Task.checkCancellation()
        try await service.setKey(key)
        let configured = await service.isConfigured
        guard !Task.isCancelled, let self, !self.closed else { return }
        self.isConfigured = configured
      } catch {
        guard !Task.isCancelled, let self, !self.closed else { return }
        self.error = (error as? RecordRankingError) ?? .unavailable
      }
    }
  }

  public func shutdown() async {
    closed = true
    saveTask?.cancel()
    await saveTask?.value
    await service.shutdown()
    isConfigured = false
  }
}
