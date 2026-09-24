import AppKit
import RillCore
import RillPlatform
import RillRuntime
import RillUI
import SwiftUI

@MainActor
final class BufferOutputController: NSObject {
  private let store: RecordStore
  private weak var model: AppModel?
  private let textOutput: RecordBufferTextOutput
  private let injectionEngine: TextInjectionEngine
  private let isRillFrontmost: () -> Bool
  private var task: Task<Void, Never>?
  private var dragSettlementTask: Task<Void, Never>?
  private var panel: NSPanel?
  private var retainedDragViews: [BufferDragView] = []
  private var isClosed = false
  private var dragGeneration: UInt64 = 0
  private var dragStarted = false

  init(
    store: RecordStore, model: AppModel, injectionEngine: TextInjectionEngine,
    textOutput: RecordBufferTextOutput = .init(),
    isRillFrontmost: @escaping () -> Bool = {
      NSWorkspace.shared.frontmostApplication?.processIdentifier
        == ProcessInfo.processInfo.processIdentifier
    }
  ) {
    self.store = store
    self.model = model
    self.textOutput = textOutput
    self.injectionEngine = injectionEngine
    self.isRillFrontmost = isRillFrontmost
    super.init()
  }

  func output(_ manualEntry: BufferEntryID? = nil) {
    guard !isClosed, task == nil, dragSettlementTask == nil, let model else { return }
    let target = textOutput.captureTarget()
    model.recordWorkspace.buffers.isSending = true
    task = Task {
      defer {
        task = nil
        model.recordWorkspace.buffers.isSending = false
      }
      do {
        if let manualEntry { try await store.requestBufferEntry(manualEntry) }
        if isRillFrontmost() {
          notify("请聚焦目标输入框，再按输出快捷键。", "Focus the target, then press the output shortcut.")
          return
        }
        let snapshot = try await store.bufferSnapshot()
        if let active = snapshot.active {
          if active.state == .delivered {
            try await settle(active.id)
            return
          }
          if active.state == .delivering, !retainedDragViews.isEmpty {
            panel?.orderFrontRegardless()
            return
          }
          showConfirmation()
          return
        }
        let output = try await store.beginBufferOutput()
        if Task.isCancelled {
          try await store.retryBufferOutput(output.entry.id)
          return
        }
        switch output.record.payload {
        case .text(let text):
          guard let target else {
            try await store.retryBufferOutput(output.entry.id)
            notify("此输入控件不支持输出，内容已保留。", "This control cannot receive text. The item is retained.")
            return
          }
          let result = await injectionEngine.insertBufferText(text, into: target, using: textOutput)
          await finish(result, entry: output.entry.id)
        case .image, .files:
          showDrag(output)
        }
      } catch BufferOutputError.empty {
        notify("没有待输出内容", "Nothing pending")
      } catch BufferOutputError.processing {
        notify("下一项仍在处理中", "The next item is still processing")
      } catch {
        notify("操作未完成，内容已保留。", "The operation could not finish. The item is retained.")
      }
    }
  }

  private func finish(_ result: BufferTextResult, entry: BufferEntryID) async {
    do {
      switch result {
      case .verified: try await settle(entry)
      case .unconfirmed:
        try await store.markBufferOutputUnconfirmed(entry)
        showConfirmation()
      case .rejected:
        try await store.retryBufferOutput(entry)
        panel?.orderOut(nil)
        notify("目标未接收，内容已保留。", "The target did not accept the item. It is retained.")
      }
    } catch {
      notify(
        "输出状态尚未保存；再次触发只重试保存。",
        "Output state could not be saved. The next request retries settlement only.")
      showConfirmation()
    }
  }

  private func settle(_ entry: BufferEntryID) async throws {
    try await store.finishBufferOutput(entry)
    panel?.orderOut(nil)
    retainedDragViews.removeAll()
    model?.recordWorkspace.buffers.message = nil
  }

  func confirm() {
    guard !isClosed, task == nil, dragSettlementTask == nil else { return }
    task = Task {
      defer { task = nil }
      guard let active = try? await store.bufferSnapshot().active else { return }
      do { try await settle(active.id) } catch {
        notify("状态保存失败；内容不会再次发送。", "Settlement failed. The item will not be sent again.")
      }
    }
  }

