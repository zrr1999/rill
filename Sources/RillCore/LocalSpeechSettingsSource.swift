import Foundation
import Synchronization

public enum LocalSpeechSettingsSourceError: Error, LocalizedError, Sendable, Equatable {
  case notReady
  case unavailable

  public var errorDescription: String? {
    switch self {
    case .notReady:
      "Local speech settings are still loading."
    case .unavailable:
      "Local speech settings are unavailable."
    }
  }
}

/// The process-wide source of truth used by the UI and local speech runtime.
///
/// Reads and updates are synchronous so a validated UI change is visible to a
/// global-hotkey run before its debounced persistence write begins. Loading or
/// unavailable state is explicit, allowing runtime callers to fail closed.
public final class LocalSpeechSettingsSource: Sendable {
  private enum State: Sendable {
    case loading
    case available(LocalSpeechSettings)
    case unavailable
  }

  private let state: Mutex<State>

  public init(initialSettings: LocalSpeechSettings? = nil) {
    state = Mutex(initialSettings.map(State.available) ?? .loading)
  }

  public func currentSettings() throws -> LocalSpeechSettings {
    try state.withLock { state in
      switch state {
      case .loading:
        throw LocalSpeechSettingsSourceError.notReady
      case .available(let settings):
        return settings
      case .unavailable:
        throw LocalSpeechSettingsSourceError.unavailable
      }
    }
  }

  public var hasAvailableSettings: Bool {
    state.withLock { state in
      if case .available = state { return true }
      return false
    }
  }

  public func update(_ settings: LocalSpeechSettings) {
    state.withLock { $0 = .available(settings) }
  }

  public func markUnavailable() {
    state.withLock { $0 = .unavailable }
  }
}
