import AppKit
import ApplicationServices
import Foundation
import ImageIO
import RillCore
import Testing
@testable import RillPlatform

struct ScreenContextCaptureTests {
    @Test func jpegEncodingRespectsByteAndDimensionLimits() async throws {
        let context = try #require(CGContext(data: nil, width: 2_560, height: 1_440, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2_560, height: 1_440))
        let cgImage = try #require(context.makeImage())
        let image = try await ScreenContextCapture.encode(cgImage)
        #expect(image.jpeg.count <= 2 * 1_024 * 1_024)
        let source = try #require(CGImageSourceCreateWithData(image.jpeg as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 2_560)
        #expect(decoded.height == 1_440)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RILL_CONTEXT_MAC_PROBE"] == "1"))
    @MainActor func currentMacCaptureProbe() async throws {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var report: [String: Any] = ["screenPermission": ScreenContextCapture.hasPermission,
                                   "accessibilityPermission": AXIsProcessTrusted(), "activeDisplays": count,
                                   "physicalShortRecording": "requires interactive microphone and speech QA",
                                   "multiDisplayInputSwitch": "requires interactive QA"]
        if ScreenContextCapture.hasPermission, AXIsProcessTrusted(), let focused = NSWorkspace.shared.frontmostApplication {
            let focus = FocusSnapshot(applicationName: nil, bundleIdentifier: focused.bundleIdentifier,
                processIdentifier: focused.processIdentifier, focusedRole: nil, selectedText: "", secureInput: false)
            let start = ContinuousClock.now
            do {
                let captured = try await BoundedOperation().run(timeout: .milliseconds(250)) {
                    try await ScreenContextCapture().capture(focus: focus,
                        excludingApplications: Set(PrivacyPolicySettings().sensitiveAppRules.filter(\.enabled).map(\.bundleIdentifier)))
                }
                report["capture"] = "captured in memory and discarded"
                report["width"] = captured.width; report["height"] = captured.height; report["jpegBytes"] = captured.jpeg.count
            } catch is OperationDeadlineError { report["capture"] = "skipped at deadline" }
            catch { report["capture"] = "unavailable" }
            let elapsed = start.duration(to: .now).components
            report["elapsedMilliseconds"] = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        } else { report["capture"] = "skipped because permission is unavailable" }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = root.appendingPathComponent(".artifacts/contextual-memory-20260920/mac-probe.json")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    }
}
