import Foundation

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
public final class PrivacyPolicySettingsSource: @unchecked Sendable {
    private enum State {
        case loading
        case available(PrivacyPolicySettings)
        case unavailable(String)
    }

    private let lock = NSLock()
    private var state: State

    public init(initialSettings: PrivacyPolicySettings? = nil) {
        state = initialSettings.map(State.available) ?? .loading
    }

    public func currentSettings() throws -> PrivacyPolicySettings {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .loading:
            throw PrivacyPolicySettingsSourceError.notReady
        case .available(let settings):
            return settings
        case .unavailable(let reason):
            throw PrivacyPolicySettingsSourceError.unavailable(reason)
        }
    }

    public var hasAvailableSettings: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .available = state {
            return true
        }
        return false
    }

    public func update(_ settings: PrivacyPolicySettings) {
        lock.lock()
        state = .available(settings)
        lock.unlock()
    }

    public func markUnavailable(reason: String) {
        lock.lock()
        state = .unavailable(reason)
        lock.unlock()
    }
}
