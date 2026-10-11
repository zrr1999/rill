import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
final class WorkflowFileDiagnosticTests: XCTestCase {
  func testDirectoryWarningCannotInvalidateOrRetainAMatchingChildFilename() async throws {
    let workflow = makeDefaultWorkflow()
    let directory = URL(fileURLWithPath: "/tmp/workflows.toml", isDirectory: true)
    let file = directory.appendingPathComponent("workflows.toml")
    let record = WorkflowFileRecord(workflow: workflow, isEnabled: true, fileURL: file)
    let warning = WorkflowFileIssue(filename: "workflows.toml", message: "Directory warning", workflowID: workflow.id, target: .configurationDirectory)
    let files = UITestWorkflowFileStore(records: [record], issues: [warning], configurationDirectoryURL: directory)
    let model = makeHarness(workflows: [], settingsStore: UITestSettingsStore(), workflowFileStore: files).model
    await model.waitForInitialVoiceConfiguration()
    for reload in [false, true] {
      if reload { await model.reloadWorkflowFiles() }
      XCTAssertEqual(model.workflowLibrary.customWorkflows.map(\.id), [workflow.id])
      XCTAssertEqual(model.workflowLibrary.workflowFileURLsByID[workflow.id], file)
      XCTAssertTrue(model.workflowLibrary.invalidWorkflowFileIDs.isEmpty)
      XCTAssertTrue(model.isWorkflowEnabled(workflow))
      XCTAssertEqual(model.workflowLibrary.workflowFileIssues, [warning])
      XCTAssertEqual(warning.resolvedURL(in: directory), directory)
    }
    await files.replaceLoadResult(records: [], issues: [warning])
    await model.reloadWorkflowFiles()
    XCTAssertTrue(model.workflowLibrary.customWorkflows.isEmpty, "A directory warning must not retain a deleted same-name file")
    XCTAssertTrue(model.workflowLibrary.invalidWorkflowFileIDs.isEmpty)
    await model.stopSettingsReadTasksForApplicationShutdown()
    await model.flushPendingPersistenceWrites()
  }

  func testFileErrorRetainsTheLastDefinitionAndBlocksItsNewRuns() async throws {
    let workflow = makeDefaultWorkflow()
    let directory = URL(fileURLWithPath: "/tmp/workflows.toml", isDirectory: true)
    let file = directory.appendingPathComponent("workflows.toml")
    let record = WorkflowFileRecord(workflow: workflow, isEnabled: true, fileURL: file)
    let files = UITestWorkflowFileStore(records: [record], configurationDirectoryURL: directory)
    let harness = makeHarness(workflows: [], settingsStore: UITestSettingsStore(), workflowFileStore: files)
    let model = harness.model
    await model.waitForInitialVoiceConfiguration()
    let issue = WorkflowFileIssue(filename: "workflows.toml", message: "Invalid process step", workflowID: workflow.id)
    await files.replaceLoadResult(records: [], issues: [issue])
    await model.reloadWorkflowFiles()
    XCTAssertEqual(model.workflowLibrary.customWorkflows.map(\.id), [workflow.id])
    XCTAssertEqual(model.workflowLibrary.invalidWorkflowFileIDs, [workflow.id])
    XCTAssertEqual(model.workflowLibrary.workflowFileURLsByID[workflow.id], file)
    XCTAssertEqual(issue.target, .file)
    XCTAssertEqual(issue.resolvedURL(in: directory), file)
    XCTAssertFalse(model.isWorkflowEnabled(workflow))
    model.runWorkflowText("Synthetic blocked input", workflow: workflow)
    XCTAssertFalse(model.voice.isRunning)
    let executions = await harness.actionLog.snapshot()
    XCTAssertEqual(executions, 0)
    await model.stopSettingsReadTasksForApplicationShutdown()
    await model.flushPendingPersistenceWrites()
  }

