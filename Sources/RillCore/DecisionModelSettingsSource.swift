import Foundation
import Synchronization

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
public final class DecisionModelSettingsSource: Sendable {
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

  private struct State: Sendable {
    var selection = DecisionModelConfiguration()
    var credential: Authorization?
    var polishing: Authorization?
  }

  private let state = Mutex(State())

  public init() {}

  public var configuration: DecisionModelConfiguration { state.withLock { $0.selection } }

  public func select(_ configuration: DecisionModelConfiguration) {
    state.withLock { state in
      guard configuration != state.selection else { return }
      state.selection = configuration
      state.credential = nil
      state.polishing = nil
    }
  }

  public var isConfigured: Bool { state.withLock { $0.credential != nil } }
  public var isPolishingEnabled: Bool { state.withLock { $0.polishing != nil } }

  /// Invalid replacements leave the existing credential and consent intact.
  public func setKey(_ value: String) throws {
    let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard key.isEmpty || JevAPIKey.isValid(key) else { throw RecordRankingError.invalidInput }
    try state.withLock { state in
      guard key.isEmpty || state.selection.isValid else { throw RecordRankingError.invalidInput }
      let wasEnabled = state.polishing != nil
      state.credential = key.isEmpty ? nil : Authorization(apiKey: key, configuration: state.selection)
      state.polishing = wasEnabled && !key.isEmpty ? Authorization(apiKey: key, configuration: state.selection) : nil
    }
  }

  public func setPolishingEnabled(_ enabled: Bool) {
    state.withLock { state in
      state.polishing = enabled ? state.credential.map { Authorization(apiKey: $0.apiKey, configuration: $0.configuration) } : nil
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
