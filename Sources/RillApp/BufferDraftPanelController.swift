import AppKit
import Observation
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
  private var lastCollectionPreferences = (voice: false, clipboard: false)

  var isVisible: Bool { panel?.isVisible == true }
  var isKey: Bool { panel?.isKeyWindow == true }

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
      // Return the key focus to the captured application without ending the
      // editor session or closing the resident panel.
      self.panel?.makeFirstResponder(nil)
      self.panel?.orderOut(nil)
      self.editingActivity(false)
      self.output.output(id, capturedTarget: captured)
      self.panel?.orderFrontRegardless()
    }
  }

  func start() {
    observeCollectionPreferences()
  }

  private func observeCollectionPreferences() {
    guard !isClosed, let model else { return }
    let preferences = withObservationTracking {
      let settings = model.settings
      return (loading: settings.isLoading,
        voice: settings.builtinPushToTalkOutputMode == .saveToVoiceGroup,
        clipboard: settings.systemClipboardCaptureEnabled)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.observeCollectionPreferences() }
    }
    guard !preferences.loading else { return }
    let newlyEnabled = (preferences.voice && !lastCollectionPreferences.voice)
      || (preferences.clipboard && !lastCollectionPreferences.clipboard)
    lastCollectionPreferences = (preferences.voice, preferences.clipboard)
    if newlyEnabled { show(activate: false) }
  }

  func show(activate: Bool = true) {
    guard !isClosed, let model else { return }
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
      panel.onWillBecomeKey = { [weak self] in self?.beginEditingVisit() }
      panel.contentView = NSHostingView(rootView: RecordBufferDraftView(model: model))
      panel.center()
      panel.setFrameAutosaveName("RillDrafts")
      self.panel = panel
    }
    if !isVisible { model.recordWorkspace.buffers.editor.open() }
    if activate {
      panel?.makeKeyAndOrderFront(nil)
    } else {
      panel?.orderFrontRegardless()
    }
  }

  private func beginEditingVisit() {
    target = textOutput.captureDraftTarget()
    model?.recordWorkspace.buffers.editor.targetName = target?.applicationName
    model?.recordWorkspace.buffers.editor.open()
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
  var onWillBecomeKey: () -> Void = {}
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func becomeKey() {
    onWillBecomeKey()
    super.becomeKey()
  }
  override func cancelOperation(_ sender: Any?) { onEscape() }
}
