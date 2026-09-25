import RillDomainTestSupport
import RillTestSupport
import AppKit
import XCTest

@testable import RillApp
@testable import RillCore
@testable import RillProviders
@testable import RillRuntime
@testable import RillUI

/// An isolated native component host. Clipboard capture and external delivery are absent.
@MainActor
final class RecordInteractiveSearchTests: XCTestCase {
  func testInteractiveSearchWithPublicFixtures() async throws {
    let env = ProcessInfo.processInfo.environment
    guard env["RILL_RECORD_INTERACTIVE"] == "1",
      let worker = env["RILL_NATIVE_SEMANTIC_WORKER"],
      let report = env["RILL_NATIVE_SEMANTIC_REPORT"]
    else {
      throw XCTSkip(
        "Set RILL_RECORD_INTERACTIVE=1 plus WORKER and REPORT for native interaction QA.")
    }
    let output = URL(fileURLWithPath: report)
    let stop = output.deletingLastPathComponent().appendingPathComponent("interactive.stop")
    guard !FileManager.default.fileExists(atPath: report),
      !FileManager.default.fileExists(atPath: stop.path)
    else {
      throw RecordEmbeddingError.invalidInput
    }
    let store = RecordStore()
    for text in [
      "git reset --soft HEAD~1", "git revert HEAD", "git status --short",
      "docker compose logs --follow", "docker compose up --detach",
      "开发环境配置说明", "已完成的测试报告", "INV-123 已支付", "INV-1234 待支付",
    ] {
      _ = try await store.ingest(
        .init(
          payload: .text(text),
          provenance: .init(
            source: .init(kind: .systemClipboard), sourceApplicationName: "Public QA")), into: [])
    }
    let supervisor = SpeechWorkerSupervisor(
      configuration: .init(executableURL: URL(fileURLWithPath: worker)))
    let search = RecordSemanticSearch(
      store: store, embedder: RecordWorkerEmbedder(supervisor: supervisor))
    let workspace = RecordWorkspaceModel(store: store, semanticSearch: search)
    let model = makeModel(workspace: workspace)
    let controller = RecordPanelController(
      pasteTargetProvider: { nil }, pasteTargetRestorer: { _ in false },
      reduceMotionProvider: { true })
    NSApplication.shared.setActivationPolicy(.regular)
    controller.show(
      model: model, deliverSelection: { _, _ in .blocked }, copySelection: { _ in .blocked },
      onDeliveryAbort: {})
    NSApplication.shared.activate()
    let deadline = ContinuousClock.now.advanced(by: .seconds(600))
    var events: [Snapshot] = []
    var last: Snapshot?
    do {
      repeat {
        let panel = controller.quickPanelModel
        let state = Snapshot(
          query: panel?.searchText ?? "", literal: panel?.results.map(\.id.description) ?? [],
          semantic: panel?.semanticResults.map(\.id.description) ?? [],
          semanticState: String(describing: panel?.semanticState),
          selected: panel?.selectedID?.description, preview: panel?.preview?.record.id.description,
          visible: controller.isVisible)
        if state != last {
          events.append(state)
          last = state
          try write(events: events, to: output, finished: false)
        }
        try await Task.sleep(for: .milliseconds(100))
      } while ContinuousClock.now < deadline && !FileManager.default.fileExists(atPath: stop.path)
      await controller.shutdown()
      await workspace.shutdown()
      try write(events: events, to: output, finished: true)
    } catch {
      await controller.shutdown()
      await workspace.shutdown()
      throw error
    }
  }

  private struct Snapshot: Codable, Equatable {
    let query: String
    let literal: [String]
    let semantic: [String]
    let semanticState: String
    let selected: String?
    let preview: String?
    let visible: Bool
  }

  private struct Report: Encodable {
    let processID: Int32
    let processName: String
    let bundleID: String?
    let operatingSystem: String
    let finished: Bool
    let events: [Snapshot]
  }

  private func write(events: [Snapshot], to output: URL, finished: Bool) throws {
    let report = Report(
      processID: ProcessInfo.processInfo.processIdentifier,
      processName: ProcessInfo.processInfo.processName, bundleID: Bundle.main.bundleIdentifier,
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, finished: finished,
      events: events)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: output, options: .atomic)
  }

  private func makeModel(workspace: RecordWorkspaceModel) -> AppModel {
    let bus = EventBus()
    let resolver = CandidateResolver(eventBus: bus)
    let actions = OutputActionRegistry(actions: [])
    let coordinator = makeTestSessionCoordinator(

      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []), actionRegistry: actions,
      candidateResolver: resolver, eventBus: bus)
    return makeAppModelForTesting(
      workflows: [], eventBus: bus, sessionCoordinator: coordinator, outputActionRegistry: actions,
      recordWorkspace: workspace, candidateResolver: resolver,
      loadsPersistentSettingsOnInitialization: false, writeClipboardTextAction: { _ in },
      deliverNextRecordAction: {},
      permissionSnapshot: PermissionSnapshot(accessibility: .granted, microphone: .granted),
      refreshPermissionsAction: {}, requestAccessibilityAction: {}, requestMicrophoneAction: {},
      openAccessibilitySettingsAction: {}, openMicrophoneSettingsAction: {},
      requestGlobalInputAction: {}, retryGlobalInputAction: {}, workflowLibraryChangedAction: {})
  }
}

private struct PublicSearchContext: ContextProvider {
  func captureContext() async -> ContextSnapshot { .empty }
}
