import AppKit
import ApplicationServices
import XCTest
@testable import RillUI

@MainActor
class NativeAccessibilityTestCase: XCTestCase {
  final func settle(_ window: NSWindow) async {
    for _ in 0..<12 { await waitForMainRunLoopDefaultMode() }
    window.layoutIfNeeded()
    window.contentView?.layoutSubtreeIfNeeded()
  }

  @nonobjc
  final func wait(_ window: NSWindow, until predicate: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !predicate() && ContinuousClock.now < deadline { await settle(window) }
    XCTAssertTrue(predicate())
    await settle(window)
  }

  // Use the external AX tree, including SwiftUI's bridge and attached sheets.
  final func elements(in window: NSWindow) -> [AXUIElement] {
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

  final func buttons(_ label: String, in window: NSWindow) -> [AXUIElement] {
    elements(in: window).filter {
      string($0, kAXRoleAttribute) == kAXButtonRole
        && (string($0, kAXDescriptionAttribute) == label || string($0, kAXTitleAttribute) == label)
    }
  }

  final func accessibilityText(_ window: NSWindow) -> String {
    elements(in: window).flatMap { element in
      [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute, kAXHelpAttribute].compactMap { string(element, $0) }
    }.joined(separator: "\n")
  }

  final func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
  }

  final func press(_ element: AXUIElement) -> Bool {
    AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
  }

  final func element(_ identifier: String, in window: NSWindow) -> AXUIElement? {
    elements(in: window).first { string($0, kAXIdentifierAttribute) == identifier }
  }

  final func button(_ label: String, in window: NSWindow) -> AXUIElement? {
    buttons(label, in: window).first
  }
}
