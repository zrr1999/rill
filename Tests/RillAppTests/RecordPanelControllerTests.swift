import AppKit
import XCTest

@testable import RillApp
@testable import RillCore
@testable import RillRuntime
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
    let coordinator = SessionCoordinator(
      contextProvider: RecordPanelReduceMotionTestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: actionRegistry,
      candidateResolver: resolver,
      eventBus: eventBus
    )
    return AppModel(
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
