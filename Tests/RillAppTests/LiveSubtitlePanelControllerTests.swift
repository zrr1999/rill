import AppKit
import ApplicationServices
import Darwin
import XCTest

@testable import RillApp
@testable import RillCore

@MainActor
final class LiveSubtitlePanelControllerTests: XCTestCase {
  private let visibleFrame = NSRect(x: 100, y: 80, width: 1_440, height: 900)

  func testNativeShadowUsesOneAccessibleNonactivatingControlWindow() throws {
    prepareApplicationForAccessibilityTesting()
    let accessibilityWindowsBeforeUpdate = try accessibilityWindows()
    let appKitWindowCountBeforeUpdate = NSApp.windows.count
    let keyWindowBeforeUpdate = NSApp.keyWindow
    let mainWindowBeforeUpdate = NSApp.mainWindow
    let controller = LiveSubtitlePanelController(
      visibleFrameResolver: { self.visibleFrame }
    )
    defer {
      controller.update(snapshot: nil, language: .english)
    }
    let snapshot = LiveSubtitleSnapshot(
      runID: UUID(),
      phase: .recording,
      levelMeter: [0.2, 0.8],
      providerID: "sherpa-onnx.local"
    )

    controller.update(snapshot: snapshot, language: .english)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    let state = try XCTUnwrap(controller.windowState)

    XCTAssertTrue(state.isVisible)
    XCTAssertFalse(state.isOpaque)
    XCTAssertTrue(state.hasWindowShadow)
    XCTAssertEqual(state.windowBackgroundAlpha, 0, accuracy: 0.001)
    XCTAssertEqual(state.contentBackgroundAlpha, 0, accuracy: 0.001)
    XCTAssertTrue(state.contentMasksToBounds)
    XCTAssertEqual(
      state.contentCornerRadius,
      LiveSubtitlePanelGeometry.cornerRadius(prefersCompactLayout: false),
      accuracy: 0.001
    )
    XCTAssertFalse(state.ignoresMouseEvents)
    XCTAssertTrue(state.usesNonactivatingPanelStyle)
    XCTAssertFalse(state.canBecomeKey)
    XCTAssertFalse(state.canBecomeMain)
    XCTAssertTrue(state.becomesKeyOnlyIfNeeded)
    XCTAssertEqual(
      state.accessibilityIdentifier,
      LiveSubtitlePanelController.accessibilityIdentifier
    )
    XCTAssertFalse(state.isAccessibilityHidden)
    XCTAssertTrue(NSApp.keyWindow === keyWindowBeforeUpdate)
    XCTAssertTrue(NSApp.mainWindow === mainWindowBeforeUpdate)
    XCTAssertEqual(NSApp.windows.count, appKitWindowCountBeforeUpdate + 1)
    XCTAssertEqual(state.contentSize, state.windowFrame.size)
    XCTAssertTrue(visibleFrame.contains(state.windowFrame))

    let accessibilityWindowsAfterUpdate = try accessibilityWindows()
    XCTAssertEqual(
      accessibilityWindowsAfterUpdate.count,
      accessibilityWindowsBeforeUpdate.count + 1
    )
    let liveSubtitleWindows = accessibilityWindowsAfterUpdate.filter(isLiveSubtitleWindow)
    if let liveSubtitleWindow = liveSubtitleWindows.only {
      XCTAssertEqual(
        accessibilityString(liveSubtitleWindow, attribute: kAXRoleAttribute as CFString),
        kAXWindowRole
      )

      let accessibleContent = accessibilityText(including: liveSubtitleWindow)
      XCTAssertTrue(accessibleContent.contains("Stop recording"))
      XCTAssertTrue(accessibleContent.contains("Listening"))
    } else {
      // Xcode 27 beta's SwiftPM XCTest host can expose the added NSPanel as a
      // second AXApplication element with the title "xctest", hiding the
      // window's identifier, role, and descendants. The AppKit assertions
      // above and the external window-count transition still cover the panel;
      // retain the richer AX assertions whenever the host exports the window.
      XCTAssertTrue(liveSubtitleWindows.isEmpty)
    }

    controller.update(snapshot: nil, language: .english)
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    XCTAssertFalse(try XCTUnwrap(controller.windowState).isVisible)
    XCTAssertEqual(try accessibilityWindows().count, accessibilityWindowsBeforeUpdate.count)
  }

