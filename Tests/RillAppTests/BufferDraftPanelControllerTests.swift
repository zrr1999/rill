import AppKit
import XCTest
import RillDomainTestSupport
import RillTestSupport
import RillWorkflows

@testable import RillApp
@testable import RillCore
@testable import RillPlatform
@testable import RillRecords
@testable import RillUI

@MainActor
final class BufferDraftPanelControllerTests: XCTestCase {
  func testRestoredCollectionWaitsForSettingsAndOpensWithoutFocusOrTargetCapture() async throws {
    for voice in [false, true] {
      let settings: [AppSettingKey: String] = voice
        ? [.builtinPushToTalkOutputMode: BuiltinPushToTalkOutputMode.saveToVoiceGroup.rawValue]
        : [.systemClipboardCaptureEnabled: "true"]
      let (model, output) = makeHarness(RecordStore(), initialSettings: settings)
      let controller = BufferDraftPanelController(model: model, output: output,
        textOutput: .init(capture: { XCTFail("Background presentation must not capture an output target"); return nil }),
        editingActivity: { active in XCTAssertFalse(active) })
      defer { controller.shutdown() }
      let clipboardCount = NSPasteboard.general.changeCount
      let keyWindow = NSApp.keyWindow
      controller.start()
      XCTAssertFalse(controller.isVisible)

      try await waitUntil { controller.isVisible }
      XCTAssertFalse(controller.isKey)
      XCTAssertTrue(NSApp.keyWindow === keyWindow)
      XCTAssertTrue(model.recordWorkspace.buffers.editor.isVisible)
      XCTAssertEqual(NSPasteboard.general.changeCount, clipboardCount)
      await model.recordWorkspace.buffers.editor.shutdown()
      await output.shutdown()
    }
  }

  func testEachCollectionSwitchOpensAndKeepsTheEditingSelection() async throws {
    let store = RecordStore()
    let id = try await store.createBufferDraft(text: "Keep this draft")
    let (model, output) = makeHarness(store)
    let controller = BufferDraftPanelController(model: model, output: output, editingActivity: { _ in })
    defer { controller.shutdown() }
    controller.start()
    XCTAssertFalse(controller.isVisible)

    XCTAssertTrue(model.setBuiltinPushToTalkOutputMode(.saveToVoiceGroup))
    try await waitUntil { controller.isVisible }
    let editor = model.recordWorkspace.buffers.editor
    await editor.refresh()
    editor.select(id)
    await editor.waitForPendingWrites()
    let session = try XCTUnwrap(editor.session)
    session.selection = .init(location: 5, length: 4)
    controller.hide()
    XCTAssertFalse(controller.isVisible)

    XCTAssertTrue(model.setSystemClipboardCaptureEnabled(true))
    try await waitUntil { controller.isVisible }
    await editor.waitForPendingWrites()
    XCTAssertTrue(editor.session === session)
    XCTAssertEqual(session.selection, .init(location: 5, length: 4))
    XCTAssertEqual(session.text, "Keep this draft")
    XCTAssertFalse(controller.isKey)

    controller.shutdown()
    XCTAssertTrue(model.setSystemClipboardCaptureEnabled(false))
    XCTAssertTrue(model.setSystemClipboardCaptureEnabled(true))
    await editor.shutdown()
    await output.shutdown()
    XCTAssertFalse(controller.isVisible)
  }

