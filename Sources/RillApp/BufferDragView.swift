import AppKit
import RillCore
import RillPlatform

/// NSDraggingSession uses the drag pasteboard. It never touches NSPasteboard.general.
@MainActor
final class BufferDragView: NSView, NSDraggingSource {
  private let record: Record
  private let asFile: Bool
  private let shouldBegin: () -> Bool
  private let completion: (BufferTextResult) -> Void
  private var writers: [BufferFilePromiseWriter] = []
  private var didStart = false
  private var accepted = false
  private var finishedWrites = 0
  private var failedWrite = false
  private var completed = false

  init(
    record: Record, asFile: Bool = false, shouldBegin: @escaping () -> Bool,
    completion: @escaping (BufferTextResult) -> Void
  ) {
    self.shouldBegin = shouldBegin
    self.record = record
    self.asFile = asFile
    self.completion = completion
    super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 70))
    wantsLayer = true
    layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
    layer?.cornerRadius = 10
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(asFile ? "Drag PNG file / 拖出 PNG 文件" : "Drag to copy / 拖到目标应用以复制")
  }

  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let label = asFile ? "↗ PNG 文件 / PNG file" : "↗ 拖到目标应用 / Drag to copy"
    (label as NSString).draw(
      at: NSPoint(x: 18, y: 26),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.labelColor,
      ])
  }

  override func mouseDown(with event: NSEvent) {}

  override func mouseDragged(with event: NSEvent) {
    guard !didStart, shouldBegin() else { return }
    didStart = true
    var items: [NSDraggingItem] = []
    switch record.payload {
    case .text:
      completion(.rejected)
      return
    case .image(let data) where !asFile:
      guard let image = NSImage(data: data) else {
        completion(.rejected)
        return
      }
      items = [NSDraggingItem(pasteboardWriter: image)]
    case .image(let data):
      writers = [BufferFilePromiseWriter(source: .image(data), feedback: feedback)]
    case .files(let urls):
      guard urls.allSatisfy({ $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) })
      else {
        completion(.rejected)
        return
      }
      writers = urls.map { BufferFilePromiseWriter(source: .file($0), feedback: feedback) }
    }
    items += writers.map { NSDraggingItem(pasteboardWriter: $0.provider()) }
    let preview =
      NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
      ?? NSImage(size: NSSize(width: 48, height: 48))
    for (index, item) in items.enumerated() {
      item.setDraggingFrame(
        NSRect(x: 12 + index * 8, y: 10, width: 48, height: 48), contents: preview)
    }
    let session = beginDraggingSession(with: items, event: event, source: self)
    session.animatesToStartingPositionsOnCancelOrFail = true
  }

  private var feedback: @Sendable (Bool) -> Void {
    { [weak self] success in
      Task { @MainActor in
        guard let self else { return }
        self.finishedWrites += 1
        self.failedWrite = self.failedWrite || !success
        self.settleIfReady()
      }
    }
  }

  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation { .copy }
  func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

  func draggingSession(
    _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
  ) {
    accepted = operation == .copy
    if !accepted { finish(.rejected) } else { settleIfReady() }
  }

  private func settleIfReady() {
    guard accepted else { return }
    guard finishedWrites == writers.count else { return }
    finish(failedWrite ? .unconfirmed : .verified)
  }

  private func finish(_ result: BufferTextResult) {
    guard !completed else { return }
    completed = true
    completion(result)
  }
}
