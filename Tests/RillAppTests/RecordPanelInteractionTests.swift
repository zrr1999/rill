import AppKit
import Testing
@testable import RillApp
@testable import RillUI

@Suite @MainActor
struct RecordPanelInteractionTests {
  @Test func shortPressRestartsHoverWithoutExpandingOrDragging() async throws {
    let harness = HoverHarness()
    defer { harness.controller.stop() }
    var actions = harness.actions.makeAsyncIterator()
    var dragActivity: [Bool] = []
    var explicitOpenCount = 0
    let handle = CapsuleDragHandle.Handle()
    handle.onExpand = { explicitOpenCount += 1 }
    handle.onDragActivity = {
      dragActivity.append($0)
      harness.controller.setDragging($0)
    }
    handle.onDrag = { _ in Issue.record("A short press must not move the capsule") }

    harness.controller.pointerMoved(to: harness.handlePoint)
    await harness.clock.waitForPendingCount(1)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = try #require(
        NSEvent.mouseEvent(
          with: type, location: harness.handlePoint, modifierFlags: [], timestamp: 0,
          windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
      harness.controller.buttonChanged(0, isDown: type == .leftMouseDown)
      if type == .leftMouseDown {
        handle.mouseDown(with: event)
        await harness.clock.waitForPendingCount(0)
      } else {
        handle.mouseUp(with: event)
      }
    }
    #expect(explicitOpenCount == 0)
    try #require(dragActivity.isEmpty)
    #expect(harness.frames.page == nil)
    await harness.clock.waitForPendingCount(1)
    #expect(harness.clock.lastDelay == .milliseconds(120))
    harness.clock.advance()
    #expect(await actions.next() == .expanded)
  }

  @Test func hoverOpensAfterItsDelayWithoutAButtonPress() async {
    let harness = HoverHarness()
    var actions = harness.actions.makeAsyncIterator()
    harness.controller.pointerMoved(to: harness.handlePoint)
    await harness.clock.waitForPendingCount(1)
    #expect(harness.clock.lastDelay == .milliseconds(120))
    #expect(harness.frames.page == nil)
    harness.clock.advance()
    #expect(await actions.next() == .expanded)
    #expect(harness.frames.page != nil)
    harness.controller.stop()
  }

  @Test func crossingTheGapOrReturningCancelsCollapse() async {
    let harness = HoverHarness(expanded: true)
    harness.controller.pointerMoved(to: .zero)
    await harness.clock.waitForPendingCount(1)
    #expect(harness.clock.lastDelay == .milliseconds(220))
    let page = harness.frames.page!
    harness.controller.pointerMoved(
      to: NSPoint(
        x: harness.frames.capsule.midX,
        y: (page.maxY + harness.frames.capsule.minY) / 2))
    await harness.clock.waitForPendingCount(0)
    #expect(harness.collapseCount == 0)
    harness.controller.pointerMoved(to: NSPoint(x: page.midX, y: page.midY))
    #expect(harness.clock.pendingCount == 0)
    harness.controller.stop()
  }

  @Test func passingOverTheCapsuleDoesNotOpenItLater() async {
    let harness = HoverHarness()
    defer { harness.controller.stop() }
    harness.controller.pointerMoved(to: harness.handlePoint)
    await harness.clock.waitForPendingCount(1)
    harness.controller.pointerMoved(to: .zero)
    await harness.clock.waitForPendingCount(0)
    harness.clock.advance()
    #expect(harness.frames.page == nil)
  }

  @Test func smallBoundaryJitterAndReturningCancelTheExitDeadline() async {
    let harness = HoverHarness(expanded: true)
    defer { harness.controller.stop() }
    var actions = harness.actions.makeAsyncIterator()
    let page = harness.frames.page!
    harness.controller.pointerMoved(to: NSPoint(x: page.maxX + 4, y: page.midY))
    #expect(harness.clock.pendingCount == 0)
    harness.controller.pointerMoved(to: NSPoint(x: page.maxX + 12, y: page.midY))
    await harness.clock.waitForPendingCount(1)
    harness.controller.pointerMoved(to: NSPoint(x: page.midX, y: page.midY))
    await harness.clock.waitForPendingCount(0)
    harness.clock.advance()
    #expect(harness.collapseCount == 0)
    harness.controller.pointerMoved(to: .zero)
    await harness.clock.waitForPendingCount(1)
    #expect(harness.clock.lastDelay == .milliseconds(220))
    harness.clock.advance()
    #expect(await actions.next() == .collapsed)
    #expect(harness.collapseCount == 1)
  }

