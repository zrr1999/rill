import AppKit
import SwiftUI
import XCTest

@testable import RillUI

@MainActor
final class RecordSearchFieldTests: XCTestCase {
  func testEnterWithMarkedTextCommitsOnlyTheInputMethod() {
    var submissions = 0
    var movement = 0
    let field = RecordSearchField(
      text: .constant(""), placeholder: "Search", onMove: { movement += $0 },
      onSubmit: { submissions += 1 }, onDigit: { _ in }, onCancel: {})
    let coordinator = field.makeCoordinator()
    let editor = NSTextView()
    editor.setMarkedText(
      "中", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(editor.hasMarkedText())
    XCTAssertFalse(
      coordinator.control(
        NSSearchField(), textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    XCTAssertFalse(
      coordinator.control(
        NSSearchField(), textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
    XCTAssertEqual(submissions, 0)
    XCTAssertEqual(movement, 0)
    editor.unmarkText()
    XCTAssertTrue(
      coordinator.control(
        NSSearchField(), textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    XCTAssertEqual(submissions, 1)
  }

  func testOnlyCommandDigitsInvokeDirectPaste() throws {
    let field = RecordSearchField.SearchField()
    var selected: [Int] = []
    field.onDigit = { selected.append($0) }
    for modifiers: NSEvent.ModifierFlags in [[], .command, [.command, .shift], .option] {
      let event = try XCTUnwrap(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
          windowNumber: 0, context: nil, characters: "1", charactersIgnoringModifiers: "1",
          isARepeat: false, keyCode: 18))
      if modifiers == .command {
        XCTAssertTrue(field.performKeyEquivalent(with: event))
      } else {
        XCTAssertFalse(field.performKeyEquivalent(with: event))
      }
    }
    XCTAssertEqual(selected, [0])
  }
}
