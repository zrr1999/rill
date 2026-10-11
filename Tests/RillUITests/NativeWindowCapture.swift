import AppKit
import ScreenCaptureKit
import XCTest

@MainActor
func captureNativeWindow(_ window: NSWindow, to url: URL) async throws {
  guard CGPreflightScreenCaptureAccess() else {
    throw XCTSkip("Compositor evidence requires existing Screen Recording permission; no prompt was requested.")
  }
  let parent = window.sheetParent ?? window
  let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
  let ownWindow = try XCTUnwrap(
    content.windows.first {
      $0.windowID == CGWindowID(parent.windowNumber)
        && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
    })
  let configuration = SCStreamConfiguration()
  let scale = ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_SCALE"].flatMap(Double.init) ?? parent.backingScaleFactor
  configuration.width = Int(parent.frame.width * scale)
  configuration.height = Int(parent.frame.height * scale)
  configuration.showsCursor = false
  configuration.capturesAudio = false
  configuration.ignoreShadowsSingleWindow = true
  configuration.includeChildWindows = true
  let image = try await SCScreenshotManager.captureImage(
    contentFilter: SCContentFilter(desktopIndependentWindow: ownWindow), configuration: configuration)
  let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
  try png.write(to: url)
}
