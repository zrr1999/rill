import AppKit
import RillUI

enum RecordPanelPlacement {
  static var pageSize: NSSize {
    NSSize(
      width: RillDynamicLength.scaled(668, minimum: 620, maximum: 820),
      height: RillDynamicLength.scaled(468, minimum: 400, maximum: 640)
    )
  }
  static let margin: CGFloat = 12

  static func pageFrame(in visibleFrame: NSRect) -> NSRect {
    let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
    let size = NSSize(
      width: min(pageSize.width, bounds.width),
      height: min(pageSize.height, bounds.height))
    return NSRect(
      x: bounds.midX - size.width / 2,
      y: bounds.midY - size.height / 2,
      width: size.width, height: size.height)
  }
}
