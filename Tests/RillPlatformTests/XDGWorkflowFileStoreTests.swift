import Foundation
import RillCore
import RillPlatform
import XCTest

final class XDGWorkflowFileStoreTests: XCTestCase {
  func testUsesXDGConfigHomeAndFallsBackForRelativeValue() {
    let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    let configured = XDGWorkflowFileStore(
      environment: ["XDG_CONFIG_HOME": "/tmp/rill-config"],
      homeDirectoryURL: home
    )
    XCTAssertEqual(
      configured.configurationDirectoryURL.path,
      "/tmp/rill-config/rill/workflows"
    )

    let fallback = XDGWorkflowFileStore(
      environment: ["XDG_CONFIG_HOME": "relative/path"],
      homeDirectoryURL: home
    )
    XCTAssertEqual(
      fallback.configurationDirectoryURL.path,
      "/Users/tester/.config/rill/workflows"
    )
  }

  func testCanonicalDocumentRoundTrips() throws {
    let workflow = makeWorkflow()
    let data = try XDGWorkflowFileStore.encode(
      workflow: workflow,
      isEnabled: false
    )
    let source = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertTrue(source.contains("schema_version = 2"))
    XCTAssertTrue(source.contains("enabled = false"))
    XCTAssertTrue(source.contains("[setup.speech]"))
    XCTAssertTrue(source.contains("[[process]]"))
    XCTAssertTrue(source.contains("kind = \"llm-answer\""))
    XCTAssertTrue(source.contains("[[output.actions]]"))

    let decoded = try XDGWorkflowFileStore.decode(source)
    XCTAssertEqual(decoded.workflow, workflow)
    XCTAssertFalse(decoded.isEnabled)
  }

  func testLivePreviewPlacementDefaultsToOverlayAndRoundTripsCursor() throws {
    let legacy = try XDGWorkflowFileStore.decode(
      String(decoding: try XDGWorkflowFileStore.encode(
        workflow: makeWorkflow(),
        isEnabled: true
      ), as: UTF8.self)
    )
    XCTAssertEqual(
      legacy.workflow.metadata[WorkflowMetadataKey.livePreviewPlacement]
        .flatMap(LivePreviewPlacement.init(rawValue:)) ?? .overlay,
      .overlay
    )

    var cursorWorkflow = makeWorkflow()
    cursorWorkflow.metadata[WorkflowMetadataKey.livePreviewPlacement] = "cursor"
    let encoded = try XDGWorkflowFileStore.encode(workflow: cursorWorkflow, isEnabled: true)
    let roundTrip = try XDGWorkflowFileStore.decode(
      try XCTUnwrap(String(data: encoded, encoding: .utf8))
    )
    XCTAssertEqual(
      roundTrip.workflow.metadata[WorkflowMetadataKey.livePreviewPlacement],
      "cursor"
    )
  }

