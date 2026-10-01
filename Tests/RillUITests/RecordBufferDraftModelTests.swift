import AppKit
import Foundation
import RillCore
import RillRecords
import Testing
@testable import RillUI

@MainActor struct RecordBufferDraftModelTests {
  @Test func closingDuringNewItemReleasesTheEventualEditingSession() async throws {
    let store = RecordStore()
    let model = RecordBufferDraftModel(store: store)
    model.open()
    model.newItem()
    // Close before the admitted command gets its first MainActor turn.
    model.close()
    await model.waitForPendingWrites()
    let session = try #require(model.session)
    let draft = try await store.saveBufferDraft(
      session.entryID, draftID: session.saved.id,
      expectedRevision: 0, text: "retained")
    try await store.commitBufferDraft(session.entryID, draftID: draft.id, expectedRevision: draft.revision)
    #expect(try await store.beginBufferOutput().record.payload.textValue == "retained")
    await model.shutdown()
  }

  @Test func editsAndSelectionSurviveNewArrivalsAndClosing() async throws {
    let store = RecordStore()
    let model = RecordBufferDraftModel(store: store)
    model.open()
    model.newItem()
    await model.waitForPendingWrites()
    let session = try #require(model.session)
    model.edit("今天去上海\n明天回来", sessionID: session.id)
    session.selection = .init(location: 3, length: 2)
    let record = try await store.ingest(.init(payload: .text("新复制内容"), provenance: .init(source: .init(kind: .systemClipboard))), into: [])
    _ = try await store.enqueueRecord(record.id, in: RecordBuffer.clipboardID)
    await model.waitForPendingWrites()
    await model.refresh()
    #expect(model.session === session)
    #expect(session.selection == .init(location: 3, length: 2))
    #expect(model.items.count == 2)
    model.close()
    await model.waitForPendingWrites()
    model.open()
    await model.waitForPendingWrites()
    #expect(model.session?.text == "今天去上海\n明天回来")
    #expect(try await store.bufferDraft(for: session.entryID)?.text == session.text)
    await model.shutdown()
  }

  @Test func dictationReplacesCapturedSelectionOnlyWhileUnchangedAndFocused() async throws {
    let store = RecordStore()
    let model = RecordBufferDraftModel(store: store)
    model.open()
    model.newItem()
    await model.waitForPendingWrites()
    let session = try #require(model.session)
    session.isFocused = true
    model.edit("去北京开会", sessionID: session.id)
    session.selection = .init(location: 1, length: 2)
    await model.waitForPendingWrites()
    var input: BufferSpeechInput?
    model.dictationAction = { input = $0 }
    model.dictateHere()
    await model.waitForPendingWrites()
    let intent = try #require(input?.draftIntent)
    // Cursor movement alone must not redirect an admitted recording.
    session.selection = .init(location: 5)
    _ = try await store.ingestBufferDictation(
      .init(payload: .text("上海"), provenance: .init(source: .init(kind: .workflow), workflowRunID: UUID())),
      recognitionText: "上海", for: intent)
    await model.refresh()
    await model.waitForPendingWrites()
    #expect(session.text == "去上海开会")
    #expect(session.selection == .init(location: 3))
    #expect(model.items.count == 1)
    await model.shutdown()
  }

  @Test func markedTextAndManualEditsKeepLateSpeechAsSuggestion() async throws {
    let store = RecordStore()
    let model = RecordBufferDraftModel(store: store)
    model.open()
    model.newItem()
    await model.waitForPendingWrites()
    let session = try #require(model.session)
    session.isFocused = true
    let intent = BufferDraftInputIntent(
      entryID: session.entryID, draftID: session.saved.id,
      revision: session.saved.revision, selection: .init(location: 0), editingSessionID: session.id)
    session.hasMarkedText = true
    model.edit("beijing", sessionID: session.id)
    _ = try await store.ingestBufferDictation(
      .init(payload: .text("上海"), provenance: .init(source: .init(kind: .workflow), workflowRunID: UUID())),
      recognitionText: "上海", for: intent)
    await model.refresh()
    #expect(session.text == "beijing")
    #expect(try await store.bufferDraft(for: session.entryID)?.text == "")
    session.hasMarkedText = false
    model.edit("北京", sessionID: session.id)
    await model.waitForPendingWrites()
    await model.refresh()
    #expect(session.text == "北京")
    #expect(session.saved.suggestions.count == 1)
    #expect(model.items.count == 1)
    await model.shutdown()
  }

  @Test func switchingItemsNeverRetargetsSpeechAndSendFreezesTheDerivedRecord() async throws {
    let store = RecordStore()
    let model = RecordBufferDraftModel(store: store)
    model.open()
    model.newItem()
    await model.waitForPendingWrites()
    let first = try #require(model.session)
    let intent = BufferDraftInputIntent(
      entryID: first.entryID, draftID: first.saved.id,
      revision: 0, selection: .init(location: 0), editingSessionID: first.id)
    model.newItem()
    await model.waitForPendingWrites()
    let second = try #require(model.session)
    model.edit("第二条的修改", sessionID: second.id)
    _ = try await store.ingestBufferDictation(
      .init(payload: .text("第一条的语音"), provenance: .init(source: .init(kind: .workflow), workflowRunID: UUID())),
      recognitionText: "第一条的语音", for: intent)
    await model.waitForPendingWrites()
    await model.refresh()
    #expect(model.session === second)
    #expect(second.text == "第二条的修改")
    #expect(try await store.bufferDraft(for: first.entryID)?.suggestions.first?.text == "第一条的语音")
    var sent: BufferEntryID?
    model.sendAction = { sent = $0 }
    model.send()
    await model.waitForPendingWrites()
    #expect(sent == second.entryID)
    let output = try await store.beginBufferOutput(manualEntryID: second.entryID)
    #expect(output.record.payload.textValue == "第二条的修改")
    #expect(try await store.bufferItems().count == 2)
    await model.shutdown()
  }
}

@MainActor @Suite(.serialized) struct BufferDraftNativeEditorTests {
  @Test func markedTextReturnAndUndoBelongToNativeEditor() throws {
    _ = NSApplication.shared
    let view = BufferDraftTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer {
      window.orderOut(nil)
      window.close()
    }
    view.isRichText = false
    view.allowsUndo = true
    view.string = "去北京开会"
    view.setSelectedRange(NSRange(location: 1, length: 2))
    window.makeFirstResponder(view)
    var submits = 0
    view.onSubmit = { submits += 1 }
    view.setMarkedText(
      "shanghai", selectedRange: NSRange(location: 8, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(view.hasMarkedText())
    let commandReturn = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero,
        modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    _ = view.performKeyEquivalent(with: commandReturn)
    #expect(submits == 0)
    view.insertText("上海", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(view.string == "去上海开会")
    #expect(!view.hasMarkedText())
    view.breakUndoCoalescing()
    view.insertNewline(nil)
    #expect(view.string.contains("\n"))
    #expect(submits == 0)
    view.undoManager?.undo()
    #expect(!view.string.contains("\n"))
    #expect(view.performKeyEquivalent(with: commandReturn))
    #expect(submits == 1)
    let capsLockReturn = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero,
        modifierFlags: [.command, .capsLock], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    #expect(view.performKeyEquivalent(with: capsLockReturn))
    #expect(submits == 2)
  }
}
