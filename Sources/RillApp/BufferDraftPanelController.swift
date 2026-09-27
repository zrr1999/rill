import AppKit
import RillPlatform
import RillUI
import SwiftUI

@MainActor
final class BufferDraftPanelController: NSObject, NSWindowDelegate {
  private weak var model: AppModel?
  private let output: BufferOutputController
  private let textOutput: RecordBufferTextOutput
  private let editingActivity: (Bool) -> Void
  private var target: RecordBufferTextOutput.Target?
  private var panel: DraftPanel?
  private var isClosed = false

  init(model: AppModel, output: BufferOutputController,
       textOutput: RecordBufferTextOutput = .init(), editingActivity: @escaping (Bool) -> Void) {
    self.model = model
    self.output = output
    self.textOutput = textOutput
    self.editingActivity = editingActivity
    super.init()
    model.recordWorkspace.buffers.editor.closeAction = { [weak self] in self?.hide() }
    model.recordWorkspace.buffers.editor.sendAction = { [weak self] id in
      guard let self else { return }
      let captured = self.target
      self.hide()
      self.output.output(id, capturedTarget: captured)
    }
  }

  func show() {
    guard !isClosed, let model else { return }
    if panel?.isVisible != true {
      target = textOutput.captureDraftTarget()
      model.recordWorkspace.buffers.editor.targetName = target?.applicationName
    }
    if panel == nil {
      let panel = DraftPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
        styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
      panel.title = model.settings.language == .simplifiedChinese ? "Rill · 待发区" : "Rill · Drafts"
      panel.level = .floating
      panel.isFloatingPanel = true
      panel.hidesOnDeactivate = false
      panel.isReleasedWhenClosed = false
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      panel.contentMinSize = NSSize(width: 580, height: 520)
      panel.delegate = self
      panel.onEscape = { [weak self] in self?.hide() }
      panel.contentView = NSHostingView(rootView: RecordBufferDraftView(
        model: model.recordWorkspace.buffers.editor, voice: model.voice, language: model.settings.language))
      panel.center()
      self.panel = panel
    }
    model.recordWorkspace.buffers.editor.open()
    panel?.makeKeyAndOrderFront(nil)
  }

  func hide() {
    panel?.makeFirstResponder(nil)
    model?.recordWorkspace.buffers.editor.close()
    panel?.orderOut(nil)
    editingActivity(false)
  }

  func shutdown() {
    isClosed = true
    hide()
    target = nil
    panel?.contentView = nil
    panel = nil
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
  func windowDidBecomeKey(_ notification: Notification) { editingActivity(true) }
  func windowDidResignKey(_ notification: Notification) { editingActivity(false) }
}

private final class DraftPanel: NSPanel {
  var onEscape: () -> Void = {}
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func cancelOperation(_ sender: Any?) { onEscape() }
}