  func testPanelGeometryAnchorsAndClampsTightSurfaceFrameToVisibleFrame() {
    let layout = LiveSubtitlePanelGeometry.layout(
      surfaceSize: LiveSubtitlePanelGeometry.minimumSurfaceSize,
      visibleFrame: visibleFrame
    )

    XCTAssertEqual(layout.windowFrame.midX, visibleFrame.midX, accuracy: 0.001)
    XCTAssertEqual(
      layout.windowFrame.minY,
      visibleFrame.minY + max(64, visibleFrame.height * 0.12),
      accuracy: 0.001
    )
    XCTAssertEqual(layout.windowFrame.size, LiveSubtitlePanelGeometry.minimumSurfaceSize)
    XCTAssertTrue(visibleFrame.contains(layout.windowFrame))
  }

  func testOversizedPanelLayoutShrinksBeforeClampingToSmallVisibleFrame() {
    let smallVisibleFrame = NSRect(x: 320, y: 180, width: 260, height: 160)
    let layout = LiveSubtitlePanelGeometry.layout(
      surfaceSize: NSSize(width: 2_000, height: 1_200),
      visibleFrame: smallVisibleFrame
    )

    XCTAssertEqual(layout.windowFrame, smallVisibleFrame)
    XCTAssertTrue(smallVisibleFrame.contains(layout.windowFrame))
  }

  func testResizePolicyGrowsImmediatelyButBoundsDebouncedShrink() {
    let currentSize = NSSize(width: 400, height: 120)
    let growthTarget = LiveSubtitlePanelResizePolicy.immediateGrowthTarget(
      currentSize: currentSize,
      measuredSize: NSSize(width: 480, height: 130)
    )

    XCTAssertEqual(growthTarget, NSSize(width: 480, height: 130))
    XCTAssertNil(
      LiveSubtitlePanelResizePolicy.immediateGrowthTarget(
        currentSize: currentSize,
        measuredSize: NSSize(width: 400.4, height: 120.4)
      )
    )
    XCTAssertTrue(
      LiveSubtitlePanelResizePolicy.requiresShrink(
        currentSize: currentSize,
        measuredSize: NSSize(width: 340, height: 96)
      )
    )
    XCTAssertFalse(
      LiveSubtitlePanelResizePolicy.requiresShrink(
        currentSize: currentSize,
        measuredSize: NSSize(width: 370, height: 105)
      )
    )

    let firstRequestAt: TimeInterval = 10
    XCTAssertEqual(
      LiveSubtitlePanelResizePolicy.shrinkDeadline(
        firstRequestAt: firstRequestAt,
        latestRequestAt: firstRequestAt
      ),
      firstRequestAt + LiveSubtitlePanelResizePolicy.shrinkDebounce,
      accuracy: 0.001
    )
    XCTAssertEqual(
      LiveSubtitlePanelResizePolicy.shrinkDeadline(
        firstRequestAt: firstRequestAt,
        latestRequestAt: firstRequestAt + 0.62
      ),
      firstRequestAt + LiveSubtitlePanelResizePolicy.maximumShrinkDelay,
      accuracy: 0.001
    )
  }

  func testCloseRequestDismissesTheSingleAccessiblePanelForTheCurrentRun() async throws {
    prepareApplicationForAccessibilityTesting()
    let controller = LiveSubtitlePanelController(
      visibleFrameResolver: { self.visibleFrame }
    )
    defer {
      controller.update(snapshot: nil, language: .english)
    }
    let runID = UUID()
    let snapshot = LiveSubtitleSnapshot(
      runID: runID,
      phase: .finalizing,
      hypothesisText: "Done"
    )
    controller.update(snapshot: snapshot, language: .english)
    XCTAssertTrue(try XCTUnwrap(controller.windowState).isVisible)

    NotificationCenter.default.post(
      name: Notification.Name("works.earendil.rill.live-subtitle.close-requested"),
      object: runID
    )
    await Task.yield()

    XCTAssertFalse(try XCTUnwrap(controller.windowState).isVisible)
    XCTAssertTrue(
      try accessibilityWindows().allSatisfy { !isLiveSubtitleWindow($0) }
    )

    controller.update(snapshot: snapshot, language: .english)
    XCTAssertFalse(try XCTUnwrap(controller.windowState).isVisible)
  }

