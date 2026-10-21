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
    let warning = WorkflowFileIssue(filename: "workflows.toml", message: "Directory warning", reason: .directoryUnreadable, workflowID: workflow.id)
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
    var workflow = makeDefaultWorkflow()
    workflow.plan.output.actions[0].documentID = "copy"
    workflow.plan.output.actions[0].optional = true
    let invalid = makeDefaultWorkflow()
    let directory = URL(fileURLWithPath: "/tmp/workflows.toml", isDirectory: true)
    let file = directory.appendingPathComponent("workflows.toml")
    let warning = WorkflowFileIssue(filename: "workflows.toml", message: "Directory warning", reason: .directoryUnreadable, workflowID: workflow.id)
    let fileIssue = WorkflowFileIssue(filename: "invalid.toml", message: "Invalid file", workflowID: invalid.id)
    var record = WorkflowFileRecord(workflow: workflow, isEnabled: true, fileURL: file)
    let files = UITestWorkflowFileStore(
      records: [record], issues: [warning, fileIssue], configurationDirectoryURL: directory)
    let settings = UITestSettingsStore(unavailableKeys: [.workflowLibrary])
    let model = makeHarness(workflows: [], settingsStore: settings, workflowFileStore: files).model
    await model.waitForInitialVoiceConfiguration()
    XCTAssertEqual(model.workflowLibrary.workflowLibraryAvailability, .unavailable)
    XCTAssertTrue(model.isWorkflowOutputEnabled(workflow.plan.output.actions[0], index: 0, workflow: workflow))
    record.outputState = WorkflowOutputState(workflowID: workflow.id, outputs: ["copy": false])
    await files.replaceLoadResult(records: [record], issues: [warning, fileIssue])
    await settings.setUnavailableKeys([])
    model.retryUnavailableStoredSettingsDomains()
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while model.workflowLibrary.workflowLibraryAvailability != .available && ContinuousClock.now < deadline { await Task.yield() }
    XCTAssertEqual(model.workflowLibrary.workflowLibraryAvailability, .available)
    XCTAssertEqual(model.workflowLibrary.customWorkflows.map(\.id), [workflow.id])
    XCTAssertEqual(model.workflowLibrary.invalidWorkflowFileIDs, [invalid.id])
    XCTAssertEqual(model.workflowLibrary.workflowFileURLsByID[workflow.id], file)
    XCTAssertEqual(model.workflowLibrary.workflowFileURLsByID[invalid.id], directory.appendingPathComponent("invalid.toml"))
    XCTAssertTrue(model.isWorkflowEnabled(workflow))
    let execution = try XCTUnwrap(model.executionWorkflows(for: workflow.trigger).first)
    XCTAssertTrue(execution.plan.output.actions.isEmpty, "Recovery must keep the saved optional output disabled")
    XCTAssertEqual(model.workflowLibrary.workflowFileIssues, [warning, fileIssue])
    await model.stopSettingsReadTasksForApplicationShutdown()
    await model.flushPendingPersistenceWrites()
  }
}