  func retry() {
    guard !isClosed, task == nil, dragSettlementTask == nil else { return }
    task = Task {
      defer { task = nil }
      guard let active = try? await store.bufferSnapshot().active, active.state != .delivered else {
        return
      }
      do {
        try await store.retryBufferOutput(active.id, keepSelected: true)
        dragGeneration += 1
        panel?.orderOut(nil)
        notify(
          "请聚焦目标输入框，再按输出快捷键重试这一项。",
          "Focus the target, then press the output shortcut to retry this item.")
      } catch { notify("状态保存失败，暂未重试。", "Could not save state; nothing was resent.") }
    }
  }

  func cancel() {
    task?.cancel()
    // A cancellation after any external effect remains guarded for confirmation.
    panel?.orderOut(nil)
  }

  func shutdown() async {
    isClosed = true
    task?.cancel()
    await task?.value
    await dragSettlementTask?.value
    dragGeneration += 1
    if let active = try? await store.bufferSnapshot().active, active.state == .delivering {
      if dragStarted {
        try? await store.markBufferOutputUnconfirmed(active.id)
      } else {
        try? await store.retryBufferOutput(active.id)
      }
    }
    panel?.orderOut(nil)
  }

  func showMessage() {
    guard task == nil, dragSettlementTask == nil, retainedDragViews.isEmpty else { return }
    showConfirmation()
  }

  private func showConfirmation() {
    guard let model else { return }
    show(
      content: NSHostingView(
        rootView: RecordBufferStatusView(
          model: model.recordWorkspace.buffers, language: model.language)))
  }

  private func showDrag(_ output: BufferOutput) {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    if let model {
      stack.addArrangedSubview(
        NSHostingView(
          rootView: RecordBufferSummaryView(
            model: model.recordWorkspace.buffers, language: model.language)))
    }
    switch output.record.payload {
    case .image(let data):
      if let image = NSImage(data: data) {
        let preview = NSImageView(image: image)
        preview.imageScaling = .scaleProportionallyDown
        preview.heightAnchor.constraint(equalToConstant: 90).isActive = true
        stack.addArrangedSubview(preview)
      }
    case .text, .files: break
    }
    dragGeneration += 1
    let generation = dragGeneration
    let completion: (BufferTextResult) -> Void = { [weak self] result in
      guard let self, !self.isClosed, self.dragGeneration == generation,
        self.dragSettlementTask == nil
      else { return }
      self.dragSettlementTask = Task {
        defer { self.dragSettlementTask = nil }
        await self.finish(result, entry: output.entry.id)
      }
    }
    dragStarted = false
    retainedDragViews = [
      BufferDragView(
        record: output.record, shouldBegin: { [weak self] in self?.beginDrag() ?? false },
        completion: completion)
    ]
    if case .image = output.record.payload {
      retainedDragViews.append(
        BufferDragView(
          record: output.record, asFile: true,
          shouldBegin: { [weak self] in self?.beginDrag() ?? false }, completion: completion))
    }
    for view in retainedDragViews {
      stack.addArrangedSubview(view)
      view.widthAnchor.constraint(equalToConstant: 340).isActive = true
      view.heightAnchor.constraint(equalToConstant: 70).isActive = true
    }
    let cancel = NSButton(title: "取消 / Cancel", target: self, action: #selector(cancelDrag))
    stack.addArrangedSubview(cancel)
    show(content: stack)
  }

  private func beginDrag() -> Bool {
    guard !dragStarted else { return false }
    dragStarted = true
    return true
  }

  @objc private func cancelDrag() {
    guard !isClosed, task == nil, dragSettlementTask == nil, let model else { return }
    panel?.orderOut(nil)
    task = Task {
      defer { task = nil }
      if let active = try? await store.bufferSnapshot().active {
        dragGeneration += 1
        if dragStarted {
          try? await store.markBufferOutputUnconfirmed(active.id)
        } else {
          try? await store.retryBufferOutput(active.id)
        }
      }
      model.recordWorkspace.buffers.message = nil
    }
  }

  private func notify(_ chinese: String, _ english: String) {
    guard let model else { return }
    model.recordWorkspace.buffers.message = model.language == .simplifiedChinese ? chinese : english
    showConfirmation()
  }

  private func show(content: NSView) {
    guard !isClosed else { return }
    if panel == nil {
      panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 390, height: 230),
        styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
      panel?.level = .floating
      panel?.isFloatingPanel = true
      panel?.becomesKeyOnlyIfNeeded = true
      panel?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      panel?.title = model?.language == .simplifiedChinese ? "Rill · 输出下一项" : "Rill · Output Next"
      panel?.center()
    }
    panel?.contentView = content
    panel?.setContentSize(
      NSSize(width: 390, height: max(230, min(420, content.fittingSize.height))))
    panel?.orderFrontRegardless()
  }
}
