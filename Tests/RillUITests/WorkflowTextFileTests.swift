import Foundation
import RillPlatform
import Testing
@testable import RillCore
@testable import RillUI

@MainActor
struct WorkflowTextFileTests {
    @Test(arguments: [false, true])
    func workflowSelectionSurvivesRestart(fileBackedCleanup: Bool) async throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RillApp/Resources/BuiltinWorkflowManifest.json")
        let workflows = try JSONDecoder().decode(WorkflowManifest.self, from: Data(contentsOf: manifestURL)).workflows
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
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RillApp/Resources/BuiltinWorkflowManifest.json")
        let workflows = try JSONDecoder().decode(WorkflowManifest.self, from: Data(contentsOf: manifestURL)).workflows
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
        #expect(model.openAICredentialAvailability == .available)
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
        #expect(model.isUpdatingWorkflowEnabledStates)
        model.setWorkflowEnabled(false, for: cleanup.id)
        await model.flushPendingPersistenceWrites()
        #expect(!model.isUpdatingWorkflowEnabledStates)
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

    @Test func openingCannotDiscardAnUnmigratedLegacyLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = XDGWorkflowFileStore(configurationDirectoryURL: directory.appendingPathComponent("workflows"))
        let model = makeHarness(settingsStore: UITestSettingsStore(), workflowFileStore: store).model
        await model.waitForInitialVoiceConfiguration()
        let legacy = [makeDefaultWorkflow(), makeDefaultWorkflow()]
        model.workflowLibrary.customWorkflows = legacy
        model.workflowLibrary.usesWorkflowFilesAsSource = false
        let opened = await model.workflowFileForEditing(legacy[0])
        #expect(opened == nil)
        #expect(model.workflowLibrary.customWorkflows == legacy)
        #expect(!model.workflowLibrary.usesWorkflowFilesAsSource)
        #expect(await store.load().records.isEmpty)
        #expect(model.workflowLibrary.workflowLibraryError != nil)
        await model.stopSettingsReadTasksForApplicationShutdown()
        await model.flushPendingPersistenceWrites()
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
        #expect(workflow.metadata["text.provider"] == nil)
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
        #expect(copy.workflow.metadata["text.provider"] == nil)
        #expect(!copy.isEnabled)
        await model.stopSettingsReadTasksForApplicationShutdown()
        await model.flushPendingPersistenceWrites()
    }
}
