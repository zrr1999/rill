import AppKit
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

  @Test func invalidAccessibilitySelectionNeverWritesOrPostsKeys() async {
    let element = BufferTextTarget()
    element.update {
      $0.supportsReplacement = true
      $0.selection = NSRange(location: NSNotFound, length: 0)
    }
    let target = RecordBufferTextOutput.Target(
      element: element, isCurrent: { true },
      post: { _ in
        Issue.record("Invalid AX selection must not fall through to key events")
        return false
      })
    let transport = RecordBufferTextOutput(
      capture: { target }, modifiersHeld: { false }, isSecure: { false })
    #expect(await transport.insert("A", into: target) == .rejected)
    #expect(element.value == "selected")
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

  @Test(arguments: ["finish", "commit", "conflict", "shutdown", "empty"])
  func cursorPreviewHoldsOutputUntilItsTerminalBoundary(terminal: String) async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let engine = makeEngine(pasteboard)
    let element = BufferTextTarget()
    element.update { $0.supportsReplacement = true }
    let target = RecordBufferTextOutput.Target(element: element, isCurrent: { true }, post: { _ in false })
    let output = RecordBufferTextOutput(capture: { target }, modifiersHeld: { false }, isSecure: { false })
    let cursor = CursorTextPreviewCoordinator(
      injectionEngine: engine, accessibilityChecker: { true }, secureInputChecker: { false },
      targetProvider: { element }, minimumWriteInterval: 0)
    let runID = UUID()
    _ = await cursor.project(cursorSnapshot(runID, text: terminal == "empty" ? "" : "preview"))
    #expect(await engine.insertBufferText("buffer", into: target, using: output) == .rejected)
    await #expect(throws: TextInjectionEngine.InjectionError.temporaryClipboardTransactionInProgress) {
      try await engine.inject("voice", method: .keyboard)
    }
    switch terminal {
    case "commit":
      #expect(await cursor.commit(runID: runID, finalText: "final") == .committed)
    case "conflict":
      element.update { $0.text = "external" }
      _ = await cursor.project(cursorSnapshot(runID, text: "new preview"))
      #expect(await cursor.commit(runID: runID, finalText: "final") == .blocked(reason: "target-content-changed"))
    case "shutdown":
      await cursor.shutdown()
      #expect(await cursor.project(cursorSnapshot(UUID(), text: "late")).livePreviewPlacement == .overlay)
    default:
      await cursor.finish(runID: runID)
    }
    let lease = try #require(await engine.reserveCursorPreview())
    await engine.releaseCursorPreview(lease)
    await engine.drainPendingClipboardRecoveryForApplicationShutdown()
  }

  @Test func concurrentUpdatesForOneRunReleaseTheSameOutputLease() async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let engine = makeEngine(pasteboard)
    let element = BufferTextTarget()
    element.update { $0.supportsReplacement = true }
    let cursor = CursorTextPreviewCoordinator(
      injectionEngine: engine, accessibilityChecker: { true }, secureInputChecker: { false },
      targetProvider: { element }, minimumWriteInterval: 0)
    for _ in 0..<32 {
      let runID = UUID()
      let snapshot = cursorSnapshot(runID, text: "preview")
      async let first = cursor.project(snapshot)
      async let second = cursor.project(snapshot)
      _ = await (first, second)
      _ = await cursor.commit(runID: runID, finalText: "final")
      let lease = try #require(await engine.reserveCursorPreview())
      await engine.releaseCursorPreview(lease)
    }
  }

  @Test func activeBufferRejectsVoiceAndDowngradesCursorPreviewWithoutWriting() async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let engine = makeEngine(pasteboard)
    let element = BufferTextTarget()
    element.update { $0.supportsReplacement = true }
    let target = RecordBufferTextOutput.Target(element: element, isCurrent: { true }, post: { _ in false })
    let modifiers = OutputModifierState()
    let started = AsyncStream<Void>.makeStream()
    let output = RecordBufferTextOutput(capture: { target }, modifiersHeld: {
      started.continuation.yield(())
      return modifiers.held
    }, isSecure: { false })
    let delivery = Task { await engine.insertBufferText("buffer", into: target, using: output) }
    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()
    let cursor = CursorTextPreviewCoordinator(
      injectionEngine: engine, accessibilityChecker: { true }, secureInputChecker: { false },
      targetProvider: { element })
    #expect(await cursor.project(cursorSnapshot(UUID(), text: "preview")).livePreviewPlacement == .overlay)
    #expect(element.value == "selected")
    await #expect(throws: TextInjectionEngine.InjectionError.temporaryClipboardTransactionInProgress) {
      try await engine.inject("voice", method: .keyboard)
    }
    modifiers.held = false
    #expect(await delivery.value == .verified)
    #expect(element.value == "buffer")
    try await engine.inject("voice", method: .keyboard)
  }

  @Test func activeKeyboardDeliveryRejectsBufferAndCancellationReleasesOutput() async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let gate = OutputKeyboardGate()
    let engine = TextInjectionEngine(
      pasteboard: SystemClipboardPort(pasteboard: pasteboard), accessibilityChecker: { true },
      keyboardChunkSender: { _ in await gate.enter(); return true })
    let element = BufferTextTarget()
    element.update { $0.supportsReplacement = true }
    let target = RecordBufferTextOutput.Target(element: element, isCurrent: { true }, post: { _ in false })
    let output = RecordBufferTextOutput(capture: { target }, modifiersHeld: { false }, isSecure: { false })
    let voice = Task { try await engine.inject(String(repeating: "voice", count: 10), method: .keyboard) }
    await gate.waitUntilEntered()
    #expect(await engine.insertBufferText("buffer", into: target, using: output) == .rejected)
    #expect(element.value == "selected")
    voice.cancel()
    await gate.release()
    _ = try? await voice.value
    #expect(await engine.insertBufferText("buffer", into: target, using: output) == .verified)
  }

  private func makeEngine(_ pasteboard: NSPasteboard) -> TextInjectionEngine {
    TextInjectionEngine(pasteboard: SystemClipboardPort(pasteboard: pasteboard),
      accessibilityChecker: { true }, keyboardChunkSender: { _ in true })
  }

  private func cursorSnapshot(_ runID: UUID, text: String) -> LiveSubtitleSnapshot {
    .init(runID: runID, phase: .transcribing, hypothesisText: text, livePreviewPlacement: .cursor)
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

private actor OutputKeyboardGate {
  private var entered = false
  private var observers: [CheckedContinuation<Void, Never>] = []
  private var continuation: CheckedContinuation<Void, Never>?
  func enter() async {
    entered = true
    for observer in observers { observer.resume() }
    observers.removeAll()
    await withCheckedContinuation { continuation = $0 }
  }
  func waitUntilEntered() async {
    if !entered { await withCheckedContinuation { observers.append($0) } }
  }
  func release() { continuation?.resume(); continuation = nil }
}

@MainActor private final class OutputModifierState { var held = true }
