import AppKit
import Foundation
import XCTest

@testable import RillCore
@testable import RillPlatform

@MainActor
final class CursorTextPreviewCoordinatorTests: XCTestCase {
  func testCursorPreviewReplacesSelectionUpdatesTailAndCommitsFinalText() async {
    let target = MockCursorTarget(content: "Say old now", selection: NSRange(location: 4, length: 3))
    let coordinator = makeCoordinator(target: target)
    let runID = UUID()

    let first = await coordinator.project(snapshot(runID: runID, text: "hello"))
    XCTAssertEqual(first.livePreviewPlacement, .cursor)
    XCTAssertEqual(target.snapshot().content, "Say hello now")

    _ = await coordinator.project(snapshot(runID: runID, text: "hello world"))
    XCTAssertEqual(target.snapshot().content, "Say hello world now")

    let commitResult = await coordinator.commit(runID: runID, finalText: "Hello, world!")
    XCTAssertEqual(commitResult, .committed)
    XCTAssertEqual(target.snapshot().content, "Say Hello, world! now")
    XCTAssertEqual(target.snapshot().selection, NSRange(location: 17, length: 0))
  }

  func testFinishingNonDirectRunRestoresSelectedTextAndSelection() async {
    let target = MockCursorTarget(content: "replace me", selection: NSRange(location: 0, length: 7))
    let coordinator = makeCoordinator(target: target)
    let runID = UUID()

    _ = await coordinator.project(snapshot(runID: runID, text: "temporary"))
    XCTAssertEqual(target.snapshot().content, "temporary me")

    await coordinator.finish(runID: runID)

    XCTAssertEqual(target.snapshot().content, "replace me")
    XCTAssertEqual(target.snapshot().selection, NSRange(location: 0, length: 7))
  }

  func testMovingCursorRollsBackAndDowngradesOnlyThatRun() async {
    let target = MockCursorTarget(content: "draft", selection: NSRange(location: 5, length: 0))
    let coordinator = makeCoordinator(target: target)
    let runID = UUID()

    _ = await coordinator.project(snapshot(runID: runID, text: " one"))
    target.setSelection(NSRange(location: 0, length: 0))
    let projected = await coordinator.project(snapshot(runID: runID, text: " one two"))

    XCTAssertEqual(projected.livePreviewPlacement, .overlay)
    XCTAssertEqual(target.snapshot().content, "draft")
    XCTAssertEqual(target.snapshot().selection, NSRange(location: 5, length: 0))
    let commitResult = await coordinator.commit(runID: runID, finalText: "one two")
    XCTAssertEqual(commitResult, .useStandardInjection)
  }

  func testExternalModificationStopsWritesAndBlocksFinalOverwrite() async {
    let target = MockCursorTarget(content: "", selection: NSRange(location: 0, length: 0))
    let coordinator = makeCoordinator(target: target)
    let runID = UUID()

    _ = await coordinator.project(snapshot(runID: runID, text: "preview"))
    target.replaceExternally(content: "user edit", selection: NSRange(location: 9, length: 0))
    let projected = await coordinator.project(snapshot(runID: runID, text: "preview more"))

    XCTAssertEqual(projected.livePreviewPlacement, .overlay)
    XCTAssertEqual(target.snapshot().content, "user edit")
    let commitResult = await coordinator.commit(runID: runID, finalText: "final")
    XCTAssertEqual(commitResult, .blocked(reason: "target-content-changed"))
    XCTAssertEqual(target.snapshot().content, "user edit")
  }

  func testMissingPermissionAndUnsupportedTargetFallBackWithoutWriting() async {
    let target = MockCursorTarget(content: "kept", selection: NSRange(location: 4, length: 0))
    let permissionDenied = CursorTextPreviewCoordinator(
      injectionEngine: TextInjectionEngine(
        pasteboard: SystemClipboardPort(pasteboard: NSPasteboard.withUniqueName()),
        accessibilityChecker: { true }),
      accessibilityChecker: { false },
      secureInputChecker: { false },
      targetProvider: { target },
      minimumWriteInterval: 0
    )
    let deniedRunID = UUID()
    let denied = await permissionDenied.project(snapshot(runID: deniedRunID, text: "ignored"))
    XCTAssertEqual(denied.livePreviewPlacement, .overlay)

    target.setSupported(false)
    let unsupported = makeCoordinator(target: target)
    let unsupportedSnapshot = await unsupported.project(
      snapshot(runID: UUID(), text: "ignored")
    )
    XCTAssertEqual(unsupportedSnapshot.livePreviewPlacement, .overlay)
    XCTAssertEqual(target.snapshot().content, "kept")
  }

