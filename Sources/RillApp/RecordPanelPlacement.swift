import AppKit

enum RecordPanelPlacement {
  static let capsuleSize = NSSize(width: 260, height: 48)
  static let pageSize = NSSize(width: 668, height: 468)
  static let gap: CGFloat = 14
  static let margin: CGFloat = 12
  private static let sideSwitchHysteresis: CGFloat = 24

  static func pageFrame(beside capsule: NSRect, in visibleFrame: NSRect, prefersBelow: Bool? = nil) -> NSRect {
    let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
    let below = max(0, capsule.minY - gap - bounds.minY)
    let above = max(0, bounds.maxY - capsule.maxY - gap)
    let opensBelow: Bool
    if let prefersBelow {
      let preferredSpace = prefersBelow ? below : above
      let otherSpace = prefersBelow ? above : below
      if preferredSpace >= pageSize.height {
        opensBelow = prefersBelow
      } else if otherSpace >= pageSize.height || otherSpace > preferredSpace + sideSwitchHysteresis {
        opensBelow = !prefersBelow
      } else {
        opensBelow = prefersBelow
      }
    } else {
      opensBelow = below >= pageSize.height || below >= above
    }
    let size = NSSize(
      width: min(pageSize.width, bounds.width),
      height: min(pageSize.height, opensBelow ? below : above))
    return NSRect(
      x: clamp(capsule.midX - size.width / 2, bounds.minX, bounds.maxX - size.width),
      y: opensBelow ? capsule.minY - gap - size.height : capsule.maxY + gap,
      width: size.width, height: size.height)
  }

  static func movingFrames(
    _ delta: NSPoint, capsule: NSRect, page: NSRect?,
    in visibleFrame: NSRect
  ) -> (capsule: NSRect, page: NSRect?) {
    let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
    var movedCapsule = capsule
    movedCapsule.origin = NSPoint(
      x: clamp(capsule.minX + delta.x, bounds.minX, bounds.maxX - capsule.width),
      y: clamp(capsule.minY + delta.y, bounds.minY, bounds.maxY - capsule.height))
    let movedPage = page.map { page in
      pageFrame(beside: movedCapsule, in: visibleFrame, prefersBelow: page.maxY <= capsule.minY)
    }
    return (movedCapsule, movedPage)
  }

  static func contains(_ point: NSPoint, capsule: NSRect, page: NSRect?) -> Bool {
    if capsule.insetBy(dx: -6, dy: -6).contains(point) { return true }
    guard let page else { return false }
    if page.insetBy(dx: -6, dy: -6).contains(point) { return true }
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
