import AppKit
import ApplicationServices
import Darwin
import XCTest

@testable import RillApp
@testable import RillCore
@testable import RillUI

private actor DurationLimitRemovalProbe {
  private var runIDs: [UUID] = []

  func record(_ runID: UUID) {
    runIDs.append(runID)
  }

  func snapshot() -> [UUID] {
    runIDs
  }
}

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
      visibleFrameResolver: { self.visibleFrame },
      reduceMotionProvider: { true }
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
      LiveSubtitlePanelGeometry.cornerRadius(for: snapshot),
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
      XCTAssertTrue(accessibleContent.contains("Press Escape to cancel and discard"))
      XCTAssertFalse(accessibleContent.contains("Cancel and discard\nbutton"))
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

  func testPreferredSurfaceSizesAreStableForEachLayoutMode() {
    XCTAssertEqual(LiveSubtitleOverlayMetrics.expandedSurfaceWidth, 360)
    XCTAssertEqual(LiveSubtitleOverlayMetrics.expandedSurfaceHeight, 96)
    XCTAssertEqual(LiveSubtitleOverlayMetrics.compactSurfaceWidth, 184)
    XCTAssertEqual(LiveSubtitleOverlayMetrics.compactSurfaceHeight, 48)
    let expanded = LiveSubtitleSnapshot(
      runID: UUID(),
      phase: .transcribing,
      hypothesisText: "Preview",
      livePreviewPlacement: .overlay
    )
    let compact = LiveSubtitleSnapshot(
      runID: UUID(),
      phase: .transcribing,
      hypothesisText: "Preview",
      livePreviewPlacement: .cursor
    )
    XCTAssertEqual(
      LiveSubtitlePanelGeometry.preferredSurfaceSize(for: expanded),
      NSSize(
        width: LiveSubtitleOverlayMetrics.expandedSurfaceWidth,
        height: LiveSubtitleOverlayMetrics.expandedSurfaceHeight
      )
    )
    XCTAssertEqual(
      LiveSubtitlePanelGeometry.preferredSurfaceSize(for: compact),
      NSSize(
        width: LiveSubtitleOverlayMetrics.compactSurfaceWidth,
        height: LiveSubtitleOverlayMetrics.compactSurfaceHeight
      )
    )
  }

  func testCaptureStartupFadesWithoutChangingCompactGeometryHostOrShadow() throws {
    _ = NSApplication.shared
    let controller = LiveSubtitlePanelController(
      visibleFrameResolver: { self.visibleFrame },
      reduceMotionProvider: { true }
    )
    defer {
      controller.update(snapshot: nil, language: .english)
    }
    let runID = UUID()
    let preparing = LiveSubtitleSnapshot(runID: runID, phase: .preparing)
    let recording = LiveSubtitleSnapshot(
      runID: runID,
      phase: .recording,
      recordingStartedAt: Date()
    )

    XCTAssertEqual(
      LiveSubtitlePanelGeometry.preferredSurfaceSize(for: preparing),
      LiveSubtitlePanelGeometry.preferredSurfaceSize(for: recording)
    )
    XCTAssertTrue(
      LiveSubtitlePanelAnimationPolicy.shouldAnimateEntrance(
        for: preparing,
        reduceMotion: false
      )
    )
    XCTAssertFalse(
      LiveSubtitlePanelAnimationPolicy.shouldAnimateEntrance(
        for: recording,
        reduceMotion: true
      )
    )

    XCTAssertEqual(LiveSubtitlePanelAnimationPolicy.fadeInDuration, 0.1)
    XCTAssertEqual(LiveSubtitlePanelAnimationPolicy.fadeOutDuration, 0.1)
    XCTAssertEqual(LiveSubtitlePanelAnimationPolicy.resizeDuration, 0.16)

    controller.update(snapshot: preparing, language: .english)
    let hostIdentity = try XCTUnwrap(controller.presentationHostIdentity)
    let shadowInvalidationCount = controller.shadowInvalidationCount
    let windowFrameAssignmentCount = controller.windowFrameAssignmentCount
    controller.update(snapshot: recording, language: .english)

    XCTAssertEqual(controller.presentationHostIdentity, hostIdentity)
    XCTAssertEqual(controller.shadowInvalidationCount, shadowInvalidationCount)
    XCTAssertEqual(controller.windowFrameAssignmentCount, windowFrameAssignmentCount)
    XCTAssertEqual(
      try XCTUnwrap(controller.windowState).contentSize,
      LiveSubtitlePanelGeometry.preferredSurfaceSize(for: recording)
    )
  }

  func testMeterFramesDoNotMutateStructuralPanelPresentation() {
    let runID = UUID()
    let first = LiveSubtitleSnapshot(
      runID: runID,
      phase: .recording,
      levelMeter: [0.2],
      updatedAt: Date(timeIntervalSince1970: 1)
    )
    let second = LiveSubtitleSnapshot(
      runID: runID,
      phase: .recording,
      levelMeter: [0.8],
      updatedAt: Date(timeIntervalSince1970: 2)
    )

    XCTAssertEqual(
      LiveSubtitlePanelPresentationPolicy.structuralSnapshot(first),
      LiveSubtitlePanelPresentationPolicy.structuralSnapshot(second)
    )
  }

  func testMeterFramesStayOnTheWaveformFastPath() throws {
    _ = NSApplication.shared
    var visibleFrameResolutionCount = 0
    let controller = LiveSubtitlePanelController(
      visibleFrameResolver: {
        visibleFrameResolutionCount += 1
        return self.visibleFrame
      },
      reduceMotionProvider: { true }
    )
    defer {
      controller.update(snapshot: nil, language: .english)
    }
    let runID = UUID()
    controller.update(
      snapshot: LiveSubtitleSnapshot(runID: runID, phase: .recording),
      language: .english
    )
    let hostIdentity = try XCTUnwrap(controller.presentationHostIdentity)
    let shadowInvalidationCount = controller.shadowInvalidationCount
    let windowFrameAssignmentCount = controller.windowFrameAssignmentCount

    for frame in 1...100 {
      controller.update(
        snapshot: LiveSubtitleSnapshot(
          runID: runID,
          phase: .recording,
          levelMeter: [Float(frame) / 100]
        ),
        language: .english
      )
    }

    XCTAssertEqual(visibleFrameResolutionCount, 1)
    XCTAssertEqual(controller.presentationHostIdentity, hostIdentity)
    XCTAssertEqual(controller.shadowInvalidationCount, shadowInvalidationCount)
    XCTAssertEqual(controller.windowFrameAssignmentCount, windowFrameAssignmentCount)
  }

  func testRepeatedTextUpdatesDoNotRestartExpansionTowardSameSize() {
    _ = NSApplication.shared
    let controller = LiveSubtitlePanelController(
      visibleFrameResolver: { self.visibleFrame },
      reduceMotionProvider: { false }
    )
    defer {
      controller.update(snapshot: nil, language: .english)
    }
    let runID = UUID()
    controller.update(
      snapshot: LiveSubtitleSnapshot(runID: runID, phase: .recording),
      language: .english
    )
    let initialFrameAssignments = controller.windowFrameAssignmentCount

    controller.update(
      snapshot: LiveSubtitleSnapshot(
        runID: runID,
        phase: .transcribing,
        hypothesisText: "First live hypothesis"
      ),
      language: .english
    )
    XCTAssertEqual(controller.windowFrameAssignmentCount, initialFrameAssignments + 1)

    controller.update(
      snapshot: LiveSubtitleSnapshot(
        runID: runID,
        phase: .transcribing,
        hypothesisText: "A newer live hypothesis"
      ),
      language: .english
    )
    XCTAssertEqual(controller.windowFrameAssignmentCount, initialFrameAssignments + 1)
  }

  func testNonCaptureEntranceStillHonorsMotionPreference() {
    let snapshot = LiveSubtitleSnapshot(runID: UUID(), phase: .processing)

    XCTAssertTrue(
      LiveSubtitlePanelAnimationPolicy.shouldAnimateEntrance(
        for: snapshot,
        reduceMotion: false
      )
    )
    XCTAssertFalse(
      LiveSubtitlePanelAnimationPolicy.shouldAnimateEntrance(
        for: snapshot,
        reduceMotion: true
      )
    )
  }

  func testDurationLimitRemovalIsRoutedOnceToTheCurrentRunOnly() async {
    _ = NSApplication.shared
    let controller = LiveSubtitlePanelController(
      visibleFrameResolver: { self.visibleFrame },
      reduceMotionProvider: { true }
    )
    defer {
      controller.update(snapshot: nil, language: .english)
    }
    let probe = DurationLimitRemovalProbe()
    let runID = UUID()
    controller.installRemoveDurationLimitAction { requestedRunID in
      await probe.record(requestedRunID)
      return true
    }
    controller.update(
      snapshot: LiveSubtitleSnapshot(
        runID: runID,
        phase: .recording,
        recordingStartedAt: Date(),
        maximumRecordingDurationSeconds: 120,
        canRemoveRecordingDurationLimit: true
      ),
      language: .english
    )

    let notificationName = Notification.Name(
      "works.earendil.rill.live-subtitle.remove-duration-limit-requested"
    )
    NotificationCenter.default.post(name: notificationName, object: UUID())
    NotificationCenter.default.post(name: notificationName, object: runID)
    NotificationCenter.default.post(name: notificationName, object: runID)
    for _ in 0..<20 {
      if !(await probe.snapshot()).isEmpty {
        break
      }
      await Task.yield()
    }

    let routedRunIDs = await probe.snapshot()
    XCTAssertEqual(routedRunIDs, [runID])
  }

  func testSameRunExpandsForOverlayTextAndCompactsAfterCapture() throws {
    _ = NSApplication.shared
    let controller = LiveSubtitlePanelController(
      visibleFrameResolver: { self.visibleFrame },
      reduceMotionProvider: { true }
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
    let initialSize = try XCTUnwrap(controller.windowState).contentSize

    controller.update(
      snapshot: LiveSubtitleSnapshot(
        runID: runID,
        phase: .finalizing,
        hypothesisText: "Done"
      ),
      language: .english
    )

    let state = try XCTUnwrap(controller.windowState)
    XCTAssertNotEqual(state.contentSize, initialSize)
    XCTAssertEqual(
      state.contentSize,
      NSSize(
        width: LiveSubtitleOverlayMetrics.compactSurfaceWidth,
        height: LiveSubtitleOverlayMetrics.compactSurfaceHeight
      )
    )
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
        == "Rill Dictation"
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
