import AppKit
import ApplicationServices
import VoxTypeCore

@MainActor
public final class FocusTracker: @unchecked Sendable {
    public init() {}

    public func captureCurrent() -> FocusSnapshot {
        let app = NSWorkspace.shared.frontmostApplication
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        let element: AXUIElement? = if focusedStatus == .success,
            let ref = focusedValue, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            unsafeBitCast(ref, to: AXUIElement.self)
        } else {
            nil
        }
        let role = element.flatMap { copyStringAttribute(kAXRoleAttribute as CFString, from: $0) }
        let selectedText = element.flatMap { copyStringAttribute(kAXSelectedTextAttribute as CFString, from: $0) } ?? ""

        return FocusSnapshot(
            applicationName: app?.localizedName,
            bundleIdentifier: app?.bundleIdentifier,
            processIdentifier: app?.processIdentifier,
            focusedRole: role,
            selectedText: selectedText,
            secureInput: false
        )
    }

    private func copyStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
