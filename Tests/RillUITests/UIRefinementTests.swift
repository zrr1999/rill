import AppKit
import ApplicationServices
import RillTestSupport
import SwiftUI
import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
final class UIRefinementTests: NativeAccessibilityTestCase {
  func testDesktopEmptySearchKeepsRecoveryVisibleWithBothSourcesUnavailable() async throws {
    _ = NSApplication.shared
    if !NSApp.isRunning { NSApp.finishLaunching() }
    guard try await requireInteractiveDesktop() else { return }
    for language in AppLanguage.allCases {
      var query = "unavailable"
      let window = NSPanel(
        contentRect: NSRect(x: 100, y: 100, width: 620, height: 420),
        styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
      window.title = "Search recovery " + UUID().uuidString
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(
        rootView: GlobalSearchResultsView(
          query: Binding(get: { query }, set: { query = $0 }), results: [], selectedResultID: nil,
          historySearchState: .failed, recordSearchState: .failed,
          historyFailureActionTitle: GlobalSearchText.historyRetry(language: language), language: language,
          focusRequest: 0, onMoveSelection: { _ in }, onSubmit: {}, onCancel: {},
          onHistorySearchFailureAction: {}, onHighlight: { _ in }, onSelect: { _ in }))
      window.makeKeyAndOrderFront(nil)
      defer { window.close() }
      await settle(window)
      XCTAssertTrue(window.isKeyWindow)
      let clear = try XCTUnwrap(button(L10n.presentation(.clearSearch, language: language), in: window))
      let root = try XCTUnwrap(elements(in: window).first)
      let clearFrame = try accessibilityFrame(clear)
      XCTAssertGreaterThan(clearFrame.width, 0)
      XCTAssertGreaterThanOrEqual(clearFrame.height, 20)
      XCTAssertTrue(try accessibilityFrame(root).contains(clearFrame), "Recovery must be visible without scrolling the empty results.")
      XCTAssertTrue(press(clear))
      await settle(window)
      XCTAssertEqual(query, "")
    }
  }

  private func accessibilityFrame(_ element: AXUIElement) throws -> CGRect {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    XCTAssertEqual(AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue), .success)
    XCTAssertEqual(AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue), .success)
    let position = try XCTUnwrap(positionValue) as! AXValue
    let size = try XCTUnwrap(sizeValue) as! AXValue
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    XCTAssertTrue(AXValueGetValue(position, .cgPoint, &point))
    XCTAssertTrue(AXValueGetValue(size, .cgSize, &dimensions))
    return CGRect(origin: point, size: dimensions)
  }

  func testDeliveryTitleUsesOnlySuppliedTargetAndHandlesUnavailableName() {
    XCTAssertEqual(RecordDeliveryTitle.make(applicationName: " Notes ", language: .english), "Insert into Notes")
    XCTAssertEqual(RecordDeliveryTitle.make(applicationName: "备忘录", language: .simplifiedChinese), "插入到 备忘录")
    for name: String? in [nil, "", "  "] {
      XCTAssertEqual(
        RecordDeliveryTitle.make(applicationName: name, language: .english),
        L10n.recordText(.insertInPreviousApp, language: .english))
    }
  }

  func testPresentationCopyIsLocalizedAndNeverFallsBackToKey() {
    for key in L10n.PresentationKey.allCases {
      for language in AppLanguage.allCases {
        let value = L10n.presentation(key, language: language)
        XCTAssertFalse(value.isEmpty)
        XCTAssertNotEqual(value, key.rawValue)
      }
    }
  }
}
