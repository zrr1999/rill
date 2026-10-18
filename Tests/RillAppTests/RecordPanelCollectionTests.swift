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
final class RecordPanelCollectionTests: XCTestCase {
  func testRestoredCollectionSettingsDoNotPresentThePanelOrCaptureATarget() async throws {
    for voice in [false, true] {
      let settings: [AppSettingKey: String] =
        voice
        ? [.builtinPushToTalkOutputMode: "voice-group"]
        : [.systemClipboardCaptureEnabled: "true"]
      let (model, output) = makeHarness(RecordStore(), initialSettings: settings)
      let controller = makeController(
        model: model, output: output,
        textOutput: .init(capture: {
          XCTFail("Background presentation must not capture an output target")
          return nil
        }),
        editingActivity: { active in XCTAssertFalse(active) })
      addTeardownBlock { await controller.shutdown() }
      let clipboardCount = NSPasteboard.general.changeCount
      let keyWindow = NSApp.keyWindow
      XCTAssertFalse(controller.isVisible)

      try await waitUntil { !model.settings.isLoading }
      await waitForMainRunLoopDefaultMode()
      XCTAssertFalse(controller.isVisible)
      XCTAssertFalse(controller.isKey)
      XCTAssertTrue(NSApp.keyWindow === keyWindow)
      XCTAssertFalse(model.recordWorkspace.buffers.editor.isVisible)
      XCTAssertEqual(NSPasteboard.general.changeCount, clipboardCount)
      await model.recordWorkspace.buffers.editor.shutdown()
      await output.shutdown()
    }
  }

  func testCollectionSwitchesStayHiddenAndExplicitOpeningRestoresEditingSelection() async throws {
    let store = RecordStore()
    let id = try await store.createBufferDraft(text: "Keep this draft")
    let (model, output) = makeHarness(store)
    let controller = makeController(model: model, output: output, editingActivity: { _ in })
    addTeardownBlock { await controller.shutdown() }
    XCTAssertFalse(controller.isVisible)

    model.workflowLibrary.workflows.append(
      WorkflowDefinition(
        name: "Pending collection",
        plan: .init(setup: .init(), process: .init(), output: .init(actions: [.init(id: RecordActionID.store, configuration: .init(buffer: "speech"))])),
        ui: .init(symbolName: "doc", accentColorName: "blue")))
    await waitForMainRunLoopDefaultMode()
    XCTAssertFalse(controller.isVisible)
    show(controller, model: model)
    let editor = model.recordWorkspace.buffers.editor
    await editor.refresh()
    editor.select(id)
    await editor.waitForPendingWrites()
    let session = try XCTUnwrap(editor.session)
    session.selection = .init(location: 5, length: 4)
    controller.dismiss()
    XCTAssertFalse(controller.isVisible)

    XCTAssertTrue(model.setSystemClipboardCaptureEnabled(true))
    await waitForMainRunLoopDefaultMode()
    XCTAssertFalse(controller.isVisible)
    show(controller, model: model)
    await editor.waitForPendingWrites()
    XCTAssertTrue(editor.session === session)
    XCTAssertEqual(session.selection, .init(location: 5, length: 4))
    XCTAssertEqual(session.text, "Keep this draft")
    XCTAssertTrue(controller.isVisible)

    await controller.shutdown()
    XCTAssertTrue(model.setSystemClipboardCaptureEnabled(false))
    XCTAssertTrue(model.setSystemClipboardCaptureEnabled(true))
    await editor.shutdown()
    await output.shutdown()
    XCTAssertFalse(controller.isVisible)
  }

