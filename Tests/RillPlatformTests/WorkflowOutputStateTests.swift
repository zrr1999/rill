import Foundation
import RillCore
import RillPlatform
import Testing

struct WorkflowOutputStateTests {
  private func store() throws -> (XDGWorkflowFileStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (XDGWorkflowFileStore(configurationDirectoryURL: directory), directory)
  }
  @Test func selectionIsSeparateAndDoesNotChangeFrozenRun() async throws {
    let (store, directory) = try store()
    defer { try? FileManager.default.removeItem(at: directory) }
    let document = try store.decodeDocument(WorkflowDocumentCodecTests.source)
    let record = try await store.saveDocument(document, replacing: nil, expected: .missing)
    var selection = WorkflowOutputState(workflowID: document.workflow.id, outputs: ["copy": false])
    let frozen = try selection.applying(to: document.workflow)
    let saved = try await store.saveOutputState(
      selection, for: record.fileURL, expected: .source(try #require(record.outputStateSource)), expectedDocument: try #require(record.source))
    #expect(try await store.readSource(at: record.fileURL) == record.source)
    #expect(saved.outputState == selection)
    #expect(frozen.plan.output.actions.map(\.documentID) == ["save"])
    selection.outputs["copy"] = true
    _ = try await store.saveOutputState(
      selection, for: record.fileURL, expected: .source(try #require(saved.outputStateSource)), expectedDocument: try #require(record.source))
    #expect(frozen.plan.output.actions.map(\.documentID) == ["save"])
    #expect(try selection.applying(to: document.workflow).plan.output.actions.count == 2)
  }
  @Test func missingStateUsesDefaultsWithoutRecreatingTheFile() async throws {
    let (store, directory) = try store()
    defer { try? FileManager.default.removeItem(at: directory) }
    let document = try store.decodeDocument(WorkflowDocumentCodecTests.source)
    let record = try await store.saveDocument(document, replacing: nil, expected: .missing)
    let url = XDGWorkflowFileStore.outputStateURL(for: record.fileURL)
    try FileManager.default.removeItem(at: url)
    let loaded = try #require(await store.load().records.first)
    #expect(loaded.outputStateSource == nil)
    let defaults = loaded.outputState ?? WorkflowOutputState(workflowID: loaded.workflow.id)
    #expect(try defaults.applying(to: loaded.workflow).plan.output.actions.count == 2)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(throws: (any Error).self) { try WorkflowOutputState(workflowID: document.workflow.id, outputs: ["removed": true]).validate(for: document.workflow) }
  }

  @Test func automaticOutputCannotBeDisabledAndAllOptionalOutputsCan() throws {
    var workflow = try WorkflowDocumentCodec().decode(WorkflowDocumentCodecTests.source).workflow
    #expect(throws: (any Error).self) { try WorkflowOutputState(workflowID: workflow.id, outputs: ["save": false]).applying(to: workflow) }
    workflow.plan.output.actions[0].optional = true
    #expect(try WorkflowOutputState(workflowID: workflow.id, outputs: ["save": false, "copy": false]).applying(to: workflow).plan.output.actions.isEmpty)
  }
  @Test func staleStateWriteCannotOverwriteASecondEdit() async throws {
    let (store, directory) = try store()
    defer { try? FileManager.default.removeItem(at: directory) }
    let document = try store.decodeDocument(WorkflowDocumentCodecTests.source)
    let record = try await store.saveDocument(document, replacing: nil, expected: .missing)
    let state = WorkflowOutputState(workflowID: document.workflow.id)
    let original = try await store.saveOutputState(
      state, for: record.fileURL, expected: .source(try #require(record.outputStateSource)), expectedDocument: try #require(record.source))
    _ = try await store.saveOutputState(
      .init(workflowID: document.workflow.id, outputs: ["copy": false]), for: record.fileURL, expected: .source(try #require(original.outputStateSource)),
      expectedDocument: try #require(record.source))
    await #expect(throws: WorkflowFileConflict.self) {
      try await store.saveOutputState(
        state, for: record.fileURL, expected: .source(try #require(original.outputStateSource)), expectedDocument: try #require(record.source))
    }
  }
  @Test(arguments: ["{", "{\"format\":\"rill.workflow-state\",\"version\":1,\"workflow_id\":\"00000000-0000-0000-0000-000000000000\",\"outputs\":{}}"])
  func invalidStateBlocksItsWorkflow(_ source: String) async throws {
    let (store, directory) = try store()
    defer { try? FileManager.default.removeItem(at: directory) }
    let document = try store.decodeDocument(WorkflowDocumentCodecTests.source)
    let record = try await store.saveDocument(document, replacing: nil, expected: .missing)
    try Data(source.utf8).write(to: XDGWorkflowFileStore.outputStateURL(for: record.fileURL))
    let loaded = await store.load()
    #expect(loaded.records.isEmpty)
    #expect(loaded.issues.first?.workflowID == document.workflow.id)
  }

  @Test func declarationEditConflictsWithAStateSave() async throws {
    let (store, directory) = try store()
    defer { try? FileManager.default.removeItem(at: directory) }
    let document = try store.decodeDocument(WorkflowDocumentCodecTests.source)
    let record = try await store.saveDocument(document, replacing: nil, expected: .missing)
    let source = try #require(record.source)
    try (source + "\n# external edit\n").write(to: record.fileURL, atomically: true, encoding: .utf8)
    await #expect(throws: WorkflowFileConflict.self) {
      try await store.saveOutputState(
        .init(workflowID: document.workflow.id), for: record.fileURL, expected: .source(try #require(record.outputStateSource)), expectedDocument: source)
    }
    #expect(try String(contentsOf: XDGWorkflowFileStore.outputStateURL(for: record.fileURL), encoding: .utf8) == record.outputStateSource)
  }

  @Test func corruptStateCanBeDeletedWithItsDeclaration() async throws {
    let (store, directory) = try store()
    defer { try? FileManager.default.removeItem(at: directory) }
    let document = try store.decodeDocument(WorkflowDocumentCodecTests.source)
    let record = try await store.saveDocument(document, replacing: nil, expected: .missing)
    let stateURL = XDGWorkflowFileStore.outputStateURL(for: record.fileURL)
    try "{".write(to: stateURL, atomically: true, encoding: .utf8)
    try await store.delete(fileURL: record.fileURL, expected: .source(try #require(record.source)))
    #expect(!FileManager.default.fileExists(atPath: stateURL.path))
    #expect(!FileManager.default.fileExists(atPath: record.fileURL.path))
    #expect(try await store.versions(for: document.workflow.id).first?.source == record.source)
  }

  @Test func invalidPackagedResourceHasNoExecutableFallback() throws {
    let (_, directory) = try store()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("[]".utf8).write(to: directory.appendingPathComponent("index.json"))
    #expect(throws: (any Error).self) { try BuiltinWorkflowCatalog(directory: directory).manifest() }
    try Data("invalid".utf8).write(to: directory.appendingPathComponent("index.json"))
    #expect(throws: (any Error).self) { try BuiltinWorkflowCatalog(directory: directory).manifest() }
  }
}
