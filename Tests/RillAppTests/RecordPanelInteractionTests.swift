import AppKit
import Testing
@testable import RillApp

struct RecordPanelInteractionTests {
  @Test(arguments: [
    NSRect(x: 0, y: 24, width: 1440, height: 850),
    NSRect(x: -1280, y: 70, width: 1280, height: 700),
    NSRect(x: 200, y: -900, width: 1024, height: 768),
    NSRect(x: 0, y: 0, width: 640, height: 400),
  ])
  func panelOpensCenteredInsideTheCurrentScreen(_ screen: NSRect) {
    let page = RecordPanelPlacement.pageFrame(in: screen)
    #expect(screen.insetBy(dx: 12, dy: 12).contains(page))
    #expect(page.midX == screen.midX)
    #expect(page.midY == screen.midY)
    #expect(page.width == min(668, screen.width - 24))
    #expect(page.height == min(468, screen.height - 24))
  }
}