  @Test func pressingAndEditingHoldThePageUntilReleased() async {
    let harness = HoverHarness(expanded: true)
    var actions = harness.actions.makeAsyncIterator()
    harness.controller.buttonChanged(0, isDown: true)
    harness.controller.pointerMoved(to: .zero)
    #expect(harness.clock.pendingCount == 0)
    harness.controller.buttonChanged(0, isDown: false)
    await harness.clock.waitForPendingCount(1)
    harness.allowsCollapse = false
    harness.controller.refresh()
    await harness.clock.waitForPendingCount(0)
    #expect(harness.collapseCount == 0)
    harness.allowsCollapse = true
    harness.controller.refresh()
    await harness.clock.waitForPendingCount(1)
    harness.clock.advance()
    #expect(await actions.next() == .collapsed)
    #expect(harness.collapseCount == 1)
    harness.controller.stop()
  }

  @Test func draggingCancelsOpeningAndRequiresANewHover() async {
    let harness = HoverHarness()
    var actions = harness.actions.makeAsyncIterator()
    harness.controller.pointerMoved(to: harness.handlePoint)
    await harness.clock.waitForPendingCount(1)
    harness.controller.setDragging(true)
    await harness.clock.waitForPendingCount(0)
    harness.controller.setDragging(false)
    harness.controller.pointerMoved(to: harness.handlePoint)
    #expect(harness.clock.pendingCount == 0)
    harness.controller.pointerMoved(to: .zero)
    harness.controller.pointerMoved(to: harness.handlePoint)
    await harness.clock.waitForPendingCount(1)
    harness.clock.advance()
    #expect(await actions.next() == .expanded)
    harness.controller.stop()
  }

  @Test func closeTargetAndShutdownDoNotOpenThePage() async {
    let harness = HoverHarness()
    harness.controller.pointerMoved(
      to: NSPoint(
        x: harness.frames.capsule.maxX - 12,
        y: harness.frames.capsule.midY))
    #expect(harness.clock.pendingCount == 0)
    harness.controller.pointerMoved(to: harness.handlePoint)
    await harness.clock.waitForPendingCount(1)
    harness.controller.stop()
    await harness.clock.waitForPendingCount(0)
    #expect(harness.frames.page == nil)
  }

  @Test func endingADragOutsideAllowsTheNextHover() async {
    let harness = HoverHarness()
    var actions = harness.actions.makeAsyncIterator()
    harness.controller.pointerMoved(to: harness.handlePoint)
    harness.controller.setDragging(true)
    harness.controller.pointerMoved(to: .zero)
    harness.controller.setDragging(false)
    harness.controller.pointerMoved(to: harness.handlePoint)
    await harness.clock.waitForPendingCount(1)
    harness.clock.advance()
    #expect(await actions.next() == .expanded)
    harness.controller.stop()
  }

