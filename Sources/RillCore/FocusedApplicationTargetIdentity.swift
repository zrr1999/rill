import Foundation

/// Content-free application identity captured before a clipboard panel paste
/// begins. It never carries selected text, clipboard data, or UI content.
public struct FocusedApplicationTargetIdentity: Sendable, Equatable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String?

    public init?(processIdentifier: Int32, bundleIdentifier: String?) {
        guard processIdentifier > 0 else { return nil }
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier?.isEmpty == false ? bundleIdentifier : nil
    }

    public init?(focus: FocusSnapshot) {
        guard let processIdentifier = focus.processIdentifier else { return nil }
        self.init(
            processIdentifier: processIdentifier,
            bundleIdentifier: focus.bundleIdentifier
        )
    }

    public func matches(_ focus: FocusSnapshot) -> Bool {
        guard focus.processIdentifier == processIdentifier else { return false }
        if let bundleIdentifier {
            return focus.bundleIdentifier == bundleIdentifier
        }
        return true
    }
}
