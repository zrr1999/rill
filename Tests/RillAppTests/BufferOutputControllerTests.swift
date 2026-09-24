import AppKit
import Testing

@testable import RillApp
@testable import RillCore
@testable import RillPlatform
@testable import RillRuntime
@testable import RillUI

@MainActor struct BufferOutputControllerTests {
  @Test func uncertainOutputRequiresExplicitRetryAndKeepsTheExactItem() async throws {
    let store = RecordStore()
    let first = try await enqueue(.text("first"), store: store)
    let model = makeModel(store)
    var sent: [String] = []
    let element = BufferUnverifiableTarget()
    let target = RecordBufferTextOutput.Target(
      element: element, isCurrent: { true },
      post: {
        sent.append(String(decoding: $0, as: UTF16.self))
        return true
      })
    let controller = BufferOutputController(
      store: store, model: model, injectionEngine: makeInjectionEngine(),
      textOutput: .init(capture: { target }, modifiersHeld: { false }, isSecure: { false }),
      isRillFrontmost: { false })
    let clipboardCount = NSPasteboard.general.changeCount
    controller.output()
    controller.output()
    try await waitUntil { !model.recordWorkspace.buffers.isSending }
    #expect(sent == ["first"])
    #expect(try await store.bufferSnapshot().active?.state == .awaitingConfirmation)

    // A newer external capture must not replace the item selected for an explicit retry.
    _ = try await enqueue(.text("new copy"), store: store)
    controller.output()
    try await waitUntil { !model.recordWorkspace.buffers.isSending }
    #expect(sent == ["first"])
    controller.retry()
    try await waitUntil { try await store.bufferSnapshot().active == nil }
    #expect(try await store.bufferSnapshot().next?.id == first)
    controller.output()
    try await waitUntil { !model.recordWorkspace.buffers.isSending }
    #expect(sent == ["first", "first"])
    controller.confirm()
    try await waitUntil { try await store.bufferSnapshot().active == nil }
    #expect(try await store.bufferSnapshot().remainingCount == 1)
    #expect(try await store.bufferSnapshot().nextHeader?.preview == "new copy")
    await controller.shutdown()
    #expect(NSPasteboard.general.changeCount == clipboardCount)
  }

  @Test func cancellationAfterFirstChunkStopsAndRetainsUncertainItem() async throws {
    let store = RecordStore()
    let id = try await enqueue(.text(String(repeating: "中文🙂", count: 100)), store: store)
    let model = makeModel(store)
    var sent = 0
    let cancellation = BufferCancellationProbe()
    let target = RecordBufferTextOutput.Target(
      element: BufferUnverifiableTarget(), isCurrent: { true },
      post: { _ in
        sent += 1
        cancellation.controller?.cancel()
        return true
      })
    let controller = BufferOutputController(
      store: store, model: model, injectionEngine: makeInjectionEngine(),
      textOutput: .init(capture: { target }, modifiersHeld: { false }, isSecure: { false }),
      isRillFrontmost: { false })
    cancellation.controller = controller
    let clipboardCount = NSPasteboard.general.changeCount
    controller.output()
    try await waitUntil { !model.recordWorkspace.buffers.isSending }
    #expect(sent == 1)
    #expect(try await store.bufferSnapshot().active?.id == id)
    #expect(try await store.bufferSnapshot().active?.state == .awaitingConfirmation)
    await controller.shutdown()
    #expect(NSPasteboard.general.changeCount == clipboardCount)
  }

