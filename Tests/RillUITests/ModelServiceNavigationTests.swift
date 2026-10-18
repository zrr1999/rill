import AppKit
import RillCore
import RillTestSupport
import SwiftUI
import XCTest
@testable import RillUI

@MainActor
final class ModelServiceNavigationTests: NativeAccessibilityTestCase {
  func testDesktopServiceDeepLinksShareOnePaneAndHideWithIt() async throws {
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
    let sections: [SettingsSection] = [.speech, .decision, .llm, .tts]
    let controls = ["settings.decision.model", "settings.models.provider", "settings.tts.model"]
    model.selectedSettingsPane = .models
    model.presentSettings()
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

    for section in sections {
      XCTAssertNotNil(element("settings.section.\(section.rawValue)", in: window))
    }
    for control in controls {
      XCTAssertNil(element(control, in: window), "The initial overview shows all four collapsed modules")
    }
    for language in AppLanguage.allCases {
      model.applyLanguage(language)
      for section in sections {
        model.showSettings(section)
        await wait(window) { model.settingsNavigationRequest == nil }
        XCTAssertEqual(model.selectedSettingsPane, .models)
        XCTAssertNotNil(element("settings.pane.models", in: window))
        for other in sections {
          XCTAssertNotNil(element("settings.section.\(other.rawValue)", in: window))
        }
        for oldPane in ["asr", "decision", "llm", "tts"] {
          XCTAssertNil(element("settings.pane.\(oldPane)", in: window))
        }
        XCTAssertNil(element("settings.wake-word.enabled", in: window))
      }
      for control in controls {
        XCTAssertNotNil(element(control, in: window), "Deep links expand their module")
      }
      model.showSettings(.llm)
      await wait(window) { model.settingsNavigationRequest == nil }
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        let event = try XCTUnwrap(
          NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        window.sendEvent(event)
      }
      await wait(window) { element("settings.models.provider", in: window) == nil }
      model.showSettings(.llm)
      await wait(window) { model.settingsNavigationRequest == nil }
      XCTAssertNotNil(element("settings.models.provider", in: window))

      model.showSettings(.input)
      await wait(window) { model.settingsNavigationRequest == nil }
      XCTAssertNotNil(element("settings.section.input", in: window))
      for section in sections {
        XCTAssertNil(element("settings.section.\(section.rawValue)", in: window), "Hidden panes must not enter the AX tree")
      }
      for control in controls {
        XCTAssertNil(element(control, in: window))
      }
    }
    await model.stopSettingsReadTasksForApplicationShutdown()
    await workspace.shutdown()
  }
}
