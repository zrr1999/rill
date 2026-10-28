@testable import RillWorkflows
import RillDomainTestSupport
import RillTestSupport
import AppKit
import XCTest

@testable import RillApp
@testable import RillCore
@testable import RillUI

@MainActor
final class RecordPanelControllerReduceMotionTests: XCTestCase {
  private func makeModel() -> AppModel {
    let eventBus = EventBus()
    let resolver = CandidateResolver(eventBus: eventBus)
    let actionRegistry = OutputActionRegistry(actions: [])
    let coordinator = makeTestSessionCoordinator(

      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: actionRegistry,
      candidateResolver: resolver,
      eventBus: eventBus
    )
    return makeAppModelForTesting(
      workflows: [],
      eventBus: eventBus,
      sessionCoordinator: coordinator,
      outputActionRegistry: actionRegistry,
      candidateResolver: resolver,
      loadsPersistentSettingsOnInitialization: false,
      writeClipboardTextAction: { _ in },
      deliverNextRecordAction: {},
      permissionSnapshot: PermissionSnapshot(accessibility: .granted, microphone: .granted),
      refreshPermissionsAction: {},
      requestAccessibilityAction: {},
      requestMicrophoneAction: {},
      openAccessibilitySettingsAction: {},
      openMicrophoneSettingsAction: {}, requestGlobalInputAction: {}, retryGlobalInputAction: {}, workflowLibraryChangedAction: {}
    )
  }

  private func makeController(
    reduceMotion: Bool
  ) -> RecordPanelController {
    RecordPanelController(
      pasteTargetProvider: { nil },
      pasteTargetRestorer: { _ in false },
      reduceMotionProvider: { reduceMotion }
    )
  }

  func testSettingsHidesPanelEvenWithoutAReturnCandidate() async {
    let controller = makeController(reduceMotion: true)
    let model = makeModel()
    controller.show(model: model, deliverSelection: { _, _ in .delivered }, onDeliveryAbort: {})
    XCTAssertTrue(controller.isVisible)
    controller.prepareForSettings(model: model) { _ in XCTFail("No candidate should resume") }
    XCTAssertFalse(controller.isVisible)
    XCTAssertNil(model.comparisonReturn)
    await controller.shutdown()
  }

