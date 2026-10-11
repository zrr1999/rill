import AppKit
import ApplicationServices
import RillTestSupport
import SwiftUI
import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
final class WorkflowDocumentPresentationTests: XCTestCase {
  func testDesktopCompactListExposesCompleteDiagnosticsAndDistinctLocationActions() async throws {
    guard try await requireInteractiveDesktop() else { return }
    for language in AppLanguage.allCases {
      let fixture = await WorkflowDocumentPresentationFixture.make()
      fixture.harness.model.setInterfaceLanguage(language)
      let window = makeWindow(WorkflowDocumentLibraryView(model: fixture.harness.model))
      addTeardownBlock { @MainActor in
        window.close()
        await fixture.shutdown()
      }
      await wait(window) { window.isKeyWindow }
      XCTAssertTrue(window.isKeyWindow)
      let text = accessibilityText(window)
      XCTAssertTrue(text.contains(WorkflowDocumentPresentationFixture.errorTail), "The real AX tree must include the end of the long error")
      XCTAssertTrue(text.contains(L10n.workflowDocument(.newWorkflowReviewHint, language: language)))
      XCTAssertEqual(buttons(L10n.workflowDocument(.labelOpenFile, language: language), in: window).count, 1)
      XCTAssertEqual(buttons(L10n.workflowDocument(.labelShowConfigurationLocation, language: language), in: window).count, 1)
      window.close()
    }
  }

  func testDesktopVisibleExplainActionOpensAndCancelsPreviewWithoutExecutingWorkflow() async throws {
    guard try await requireInteractiveDesktop() else { return }
    for language in AppLanguage.allCases {
      let fixture = await WorkflowDocumentPresentationFixture.make()
      let model = fixture.harness.model
      model.setInterfaceLanguage(language)
      model.showWorkflow(fixture.workflow.id)
      let window = makeWindow(WorkflowDocumentLibraryView(model: model), size: NSSize(width: 500, height: 600))
      addTeardownBlock { @MainActor in
        window.close()
        await fixture.shutdown()
      }
      await wait(window) { window.isKeyWindow }
      XCTAssertTrue(window.isKeyWindow)
      XCTAssertTrue(accessibilityText(window).contains(model.localizedWorkflowName(for: fixture.workflow)))
      let explainButtons = buttons(L10n.workflowExplanationCopy(.button, language: language), in: window)
      XCTAssertEqual(explainButtons.count, 1, "Only the selected ViewThatFits layout should expose its visible Explain button")
      let explain = try XCTUnwrap(explainButtons.first)
      XCTAssertTrue(press(explain))
      await wait(window) { window.attachedSheet != nil }
      await model.workflowLibrary.waitForWorkflowExplanationTasks()
      await settle(window)
      let sheet = try XCTUnwrap(window.attachedSheet)
      XCTAssertTrue(accessibilityText(sheet).contains(L10n.workflowExplanationCopy(.sheetTitle, language: language)))
      XCTAssertTrue(accessibilityText(sheet).contains(L10n.workflowExplanationCopy(.previewNotice, language: language)))
      guard case .loaded(let receipt) = model.workflowLibrary.workflowExplanationState else {
        XCTFail("Pressing Explain must load the actual static preview")
        throw CancellationError()
      }
      XCTAssertEqual(receipt.workflowID, fixture.workflow.id)
      let executionsBeforeClose = await fixture.harness.actionLog.snapshot()
      XCTAssertEqual(executionsBeforeClose, 0)
      XCTAssertFalse(model.voice.isRunning)
      let close = try XCTUnwrap(buttons(L10n.workflowExplanationCopy(.close, language: language), in: sheet).first)
      XCTAssertTrue(press(close))
      await wait(window) { window.attachedSheet == nil }
      let executionsAfterClose = await fixture.harness.actionLog.snapshot()
      XCTAssertEqual(executionsAfterClose, 0)
      XCTAssertFalse(model.voice.isRunning)
      XCTAssertEqual(model.workflowLibrary.workflowExplanationState, .idle)
      window.close()
    }
  }

