import Foundation

public enum PermissionState: String, Codable, Sendable, Equatable {
    case unknown
    case granted
    case denied
}

public struct PermissionSnapshot: Codable, Sendable, Equatable {
    public var accessibility: PermissionState
    public var microphone: PermissionState

    public init(accessibility: PermissionState, microphone: PermissionState) {
        self.accessibility = accessibility
        self.microphone = microphone
    }
}
