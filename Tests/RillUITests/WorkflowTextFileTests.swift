import Foundation
import RillPlatform
@testable import RillWorkflows
import Testing
@testable import RillCore
@testable import RillUI

@MainActor
struct WorkflowTextFileTests {
  @Test(arguments: [false, true])
  func workflowSelectionSurvivesRestart(fileBackedCleanup: Bool) async throws {
    let workflows = try BuiltinWorkflowCatalog().manifest().workflows
    let cleanup = try #require(workflows.first { $0.titleKey == .smartCleanup })
    let dictation = try #require(workflows.first { $0.titleKey == .speechRecognition })
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = XDGWorkflowFileStore(configurationDirectoryURL: directory.appendingPathComponent("workflows"))
    let settingsStore = UITestSettingsStore()
    func makeModel() -> AppModel {
      makeHarness(
        workflows: workflows, settingsStore: settingsStore, workflowFileStore: store,
        credentialStore: UITestSecureCredentialStore(storage: [.openAIAPIKey: "test-key"]),
        settingsWriteDebounceDuration: .zero
      ).model
    }

    var model = makeModel()
    await model.waitForInitialVoiceConfiguration()
    #expect(!model.isWorkflowEnabled(cleanup))
    #expect(model.isWorkflowEnabled(dictation))
    if fileBackedCleanup {
      _ = try #require(await model.workflowFileForEditing(cleanup))
    }

    for selectedID in [cleanup.id, dictation.id, nil] {
      if let selectedID {
        model.setWorkflowEnabled(true, for: selectedID)
      } else {
        model.setWorkflowEnabled(false, for: dictation.id)
      }
      await model.flushPendingPersistenceWrites()
      #expect(model.isWorkflowEnabled(cleanup) == (selectedID == cleanup.id))
      #expect(model.isWorkflowEnabled(dictation) == (selectedID == dictation.id))
      await model.stopSettingsReadTasksForApplicationShutdown()
      await model.flushPendingPersistenceWrites()

      model = makeModel()
      await model.waitForInitialVoiceConfiguration()
      #expect(model.isWorkflowEnabled(cleanup) == (selectedID == cleanup.id))
      #expect(model.isWorkflowEnabled(dictation) == (selectedID == dictation.id))
      #expect(model.enabledWorkflows(for: .hotkey).map(\.id) == selectedID.map { [$0] } ?? [])
    }
    await model.stopSettingsReadTasksForApplicationShutdown()
    await model.flushPendingPersistenceWrites()
  }

  @Test func fileBackedCleanupAndBuiltinDictationRemainMutuallyExclusive() async throws {
    let workflows = try BuiltinWorkflowCatalog().manifest().workflows
    let cleanup = try #require(workflows.first { $0.titleKey == .smartCleanup })
    let dictation = try #require(workflows.first { $0.titleKey == .speechRecognition })
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = XDGWorkflowFileStore(configurationDirectoryURL: directory.appendingPathComponent("workflows"))
    let model = makeHarness(
      workflows: workflows, settingsStore: UITestSettingsStore(), workflowFileStore: store,
      credentialStore: UITestSecureCredentialStore(storage: [.openAIAPIKey: "deepseek-test-key"]),
      settingsWriteDebounceDuration: .zero
    ).model
    await model.waitForInitialVoiceConfiguration()
    #expect(model.settings.openAICredentialAvailability == .available)
    #expect(model.isWorkflowExecutionSupported(cleanup))
    let fileURL = try #require(await model.workflowFileForEditing(cleanup))
    model.setWorkflowEnabled(true, for: cleanup.id)
    await model.flushPendingPersistenceWrites()
    #expect(model.isWorkflowEnabled(cleanup))
    #expect(!model.isWorkflowEnabled(dictation))
    #expect(model.enabledWorkflows(for: .hotkey).map(\.id) == [cleanup.id])
    #expect(try store.decodeDocument(String(contentsOf: fileURL, encoding: .utf8)).isEnabled)

    let externalSource = "# Changed by an external editor\n" + (try String(contentsOf: fileURL, encoding: .utf8))
    try externalSource.write(to: fileURL, atomically: true, encoding: .utf8)
    model.setWorkflowEnabled(true, for: dictation.id)
    #expect(model.workflowLibrary.isUpdatingWorkflowEnabledStates)
    model.setWorkflowEnabled(false, for: cleanup.id)
    await model.flushPendingPersistenceWrites()
    #expect(!model.workflowLibrary.isUpdatingWorkflowEnabledStates)
    #expect(!model.isWorkflowEnabled(dictation))
    #expect(model.enabledWorkflows(for: .hotkey).map(\.id) == [cleanup.id])
    #expect(try String(contentsOf: fileURL, encoding: .utf8) == externalSource)

    model.setWorkflowEnabled(true, for: dictation.id)
    await model.flushPendingPersistenceWrites()
    #expect(!model.isWorkflowEnabled(cleanup))
    #expect(model.enabledWorkflows(for: .hotkey).map(\.id) == [dictation.id])
    #expect(try !store.decodeDocument(String(contentsOf: fileURL, encoding: .utf8)).isEnabled)
    await model.stopSettingsReadTasksForApplicationShutdown()
    await model.flushPendingPersistenceWrites()
  }

