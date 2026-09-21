import AppKit
import ApplicationServices
import Carbon
import ImageIO
import RillCore
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
public final class ScreenContextCapture: ScreenContextCapturing {
    public init() {}

    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    public func capture(focus: FocusSnapshot, excludingApplications: Set<String>) async throws -> CorrectionReferenceImage {
        guard Self.hasPermission, !focus.secureInput, !IsSecureEventInputEnabled(),
              let pid = focus.processIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let displayID = await Self.inputDisplay(processIdentifier: pid) else {
            throw ContextCorrectionError.invalidReference
        }
        let excludingApplications = Set(excludingApplications.map { SensitiveAppRule(bundleIdentifier: $0).normalizedBundleIdentifier })
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ContextCorrectionError.invalidReference
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excluded = content.applications.filter {
            $0.processID == ownPID || excludingApplications.contains(SensitiveAppRule(bundleIdentifier: $0.bundleIdentifier).normalizedBundleIdentifier)
        }
        guard !excluded.contains(where: { $0.processID == pid }) else { throw ContextCorrectionError.invalidReference }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = min(1, 2_560 / Double(max(display.width, display.height)))
        configuration.width = max(1, Int(Double(display.width) * scale))
        configuration.height = max(1, Int(Double(display.height) * scale))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        let displayBeforeCapture = await Self.inputDisplay(processIdentifier: pid)
        try Task.checkCancellation()
        guard !IsSecureEventInputEnabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              displayBeforeCapture == displayID else { throw ContextCorrectionError.invalidReference }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        let displayAfterCapture = await Self.inputDisplay(processIdentifier: pid)
        try Task.checkCancellation()
        guard Self.hasPermission, !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              displayAfterCapture == displayID else { throw ContextCorrectionError.invalidReference }
        return try await Self.encode(image)
    }

    @concurrent nonisolated static func inputDisplay(processIdentifier: Int32) async -> CGDirectDisplayID? {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.04)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.04)
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        let center = CGPoint(x: point.x + dimensions.width / 2, y: point.y + dimensions.height / 2)
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(center, 1, &display, &count) == .success, count == 1 else { return nil }
        return display
    }

    @concurrent nonisolated static func encode(_ image: CGImage) async throws -> CorrectionReferenceImage {
        for quality in [0.85, 0.7, 0.55, 0.4] {
            try Task.checkCancellation()
            let bytes = NSMutableData()
            guard let encoder = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw ContextCorrectionError.invalidReference
            }
            CGImageDestinationAddImage(encoder, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(encoder) else { throw ContextCorrectionError.invalidReference }
            if bytes.length <= 2 * 1_024 * 1_024 {
                return try CorrectionReferenceImage(jpeg: bytes as Data, width: image.width, height: image.height)
            }
        }
        throw ContextCorrectionError.invalidReference
    }
}
