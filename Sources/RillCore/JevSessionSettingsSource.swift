import Foundation

/// One session credential; ranking and automatic polishing require separate consent.
public final class JevSessionSettingsSource: @unchecked Sendable {
  public struct Authorization: Sendable {
    public let id: UUID
    public let apiKey: String
  }

  private let lock = NSLock()
  private var credential: Authorization?
  private var polishing: Authorization?

  public init() {}

  public var isConfigured: Bool { lock.withLock { credential != nil } }
  public var isPolishingEnabled: Bool { lock.withLock { polishing != nil } }

  /// Invalid replacements leave the existing credential and consent intact.
  public func setKey(_ value: String) throws {
    let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard key.isEmpty || JevAPIKey.isValid(key) else { throw RecordRankingError.invalidInput }
    lock.withLock {
      let wasEnabled = polishing != nil
      credential = key.isEmpty ? nil : Authorization(id: UUID(), apiKey: key)
      polishing = wasEnabled && !key.isEmpty ? Authorization(id: UUID(), apiKey: key) : nil
    }
  }

  public func setPolishingEnabled(_ enabled: Bool) {
    lock.withLock {
      polishing = enabled ? credential.map { Authorization(id: UUID(), apiKey: $0.apiKey) } : nil
    }
  }

  public func rankingAuthorization() -> Authorization? { lock.withLock { credential } }
  public func currentAuthorization() -> Authorization? { lock.withLock { polishing } }
  public func isCurrent(_ value: Authorization) -> Bool {
    lock.withLock { credential?.id == value.id || polishing?.id == value.id }
  }

  public func clear() { lock.withLock { credential = nil; polishing = nil } }
}
