import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
final class WebhookReleaseGateTests: XCTestCase {
    func testLegacyWebhookWorkflowIsRejectedBeforeAppModelExecution() {
        let workflow = WorkflowDefinition(
            name: "Legacy Webhook",
            pipeline: PipelineDeclaration(
                recognizerID: "ui.test.recognizer",
                outputActions: [
                    OutputActionReference(
                        id: ExternalOutputActionID.webhookPost,
                        configuration: [
                            ExternalOutputActionConfigurationKey.webhookURL: "https://example.com/private-hook",
                        ]
                    ),
                ]
            ),
            ui: WorkflowUIConfig(symbolName: "network.slash", accentColorName: "orange")
        )
        let harness = makeHarness(workflow: workflow)
        harness.model.language = .english

        XCTAssertFalse(harness.model.canTriggerWorkflow(workflow))
        harness.model.runWorkflow(workflow)

        XCTAssertFalse(harness.model.isRunning)
        XCTAssertEqual(
            harness.model.lastFailure,
            "This workflow cannot run because no production output action is registered for \(ExternalOutputActionID.webhookPost)."
        )
    }

    func testShortcutsAndMarkdownActionsRemainSupported() {
        for actionID in [
            ExternalOutputActionID.shortcutsRun,
            ExternalOutputActionID.markdownAppend,
        ] {
            let workflow = WorkflowDefinition(
                name: "Supported External Output",
                pipeline: PipelineDeclaration(
                    recognizerID: "ui.test.recognizer",
                    outputActions: [OutputActionReference(id: actionID)]
                ),
                ui: WorkflowUIConfig(symbolName: "square.and.arrow.up", accentColorName: "blue")
            )
            let harness = makeHarness(workflow: workflow)

            XCTAssertTrue(harness.model.canTriggerWorkflow(workflow), actionID)
        }
    }

    func testPersistedLegacyWebhookConfigurationIsPreservedButNotEnabledForExecution() async throws {
        let workflow = WorkflowDefinition(
            name: "Persisted Legacy Webhook",
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: "ui.test.recognizer",
                outputActions: [
                    OutputActionReference(
                        id: ExternalOutputActionID.webhookPost,
                        configuration: [
                            ExternalOutputActionConfigurationKey.webhookURL: "https://example.com/preserved-hook",
                            ExternalOutputActionConfigurationKey.webhookHeadersJSON: #"{"X-Project":"preserved"}"#,
                        ]
                    ),
                ]
            ),
            ui: WorkflowUIConfig(symbolName: "network.slash", accentColorName: "orange"),
            metadata: [AppModel.workflowOriginMetadataKey: AppModel.userWorkflowOriginMetadataValue]
        )
        let encoded = try XCTUnwrap(
            String(data: JSONEncoder().encode([workflow]), encoding: .utf8)
        )
        let settingsStore = UITestSettingsStore(storage: [.customWorkflows: encoded])
        let harness = makeHarness(settingsStore: settingsStore)

        await waitForEventProcessing()

        let loadedAction = try XCTUnwrap(harness.model.customWorkflows.first?.pipeline.outputActions.first)
        XCTAssertEqual(loadedAction.id, ExternalOutputActionID.webhookPost)
        XCTAssertEqual(
            loadedAction.configuration[ExternalOutputActionConfigurationKey.webhookHeadersJSON],
            #"{"X-Project":"preserved"}"#
        )
        XCTAssertFalse(harness.model.enabledWorkflows(for: .manual).contains { $0.id == workflow.id })

        let storage = await settingsStore.activitySnapshot()
        XCTAssertEqual(storage.storage[.customWorkflows], encoded)
        XCTAssertNil(storage.setCounts[.customWorkflows])
        XCTAssertNil(storage.removeCounts[.customWorkflows])
    }
}