  @Test(arguments: [
    NSRect(x: 0, y: 24, width: 1440, height: 850),
    NSRect(x: -1280, y: 70, width: 1280, height: 700),
    NSRect(x: 200, y: -900, width: 1024, height: 768),
  ])
  func placementKeepsCapsuleSeparateAndPageOnScreen(_ screen: NSRect) {
    for fraction in [0.0, 0.5, 1.0] {
      let capsule = NSRect(
        x: screen.minX + 12 + (screen.width - 284) * fraction,
        y: screen.minY + 12 + (screen.height - 72) * fraction, width: 260, height: 48)
      let page = RecordPanelPlacement.pageFrame(beside: capsule, in: screen)
      #expect(screen.contains(page))
      #expect(!page.intersects(capsule))
      #expect(page.height > 200)
      #expect(min(abs(page.maxY - capsule.minY), abs(page.minY - capsule.maxY)) == 14)
      #expect(
        RecordPanelPlacement.contains(
          NSPoint(x: capsule.midX, y: capsule.midY),
          capsule: capsule, page: page))
    }
  }

  @Test(arguments: [false, true])
  func draggingToTheOppositeVerticalEdgeFlipsThePageWithoutConstrainingTheCapsule(toTop: Bool) {
    let screen = NSRect(x: -1440, y: 0, width: 1440, height: 900)
    let bounds = screen.insetBy(dx: RecordPanelPlacement.margin, dy: RecordPanelPlacement.margin)
    let capsule = NSRect(x: -850, y: toTop ? bounds.minY : bounds.maxY - 48, width: 260, height: 48)
    let page = RecordPanelPlacement.pageFrame(beside: capsule, in: screen)
    let moved = RecordPanelPlacement.movingFrames(
      NSPoint(x: 2000, y: toTop ? 2000 : -2000),
      capsule: capsule, page: page, in: screen)
    let movedCapsule = moved.capsule
    let movedPage = moved.page!
    #expect(screen.contains(movedCapsule.union(movedPage)))
    #expect(movedCapsule.size == capsule.size)
    #expect(movedPage.size == page.size)
    #expect(movedCapsule.minY == (toTop ? bounds.maxY - capsule.height : bounds.minY))
    #expect(toTop ? movedPage.maxY == movedCapsule.minY - 14 : movedPage.minY == movedCapsule.maxY + 14)
    #expect(movedCapsule.maxX == screen.maxX - RecordPanelPlacement.margin)
    #expect(movedPage.maxX == movedCapsule.maxX)
  }

  @Test func crossingTheScreenMidpointKeepsThePageOnScreenWithoutSideJitter() {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let bounds = screen.insetBy(dx: RecordPanelPlacement.margin, dy: RecordPanelPlacement.margin)
    let capsule = NSRect(x: 590, y: bounds.minY, width: 260, height: 48)
    let page = RecordPanelPlacement.pageFrame(beside: capsule, in: screen)
    var placement = RecordPanelPlacement.movingFrames(
      NSPoint(x: 0, y: screen.midY - capsule.midY), capsule: capsule, page: page, in: screen)
    #expect(placement.page!.minY == placement.capsule.maxY + 14)
    #expect(placement.page!.height < RecordPanelPlacement.pageSize.height)

    for movement in [5.0, -10.0, 5.0] {
      placement = RecordPanelPlacement.movingFrames(
        NSPoint(x: 0, y: movement), capsule: placement.capsule, page: placement.page, in: screen)
      #expect(placement.page!.minY == placement.capsule.maxY + 14)
      #expect(bounds.contains(placement.page!))
    }
    placement = RecordPanelPlacement.movingFrames(
      NSPoint(x: 0, y: 20), capsule: placement.capsule, page: placement.page, in: screen)
    #expect(placement.page!.maxY == placement.capsule.minY - 14)
    placement = RecordPanelPlacement.movingFrames(
      NSPoint(x: 0, y: -25), capsule: placement.capsule, page: placement.page, in: screen)
    #expect(placement.page!.maxY == placement.capsule.minY - 14)
    #expect(bounds.contains(placement.page!))

    placement = RecordPanelPlacement.movingFrames(
      NSPoint(x: 0, y: 2000), capsule: placement.capsule, page: placement.page, in: screen)
    #expect(placement.capsule.maxY == bounds.maxY)
    #expect(placement.page!.size == RecordPanelPlacement.pageSize)
    #expect(placement.page!.maxY == placement.capsule.minY - 14)
    #expect(bounds.contains(placement.page!))
  }

  @Test(arguments: [false, true])
  func draggingIntoSpaceForEitherSideKeepsTheExistingSide(opensAbove: Bool) {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 1400)
    let capsule = NSRect(x: 590, y: opensAbove ? 12 : 1340, width: 260, height: 48)
    let page = RecordPanelPlacement.pageFrame(beside: capsule, in: screen)
    let moved = RecordPanelPlacement.movingFrames(
      NSPoint(x: 0, y: screen.midY - capsule.midY), capsule: capsule, page: page, in: screen)
    #expect(moved.page!.size == page.size)
    #expect(opensAbove ? moved.page!.minY == moved.capsule.maxY + 14 : moved.page!.maxY == moved.capsule.minY - 14)
  }

  @Test(
    arguments: [
      NSRect(x: 0, y: 24, width: 1440, height: 850),
      NSRect(x: -1280, y: 70, width: 1280, height: 700),
      NSRect(x: 200, y: -900, width: 1024, height: 768),
    ], [false, true])
  func capsuleReachesEitherEdgeWhileThePageRemainsReadable(_ screen: NSRect, opensAbove: Bool) {
    let bounds = screen.insetBy(dx: RecordPanelPlacement.margin, dy: RecordPanelPlacement.margin)
    let capsule = NSRect(
      x: screen.midX - 130, y: opensAbove ? bounds.minY : bounds.maxY - 48,
      width: 260, height: 48)
    let page = RecordPanelPlacement.pageFrame(beside: capsule, in: screen)
    for horizontalMovement in [-2000.0, 2000.0] {
      let moved = RecordPanelPlacement.movingFrames(
        NSPoint(x: horizontalMovement, y: 0), capsule: capsule, page: page, in: screen)
      let movedPage = moved.page!
      #expect(moved.capsule.minX == (horizontalMovement < 0 ? bounds.minX : bounds.maxX - capsule.width))
      #expect(bounds.contains(movedPage))
      #expect(movedPage.size == page.size)
      #expect(movedPage.minY == page.minY)
      #expect(!movedPage.intersects(moved.capsule))
      let gapPoint = NSPoint(
        x: moved.capsule.midX,
        y: opensAbove ? moved.capsule.maxY + 7 : moved.capsule.minY - 7)
      #expect(RecordPanelPlacement.contains(gapPoint, capsule: moved.capsule, page: movedPage))
      let returned = RecordPanelPlacement.movingFrames(
        NSPoint(x: capsule.minX - moved.capsule.minX, y: 0),
        capsule: moved.capsule, page: movedPage, in: screen)
      #expect(returned.capsule == capsule)
      #expect(returned.page == page)
    }
  }

  @Test func collapsedCapsuleUsesItsOwnScreenBounds() {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let moved = RecordPanelPlacement.movingFrames(
      NSPoint(x: 2000, y: -2000), capsule: NSRect(x: 500, y: 760, width: 260, height: 48),
      page: nil, in: screen)
    #expect(moved.page == nil)
    #expect(moved.capsule.maxX == screen.maxX - RecordPanelPlacement.margin)
    #expect(moved.capsule.minY == screen.minY + RecordPanelPlacement.margin)
  }
}

