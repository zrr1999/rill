import AppKit
import SwiftUI

public struct RecordPanelCapsuleView: View {
  @Bindable private var model: AppModel
  private let onExpand: () -> Void
  private let onClose: () -> Void
  private let onDrag: (NSPoint) -> Void
  private let onDragActivity: (Bool) -> Void

  public init(
    model: AppModel, onExpand: @escaping () -> Void, onClose: @escaping () -> Void,
    onDrag: @escaping (NSPoint) -> Void = { _ in },
    onDragActivity: @escaping (Bool) -> Void = { _ in }
  ) {
    self.model = model
    self.onExpand = onExpand
    self.onClose = onClose
    self.onDrag = onDrag
    self.onDragActivity = onDragActivity
  }

  private var buffers: RecordBufferModel { model.recordWorkspace.buffers }
  private var needsAttention: Bool {
    buffers.editor.failure != nil || buffers.message != nil || buffers.snapshot?.active != nil
  }
  private func panelText(_ key: RecordPanelText) -> String {
    L10n.recordPanel(key, language: model.settings.language)
  }

  public var body: some View {
    HStack(spacing: 8) {
      HStack(spacing: 10) {
        dragGrip
        Image(systemName: RillSystemSymbol.tray.rawValue).font(.system(size: 14)).foregroundStyle(.secondary)
        Text(panelText(.drafts)).font(.system(size: 14, weight: .medium))
        Text("\(buffers.snapshot?.remainingCount ?? 0)")
          .font(.system(size: 14).monospacedDigit()).foregroundStyle(.secondary)
          .frame(width: 40, alignment: .leading).lineLimit(1)
        Spacer(minLength: 0)
        Image(systemName: RillSystemSymbol.exclamationmarkCircle.rawValue).foregroundStyle(.orange)
          .frame(width: 16).opacity(needsAttention ? 1 : 0)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay {
        CapsuleDragHandle(
          label: panelText(.moveAndOpen),
          onExpand: onExpand, onDrag: onDrag, onDragActivity: onDragActivity)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(panelText(.drafts) + " · \(buffers.snapshot?.remainingCount ?? 0)")
      .accessibilityValue(needsAttention ? panelText(.needsAttention) : "")
      .accessibilityAction { onExpand() }
      Button(action: onClose) { Image(systemName: RillSystemSymbol.xmark.rawValue).font(.caption).frame(width: 28, height: 32) }
        .buttonStyle(.borderless).foregroundStyle(.secondary)
        .disabled(buffers.editor.session?.hasMarkedText == true)
        .accessibilityLabel(panelText(.closeFloatingWindow))
        .accessibilityIdentifier("record-panel.close")
    }
    .padding(.leading, 14).padding(.trailing, 8)
    .frame(width: 260, height: 48)
    .rillGlass(in: Capsule(), interactive: true)
    .accessibilityIdentifier("record-panel.capsule")
  }

  private var dragGrip: some View {
    VStack(spacing: 3) {
      ForEach(0..<3) { _ in
        HStack(spacing: 3) {
          Circle().frame(width: 2, height: 2)
          Circle().frame(width: 2, height: 2)
        }
      }
    }
    .foregroundStyle(.secondary)
    .frame(width: 12, height: 16)
    .accessibilityHidden(true)
  }
}

struct CapsuleDragHandle: NSViewRepresentable {
  let label: String
  let onExpand: () -> Void
  let onDrag: (NSPoint) -> Void
  let onDragActivity: (Bool) -> Void

  func makeNSView(context: Context) -> Handle {
    let view = Handle()
    view.setAccessibilityRole(.button)
    view.setAccessibilityIdentifier("record-panel.move-and-open")
    return view
  }

  func updateNSView(_ view: Handle, context: Context) {
    view.setAccessibilityLabel(label)
    view.onExpand = onExpand
    view.onDrag = onDrag
    view.onDragActivity = onDragActivity
  }

  final class Handle: NSView {
    var onExpand: () -> Void = {}
    var onDrag: (NSPoint) -> Void = { _ in }
    var onDragActivity: (Bool) -> Void = { _ in }
    private var origin: NSPoint?
    private var previous: NSPoint?
    private var isDragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func accessibilityPerformPress() -> Bool {
      onExpand()
      return true
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
      origin = NSEvent.mouseLocation
      previous = origin
    }

    override func mouseDragged(with event: NSEvent) {
      guard let origin, let previous else { return }
      let point = NSEvent.mouseLocation
      guard isDragging || hypot(point.x - origin.x, point.y - origin.y) >= 5 else { return }
      if !isDragging {
        isDragging = true
        onDragActivity(true)
      }
      NSCursor.closedHand.set()
      onDrag(NSPoint(x: point.x - previous.x, y: point.y - previous.y))
      self.previous = point
    }

    override func mouseUp(with event: NSEvent) {
      let wasDragging = isDragging
      origin = nil
      previous = nil
      isDragging = false
      NSCursor.openHand.set()
      if wasDragging { onDragActivity(false) }
    }
  }
}