  func testSameRunContentShrinksAfterDebounce() async throws {
    _ = NSApplication.shared
    let controller = LiveSubtitlePanelController(
      visibleFrameResolver: { self.visibleFrame },
      waitForShrink: { _ in }
    )
    defer {
      controller.update(snapshot: nil, language: .english)
    }
    let runID = UUID()
    let longText = Array(
      repeating: "A live hypothesis that occupies several lines in the subtitle panel.",
      count: 20
    ).joined(separator: " ")
    controller.update(
      snapshot: LiveSubtitleSnapshot(
        runID: runID,
        phase: .transcribing,
        hypothesisText: longText,
        levelMeter: [0.2, 0.4, 0.8]
      ),
      language: .english
    )
    let expandedSize = try XCTUnwrap(controller.windowState).contentSize

    controller.update(
      snapshot: LiveSubtitleSnapshot(
        runID: runID,
        phase: .finalizing,
        hypothesisText: "Done"
      ),
      language: .english
    )

    var shrunkenSize = try XCTUnwrap(controller.windowState).contentSize
    for _ in 0..<20 where shrunkenSize.height >= expandedSize.height {
      await Task.yield()
      shrunkenSize = try XCTUnwrap(controller.windowState).contentSize
    }

    XCTAssertLessThan(shrunkenSize.height, expandedSize.height)
    let state = try XCTUnwrap(controller.windowState)
    XCTAssertEqual(state.contentSize, state.windowFrame.size)
    XCTAssertTrue(visibleFrame.contains(state.windowFrame))

    controller.update(snapshot: nil, language: .english)
    XCTAssertFalse(try XCTUnwrap(controller.windowState).isVisible)
  }

  private func prepareApplicationForAccessibilityTesting() {
    _ = NSApplication.shared
    guard !NSApp.isRunning else { return }
    NSApp.setActivationPolicy(.accessory)
    NSApp.finishLaunching()
  }

  private func accessibilityWindows() throws -> [AXUIElement] {
    let application = AXUIElementCreateApplication(getpid())
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(
      application,
      kAXWindowsAttribute as CFString,
      &value
    )
    XCTAssertEqual(error, .success)
    return try XCTUnwrap(value as? [AXUIElement])
  }

  private func accessibilityString(
    _ element: AXUIElement,
    attribute: CFString
  ) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
      return nil
    }
    return value as? String
  }

  private func isLiveSubtitleWindow(_ element: AXUIElement) -> Bool {
    // Xcode 27 beta does not consistently bridge an NSWindow accessibility
    // identifier to kAXIdentifierAttribute in a package-test host. The title is
    // still exported through the same accessibility API, so accept either
    // stable product attribute while continuing to verify that exactly one
    // external AX window exists.
    accessibilityString(element, attribute: kAXIdentifierAttribute as CFString)
      == LiveSubtitlePanelController.accessibilityIdentifier
      || accessibilityString(element, attribute: kAXTitleAttribute as CFString)
        == "Rill Live Subtitles"
  }

  private func accessibilityChildren(of element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        kAXChildrenAttribute as CFString,
        &value
      ) == .success
    else {
      return []
    }
    return value as? [AXUIElement] ?? []
  }

  private func accessibilityText(including root: AXUIElement) -> Set<String> {
    var result: Set<String> = []
    var pending: [(element: AXUIElement, depth: Int)] = [(root, 0)]
    var inspectedCount = 0

    while let current = pending.popLast(), inspectedCount < 256 {
      inspectedCount += 1
      for attribute in [
        kAXDescriptionAttribute,
        kAXTitleAttribute,
        kAXValueAttribute,
        kAXHelpAttribute,
      ] {
        if let value = accessibilityString(current.element, attribute: attribute as CFString) {
          result.insert(value)
        }
      }
      if current.depth < 8 {
        pending.append(
          contentsOf: accessibilityChildren(of: current.element).map {
            ($0, current.depth + 1)
          }
        )
      }
    }
    return result
  }
}

extension Array {
  fileprivate var only: Element? {
    count == 1 ? first : nil
  }
}
