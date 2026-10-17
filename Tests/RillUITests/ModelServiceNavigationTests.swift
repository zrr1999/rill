import AppKit
import RillCore
import RillTestSupport
import SwiftUI
import XCTest
@testable import RillUI

@MainActor
final class ModelServiceNavigationTests: NativeAccessibilityTestCase {
  func testDesktopServiceDeepLinksExposeOnlyTheSelectedPage() async throws {
    _ = NSApplication.shared
    if !NSApp.isRunning {
      NSApp.finishLaunching()
    }
    guard try await requireInteractiveDesktop() else { return }
    let fixture = JevPanelFixture()
    let workspace = RecordWorkspaceModel(store: fixture.store, cloudRanking: fixture.service)
    let model = makeHarness(recordWorkspace: workspace).model
    await model.waitForInitialVoiceConfiguration()
    model.voiceSetupPresentation = .dismissed
    let services: [(section: SettingsSection, pane: SettingsPane, control: String)] = [
      (.speech, .asr, "settings.section.speech"),
      (.decision, .decision, "settings.decision.model"),
      (.llm, .llm, "settings.models.provider"),
      (.tts, .tts, "settings.tts.model"),
    ]
    model.showSettings(.speech)
    let window = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
      styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    window.title = "Model services " + UUID().uuidString
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: MainShellView(model: model))
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    await settle(window)
    XCTAssertTrue(window.isKeyWindow)

    for language in AppLanguage.allCases {
      model.applyLanguage(language)
      for selected in services {
        model.showSettings(selected.section)
        await settle(window)
        XCTAssertEqual(model.selectedSettingsPane, selected.pane)
        for service in services {
          XCTAssertNotNil(element("settings.pane.\(service.pane.rawValue)", in: window))
          if service.pane == selected.pane {
            XCTAssertNotNil(element(service.control, in: window))
          } else {
            XCTAssertNil(element(service.control, in: window), "Hidden service controls must not enter the AX tree")
          }
        }
        XCTAssertNil(element("settings.wake-word.enabled", in: window))
      }
    }
    await model.stopSettingsReadTasksForApplicationShutdown()
    await workspace.shutdown()
  }
}