  func testDesktopSendingDismissesPanelAndDoesNotRecaptureAChangedTarget() async throws {
    guard try await requireInteractiveDesktop() else { return }
    for reduceMotion in [false, true] {
      for changeTarget in [false, true] {
        let store = RecordStore()
        let id = try await store.createBufferDraft(text: "Review before sending")
        let element = BufferVerifiableTarget()
        var captureCount = 0
        let textOutput = RecordBufferTextOutput(
          capture: {
            captureCount += 1
            return .init(
              element: element, isCurrent: { true },
              post: { _ in
                XCTFail("A readable text target must use verified replacement")
                return false
              })
          }, modifiersHeld: { false }, isSecure: { false })
        let (model, output) = makeHarness(store, textOutput: textOutput)
        let controller = makeController(
          model: model, output: output,
          textOutput: textOutput, reduceMotion: reduceMotion, editingActivity: { _ in })
        addTeardownBlock { await controller.shutdown() }
        show(controller, model: model)
        let editor = model.recordWorkspace.buffers.editor
        await editor.refresh()
        editor.select(id)
        await editor.waitForPendingWrites()
        let capturesBeforeSend = captureCount
        XCTAssertGreaterThan(capturesBeforeSend, 0)
        controller.selectMode(.collections)
        controller.selectMode(.drafts)
        XCTAssertEqual(captureCount, capturesBeforeSend)
        if changeTarget {
          XCTAssertTrue(
            element.replaceText(
              in: .init(location: 0, length: 0), with: "external edit",
              selection: .init(location: 13, length: 0)))
        }
        let clipboardCount = NSPasteboard.general.changeCount

        editor.send()
        await editor.waitForPendingWrites()
        try await waitUntil { !controller.isVisible && !model.recordWorkspace.buffers.isSending }

        XCTAssertFalse(controller.isVisible)
        XCTAssertFalse(editor.isVisible)
        XCTAssertEqual(output.isVisible, changeTarget)
        XCTAssertFalse(controller.isKey)
        XCTAssertEqual(captureCount, capturesBeforeSend)
        let snapshot = try await store.bufferSnapshot()
        XCTAssertEqual(snapshot.remainingCount, changeTarget ? 1 : 0)
        XCTAssertEqual(element.value, changeTarget ? "external edit" : "Review before sending")
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboardCount)
        if changeTarget {
          show(controller, model: model)
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
          try await waitUntil { !controller.isVisible && !model.recordWorkspace.buffers.isSending }
          XCTAssertEqual(element.value, "external editReview before sending")
          let settled = try await store.bufferSnapshot()
          XCTAssertEqual(settled.remainingCount, 0)
          XCTAssertFalse(controller.isVisible)
        }
        await editor.shutdown()
        await output.shutdown()
      }
    }
  }

  func testBackgroundCollectionPreservesAndRestoresSettingsComparison() async throws {
    let store = RecordStore()
    let record = try await store.ingest(
      .init(
        payload: .text("retained candidate"),
        provenance: .init(source: .init(kind: .systemClipboard))), into: [])
    let (model, output) = makeHarness(store)
    let controller = makeController(model: model, output: output, editingActivity: { _ in })
    addTeardownBlock { await controller.shutdown() }
    let context = RecordComparisonReturn(
      query: "retained", resultLimit: 50, candidateIDs: [record.id],
      semanticIDs: [], selectedID: record.id, sourceBundleIdentifier: nil, currentAppOnly: false,
      kind: .text, pinnedOnly: false)
    var resumed = false
    model.offerComparisonReturn(context) { [weak controller, weak model] returned in
      guard let controller, let model else { return }
      resumed = true
      XCTAssertEqual(returned, context)
      controller.show(
        model: model, mode: .collections, toggle: false,
        deliverSelection: { _, _ in
          XCTFail("Navigation cannot output")
          return .blocked
        },
        onDeliveryAbort: {}, restoring: returned)
    }
    XCTAssertTrue(model.setSystemClipboardCaptureEnabled(true))
    await waitForMainRunLoopDefaultMode()
    XCTAssertFalse(controller.isVisible)
    XCTAssertEqual(model.comparisonReturn, context)

    model.resumeComparison()
    XCTAssertTrue(resumed)
    XCTAssertNil(model.comparisonReturn)
    XCTAssertEqual(controller.presentation.mode, .collections)
    await controller.quickPanelModel?.waitForSearch()
    XCTAssertEqual(controller.quickPanelModel?.searchText, context.query)
    XCTAssertEqual(controller.quickPanelModel?.kind, .text)
    XCTAssertEqual(controller.quickPanelModel?.selectedID, record.id)
    await controller.shutdown()
    await model.recordWorkspace.buffers.editor.shutdown()
    await output.shutdown()
  }

  private func makeController(
    model: AppModel, output: BufferOutputController,
    textOutput: RecordBufferTextOutput = .init(capture: { nil }),
    reduceMotion: Bool = true,
    editingActivity: @escaping (Bool) -> Void
  ) -> RecordPanelController {
    let controller = RecordPanelController(
      pasteTargetProvider: { nil }, pasteTargetRestorer: { _ in false },
      reduceMotionProvider: { reduceMotion })
    controller.configureDrafts(model: model, output: output, textOutput: textOutput, editingActivity: editingActivity)
    return controller
  }

  private func show(_ controller: RecordPanelController, model: AppModel) {
    controller.show(
      model: model, mode: .drafts, toggle: false,
      deliverSelection: { _, _ in .blocked }, onDeliveryAbort: {})
  }

  private func makeHarness(
    _ store: RecordStore, initialSettings: [AppSettingKey: String]? = nil,
    textOutput: RecordBufferTextOutput = .init(capture: { nil })
  )
    -> (AppModel, BufferOutputController)
  {
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
    let output = BufferOutputController(
      store: store, model: model,
      injectionEngine: .init(pasteboard: .init(pasteboard: .withUniqueName()), accessibilityChecker: { true }),
      textOutput: textOutput, isRillFrontmost: { false })
    return (model, output)
  }

  private func waitUntil(_ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !ready() {
      if ContinuousClock.now >= deadline {
        XCTFail("The panel did not reach the expected state")
        throw CancellationError()
      }
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