  func testOverlappingAndClosedRunsCannotClaimExistingCursorRange() async {
    let target = MockCursorTarget(content: "", selection: NSRange(location: 0, length: 0))
    let coordinator = makeCoordinator(target: target)
    let firstRunID = UUID()
    let secondRunID = UUID()

    _ = await coordinator.project(snapshot(runID: firstRunID, text: "first"))
    let overlapping = await coordinator.project(snapshot(runID: secondRunID, text: "second"))
    XCTAssertEqual(overlapping.livePreviewPlacement, .overlay)
    XCTAssertEqual(target.snapshot().content, "first")

    await coordinator.finish(runID: firstRunID)
    let stale = await coordinator.project(snapshot(runID: firstRunID, text: "stale"))
    XCTAssertEqual(stale.livePreviewPlacement, .overlay)
    XCTAssertEqual(target.snapshot().content, "")
  }

  func testCommonPrefixUsesUTF16OffsetsAtCharacterBoundaries() {
    XCTAssertEqual(
      CursorTextPreviewCoordinator.commonPrefixUTF16Length("你好🙂a", "你好🙂b"),
      "你好🙂".utf16.count
    )
  }

  private func makeCoordinator(target: MockCursorTarget) -> CursorTextPreviewCoordinator {
    CursorTextPreviewCoordinator(
      injectionEngine: TextInjectionEngine(
        pasteboard: SystemClipboardPort(pasteboard: NSPasteboard.withUniqueName()),
        accessibilityChecker: { true }),
      accessibilityChecker: { true },
      secureInputChecker: { false },
      targetProvider: { target },
      minimumWriteInterval: 0
    )
  }

  private func snapshot(runID: UUID, text: String) -> LiveSubtitleSnapshot {
    LiveSubtitleSnapshot(
      runID: runID,
      phase: .transcribing,
      hypothesisText: text,
      livePreviewPlacement: .cursor
    )
  }
}

private final class MockCursorTarget: CursorTextPreviewTarget, @unchecked Sendable {
  struct State {
    var content: String
    var selection: NSRange
    var focused = true
    var supported = true
  }

  private let lock = NSLock()
  private var state: State

  init(content: String, selection: NSRange) {
    state = State(content: content, selection: selection)
  }

  func isFocused() -> Bool { lock.withLock { state.focused } }
  func supportsSelectedTextReplacement() -> Bool { lock.withLock { state.supported } }
  func selectedRange() -> NSRange? { lock.withLock { state.selection } }

  func selectedText(in range: NSRange) -> String? {
    lock.withLock {
      let units = Array(state.content.utf16)
      guard range.location >= 0,
        range.length >= 0,
        range.location + range.length <= units.count
      else { return nil }
      return String(decoding: units[range.location..<(range.location + range.length)], as: UTF16.self)
    }
  }

  func replaceText(in range: NSRange, with text: String, selection: NSRange) -> Bool {
    lock.withLock {
      var units = Array(state.content.utf16)
      guard range.location >= 0,
        range.length >= 0,
        range.location + range.length <= units.count
      else { return false }
      units.replaceSubrange(
        range.location..<(range.location + range.length),
        with: text.utf16
      )
      state.content = String(decoding: units, as: UTF16.self)
      state.selection = selection
      return true
    }
  }

  func snapshot() -> State { lock.withLock { state } }
  func setSelection(_ selection: NSRange) { lock.withLock { state.selection = selection } }
  func setSupported(_ supported: Bool) { lock.withLock { state.supported = supported } }
  func replaceExternally(content: String, selection: NSRange) {
    lock.withLock {
      state.content = content
      state.selection = selection
    }
  }
}
