import Foundation
import XCTest
@testable import RillCore

final class JSONWorkflowManifestLoaderTests: XCTestCase {
    func testLoaderDecodesValidManifest() throws {
        let json = """
        {
          "schemaVersion": 1,
          "voiceProfiles": [],
          "workflows": [
            {
              "id": "A0F99D93-7E4D-46CE-A188-8B713EF229DA",
              "name": "Valid Workflow",
              "titleKey": "directDemoClipboard",
              "trigger": "manual",
              "pipeline": {
                "recognizerID": "demo.direct",
                "postProcessSteps": [],
                "outputActions": [
                  {
                    "id": "system-clipboard.copy",
                    "configuration": {}
                  }
                ],
                "uncertaintyPolicy": {
                  "mode": "off",
                  "confidenceThreshold": 0,
                  "timeoutSeconds": 0
                },
                "deliveryPolicy": {
                  "strategy": "clipboardOnly"
                }
              },
              "ui": {
                "symbolName": "waveform",
                "accentColorName": "blue"
              },
              "metadata": {
                "source": "test"
              }
            }
          ],
          "metadata": {
            "format": "json"
          }
        }
        """

        let manifest = try JSONWorkflowManifestLoader(data: Data(json.utf8)).loadManifest()

        XCTAssertEqual(manifest.workflows.count, 1)
        XCTAssertEqual(manifest.workflows[0].metadata["source"], "test")
    }

    func testLoaderRejectsEmptyWorkflowList() {
        let json = """
        {
          "schemaVersion": 1,
          "voiceProfiles": [],
          "workflows": [],
          "metadata": {}
        }
        """

        XCTAssertThrowsError(try JSONWorkflowManifestLoader(data: Data(json.utf8)).loadManifest()) { error in
            XCTAssertEqual(
                error as? WorkflowManifestLoadError,
                .invalid("Workflow manifest must include at least one workflow.")
            )
        }
    }

    func testLoaderRejectsUnsupportedWebhookAction() throws {
        let manifest = makeManifest(
            action: OutputActionReference(id: ExternalOutputActionID.webhookPost)
        )

        XCTAssertThrowsError(
            try JSONWorkflowManifestLoader(data: JSONEncoder().encode(manifest)).loadManifest()
        ) { error in
            XCTAssertEqual(
                error as? WorkflowManifestLoadError,
                .invalid(
                    "Workflow Imported Workflow uses unsupported output action \(ExternalOutputActionID.webhookPost)."
                )
            )
        }
    }

    func testLoaderRejectsPlaintextWebhookConfigurationOnAnyAction() throws {
        let manifest = makeManifest(
            action: OutputActionReference(
                id: ExternalOutputActionID.shortcutsRun,
                configuration: [
                    ExternalOutputActionConfigurationKey.webhookURL: "https://example.com/private-hook",
                ]
            )
        )

        XCTAssertThrowsError(
            try JSONWorkflowManifestLoader(data: JSONEncoder().encode(manifest)).loadManifest()
        ) { error in
            XCTAssertEqual(
                error as? WorkflowManifestLoadError,
                .invalid(
                    "Workflow Imported Workflow contains plaintext Webhook configuration (\(ExternalOutputActionConfigurationKey.webhookURL)), which is not accepted."
                )
            )
        }
    }

    func testLoaderAcceptsSupportedExternalActionConfiguration() throws {
        let actions = [
            OutputActionReference(
                id: ExternalOutputActionID.shortcutsRun,
                configuration: [ExternalOutputActionConfigurationKey.shortcutName: "Capture Note"]
            ),
            OutputActionReference(
                id: ExternalOutputActionID.markdownAppend,
                configuration: [ExternalOutputActionConfigurationKey.markdownAppendPath: "~/Notes/Capture.md"]
            ),
        ]

        for action in actions {
            let data = try JSONEncoder().encode(makeManifest(action: action))
            XCTAssertNoThrow(try JSONWorkflowManifestLoader(data: data).loadManifest())
        }
    }

    private func makeManifest(action: OutputActionReference) -> WorkflowManifest {
        WorkflowManifest(
            workflows: [
                WorkflowDefinition(
                    name: "Imported Workflow",
                    pipeline: PipelineDeclaration(
                        recognizerID: "test.recognizer",
                        outputActions: [action]
                    ),
                    ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
                ),
            ]
        )
    }
}
