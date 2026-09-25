import AppKit

@MainActor
final class CandidateWindow {
  private let panel: NSPanel
  var selected: ((Int) -> Void)?

  init() {
    panel = NSPanel(
      contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered,
      defer: false)
    panel.level = .popUpMenu
    panel.hasShadow = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isReleasedWhenClosed = false
  }

  func show(_ snapshot: RimeSession.Snapshot, at caret: NSRect) {
    guard !snapshot.candidates.isEmpty else {
      hide()
      return
    }
    let visible =
      NSScreen.screens.first { $0.frame.intersects(caret) }?.visibleFrame ?? NSScreen.main?
      .visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
    let content = NSVisualEffectView()
    content.material = .popover
    content.state = .active
    content.wantsLayer = true
    content.layer?.cornerRadius = 9
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    stack.edgeInsets = NSEdgeInsets(top: 7, left: 9, bottom: 7, right: 9)
    var preferredWidth: CGFloat = 120
    for (index, candidate) in snapshot.candidates.enumerated() {
      let button = NSButton(
        title: "\(index + 1)  \(candidate.text)  \(candidate.comment)", target: self,
        action: #selector(choose(_:)))
      button.tag = index
      button.isBordered = false
      button.alignment = .left
      button.font = .systemFont(ofSize: 20)
      button.cell?.lineBreakMode = .byTruncatingTail
      button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      button.contentTintColor = index == snapshot.selected ? .controlAccentColor : .labelColor
      button.setAccessibilityLabel(candidate.text)
      button.toolTip = candidate.text
      preferredWidth = max(preferredWidth, button.intrinsicContentSize.width + 18)
      stack.addArrangedSubview(button)
      button.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -18).isActive = true
    }
    content.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: content.topAnchor),
      stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      stack.widthAnchor.constraint(equalToConstant: min(preferredWidth, 560, visible.width - 16)),
    ])
    panel.contentView = content
    let size = stack.fittingSize
    let x = min(max(caret.minX, visible.minX), max(visible.minX, visible.maxX - size.width))
    let below = caret.minY - size.height - 4
    let y = below >= visible.minY ? below : min(caret.maxY + 4, visible.maxY - size.height)
    panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    panel.orderFrontRegardless()
  }

  func hide() { panel.orderOut(nil) }
  @objc private func choose(_ sender: NSButton) { selected?(sender.tag) }
}
