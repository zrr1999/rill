import AppKit

enum RecordPanelPlacement {
  static let capsuleSize = NSSize(width: 260, height: 48)
  static let pageSize = NSSize(width: 668, height: 468)
  static let gap: CGFloat = 14
  static let margin: CGFloat = 12

  static func pageFrame(beside capsule: NSRect, in visibleFrame: NSRect) -> NSRect {
    let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
    let below = max(0, capsule.minY - gap - bounds.minY)
    let above = max(0, bounds.maxY - capsule.maxY - gap)
    let opensBelow = below >= pageSize.height || below >= above
    let size = NSSize(
      width: min(pageSize.width, bounds.width),
      height: min(pageSize.height, opensBelow ? below : above))
    return NSRect(
      x: clamp(capsule.midX - size.width / 2, bounds.minX, bounds.maxX - size.width),
      y: opensBelow ? capsule.minY - gap - size.height : capsule.maxY + gap,
      width: size.width, height: size.height)
  }

  static func translation(
    _ delta: NSPoint, capsule: NSRect, page: NSRect?,
    in visibleFrame: NSRect
  ) -> NSPoint {
    let group = page.map { capsule.union($0) } ?? capsule
    let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
    return NSPoint(
      x: clamp(delta.x, bounds.minX - group.minX, bounds.maxX - group.maxX),
      y: clamp(delta.y, bounds.minY - group.minY, bounds.maxY - group.maxY))
  }

  static func contains(_ point: NSPoint, capsule: NSRect, page: NSRect?) -> Bool {
    if capsule.contains(point) { return true }
    guard let page else { return false }
    if page.contains(point) { return true }
    let lower: NSRect, upper: NSRect
    if page.maxY <= capsule.minY {
      lower = page
      upper = capsule
    } else {
      lower = capsule
      upper = page
    }
    guard point.y >= lower.maxY, point.y <= upper.minY, upper.minY > lower.maxY else { return false }
    let progress = (point.y - lower.maxY) / (upper.minY - lower.maxY)
    let left = lower.minX + (upper.minX - lower.minX) * progress - 8
    let right = lower.maxX + (upper.maxX - lower.maxX) * progress + 8
    return point.x >= left && point.x <= right
  }

  private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    max(lower, min(value, max(lower, upper)))
  }
}
