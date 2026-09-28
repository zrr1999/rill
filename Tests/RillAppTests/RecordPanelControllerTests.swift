@testable import RillWorkflows
import RillDomainTestSupport
import RillTestSupport
import AppKit
import XCTest

@testable import RillApp
@testable import RillCore
@testable import RillUI

private struct RecordPanelReduceMotionTestContextProvider: ContextProvider {
  func captureContext() async -> ContextSnapshot { .empty }
}

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

  func testFocusLossDuringPresentationEventuallyDismissesPanel() async throws {
    let otherWindow = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    defer { otherWindow.orderOut(nil) }
    let controller = makeController(reduceMotion: true)
    controller.show(model: makeModel(), deliverSelection: { _, _ in .delivered }, onDeliveryAbort: {})
    otherWindow.makeKeyAndOrderFront(nil)
    XCTAssertTrue(otherWindow.isKeyWindow)
    XCTAssertTrue(controller.isVisible)

    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while controller.isVisible, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(controller.isVisible, "A panel that lost keyboard focus must not remain over the typing target")
    await controller.shutdown()
  }

  func testRegainingFocusCancelsPendingDismissal() async throws {
    let otherWindow = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    defer { otherWindow.orderOut(nil) }
    let controller = makeController(reduceMotion: true)
    let existingWindowNumbers = Set(NSApplication.shared.windows.map(\.windowNumber))
    controller.show(model: makeModel(), deliverSelection: { _, _ in .delivered }, onDeliveryAbort: {})
    let panel = try XCTUnwrap(NSApp.windows.first {
      $0 is NSPanel && $0.isVisible && !existingWindowNumbers.contains($0.windowNumber)
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

  func testAnimatedDismissKeepsPanelVisibleUntilFadeCompletes() async throws {
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
