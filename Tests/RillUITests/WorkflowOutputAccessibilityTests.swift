import AppKit
import ApplicationServices
import RillCore
import RillPlatform
import RillTestSupport
import SwiftUI
import XCTest
@testable import RillUI

@MainActor
final class WorkflowOutputAccessibilityTests: NativeAccessibilityTestCase {
  func testDesktopOutputSwitchesExposeIdentityValueAndAutomaticState() async throws {
    _ = NSApplication.shared
    if !NSApp.isRunning {
      NSApp.finishLaunching()
    }
    guard try await requireInteractiveDesktop() else { return }
    let workflows = try BuiltinWorkflowCatalog().manifest().workflows
    let workflow = try XCTUnwrap(workflows.first { $0.titleKey == .speechRecognition })
    for language in AppLanguage.allCases {
      let model = makeHarness(workflows: workflows).model
      await model.waitForInitialVoiceConfiguration()
      model.applyLanguage(language)
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
      window.title = "Workflow outputs " + UUID().uuidString
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(
        rootView: VStack(alignment: .leading) {
          WorkflowOutputChoices(model: model, workflow: workflow)
        }.padding(20))
      window.makeKeyAndOrderFront(nil)
      defer { window.close() }
      await settle(window)
      let automatic = try XCTUnwrap(element("workflow.output.save", in: window))
      let optional = try XCTUnwrap(element("workflow.output.deliver", in: window))
      XCTAssertEqual(string(automatic, kAXRoleAttribute), kAXCheckBoxRole)
      XCTAssertEqual(boolean(automatic, kAXEnabledAttribute), false)
      XCTAssertEqual(boolean(automatic, kAXValueAttribute), true)
      XCTAssertEqual(boolean(optional, kAXEnabledAttribute), true)
      XCTAssertTrue(accessibilityText(window).contains(L10n.actionName(RecordActionID.store, language: language)))
      XCTAssertTrue(press(optional))
      await model.flushPendingPersistenceWrites()
      await settle(window)
      let updated = try XCTUnwrap(element("workflow.output.deliver", in: window))
      XCTAssertEqual(boolean(updated, kAXValueAttribute), false)
      XCTAssertEqual(model.executionWorkflows(for: .hotkey).first?.plan.output.actions.map(\.documentID), ["save", "enqueue"])
      await model.stopSettingsReadTasksForApplicationShutdown()
      await model.flushPendingPersistenceWrites()
    }
  }

  private func boolean(_ element: AXUIElement, _ attribute: String) -> Bool? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return (value as? NSNumber)?.boolValue
  }
}
