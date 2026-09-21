import AppKit
import ApplicationServices
import Carbon
import RillCore

@MainActor
public final class FocusTracker: NSObject, @unchecked Sendable {
    private var applicationActivationRevision: UInt64 = 0

    public override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

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
            unsafeDowncast(ref, to: AXUIElement.self)
        } else {
            nil
        }
        let role = element.flatMap { copyStringAttribute(kAXRoleAttribute as CFString, from: $0) }
        let secureInputBeforeSelectionRead = IsSecureEventInputEnabled()
        let selectedText = secureInputBeforeSelectionRead
            ? ""
            : element.flatMap { copyStringAttribute(kAXSelectedTextAttribute as CFString, from: $0) } ?? ""
        let secureInputAfterSelectionRead = IsSecureEventInputEnabled()
        let secureInput = secureInputBeforeSelectionRead || secureInputAfterSelectionRead

        return FocusSnapshot(
            applicationName: app?.localizedName,
            bundleIdentifier: app?.bundleIdentifier,
            processIdentifier: app?.processIdentifier,
            focusedRole: role,
            selectedText: secureInput ? "" : selectedText,
            secureInput: secureInput
        )
    }

    public func capturePrivacyIdentity() -> FocusSnapshot {
        let app = NSWorkspace.shared.frontmostApplication
        return FocusSnapshot(
            applicationName: app?.localizedName,
            bundleIdentifier: app?.bundleIdentifier,
            processIdentifier: app?.processIdentifier,
            focusedRole: nil,
            selectedText: "",
            secureInput: IsSecureEventInputEnabled()
        )
    }

    public func capturePrivacyIdentitySample() -> FocusPrivacyIdentitySample {
        FocusPrivacyIdentitySample(
            focus: capturePrivacyIdentity(),
            applicationActivationRevision: applicationActivationRevision
        )
    }

    @objc
    private func applicationDidActivate(_ notification: Notification) {
        applicationActivationRevision &+= 1
    }

    private func copyStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
