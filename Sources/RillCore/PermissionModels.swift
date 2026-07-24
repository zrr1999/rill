import Foundation

public enum PermissionState: String, Codable, Sendable, Equatable {
    case unknown
    case granted
    case denied
}

/// Product-facing state for the shared global keyboard event tap.
///
/// Permission preflight alone is not enough: macOS can report that event
/// listening is authorized while the active event tap still fails to install.
/// `available` therefore means the tap itself is installed for this process.
public enum GlobalInputCapability: Sendable, Equatable {
    case checking
    case available
    case permissionRequired
    case installationFailed

    public var isAvailable: Bool {
        self == .available
    }
}

public struct PermissionSnapshot: Codable, Sendable, Equatable {
    public var accessibility: PermissionState
    public var microphone: PermissionState

    public init(accessibility: PermissionState, microphone: PermissionState) {
        self.accessibility = accessibility
        self.microphone = microphone
    }
}
