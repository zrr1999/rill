import Foundation

/// A decision before rewriting; a skipped rewrite must not produce an LLM trace.
public protocol TextPolishingGate: Sendable {
  func shouldSkip(text: String, step: PostProcessStep, context: TransformContext) async throws -> Bool
}

/// Session-only consent and credentials. Changes synchronously revoke an in-flight decision.
public final class JevPolishingSettingsSource: @unchecked Sendable {
  public struct Authorization: Sendable {
    public let id: UUID
    public let apiKey: String
  }

  private let lock = NSLock()
  private var authorization: Authorization?

  public init() {}

  public static func isValidKey(_ key: String) -> Bool {
    JevAPIKey.isValid(key)
  }

  public func update(isEnabled: Bool, apiKey: String) {
    lock.withLock {
      authorization = isEnabled && Self.isValidKey(apiKey)
        ? Authorization(id: UUID(), apiKey: apiKey) : nil
    }
  }

  public func currentAuthorization() -> Authorization? {
    lock.withLock { authorization }
  }

  public func isCurrent(_ value: Authorization) -> Bool {
    lock.withLock { authorization?.id == value.id }
  }
}
