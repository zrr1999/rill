import AppKit
import QuartzCore
import SwiftUI
import RillCore
import RillUI

struct LiveSubtitlePanelLayout: Equatable {
  let windowFrame: NSRect
}

enum LiveSubtitlePanelGeometry {
  static var minimumSurfaceSize: NSSize {
    NSSize(
      width: LiveSubtitleOverlayMetrics.minimumSurfaceWidth,
      height: LiveSubtitleOverlayMetrics.minimumSurfaceHeight
    )
  }

  static var maximumSurfaceWidth: CGFloat {
    LiveSubtitleOverlayMetrics.maximumSurfaceWidth
  }

  static func preferredSurfaceSize(for snapshot: LiveSubtitleSnapshot) -> NSSize {
    if !LiveSubtitlePresentationPolicy.usesExpandedLayout(snapshot) {
      return NSSize(
        width: LiveSubtitleOverlayMetrics.compactSurfaceWidth,
        height: LiveSubtitleOverlayMetrics.compactSurfaceHeight
      )
    }
    return NSSize(
      width: LiveSubtitleOverlayMetrics.standardSurfaceWidth,
      height: LiveSubtitleOverlayMetrics.standardSurfaceHeight
    )
  }

  static func cornerRadius(for snapshot: LiveSubtitleSnapshot?) -> CGFloat {
    guard let snapshot else { return LiveSubtitleOverlayMetrics.compactCornerRadius }
    return LiveSubtitlePresentationPolicy.usesExpandedLayout(snapshot)
      ? LiveSubtitleOverlayMetrics.standardCornerRadius
      : LiveSubtitleOverlayMetrics.compactCornerRadius
  }

  static func constrainedSurfaceSize(
    _ proposedSize: NSSize,
    visibleFrame: NSRect?
  ) -> NSSize {
    guard let visibleFrame else {
      return NSSize(
        width: min(
          max(proposedSize.width, minimumSurfaceSize.width),
          maximumSurfaceWidth
        ),
        height: max(proposedSize.height, minimumSurfaceSize.height)
      )
    }

    let availableWidth = max(visibleFrame.width, 0)
    let availableHeight = max(visibleFrame.height, 0)
    let minimumWidth = min(minimumSurfaceSize.width, availableWidth)
    let minimumHeight = min(minimumSurfaceSize.height, availableHeight)
    let maximumWidth = min(maximumSurfaceWidth, availableWidth)

    return NSSize(
      width: min(max(proposedSize.width, minimumWidth), maximumWidth),
      height: min(max(proposedSize.height, minimumHeight), availableHeight)
    )
  }

  static func layout(surfaceSize: NSSize, visibleFrame: NSRect) -> LiveSubtitlePanelLayout {
    let surfaceSize = constrainedSurfaceSize(surfaceSize, visibleFrame: visibleFrame)
    let proposedOrigin = NSPoint(
      x: visibleFrame.midX - surfaceSize.width / 2,
      y: visibleFrame.minY + max(64, visibleFrame.height * 0.12)
    )
    let origin = clampedOrigin(
      proposedOrigin,
      size: surfaceSize,
      visibleFrame: visibleFrame
    )
    return LiveSubtitlePanelLayout(
      windowFrame: NSRect(origin: origin, size: surfaceSize)
    )
  }

