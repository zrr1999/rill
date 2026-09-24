import AppKit
import Testing

@testable import RillInputMethodKit

@MainActor
struct InputMethodCompositionTests {
  @Test func unhandledEventsPreserveSelectedDocumentText() {
    let text = NSTextView()
    text.string = "keep this text"
    text.setSelectedRange(NSRange(location: 0, length: 4))
    var composition = InputMethodComposition()
    apply(&composition, to: text, commit: nil, preedit: "")
    #expect(text.string == "keep this text")
    #expect(text.selectedRange() == NSRange(location: 0, length: 4))
  }

  @Test func compositionReplacesItsOwnMarkedTextAndCommitsOnce() {
    let text = NSTextView()
    text.string = "before after"
    text.setSelectedRange(NSRange(location: 7, length: 0))
    var composition = InputMethodComposition()
    apply(&composition, to: text, commit: nil, preedit: "ni")
    apply(&composition, to: text, commit: nil, preedit: "nihao")
    apply(&composition, to: text, commit: "你好", preedit: "")
    apply(&composition, to: text, commit: nil, preedit: "")
    #expect(text.string == "before 你好after")
    #expect(!text.hasMarkedText())
  }

  @Test func cancellationOnlyRemovesTheMarkedComposition() {
    let text = NSTextView()
    text.string = "retained"
    text.setSelectedRange(NSRange(location: 8, length: 0))
    var composition = InputMethodComposition()
    apply(&composition, to: text, commit: nil, preedit: "hello")
    apply(&composition, to: text, commit: nil, preedit: "")
    #expect(text.string == "retained")
  }

  private func apply(
    _ composition: inout InputMethodComposition, to client: NSTextView,
    commit: String?, preedit: String
  ) {
    composition.update(
      commit: commit, preedit: preedit, caret: preedit.utf16.count,
      insert: { client.insertText($0, replacementRange: NSRange(location: NSNotFound, length: 0)) },
      mark: {
        client.setMarkedText(
          $0, selectedRange: $1, replacementRange: NSRange(location: NSNotFound, length: 0))
      })
  }
}
