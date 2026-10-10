import AppKit
import XCTest
import RillDomainTestSupport
import RillTestSupport
import RillWorkflows

@testable import RillApp
@testable import RillCore
@testable import RillRecords
@testable import RillUI

@MainActor
final class RecordPanelComparisonReturnTests: XCTestCase {
  func testSettingsReturnPresentsRebuiltComparisonInTheMountedPanelWithoutSending() async throws {
    _ = NSApplication.shared
    // XCTest drives the run loop without NSApplication.run().
    if NSApp.activationPolicy() == .prohibited {
      NSApp.setActivationPolicy(.accessory)
      NSApp.finishLaunching()
    }
    let store = RecordStore()
    let record = try await store.ingest(
      .init(
        payload: .text("git worktree"),
        provenance: .init(
          source: .init(kind: .systemClipboard),
          sourceApplicationName: "Terminal", sourceBundleIdentifier: "example.allowed")), into: [])
    let provider = ComparisonReturnProvider()
    let service = RecordCloudRanking(
      store: store, provider: provider, privacy: .init(initialSettings: .defaults),
      currentFocus: {
        .init(
          applicationName: "Rill", bundleIdentifier: "example.rill", processIdentifier: 1,
          focusedRole: nil, selectedText: "", secureInput: false)
      })
    let workspace = RecordWorkspaceModel(store: store, cloudRanking: service)
    let eventBus = EventBus()
    let resolver = CandidateResolver(eventBus: eventBus)
    let actions = OutputActionRegistry(actions: [])
    let model = makeAppModelForTesting(
      workflows: [], eventBus: eventBus,
      sessionCoordinator: makeTestSessionCoordinator(
        recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
        transformerRegistry: TextTransformerRegistry(transformers: []), actionRegistry: actions,
        candidateResolver: resolver, eventBus: eventBus),
      outputActionRegistry: actions, recordWorkspace: workspace, candidateResolver: resolver,
      loadsPersistentSettingsOnInitialization: false,
      writeClipboardTextAction: { _ in }, deliverNextRecordAction: {},
      permissionSnapshot: .init(accessibility: .granted, microphone: .granted),
      refreshPermissionsAction: {}, requestAccessibilityAction: {}, requestMicrophoneAction: {},
      openAccessibilitySettingsAction: {}, openMicrophoneSettingsAction: {},
      requestGlobalInputAction: {}, retryGlobalInputAction: {}, workflowLibraryChangedAction: {})
    let controller = RecordPanelController(
      pasteTargetProvider: { nil }, pasteTargetRestorer: { _ in false },
      reduceMotionProvider: { true },
      pointerLocationProvider: { NSPoint(x: -100_000, y: -100_000) })
    addTeardownBlock {
      await controller.shutdown()
      await workspace.shutdown()
    }
    controller.show(model: model, deliverSelection: { _, _ in .blocked }, onDeliveryAbort: {})
    let page = try XCTUnwrap(
      NSApp.windows.first {
        $0.identifier?.rawValue == "record-panel.page" && $0.isVisible
      })
    addTeardownBlock { @MainActor in
      let sheet = page.attachedSheet
      controller.quickPanelModel?.jev?.invalidate()
      let deadline = ContinuousClock.now.advanced(by: .seconds(4))
      while page.attachedSheet != nil || sheet?.isVisible == true, ContinuousClock.now < deadline {
        await waitForMainRunLoopDefaultMode()
      }
      XCTAssertNil(page.attachedSheet)
      XCTAssertFalse(sheet?.isVisible == true)
    }
    let original = try XCTUnwrap(controller.quickPanelModel)
    original.setSearchText("git")
    original.setKind(.text)
    try await waitUntil { original.canCompareWithJev }
    original.select(record.id)
    original.compareWithJev()
    try await waitUntil { original.jev?.state == .review }
    let oldReview = try XCTUnwrap(original.jev?.review)
    controller.prepareForSettings(model: model) { context in
      controller.show(
        model: model, deliverSelection: { _, _ in .blocked }, onDeliveryAbort: {}, restoring: context)
    }
    XCTAssertFalse(controller.isVisible)
    XCTAssertNil(original.jev?.review)
    XCTAssertNotNil(model.comparisonReturn)
    workspace.jevSettings?.setKey("unit-test-key")
    model.resumeComparison()
    let restored = try XCTUnwrap(controller.quickPanelModel)
    XCTAssertFalse(restored === original)
    try await waitUntil { restored.jev?.state == .review }
    XCTAssertEqual(restored.selectedID, record.id)
    XCTAssertEqual(restored.searchText, "git")
    XCTAssertEqual(restored.kind, .text)
    XCTAssertNotEqual(restored.jev?.review?.id, oldReview.id)
    XCTAssertEqual(restored.jev?.review?.candidates.map(\.id), [record.id])
    try await waitUntil { page.attachedSheet?.isVisible == true }
    let sheet = try XCTUnwrap(page.attachedSheet)
    XCTAssertNotNil(sheet.contentView)
    let calls = await provider.calls
    XCTAssertEqual(calls, 0)
    controller.prepareForSettings(model: model) { context in
      controller.show(
        model: model, deliverSelection: { _, _ in .blocked }, onDeliveryAbort: {}, restoring: context)
    }
    try await waitUntil { !controller.isVisible && model.comparisonReturn != nil }
    XCTAssertNil(restored.jev?.review)
    model.resumeComparison()
    try await waitUntil { controller.quickPanelModel?.jev?.state == .review && page.attachedSheet?.isVisible == true }
    XCTAssertNotNil(page.attachedSheet?.contentView)
    XCTAssertEqual(controller.quickPanelModel?.selectedID, record.id)
    let callsAfterReturn = await provider.calls
    XCTAssertEqual(callsAfterReturn, 0)
  }

  private func waitUntil(
    file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !condition(), ContinuousClock.now < deadline { await waitForMainRunLoopDefaultMode() }
    XCTAssertTrue(condition(), file: file, line: line)
    if !condition() { throw ComparisonReturnTestError.timedOut }
  }

}

private enum ComparisonReturnTestError: Error { case timedOut }

private actor ComparisonReturnProvider: RecordRankingProvider {
  private(set) var calls = 0
  func score(query: String, candidates: [String], apiKey: String) async throws -> RecordRankingResponse {
    calls += 1
    return .init(scores: candidates.map { _ in 1 }, model: "test", inputTokens: 0, outputTokens: 0)
  }
}
