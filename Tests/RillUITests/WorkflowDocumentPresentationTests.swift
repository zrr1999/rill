import AppKit
import ApplicationServices
import RillTestSupport
import SwiftUI
import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
final class WorkflowDocumentPresentationTests: NativeAccessibilityTestCase {
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
      XCTAssertTrue(text.contains(L10n.catalogString("workflowFile.error.invalidDocument", language: language)))
      XCTAssertTrue(text.contains(L10n.catalogString("workflowFile.error.configurationPathIsNotDirectory", language: language)))
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

}