  private static func clampedOrigin(
    _ proposedOrigin: NSPoint,
    size: NSSize,
    visibleFrame: NSRect
  ) -> NSPoint {
    NSPoint(
      x: min(max(proposedOrigin.x, visibleFrame.minX), visibleFrame.maxX - size.width),
      y: min(max(proposedOrigin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
    )
  }
}

struct LiveSubtitlePanelWindowState: Equatable {
  let isVisible: Bool
  let isOpaque: Bool
  let hasWindowShadow: Bool
  let windowBackgroundAlpha: CGFloat
  let contentBackgroundAlpha: CGFloat
  let contentMasksToBounds: Bool
  let contentCornerRadius: CGFloat
  let contentSize: NSSize
  let windowFrame: NSRect
  let ignoresMouseEvents: Bool
  let usesNonactivatingPanelStyle: Bool
  let canBecomeKey: Bool
  let canBecomeMain: Bool
  let becomesKeyOnlyIfNeeded: Bool
  let accessibilityIdentifier: String
  let isAccessibilityHidden: Bool
  let windowNumber: Int
  let visibleFrame: NSRect?
}

@MainActor
final class LiveSubtitlePanelController {
  static let accessibilityIdentifier = "works.earendil.rill.live-subtitle"

  private static let closeRequestedNotification = Notification.Name(
    "works.earendil.rill.live-subtitle.close-requested"
  )
  private static let stopRequestedNotification = Notification.Name(
    "works.earendil.rill.live-subtitle.stop-requested"
  )
  private static let removeDurationLimitRequestedNotification = Notification.Name(
    "works.earendil.rill.live-subtitle.remove-duration-limit-requested"
  )

  private let visibleFrameResolver: @MainActor () -> NSRect?
  private let reduceMotionProvider: @MainActor () -> Bool

  private var panel: NSPanel?
  private var hostingController: NSHostingController<LiveSubtitleOverlay>?
  private var visibleRunID: UUID?
  private var dismissedRunID: UUID?
  private var currentVisibleFrame: NSRect?
  private var closeObserver: NotificationObserverToken?
  private var stopObserver: NotificationObserverToken?
  private var removeDurationLimitObserver: NotificationObserverToken?
  private var stopAction: (@Sendable (UUID) async -> Void)?
  private var removeDurationLimitAction: (@Sendable (UUID) async -> Bool)?
  private var stopRequestedRunID: UUID?
  private var durationLimitRemovalRequestedRunID: UUID?
  private var visibilityGeneration: UInt64 = 0

  init(
    visibleFrameResolver: @escaping @MainActor () -> NSRect? = {
      LiveSubtitlePanelController.systemVisibleFrame()
    },
    reduceMotionProvider: @escaping @MainActor () -> Bool = {
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
  ) {
    self.visibleFrameResolver = visibleFrameResolver
    self.reduceMotionProvider = reduceMotionProvider

    let observer = NotificationCenter.default.addObserver(
      forName: Self.closeRequestedNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let runID = notification.object as? UUID else { return }
      Task { @MainActor in
        self?.dismiss(runID: runID)
      }
    }
    closeObserver = NotificationObserverToken(observer)

    let stopObserver = NotificationCenter.default.addObserver(
      forName: Self.stopRequestedNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let runID = notification.object as? UUID else { return }
      Task { @MainActor in
        guard let self,
          self.visibleRunID == runID,
          self.stopRequestedRunID != runID,
          let stopAction = self.stopAction
        else {
          return
        }
        self.stopRequestedRunID = runID
        await stopAction(runID)
      }
    }
    self.stopObserver = NotificationObserverToken(stopObserver)

    let removeDurationLimitObserver = NotificationCenter.default.addObserver(
      forName: Self.removeDurationLimitRequestedNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let runID = notification.object as? UUID else { return }
      Task { @MainActor in
        guard let self,
          self.visibleRunID == runID,
          self.durationLimitRemovalRequestedRunID != runID,
          let removeDurationLimitAction = self.removeDurationLimitAction
        else {
          return
        }
        self.durationLimitRemovalRequestedRunID = runID
        let removed = await removeDurationLimitAction(runID)
        if !removed, self.visibleRunID == runID {
          self.durationLimitRemovalRequestedRunID = nil
        }
      }
    }
    self.removeDurationLimitObserver = NotificationObserverToken(removeDurationLimitObserver)
  }

  func installStopAction(_ action: @escaping @Sendable (UUID) async -> Void) {
    stopAction = action
  }

  func installRemoveDurationLimitAction(
    _ action: @escaping @Sendable (UUID) async -> Bool
  ) {
    removeDurationLimitAction = action
  }

  var windowState: LiveSubtitlePanelWindowState? {
    guard let panel else { return nil }
    let layer = panel.contentView?.layer
    return LiveSubtitlePanelWindowState(
      isVisible: panel.isVisible,
      isOpaque: panel.isOpaque,
      hasWindowShadow: panel.hasShadow,
      windowBackgroundAlpha: panel.backgroundColor.alphaComponent,
      contentBackgroundAlpha: layer?.backgroundColor?.alpha ?? 0,
      contentMasksToBounds: layer?.masksToBounds ?? false,
      contentCornerRadius: layer?.cornerRadius ?? 0,
      contentSize: panel.contentRect(forFrameRect: panel.frame).size,
      windowFrame: panel.frame,
      ignoresMouseEvents: panel.ignoresMouseEvents,
      usesNonactivatingPanelStyle: panel.styleMask.contains(.nonactivatingPanel),
      canBecomeKey: panel.canBecomeKey,
      canBecomeMain: panel.canBecomeMain,
      becomesKeyOnlyIfNeeded: panel.becomesKeyOnlyIfNeeded,
      accessibilityIdentifier: panel.accessibilityIdentifier(),
      isAccessibilityHidden: panel.isAccessibilityHidden(),
      windowNumber: panel.windowNumber,
      visibleFrame: currentVisibleFrame
    )
  }

  func update(snapshot: LiveSubtitleSnapshot?, language: AppLanguage) {
    guard let snapshot, snapshot.isVisible else {
      hidePanel(animated: true)
      visibleRunID = nil
      currentVisibleFrame = nil
      stopRequestedRunID = nil
      durationLimitRemovalRequestedRunID = nil
      return
    }

    if dismissedRunID == snapshot.runID {
      hidePanel(animated: false)
      visibleRunID = nil
      currentVisibleFrame = nil
      return
    }
    dismissedRunID = nil
    if stopRequestedRunID != snapshot.runID {
      stopRequestedRunID = nil
    }
    if durationLimitRemovalRequestedRunID != snapshot.runID
      || snapshot.canRemoveRecordingDurationLimit != true
    {
      durationLimitRemovalRequestedRunID = nil
    }

    let panel = panel ?? makePanel()
    let overlay = LiveSubtitleOverlay(
      snapshot: snapshot,
      language: language,
      includesShadow: false
    )
    let hostingController = hostingController ?? NSHostingController(rootView: overlay)
    hostingController.rootView = overlay
    configureHostingView(hostingController.view, snapshot: snapshot)
    configureAccessibility(of: panel, language: language)

    if self.hostingController == nil {
      self.hostingController = hostingController
      panel.contentViewController = hostingController
      configureHostingView(hostingController.view, snapshot: snapshot)
    }
    self.panel = panel

    let visibleFrame = visibleFrameResolver()
    currentVisibleFrame = visibleFrame
    let surfaceSize = LiveSubtitlePanelGeometry.constrainedSurfaceSize(
      LiveSubtitlePanelGeometry.preferredSurfaceSize(for: snapshot),
      visibleFrame: visibleFrame
    )
    let isNewRun = visibleRunID != snapshot.runID || !panel.isVisible

    if isNewRun {
      visibilityGeneration &+= 1
      panel.setContentSize(surfaceSize)
      position(panel, using: visibleFrame)
      panel.alphaValue = reduceMotionProvider() ? 1 : 0
      panel.orderFrontRegardless()
      if !reduceMotionProvider() {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.1
          context.timingFunction = CAMediaTimingFunction(name: .easeOut)
          panel.animator().alphaValue = 1
        }
      }
      panel.invalidateShadow()
      visibleRunID = snapshot.runID
      return
    }

    let currentSize = panel.contentRect(forFrameRect: panel.frame).size
    if currentSize != surfaceSize {
      if let visibleFrame {
        let targetFrame = LiveSubtitlePanelGeometry.layout(
          surfaceSize: surfaceSize,
          visibleFrame: visibleFrame
        ).windowFrame
        if reduceMotionProvider() {
          panel.setFrame(targetFrame, display: true)
        } else {
          NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(targetFrame, display: true)
          }
        }
      } else {
        panel.setContentSize(surfaceSize)
      }
    } else {
      position(panel, using: visibleFrame)
    }
    panel.invalidateShadow()
  }

  private func makePanel() -> NSPanel {
    let panel = OverlayPanel(
      contentRect: NSRect(origin: .zero, size: LiveSubtitlePanelGeometry.minimumSurfaceSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.ignoresMouseEvents = false
    panel.setAccessibilityIdentifier(Self.accessibilityIdentifier)
    if let contentView = panel.contentView {
      configureHostingView(contentView, snapshot: nil)
    }
    return panel
  }

  private func configureHostingView(_ view: NSView, snapshot: LiveSubtitleSnapshot?) {
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.clear.cgColor
    view.layer?.isOpaque = false
    view.layer?.masksToBounds = true
    view.layer?.cornerCurve = .continuous
    view.layer?.cornerRadius = LiveSubtitlePanelGeometry.cornerRadius(for: snapshot)
  }

  private func configureAccessibility(of panel: NSPanel, language: AppLanguage) {
    let title = language == .english ? "Rill Dictation" : "Rill 语音输入"
    panel.title = title
    panel.setAccessibilityLabel(title)
  }

  private func dismiss(runID: UUID) {
    dismissedRunID = runID
    visibleRunID = nil
    currentVisibleFrame = nil
    hidePanel(animated: false)
  }

  private func hidePanel(animated: Bool) {
    guard let panel, panel.isVisible else { return }
    visibilityGeneration &+= 1
    let generation = visibilityGeneration
    guard animated, !reduceMotionProvider() else {
      panel.alphaValue = 1
      panel.orderOut(nil)
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.1
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().alphaValue = 0
    } completionHandler: { [weak self, weak panel] in
      Task { @MainActor in
        guard let self, self.visibilityGeneration == generation else { return }
        panel?.orderOut(nil)
        panel?.alphaValue = 1
      }
    }
  }

  private func position(_ panel: NSPanel, using visibleFrame: NSRect?) {
    guard let visibleFrame else { return }
    let surfaceSize = panel.contentRect(forFrameRect: panel.frame).size
    let layout = LiveSubtitlePanelGeometry.layout(
      surfaceSize: surfaceSize,
      visibleFrame: visibleFrame
    )
    panel.setFrame(layout.windowFrame, display: false)
  }

  private static func systemVisibleFrame() -> NSRect? {
    let screen =
      NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
      ?? NSScreen.main
      ?? NSScreen.screens.first
    return screen?.visibleFrame
  }
}

private final class OverlayPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private final class NotificationObserverToken: @unchecked Sendable {
  private let observer: NSObjectProtocol

  init(_ observer: NSObjectProtocol) {
    self.observer = observer
  }

  deinit {
    NotificationCenter.default.removeObserver(observer)
  }
}
