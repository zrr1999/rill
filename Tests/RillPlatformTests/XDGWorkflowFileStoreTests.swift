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
    XCTAssertTrue(source.contains("schema_version = 1"))
    XCTAssertTrue(source.contains("enabled = false"))
    XCTAssertTrue(source.contains("[setup.speech]"))
    XCTAssertTrue(source.contains("[[process]]"))
    XCTAssertTrue(source.contains("[[output.actions]]"))

    let decoded = try XDGWorkflowFileStore.decode(source)
    XCTAssertEqual(decoded.workflow, workflow)
    XCTAssertFalse(decoded.isEnabled)
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

  func testBundledTemplatesConformToSchemaVersionOne() throws {
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
    FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-workflow-store-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  private func makeWorkflow(
    id: UUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
    name: String = "Manual Dictation"
  ) -> WorkflowDefinition {
    WorkflowDefinition(
      id: id,
      name: name,
      trigger: .hotkey,
      plan: WorkflowPlan(
        setup: WorkflowSetupPhase(
          speechRoute: WorkflowSpeechRoute(
            selection: .automatic,
            recognizerID: "sherpa-onnx.local",
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
        ]),
        output: WorkflowOutputPhase(
          actions: [OutputActionReference(id: "inject.text")],
          deliveryPolicy: DeliveryPolicy(strategy: .immediate)
        )
      ),
      ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "blue"),
      metadata: [
        "workflow.origin": "user",
        "trigger.gesture": "control-option-shift-space",
      ]
    )
  }
}
