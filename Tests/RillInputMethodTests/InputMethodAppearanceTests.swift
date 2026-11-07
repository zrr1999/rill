import AppKit
import RillInputMethodContracts
import RillInputMethodIPC
import Testing

@testable import RillInputMethodKit

struct InputMethodAppearanceTests {
  @Test @MainActor func oversizedCandidatesScrollAndKeepTheSelectedRowVisible() throws {
    let application = NSApplication.shared
    let existing = Set(application.windows.map(\.windowNumber))
    let candidates = CandidateWindow()
    defer { candidates.hide() }
    let screen = try #require(NSScreen.screens.first)
    let caret = NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 0, height: 22)
    var appearance = InputMethodAppearance.defaults
    appearance.fontName = "Zapfino"
    appearance.fontSize = 48
    _ = try #require(NSFont(name: "Zapfino", size: 48))
    let count = max(6, Int(screen.visibleFrame.height / appearance.fontSize) + 1)
    for index in [0, count - 1] {
      let snapshot = RimeSession.Snapshot(
        preedit: "hello", caretUTF16: 5,
        candidates: (0..<count).map { .init(text: "Candidate \($0 + 1)", comment: "候选词") }, selected: index)
      candidates.show(snapshot, at: caret, appearance: appearance)
      let panel = try #require(application.windows.first { !existing.contains($0.windowNumber) && $0.isVisible })
      #expect(screen.visibleFrame.contains(panel.frame))
      let scroll = try #require(panel.contentView?.subviews.first as? NSScrollView)
      let stack = try #require(scroll.documentView as? NSStackView)
      #expect(stack.frame.height > scroll.contentSize.height)
      let button = try #require(stack.arrangedSubviews[index] as? NSButton)
      for style in [NSScroller.Style.legacy, .overlay] {
        scroll.scrollerStyle = style
        scroll.tile()
        panel.contentView?.layoutSubtreeIfNeeded()
        #expect(scroll.documentVisibleRect.contains(button.frame))
      }
      #expect(button.isAccessibilitySelected() == true)
      var selected: Int?
      candidates.selected = { selected = $0 }
      button.performClick(nil)
      #expect(selected == index)
    }
  }

  @Test @MainActor func nativeCandidatesApplyFontsAndKeepAccessibleNumbersWhenHidden() throws {
    let application = NSApplication.shared
    let existing = Set(application.windows.map(\.windowNumber))
    let candidates = CandidateWindow()
    defer { candidates.hide() }
    let snapshot = RimeSession.Snapshot(
      preedit: "nihao", caretUTF16: 5,
      candidates: [.init(text: "你好", comment: ""), .init(text: "拟好", comment: "ni hao")], selected: 0)
    let screen = try #require(NSScreen.screens.first)
    let caret = NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 0, height: 22)
    var appearance = InputMethodAppearance.defaults
    appearance.showsNumbers = false
    appearance.fontName = "Helvetica-Bold"
    appearance.fontSize = 28
    candidates.show(snapshot, at: caret, appearance: appearance)
    let panel = try #require(application.windows.first { !existing.contains($0.windowNumber) && $0.isVisible })
    let stack = try #require(panel.contentView?.subviews.first as? NSStackView)
    let buttons = stack.arrangedSubviews.compactMap { $0 as? NSButton }
    #expect(buttons.map(\.title) == ["你好", "拟好  ni hao"])
    #expect(buttons.first?.font?.fontName == appearance.fontName)
    #expect(buttons.first?.font?.pointSize == 28)
    #expect(buttons.first?.accessibilityLabel() == "1  你好")
    #expect(buttons.first?.isAccessibilitySelected() == true)
    var selected: Int?
    candidates.selected = { selected = $0 }
    buttons.last?.performClick(nil)
    #expect(selected == 1)
    if let directory = ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_DIR"], let view = panel.contentView {
      let output = URL(fileURLWithPath: directory, isDirectory: true)
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      panel.layoutIfNeeded()
      view.layoutSubtreeIfNeeded()
      let representation = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: representation)
      try #require(representation.representation(using: .png, properties: [:]))
        .write(to: output.appendingPathComponent("candidate-panel-custom-font.png"))
    }
  }

  @Test func labelsCanBeHiddenOrFormattedWithoutChangingCandidateText() throws {
    var appearance = InputMethodAppearance.defaults
    #expect(appearance.candidateTitle(at: 0, text: "你好", comment: "ni hao") == "1  你好  ni hao")
    appearance.numberFormat = "({n})."
    #expect(try appearance.validated().candidateTitle(at: 5, text: "世界", comment: "") == "(6).  世界")
    appearance.showsNumbers = false
    #expect(appearance.candidateTitle(at: 5, text: "世界", comment: "") == "世界")
  }

  @Test(arguments: ["", "1.", "{n}{n}", "{n}\n", "{n}\u{2028}", String(repeating: "x", count: 33) + "{n}"])
  func invalidTemplatesAreRejected(_ format: String) {
    var appearance = InputMethodAppearance.defaults
    appearance.numberFormat = format
    #expect(throws: InputMethodAppearance.ValidationError.numberFormat) { try appearance.validated() }
  }

  @Test(arguments: [0.0, 9.0, 49.0, Double.infinity, Double.nan])
  func invalidFontSizesAreRejected(_ size: Double) {
    var appearance = InputMethodAppearance.defaults
    appearance.fontSize = size
    #expect(throws: InputMethodAppearance.ValidationError.fontSize) { try appearance.validated() }
  }

  @Test func savedAppearanceSurvivesNewReadersAndInvalidEdits() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("appearance.json")
    let store = InputMethodAppearanceStore(file: file)
    #expect(try store.load() == .defaults)
    var appearance = InputMethodAppearance.defaults
    appearance.numberFormat = "{n}."
    appearance.fontName = "Helvetica-Bold"
    appearance.fontSize = 28
    try store.save(appearance)
    #expect(try InputMethodAppearanceStore(file: file).load() == appearance)
    var invalid = appearance
    invalid.numberFormat = "no placeholder"
    #expect(throws: InputMethodAppearance.ValidationError.numberFormat) { try store.save(invalid) }
    #expect(try store.load() == appearance)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("InputMethod").path))
  }

  @Test func corruptOrFutureConfigurationIsReported() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("appearance.json")
    let store = InputMethodAppearanceStore(file: file)
    try Data("invalid".utf8).write(to: file)
    #expect(throws: (any Error).self) { try store.load() }
    var future = InputMethodAppearance.defaults
    future.version = 99
    try JSONEncoder().encode(future).write(to: file)
    #expect(throws: InputMethodAppearance.ValidationError.unsupportedVersion) { try store.load() }
  }
}
