import Foundation

public enum DecisionModel: String, Codable, CaseIterable, Identifiable, Sendable {
  case jev
  case clef
  case clefFlash = "clef-flash"

  public var id: String { rawValue }
  public var modelID: String { self == .jev ? "jev-1.13.0" : rawValue }
  public var displayName: String {
    switch self {
    case .jev: "TypeSafe · Jev"
    case .clef: "Cloudflare · Clef"
    case .clefFlash: "Cloudflare · Clef Flash"
    }
  }
}

public struct DecisionModelConfiguration: Sendable, Equatable {
  public var model: DecisionModel
  public var accountID: String

  public init(model: DecisionModel = .jev, accountID: String = "") {
    self.model = model
    self.accountID = accountID
  }

  public var isValid: Bool {
    model == .jev
      || (accountID.utf8.count == 32
        && accountID.utf8.allSatisfy {
          (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        })
  }

  public var endpoint: URL? {
    guard isValid else { return nil }
    if model == .jev { return URL(string: "https://api.typesafe.ai/v1/systemone") }
    return URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountID)/ai/run/@cf/cloudflare/\(model.rawValue)")
  }
}

/// One global session configuration; ranking and automatic polishing require separate consent.
public final class DecisionModelSettingsSource: @unchecked Sendable {
  public struct Authorization: Sendable, Equatable {
    public let id: UUID
    public let apiKey: String
    public let configuration: DecisionModelConfiguration

    public init(id: UUID = UUID(), apiKey: String, configuration: DecisionModelConfiguration = .init()) {
      self.id = id
      self.apiKey = apiKey
      self.configuration = configuration
    }
  }

  private let lock = NSLock()
  private var selection = DecisionModelConfiguration()
  private var credential: Authorization?
  private var polishing: Authorization?

  public init() {}

  public var configuration: DecisionModelConfiguration { lock.withLock { selection } }

  public func select(_ configuration: DecisionModelConfiguration) {
    lock.withLock {
      guard configuration != selection else { return }
      selection = configuration
      credential = nil
      polishing = nil
    }
  }

  public var isConfigured: Bool { lock.withLock { credential != nil } }
  public var isPolishingEnabled: Bool { lock.withLock { polishing != nil } }

  /// Invalid replacements leave the existing credential and consent intact.
  public func setKey(_ value: String) throws {
    let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard key.isEmpty || JevAPIKey.isValid(key) else { throw RecordRankingError.invalidInput }
    try lock.withLock {
      guard key.isEmpty || selection.isValid else { throw RecordRankingError.invalidInput }
      let wasEnabled = polishing != nil
      credential = key.isEmpty ? nil : Authorization(apiKey: key, configuration: selection)
      polishing = wasEnabled && !key.isEmpty ? Authorization(apiKey: key, configuration: selection) : nil
    }
  }

  public func setPolishingEnabled(_ enabled: Bool) {
    lock.withLock {
      polishing = enabled ? credential.map { Authorization(apiKey: $0.apiKey, configuration: $0.configuration) } : nil
    }
  }

  public func rankingAuthorization() -> Authorization? { lock.withLock { credential } }
  public func currentAuthorization() -> Authorization? { lock.withLock { polishing } }
  public func isCurrent(_ value: Authorization) -> Bool {
    lock.withLock { credential?.id == value.id || polishing?.id == value.id }
  }

  public func clear() {
    lock.withLock {
      credential = nil
      polishing = nil
    }
  }
}
