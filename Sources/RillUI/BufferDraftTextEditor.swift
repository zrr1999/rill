import AppKit
import RillCore
import SwiftUI

struct BufferDraftTextEditor: NSViewRepresentable {
  @Bindable var model: RecordBufferDraftModel
  @Bindable var session: BufferEditingSession
  let accessibilityLabel: String

  func makeCoordinator() -> Coordinator { Coordinator(model: model, session: session) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    let view = BufferDraftTextView()
    view.isRichText = false
    view.importsGraphics = false
    view.allowsUndo = true
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.isAutomaticDashSubstitutionEnabled = false
    view.isAutomaticTextReplacementEnabled = false
    view.font = .systemFont(ofSize: 14)
    view.textColor = .textColor
    view.drawsBackground = false
    view.textContainerInset = NSSize(width: 22, height: 4)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 7
    view.defaultParagraphStyle = paragraph
    view.typingAttributes[.paragraphStyle] = paragraph
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]
    view.textContainer?.widthTracksTextView = true
    view.textContainer?.lineFragmentPadding = 0
    view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    view.setAccessibilityIdentifier("record-buffer.editor")
    view.setAccessibilityLabel(accessibilityLabel)
    view.string = session.text
    view.textStorage?.addAttribute(.paragraphStyle, value: paragraph,
      range: NSRange(location: 0, length: view.string.utf16.count))
    view.delegate = context.coordinator
    view.onSubmit = { [weak model] in model?.send() }
    view.onFocusChanged = { [weak session] focused in session?.isFocused = focused }
    view.onCompositionEnded = { [weak coordinator = context.coordinator, weak view] in
      if let view { coordinator?.changed(view) }
    }
    scroll.documentView = view
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let view = scroll.documentView as? BufferDraftTextView else { return }
    view.isInteractionEnabled = context.environment.isEnabled
    view.isEditable = !model.isBusy && context.environment.isEnabled
    guard !view.hasMarkedText(), view.string != session.text else { return }
    context.coordinator.isUpdating = true
    // insertText participates in the native undo stack; one final ASR result
    // is one edit, while partial results never enter the text storage.
    view.breakUndoCoalescing()
    view.insertText(session.text, replacementRange: NSRange(location: 0, length: view.string.utf16.count))
    view.breakUndoCoalescing()
    let position = min(session.selection.location, view.string.utf16.count)
    view.setSelectedRange(NSRange(location: position, length: min(session.selection.length, view.string.utf16.count - position)))
    context.coordinator.isUpdating = false
  }

  @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
    let model: RecordBufferDraftModel
    let session: BufferEditingSession
    var isUpdating = false

    init(model: RecordBufferDraftModel, session: BufferEditingSession) {
      self.model = model
      self.session = session
    }

    func changed(_ view: NSTextView) {
      guard !isUpdating else { return }
      session.hasMarkedText = view.hasMarkedText()
      session.selection = .init(location: view.selectedRange().location, length: view.selectedRange().length)
      model.edit(view.string, sessionID: session.id)
    }

    func textDidChange(_ notification: Notification) {
      if let view = notification.object as? NSTextView { changed(view) }
    }

    func textDidBeginEditing(_ notification: Notification) { session.isFocused = true }
    func textDidEndEditing(_ notification: Notification) {
      session.isFocused = false
      if let view = notification.object as? NSTextView { changed(view) }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard !isUpdating, let view = notification.object as? NSTextView else { return }
      session.selection = .init(location: view.selectedRange().location, length: view.selectedRange().length)
      session.hasMarkedText = view.hasMarkedText()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      guard !textView.hasMarkedText(),
        (textView as? BufferDraftTextView)?.eventStartedWithMarkedText != true else { return false }
      if selector == #selector(NSResponder.cancelOperation(_:)) {
        textView.window?.makeFirstResponder(nil)
        session.isFocused = false
        return true
      }
      return false
    }
  }
}

final class BufferDraftTextView: NSTextView {
  var isInteractionEnabled = true
  override var acceptsFirstResponder: Bool { isInteractionEnabled && super.acceptsFirstResponder }

  var onSubmit: () -> Void = {}
  var onFocusChanged: (Bool) -> Void = { _ in }
  var onCompositionEnded: () -> Void = {}
  private(set) var eventStartedWithMarkedText = false

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { onFocusChanged(true) }
    return accepted
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.keyCode == 36, event.modifierFlags.intersection([.command, .shift, .control, .option]) == .command,
      !hasMarkedText() {
      onSubmit()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func keyDown(with event: NSEvent) {
    eventStartedWithMarkedText = hasMarkedText()
    defer { eventStartedWithMarkedText = false }
    if event.keyCode == 36, event.modifierFlags.intersection([.command, .shift, .control, .option]) == .command,
      !eventStartedWithMarkedText {
      onSubmit()
      return
    }
    super.keyDown(with: event)
  }

  override func unmarkText() {
    super.unmarkText()
    onCompositionEnded()
  }

  override func resignFirstResponder() -> Bool {
    if hasMarkedText() { unmarkText() }
    let accepted = super.resignFirstResponder()
    if accepted { onFocusChanged(false) }
    return accepted
  }
}
