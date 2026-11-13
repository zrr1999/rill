import CoreGraphics

struct CandidateWindowPlacement {
  struct Screen {
    let frame: CGRect
    let visibleFrame: CGRect
  }

  struct Anchor {
    let caret: CGRect
    let visibleFrame: CGRect

    func frame(for size: CGSize) -> CGRect {
      let x = min(
        max(caret.minX, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - size.width))
      let below = caret.minY - size.height - 4
      let preferredY = below >= visibleFrame.minY ? below : caret.maxY + 4
      let y = min(
        max(preferredY, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - size.height))
      return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
  }

  private var lastCaret: CGRect?

  mutating func resolve(
    _ caret: CGRect, screens: [Screen], fallbackCaret: (() -> CGRect)? = nil
  ) -> Anchor? {
    if let anchor = Self.anchor(for: caret, screens: screens)
      ?? fallbackCaret.flatMap({ Self.anchor(for: $0(), screens: screens) })
    {
      lastCaret = anchor.caret
      return anchor
    }
    guard let lastCaret else { return nil }
    return Self.anchor(for: lastCaret, screens: screens)
  }

  mutating func reset() { lastCaret = nil }

  private static func anchor(for caret: CGRect, screens: [Screen]) -> Anchor? {
    guard caret.origin.x.isFinite, caret.origin.y.isFinite,
      caret.size.width.isFinite, caret.size.height.isFinite,
      caret.size.width >= 0, caret.size.height >= 0, caret != .zero,
      let screen = screens.first(where: {
        $0.frame.contains(CGPoint(x: caret.midX, y: caret.midY))
      })
    else { return nil }
    return Anchor(caret: caret, visibleFrame: screen.visibleFrame)
  }
}
