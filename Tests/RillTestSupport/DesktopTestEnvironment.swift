import AppKit

private struct DesktopUnavailable: LocalizedError, CustomStringConvertible {
  var description: String {
    "Desktop test environment unavailable: a plain AppKit panel could not acquire keyboard focus. "
      + "Run just test-desktop in an unlocked interactive macOS session with no competing UI automation. "
      + "Desktop behavior was not verified; this is a failed prerequisite, not a skipped or passing test."
  }

  var errorDescription: String? { description }
}

/// Probe the desktop independently of the application under test, before it opens any windows.
@MainActor
public func requireInteractiveDesktop() async throws {
  _ = NSApplication.shared
  let probe = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
    styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
  defer { probe.orderOut(nil) }
  probe.makeKeyAndOrderFront(nil)
  let deadline = ContinuousClock.now.advanced(by: .seconds(1))
  while !probe.isKeyWindow, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  guard probe.isKeyWindow else { throw DesktopUnavailable() }
}