@MainActor
private final class HoverHarness {
  enum Action { case expanded, collapsed }
  let clock = PanelHoverClock()
  let actions: AsyncStream<Action>
  private let events: AsyncStream<Action>.Continuation
  var frames: RecordPanelHoverController.Frames
  var allowsCollapse = true
  var collapseCount = 0
  var handlePoint: NSPoint { NSPoint(x: frames.capsule.midX, y: frames.capsule.midY) }

  lazy var controller = RecordPanelHoverController(
    frames: { [weak self] in self?.frames },
    canCollapse: { [weak self] in self?.allowsCollapse == true },
    expand: { [weak self] in
      guard let self else { return }
      frames.page = RecordPanelPlacement.pageFrame(
        beside: frames.capsule,
        in: NSRect(x: 0, y: 0, width: 1440, height: 900))
      events.yield(.expanded)
    },
    collapse: { [weak self] in
      guard let self else { return }
      frames.page = nil
      collapseCount += 1
      events.yield(.collapsed)
    }, wait: { [clock] in try await clock.sleep(for: $0) }
  )

  init(expanded: Bool = false) {
    (actions, events) = AsyncStream.makeStream()
    let capsule = NSRect(x: 500, y: 760, width: 260, height: 48)
    frames = (
      capsule,
      expanded
        ? RecordPanelPlacement.pageFrame(
          beside: capsule,
          in: NSRect(x: 0, y: 0, width: 1440, height: 900)) : nil
    )
  }
}

@MainActor
private final class PanelHoverClock {
  private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
  private var cancelled: Set<UUID> = []
  private var observers: [CheckedContinuation<Void, Never>] = []
  private(set) var lastDelay: Duration?
  var pendingCount: Int { pending.count }

  func sleep(for duration: Duration) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled || cancelled.remove(id) != nil {
          continuation.resume(throwing: CancellationError())
        } else {
          lastDelay = duration
          pending[id] = continuation
        }
        notify()
      }
    } onCancel: {
      Task { @MainActor in self.cancel(id) }
    }
  }

  func waitForPendingCount(_ count: Int) async {
    while pending.count != count { await withCheckedContinuation { observers.append($0) } }
  }

  func advance() {
    let waiting = pending
    pending.removeAll()
    for continuation in waiting.values { continuation.resume() }
    notify()
  }

  private func cancel(_ id: UUID) {
    if let continuation = pending.removeValue(forKey: id) {
      continuation.resume(throwing: CancellationError())
    } else {
      cancelled.insert(id)
    }
    notify()
  }

  private func notify() {
    let waiting = observers
    observers.removeAll()
    for observer in waiting { observer.resume() }
  }
}
