import Foundation
import RillCore

public struct SystemClipboardCopyAction: OutputAction {
  public let id = RecordActionID.systemClipboardCopy
  private let pasteboard: SystemClipboardPort

  public init(pasteboard: SystemClipboardPort) {
    self.pasteboard = pasteboard
  }

  public func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
    var captureTags = record.provenance.captureTags
    if context.workflow.excludesOutputFromRecordCapture,
      !captureTags.contains(.excludeFromWorkflowCapture)
    {
      captureTags.append(.excludeFromWorkflowCapture)
    }
    let snapshot: SystemClipboardSnapshot
    switch record.payload {
    case .text(let text):
      snapshot = SystemClipboardSnapshot(plainText: text, changeCount: 0)
    case .image(let data):
      snapshot = SystemClipboardSnapshot(
        plainText: "",
        imagePNGData: data,
        changeCount: 0
      )
    case .files(let files):
      snapshot = SystemClipboardSnapshot(
        plainText: "",
        fileURLs: files,
        changeCount: 0
      )
    }
    _ = await pasteboard.writeSnapshot(snapshot, captureTags: captureTags)
    return .copiedToClipboard
  }
}

public struct FocusedApplicationInsertAction: OutputAction {
  public let id = RecordActionID.focusedApplicationInsert
  private let engine: TextInjectionEngine
  private let cursorPreviewCoordinator: CursorTextPreviewCoordinator?

  public init(
    engine: TextInjectionEngine,
    cursorPreviewCoordinator: CursorTextPreviewCoordinator? = nil
  ) {
    self.engine = engine
    self.cursorPreviewCoordinator = cursorPreviewCoordinator
  }

  public func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
    if case .text(let text) = record.payload,
      context.workflow.resolvedLivePreviewPlacement == .cursor,
      let cursorPreviewCoordinator
    {
      switch await cursorPreviewCoordinator.commit(
        runID: context.runID,
        finalText: text
      ) {
      case .committed:
        return .injected
      case .useStandardInjection:
        break
      case .blocked:
        return .skipped(
          "The cursor preview target changed, so Rill did not overwrite its contents."
        )
      }
    }
    do {
      switch record.payload {
      case .text(let text):
        try await engine.inject(text, targetFocus: context.contextSnapshot.focus)
      case .image(let data):
        try await engine.injectClipboardSnapshot(
          SystemClipboardSnapshot(
            plainText: "",
            imagePNGData: data,
            changeCount: 0,
            captureTags: record.provenance.captureTags
          ),
          targetFocus: context.contextSnapshot.focus
        )
      case .files(let files):
        try await engine.injectClipboardSnapshot(
          SystemClipboardSnapshot(
            plainText: "",
            fileURLs: files,
            changeCount: 0,
            captureTags: record.provenance.captureTags
          ),
          targetFocus: context.contextSnapshot.focus
        )
      }
    } catch let error as TextInjectionEngine.InjectionError
      where error == .deliveredButClipboardRestorationFailed
    {
      // The paste command has already committed. Preserve that semantic
      // across the Platform -> Runtime boundary so callers never turn a
      // clipboard-recovery problem into a retryable output failure.
      throw CommittedOutputFailure.clipboardRestorationFailedAfterInjection
    }
    return .injected
  }
}