  @Test func outputChoicesReloadAndDoNotChangeAnExistingExecutionSnapshot() async throws {
    let workflows = try BuiltinWorkflowCatalog().manifest().workflows
    let builtin = try #require(workflows.first { $0.titleKey == .speechRecognition })
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = XDGWorkflowFileStore(configurationDirectoryURL: directory.appendingPathComponent("workflows"))
    let model = makeHarness(workflows: workflows, workflowFileStore: store).model
    await model.waitForInitialVoiceConfiguration()
    let frozen = try #require(model.executionWorkflows(for: .hotkey).first)
    #expect(frozen.plan.output.actions.count == 3)
    for (index, action) in builtin.plan.output.actions.enumerated() where action.optional {
      model.setWorkflowOutputEnabled(false, action: action, index: index, workflow: builtin)
      await model.flushPendingPersistenceWrites()
    }
    #expect(model.workflowLibrary.workflowLibraryErrorPresentation?(.english) == nil)
    let declaration = try #require(model.enabledWorkflows(for: .hotkey).first)
    #expect(declaration.plan.output.actions.count == 3)
    let selected = try #require(model.executionWorkflows(for: .hotkey).first)
    #expect(selected.plan.output.actions.map(\.documentID) == ["save"])
    #expect(frozen.plan.output.actions.count == 3)
    #expect(model.requiresCapturedAudioForInteractiveRun(declaration))

    let url = try #require(model.workflowLibrary.workflowFileURLsByID[builtin.id])
    let stateURL = url.deletingPathExtension().appendingPathExtension("state.json")
    let state = WorkflowOutputState(workflowID: builtin.id, outputs: ["deliver": true, "enqueue": false])
    try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    await model.reloadWorkflowFiles()
    #expect(model.executionWorkflows(for: .hotkey).first?.plan.output.actions.map(\.documentID) == ["save", "deliver"])
    try Data("{}".utf8).write(to: stateURL, options: .atomic)
    await model.reloadWorkflowFiles()
    #expect(model.executionWorkflows(for: .hotkey).isEmpty)
    await model.stopSettingsReadTasksForApplicationShutdown()
    await model.flushPendingPersistenceWrites()
  }

  @Test func manualTextRunUsesTheAuthorizedClipboardInput() async throws {
    let workflow = WorkflowDefinition(
      name: "Clipboard", plan: .init(setup: .init(), process: .init(), output: .init(actions: [.init(id: RecordActionID.systemClipboardCopy)])),
      ui: .init(symbolName: "doc", accentColorName: "blue"))
    let harness = makeHarness(
      workflow: workflow,
      authorizeWorkflowRunAction: { value in
        .init(
          workflow: value, contextSnapshot: .init(focus: ContextSnapshot.empty.focus, clipboard: .init(plainText: "authorized input", changeCount: 1)),
          recognitionOptions: .empty)
      })
    await harness.model.waitForInitialVoiceConfiguration()
    harness.model.runWorkflow(workflow)
    await harness.model.waitForInteractiveWorkflowRun()
    #expect(await harness.actionLog.snapshot() == 1)
    #expect(harness.model.lastFailure == nil)
    await harness.model.stopSettingsReadTasksForApplicationShutdown()
  }

  @Test func openingAnExistingFilePreservesCommentsAndSource() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = XDGWorkflowFileStore(configurationDirectoryURL: directory.appendingPathComponent("workflows"))
    let model = makeHarness(settingsStore: UITestSettingsStore(), workflowFileStore: store).model
    await model.waitForInitialVoiceConfiguration()
    let url = try #require(await model.newWorkflowFile())
    let source = "# My instructions and comments\n" + (try String(contentsOf: url, encoding: .utf8))
    try source.write(to: url, atomically: true, encoding: .utf8)
    await model.reloadWorkflowFiles()
    let workflow = try #require(model.workflowLibrary.customWorkflows.first)

    #expect(!model.isWorkflowEnabled(workflow))
    let reopened = await model.workflowFileForEditing(workflow)
    #expect(reopened?.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path)
    #expect(try String(contentsOf: url, encoding: .utf8) == source)
    await model.stopSettingsReadTasksForApplicationShutdown()
    await model.flushPendingPersistenceWrites()
  }

  @Test func duplicatingCreatesADisabledFileWithANewIdentity() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = XDGWorkflowFileStore(configurationDirectoryURL: directory.appendingPathComponent("workflows"))
    let model = makeHarness(settingsStore: UITestSettingsStore(), workflowFileStore: store).model
    await model.waitForInitialVoiceConfiguration()
    let originalURL = try #require(await model.newWorkflowFile())
    let original = try store.decodeDocument(String(contentsOf: originalURL, encoding: .utf8))
    let copyURL = try #require(await model.workflowFileForEditing(original.workflow, duplicate: true))
    let copy = try store.decodeDocument(String(contentsOf: copyURL, encoding: .utf8))
    #expect(copyURL != originalURL)
    #expect(copy.workflow.id != original.workflow.id)
    #expect(copy.workflow.plan == original.workflow.plan)

    #expect(!copy.isEnabled)
    await model.stopSettingsReadTasksForApplicationShutdown()
    await model.flushPendingPersistenceWrites()
  }
}
