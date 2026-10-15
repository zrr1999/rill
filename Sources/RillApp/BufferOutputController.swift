import AppKit
import Observation
import RillCore
import RillPlatform
import RillRecords
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
  private var isPresentingDrag = false
  private var pendingMessage: LocalizedStringResource?
  private var cancelButton: NSButton?

  var presentStatus: (() -> Void)?
  var isVisible: Bool { panel?.isVisible ?? false }

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
    observeLanguage()
  }

  func output(_ manualEntry: BufferEntryID? = nil) {
    beginOutput(manualEntry, target: textOutput.captureTarget())
  }

  func output(_ manualEntry: BufferEntryID, capturedTarget: RecordBufferTextOutput.Target?) {
    beginOutput(manualEntry, target: capturedTarget)
  }

  private func beginOutput(_ manualEntry: BufferEntryID?, target: RecordBufferTextOutput.Target?) {
    guard !isClosed, task == nil, dragSettlementTask == nil, let model else { return }
    model.recordWorkspace.buffers.isSending = true
    task = Task {
      defer {
        task = nil
        model.recordWorkspace.buffers.isSending = false
        presentPendingMessageIfPossible()
      }
      do {
        if let manualEntry { try await store.requestBufferEntry(manualEntry) }
        if isRillFrontmost() {
          notify(L10n.bufferOutputMessage(.focusTarget))
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
            notify(L10n.bufferOutputMessage(.unsupportedControl))
            return
          }
          let result = await injectionEngine.insertBufferText(text, into: target, using: textOutput)
          await finish(result, entry: output.entry.id)
        case .image, .files:
          showDrag(output)
        }
      } catch BufferOutputError.empty {
        notify(L10n.bufferOutputMessage(.empty))
      } catch BufferOutputError.processing {
        notify(L10n.bufferOutputMessage(.processing))
      } catch BufferOutputError.editing {
        notify(L10n.bufferOutputMessage(.draft))
      } catch {
        notify(L10n.bufferOutputMessage(.operationFailed))
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
        notify(L10n.bufferOutputMessage(.rejected))
      }
    } catch {
      notify(L10n.bufferOutputMessage(.settlementPending))
      showConfirmation()
    }
  }

  private func settle(_ entry: BufferEntryID) async throws {
    try await store.finishBufferOutput(entry)
    panel?.orderOut(nil)
    isPresentingDrag = false
    retainedDragViews.removeAll()
    model?.recordWorkspace.buffers.message = nil
  }

  func confirm() {
    guard !isClosed, task == nil, dragSettlementTask == nil else { return }
    task = Task {
      defer {
        task = nil
        presentPendingMessageIfPossible()
      }
      guard let active = try? await store.bufferSnapshot().active else { return }
      do { try await settle(active.id) } catch {
        notify(L10n.bufferOutputMessage(.settlementFailed))
      }
    }
  }

  func retry() {
    guard !isClosed, task == nil, dragSettlementTask == nil else { return }
    task = Task {
      defer {
        task = nil
        presentPendingMessageIfPossible()
      }
      guard let active = try? await store.bufferSnapshot().active, active.state != .delivered else {
        return
      }
      do {
        try await store.retryBufferOutput(active.id, keepSelected: true)
        dragGeneration += 1
        panel?.orderOut(nil)
        notify(L10n.bufferOutputMessage(.retryTarget))
      } catch { notify(L10n.bufferOutputMessage(.retryFailed)) }
    }
  }

  func cancel() {
    task?.cancel()
    // A cancellation after any external effect remains guarded for confirmation.
    panel?.orderOut(nil)
    isPresentingDrag = false
    presentPendingMessageIfPossible()
  }

  func shutdown() async {
    isClosed = true
    pendingMessage = nil
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

  func showMessage(_ message: LocalizedStringResource) {
    guard !isClosed else { return }
    pendingMessage = message
    presentPendingMessageIfPossible()
  }

  private func presentPendingMessageIfPossible() {
    guard !isClosed, task == nil, dragSettlementTask == nil, !isPresentingDrag,
      let message = pendingMessage, let model
    else { return }
    pendingMessage = nil
    model.recordWorkspace.buffers.message = message
    showConfirmation()
  }

  private func showConfirmation() {
    guard let model else { return }
    isPresentingDrag = false
    if let presentStatus {
      panel?.orderOut(nil)
      presentStatus()
      return
    }
    show(
      content: NSHostingView(
        rootView: BufferOutputStatusView(model: model, summaryOnly: false)))
  }

  private func showDrag(_ output: BufferOutput) {
    isPresentingDrag = true
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    if let model {
      stack.addArrangedSubview(
        NSHostingView(
          rootView: BufferOutputStatusView(model: model, summaryOnly: true)))
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
        defer {
          self.dragSettlementTask = nil
          self.presentPendingMessageIfPossible()
        }
        await self.finish(result, entry: output.entry.id)
      }
    }
    dragStarted = false
    retainedDragViews = [
      BufferDragView(
        record: output.record, language: model?.settings.language ?? .preferred, shouldBegin: { [weak self] in self?.beginDrag() ?? false },
        completion: completion)
    ]
    if case .image = output.record.payload {
      retainedDragViews.append(
        BufferDragView(
          record: output.record, asFile: true, language: model?.settings.language ?? .preferred,
          shouldBegin: { [weak self] in self?.beginDrag() ?? false }, completion: completion))
    }
    for view in retainedDragViews {
      stack.addArrangedSubview(view)
      view.widthAnchor.constraint(equalToConstant: 340).isActive = true
      view.heightAnchor.constraint(equalToConstant: 70).isActive = true
    }
    let cancel = NSButton(title: L10n.surface(.cancel, language: model?.settings.language ?? .preferred), target: self, action: #selector(cancelDrag))
    cancelButton = cancel
    stack.addArrangedSubview(cancel)
    show(content: stack)
  }

  private func beginDrag() -> Bool {
    guard !dragStarted else { return false }
    dragStarted = true
    return true
  }

  @objc func cancelDrag() {
    guard !isClosed, task == nil, dragSettlementTask == nil, let model else { return }
    panel?.orderOut(nil)
    isPresentingDrag = false
    task = Task {
      defer {
        task = nil
        presentPendingMessageIfPossible()
      }
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

  private func notify(_ message: LocalizedStringResource) {
    guard let model else { return }
    model.recordWorkspace.buffers.message = message
    showConfirmation()
  }

  private func observeLanguage() {
    guard !isClosed else { return }
    withObservationTracking {
      _ = model?.settings.language
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, !self.isClosed else { return }
        self.synchronizeLanguage()
        self.observeLanguage()
      }
    }
  }

  private func synchronizeLanguage() {
    let language = model?.settings.language ?? .preferred
    panel?.title = L10n.surface(.rillOutputNext, language: language)
    cancelButton?.title = L10n.surface(.cancel, language: language)
    for view in retainedDragViews { view.updateLanguage(language) }
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
      panel?.title = L10n.surface(
        .rillOutputNext, language: model?.settings.language ?? .english)
      panel?.center()
    }
    synchronizeLanguage()
    panel?.contentView = content
    panel?.setContentSize(
      NSSize(width: 390, height: max(230, min(420, content.fittingSize.height))))
    panel?.orderFrontRegardless()
  }
}

private struct BufferOutputStatusView: View {
  let model: AppModel
  let summaryOnly: Bool

  var body: some View {
    Group {
      if summaryOnly {
        RecordBufferSummaryView(model: model.recordWorkspace.buffers, language: model.settings.language)
      } else {
        RecordBufferStatusView(model: model.recordWorkspace.buffers, language: model.settings.language)
      }
    }
    .environment(\.locale, model.settings.language.formattingLocale)
  }
}
