import Foundation

public enum SystemClipboardCaptureControlState: String, Codable, Sendable, Equatable {
    case active
    case pausing
    case paused
    case resuming
    case armingIgnoreNextExternalChange
    case ignoringNextExternalChange

    public var isPaused: Bool {
        switch self {
        case .pausing, .paused, .resuming:
            true
        case .active, .armingIgnoreNextExternalChange, .ignoringNextExternalChange:
            false
        }
    }

    public var isIgnoringNextExternalChange: Bool {
        switch self {
        case .armingIgnoreNextExternalChange, .ignoringNextExternalChange:
            true
        case .active, .pausing, .paused, .resuming:
            false
        }
    }

    public var isTransitioning: Bool {
        switch self {
        case .pausing, .resuming, .armingIgnoreNextExternalChange:
            true
        case .active, .paused, .ignoringNextExternalChange:
            false
        }
    }
}

public struct SystemClipboardCaptureControlSnapshot: Codable, Sendable, Equatable {
    public var revision: UInt64
    public var state: SystemClipboardCaptureControlState

    public init(revision: UInt64, state: SystemClipboardCaptureControlState) {
        self.revision = revision
        self.state = state
    }

    public static let initial = SystemClipboardCaptureControlSnapshot(
        revision: 0,
        state: .active
    )
}