  func testDesktopNewWorkflowMenuIsVisibleInTheMainWindowToolbar() async throws {
    guard try await requireInteractiveDesktop() else { return }
    for language in AppLanguage.allCases {
      let fixture = await WorkflowDocumentPresentationFixture.make()
      let model = fixture.harness.model
      model.setInterfaceLanguage(language)
      model.selectSidebarSection(.workflows)
      let window = makeWindow(MainShellView(model: model), size: NSSize(width: 960, height: 720))
      addTeardownBlock { @MainActor in
        window.close()
        await fixture.shutdown()
      }
      await wait(window) { window.isKeyWindow }
      XCTAssertTrue(window.isKeyWindow)
      XCTAssertTrue(accessibilityText(window).contains(model.localizedWorkflowName(for: fixture.workflow)))
      let menus = elements(in: window).filter { string($0, kAXIdentifierAttribute) == "workflow.document.new" }
      XCTAssertEqual(menus.count, 1)
      let menu = try XCTUnwrap(menus.first)
      let title = L10n.workflowDocument(.labelNewWorkflow, language: language)
      XCTAssertTrue([string(menu, kAXTitleAttribute), string(menu, kAXDescriptionAttribute)].contains(title))
      window.close()
    }
  }

  private func makeWindow<Content: View>(_ content: Content, size: NSSize = NSSize(width: 500, height: 700)) -> NSWindow {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    if !NSApp.isRunning { NSApp.finishLaunching() }
    let window = NSPanel(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let title = "Workflow presentation \(UUID().uuidString)"
    window.title = title
    window.setAccessibilityTitle(title)
    window.setAccessibilityIdentifier(title)
    window.contentView = NSHostingView(rootView: content)
    window.makeKeyAndOrderFront(nil)
    return window
  }

  private func settle(_ window: NSWindow) async {
    for _ in 0..<12 { await waitForMainRunLoopDefaultMode() }
    window.layoutIfNeeded()
    window.contentView?.layoutSubtreeIfNeeded()
  }

  private func wait(_ window: NSWindow, until predicate: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !predicate() && ContinuousClock.now < deadline { await settle(window) }
    XCTAssertTrue(predicate())
    await settle(window)
  }

  // Use the external AX tree, including SwiftUI's bridge and attached sheets.
  private func elements(in window: NSWindow) -> [AXUIElement] {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute as CFString, &value)
    XCTAssertEqual(status, .success)
    let parent = window.sheetParent ?? window
    let identifier = parent.accessibilityIdentifier()
    let title = parent.accessibilityTitle() ?? parent.title
    let roots = (value as? [AXUIElement] ?? []).filter {
      (!identifier.isEmpty && string($0, kAXIdentifierAttribute) == identifier) || string($0, kAXTitleAttribute) == title
    }
    XCTAssertEqual(roots.count, 1, "Exactly the fixture window must be present in the external AX tree")
    guard let root = roots.first else { return [] }
    XCTAssertEqual(string(root, kAXRoleAttribute), kAXWindowRole, "An AXApplication alias cannot stand in for a window")
    var pending = [root]
    var result: [AXUIElement] = []
    while let element = pending.popLast() {
      guard !result.contains(where: { CFEqual($0, element) }) else { continue }
      result.append(element)
      var children: CFTypeRef?
      if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success {
        pending.append(contentsOf: (children as? [AXUIElement] ?? []).reversed())
      }
    }
    XCTAssertGreaterThan(result.count, 1, "The real window must export its content")
    return result
  }

  private func buttons(_ label: String, in window: NSWindow) -> [AXUIElement] {
    elements(in: window).filter {
      string($0, kAXRoleAttribute) == kAXButtonRole
        && (string($0, kAXDescriptionAttribute) == label || string($0, kAXTitleAttribute) == label)
    }
  }

  private func accessibilityText(_ window: NSWindow) -> String {
    elements(in: window).flatMap { element in
      [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute, kAXHelpAttribute].compactMap { string(element, $0) }
    }.joined(separator: "\n")
  }

  private func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
  }

  private func press(_ element: AXUIElement) -> Bool {
    AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
  }
}