  func testReusedPanelTitleFollowsInterfaceLanguage() async throws {
    let controller = makeController(reduceMotion: true)
    let model = makeModel()
    model.applyLanguage(.english)
    let existingWindows = Set(NSApplication.shared.windows.map(\.windowNumber))
    controller.show(
      model: model, deliverSelection: { _, _ in .blocked },
      onDeliveryAbort: {
        XCTFail("Window title changes must not abort record delivery")
      })
    let panel = try XCTUnwrap(
      NSApp.windows.first {
        $0.identifier?.rawValue == "record-panel.page" && !existingWindows.contains($0.windowNumber)
      })
    XCTAssertEqual(panel.title, "Clipboard")

    func waitForTitle(_ expected: String) async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while panel.title != expected, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
      }
      XCTAssertEqual(panel.title, expected)
    }

    controller.dismiss()
    model.applyLanguage(.simplifiedChinese)
    try await waitForTitle("剪贴板")
    controller.show(
      model: model, toggle: false, deliverSelection: { _, _ in .blocked },
      onDeliveryAbort: {
        XCTFail("Window title changes must not abort record delivery")
      })
    XCTAssertTrue(NSApp.windows.first { $0.identifier?.rawValue == "record-panel.page" && $0.isVisible } === panel)
    model.applyLanguage(.english)
    try await waitForTitle("Clipboard")
    await controller.shutdown()
  }

  func testDesktopFocusLossDuringPresentationDismissesThePanel() async throws {
    guard try await requireInteractiveDesktop() else { return }
    let otherWindow = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    defer { otherWindow.orderOut(nil) }
    let controller = makeController(reduceMotion: true)
    controller.show(model: makeModel(), deliverSelection: { _, _ in .delivered }, onDeliveryAbort: {})
    otherWindow.makeKeyAndOrderFront(nil)
    XCTAssertTrue(otherWindow.isKeyWindow)
    XCTAssertTrue(controller.isVisible)

    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while controller.isVisible, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(controller.isVisible, "Losing focus should leave no resident window")
    await controller.shutdown()
  }

  func testDesktopRegainingFocusCancelsPendingDismissal() async throws {
    guard try await requireInteractiveDesktop() else { return }
    let otherWindow = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    defer { otherWindow.orderOut(nil) }
    let controller = makeController(reduceMotion: true)
    let existingWindowNumbers = Set(NSApplication.shared.windows.map(\.windowNumber))
    controller.show(model: makeModel(), deliverSelection: { _, _ in .delivered }, onDeliveryAbort: {})
    let panel = try XCTUnwrap(
      NSApp.windows.first {
        $0.identifier?.rawValue == "record-panel.page" && $0.isVisible && !existingWindowNumbers.contains($0.windowNumber)
      })
    otherWindow.makeKeyAndOrderFront(nil)
    XCTAssertTrue(otherWindow.isKeyWindow)
    panel.makeKey()
    XCTAssertTrue(panel.isKeyWindow)

    // Cross the presentation suppression and focus-loss debounce deadlines.
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertTrue(controller.isVisible)
    XCTAssertTrue(panel.isKeyWindow)
    await controller.shutdown()
  }

  func testReduceMotionPresentsAndDismissesPanelWithoutFade() async {
    let controller = makeController(reduceMotion: true)

    controller.show(model: makeModel(), deliverSelection: { _, _ in .delivered }, onDeliveryAbort: {})
    XCTAssertTrue(controller.isVisible)

    controller.dismiss()
    XCTAssertFalse(controller.isVisible)
    await controller.shutdown()
  }

  func testEscapeDismissesThePanelWithoutAResidentWindow() async throws {
    let controller = makeController(reduceMotion: true)
    let existingWindowNumbers = Set(NSApplication.shared.windows.map(\.windowNumber))
    controller.show(model: makeModel(), deliverSelection: { _, _ in .delivered }, onDeliveryAbort: {})
    let panel = try XCTUnwrap(
      NSApp.windows.first {
        $0.identifier?.rawValue == "record-panel.page" && $0.isVisible && !existingWindowNumbers.contains($0.windowNumber)
      })
    let session = try XCTUnwrap(controller.quickPanelModel)
    if !session.isPreviewVisible { session.togglePreview() }
    panel.cancelOperation(nil)
    XCTAssertFalse(controller.isVisible)
    XCTAssertFalse(panel.isVisible)
    XCTAssertFalse(
      NSApp.windows.contains {
        $0.identifier?.rawValue == "record-panel.capsule" && $0.isVisible
      })
    await controller.shutdown()
  }

  func testShortcutTogglesBothModesAndReopensTheLastMode() async throws {
    let controller = makeController(reduceMotion: true)
    let model = makeModel()
    model.installRecordPanelAction {
      controller.show(model: model, deliverSelection: { _, _ in .delivered }, onDeliveryAbort: {})
    }
    model.showRecordPanel()
    XCTAssertEqual(controller.presentation.mode, .collections)
    for mode in RecordPanelPresentation.Mode.allCases {
      controller.selectMode(mode)
      model.showRecordPanel()
      XCTAssertFalse(controller.isVisible)
      model.showRecordPanel()
      XCTAssertTrue(controller.isVisible)
      XCTAssertEqual(controller.presentation.mode, mode)
    }
    await controller.shutdown()
  }

  func testDesktopAnimatedDismissKeepsPanelVisibleUntilFadeCompletes() async throws {
    guard try await requireInteractiveDesktop() else { return }
    let controller = makeController(reduceMotion: false)

    controller.show(model: makeModel(), deliverSelection: { _, _ in .delivered }, onDeliveryAbort: {})
    XCTAssertTrue(controller.isVisible)
    try await Task.sleep(for: .milliseconds(250))

    controller.dismiss()
    XCTAssertTrue(controller.isVisible)

    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while controller.isVisible, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertFalse(controller.isVisible)
    await controller.shutdown()
  }
  func testDismissDuringEntranceDoesNotWaitForANoopAnimation() async throws {
    let controller = makeController(reduceMotion: false)
    controller.show(model: makeModel(), deliverSelection: { _, _ in .delivered }, onDeliveryAbort: {})
    XCTAssertTrue(controller.isVisible)
    controller.dismiss()

    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while controller.isVisible, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertFalse(controller.isVisible)
    await controller.shutdown()
  }

}
