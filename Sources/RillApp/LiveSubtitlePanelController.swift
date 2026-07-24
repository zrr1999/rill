import AppKit
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

  static func cornerRadius(prefersCompactLayout: Bool) -> CGFloat {
    prefersCompactLayout
      ? LiveSubtitleOverlayMetrics.compactCornerRadius
      : LiveSubtitleOverlayMetrics.standardCornerRadius
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

enum LiveSubtitlePanelResizePolicy {
  static let growthTolerance: CGFloat = 0.5
  static let widthThreshold: CGFloat = 48
  static let heightThreshold: CGFloat = 20
  static let shrinkDebounce: TimeInterval = 0.16
  static let maximumShrinkDelay: TimeInterval = 0.65

  static func immediateGrowthTarget(
    currentSize: NSSize,
    measuredSize: NSSize
  ) -> NSSize? {
    var target = currentSize
    if measuredSize.width - currentSize.width > growthTolerance {
      target.width = measuredSize.width
    }
    if measuredSize.height - currentSize.height > growthTolerance {
      target.height = measuredSize.height
    }
    return target == currentSize ? nil : target
  }

  static func requiresShrink(currentSize: NSSize, measuredSize: NSSize) -> Bool {
    currentSize.width - measuredSize.width >= widthThreshold
      || currentSize.height - measuredSize.height >= heightThreshold
  }

  static func shrinkDeadline(
    firstRequestAt: TimeInterval,
    latestRequestAt: TimeInterval
  ) -> TimeInterval {
    min(
      latestRequestAt + shrinkDebounce,
      firstRequestAt + maximumShrinkDelay
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

  private let visibleFrameResolver: @MainActor () -> NSRect?
  private let uptimeProvider: @MainActor () -> TimeInterval
  private let waitForShrink: @Sendable (Duration) async throws -> Void

  private var panel: NSPanel?
  private var hostingController: NSHostingController<LiveSubtitleOverlay>?
  private var visibleRunID: UUID?
  private var dismissedRunID: UUID?
  private var currentVisibleFrame: NSRect?
  private var closeObserver: NotificationObserverToken?
  private var stopObserver: NotificationObserverToken?
  private var stopAction: (@Sendable (UUID) async -> Void)?
  private var stopRequestedRunID: UUID?
  private var pendingShrinkTask: Task<Void, Never>?
  private var firstShrinkRequestAt: TimeInterval?

  init(
    visibleFrameResolver: @escaping @MainActor () -> NSRect? = {
      LiveSubtitlePanelController.systemVisibleFrame()
    },
    uptimeProvider: @escaping @MainActor () -> TimeInterval = {
      ProcessInfo.processInfo.systemUptime
    },
    waitForShrink: @escaping @Sendable (Duration) async throws -> Void = { duration in
      try await Task.sleep(for: duration)
    }
  ) {
    self.visibleFrameResolver = visibleFrameResolver
    self.uptimeProvider = uptimeProvider
    self.waitForShrink = waitForShrink

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
  }

  func installStopAction(_ action: @escaping @Sendable (UUID) async -> Void) {
    stopAction = action
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
      hidePanel()
      visibleRunID = nil
      currentVisibleFrame = nil
      stopRequestedRunID = nil
      cancelPendingShrink()
      return
    }

    if dismissedRunID == snapshot.runID {
      hidePanel()
      visibleRunID = nil
      currentVisibleFrame = nil
      cancelPendingShrink()
      return
    }
    dismissedRunID = nil
    if stopRequestedRunID != snapshot.runID {
      stopRequestedRunID = nil
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
    let measuredSize = measureSurface(
      for: hostingController,
      visibleFrame: visibleFrame
    )
    let isNewRun = visibleRunID != snapshot.runID || !panel.isVisible

    if isNewRun {
      cancelPendingShrink()
      panel.setContentSize(measuredSize)
      position(panel, using: visibleFrame)
      panel.orderFrontRegardless()
      panel.invalidateShadow()
      visibleRunID = snapshot.runID
      return
    }

    let currentSize = panel.contentRect(forFrameRect: panel.frame).size
    if let growthTarget = LiveSubtitlePanelResizePolicy.immediateGrowthTarget(
      currentSize: currentSize,
      measuredSize: measuredSize
    ) {
      panel.setContentSize(growthTarget)
    }

    let resizedSize = panel.contentRect(forFrameRect: panel.frame).size
    if LiveSubtitlePanelResizePolicy.requiresShrink(
      currentSize: resizedSize,
      measuredSize: measuredSize
    ) {
      scheduleShrink(for: snapshot.runID)
    } else {
      cancelPendingShrink()
    }
    position(panel, using: visibleFrame)
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
    view.layer?.cornerRadius = LiveSubtitlePanelGeometry.cornerRadius(
      prefersCompactLayout: snapshot?.prefersCompactLayout == true
    )
  }

  private func configureAccessibility(of panel: NSPanel, language: AppLanguage) {
    let title = language == .english ? "Rill Live Subtitles" : "Rill 实时字幕"
    panel.title = title
    panel.setAccessibilityLabel(title)
  }

  private func measureSurface(
    for hostingController: NSHostingController<LiveSubtitleOverlay>,
    visibleFrame: NSRect?
  ) -> NSSize {
    hostingController.view.needsLayout = true
    hostingController.view.layoutSubtreeIfNeeded()
    return LiveSubtitlePanelGeometry.constrainedSurfaceSize(
      hostingController.view.fittingSize,
      visibleFrame: visibleFrame
    )
  }

  private func scheduleShrink(for runID: UUID) {
    let now = uptimeProvider()
    let firstRequestAt = firstShrinkRequestAt ?? now
    firstShrinkRequestAt = firstRequestAt
    let deadline = LiveSubtitlePanelResizePolicy.shrinkDeadline(
      firstRequestAt: firstRequestAt,
      latestRequestAt: now
    )
    let delayMilliseconds = Int64(ceil(max(deadline - now, 0) * 1_000))
    let delay = Duration.milliseconds(delayMilliseconds)
    let waitForShrink = waitForShrink

    pendingShrinkTask?.cancel()
    pendingShrinkTask = Task { @MainActor [weak self] in
      do {
        try await waitForShrink(delay)
      } catch {
        return
      }
      guard !Task.isCancelled, let self else { return }
      self.pendingShrinkTask = nil
      self.firstShrinkRequestAt = nil
      self.applyScheduledShrink(for: runID)
    }
  }

  private func applyScheduledShrink(for runID: UUID) {
    guard
      visibleRunID == runID,
      panel?.isVisible == true,
      let panel,
      let hostingController
    else {
      return
    }

    let visibleFrame = visibleFrameResolver()
    currentVisibleFrame = visibleFrame
    let measuredSize = measureSurface(
      for: hostingController,
      visibleFrame: visibleFrame
    )
    let currentSize = panel.contentRect(forFrameRect: panel.frame).size
    guard
      LiveSubtitlePanelResizePolicy.requiresShrink(
        currentSize: currentSize,
        measuredSize: measuredSize
      )
    else {
      position(panel, using: visibleFrame)
      panel.invalidateShadow()
      return
    }

    panel.setContentSize(measuredSize)
    position(panel, using: visibleFrame)
    panel.invalidateShadow()
  }

  private func cancelPendingShrink() {
    pendingShrinkTask?.cancel()
    pendingShrinkTask = nil
    firstShrinkRequestAt = nil
  }

  private func dismiss(runID: UUID) {
    dismissedRunID = runID
    visibleRunID = nil
    currentVisibleFrame = nil
    cancelPendingShrink()
    hidePanel()
  }

  private func hidePanel() {
    panel?.orderOut(nil)
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
