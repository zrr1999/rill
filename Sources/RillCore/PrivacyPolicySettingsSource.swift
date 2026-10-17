import Foundation
import Synchronization

public enum PrivacyPolicySettingsSourceError: Error, LocalizedError, Sendable, Equatable {
  case notReady
  case unavailable(String)

  public var errorDescription: String? {
    switch self {
    case .notReady:
      return "Privacy settings are still loading."
    case .unavailable(let reason):
      return "Privacy settings are unavailable: \(reason)"
    }
  }
}

/// The process-wide source of truth used by UI and runtime privacy gates.
///
/// Reads and updates are synchronous so a validated UI change is visible to the
/// next runtime decision before persistence begins. An uninitialized or failed
/// source throws, allowing callers to fail closed.
public final class PrivacyPolicySettingsSource: Sendable {
  public struct Snapshot: Sendable, Equatable {
    public let settings: PrivacyPolicySettings
    public let revision: UInt64
  }

  private enum Value: Sendable {
    case loading
    case available(PrivacyPolicySettings)
    case unavailable(String)
  }

  private struct State: Sendable {
    var value: Value
    var revision: UInt64
  }

  private let state: Mutex<State>

  public init(initialSettings: PrivacyPolicySettings? = nil) {
    state = Mutex(
      State(
        value: initialSettings.map(Value.available) ?? .loading,
        revision: 0
      )
    )
  }

  public func currentSettings() throws -> PrivacyPolicySettings {
    try currentSnapshot().settings
  }

  public func currentSnapshot() throws -> Snapshot {
    try state.withLock { state in
      switch state.value {
      case .loading:
        throw PrivacyPolicySettingsSourceError.notReady
      case .available(let settings):
        return Snapshot(settings: settings, revision: state.revision)
      case .unavailable(let reason):
        throw PrivacyPolicySettingsSourceError.unavailable(reason)
      }
    }
  }

  public var hasAvailableSettings: Bool {
    state.withLock { state in
      if case .available = state.value { return true }
      return false
    }
  }

  public func update(_ settings: PrivacyPolicySettings) {
    state.withLock { state in
      state.value = .available(settings)
      state.revision &+= 1
    }
  }

  public func markUnavailable(reason: String) {
    state.withLock { state in
      state.value = .unavailable(reason)
      state.revision &+= 1
    }
  }
}