  func testLegacyRecordActionsStrategyAndMetadataNormalizeWithoutRewritingSource() async throws {
    let collectionID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    let legacy = """
    schema_version = 1
    id = "11111111-2222-3333-4444-555555555555"
    name = "Legacy workflow"
    trigger = "manual"
    process = []
    [ui]
    symbol = "sparkles"
    accent = "blue"
    [setup]
    [output]
    strategy = "stack-first"
    [[output.actions]]
    id = "stack.push"
    [metadata]
    "\(WorkflowMetadataKey.legacyTargetRecordCollectionID)" = "\(collectionID.uuidString)"
    "\(WorkflowMetadataKey.excludeOutputFromWorkflowCapture)" = "true"
    """
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("legacy.toml")
    try Data(legacy.utf8).write(to: fileURL)

    let store = XDGWorkflowFileStore(configurationDirectoryURL: directory)
    let result = await store.load()
    let loaded = try XCTUnwrap(result.records.first?.workflow)

    XCTAssertEqual(loaded.plan.output.actions.map(\.id), ["record.store"])
    XCTAssertEqual(loaded.plan.output.deliveryPolicy.strategy, .collectionFirst)
    XCTAssertEqual(loaded.targetRecordCollectionIDs, [RecordCollectionID(collectionID)])
    XCTAssertTrue(loaded.excludesOutputFromRecordCapture)
    XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), legacy)

    let saved = String(
      decoding: try XDGWorkflowFileStore.encode(workflow: loaded, isEnabled: true),
      as: UTF8.self
    )
    XCTAssertTrue(saved.contains("record.store"))
    XCTAssertTrue(saved.contains("collection-first"))
    XCTAssertFalse(saved.contains("stack.push"))
    XCTAssertFalse(saved.contains("stack-first"))
    XCTAssertFalse(saved.contains(WorkflowMetadataKey.legacyTargetRecordCollectionID))
    _ = try await store.saveDocument(WorkflowDocument(workflow: loaded, isEnabled: true), replacing: fileURL, expected: .source(legacy))
    let history = try await store.versions(for: loaded.id)
    XCTAssertEqual(history.first?.source, legacy)
    XCTAssertTrue(try String(contentsOf: fileURL, encoding: .utf8).contains("schema_version = 2"))

  }

  func testInvalidLivePreviewPlacementIsRejected() throws {
    var workflow = makeWorkflow()
    workflow.metadata[WorkflowMetadataKey.livePreviewPlacement] = "cursor"
    let data = try XDGWorkflowFileStore.encode(workflow: workflow, isEnabled: true)
    let source = String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: "live_preview_placement = \"cursor\"",
      with: "live_preview_placement = \"nearby-window\""
    )

    XCTAssertThrowsError(try XDGWorkflowFileStore.decode(source))
  }

  func testSaveCreatesPrivateFileAndLoadPreservesItsURL() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = XDGWorkflowFileStore(configurationDirectoryURL: directory)
    let workflow = makeWorkflow()

    let fileURL = try await store.save(
      workflow: workflow,
      isEnabled: true,
      replacing: nil
    )
    let permissions = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions]
        as? NSNumber
    )
    XCTAssertEqual(permissions.intValue & 0o777, 0o600)

    let result = await store.load()
    XCTAssertEqual(result.discoveredFileCount, 1)
    XCTAssertTrue(result.issues.isEmpty)
    let record = try XCTUnwrap(result.records.first)
    XCTAssertEqual(record.workflow, workflow)
    XCTAssertTrue(record.isEnabled)
    XCTAssertEqual(
      record.fileURL.resolvingSymlinksInPath(),
      fileURL.resolvingSymlinksInPath()
    )
    let replacedURL = try await store.save(
      workflow: record.workflow,
      isEnabled: false,
      replacing: record.fileURL
    )
    XCTAssertEqual(
      replacedURL.resolvingSymlinksInPath(),
      fileURL.resolvingSymlinksInPath()
    )
  }

  func testDeleteRejectsExternalChangesAndPreservesAcceptedSourceForRecovery() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = XDGWorkflowFileStore(configurationDirectoryURL: directory)
    let workflow = makeWorkflow()
    let saved = try await store.saveDocument(.init(workflow: workflow), replacing: nil, expected: .missing)
    let source = try XCTUnwrap(saved.source)
    let changed = source + "\n# External edit\n"
    try changed.write(to: saved.fileURL, atomically: true, encoding: .utf8)
    do {
      try await store.delete(fileURL: saved.fileURL, expected: .source(source))
      XCTFail("An external edit must survive a stale delete")
    } catch WorkflowFileConflict.changed {}
    XCTAssertEqual(try String(contentsOf: saved.fileURL, encoding: .utf8), changed)
    try await store.delete(fileURL: saved.fileURL, expected: .source(changed))
    XCTAssertFalse(FileManager.default.fileExists(atPath: saved.fileURL.path))
    let versions = try await store.versions(for: workflow.id)
    XCTAssertTrue(versions.contains(where: { $0.source == changed }))
  }

  func testMalformedAndDuplicateFilesAreReportedWithoutHidingValidFiles() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let store = XDGWorkflowFileStore(configurationDirectoryURL: directory)
    let firstWorkflow = makeWorkflow()
    let secondWorkflow = makeWorkflow(
      id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      name: "Second"
    )
    let firstData = try XDGWorkflowFileStore.encode(
      workflow: firstWorkflow,
      isEnabled: true
    )
    let secondData = try XDGWorkflowFileStore.encode(
      workflow: secondWorkflow,
      isEnabled: true
    )
    try firstData.write(to: directory.appendingPathComponent("first.toml"))
    try firstData.write(to: directory.appendingPathComponent("duplicate.toml"))
    try secondData.write(to: directory.appendingPathComponent("second.toml"))
    try Data("schema_version = [".utf8).write(
      to: directory.appendingPathComponent("broken.toml")
    )

    let result = await store.load()
    XCTAssertEqual(result.discoveredFileCount, 4)
    XCTAssertEqual(result.records.map(\.workflow.id), [secondWorkflow.id])
    XCTAssertEqual(result.issues.count, 3)
    XCTAssertTrue(result.issues.contains { $0.filename == "broken.toml" })
    XCTAssertEqual(
      Set(result.issues.map(\.filename)),
      ["broken.toml", "duplicate.toml", "first.toml"]
    )
  }

  func testBundledTemplatesConformToCurrentSchema() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let templateDirectory = repositoryRoot
      .appendingPathComponent("Sources/RillApp/Resources/WorkflowTemplates")
    let templates = try FileManager.default.contentsOfDirectory(
      at: templateDirectory,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "toml" }
    XCTAssertEqual(templates.count, 3)

    for template in templates {
      let source = try String(contentsOf: template, encoding: .utf8)
      XCTAssertNoThrow(try XDGWorkflowFileStore.decode(source, fileURL: template))
    }
  }

  private func temporaryDirectory() -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-workflow-store-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    // The configuration and its sibling version directory share one test-owned root.
    return root.appendingPathComponent("workflows", isDirectory: true)
  }

  private func makeWorkflow(
    id: UUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
    name: String = "Manual Dictation"
  ) -> WorkflowDefinition {
    var workflow = WorkflowDefinition(
      id: id,
      name: name,
      trigger: .hotkey,
      plan: WorkflowPlan(
        setup: WorkflowSetupPhase(
          speechRoute: WorkflowSpeechRoute(
            selection: .automatic,
            recognizerID: "local-speech",
            language: "zh-CN"
          ),
          vocabularyBindings: [
            VocabularyCollectionBinding(
              id: UUID(uuidString: "99999999-2222-3333-4444-555555555555")!,
              collectionID: VocabularyCollection.personalID,
              uses: [.recognitionHints, .textReplacement]
            )
          ]
        ),
        process: WorkflowProcessPhase(steps: [
          WorkflowProcessStep(
            id: UUID(uuidString: "77777777-2222-3333-4444-555555555555")!,
            kind: .recognizeSpeech
          ),
          WorkflowProcessStep(
            id: UUID(uuidString: "88888888-2222-3333-4444-555555555555")!,
            kind: .applyVocabulary
          ),
          WorkflowProcessStep(
            id: UUID(uuidString: "AAAAAAAA-2222-3333-4444-555555555555")!,
            kind: .llmAnswer,
            prompt: "Answer directly."
          ),
        ]),
        output: WorkflowOutputPhase(
          actions: [OutputActionReference(id: "focused-application.insert")],
          deliveryPolicy: DeliveryPolicy(strategy: .immediate)
        )
      ),
      ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "blue"),
      metadata: [
        "workflow.origin": "user",
        "trigger.gesture": "control-option-shift-space",
      ]
    )
    workflow.declaredInputKind = .audio
    for index in workflow.plan.process.steps.indices {
      workflow.plan.process.steps[index].documentID = workflow.plan.process.steps[index].id.uuidString
    }
    for index in workflow.plan.output.actions.indices {
      workflow.plan.output.actions[index].documentID = "output-\(index + 1)"
    }
    return workflow
  }
}
