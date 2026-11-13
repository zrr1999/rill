import AppKit
import Testing

@testable import RillInputMethodKit

struct CandidateWindowPlacementTests {
  private let builtIn = CandidateWindowPlacement.Screen(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 92, width: 1512, height: 857))
  private let external = CandidateWindowPlacement.Screen(
    frame: CGRect(x: -157, y: 982, width: 1920, height: 1080),
    visibleFrame: CGRect(x: -157, y: 982, width: 1920, height: 1080))

  @Test @MainActor func nativePanelFollowsDisplaysAndDoesNotJumpWhenTheCaretIsMissing() throws {
    let application = NSApplication.shared
    let existing = Set(application.windows.map(\.windowNumber))
    let candidates = CandidateWindow()
    defer { candidates.hide() }
    let snapshot = RimeSession.Snapshot(
      preedit: "nihao", caretUTF16: 5,
      candidates: [.init(text: "你好", comment: ""), .init(text: "拟好", comment: "")], selected: 0)
    let screens = NSScreen.screens
    #expect(!screens.isEmpty)
    for screen in screens {
      let caret = NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 0, height: 22)
      candidates.show(snapshot, at: caret)
      let panel = try #require(application.windows.first { !existing.contains($0.windowNumber) && $0.isVisible })
      #expect(screen.visibleFrame.contains(panel.frame))
      let frame = panel.frame
      candidates.show(snapshot, at: .zero)
      #expect(panel.frame == frame)
      #expect(panel.isVisible)
      candidates.hide()
      candidates.show(snapshot, at: .zero)
      #expect(!panel.isVisible)
      var fallbackQueries = 0
      candidates.show(
        snapshot, at: .zero,
        fallbackCaret: {
          fallbackQueries += 1
          return NSRect(origin: caret.origin, size: .zero)
        })
      #expect(fallbackQueries == 1)
      #expect(panel.isVisible)
      #expect(screen.visibleFrame.contains(panel.frame))
      let fallbackFrame = panel.frame
      candidates.show(
        snapshot, at: .zero,
        fallbackCaret: {
          fallbackQueries += 1
          return .zero
        })
      #expect(fallbackQueries == 2)
      #expect(panel.frame == fallbackFrame)
      #expect(panel.isVisible)
      candidates.hide()
    }
  }

  @Test func pointOnlyCaretKeepsCandidatesOnItsDisplay() throws {
    var placement = CandidateWindowPlacement()
    let caret = CGRect(x: 600, y: 1300, width: 0, height: 0)
    let resolved = placement.resolve(caret, screens: [builtIn, external])
    let anchor = try #require(resolved)
    #expect(anchor.visibleFrame == external.visibleFrame)
    #expect(external.visibleFrame.contains(anchor.frame(for: CGSize(width: 300, height: 200))))
  }

  @Test func freshFallbackMovesThePanelBeforeUsingCachedCoordinates() throws {
    var placement = CandidateWindowPlacement()
    let initial = CGRect(x: 400, y: 400, width: 0, height: 22)
    let moved = CGRect(x: 600, y: 1300, width: 0, height: 22)
    let screens = [builtIn, external]
    var fallbackQueries = 0
    let primary = placement.resolve(
      initial, screens: screens,
      fallbackCaret: {
        fallbackQueries += 1
        return moved
      })
    #expect(primary?.visibleFrame == builtIn.visibleFrame)
    #expect(fallbackQueries == 0)
    let updated = placement.resolve(
      .zero, screens: screens,
      fallbackCaret: {
        fallbackQueries += 1
        return moved
      })
    let anchor = try #require(updated)
    #expect(fallbackQueries == 1)
    #expect(external.visibleFrame.contains(anchor.frame(for: CGSize(width: 300, height: 200))))
    let cached = placement.resolve(.zero, screens: screens, fallbackCaret: { .zero })
    #expect(cached?.caret == moved)
  }

  @Test func zeroWidthCaretUsesItsDisplay() throws {
    var placement = CandidateWindowPlacement()
    let resolved = placement.resolve(CGRect(x: 600, y: 1300, width: 0, height: 22), screens: [builtIn, external])
    let anchor = try #require(resolved)
    #expect(anchor.visibleFrame == external.visibleFrame)
  }

  @Test func caretStraddlingStackedDisplaysUsesItsCenter() throws {
    let caret = CGRect(x: 600, y: 980, width: 1, height: 22)
    #expect(builtIn.frame.intersects(caret))
    #expect(external.frame.intersects(caret))
    var placement = CandidateWindowPlacement()
    let resolved = placement.resolve(caret, screens: [builtIn, external])
    let anchor = try #require(resolved)
    #expect(anchor.visibleFrame == external.visibleFrame)
    #expect(external.visibleFrame.contains(anchor.frame(for: CGSize(width: 300, height: 200))))
  }

  @Test(arguments: [
    CGRect.zero, CGRect.null,
    CGRect(x: 600, y: 1300, width: -1, height: 22),
    CGRect(x: 600, y: 1300, width: 1, height: -22),
    CGRect(x: 9999, y: 9999, width: 1, height: 22),
  ])
  func missingCaretKeepsOnlyTheCurrentCompositionAnchor(_ missing: CGRect) throws {
    var placement = CandidateWindowPlacement()
    #expect(placement.resolve(missing, screens: [builtIn, external]) == nil)
    let caret = CGRect(x: 600, y: 1300, width: 0, height: 22)
    _ = placement.resolve(caret, screens: [builtIn, external])
    let resolved = placement.resolve(missing, screens: [builtIn, external])
    let anchor = try #require(resolved)
    #expect(anchor.caret == caret)
    #expect(anchor.visibleFrame == external.visibleFrame)
    placement.reset()
    #expect(placement.resolve(missing, screens: [builtIn, external]) == nil)
  }

  @Test func disconnectedDisplayDoesNotRedirectAnUnknownCaret() {
    var placement = CandidateWindowPlacement()
    _ = placement.resolve(CGRect(x: 600, y: 1300, width: 0, height: 22), screens: [builtIn, external])
    #expect(placement.resolve(.zero, screens: [builtIn]) == nil)
  }

  @Test func validCaretMovesToAnotherDisplayImmediately() throws {
    var placement = CandidateWindowPlacement()
    _ = placement.resolve(CGRect(x: 600, y: 1300, width: 0, height: 22), screens: [builtIn, external])
    let resolved = placement.resolve(CGRect(x: 400, y: 400, width: 0, height: 22), screens: [builtIn, external])
    let anchor = try #require(resolved)
    #expect(anchor.visibleFrame == builtIn.visibleFrame)
  }

  @Test func placementHandlesNegativeDisplayCoordinatesAndEdges() throws {
    let screen = CandidateWindowPlacement.Screen(
      frame: CGRect(x: -1920, y: -300, width: 1920, height: 1080),
      visibleFrame: CGRect(x: -1920, y: -270, width: 1920, height: 1020))
    let size = CGSize(width: 500, height: 220)
    for caret in [
      CGRect(x: -1910, y: -290, width: 0, height: 22),
      CGRect(x: -10, y: 740, width: 0, height: 22),
    ] {
      var placement = CandidateWindowPlacement()
      let resolved = placement.resolve(caret, screens: [builtIn, screen])
      let anchor = try #require(resolved)
      #expect(screen.visibleFrame.contains(anchor.frame(for: size)))
    }
  }
}