  func testSendingKeepsPanelVisibleAndDoesNotRecaptureAChangedTarget() async throws {
    for changeTarget in [false, true] {
      let store = RecordStore()
      let id = try await store.createBufferDraft(text: "Review before sending")
      let element = BufferVerifiableTarget()
      var captureCount = 0
      let textOutput = RecordBufferTextOutput(capture: {
        captureCount += 1
        return .init(element: element, isCurrent: { true }, post: { _ in
          XCTFail("A readable text target must use verified replacement"); return false
        })
      }, modifiersHeld: { false }, isSecure: { false })
      let (model, output) = makeHarness(store, textOutput: textOutput)
      let controller = BufferDraftPanelController(model: model, output: output,
        textOutput: textOutput, editingActivity: { _ in })
      defer { controller.shutdown() }
      controller.show()
      let editor = model.recordWorkspace.buffers.editor
      await editor.refresh()
      editor.select(id)
      await editor.waitForPendingWrites()
      let capturesBeforeSend = captureCount
      XCTAssertGreaterThan(capturesBeforeSend, 0)
      if changeTarget {
        XCTAssertTrue(element.replaceText(in: .init(location: 0, length: 0), with: "external edit",
                                         selection: .init(location: 13, length: 0)))
      }
      let clipboardCount = NSPasteboard.general.changeCount

      editor.send()
      await editor.waitForPendingWrites()
      try await waitUntil { !model.recordWorkspace.buffers.isSending }

      XCTAssertTrue(controller.isVisible)
      XCTAssertTrue(editor.isVisible)
      XCTAssertFalse(controller.isKey)
      XCTAssertEqual(captureCount, capturesBeforeSend)
      let snapshot = try await store.bufferSnapshot()
      XCTAssertEqual(snapshot.remainingCount, changeTarget ? 1 : 0)
      XCTAssertEqual(element.value, changeTarget ? "external edit" : "Review before sending")
      XCTAssertEqual(NSPasteboard.general.changeCount, clipboardCount)
      if changeTarget {
        controller.show()
        await editor.waitForPendingWrites()
        XCTAssertGreaterThan(captureCount, capturesBeforeSend)
        do {
          _ = try await store.beginBufferOutput(manualEntryID: id)
          XCTFail("Returning to edit must protect the selected draft from direct output")
          try await store.retryBufferOutput(id)
        } catch let error as BufferOutputError {
          XCTAssertEqual(error, .editing)
        }
        editor.send()
        await editor.waitForPendingWrites()
        try await waitUntil { !model.recordWorkspace.buffers.isSending }
        XCTAssertEqual(element.value, "external editReview before sending")
        let settled = try await store.bufferSnapshot()
        XCTAssertEqual(settled.remainingCount, 0)
        XCTAssertTrue(controller.isVisible)
      }
      await editor.shutdown()
      await output.shutdown()
    }
  }

  private func makeHarness(_ store: RecordStore, initialSettings: [AppSettingKey: String]? = nil,
                           textOutput: RecordBufferTextOutput = .init(capture: { nil }))
    -> (AppModel, BufferOutputController) {
    let bus = EventBus()
    let resolver = CandidateResolver(eventBus: bus)
    let actions = OutputActionRegistry(actions: [])
    let coordinator = makeTestSessionCoordinator(
      recognizerRegistry: .init(recognizers: []), transformerRegistry: .init(transformers: []),
      actionRegistry: actions, candidateResolver: resolver, recordStore: store, eventBus: bus)
    let model = makeAppModelForTesting(
      workflows: [], eventBus: bus, sessionCoordinator: coordinator,
      outputActionRegistry: actions, recordWorkspace: .init(store: store), candidateResolver: resolver,
      settingsStore: DraftPanelSettingsStore(values: initialSettings ?? [:]),
      loadsPersistentSettingsOnInitialization: initialSettings != nil,
      writeClipboardTextAction: { _ in XCTFail("Draft collection must not write the clipboard") },
      deliverNextRecordAction: {}, permissionSnapshot: .init(accessibility: .granted, microphone: .granted),
      refreshPermissionsAction: {}, requestAccessibilityAction: {}, requestMicrophoneAction: {},
      openAccessibilitySettingsAction: {}, openMicrophoneSettingsAction: {},
      requestGlobalInputAction: {}, retryGlobalInputAction: {}, workflowLibraryChangedAction: {})
    model.settings.systemClipboardCaptureEnabled = false
    let output = BufferOutputController(store: store, model: model,
      injectionEngine: .init(pasteboard: .init(pasteboard: .withUniqueName()), accessibilityChecker: { true }),
      textOutput: textOutput, isRillFrontmost: { false })
    return (model, output)
  }

  private func waitUntil(_ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !ready() {
      if ContinuousClock.now >= deadline { XCTFail("The panel did not reach the expected state"); throw CancellationError() }
      await Task.yield()
    }
  }
}

private actor DraftPanelSettingsStore: SettingsStore {
  private var values: [AppSettingKey: String]
  init(values: [AppSettingKey: String]) { self.values = values }
  func string(forKey key: AppSettingKey) -> String? { values[key] }
  func setString(_ value: String, forKey key: AppSettingKey) { values[key] = value }
  func setStringsAtomically(_ values: [AppSettingKey: String]) {
    self.values.merge(values) { _, new in new }
  }
  func removeValue(forKey key: AppSettingKey) { values.removeValue(forKey: key) }
}