  func testFileIssueStaysVisibleWithoutDisablingTheActiveLegacyDefinition() async throws {
    let workflow = makeDefaultWorkflow()
    let document = WorkflowLibraryDocument(customWorkflows: [workflow])
    let settings = UITestSettingsStore(storage: [
      .workflowLibrary: String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
    ])
    let issue = WorkflowFileIssue(filename: "legacy.toml", message: "Invalid migrated copy", workflowID: workflow.id)
    let files = UITestWorkflowFileStore(issues: [issue])
    let model = makeHarness(workflows: [], settingsStore: settings, workflowFileStore: files).model
    await model.waitForInitialVoiceConfiguration()
    for reload in [false, true] {
      if reload { await model.reloadWorkflowFiles() }
      XCTAssertFalse(model.workflowLibrary.usesWorkflowFilesAsSource)
      XCTAssertEqual(model.workflowLibrary.customWorkflows.map(\.id), [workflow.id])
      XCTAssertTrue(model.isWorkflowEnabled(workflow))
      XCTAssertTrue(model.workflowLibrary.invalidWorkflowFileIDs.isEmpty)
      XCTAssertEqual(model.workflowLibrary.workflowFileIssues.filter { $0.target == .file }, [issue])
      XCTAssertEqual(model.workflowLibrary.workflowFileIssues.filter { $0.target == .configurationDirectory }.count, 1)
      XCTAssertEqual(issue.resolvedURL(in: files.configurationDirectoryURL), files.configurationDirectoryURL.appendingPathComponent("legacy.toml"))
    }
    await model.stopSettingsReadTasksForApplicationShutdown()
    await model.flushPendingPersistenceWrites()
  }

  func testNewMalformedBuiltinOverrideOpensTheReportedFileWithoutCreatingATemplate() async throws {
    let workflow = makeBuiltinPushToTalkWorkflow()
    let files = UITestWorkflowFileStore()
    let model = makeHarness(workflows: [workflow], settingsStore: UITestSettingsStore(), workflowFileStore: files).model
    await model.waitForInitialVoiceConfiguration()
    let issue = WorkflowFileIssue(filename: "broken.toml", message: "Invalid process step", workflowID: workflow.id)
    await files.replaceLoadResult(records: [], issues: [issue])
    await model.reloadWorkflowFiles()
    let file = files.configurationDirectoryURL.appendingPathComponent("broken.toml")
    XCTAssertEqual(model.workflowLibrary.invalidWorkflowFileIDs, [workflow.id])
    XCTAssertEqual(model.workflowLibrary.workflowFileURLsByID[workflow.id], file)
    let opened = await model.workflowFileForEditing(workflow)
    XCTAssertEqual(opened, file)
    let records = await files.records()
    XCTAssertTrue(records.isEmpty, "Opening the diagnostic must not create a replacement template")
    await model.stopSettingsReadTasksForApplicationShutdown()
    await model.flushPendingPersistenceWrites()
  }

  func testProtectedSettingsRecoverySeparatesDirectoryWarningsFromInvalidFiles() async throws {
    let workflow = makeDefaultWorkflow()
    let invalid = makeDefaultWorkflow()
    let directory = URL(fileURLWithPath: "/tmp/workflows.toml", isDirectory: true)
    let file = directory.appendingPathComponent("workflows.toml")
    let warning = WorkflowFileIssue(filename: "workflows.toml", message: "Directory warning", workflowID: workflow.id, target: .configurationDirectory)
    let fileIssue = WorkflowFileIssue(filename: "invalid.toml", message: "Invalid file", workflowID: invalid.id)
    let files = UITestWorkflowFileStore(
      records: [.init(workflow: workflow, isEnabled: true, fileURL: file)], issues: [warning, fileIssue], configurationDirectoryURL: directory)
    let settings = UITestSettingsStore(storage: [.workflowEnabledStates: "{invalid-json"])
    let model = makeHarness(workflows: [], settingsStore: settings, workflowFileStore: files).model
    await model.waitForInitialVoiceConfiguration()
    XCTAssertEqual(model.workflowLibrary.workflowLibraryAvailability, .unavailable)
    try await settings.setString("{}", forKey: .workflowEnabledStates)
    model.retryUnavailableStoredSettingsDomains()
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while model.workflowLibrary.workflowLibraryAvailability != .available && ContinuousClock.now < deadline { await Task.yield() }
    XCTAssertEqual(model.workflowLibrary.workflowLibraryAvailability, .available)
    XCTAssertEqual(model.workflowLibrary.customWorkflows.map(\.id), [workflow.id])
    XCTAssertEqual(model.workflowLibrary.invalidWorkflowFileIDs, [invalid.id])
    XCTAssertEqual(model.workflowLibrary.workflowFileURLsByID[workflow.id], file)
    XCTAssertEqual(model.workflowLibrary.workflowFileURLsByID[invalid.id], directory.appendingPathComponent("invalid.toml"))
    XCTAssertTrue(model.isWorkflowEnabled(workflow))
    XCTAssertEqual(model.workflowLibrary.workflowFileIssues, [warning, fileIssue])
    await model.stopSettingsReadTasksForApplicationShutdown()
    await model.flushPendingPersistenceWrites()
  }
}