  @Test(arguments: [
    RecordPayload.image(Data([1])), .files([URL(fileURLWithPath: "/tmp/rill-pending-file")]),
  ])
  func unstartedDragAndEmptyBufferNeverFallBackToClipboard(payload: RecordPayload) async throws {
    let store = RecordStore()
    let model = makeModel(store)
    let controller = BufferOutputController(
      store: store, model: model, injectionEngine: makeInjectionEngine(),
      textOutput: .init(capture: { nil }, modifiersHeld: { false }, isSecure: { false }),
      isRillFrontmost: { false })
    let clipboardCount = NSPasteboard.general.changeCount
    controller.output()
    try await waitUntil { !model.recordWorkspace.buffers.isSending }
    #expect(try await store.bufferSnapshot().active == nil)
    let id = try await enqueue(payload, store: store)
    controller.output()
    try await waitUntil { !model.recordWorkspace.buffers.isSending }
    #expect(try await store.bufferSnapshot().active?.id == id)
    controller.cancel()
    await controller.shutdown()
    #expect(try await store.bufferSnapshot().active == nil)
    #expect(try await store.bufferSnapshot().next?.id == id)
    #expect(NSPasteboard.general.changeCount == clipboardCount)
  }

  private func makeInjectionEngine() -> TextInjectionEngine {
    TextInjectionEngine(
      pasteboard: SystemClipboardPort(pasteboard: NSPasteboard.withUniqueName()),
      accessibilityChecker: { true })
  }

  private func enqueue(_ payload: RecordPayload, store: RecordStore) async throws -> BufferEntryID {
    let record = try await store.ingest(
      .init(payload: payload, provenance: .init(source: .init(kind: .systemClipboard))), into: [])
    return try await store.enqueueRecord(record.id, in: RecordBuffer.clipboardID)
  }

  private func waitUntil(_ ready: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while try await !ready() {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private func makeModel(_ store: RecordStore) -> AppModel {
    let bus = EventBus()
    let resolver = CandidateResolver(eventBus: bus)
    let actions = OutputActionRegistry(actions: [
      ForbiddenBufferClipboardAction(id: "system-clipboard.copy"),
      ForbiddenBufferClipboardAction(id: "focused-application.insert"),
    ])
    let coordinator = SessionCoordinator(
      contextProvider: BufferOutputTestContextProvider(),
      recognizerRegistry: .init(recognizers: []), transformerRegistry: .init(transformers: []),
      actionRegistry: actions, candidateResolver: resolver, recordStore: store, eventBus: bus)
    return AppModel(
      workflows: [], eventBus: bus, sessionCoordinator: coordinator,
      outputActionRegistry: actions, recordWorkspace: .init(store: store),
      candidateResolver: resolver,
      loadsPersistentSettingsOnInitialization: false,
      writeClipboardTextAction: { _ in
        Issue.record("Special output must never write the general clipboard")
      },
      deliverNextRecordAction: { Issue.record("Special output must never use legacy delivery") },
      permissionSnapshot: .init(accessibility: .granted, microphone: .granted),
      refreshPermissionsAction: {}, requestAccessibilityAction: {}, requestMicrophoneAction: {},
      openAccessibilitySettingsAction: {}, openMicrophoneSettingsAction: {},
      requestGlobalInputAction: {}, retryGlobalInputAction: {}, workflowLibraryChangedAction: {})
  }
}

private struct ForbiddenBufferClipboardAction: OutputAction {
  let id: String
  func execute(text: String, context: ActionContext) async throws -> ActionResult {
    Issue.record("Special output must never invoke a clipboard-writing transport")
    throw CancellationError()
  }
}

private struct BufferOutputTestContextProvider: ContextProvider {
  func captureContext() async -> ContextSnapshot { .empty }
}

private struct BufferUnverifiableTarget: CursorTextPreviewTarget {
  func isFocused() -> Bool { true }
  func supportsSelectedTextReplacement() -> Bool { false }
  func selectedRange() -> NSRange? { nil }
  func selectedText(in range: NSRange) -> String? { nil }
  func replaceText(in range: NSRange, with text: String, selection: NSRange) -> Bool {
    Issue.record("Unsupported AX replacement must not be attempted")
    return false
  }
}

@MainActor private final class BufferCancellationProbe {
  weak var controller: BufferOutputController?
}
