import AppKit
import RillInputMethodContracts

@MainActor
final class CandidateWindow {
  private let panel: NSPanel
  private var placement = CandidateWindowPlacement()
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

  func show(
    _ snapshot: RimeSession.Snapshot, at caret: NSRect,
    fallbackCaret: (() -> NSRect)? = nil,
    appearance: InputMethodAppearance = .defaults
  ) {
    guard !snapshot.candidates.isEmpty else {
      hide()
      return
    }
    let screens = NSScreen.screens.map {
      CandidateWindowPlacement.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame)
    }
    guard let anchor = placement.resolve(caret, screens: screens, fallbackCaret: fallbackCaret) else {
      hide()
      return
    }
    let visible = anchor.visibleFrame
    let content = candidateContentView()
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    stack.edgeInsets = NSEdgeInsets(top: 7, left: 9, bottom: 7, right: 9)
    let font =
      appearance.fontName.flatMap { NSFont(name: $0, size: appearance.fontSize) }
      ?? .systemFont(ofSize: appearance.fontSize)
    var preferredWidth: CGFloat = 120
    for (index, candidate) in snapshot.candidates.enumerated() {
      let button = NSButton(
        title: appearance.candidateTitle(at: index, text: candidate.text, comment: candidate.comment), target: self,
        action: #selector(choose(_:)))
      button.tag = index
      button.isBordered = false
      button.alignment = .left
      button.font = font
      button.cell?.lineBreakMode = .byTruncatingTail
      button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      let isSelected = index == snapshot.selected
      button.contentTintColor = isSelected ? .controlAccentColor : .labelColor
      button.setAccessibilityLabel(
        InputMethodAppearance.defaults.candidateTitle(
          at: index, text: candidate.text, comment: candidate.comment))
      button.setAccessibilitySelected(isSelected)
      button.toolTip = candidate.text
      preferredWidth = max(preferredWidth, button.intrinsicContentSize.width + 18)
      stack.addArrangedSubview(button)
      button.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -18).isActive = true
    }
    stack.translatesAutoresizingMaskIntoConstraints = false
    let width = stack.widthAnchor.constraint(equalToConstant: min(preferredWidth, 560, visible.width - 16))
    width.isActive = true
    let fittingSize = stack.fittingSize
    let size = NSSize(width: fittingSize.width, height: min(fittingSize.height, visible.height - 16))
    let body: NSView
    if fittingSize.height > size.height {
      let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
      scroll.drawsBackground = false
      scroll.hasVerticalScroller = true
      scroll.autohidesScrollers = true
      scroll.scrollerStyle = .overlay
      stack.frame = NSRect(origin: .zero, size: fittingSize)
      scroll.documentView = stack
      width.isActive = false
      stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
      body = scroll
    } else {
      body = stack
    }
    content.addSubview(body)
    body.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      body.topAnchor.constraint(equalTo: content.topAnchor),
      body.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      body.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
    ])
    panel.contentView = content
    panel.setFrame(anchor.frame(for: size), display: true)
    if body is NSScrollView {
      content.layoutSubtreeIfNeeded()
      stack.layoutSubtreeIfNeeded()
      let index = stack.arrangedSubviews.indices.contains(snapshot.selected) ? snapshot.selected : 0
      let selected = stack.arrangedSubviews[index]
      selected.scrollToVisible(selected.bounds)
    }
    panel.orderFrontRegardless()
  }

  func hide() {
    panel.orderOut(nil)
    placement.reset()
  }
  @objc private func choose(_ sender: NSButton) { selected?(sender.tag) }

  private func candidateContentView() -> NSView {
    let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    if reduceTransparency || increaseContrast {
      return OpaqueCandidateSurface()
    }
    let content = NSVisualEffectView()
    content.material = .popover
    content.state = .active
    content.wantsLayer = true
    content.layer?.cornerRadius = 9
    return content
  }
}

/// Opaque fallback for Reduce Transparency and Increase Contrast. The semantic
/// color is resolved while drawing so an appearance change does not keep a
/// stale layer color. The radius matches the existing candidate chrome.
@MainActor
private final class OpaqueCandidateSurface: NSView {
  override var isOpaque: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.controlBackgroundColor.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
  }
}
