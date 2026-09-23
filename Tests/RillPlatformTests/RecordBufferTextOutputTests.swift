import Foundation
import Testing

@testable import RillCore
@testable import RillPlatform

@MainActor struct RecordBufferTextOutputTests {
  @Test func unicodeChunksPreserveScalarsAndLineBreaks() {
    let text = String(repeating: "中文🙂👨‍👩‍👧‍👦\né", count: 100)
    let chunks = RecordBufferTextOutput.utf16Chunks(text)
    #expect(chunks.allSatisfy { $0.count <= 20 })
    #expect(chunks.map { String(decoding: $0, as: UTF16.self) }.joined() == text)
  }

  @Test func verifiedSelectionReplacementDoesNotPostKeys() async {
    let element = BufferTextTarget()
    element.update { $0.supportsReplacement = true }
    let target = RecordBufferTextOutput.Target(
      element: element, isCurrent: { element.isFocused() },
      post: { _ in
        Issue.record("AX replacement must not fall through to key events")
        return false
      })
    let transport = RecordBufferTextOutput(
      capture: { target }, modifiersHeld: { false }, isSecure: { false })
    #expect(await transport.insert("中文\n🙂", into: target) == .verified)
    #expect(element.value == "中文\n🙂")
  }

  @Test func ambiguousAXWriteNeverFallsBack() async {
    let element = BufferTextTarget()
    element.update {
      $0.supportsReplacement = true
      $0.rejectReplacement = true
    }
    let target = RecordBufferTextOutput.Target(
      element: element, isCurrent: { true },
      post: { _ in
        Issue.record("An ambiguous write must not be repeated")
        return false
      })
    let transport = RecordBufferTextOutput(
      capture: { target }, modifiersHeld: { false }, isSecure: { false })
    #expect(await transport.insert("A", into: target) == .unconfirmed)
  }

  @Test func ignoredEventsRemainUnconfirmedAndFocusDriftStopsChunks() async {
    let element = BufferTextTarget()
    var calls = 0
    let target = RecordBufferTextOutput.Target(
      element: element, isCurrent: { element.isFocused() },
      post: { _ in
        calls += 1
        element.update { $0.focused = false }
        return true
      })
    let transport = RecordBufferTextOutput(
      capture: { target }, modifiersHeld: { false }, isSecure: { false })
    #expect(
      await transport.insert(String(repeating: "中文🙂", count: 100), into: target) == .unconfirmed)
    #expect(calls == 1)
  }

  @Test func secureFieldOrCancelledOperationNeverSends() async {
    let element = BufferTextTarget()
    let target = RecordBufferTextOutput.Target(
      element: element, isCurrent: { true },
      post: { _ in
        Issue.record("Secure input must reject all events")
        return false
      })
    let transport = RecordBufferTextOutput(
      capture: { target }, modifiersHeld: { false }, isSecure: { true })
    #expect(transport.captureTarget() == nil)
    #expect(await transport.insert("secret", into: target) == .rejected)
  }
}

private final class BufferTextTarget: CursorTextPreviewTarget, @unchecked Sendable {
  struct State: Sendable {
    var focused = true
    var supportsReplacement = false
    var rejectReplacement = false
    var text = "selected"
    var selection = NSRange(location: 0, length: 8)
  }
  let state = LockedState()
  var value: String { state.withLock { $0.text } }
  func update(_ update: (inout State) -> Void) { state.withLock(update) }
  func isFocused() -> Bool { state.withLock { $0.focused } }
  func supportsSelectedTextReplacement() -> Bool { state.withLock { $0.supportsReplacement } }
  func selectedRange() -> NSRange? { state.withLock { $0.selection } }
  func selectedText(in range: NSRange) -> String? {
    state.withLock { state in
      guard range.location + range.length <= state.text.utf16.count else { return nil }
      return (state.text as NSString).substring(with: range)
    }
  }
  func replaceText(in range: NSRange, with text: String, selection: NSRange) -> Bool {
    state.withLock {
      $0.text = text
      guard !$0.rejectReplacement else { return false }
      $0.selection = selection
      return true
    }
  }
}

private final class LockedState {
  private let lock = NSLock()
  private var value = BufferTextTarget.State()
  func withLock<T>(_ body: (inout BufferTextTarget.State) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&value)
  }
}
