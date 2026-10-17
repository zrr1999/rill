import Foundation
import Synchronization

/// One session credential; ranking and automatic polishing require separate consent.
public final class JevSessionSettingsSource: Sendable {
  public struct Authorization: Sendable {
    public let id: UUID
    public let apiKey: String
  }

  private struct State: Sendable {
    var credential: Authorization?
    var polishing: Authorization?
  }

  private let state = Mutex(State())

  public init() {}

  public var isConfigured: Bool { state.withLock { $0.credential != nil } }
  public var isPolishingEnabled: Bool { state.withLock { $0.polishing != nil } }

  /// Invalid replacements leave the existing credential and consent intact.
  public func setKey(_ value: String) throws {
    let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard key.isEmpty || JevAPIKey.isValid(key) else { throw RecordRankingError.invalidInput }
    state.withLock { state in
      let wasEnabled = state.polishing != nil
      state.credential = key.isEmpty ? nil : Authorization(id: UUID(), apiKey: key)
      state.polishing = wasEnabled && !key.isEmpty ? Authorization(id: UUID(), apiKey: key) : nil
    }
  }

  public func setPolishingEnabled(_ enabled: Bool) {
    state.withLock { state in
      state.polishing = enabled ? state.credential.map { Authorization(id: UUID(), apiKey: $0.apiKey) } : nil
    }
  }

  public func rankingAuthorization() -> Authorization? { state.withLock { $0.credential } }
  public func currentAuthorization() -> Authorization? { state.withLock { $0.polishing } }
  public func isCurrent(_ value: Authorization) -> Bool {
    state.withLock { $0.credential?.id == value.id || $0.polishing?.id == value.id }
  }

  public func clear() {
    state.withLock { state in
      state.credential = nil
      state.polishing = nil
    }
  }
}
